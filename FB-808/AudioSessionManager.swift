//  AudioSessionManager.swift — owns the AVAudioSession: category, the per-route IO-buffer policy, and
//  route classification. Extracted from AudioEngine (Phase 1 of AUDIO_ENGINE_PLAN) so the session policy
//  has one home and can grow (sample-rate negotiation, external-interface tuning) without touching the
//  render graph. Pure session policy — it never owns or rebuilds the AVAudioEngine itself.

import AVFoundation
import Combine

@MainActor
final class AudioSessionManager: ObservableObject {
    enum RouteClass: String { case builtIn, wired, bluetooth, usb, other }

    @Published private(set) var grantedBufferSec = 0.0   // what the OS ACTUALLY granted (never assumed)
    @Published private(set) var routeName = "—"
    @Published private(set) var routeClass: RouteClass = .builtIn
    private var manualBufferSec = 0.0                     // 0 ⇒ Auto (per-route frame-count policy)
    var preferredSampleRate = 0.0                         // request the engine's rate from the hardware (0 = leave default)

    /// Frames the policy targets for the current route. 256 is the default low-latency target; Bluetooth
    /// is inherently high-latency so it gets a bigger one. A manual override (user-picked ms) wins when set.
    /// Default is 512 frames (~10.7 ms @48k): our render does real per-sample DSP across many voices, so the
    /// old 256 left too little time per callback → missed deadlines → crackle. 512 doubles the render budget
    /// (still well under AudioKit's 1024 default) for negligible added latency. Users who need snappier pads
    /// can still pick "Low · 3 ms" manually.
    var targetFrames: Int {
        guard manualBufferSec <= 0 else { return Int((manualBufferSec * grantedSampleRate).rounded()) }
        return routeClass == .bluetooth ? 1024 : 512
    }
    private var grantedSampleRate: Double { max(8000, AVAudioSession.sharedInstance().sampleRate) }

    /// Set the manual buffer (0 = Auto). Returns true only if it actually changed (so the caller can
    /// skip a needless IO restart when an unrelated audio setting changed).
    @discardableResult
    func setManualBuffer(_ sec: Double) -> Bool {
        let v = max(0, sec)
        guard abs(v - manualBufferSec) > 1e-6 else { return false }
        manualBufferSec = v
        return true
    }

    /// Category + buffer target + activate, then READ BACK the granted buffer (the system may quantize to
    /// something larger). Returns the granted IO buffer duration. Re-callable on route/interruption recovery.
    @discardableResult
    func activatePlayback() -> Double {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        if preferredSampleRate > 0 { try? s.setPreferredSampleRate(preferredSampleRate) }   // match engine rate when the HW can
        classifyRoute(s)                                    // know the route before picking the target
        let sr = max(8000, s.sampleRate)
        let target = manualBufferSec > 0 ? manualBufferSec : Double(targetFrames) / sr
        try? s.setPreferredIOBufferDuration(max(0.0026, min(0.046, target)))
        try? s.setActive(true)
        grantedBufferSec = s.ioBufferDuration               // TRUTH, not the requested value
        classifyRoute(s)                                    // route can finalize after activation
        return grantedBufferSec
    }

    /// Switch the session to play-and-record for mic/line/USB capture (Phase 7). Mirrors `activatePlayback`
    /// (preferred SR + buffer + readback + route classify) but with `.playAndRecord`, so recording runs at
    /// the engine rate and the buffer/route policy stays in this one home. Honors a user-selected input
    /// (`preferredInputUID`) when set. Returns the granted IO buffer duration. The caller still owns the
    /// AVAudioEngine graph dance (stop → reconfigure → start); this only owns the session policy.
    @discardableResult
    func activateRecording() -> Double {
        let s = AVAudioSession.sharedInstance()
        // .bluetoothHighQualityRecording (iOS 26): record AirPods at LAV-mic quality instead of HFP (WWDC25).
        var opts: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth, .mixWithOthers]
        if #available(iOS 26.0, *) { opts.insert(.bluetoothHighQualityRecording) }
        try? s.setCategory(.playAndRecord, mode: .default, options: opts)
        if preferredSampleRate > 0 { try? s.setPreferredSampleRate(preferredSampleRate) }
        classifyRoute(s)
        let sr = max(8000, s.sampleRate)
        let target = manualBufferSec > 0 ? manualBufferSec : Double(targetFrames) / sr
        try? s.setPreferredIOBufferDuration(max(0.0026, min(0.046, target)))
        try? s.setActive(true)
        applyPreferredInput(s)                              // route to the chosen input device, if any
        grantedBufferSec = s.ioBufferDuration
        classifyRoute(s)
        return grantedBufferSec
    }

    func currentBufferDuration() -> Double { AVAudioSession.sharedInstance().ioBufferDuration }

    // MARK: input selection (Phase 7) — mic / line / Bluetooth / USB capture sources

    struct InputOption: Identifiable, Equatable { let id: String; let name: String; let kind: RouteClass }
    /// The user's chosen capture input (portUID), or nil for the system default. Applied on the next record activation.
    private(set) var preferredInputUID: String?

    /// Capture inputs currently available (only meaningful once a record-capable category is active).
    func availableInputs() -> [InputOption] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map {
            InputOption(id: $0.uid, name: $0.portName, kind: inputKind($0.portType))
        }
    }

    /// Choose a capture input by portUID (nil = system default). Applied immediately if recording is live.
    func setPreferredInput(_ uid: String?) {
        preferredInputUID = uid
        let s = AVAudioSession.sharedInstance()
        if s.category == .playAndRecord { applyPreferredInput(s) }
    }

    private func applyPreferredInput(_ s: AVAudioSession) {
        guard let uid = preferredInputUID,
              let port = (s.availableInputs ?? []).first(where: { $0.uid == uid }) else { return }
        try? s.setPreferredInput(port)
    }

    /// Active capture input name (for the record meter / diagnostics), or "—" when none.
    var inputName: String { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "—" }

    private func inputKind(_ t: AVAudioSession.Port) -> RouteClass {
        switch t {
        case .builtInMic:                                       return .builtIn
        case .headsetMic, .headphones:                          return .wired
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP:       return .bluetooth
        case .usbAudio:                                         return .usb
        default:                                                return .other
        }
    }

    /// Human-readable line for the diagnostics panel, e.g. "Built-in · 256 fr · 5.3 ms".
    var summary: String {
        let frames = Int((grantedBufferSec * grantedSampleRate).rounded())
        return "\(routeName) · \(frames) fr · \(String(format: "%.1f", grantedBufferSec * 1000)) ms\(manualBufferSec > 0 ? "" : " (auto)")"
    }

    private func classifyRoute(_ s: AVAudioSession) {
        let out = s.currentRoute.outputs.first
        routeName = out?.portName ?? "—"
        switch out?.portType {
        case .some(.builtInSpeaker), .some(.builtInReceiver):                 routeClass = .builtIn
        case .some(.headphones), .some(.headsetMic):                          routeClass = .wired
        case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP): routeClass = .bluetooth
        case .some(.usbAudio):                                                routeClass = .usb
        default:                                                              routeClass = .other
        }
    }
}
