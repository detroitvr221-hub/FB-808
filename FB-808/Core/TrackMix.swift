import Foundation

struct TrackMix {
    var audible: Bool
    var gain: Double
    var pan: Double
    var busKey: String?
}

extension Project {
    /// One gate, fader and routing calculation for seeded, linked, frozen and recorded tracks.
    /// The fader's marked 0 dB position is AudioDefaults.unityGain.
    func trackMix(_ id: String) -> TrackMix {
        var chain: [Track] = []
        var next: String? = id
        var visited = Set<String>()
        while let key = next, let track = tracks.first(where: { $0.id == key }) {
            guard visited.insert(key).inserted else { return TrackMix(audible: false, gain: 0, pan: 0) }
            chain.append(track)
            next = track.busParent.flatMap { parent in tracks.contains { $0.id == parent && $0.type == .bus } ? parent : nil }
        }
        let ids = Set(chain.map(\.id)).union([id])
        let soloOn = tracks.contains { trackSolo[$0.id] == true }
        let audible = !ids.contains { trackMute[$0] == true }
            && (!soloOn || ids.contains { trackSolo[$0] == true })
        let gain = chain.reduce(1.0) { value, track in
            let baked = track.frozenToAudio ? (track.frozenSourceGain ?? 1) : 1
            return value * track.vol / AudioDefaults.unityGain / max(0.00001, baked)
        }
        let pan = max(-1, min(1, chain.reduce(0.0) { $0 + $1.pan - ($1.frozenToAudio ? ($1.frozenSourcePan ?? 0) : 0) }))
        let routed = chain.last(where: { $0.type == .bus || $0.ownsBus })?.id
        return TrackMix(audible: audible, gain: gain, pan: pan, busKey: routed)
    }

    func trackBusChannel(_ mix: TrackMix, fallback: Int) -> Int {
        mix.busKey.flatMap { busOrder.firstIndex(of: $0) } ?? fallback
    }

    /// Balance stereo without collapsing its image. Mono uses the voice's pan law.
    nonisolated static func stereoBalance(_ pan: Double) -> (left: Double, right: Double) {
        (pan > 0 ? 1 - pan : 1, pan < 0 ? 1 + pan : 1)
    }
}
