//  Groove.swift — named timing "feels" (E4). Each groove is a set of per-16th-step micro-timing
//  offsets (as a fraction of one 16th step) applied in the scheduler on top of the grid, so a beat
//  can swing / lay back / push like an MPC or boom-bap kit without re-entering it. "Straight" defers
//  to the manual Swing slider, so existing projects are unchanged.

import Foundation

struct Groove: Identifiable {
    let id: String
    let name: String
    let push: [Double]      // 16 offsets, fraction of a 16th step (+ = later/behind, − = earlier/ahead)

    static func byID(_ id: String) -> Groove { all.first { $0.id == id } ?? all[0] }

    static let all: [Groove] = [
        Groove(id: "straight", name: "Straight",   push: Array(repeating: 0, count: 16)),
        Groove(id: "light",    name: "Light Swing", push: offbeat(0.18)),
        Groove(id: "mpc",      name: "MPC Swing",   push: offbeat(0.33)),
        Groove(id: "hard",     name: "Hard Swing",  push: offbeat(0.5)),
        Groove(id: "boombap",  name: "Boom Bap",    push: boomBap()),
        Groove(id: "laidback", name: "Laid Back",   push: Array(repeating: 0.06, count: 16)),
        Groove(id: "push",     name: "Push",        push: Array(repeating: -0.05, count: 16)),
    ]

    /// Delay the off-beat 16ths (odd steps) by `amt` of a step — the classic swing shape.
    private static func offbeat(_ amt: Double) -> [Double] { (0..<16).map { $0 % 2 == 1 ? amt : 0 } }

    /// Boom-bap: swung off-beats + the backbeat snares (steps 4 & 12) dragged slightly behind.
    private static func boomBap() -> [Double] {
        var p = offbeat(0.3); p[4] += 0.05; p[12] += 0.05; return p
    }
}
