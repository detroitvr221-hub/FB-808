//  BeatGenerator.swift — D8: genre-aware drum-pattern generation. Fills `project.lanes`
//  with a full, editable groove from a style + density. No ML — musical rules: each style
//  is a set of per-pad roles (always-on "core" hits + probabilistic "ghost" ornaments),
//  so every press gives a fresh in-grid variation the user can then edit by hand.

import Foundation

extension Project {

    struct BeatStyle: Identifiable {
        let id: String
        let name: String
        let bpm: Int       // suggested tempo, applied on generate
        let swing: Double  // suggested swing feel
    }

    static let beatStyles: [BeatStyle] = [
        .init(id: "boombap",  name: "Boom Bap",  bpm: 88,  swing: 0.18),
        .init(id: "trap",     name: "Trap",      bpm: 140, swing: 0.0),
        .init(id: "house",    name: "House",     bpm: 124, swing: 0.0),
        .init(id: "drill",    name: "Drill",     bpm: 142, swing: 0.06),
        .init(id: "afrobeat", name: "Afrobeat",  bpm: 108, swing: 0.0),
        .init(id: "lofi",     name: "Lo-Fi",     bpm: 78,  swing: 0.24),
        .init(id: "pop",      name: "Pop",       bpm: 104, swing: 0.0),
        .init(id: "rock",     name: "Rock",      bpm: 120, swing: 0.0),
    ]

    // velocity tiers
    private static let ACC = 0.95, HIT = 0.82, SOFT = 0.62, GH = 0.5

    /// One pad's part within a style.
    private struct Role {
        let pad: String
        var core: [Int] = []          // always placed (if < barSteps)
        var coreVel = HIT
        var ghosts: [Int] = []        // placed with `ghostProb` (× density)
        var ghostProb = 0.0
        var ghostVel = GH
    }

    private static func styleRoles(_ id: String) -> [Role] {
        switch id {
        case "trap":
            return [
                Role(pad: "kick", core: [0, 8], coreVel: ACC, ghosts: [11], ghostProb: 0.4, ghostVel: HIT),
                Role(pad: "sub808", core: [0], coreVel: ACC, ghosts: [6, 7, 10, 11, 14], ghostProb: 0.45, ghostVel: HIT),
                Role(pad: "clap", core: [4, 12], coreVel: ACC),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: HIT,
                     ghosts: [1, 3, 5, 7, 9, 11, 13, 15], ghostProb: 0.7, ghostVel: GH),
                Role(pad: "hatOpen", ghosts: [14], ghostProb: 0.35, ghostVel: SOFT),
            ]
        case "house":
            return [
                Role(pad: "kick", core: [0, 4, 8, 12], coreVel: ACC),
                Role(pad: "clap", core: [4, 12], coreVel: HIT),
                Role(pad: "hatOpen", core: [2, 6, 10, 14], coreVel: HIT),
                Role(pad: "hatClosed", ghosts: [1, 3, 5, 7, 9, 11, 13, 15], ghostProb: 0.55, ghostVel: GH),
                Role(pad: "shaker", ghosts: [0, 2, 4, 6, 8, 10, 12, 14], ghostProb: 0.4, ghostVel: SOFT),
            ]
        case "drill":
            return [
                Role(pad: "kick", core: [0], coreVel: ACC, ghosts: [3, 6, 10, 13], ghostProb: 0.5, ghostVel: HIT),
                Role(pad: "sub808", core: [0], coreVel: ACC, ghosts: [3, 10], ghostProb: 0.5, ghostVel: HIT),
                Role(pad: "snare", core: [4, 12], coreVel: ACC),
                Role(pad: "rim", ghosts: [8, 11], ghostProb: 0.45, ghostVel: GH),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: HIT,
                     ghosts: [1, 3, 5, 7, 9, 11, 13, 15], ghostProb: 0.6, ghostVel: GH),
            ]
        case "afrobeat":
            return [
                Role(pad: "kick", core: [0, 6, 10], coreVel: ACC, ghosts: [3], ghostProb: 0.3, ghostVel: HIT),
                Role(pad: "conga", core: [2, 6, 10, 14], coreVel: HIT, ghosts: [4, 12], ghostProb: 0.4, ghostVel: GH),
                Role(pad: "shaker", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: SOFT),
                Role(pad: "clap", core: [4, 12], coreVel: HIT),
                Role(pad: "rim", ghosts: [7, 15], ghostProb: 0.4, ghostVel: GH),
            ]
        case "lofi":
            return [
                Role(pad: "kick", core: [0, 8], coreVel: HIT, ghosts: [10], ghostProb: 0.35, ghostVel: SOFT),
                Role(pad: "snare", core: [4, 12], coreVel: SOFT),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: GH,
                     ghosts: [3, 7, 11, 15], ghostProb: 0.3, ghostVel: GH),
                Role(pad: "rim", ghosts: [6], ghostProb: 0.3, ghostVel: GH),
            ]
        case "pop":
            return [
                Role(pad: "kick", core: [0, 8], coreVel: ACC, ghosts: [10], ghostProb: 0.4, ghostVel: HIT),
                Role(pad: "snare", core: [4, 12], coreVel: ACC),
                Role(pad: "clap", core: [4, 12], coreVel: SOFT),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: HIT,
                     ghosts: [1, 3, 5, 7, 9, 11, 13, 15], ghostProb: 0.3, ghostVel: GH),
            ]
        case "rock":
            return [
                Role(pad: "kick", core: [0, 8], coreVel: ACC, ghosts: [6], ghostProb: 0.35, ghostVel: HIT),
                Role(pad: "snare", core: [4, 12], coreVel: ACC),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: HIT),
                Role(pad: "crash", core: [0], coreVel: HIT),
            ]
        default: // boombap
            return [
                Role(pad: "kick", core: [0, 8], coreVel: ACC, ghosts: [6, 10, 11], ghostProb: 0.4, ghostVel: GH),
                Role(pad: "snare", core: [4, 12], coreVel: ACC),
                Role(pad: "hatClosed", core: [0, 2, 4, 6, 8, 10, 12, 14], coreVel: HIT,
                     ghosts: [1, 3, 5, 7, 9, 11, 13, 15], ghostProb: 0.25, ghostVel: GH),
                Role(pad: "rim", ghosts: [7, 15], ghostProb: 0.3, ghostVel: GH),
            ]
        }
    }

    /// Generate a full editable beat into `lanes`. `density` 0..1 scales the ornament hits.
    /// `applyTempo` also sets the style's suggested bpm + swing (all captured in one undo step).
    func generateBeat(style id: String, density: Double, applyTempo: Bool = true) {
        checkpoint("genBeat", coalesce: false)
        let n = max(1, barSteps)
        let densMul = 0.45 + density * 1.1   // 0 → 0.45×, 1 → 1.55×
        var out: [String: [Double]] = [:]
        for role in Self.styleRoles(id) {
            var lane = Kit.emptyLane()
            for s in role.core where s < n { lane[s] = role.coreVel }
            for s in role.ghosts where s < n {
                if Double.random(in: 0..<1) < min(0.97, role.ghostProb * densMul) {
                    lane[s] = max(0.25, min(1, role.ghostVel + Double.random(in: -0.06...0.06)))
                }
            }
            out[role.pad] = lane
        }
        lanes = out
        stepMeta = [:]
        if applyTempo, let st = Self.beatStyles.first(where: { $0.id == id }) {
            setBpm(st.bpm); swing = st.swing
        }
    }
}
