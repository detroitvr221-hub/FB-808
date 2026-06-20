//  Instruments.swift — oscillator waveforms and music-theory helpers
//  (scales, note names, midi→freq) used by the Synth mode + melody generator.

import SwiftUI
import FD808Engine

// The synth-patch swatch color (UI-only; the DSP `SynthPatch` lives in FD808Engine).
extension SynthPatch {
    var color: Color { Color(hex: colorHex) }
}

enum Music {
    static func midiToFreq(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12.0) }
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

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
    static func name(_ midi: Int) -> String { noteNames[((midi % 12) + 12) % 12] + "\(midi / 12 - 1)" }
}
