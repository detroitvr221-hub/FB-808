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

    /// Frames the policy targets for the current route. 256 is the default low-latency target; Bluetooth
    /// is inherently high-latency so it gets 512. A manual override (user-picked ms) wins when set.
    var targetFrames: Int {
        guard manualBufferSec <= 0 else { return Int((manualBufferSec * grantedSampleRate).rounded()) }
        return routeClass == .bluetooth ? 512 : 256
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
        classifyRoute(s)                                    // know the route before picking the target
        let sr = max(8000, s.sampleRate)
        let target = manualBufferSec > 0 ? manualBufferSec : Double(targetFrames) / sr
        try? s.setPreferredIOBufferDuration(max(0.0026, min(0.046, target)))
        try? s.setActive(true)
        grantedBufferSec = s.ioBufferDuration               // TRUTH, not the requested value
        classifyRoute(s)                                    // route can finalize after activation
        return grantedBufferSec
    }

    func currentBufferDuration() -> Double { AVAudioSession.sharedInstance().ioBufferDuration }

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
