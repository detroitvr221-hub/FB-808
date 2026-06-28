//  Haptics.swift — "feel the beat" (F2). A CoreHaptics transient pulse on every quarter-note beat
//  during playback (stronger on the downbeat), so the rhythm is felt as well as heard — a genuinely
//  useful angle for a *learning* app, and for deaf / hard-of-hearing learners especially. Opt-in
//  (Settings → Haptics); a no-op on devices without a Taptic Engine.

import CoreHaptics

final class Haptics {
    static let shared = Haptics()

    var enabled = false { didSet { if enabled { ensure() } } }
    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    private func ensure() {
        guard supported, engine == nil else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true                 // the OS can idle it; we restart on demand
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        try? engine?.start()
    }

    /// A short transient tap. `strong` = the bar downbeat (fuller + sharper), else a lighter beat pulse.
    func beat(strong: Bool) {
        guard enabled, supported else { return }
        ensure()
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: strong ? 1.0 : 0.55)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: strong ? 0.7 : 0.4)
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine?.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }
}
