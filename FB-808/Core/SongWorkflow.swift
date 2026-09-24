import SwiftUI

extension Project {
    func sequenceHasContent(_ index: Int) -> Bool {
        lanesOfSeq(index).values.contains { $0.contains { $0 != 0 } }
            || !melodyOfSeq(index).isEmpty || partsOfSeq(index).contains { !$0.notes.isEmpty }
    }

    /// One-tap full song: Intro→Verse→Hook→Verse→Outro with track dynamics (Song Mode).
    /// Each section only plays the tracks listed, so the arrangement actually breathes.
    func buildSong() {
        checkpoint("buildsong", coalesce: false)
        // The hook lifts to pattern B only when the user actually wrote one. B ships seeded with a stock
        // house pattern, and `generateBeat` only ever fills the ACTIVE buffer, so the old unconditional
        // `min(1, …)` dropped a four-on-the-floor house bar into the middle of (say) a trap beat the user
        // had never heard (SEQUENCE_TRACKS_AUDIT finding 4). Untouched B → keep the user's own pattern.
        let baseSeq = activeSeq
        let hookSeq = sequences.indices.first { $0 != baseSeq && isUserAuthored(seq: $0) && sequenceHasContent($0) } ?? baseSeq
        songBars = max(16, songBars)
        if songAuto.count < songBars { songAuto += Array(repeating: songAuto.last ?? 1, count: songBars - songAuto.count) }
        let structure: [(sec: String, len: Int, seq: Int, tracks: [String])] = [
            ("intro", 2, baseSeq,       ["drums", "hats"]),
            ("verse", 4, baseSeq,       ["drums", "hats", "bass", "vox"]),
            ("hook",  4, hookSeq, ["drums", "hats", "bass", "perc", "vox"]),
            ("verse", 4, baseSeq,       ["drums", "hats", "bass", "vox"]),
            ("outro", 2, baseSeq,       ["drums"]),
        ]
        var arr: [ArrItem] = []
        var clipMap: [String: [Clip]] = [:]
        var start = 0
        for (i, s) in structure.enumerated() {
            let seq = max(0, min(s.seq, sequences.count - 1))
            arr.append(ArrItem(id: "sng\(i)", section: s.sec, start: start, len: s.len, seq: seq))
            for t in s.tracks { clipMap[t, default: []].append(Clip(s: start, l: s.len, color: tracks.first { $0.id == t }?.color ?? Kit.channelColor(t))) }
            start += s.len
        }
        arrangement = arr
        // Only the 5 legacy lanes are (re)built by the auto-arranger; preserve clips authored on any
        // user-added tracks instead of wiping the whole clip map (which contradicted the 99-track feature).
        let legacy: Set<String> = ["drums", "hats", "bass", "perc", "vox"]
        var merged = clips.filter { !legacy.contains($0.key) }
        for (k, v) in clipMap { merged[k] = v }
        clips = merged
        songMode = true
    }

}
