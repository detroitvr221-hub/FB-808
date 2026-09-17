//  Haptics.swift — "feel the beat" (F2). A CoreHaptics transient pulse on every quarter-note beat
//  during playback (stronger on the downbeat), so the rhythm is felt as well as heard — a genuinely
//  useful angle for a *learning* app, and for deaf / hard-of-hearing learners especially. Opt-in
//  (Settings → Haptics); a no-op on devices without a Taptic Engine.

import CoreHaptics

/// A fireable haptic pulse. Production wraps a CoreHaptics player; the regression test injects a counting
/// double so the "built once, reused on every beat" structural property is provable on a simulator with
/// no Taptic Engine (#69).
@MainActor
protocol HapticPulsePlayer: AnyObject {
    func fire()
}

@MainActor
private final class CoreHapticPulsePlayer: HapticPulsePlayer {
    private let player: CHHapticPatternPlayer
    init(player: CHHapticPatternPlayer) { self.player = player }
    func fire() { try? player.start(atTime: CHHapticTimeImmediate) }
}

@MainActor
final class Haptics {
    static let shared = Haptics()

    /// The two beat pulses. Pure values so the shapes can be built and inspected without hardware.
    nonisolated enum Pulse: CaseIterable {
        case weak, strong
        var isStrong: Bool { self == .strong }
        var intensity: Float { isStrong ? 1.0 : 0.55 }
        var sharpness: Float { isStrong ? 0.7 : 0.4 }
    }

    var enabled = false { didSet { if enabled { ensure() } } }
    private var engine: CHHapticEngine?
    /// One cached player per pulse kind, built ONCE in `ensure()` and reused for every beat. The shipped
    /// `beat(strong:)` built a fresh CHHapticEvent + CHHapticPattern + player on the main queue on every
    /// call (four times a second at 120 BPM, same queue as the sampler scheduler) (#69).
    private var players: [Pulse: HapticPulsePlayer] = [:]
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Test seam (#69). Production leaves this nil and `ensure()` builds the CoreHaptics players; the
    /// regression test injects a factory so it can count how many players a run of beats built.
    var pulseFactory: ((Pulse) -> HapticPulsePlayer?)?

    /// Structural counters (#69). `playersBuilt` must stay at one per pulse no matter how many beats fire;
    /// `pulsesFired` counts the beats that actually reached a player.
    private(set) var playersBuilt = 0
    private(set) var pulsesFired = 0

    init() {}

    private func ensure() {
        if let factory = pulseFactory {   // test seam: build the two pulses once, then reuse them
            for pulse in Pulse.allCases where players[pulse] == nil {
                if let player = factory(pulse) { players[pulse] = player; playersBuilt += 1 }
            }
            return
        }
        guard supported, engine == nil else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true                 // the OS can idle it; we restart on demand
        engine?.resetHandler = { [weak self] in
            Task { @MainActor in
                try? self?.engine?.start()
                // The engine restarted, so the cached players belong to a dead engine — rebuild them.
                self?.players.removeAll()
                self?.buildCorePulses()
            }
        }
        try? engine?.start()
        buildCorePulses()
    }

    /// Build the strong/weak players once, against the live engine. Also re-run after a reset.
    private func buildCorePulses() {
        guard let engine else { return }
        for pulse in Pulse.allCases where players[pulse] == nil {
            guard let pattern = try? Self.pattern(for: pulse),
                  let player = try? engine.makePlayer(with: pattern) else { continue }
            players[pulse] = CoreHapticPulsePlayer(player: player)
            playersBuilt += 1
        }
    }

    /// One transient event carrying the pulse's intensity + sharpness. Pure so the shapes are inspectable.
    nonisolated static func pattern(for pulse: Pulse) throws -> CHHapticPattern {
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness)
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
        return try CHHapticPattern(events: [event], parameters: [])
    }

    /// A short transient tap. `strong` = the bar downbeat (fuller + sharper), else a lighter beat pulse.
    /// Only fires the cached player — no allocation on the beat path. The beat is still dispatched from the
    /// main queue by `Transport.scheduleStep` (against musical time), so its placement is only as good as
    /// main-queue latency; building the pattern once removes the allocation jitter, not that scheduling.
    func beat(strong: Bool) {
        guard enabled, supported || pulseFactory != nil else { return }
        ensure()
        pulsesFired += 1
        players[strong ? .strong : .weak]?.fire()
    }
}
