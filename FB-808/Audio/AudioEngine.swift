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

/// App-wide logger — replaces scattered `print` for engine/file/export errors (shows in Console.app,
/// off the hot path). Errors are logged `.public` so they're readable in release builds.
nonisolated let fdLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FD808", category: "fd808")

/// Shared audio defaults — one source of truth for the engine sample rate so the validator, the settings
/// UI, the persisted fallback, and the WAV writers can't drift apart. Nonisolated so the `nonisolated`
/// file-writers in Persistence can use them.
nonisolated enum AudioDefaults {
    static let sampleRate: Double = 48_000
    /// Selectable engine sample rates (Hz). Adding one here surfaces it in Settings AND the validator.
    static let supportedSampleRates: [Double] = [44_100, 48_000, 88_200, 96_000]
    /// Unity channel level (linear). Reads as 0 dB on the mixer, the default channel/track volume, and
    /// the fader double-tap reset — kept here so the dB readout and the reset value can't drift apart.
    static let unityGain: Double = 0.82
    /// Fader ceilings (linear). Buses/channels stop at +2.3 dB, arrangement tracks get +4.6 dB of boost for
    /// stacking. Defined ONCE here — the mixer strips, the track setters and the restore/remote sanitizers
    /// all read these (SYSTEMS_GAP_AUDIT #cross-6).
    static let maxChannelVol: Double = 1.1
    static let maxTrackVol: Double = 1.4
    /// Engine strip pool — the DSP allocates at most this many insert-FX buses (SynthCore.setChannelCount).
    static let maxBuses = 64
    /// Max seconds captured for a sampler buffer — shared by mic record AND file import so an imported
    /// loop isn't silently trimmed to a shorter cap than a recording (#SAMPLING-03).
    static let maxSampleSeconds: Double = 60
}

/// Coarse hardware tier (by RAM: 2 GB ≈ A10, 3–4 GB ≈ A12-class) so slow devices get a bigger IO buffer,
/// a lower voice ceiling, and a 48 kHz clamp up front — before the CPU governor has to shed voices after
/// the crackle already happened.
nonisolated enum DeviceTier {
    case low, mid, high
    static func forMemory(_ bytes: UInt64) -> DeviceTier {
        let gib = Double(bytes) / 1_073_741_824
        return gib <= 2.5 ? .low : (gib <= 4.5 ? .mid : .high)
    }
    static let current = forMemory(ProcessInfo.processInfo.physicalMemory)
    var maximumVoices: Int { self == .low ? 32 : (self == .mid ? 64 : 128) }
    var maximumSampleRate: Double { self == .high ? 96_000 : 48_000 }
    var automaticBufferFrames: Int { self == .low ? 1024 : 512 }
    func sampleRate(_ requested: Double) -> Double {
        guard AudioDefaults.supportedSampleRates.contains(requested) else { return AudioDefaults.sampleRate }
        return min(requested, maximumSampleRate)
    }

}

// MARK: - Engine wrapper (main actor)

@MainActor
final class AudioEngine: ObservableObject {
    /// The engine sample rate, chosen at launch from the persisted setting (44.1/48/88.2/96 kHz; default
    /// 48k). A live switch would require recreating the core + graph + re-resampling every loaded sample,
    /// so the rate is fixed per launch (a change applies on the next launch) — safe and behavior-preserving.
    static func savedSampleRate() -> Double {
        DeviceTier.current.sampleRate(UserDefaults.standard.object(forKey: "fd.sampleRate") as? Double ?? AudioDefaults.sampleRate)
    }
    let core = SynthCore(sampleRate: AudioEngine.savedSampleRate())
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var started = false
    private var configured = false
    private var restoredMasterChain = false
    private var ioFormat: AVAudioFormat!
    let sessionMgr = AudioSessionManager()            // owns AVAudioSession category + per-route buffer policy
    private var reclaimTimer: Timer?                  // frees finished voices off the audio thread
    private var diagTimer: Timer?                     // samples engine telemetry for the UI (~5 Hz)
    @Published private(set) var diag = AudioDiagnostics()   // live render metrics (Phase 0)
    @Published private(set) var restartCount = 0            // engine restarts (interruption/route/config recovery)
    @Published private(set) var lastRestartReason = ""
    /// Non-nil while the engine could not be started (session refused, another app holds the route…). The
    /// UI shows a banner from this; before it existed a failed start was a log line and the app animated in
    /// silence (SYSTEMS_GAP_AUDIT #lifecycle-3/8).
    @Published private(set) var audioFailure: String?
    /// Between `.began` and `.ended` the system owns the route: every trigger's ensure() must not hammer
    /// setActive/engine.start (~8 failed starts a second at 120 bpm) or flap the failure banner.
    private var interrupted = false
    private var pendingRestart = false      // a recovery event that arrived mid-restart is re-run once
    private var pendingReconfigure = false  // …with the strongest `reconfigure` any deferred caller asked for
    private var pendingReset = false        // …and a media-services reset always wins (graph must be rebuilt)

    // Rolling telemetry history — timestamped audio events (underruns, clips, voice-steal bursts, dropped
    // commands, restarts, route changes) so a glitch can be diagnosed AFTER the fact on a real device, with
    // no live console. Sampled from the engine's cumulative counters at ~5 Hz; capped ring, newest last.
    struct AudioEvent: Identifiable { let id = UUID(); let at = Date(); let kind: String; let detail: String }
    @Published private(set) var telemetry: [AudioEvent] = []
    private var lastCounters = (spikes: UInt64(0), overruns: UInt64(0), clips: UInt64(0), steals: UInt64(0), dropped: UInt64(0))
    private var lastLoggedSpikeTime = -1.0   // coalesce: one spike reported by several 5 Hz samples logged once
    private let telemetryCap = 200

    private func logEvent(_ kind: String, _ detail: String) {
        telemetry.append(AudioEvent(kind: kind, detail: detail))
        if telemetry.count > telemetryCap { telemetry.removeFirst(telemetry.count - telemetryCap) }
    }
    /// Diff the engine's cumulative counters against the last sample and log notable jumps.
    private func recordTelemetry(_ d: AudioDiagnostics) {
        if d.spikeBlocks > lastCounters.spikes, d.lastSpikeTime != lastLoggedSpikeTime {   // same spike time → already logged
            lastLoggedSpikeTime = d.lastSpikeTime
            logEvent("cpu spike", "+\(d.spikeBlocks - lastCounters.spikes) block(s) · t+\(String(format: "%.2f", d.lastSpikeTime))s · load \(Int(d.lastSpikeLoad * 100))%")
        }
        if d.overruns > lastCounters.overruns {
            logEvent("underrun", "+\(d.overruns - lastCounters.overruns) block(s) · t+\(String(format: "%.2f", d.lastOverrunTime))s · load \(Int(d.lastOverrunLoad * 100))% · \(d.activeVoices) voices")
        }
        if d.droppedCommands > lastCounters.dropped {
            logEvent("dropped cmd", "+\(d.droppedCommands - lastCounters.dropped) (control queue full — overload)")
        }
        if d.clips > lastCounters.clips {
            logEvent("clip", "+\(d.clips - lastCounters.clips) block(s) at ceiling · peak \(String(format: "%.2f", d.peak))")
        }
        if d.steals > lastCounters.steals + 8 {   // only bursts (governor / heavy polyphony), not routine stealing
            logEvent("voice-steal burst", "+\(d.steals - lastCounters.steals) · \(d.activeVoices) voices · load \(Int(d.cpuLoad * 100))%")
        }
        lastCounters = (d.spikeBlocks, d.overruns, d.clips, d.steals, d.droppedCommands)
    }

    /// Human-readable diagnostics report for the in-app "Copy diagnostics" button (item: crash diagnostics).
    func telemetryReport() -> String {
        let s = diagnosticsSummary()
        var L = ["FD-808 audio diagnostics — \(Date())", ""]
        L.append("Sample rate : \(Int(s.diag.sampleRate)) Hz")
        L.append("Buffer      : \(String(format: "%.1f", s.bufferMs)) ms")
        L.append("Route       : \(sessionMgr.summary)")
        L.append("Restarts    : \(s.restarts)\(s.reason.isEmpty ? "" : " (\(s.reason))")")
        L.append("Render load : \(Int(s.diag.cpuLoad * 100))% (\(String(format: "%.2f", s.diag.renderMs))/\(String(format: "%.2f", s.diag.budgetMs)) ms)")
        L.append("Worst block : \(String(format: "%.2f", s.diag.maxRenderMs)) ms · \(Int(s.diag.maxCPULoad * 100))% budget")
        L.append("Voices      : \(s.diag.activeVoices) · peak \(String(format: "%.2f", s.diag.peak))")
        L.append("Timeline    : engine t+\(String(format: "%.2f", s.diag.engineTime))s · last spike t+\(String(format: "%.2f", s.diag.lastSpikeTime))s · last underrun t+\(String(format: "%.2f", s.diag.lastOverrunTime))s")
        L.append("Totals      : spikes \(s.diag.spikeBlocks) · underruns \(s.diag.overruns) · clips \(s.diag.clips) · steals \(s.diag.steals) · dropped \(s.diag.droppedCommands)")
        L.append("Pool        : hits \(s.diag.poolHits) · render-lock misses \(s.diag.renderLockMisses)")
        L.append(""); L.append("Recent events (newest last):")
        if telemetry.isEmpty { L.append("  (none)") }
        for e in telemetry.suffix(100) { L.append("  \(Self.tsFormatter.string(from: e.at))  \(e.kind) — \(e.detail)") }
        return L.joined(separator: "\n")
    }
    private static let tsFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    init() { core.setMetersActive(false) }   // the LUFS readout turns this on when visible

    deinit {
        reclaimTimer?.invalidate()
        diagTimer?.invalidate()
        for observer in audioObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func configure() {
        guard !configured else { return }
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
        configured = true
    }

    private func ensureConfigured() {
        if !configured { configure() }
        if !restoredMasterChain {
            restoredMasterChain = true
            restoreMasterChain()
        }
    }

    // MARK: - AUv3 hosting (A15): 3rd-party effects inserted on the master bus

    struct HostedAU: Identifiable {
        let id: UUID
        let name: String
        let unit: AVAudioUnit
    }
    @Published private(set) var masterAUs: [HostedAU] = []
    @Published private(set) var projectEffects: [HostedEffectState] = []
    @Published private(set) var pluginNotice: String?
    private var chainGeneration = UUID()
    private var chainTask: Task<Void, Never>?
    var onMasterChainWillChange: (() -> Void)?
    var hasHostedEffects: Bool { !projectEffects.isEmpty || !masterAUs.isEmpty }
    static let pluginExportNotice = "AU effects are for live monitoring. Audio exports, stems, resampling and classroom bounces exclude them. Built-in effects are included."

    private let auQuarantinePrefix = "fd808.auFail."
    private let auQuarantineThreshold = 2

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
        ensureConfigured()
        let key = quarantineKey(comp.audioComponentDescription)
        let generation = chainGeneration
        do {
            let avAU = try await instantiateAU(comp.audioComponentDescription, timeout: 5)
            guard generation == chainGeneration, !Task.isCancelled else { return false }
            onMasterChainWillChange?()
            engine.attach(avAU)
            masterAUs.append(HostedAU(id: UUID(), name: comp.name, unit: avAU))
            engine.mainMixerNode.outputVolume = 0   // mute across the rewire so disconnecting srcNode doesn't click
            rebuildMasterChain()
            engine.mainMixerNode.outputVolume = 1
            persistMasterChain()
            clearAUFailure(key)
            return true
        } catch {
            fdLog.error("AU load error: \(error.localizedDescription, privacy: .public)")
            recordAUFailure(key, name: comp.name)
            return false
        }
    }

    func removeMasterAU(_ id: UUID) {
        ensureConfigured()
        guard projectEffects.contains(where: { $0.id == id }) || masterAUs.contains(where: { $0.id == id }) else { return }
        onMasterChainWillChange?()
        // Reconcile the entire requested chain, including a restore still in progress.
        // Cancelling only the removed unit could leave the later saved plugins unloaded.
        restoreProjectEffects(masterChainSnapshot().filter { $0.id != id }, force: true)
    }

    /// Re-wire srcNode → [AU…] → mainMixer to reflect the current chain.
    private func rebuildMasterChain() {
        guard configured else { return }
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

    // The chain is persisted in each project; only the crash watchdog is global.
    private let auRestoreSentinelKey = "fd808.auRestoreInFlight"   // set before restore, cleared after → catches a hung/crashed restore
    struct AUTimeout: Error {}
    private final class AUInstantiateGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func finish(_ body: () -> Void) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            body()
        }
    }
    private final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

    /// Instantiate an AU but give up after `seconds` so a HUNG plugin (which never throws) can't stall
    /// the restore forever — a timeout is treated as a failure (→ quarantine after repeats).
    private func instantiateAU(_ desc: AudioComponentDescription, timeout seconds: Double) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { continuation in
            let gate = AUInstantiateGate()
            let timeout = TaskBox()
            timeout.task = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                gate.finish { continuation.resume(throwing: AUTimeout()) }
            }
            AVAudioUnit.instantiate(with: desc, options: []) { avAU, error in
                gate.finish {
                    timeout.task?.cancel()   // don't leave the timer task sleeping after we've already resolved
                    if let avAU {
                        continuation.resume(returning: avAU)
                    } else {
                        continuation.resume(throwing: error ?? AUTimeout())
                    }
                }
            }
        }
    }

    private func quarantineKey(_ d: AudioComponentDescription) -> String {
        "\(auQuarantinePrefix)\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)"
    }
    private func auFailureCount(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    private func isAUQuarantined(_ key: String) -> Bool { auFailureCount(key) >= auQuarantineThreshold }
    private func recordAUFailure(_ key: String, name: String) {
        let n = auFailureCount(key) + 1
        UserDefaults.standard.set(n, forKey: key)
        logEvent("AUv3 failed", "\(name) · failure \(n)")
    }
    private func clearAUFailure(_ key: String) { UserDefaults.standard.removeObject(forKey: key) }

    func masterChainSnapshot() -> [HostedEffectState] {
        var saved = projectEffects
        for hosted in masterAUs {
            let d = hosted.unit.audioComponentDescription
            let state = hosted.unit.auAudioUnit.fullState.flatMap {
                try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
            }
            let item = HostedEffectState(id: hosted.id, name: hosted.name, type: d.componentType,
                                         subtype: d.componentSubType, manufacturer: d.componentManufacturer, state: state)
            if let i = saved.firstIndex(where: { $0.id == hosted.id }) { saved[i] = item }
            else { saved.append(item) }
        }
        return saved
    }

    private func persistMasterChain() { projectEffects = masterChainSnapshot() }

    func restoreProjectEffects(_ saved: [HostedEffectState], force: Bool = false) {
        guard force || saved != masterChainSnapshot()
                || (chainTask == nil && saved.count != masterAUs.count) else { return }
        if chainTask != nil { UserDefaults.standard.removeObject(forKey: auRestoreSentinelKey) }
        chainGeneration = UUID(); chainTask?.cancel(); chainTask = nil
        let generation = chainGeneration
        projectEffects = saved; pluginNotice = nil
        let removed = masterAUs
        masterAUs.removeAll()
        rebuildMasterChain()
        for au in removed { engine.detach(au.unit) }
        restoredMasterChain = true
        guard !saved.isEmpty else { return }
        ensureConfigured()
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: auRestoreSentinelKey) {
            defaults.removeObject(forKey: auRestoreSentinelKey)
            pluginNotice = "Plugin restore was interrupted. The saved chain is retained; reopen the beat to retry."
            return
        }
        defaults.set(true, forKey: auRestoreSentinelKey)
        chainTask = Task { @MainActor in
            defer {
                if generation == chainGeneration {
                    defaults.removeObject(forKey: auRestoreSentinelKey)
                    chainTask = nil
                }
            }
            for item in saved {
                guard !Task.isCancelled, generation == chainGeneration else { return }
                let desc = AudioComponentDescription(componentType: item.type, componentSubType: item.subtype,
                                                     componentManufacturer: item.manufacturer, componentFlags: 0, componentFlagsMask: 0)
                let key = quarantineKey(desc)
                guard !isAUQuarantined(key), AVAudioUnitComponentManager.shared().components(matching: desc).first != nil else {
                    pluginNotice = "Some saved plugins are unavailable. Their settings have been kept in this beat."
                    continue
                }
                do {
                    let unit = try await instantiateAU(desc, timeout: 5)
                    guard !Task.isCancelled, generation == chainGeneration else { return }
                    if let data = item.state,
                       let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                        unit.auAudioUnit.fullState = state
                    }
                    engine.attach(unit)
                    masterAUs.append(HostedAU(id: item.id, name: item.name, unit: unit))
                    clearAUFailure(key)
                } catch {
                    guard generation == chainGeneration else { return }
                    recordAUFailure(key, name: item.name)
                    pluginNotice = "A plugin could not load. Its settings have been kept in this beat."
                }
            }
            rebuildMasterChain()
        }
    }

    private func restoreMasterChain() { restoreProjectEffects(projectEffects, force: true) }

    func start() {
        guard !engine.isRunning else { started = true; audioFailure = nil; return }   // guard on real engine state, not a cached flag
        guard !interrupted else { return }   // wait for .ended (see `interrupted`)
        // Observers BEFORE the first start attempt: if this launch's start fails (app opened during a call,
        // route held by another app) the interruption/route/reset observers must still be installed, or the
        // engine can never self-recover (SYSTEMS_GAP_AUDIT #lifecycle-8).
        installAudioObservers()
        sessionMgr.preferredSampleRate = core.sr   // ask the hardware to run at the engine rate (96k etc.)
        sessionMgr.activatePlayback()   // category + per-route buffer target + activate + read back actual
        ensureConfigured()
        do {
            try engine.start()
            started = true
            audioFailure = nil
            startReclaimTimer()
        } catch {
            fdLog.error("AudioEngine start error: \(error.localizedDescription, privacy: .public)")
            audioFailure = sessionMgr.lastActivationError ?? error.localizedDescription
            logEvent("engine start failed", audioFailure ?? "")
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
                    self.recordTelemetry(self.diag)   // diff counters → rolling telemetry history
                    self.inputLevel = self.isMicRecording ? (self.mic?.peakLevel() ?? 0) : 0
                    if self.isMicRecording, self.now() - self.micStartTime >= AudioDefaults.maxSampleSeconds {
                        self.finishMicCapture()
                    }
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
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    // iOS has stopped the engine. Release held voices (a sustained synth note or a Note Repeat
                    // roll must not be stranded until resume) and drop the cached `started` flag so the next
                    // trigger's ensure() actually restarts — this case used to be ignored entirely, which is
                    // why a call that ended without .shouldResume left the app silent (SYSTEMS_GAP_AUDIT #lifecycle-1/2).
                    self.interrupted = true
                    self.allNotesOff()
                    self.engine.stop()   // make the stop explicit so isRunning is false and `.active` can recover (round 3, lifecycle-5)
                    self.started = false
                    if self.isMicRecording { self.finishMicCapture() }   // commit the take captured so far
                    self.logEvent("interruption", "began")
                case .ended:
                    self.interrupted = false
                    let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    self.logEvent("interruption", opts.contains(.shouldResume) ? "ended · resume" : "ended")
                    self.restartAudio()   // a music app should come back whether or not iOS hints .shouldResume
                @unknown default: break
                }
            }
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Only restart on route changes that actually affect playback. Route-change fires for many
                // benign reasons (category change from our own activate calls, wake-from-sleep), and
                // restarting on those causes needless stop/start churn — and can re-enter mid-recovery.
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
                switch reason {
                case .oldDeviceUnavailable, .newDeviceAvailable, .override, .routeConfigurationChange:
                    self?.logEvent("route change", AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "—")
                    self?.restartAudio()                                 // headphones unplugged / BT switched
                default:
                    break
                }
            }
        })
        audioObservers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio(reconfigure: true) }   // output rate/route changed
        })
        audioObservers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        audioObservers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let state = ProcessInfo.processInfo.thermalState
                let throttle = state == .serious || state == .critical
                guard throttle != self.thermalThrottled else { return }
                self.thermalThrottled = throttle
                self.core.setVoiceLimit(self.cappedPolyphony())
                self.logEvent("thermal", throttle ? "throttled — voices capped at 24" : "recovered — voice cap restored")
            }
        })
    }

    /// Re-activate the session and restart the engine if it stopped. Idempotent. Re-applies the per-route
    /// buffer policy (so e.g. switching to Bluetooth re-targets 512 frames) and re-reads the granted buffer.
    private var restartingAudio = false
    func restartAudio(reconfigure: Bool = false) {
        guard !restartingAudio else {   // re-run once after this pass, remembering what was asked (round 3, lifecycle-1/2)
            pendingRestart = true; pendingReconfigure = pendingReconfigure || reconfigure; return
        }
        restartingAudio = true
        defer {
            restartingAudio = false
            if pendingReset {
                pendingReset = false; pendingRestart = false; pendingReconfigure = false
                handleMediaServicesReset()
            } else if pendingRestart {
                let r = pendingReconfigure
                pendingRestart = false; pendingReconfigure = false
                restartAudio(reconfigure: r)
            }
        }
        // A take cannot survive the engine stopping: the input node is re-created with the route, the tap
        // is gone, and the capture's trim math assumes a continuous take from micStartTime. Commit the
        // audio captured so far through Transport instead of a silently misaligned take (round 2, lifecycle-5).
        if isMicRecording && !engine.isRunning {
            logEvent("take ended", "audio route/engine restarted during recording")
            finishMicCapture()
        }
        if isMicRecording { sessionMgr.activateRecording() } else { sessionMgr.activatePlayback() }
        ensureConfigured()
        if reconfigure { rebuildMasterChain() }   // re-establish srcNode→mixer after a graph teardown
        let wasRunning = engine.isRunning
        if !engine.isRunning {
            do {
                try engine.start(); audioFailure = nil
                startReclaimTimer()   // the voice-reclaim + diagnostics timers must run after ANY successful start (round 2, lifecycle-1)
            } catch {
                fdLog.error("AudioEngine restart error: \(error.localizedDescription, privacy: .public)")
                audioFailure = sessionMgr.lastActivationError ?? error.localizedDescription
            }
        }
        // The interruption hold lifts only once the engine is really back; clearing it on a FAILED restart
        // (headphones unplugged during a call) re-opened the failed-start storm (round 3, lifecycle-3).
        if engine.isRunning { interrupted = false }
        if !wasRunning && engine.isRunning {       // diagnostics: count actual recoveries
            restartCount += 1
            lastRestartReason = reconfigure ? "config/route" : "interruption/route"
            logEvent("engine restart", "#\(restartCount) · \(lastRestartReason) · \(sessionMgr.summary)")
        }
        started = engine.isRunning
    }

    /// audiod restarted underneath us: every node and hosted AUv3 is dead. Apple's guidance is to dispose and
    /// recreate the graph — a plain restart against the old srcNode/AUs failed silently before
    /// (SYSTEMS_GAP_AUDIT #lifecycle-4). Rebuild from scratch and re-instantiate the master chain from its
    /// persisted state.
    private func handleMediaServicesReset() {
        guard !restartingAudio else { pendingReset = true; return }
        logEvent("media services reset", "rebuilding audio graph")
        if isMicRecording {
            // Commit the take FIRST (the hook tears the capture down through stopMicRecordingRaw); clearing
            // the mic state before it made the hook bail and the audio was lost (round 3, lifecycle-4).
            finishMicCapture()
            if isMicRecording { engine.inputNode.removeTap(onBus: 0); isMicRecording = false; mic = nil }
        }
        persistMasterChain()
        chainGeneration = UUID(); chainTask?.cancel()
        UserDefaults.standard.removeObject(forKey: auRestoreSentinelKey)
        engine.stop()
        for au in masterAUs { engine.detach(au.unit) }
        masterAUs.removeAll()
        if let old = srcNode { engine.detach(old) }
        srcNode = nil
        configured = false
        restoredMasterChain = false
        started = false
        restartAudio(reconfigure: true)   // ensureConfigured() rebuilds srcNode and re-runs restoreMasterChain()
    }

    // MARK: - Audio settings (latency / polyphony / safety limiter)

    /// Push the user's audio preferences to the engine. Buffer changes restart the IO; polyphony +
    /// limiter apply live.
    func applyAudioSettings(bufferSec: Double, polyphony: Int, limiterOn: Bool, limiterCeilingDb: Double) {
        userPolyphony = polyphony
        core.setVoiceLimit(cappedPolyphony())
        core.setSafetyLimiter(ceilingDb: limiterCeilingDb, enabled: limiterOn)
        setPreferredBuffer(bufferSec)
    }

    private var userPolyphony = 32
    private var thermalThrottled = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    /// Low-tier hardware never gets more than 32 voices regardless of the Settings slider; a serious/critical
    /// thermal state tightens any tier to 24 until it recovers.
    private func cappedPolyphony() -> Int {
        var cap = DeviceTier.current.maximumVoices
        if thermalThrottled { cap = Swift.min(cap, 24) }
        return Swift.max(4, Swift.min(userPolyphony, cap))
    }

    /// Live K-weighted loudness metering is CPU the render thread pays on every block; only the LUFS
    /// readout consumes it, so it stays off until that view appears.
    func setMetersActive(_ on: Bool) { core.setMetersActive(on) }

    /// The IO buffer the system actually granted (may differ from preferred; the OS quantizes it).
    func currentBufferDuration() -> Double { sessionMgr.currentBufferDuration() }
    /// The active capture-input device name (e.g. "Scarlett 2i2 USB"), or "—" — for the input picker UI.
    var inputName: String { sessionMgr.inputName }

    /// Configure the session for input selection BEFORE presenting the system input picker (WWDC25:
    /// "configure AVAudioSession before presenting" so the correct device list — USB/Bluetooth — shows).
    /// Requests mic access + switches to a record-capable session. No-op while already recording. The
    /// session stays record-capable (A2DP output + defaultToSpeaker preserved); the next start()/record
    /// re-activates as needed.
    func prepareInputSelection() {
        guard !isMicRecording else { return }
        requestMicPermission { _ in }                   // ensure input access so the picker can enumerate devices
        sessionMgr.preferredSampleRate = core.sr
        sessionMgr.activateRecording()                  // record-capable session → picker lists all inputs
    }
    /// The input picker closed: leave play-and-record (HFP-capable, speaker-default) unless a take is
    /// running, so playback goes back to the normal `.playback` route policy (SETTINGS_AUDIT #2).
    func inputSelectionDismissed() {
        guard !isMicRecording else { return }
        restartAudio()   // re-applies the per-route policy for the current (non-recording) state
    }

    /// The voice limit the engine actually renders with right now (Settings value after the device-tier
    /// and thermal caps) — what the diagnostics readout should show next to "active voices".
    var effectivePolyphony: Int { cappedPolyphony() }

    /// Set the buffer policy (sec; pass 0 for the per-route Auto target) and restart the IO if running.
    func setPreferredBuffer(_ sec: Double) {
        guard sessionMgr.setManualBuffer(sec) else { return }   // unchanged → don't restart the IO
        guard engine.isRunning else { return }         // otherwise applied on next start()
        engine.mainMixerNode.outputVolume = 0          // mute across the IO restart to avoid a click
        engine.stop(); started = false
        start()
        engine.mainMixerNode.outputVolume = 1
    }

    /// Gate on the REAL engine state: `started` is a cache that an interruption invalidates without telling us.
    private func ensure() { if !engine.isRunning && !interrupted { start() } }
    /// Whether the render engine is currently running (RootView's `.active` restart checks this first).
    var isRunning: Bool { engine.isRunning }

    /// Idle in the background: stop rendering and the timers; the next trigger / `.active` restarts (the
    /// audio background mode is for PLAYING in the background, not for burning battery on silence).
    func suspend() {
        guard !isMicRecording else { return }
        engine.stop(); started = false
        reclaimTimer?.invalidate(); reclaimTimer = nil
        diagTimer?.invalidate(); diagTimer = nil
        logEvent("engine suspended", "background, idle")
    }

    // MARK: microphone recording (A4)

    enum MicOwner: Equatable {
        case sampler(String)
        case track(project: String, track: String)
    }
    @Published private(set) var micOwner: MicOwner?
    private var micRequest = UUID()
    private var finishCapture: (() -> Void)?
    @Published private(set) var isMicRecording = false
    @Published private(set) var inputLevel: Float = 0   // record-meter input peak (0…1), published ~5 Hz while recording
    var stereoCapture = false                           // opt-in: capture 2 channels (set from AppSettings before recording)
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
    func startMicRecording(owner: MicOwner, finish: @escaping () -> Void,
                           requestPermission: ((@escaping (Bool) -> Void) -> Void)? = nil,
                           completion: @escaping (Bool) -> Void) {
        guard micOwner == nil, !isMicRecording else { completion(false); return }
        let request = UUID()
        micRequest = request; micOwner = owner; finishCapture = finish
        let requestAccess = requestPermission ?? requestMicPermission
        requestAccess { [weak self] granted in
            guard let self, self.micRequest == request, self.micOwner == owner else { return }
            let ok = granted && self.beginMicTap()
            if !ok { self.micOwner = nil; self.finishCapture = nil }
            completion(ok)
        }
    }

    /// Stop buttons, interruptions and project changes dispatch to the original destination.
    /// Invalidating the request also prevents a late permission response starting capture elsewhere.
    func finishMicCapture(owner: MicOwner? = nil) {
        if let owner, micOwner != owner { return }
        micRequest = UUID()
        let finish = finishCapture
        finishCapture = nil
        if isMicRecording { finish?() }
        micOwner = nil
    }

    private func beginMicTap() -> Bool {
        engine.stop()
        sessionMgr.preferredSampleRate = core.sr            // capture at the engine rate (Phase 5/7)
        sessionMgr.activateRecording()                      // .playAndRecord via the one session-policy home (Phase 7)
        ensureConfigured()
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0,
              let cap = MicCapture(inputFormat: fmt, sr: core.sr, channels: stereoCapture ? 2 : 1,
                                   maxSeconds: AudioDefaults.maxSampleSeconds) else {   // shared cap, not the duplicated default 60
            started = false; start(); return false           // restore playback
        }
        mic = cap
        input.removeTap(onBus: 0)   // clear any stale tap after an interrupted/failed previous capture
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in cap.feed(buf) }
        do {
            try engine.start()
        } catch {
            fdLog.error("mic record start error: \(error.localizedDescription, privacy: .public)")
            input.removeTap(onBus: 0); mic = nil; started = false; start()   // restore playback
            return false
        }
        micStartTime = core.now()
        isMicRecording = true
        return true
    }

    /// Tear down the tap, return captured audio (left + optional right), restore the .playback session.
    private func endMicCaptureStereo() -> (l: [Float], r: [Float]?)? {
        guard isMicRecording else { return nil }
        isMicRecording = false
        micOwner = nil; finishCapture = nil
        engine.inputNode.removeTap(onBus: 0)
        let st = mic?.takeStereo() ?? (l: [], r: nil)
        mic = nil
        engine.stop()
        started = false; start()                          // back to .playback
        return st.l.isEmpty ? nil : st
    }
    private func endMicCapture() -> [Float]? { endMicCaptureStereo()?.l }   // mono path (Sample buffer)

    /// Stop recording → load into the Sample buffer (Sample mode "Record Mic").
    func stopMicRecording() -> (dur: Double, transients: [Double], wave: [Double])? {
        guard let data = endMicCapture() else { return nil }
        return core.loadExternal(data)
    }

    /// Stop recording → return raw audio (left + optional right for stereo) + round-trip latency (for clip recording).
    func stopMicRecordingRaw() -> (data: [Float], dataR: [Float]?, latency: Double)? {
        let s = AVAudioSession.sharedInstance()
        let lat = s.inputLatency + s.outputLatency
        guard let st = endMicCaptureStereo() else { return nil }
        return (st.l, st.r, lat)
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
    func applySampleEdits(reverse: Bool, normalize: Bool, fadeIn: Bool, fadeOut: Bool, gain: Double,
                          trim: [Double] = [0, 1]) -> [Double] {
        core.applySampleEdits(reverse: reverse, normalize: normalize, fadeIn: fadeIn, fadeOut: fadeOut, gain: gain, trim: trim)
    }
    func cropSample(trim: [Double]) -> (dur: Double, wave: [Double]) { core.cropSample(trim: trim) }
    func stretchSample(ratio: Double) -> (dur: Double, wave: [Double]) { core.stretchSample(ratio: ratio) }
    func resetSample() -> [Double] { core.resetSample() }
    func currentSampleOriginal() -> [Float] { core.currentSampleOriginal() }
    func currentSampleData() -> [Float] { core.currentSampleData() }   // edited buffer, for the GPU waveform view
    var audioQuality: AudioQuality { core.quality }
    func setHQInterpolation(_ on: Bool) { core.setHQInterpolation(on) }   // opt-in HQ DSP (default off)
    func setEqualPowerPan(_ on: Bool) { core.setEqualPowerPan(on) }
    func setBandlimitedOsc(_ on: Bool) { core.setBandlimitedOsc(on) }
    /// Split the loaded sample into harmonic (melody) + percussive (drums) stems — on-device, no model. (D1)
    func splitStems() -> (harmonic: [Float], percussive: [Float]) {
        ensure(); return StemSplit.harmonicPercussive(core.currentSampleOriginal(), sr: core.sr)
    }
    /// The loaded sample's raw buffer + engine sample rate (for off-main 4-stem separation). (D1)
    func currentSampleForStems() -> (data: [Float], sr: Double) { ensure(); return (core.currentSampleOriginal(), core.sr) }
    func makeWavetableFromSample() -> [Float]? { ensure(); return core.makeWavetableFromSample() }
    func sampleToSynth() { core.sampleToSynth() }
    /// The last few seconds of live output, silence-trimmed — nil when the capture holds no real signal,
    /// so Resample Mix in a silent project can't replace a loaded sample with a flat line (E3).
    func captureMixOutput() -> [Float]? { ensure(); return core.captureOutputTrimmed() }
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

    /// Off-thread decode — the UI never blocks on import or large files (Phase 2). Returns on the caller.
    /// (Sampler import decodes here, then commits via `importBuffer` inside `mutateSample` so the undo
    /// capture happens on decode SUCCESS, right before the buffer is replaced — C7.)
    func decodeAudioFileAsync(url: URL, maxSeconds: Double = 60) async -> [Float]? {
        ensure(); return await SampleEngine.decodeAsync(url: url, targetSR: core.sr, maxSeconds: maxSeconds)
    }

    /// Push a raw mono buffer into the sample slot (used to restore a persisted sample on project load).
    @discardableResult
    func importBuffer(_ data: [Float]) -> (dur: Double, transients: [Double], wave: [Double]) { ensure(); return core.loadExternal(data) }

    func playClip(_ data: [Float], when: Double, gain: Double, channel: Int, pan: Double = 0, maxFrames: Int? = nil) {
        ensure()
        core.playClip(data: data, whenSample: when * core.sr, gain: gain, channel: channel, pan: pan, maxFrames: maxFrames)
    }
    func stopClips() { core.stopClips() }
    /// Stop any sample-audition voices sounding on the sample channel (Sample-tab Stop / leaving the tab). (#SAMPLING-05)
    func stopSampleAudition() { core.stopClips(channel: Self.sampleChannel) }

    /// Out-of-band review playback (e.g. a student submission in the Teacher console). Routes a fully
    /// decoded clip through the engine's master graph instead of a side `AVPlayer`, so ALL audio runs
    /// through FD808Engine (one session, one route, the master limiter/volume). It plays on a dedicated
    /// review channel and stops channel-scoped, so it never disturbs transport track clips.
    func playReviewClip(_ data: [Float]) {
        guard !data.isEmpty else { return }
        ensure()
        core.stopClips(channel: Self.sampleChannel)   // never overlap review clips
        core.playClip(data: data, whenSample: (core.now() + 0.05) * core.sr, gain: 1, channel: Self.sampleChannel)
    }
    func stopReviewClip() { core.stopClips(channel: Self.sampleChannel) }

    /// Panic / all-notes-off — declick every voice and release held live notes (stuck-note recovery).
    func allNotesOff() { core.releaseAll() }
}
