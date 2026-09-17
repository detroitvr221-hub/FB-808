//  Instruments.swift — oscillator waveforms and music-theory helpers
//  (scales, note names, midi→freq) used by the Synth mode + melody generator.

import SwiftUI
import FD808Engine

// The synth-patch swatch color (UI-only; the DSP `SynthPatch` lives in FD808Engine).
extension SynthPatch {
    var color: Color { Color(hex: colorHex) }
}

enum Music {
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    // Properly-glyphed enharmonic spellings for theory UI. A key is spelled with EITHER sharps OR flats,
    // never mixed — flat keys (F, B♭, E♭, A♭, D♭, G♭ and their relative minors) spell with flats.
    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames  = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    /// Key-aware note spelling for a pitch class 0…11. Use flats for flat keys, sharps otherwise.
    static func spelled(_ pc: Int, preferFlats: Bool) -> String { (preferFlats ? flatNames : sharpNames)[pitchClass(pc)] }
    /// Whether a key should be spelled with flats. `tonicPC` 0…11; `minor` selects the relative-minor convention.
    static func preferFlats(tonicPC: Int, minor: Bool) -> Bool {
        let majorPC = pitchClass(minor ? tonicPC + 3 : tonicPC)
        return [5, 10, 3, 8, 1, 6].contains(majorPC)   // F, B♭, E♭, A♭, D♭, G♭
    }

    /// Pitch class 0…11 for any (possibly negative) MIDI/interval value.
    static func pitchClass(_ midi: Int) -> Int { ((midi % 12) + 12) % 12 }
    /// Note name without octave (e.g. "C", "F#").
    static func noteName(_ midi: Int) -> String { noteNames[pitchClass(midi)] }
    /// Pan readout from a -1…1 value: "C" centre, else "L42"/"R30".
    static func panLabel(_ v: Double) -> String { v == 0 ? "C" : (v > 0 ? "R" : "L") + "\(Int(abs(v) * 100))" }

    struct Scale: Identifiable { let id: String; let name: String; let intervals: [Int] }
    static let scales: [Scale] = [
        Scale(id: "major", name: "Major", intervals: [0, 2, 4, 5, 7, 9, 11]),
        Scale(id: "minor", name: "Minor", intervals: [0, 2, 3, 5, 7, 8, 10]),
        Scale(id: "dorian", name: "Dorian", intervals: [0, 2, 3, 5, 7, 9, 10]),
        Scale(id: "mixolydian", name: "Mixolyd.", intervals: [0, 2, 4, 5, 7, 9, 10]),
        Scale(id: "lydian", name: "Lydian", intervals: [0, 2, 4, 6, 7, 9, 11]),
        Scale(id: "phrygian", name: "Phrygian", intervals: [0, 1, 3, 5, 7, 8, 10]),
        Scale(id: "pentatonic", name: "Pentatonic", intervals: [0, 2, 4, 7, 9]),
        Scale(id: "minorPent", name: "Minor Pent", intervals: [0, 3, 5, 7, 10]),
        Scale(id: "blues", name: "Blues", intervals: [0, 3, 5, 6, 7, 10]),
        Scale(id: "harmonicMinor", name: "Harm. Min", intervals: [0, 2, 3, 5, 7, 8, 11]),
    ]
    static func intervals(_ id: String) -> [Int] { scales.first { $0.id == id }?.intervals ?? [0, 2, 4, 5, 7, 9, 11] }

    /// Ascending in-scale note ladder from `root`: `octaves` full octaves of the scale plus the top octave note.
    static func scaleLadder(root: Int, scaleID: String, octaves: Int = 2) -> [Int] {
        let iv = intervals(scaleID)
        var out: [Int] = []
        for o in 0..<octaves { for x in iv { out.append(root + 12 * o + x) } }
        out.append(root + 12 * octaves)
        return out
    }
    /// First `count` ascending in-scale notes from `root` (no top cap) — for fixed-size pad maps.
    static func scaleLadder(root: Int, scaleID: String, count: Int) -> [Int] {
        let iv = intervals(scaleID)
        var out: [Int] = []
        var oct = 0
        while out.count < count { for x in iv where out.count < count { out.append(root + 12 * oct + x) }; oct += 1 }
        return out
    }
    static func name(_ midi: Int) -> String { noteName(midi) + "\(midi / 12 - 1)" }

    /// Shared "Theory" chord-preview patch — the Circle of Fifths and the Progression builder play the same voice.
    static var theoryChordVoice: SynthPatch {
        var p = SynthPatch()
        p.name = "Theory"; p.source = "synth"; p.wave = .triangle
        p.unison = false; p.sub = false; p.octave = 0; p.glide = 0
        p.cutoff = 5200; p.reso = 1; p.filterEnv = 0.22; p.drive = 0.05
        p.attack = 0.004; p.decay = 0.55; p.sustain = 0.26; p.release = 0.5; p.level = 0.5
        return p
    }
    /// Harmonic-function color (Tonic / Subdominant / Dominant) shared by the theory views.
    static func functionColor(_ f: String) -> Color {
        switch f { case "T": return Color(hex: "#4D8AF0"); case "S": return Color(hex: "#21D0B2"); default: return Color(hex: "#FF6A2B") }
    }
}

extension Array where Element: Equatable {
    /// The element after `current`, wrapping to the front — for "tap to cycle through options" controls.
    /// Returns `current` unchanged for an empty array; treats a missing `current` as index 0 (so the
    /// first tap lands on the second option, matching the previous inline idiom).
    func next(after current: Element) -> Element {
        guard !isEmpty else { return current }
        let i = firstIndex(of: current) ?? 0
        return self[(i + 1) % count]
    }
}
