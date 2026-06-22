//  AudioEngine.swift — centralized low-latency synth engine.
//
//  A single AVAudioSourceNode performs real-time additive/subtractive synthesis
//  for every drum voice (ported sample-for-sample from the prototype's audio.js
//  Web-Audio graph) plus sample-buffer slice playback for Sample Mode.
//
//  The synthesis core is `nonisolated` and `@unchecked Sendable` so the audio
//  render thread can drive it; a tiny os_unfair_lock guards the voice pool.

@preconcurrency import AVFoundation   // suppress AVFAudio Sendable noise (e.g. AVAudioPCMBuffer in the converter block)
import Combine
import os
import FD808Engine

// MARK: - Engine wrapper (main actor)

@MainActor
final class AudioEngine: ObservableObject {
    /// The engine sample rate, chosen at launch from the persisted setting (44.1/48/88.2/96 kHz; default
    /// 48k). A live switch would require recreating the core + graph + re-resampling every loaded sample,
    /// so the rate is fixed per launch (a change applies on the next launch) — safe and behavior-preserving.
    static func savedSampleRate() -> Double {
        let v = UserDefaults.standard.object(forKey: "fd.sampleRate") as? Double ?? 48000
        return [44100.0, 48000, 88200, 96000].contains(v) ? v : 48000
    }
    let core = SynthCore(sampleRate: AudioEngine.savedSampleRate())
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var started = false
    private var ioFormat: AVAudioFormat!
    let sessionMgr = AudioSessionManager()            // owns AVAudioSession category + per-route buffer policy
    private var reclaimTimer: Timer?                  // frees finished voices off the audio thread
    private var diagTimer: Timer?                     // samples engine telemetry for the UI (~5 Hz)
    @Published private(set) var diag = AudioDiagnostics()   // live render metrics (Phase 0)
    @Published private(set) var restartCount = 0            // engine restarts (interruption/route/config recovery)
    @Published private(set) var lastRestartReason = ""

    init() { configure(); restoreMasterChain() }

    private func configure() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: core.sr, channels: 2)!
        ioFormat = fmt
        let core = self.core
        srcNode = AVAudioSourceNode(format: fmt) { _, _, frameCount, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            core.render(frames: Int(frameCount), abl: abl)
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
    }

    // MARK: - AUv3 hosting (A15): 3rd-party effects inserted on the master bus

    struct HostedAU: Identifiable {
        let id = UUID()
        let name: String
        let unit: AVAudioUnit
    }
    @Published private(set) var masterAUs: [HostedAU] = []

    /// Every installed AUv3 audio effect (+ music effect) the system can load.
    /// Returns nothing in the Simulator — 3rd-party AUv3s only register on device.
    nonisolated static func availableEffects() -> [AVAudioUnitComponent] {
        let mgr = AVAudioUnitComponentManager.shared()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: 0, componentManufacturer: 0,
                                             componentFlags: 0, componentFlagsMask: 0)
        let fx = mgr.components(matching: desc)
        desc.componentType = kAudioUnitType_MusicEffect
        let mfx = mgr.components(matching: desc)
        return (fx + mfx).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Instantiate an effect and append it to the master insert chain.
    func addMasterAU(_ comp: AVAudioUnitComponent) async -> Bool {
        do {
            let avAU = try await AVAudioUnit.instantiate(with: comp.audioComponentDescription, options: [])
            engine.attach(avAU)
            masterAUs.append(HostedAU(name: comp.name, unit: avAU))
            engine.mainMixerNode.outputVolume = 0   // mute across the rewire so disconnecting srcNode doesn't click
            rebuildMasterChain()
            engine.mainMixerNode.outputVolume = 1
            persistMasterChain()
            return true
        } catch {
            print("AU load error: \(error)")
            return false
        }
    }

    func removeMasterAU(_ id: UUID) {
        guard let idx = masterAUs.firstIndex(where: { $0.id == id }) else { return }
        let removed = masterAUs.remove(at: idx)
        engine.mainMixerNode.outputVolume = 0   // mute across the rewire (avoids the disconnect click)
        rebuildMasterChain()
        engine.mainMixerNode.outputVolume = 1
        engine.detach(removed.unit)
        persistMasterChain()
    }

    /// Re-wire srcNode → [AU…] → mainMixer to reflect the current chain.
    private func rebuildMasterChain() {
        let mixer = engine.mainMixerNode
        engine.disconnectNodeOutput(srcNode)
        for au in masterAUs { engine.disconnectNodeOutput(au.unit) }
        var prev: AVAudioNode = srcNode
        for au in masterAUs {
            engine.connect(prev, to: au.unit, format: ioFormat)
            prev = au.unit
        }
        engine.connect(prev, to: mixer, format: ioFormat)
    }

    // Persist the chain (component IDs + each plugin's fullState) so it reloads next launch.
    private let auChainKey = "fd808.masterAUChain"

    private func persistMasterChain() {
        let arr: [[String: Any]] = masterAUs.map { hosted in
            let d = hosted.unit.audioComponentDescription
            var entry: [String: Any] = [
                "type": NSNumber(value: d.componentType),
                "sub": NSNumber(value: d.componentSubType),
                "mfr": NSNumber(value: d.componentManufacturer),
            ]
            if let state = hosted.unit.auAudioUnit.fullState { entry["state"] = state }
            return entry
        }
        UserDefaults.standard.set(arr, forKey: auChainKey)
    }

    private func restoreMasterChain() {
        guard let arr = UserDefaults.standard.array(forKey: auChainKey) as? [[String: Any]], !arr.isEmpty else { return }
        Task { @MainActor in
            for entry in arr {
                guard let t = (entry["type"] as? NSNumber)?.uint32Value,
                      let s = (entry["sub"] as? NSNumber)?.uint32Value,
                      let m = (entry["mfr"] as? NSNumber)?.uint32Value else { continue }
                let desc = AudioComponentDescription(componentType: t, componentSubType: s,
                                                     componentManufacturer: m, componentFlags: 0, componentFlagsMask: 0)
                guard AVAudioUnitComponentManager.shared().components(matching: desc).first != nil,
                      let avAU = try? await AVAudioUnit.instantiate(with: desc, options: []) else { continue }
                if let state = entry["state"] as? [String: Any] { avAU.auAudioUnit.fullState = state }
                engine.attach(avAU)
                masterAUs.append(HostedAU(name: avAU.auAudioUnit.audioUnitName ?? "Plugin", unit: avAU))
            }
            rebuildMasterChain()
        }
    }

    func start() {
        guard !engine.isRunning else { started = true; return }   // guard on real engine state, not a cached flag
        sessionMgr.preferredSampleRate = core.sr   // ask the hardware to run at the engine rate (96k etc.)
        sessionMgr.activatePlayback()   // category + per-route buffer target + activate + read back actual
        do {
            try engine.start()
            started = true
            startReclaimTimer()
            installAudioObservers()
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }

    /// Periodically release finished voices the render thread parked (off the audio thread). 100ms keeps
    /// the reclaim bin well under capacity even during dense rolls (so the render thread never frees).
    private func startReclaimTimer() {
        guard reclaimTimer == nil else { return }
        let core = self.core
        reclaimTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in core.drainReclaim() }
        if diagTimer == nil {
            diagTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.diag = self.core.diagnostics()
                    self.inputLevel = self.isMicRecording ? (self.mic?.peakLevel() ?? 0) : 0   // record meter
                }
            }
        }
    }

    /// Combined telemetry for the UI: engine render metrics + the session-level facts the engine owns.
    func diagnosticsSummary() -> (diag: AudioDiagnostics, bufferMs: Double, restarts: Int, reason: String) {
        (diag, currentBufferDuration() * 1000, restartCount, lastRestartReason)
    }

    // MARK: - Interruption / route / configuration recovery
    // Without these, audio dies permanently after a phone call, a headphone unplug, or an output switch.

    private var audioObservers: [NSObjectProtocol] = []
    private func installAudioObservers() {
        guard audioObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        audioObservers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let info = note.userInfo,
                      let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                if opts.contains(.shouldResume) { self.restartAudio() }   // resume after the call/alarm ends
            }
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio() }            // headphones unplugged / BT switched
        })
        audioObservers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio(reconfigure: true) }   // output rate/route changed
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio(reconfigure: true) }
        })
    }

    /// Re-activate the session and restart the engine if it stopped. Idempotent. Re-applies the per-route
    /// buffer policy (so e.g. switching to Bluetooth re-targets 512 frames) and re-reads the granted buffer.
    func restartAudio(reconfigure: Bool = false) {
        sessionMgr.activatePlayback()
        if reconfigure { rebuildMasterChain() }   // re-establish srcNode→mixer after a graph teardown
        let wasRunning = engine.isRunning
        if !engine.isRunning {
            do { try engine.start() } catch { print("AudioEngine restart error: \(error)") }
        }
        if !wasRunning && engine.isRunning {       // diagnostics: count actual recoveries
            restartCount += 1
            lastRestartReason = reconfigure ? "config/route" : "interruption/route"
        }
        started = engine.isRunning
    }

    // MARK: - Audio settings (latency / polyphony / safety limiter)

    /// Push the user's audio preferences to the engine. Buffer changes restart the IO; polyphony +
    /// limiter apply live.
    func applyAudioSettings(bufferSec: Double, polyphony: Int, limiterOn: Bool, limiterCeilingDb: Double) {
        core.setVoiceLimit(polyphony)
        core.setSafetyLimiter(ceilingDb: limiterCeilingDb, enabled: limiterOn)
        setPreferredBuffer(bufferSec)
    }

    /// The IO buffer the system actually granted (may differ from preferred; the OS quantizes it).
    func currentBufferDuration() -> Double { sessionMgr.currentBufferDuration() }

    /// Set the buffer policy (sec; pass 0 for the per-route Auto target) and restart the IO if running.
    func setPreferredBuffer(_ sec: Double) {
        guard sessionMgr.setManualBuffer(sec) else { return }   // unchanged → don't restart the IO
        guard engine.isRunning else { return }         // otherwise applied on next start()
        engine.mainMixerNode.outputVolume = 0          // mute across the IO restart to avoid a click
        engine.stop(); started = false
        start()
        engine.mainMixerNode.outputVolume = 1
    }

    private func ensure() { if !started { start() } }

    // MARK: microphone recording (A4)

    @Published private(set) var isMicRecording = false
    @Published private(set) var inputLevel: Float = 0   // record-meter input peak (0…1), published ~5 Hz while recording
    private(set) var micStartTime = 0.0   // engine time when the input tap began (for record alignment)
    private var mic: MicCapture?

    private func requestMicPermission(_ cb: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { cb(ok) } }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { ok in DispatchQueue.main.async { cb(ok) } }
        }
    }

    /// Ask for mic access, switch the session to play-and-record, and tap the input.
    func startMicRecording(_ completion: @escaping (Bool) -> Void) {
        guard !isMicRecording else { completion(false); return }
        requestMicPermission { [weak self] granted in
            guard let self else { completion(false); return }
            completion(granted ? self.beginMicTap() : false)
        }
    }

    private func beginMicTap() -> Bool {
        engine.stop()
        sessionMgr.preferredSampleRate = core.sr            // capture at the engine rate (Phase 5/7)
        sessionMgr.activateRecording()                      // .playAndRecord via the one session-policy home (Phase 7)
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0, let cap = MicCapture(inputFormat: fmt, sr: core.sr) else {
            started = false; start(); return false           // restore playback
        }
        mic = cap
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in cap.feed(buf) }
        do {
            try engine.start()
        } catch {
            print("mic record start error: \(error)")
            input.removeTap(onBus: 0); mic = nil; started = false; start()   // restore playback
            return false
        }
        micStartTime = core.now()
        isMicRecording = true
        return true
    }

    /// Tear down the tap, return captured mono audio, restore the .playback session.
    private func endMicCapture() -> [Float]? {
        guard isMicRecording else { return nil }
        isMicRecording = false
        engine.inputNode.removeTap(onBus: 0)
        let data = mic?.take() ?? []
        mic = nil
        engine.stop()
        started = false; start()                          // back to .playback
        return data.isEmpty ? nil : data
    }

    /// Stop recording → load into the Sample buffer (Sample mode "Record Mic").
    func stopMicRecording() -> (dur: Double, transients: [Double], wave: [Double])? {
        guard let data = endMicCapture() else { return nil }
        return core.loadExternal(data)
    }

    /// Stop recording → return raw mono audio + reported round-trip latency (for clip recording).
    func stopMicRecordingRaw() -> (data: [Float], latency: Double)? {
        let s = AVAudioSession.sharedInstance()
        let lat = s.inputLatency + s.outputLatency
        guard let data = endMicCapture() else { return nil }
        return (data, lat)
    }

    func now() -> Double { core.now() }
    /// The engine's working sample rate (Phase 5). Authoritative for any seconds↔samples math outside the
    /// core — e.g. trimming a recorded take to the beat, which must NOT assume 48 k once higher rates exist.
    var sampleRate: Double { core.sr }

    // Map sounds → their mixer bus index for per-channel insert FX.
    static let melodyChannel = FX_CHANNELS.firstIndex(of: "melody") ?? 5
    static let sampleChannel = FX_CHANNELS.firstIndex(of: "perc") ?? 2
    static func channelIndex(for sound: String) -> Int {
        let s = sound.hasPrefix("smp:") ? String(sound.dropFirst(4)) : sound
        return FX_CHANNELS.firstIndex(of: Kit.channelOf(s)) ?? 0
    }

    /// Register/clear an imported one-shot for a pad. `padID` is the bare pad id.
    func registerPadSample(_ padID: String, _ data: [Float]) { core.registerPadSample("smp:" + padID, data) }
    func clearPadSample(_ padID: String) { core.clearPadSample("smp:" + padID) }

    func trigger(_ sound: String, vel: Double = 0.82, when: Double? = nil, opts: TriggerOpts? = nil, channel: Int? = nil) {
        ensure()
        let w = when ?? (now() + 0.003)
        core.trigger(sound, vel: vel, whenSample: w * core.sr, opts: opts, channel: channel ?? Self.channelIndex(for: sound))
    }

    func playBuffer(offset: Double, dur: Double, vel: Double = 0.9, when: Double? = nil, pitch: Double = 0, pan: Double = 0) {
        ensure()
        let w = when ?? (now() + 0.003)
        core.playBuffer(offsetSec: offset, durSec: dur, vel: vel, whenSample: w * core.sr, pitch: pitch, pan: pan, channel: Self.sampleChannel)
    }

    /// Granular cloud over the loaded sample buffer (Sample mode "Granular").
    func playGranular(pos: Double, grainMs: Double, density: Double, spread: Double, pitch: Double, dur: Double) {
        ensure()
        core.playGranular(posNorm: pos, grainMs: grainMs, density: density, spread: spread,
                          pitch: pitch, durSec: dur, whenSample: (now() + 0.003) * core.sr, channel: Self.sampleChannel)
    }

    func synthOn(_ key: String, midi: Int, patch: SynthPatch, vel: Double = 1.0, when: Double? = nil) {
        ensure()
        let w = when ?? (now() + 0.003)
        core.synthOn(key, midi: midi, patch: patch, vel: vel, whenSample: w * core.sr, channel: Self.melodyChannel)
    }
    func synthOff(_ key: String) { core.synthOff(key) }
    func triggerSynth(_ patch: SynthPatch, midi: Int, dur: Double, vel: Double, when: Double? = nil, pan: Double = 0, channel: Int? = nil) {
        ensure()
        let w = when ?? (now() + 0.003)
        core.triggerSynth(patch, midi: midi, dur: dur, vel: vel, whenSample: w * core.sr, channel: channel ?? Self.melodyChannel, pan: pan)
    }
    func makeSynthSample(_ kind: String) { ensure(); core.makeSynthSample(kind) }
    func applySampleEdits(reverse: Bool, normalize: Bool, fadeIn: Bool, fadeOut: Bool, gain: Double) -> [Double] {
        core.applySampleEdits(reverse: reverse, normalize: normalize, fadeIn: fadeIn, fadeOut: fadeOut, gain: gain)
    }
    func cropSample(trim: [Double]) -> (dur: Double, wave: [Double]) { core.cropSample(trim: trim) }
    func stretchSample(ratio: Double) -> (dur: Double, wave: [Double]) { core.stretchSample(ratio: ratio) }
    func resetSample() -> [Double] { core.resetSample() }
    func currentSampleOriginal() -> [Float] { core.currentSampleOriginal() }
    func detectPitch() -> Double { ensure(); return core.detectPitch() }
    func makeWavetableFromSample() -> [Float]? { ensure(); return core.makeWavetableFromSample() }
    func sampleToSynth() { core.sampleToSynth() }
    func resampleOutput() -> (dur: Double, wave: [Double]) { ensure(); return core.resampleOutput() }
    func scopeSnapshot() -> [Float] { core.scopeSnapshot() }
    func recordingWaveform() -> [Float] { core.recWaveSnapshot() }
    func momentaryLUFS() -> Double { core.momentaryLUFS() }
    func spectrumSamples(_ count: Int) -> [Float] { core.spectrumSamples(count) }

    func setVolume(_ x: Double) { core.setMaster(x) }
    func setMasterFX(_ s: MasterFX) { core.setMasterFX(s) }
    func setMasterBus(_ s: MasterBus) { core.setMasterBus(s) }
    func setMasterCutoff(_ hz: Double) { core.setMasterCutoff(hz) }
    func setReverbAuto(_ v: Double) { core.setReverbAuto(v) }
    func setDelayAuto(_ v: Double) { core.setDelayAuto(v) }
    func setFlex(_ mode: Int, stepSec: Double) { core.setFlex(mode, stepSec: stepSec) }
    /// Reset all automation overrides to their neutral (off) state.
    func resetAutomation() { core.setMasterCutoff(20000); core.setReverbAuto(-1); core.setDelayAuto(-1) }
    func setChannelFX(_ index: Int, _ s: ChannelFX) { core.setChannelFX(index, s) }
    func setChannelCount(_ n: Int) { core.setChannelCount(n) }   // G2 — dynamic insert-FX bus pool
    func setMultiSample(_ regions: [MultiSampleRegion]) { core.setMultiSample(regions) }

    func makeSample(_ kind: String) -> (dur: Double, transients: [Double], wave: [Double]) {
        ensure()
        return core.makeSampleBuffer(kind)
    }

    /// Decode a user audio file (from Files / iCloud) into the sample buffer as
    /// mono at the engine's sample rate. Returns nil if the file can't be read.
    func importAudio(url: URL, maxSeconds: Double = 30) -> (dur: Double, transients: [Double], wave: [Double])? {
        ensure()
        guard let data = SampleEngine.decode(url: url, targetSR: core.sr, maxSeconds: maxSeconds) else { return nil }
        return core.loadExternal(data)
    }

    /// Off-thread decode then load into the sampler buffer (Phase 2) — the UI doesn't block on the file read.
    func importAudioAsync(url: URL, maxSeconds: Double = 30) async -> (dur: Double, transients: [Double], wave: [Double])? {
        ensure()
        guard let data = await SampleEngine.decodeAsync(url: url, targetSR: core.sr, maxSeconds: maxSeconds) else { return nil }
        return core.loadExternal(data)
    }

    /// Decode a file to mono @ engine SR *without* touching the sample buffer (for audio clips).
    func decodeAudioFile(url: URL, maxSeconds: Double = 60) -> [Float]? {
        ensure(); return SampleEngine.decode(url: url, targetSR: core.sr, maxSeconds: maxSeconds)
    }

    /// Off-thread decode — the UI never blocks on import or large files (Phase 2). Returns on the caller.
    func decodeAudioFileAsync(url: URL, maxSeconds: Double = 60) async -> [Float]? {
        ensure(); return await SampleEngine.decodeAsync(url: url, targetSR: core.sr, maxSeconds: maxSeconds)
    }

    /// Push a raw mono buffer into the sample slot (used to restore a persisted sample on project load).
    @discardableResult
    func importBuffer(_ data: [Float]) -> (dur: Double, transients: [Double], wave: [Double]) { ensure(); return core.loadExternal(data) }

    func playClip(_ data: [Float], when: Double, gain: Double, channel: Int) {
        ensure()
        core.playClip(data: data, whenSample: when * core.sr, gain: gain, channel: channel)
    }
    func stopClips() { core.stopClips() }

    /// Panic / all-notes-off — declick every voice and release held live notes (stuck-note recovery).
    func allNotesOff() { core.releaseAll() }
    /// Per-channel post-strip peak levels for mixer meters (indexed by bus slot).
    func channelPeaks() -> [Float] { core.channelPeaks() }
}
