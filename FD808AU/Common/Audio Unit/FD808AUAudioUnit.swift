//
//  FD808AUAudioUnit.swift
//  FD808AU
//
//  The FD-808 instrument as an AUv3 (type `aumu`). Renders through the SAME
//  `SynthCore` DSP the app uses (shared via the FD808Engine package), so the
//  plugin sounds identical to the app's Synth mode. Handles both legacy
//  `.MIDI` and MIDI-2.0 `.midiEventList` (UMP) note events; factory presets
//  expose the full `SynthPresets` bank; the host "Output Gain" parameter maps
//  to the core master; `fullState` + the App Group persist the patch.
//
//  (The Xcode template's C++ kernel / SinOscillator are unused — left in the
//  target but no longer referenced.)
//

import AVFoundation
import AudioToolbox
import CoreMIDI
import FD808Engine
import os

// Lock-protected patch holder: the render thread reads it on each note-on while
// the main thread may swap it via a preset change. Same os_unfair_lock approach
// SynthCore uses on the audio thread.
private final class AtomicPatch: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var patch: SynthPatch
    init(_ p: SynthPatch) { patch = p }
    func get() -> SynthPatch { os_unfair_lock_lock(&lock); let p = patch; os_unfair_lock_unlock(&lock); return p }
    func set(_ p: SynthPatch) { os_unfair_lock_lock(&lock); patch = p; os_unfair_lock_unlock(&lock) }
}

public class FD808AUAudioUnit: AUAudioUnit, @unchecked Sendable {

    private var core: SynthCore
    private let patchBox: AtomicPatch
    private var gainValue: AUValue = 0.25

    private let format: AVAudioFormat
    private var outputBus: AUAudioUnitBus?
    private var _outputBusses: AUAudioUnitBusArray!

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        self.format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        self.core = SynthCore(sampleRate: 48_000)
        // Pick up the patch the app last designed (App Group), else the default.
        self.patchBox = AtomicPatch(SharedPatchStore.load() ?? SynthPresets.default)
        try super.init(componentDescription: componentDescription, options: options)
        self.core.setMaster(Double(gainValue))
        outputBus = try AUAudioUnitBus(format: self.format)
        outputBus?.maximumChannelCount = 2
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus!])
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    // Opt into MIDI: hosts deliver UMP `.midiEventList`; we also accept legacy `.MIDI`.
    public override var audioUnitMIDIProtocol: MIDIProtocolID { ._1_0 }

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let sr: Double = outputBus?.format.sampleRate ?? 48_000
        if (sr - core.sr).magnitude > 0.5 {
            let fresh = SynthCore(sampleRate: sr)
            fresh.setMaster(Double(gainValue))
            core = fresh
        }
    }

    // MARK: - Rendering (pure Swift — drives SynthCore)

    public override var internalRenderBlock: AUInternalRenderBlock {
        let core = self.core               // captured post-allocate (getter runs after allocateRenderResources)
        let patchBox = self.patchBox
        return { _, _, frameCount, _, outputData, renderEvents, _ in
            let when = core.now() * core.sr
            // status: 0x90 note-on / 0x80 note-off (vel 0 on == off). vel is 0...1.
            func note(_ status: UInt8, _ midi: Int, _ vel: Double) {
                if status == 0x90, vel > 0 {
                    core.synthOn("au\(midi)", midi: midi, patch: patchBox.get(), vel: vel, whenSample: when)
                } else if status == 0x80 || (status == 0x90 && vel == 0) {
                    core.synthOff("au\(midi)")
                }
            }
            var event = renderEvents
            while let e = event {
                let head = e.pointee.head
                switch head.eventType {
                case .MIDI:                                   // legacy AURenderEventMIDI (3 bytes)
                    let m = e.pointee.MIDI
                    note(m.data.0 & 0xF0, Int(m.data.1), Double(m.data.2) / 127.0)
                case .midiEventList:                          // MIDI-2.0 UMP packet(s)
                    let list = e.pointee.MIDIEventsList.eventList
                    // Walk the first packet's words (the common live-input case).
                    withUnsafeBytes(of: list.packet.words) { raw in
                        let words = raw.bindMemory(to: UInt32.self)
                        let count = Int(list.packet.wordCount)
                        var i = 0
                        while i < count {
                            let w0 = words[i]
                            let mt = (w0 >> 28) & 0xF
                            if mt == 0x2 {                    // MIDI 1.0 channel-voice in UMP (1 word)
                                note(UInt8((w0 >> 16) & 0xF0), Int((w0 >> 8) & 0x7F), Double(w0 & 0x7F) / 127.0)
                            } else if mt == 0x4 {             // MIDI 2.0 channel-voice (2 words, 16-bit vel)
                                let w1 = i + 1 < count ? words[i + 1] : 0
                                note(UInt8((w0 >> 16) & 0xF0), Int((w0 >> 8) & 0x7F), Double((w1 >> 16) & 0xFFFF) / 65535.0)
                            }
                            i += FD808AUAudioUnit.umpWordCount(mt)
                        }
                    }
                default: break
                }
                event = head.next.map { UnsafePointer($0) }   // .next is a mutable ptr; the list head is const
            }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            core.render(frames: Int(frameCount), abl: abl)
            return noErr
        }
    }

    private static func umpWordCount(_ messageType: UInt32) -> Int {
        switch messageType {
        case 0x0, 0x1, 0x2: return 1     // utility / system / MIDI1 channel-voice
        case 0x3, 0x4: return 2          // SysEx7 / MIDI2 channel-voice
        case 0x5: return 4               // data128
        default: return 1
        }
    }

    // MARK: - UI helpers (the SwiftUI view's test keyboard + preset stepper)

    public func uiNoteOn(_ midi: Int) {
        core.synthOn("ui\(midi)", midi: midi, patch: patchBox.get(), vel: 0.9, whenSample: core.now() * core.sr)
    }
    public func uiNoteOff(_ midi: Int) { core.synthOff("ui\(midi)") }

    public var patchName: String { patchBox.get().name }

    public func applyPatch(_ p: SynthPatch) {
        patchBox.set(p)
        SharedPatchStore.save(p)
    }

    // MARK: - Factory presets (the full SynthPresets bank)

    public override var factoryPresets: [AUAudioUnitPreset] {
        SynthPresets.all.enumerated().map { i, p in
            let preset = AUAudioUnitPreset()
            preset.number = i
            preset.name = p.name
            return preset
        }
    }

    private var _currentPreset: AUAudioUnitPreset? = {
        let p = AUAudioUnitPreset(); p.number = 0; p.name = SynthPresets.default.name; return p
    }()

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            _currentPreset = newValue
            guard let n = newValue?.number, n >= 0, n < SynthPresets.all.count else { return }
            applyPatch(SynthPresets.all[n])
        }
    }

    // MARK: - State (host session) + App Group

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(patchBox.get()) { s["fd808.patch"] = data }
            s["fd808.gain"] = gainValue
            return s
        }
        set {
            super.fullState = newValue
            if let data = newValue?["fd808.patch"] as? Data,
               let p = try? JSONDecoder().decode(SynthPatch.self, from: data) {
                patchBox.set(p)
            }
            if let g = newValue?["fd808.gain"] as? AUValue {
                gainValue = g
                core.setMaster(Double(g))
            }
        }
    }

    // MARK: - Parameter tree (host "Output Gain" → core master)

    public func setupParameterTree(_ parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree
        for param in parameterTree.allParameters where param.address == FD808AUParameterAddress.gain.rawValue {
            gainValue = param.value
            core.setMaster(Double(param.value))
        }
        setupParameterCallbacks()
    }

    private func setupParameterCallbacks() {
        parameterTree?.implementorValueObserver = { [weak self] param, value in
            guard let self else { return }
            if param.address == FD808AUParameterAddress.gain.rawValue {
                self.gainValue = value
                self.core.setMaster(Double(value))
            }
        }
        parameterTree?.implementorValueProvider = { [weak self] param in
            guard let self else { return 0 }
            return param.address == FD808AUParameterAddress.gain.rawValue ? self.gainValue : 0
        }
        parameterTree?.implementorStringFromValueCallback = { param, valuePtr in
            let v = valuePtr?.pointee ?? param.value
            return String(format: "%.2f", v)
        }
    }
}
