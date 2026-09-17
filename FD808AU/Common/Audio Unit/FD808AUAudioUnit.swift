//
//  FD808AUAudioUnit.swift
//  FD808AU
//
//  The FD-808 instrument as an AUv3 (type `aumu`). Renders through the SAME
//  `SynthCore` DSP the app uses (shared via the FD808Engine package), so the
//  plugin sounds identical to the app's Synth mode. Handles legacy `.MIDI` note
//  events (with a defensive UMP fallback); factory presets
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

/// Fixed-capacity hand-off ring for render banks that have been replaced.
///
/// Publication never waits on this ring: `push` always accepts the newest element and returns the
/// one it displaced (for the caller to release on a control thread), so a burst of preset changes
/// can never stall, drop or delay publishing the bank the render thread should be playing.
// `PreparedInstrument` is the render bank type read by the audio thread. See `AtomicPatch` below for
// how retired banks are kept alive until the render thread can no longer be holding them.

// Patch preparation and disposal run on control threads. The render thread reads the published bank
// through an atomic (+1 owned) reference: no lock, no ARC race, and never a stale bank.
//
// Disposal is governed by a RENDER GRACE PERIOD, not by a timer. A bank that has just been
// unpublished may still be held by a render callback that borrowed it moments earlier, so it is
// parked together with the render epoch at which it was unpublished, and released only once no
// render can still be using it: either a render has completed since (the epoch advanced), or no
// render is in flight at all. The previous design released parked banks from a 50 ms maintenance
// timer whose phase has nothing to do with `set()`, which left a use-after-free window inside the
// audio callback (audit finding 77).
final class AtomicPatch: @unchecked Sendable {
    /// A bank that has been unpublished but may still be in a render callback's hands.
    private struct RetiredBank {
        let bank: PreparedInstrument
        /// Value of `renderEpoch` at the moment the bank was unpublished.
        let retiredAtEpoch: UInt64
    }

    private var lock = os_unfair_lock_s()
    private var patch: SynthPatch
    private var rate = 48_000.0
    /// The bank the render thread plays, as an atomically swapped `Unmanaged` +1 reference.
    /// Non-zero from `init` onwards; readers borrow it, writers retire it (never release in place).
    private let publishedBits = RealtimeAtomic(0)
    /// Count of completed render callbacks. Advanced by the render thread only.
    private let renderEpoch = RealtimeAtomic(0)
    /// 1 while a render callback is executing. Lets the control thread release immediately when the
    /// audio thread is provably not inside a render (for example a stopped host transport).
    private let renderInFlight = RealtimeAtomic(0)
    /// Parked banks, owned and mutated only under `lock`.
    private var retired: [RetiredBank] = []

    init(_ patch: SynthPatch) {
        self.patch = patch
        publishedBits.store(Self.reference(PreparedInstrument(patch: patch, sampleRate: 48_000)))
    }

    deinit {
        // Release the +1 reference held by the published slot (the ring's contents release themselves).
        _ = Self.take(publishedBits.load())
    }

    private static func reference(_ bank: PreparedInstrument) -> UInt64 {
        UInt64(UInt(bitPattern: Unmanaged.passRetained(bank).toOpaque()))
    }

    /// Borrow the published bank without transferring ownership. Safe on the render thread because a
    /// bank stops being published only inside `set()`, which parks it until the grace period proves
    /// no render can still hold it — never released on a timer's schedule.
    private static func borrow(_ bits: UInt64) -> PreparedInstrument? {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: bits)) else { return nil }
        return Unmanaged<PreparedInstrument>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Take ownership of a published reference so it can be parked or released.
    private static func take(_ bits: UInt64) -> PreparedInstrument? {
        guard let raw = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: bits)) else { return nil }
        return Unmanaged<PreparedInstrument>.fromOpaque(raw).takeRetainedValue()
    }

    func get() -> SynthPatch {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return patch
    }

    /// Render-thread read: lock-free, and always the newest bank the control thread published.
    func renderBank() -> PreparedInstrument? { Self.borrow(publishedBits.load()) }

    /// Render-thread bookkeeping. Must bracket every render callback that used `renderBank()`:
    /// call `noteRenderStarted()` *before* borrowing and `noteRenderFinished()` when the callback
    /// returns, so the control thread can tell whether a borrowed bank may still be in use.
    func noteRenderStarted() { renderInFlight.store(1) }
    func noteRenderFinished() { _ = renderEpoch.add(1); renderInFlight.store(0) }

    /// Whether a parked bank is provably unreachable by the render thread. Either no render is in
    /// flight at all (nothing can be holding it), or a render has completed since it was parked, so
    /// the callback that borrowed it has returned. Caller must hold `lock`.
    private func isReleasable(_ entry: RetiredBank) -> Bool {
        if renderInFlight.load() == 0 { return true }
        return entry.retiredAtEpoch < renderEpoch.load()
    }

    /// Remove and return every parked bank the grace period has proven unreachable. Caller must hold
    /// `lock`. `force` returns all of them and is valid only when no render can be in flight.
    private func reapLocked(force: Bool) -> [PreparedInstrument] {
        guard !retired.isEmpty else { return [] }
        var dead: [PreparedInstrument] = []
        var keep: [RetiredBank] = []
        keep.reserveCapacity(retired.count)
        for entry in retired {
            if force || isReleasable(entry) { dead.append(entry.bank) } else { keep.append(entry) }
        }
        retired = keep
        return dead
    }

    func set(_ value: SynthPatch, sampleRate: Double? = nil, resetRenderBank: Bool = false) {
        // State/preset setters are control-thread operations, never called from internalRenderBlock.
        os_unfair_lock_lock(&lock)
        if let sampleRate { rate = sampleRate }
        let bank = PreparedInstrument(patch: value, sampleRate: rate)
        patch = value
        let displaced = publishedBits.exchange(Self.reference(bank))
        // Release anything this swap made garbage *after* dropping the lock, and only on this control
        // thread — never on the render thread.
        var dead: [PreparedInstrument] = []
        if let old = Self.take(displaced) {
            if resetRenderBank {
                // Allocation path: the host guarantees no render is in flight, release right away.
                dead.append(old)
            } else {
                // Never release here. Park it with the current epoch and let the grace period decide,
                // so publication is never deferred however fast presets are changed.
                retired.append(RetiredBank(bank: old, retiredAtEpoch: renderEpoch.load()))
            }
        }
        if resetRenderBank { dead.append(contentsOf: reapLocked(force: true)) }
        // Bounded retention: this reaps whatever is already safe, and when the audio thread is idle
        // `isReleasable` is true for everything, so a host that changes presets without ever
        // rendering cannot accumulate banks.
        dead.append(contentsOf: reapLocked(force: false))
        os_unfair_lock_unlock(&lock)
        withExtendedLifetime(dead) {}
    }

    func collectRetired() {
        os_unfair_lock_lock(&lock)
        let dead = reapLocked(force: false)
        os_unfair_lock_unlock(&lock)
        withExtendedLifetime(dead) {}
    }
}

/// How a host-supplied preset number maps onto this AU's banks. Pure so the contract can be tested
/// without an audio unit.
enum FD808AUPresetResolution: Equatable {
    /// A factory preset; the payload indexes `SynthPresets.all`.
    case factory(Int)
    /// A user preset (`number < 0`) — its state lives in the base class's user-preset store.
    case user
    /// A non-negative number outside the factory bank.
    case unknown
    /// No preset at all.
    case none
}

enum FD808AUPresetResolver {
    /// The SDK contract (AUAudioUnit.h, `presetStateFor:`): "If the preset number is >= 0 then the
    /// preset is a factory preset. If the preset number is < 0 then it is a user preset."
    static func resolve(number: Int?, factoryCount: Int) -> FD808AUPresetResolution {
        guard let number else { return .none }
        if number < 0 { return .user }
        return number < factoryCount ? .factory(number) : .unknown
    }

    /// Index of the factory preset carrying `name`, or nil when the patch is not a factory preset
    /// (restored custom state or a user preset).
    static func factoryIndex(forPatchNamed name: String, in presets: [SynthPatch]) -> Int? {
        presets.firstIndex { $0.name == name }
    }
}

// Only changed by the host's stopped allocate/deallocate lifecycle. A render block fetched before
// allocation still sees the active resources, rather than permanently capturing a nil scratch buffer.
private final class RenderResources: @unchecked Sendable {
    var core: SynthCore?
    var scratch: AVAudioPCMBuffer?
}

public class FD808AUAudioUnit: AUAudioUnit, @unchecked Sendable {

    private var core: SynthCore
    private let patchBox: AtomicPatch
    private let hostEvents = HostEventBuffer()
    private let renderResources = RenderResources()
    private var maintenance: DispatchSourceTimer?
    private let gainBits = RealtimeAtomic(UInt64(Float(0.25).bitPattern))
    private var gainValue: AUValue {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: gainBits.load())) }
        set { gainBits.store(UInt64((newValue.isFinite ? max(0, min(1, newValue)) : 0.25).bitPattern)) }
    }

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
        // The app's live audio-quality / polyphony / limiter settings, so the plugin aliases (or doesn't)
        // exactly where the app does and stacks the same number of voices for the same patch (finding 55).
        SharedAudioSettingsStore.current().apply(to: self.core)
        outputBus = try AUAudioUnitBus(format: self.format)
        outputBus?.maximumChannelCount = 2
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus!])
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    // Declared legacy `.1_0`: hosts deliver `.MIDI` events. The `.midiEventList` branch in the render
    // block is defensive fallback only.
    public override var audioUnitMIDIProtocol: MIDIProtocolID { ._1_0 }

    // MARK: - Render resources

    public override func allocateRenderResources() throws {
        guard let outputFormat = outputBus?.format,
              outputFormat.commonFormat == .pcmFormatFloat32, !outputFormat.isInterleaved,
              (1...2).contains(outputFormat.channelCount),
              let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        maintenance?.cancel()
        let fresh = SynthCore(sampleRate: outputFormat.sampleRate)
        fresh.setMaster(Double(gainValue))
        // Re-apply on every (re)allocation: this is where the host's real sample rate is known, and it is
        // the same core-rebuild path — without this the plugin kept SynthCore's raw defaults (naive
        // oscillator, 64 voices) and did NOT match the app for the same patch (finding 55).
        SharedAudioSettingsStore.current().apply(to: fresh)
        core = fresh; renderResources.core = fresh; renderResources.scratch = scratch
        patchBox.set(patchBox.get(), sampleRate: fresh.sr, resetRenderBank: true)
        let box = patchBox
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fd808.au.reclaim", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { fresh.drainReclaim(); box.collectRetired() }
        maintenance = timer; timer.resume()
    }

    public override func deallocateRenderResources() {
        maintenance?.cancel(); maintenance = nil
        Task { await SharedPatchStore.flush() }
        super.deallocateRenderResources()
        core.drainReclaim()
        renderResources.core = nil; renderResources.scratch = nil
    }
    deinit { maintenance?.cancel() }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        let resources = self.renderResources
        let patchBox = self.patchBox
        let events = self.hostEvents
        return { _, timestamp, frameCount, _, outputData, renderEvents, _ in
            guard let core = resources.core, let scratch = resources.scratch, frameCount <= scratch.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count == Int(scratch.format.channelCount) else { return kAudioUnitErr_FormatNotSupported }
            for channel in 0..<abl.count {
                guard abl[channel].mNumberChannels == 1 else { return kAudioUnitErr_FormatNotSupported }
                if abl[channel].mData == nil {
                    abl[channel].mData = UnsafeMutableRawPointer(scratch.floatChannelData![channel])
                    abl[channel].mDataByteSize = frameCount * 4
                } else if abl[channel].mDataByteSize < frameCount * 4 {
                    return kAudioUnitErr_TooManyFramesToProcess
                }
            }
            events.collect(renderEvents, blockSampleTime: timestamp.pointee.mSampleTime, frames: Int(frameCount))
            if events.overflowed { core.requestPanic() }
            // Bracket the render so AtomicPatch can tell when a borrowed bank is provably out of use.
            // The borrow MUST happen after noteRenderStarted() (audit finding 77).
            patchBox.noteRenderStarted()
            core.render(frames: Int(frameCount), abl: abl, hostEvents: events.events,
                        hostParams: events.parameterEvents, instrument: patchBox.renderBank())
            patchBox.noteRenderFinished()
            return noErr
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

    /// Index of the factory preset whose patch is loaded, or nil when what is loaded is not a factory
    /// preset (restored custom state, or a user preset).
    public var factoryPresetIndex: Int? {
        FD808AUPresetResolver.factoryIndex(forPatchNamed: patchBox.get().name, in: SynthPresets.all)
    }

    /// This AU keeps no user-preset store of its own, so it deliberately does not advertise user
    /// presets. The base class default is already `false`; stating it here is what makes the
    /// `currentPreset` handling below (which never *claims* a preset it could not apply) consistent
    /// for hosts that check this property.
    public override var supportsUserPresets: Bool { false }

    public override var currentPreset: AUAudioUnitPreset? {
        get { _currentPreset }
        set {
            switch FD808AUPresetResolver.resolve(number: newValue?.number, factoryCount: SynthPresets.all.count) {
            case .none:
                _currentPreset = nil
                super.currentPreset = nil
            case .factory(let index):
                applyPatch(SynthPresets.all[index])
                _currentPreset = newValue
                super.currentPreset = newValue     // keep the base class's PresentPreset in sync
            case .user:
                // A user preset is only real when the base class can actually vend its state. If it
                // cannot, the selection did not happen and must not be reported as current.
                if let preset = newValue, let state = try? presetState(for: preset) {
                    fullState = state
                    _currentPreset = preset
                    super.currentPreset = preset
                }
            case .unknown:
                // A non-negative number outside the bank selects nothing; leave the selection alone.
                break
            }
        }
    }

    // MARK: - State (host session) + App Group

    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(patchBox.get()) { s["fd808.patch"] = data }
            s["fd808.gain"] = gainValue
            // Remember the selection as well as the patch: the bank contains presets that share a
            // name (e.g. "Bright Bell" at 80 and 151), so the patch alone cannot restore the number.
            if let number = _currentPreset?.number { s["fd808.preset"] = number }
            return s
        }
        set {
            super.fullState = newValue
            if let data = newValue?["fd808.patch"] as? Data,
               let p = try? JSONDecoder().decode(SynthPatch.self, from: data) {
                patchBox.set(p)
                syncCurrentPreset(to: p, restoredNumber: newValue?["fd808.preset"] as? Int)
            }
            if let g = newValue?["fd808.gain"] as? AUValue {
                gainValue = g
                core.setMaster(Double(g))
            }
        }
    }

    /// Keep the reported preset honest after a state restore: point it at the factory preset that
    /// matches the restored patch, or clear it when the patch is not one of the factory presets.
    private func syncCurrentPreset(to patch: SynthPatch, restoredNumber: Int?) {
        let saved = restoredNumber.flatMap { number -> Int? in
            // Trust a saved number only while it still names the restored patch (banks change between
            // builds); otherwise fall back to matching the patch name.
            guard SynthPresets.all.indices.contains(number), SynthPresets.all[number].name == patch.name else { return nil }
            return number
        }
        let index = saved ?? FD808AUPresetResolver.factoryIndex(forPatchNamed: patch.name, in: SynthPresets.all)
        if let index {
            let preset = AUAudioUnitPreset()
            preset.number = index
            preset.name = SynthPresets.all[index].name
            _currentPreset = preset
            super.currentPreset = preset
        } else {
            _currentPreset = nil
            super.currentPreset = nil
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
