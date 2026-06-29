//  ChordSuggest.swift — D7 chord-suggestion engine + the Theory "Progression" tab.
//  A bundled Markov "next-chord" probability table (major & minor), derived from
//  common pop-progression statistics (Hooktheory-style), plus a builder UI that
//  ranks the likely next chords sized by probability. Teaches harmony & speeds writing.

import SwiftUI
import FD808Engine

enum ChordSuggest {
    // Degrees: major = I ii iii IV V vi vii° ; minor = i ii° III iv v VI VII.
    // Each row = P(next degree | current degree), roughly normalized to 1.0.
    static let majorTable: [[Double]] = [
        /* I    */ [0.05, 0.12, 0.10, 0.24, 0.27, 0.18, 0.04],
        /* ii   */ [0.12, 0.04, 0.06, 0.18, 0.40, 0.14, 0.06],
        /* iii  */ [0.12, 0.16, 0.04, 0.24, 0.10, 0.30, 0.04],
        /* IV   */ [0.30, 0.12, 0.06, 0.04, 0.28, 0.16, 0.04],
        /* V    */ [0.45, 0.08, 0.05, 0.15, 0.05, 0.20, 0.02],
        /* vi   */ [0.16, 0.20, 0.12, 0.26, 0.18, 0.04, 0.04],
        /* vii° */ [0.55, 0.06, 0.12, 0.08, 0.05, 0.20, 0.04],
    ]
    static let minorTable: [[Double]] = [
        /* i   */ [0.05, 0.10, 0.14, 0.20, 0.16, 0.20, 0.15],
        /* ii° */ [0.18, 0.04, 0.10, 0.12, 0.40, 0.10, 0.06],
        /* III */ [0.16, 0.10, 0.04, 0.18, 0.10, 0.30, 0.12],
        /* iv  */ [0.28, 0.10, 0.10, 0.04, 0.26, 0.14, 0.08],
        /* v   */ [0.40, 0.06, 0.10, 0.14, 0.04, 0.20, 0.06],
        /* VI  */ [0.18, 0.14, 0.16, 0.20, 0.16, 0.04, 0.12],
        /* VII */ [0.30, 0.06, 0.24, 0.10, 0.08, 0.18, 0.04],
    ]
    // Likely opening chords when the progression is empty (tonic-heavy).
    static let majorStart: [Double] = [0.45, 0.06, 0.05, 0.16, 0.12, 0.14, 0.02]
    static let minorStart: [Double] = [0.45, 0.05, 0.10, 0.12, 0.08, 0.15, 0.05]

    static let majorRomans = ["I", "ii", "iii", "IV", "V", "vi", "vii°"]
    static let minorRomans = ["i", "ii°", "III", "iv", "v", "VI", "VII"]
    // Harmonic function per degree (Tonic / Subdominant / Dominant) for color-coding.
    static let majorFns = ["T", "S", "T", "S", "D", "T", "D"]
    static let minorFns = ["T", "S", "T", "S", "D", "S", "D"]

    static func roman(_ deg: Int, minor: Bool) -> String { (minor ? minorRomans : majorRomans)[deg] }
    static func fn(_ deg: Int, minor: Bool) -> String { (minor ? minorFns : majorFns)[deg] }

    /// Next-degree suggestions given the last degree (nil = opening), ranked by probability.
    static func suggestions(after last: Int?, minor: Bool) -> [(degree: Int, p: Double)] {
        let row = last.map { (minor ? minorTable : majorTable)[$0] } ?? (minor ? minorStart : majorStart)
        return row.enumerated().map { (degree: $0.offset, p: $0.element) }.sorted { $0.p > $1.p }
    }

    /// Sample one next degree from the distribution using a 0..<1 random value (deterministic given r).
    static func sample(after last: Int?, minor: Bool, r: Double) -> Int {
        let row = last.map { (minor ? minorTable : majorTable)[$0] } ?? (minor ? minorStart : majorStart)
        var acc = 0.0
        for (i, p) in row.enumerated() { acc += p; if r < acc { return i } }
        return row.count - 1
    }

    // The triad's MIDI notes for a degree in a given key (root pitch class + scale).
    static func chordMidis(_ deg: Int, rootPC: Int, scaleID: String, base: Int = 60) -> [Int] {
        let iv = Music.intervals(scaleID); let n = iv.count
        func tone(_ d: Int) -> Int { base + rootPC + iv[d % n] + 12 * (d / n) }
        // keep voicings in a comfortable register
        var m = [tone(deg), tone(deg + 2), tone(deg + 4)]
        if (m.first ?? 60) > 71 { m = m.map { $0 - 12 } }
        return m
    }
    static func chordName(_ deg: Int, rootPC: Int, scaleID: String, minor: Bool) -> String {
        let iv = Music.intervals(scaleID)
        let suffix = minor ? ["m", "°", "", "m", "m", "", ""] : ["", "m", "m", "", "", "m", "°"]
        let flats = Music.preferFlats(tonicPC: rootPC, minor: minor)
        return Music.spelled((rootPC + iv[deg % iv.count]) % 12, preferFlats: flats) + suffix[deg % suffix.count]
    }
}

// MARK: - Progression builder (Theory tab)

struct ChordSuggestView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    var openTab: (String) -> Void = { _ in }

    @State private var prog: [Int] = []     // chosen scale degrees
    @State private var seed = 0             // varies the auto-generate
    @State private var added = false        // "Use in Song" confirmation

    private var minor: Bool { project.melodyScale == "minor" }
    private var rootPC: Int { project.melodyKey }
    private var scaleID: String { project.melodyScale }
    private var keyName: String { Music.spelled(rootPC % 12, preferFlats: Music.preferFlats(tonicPC: rootPC, minor: minor)) + (minor ? " Minor" : " Major") }

    private var voice: SynthPatch { Music.theoryChordVoice }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                progressionBar
                suggestions
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            sidePanel.frame(width: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: progression

    private var progressionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("YOUR PROGRESSION").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
                Spacer()
                Text("in \(keyName)").font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkDim)
            }
            if prog.isEmpty {
                Text("Pick a chord below to start — or tap Generate. Suggestions update after each chord.")
                    .font(FDFont.ui(13)).foregroundStyle(settings.inkDim)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    .padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.line, lineWidth: 1))
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(prog.enumerated()), id: \.offset) { (i, d) in progChip(i, d) }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.line, lineWidth: 1))
            }
        }
    }

    private func progChip(_ i: Int, _ d: Int) -> some View {
        let col = fnColor(ChordSuggest.fn(d, minor: minor))
        return Button { playChord(d) } label: {
            VStack(spacing: 2) {
                Text(ChordSuggest.roman(d, minor: minor)).font(FDFont.mono(10, .bold)).foregroundStyle(col)
                Text(ChordSuggest.chordName(d, rootPC: rootPC, scaleID: scaleID, minor: minor)).font(FDFont.display(20, .bold)).foregroundStyle(settings.ink)
            }
            .frame(width: 64, height: 52)
            .background(RoundedRectangle(cornerRadius: 11).fill(col.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(col.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: suggestions (sized by probability)

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prog.isEmpty ? "LIKELY OPENINGS" : "LIKELY NEXT").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
            ForEach(Array(ChordSuggest.suggestions(after: prog.last, minor: minor).enumerated()), id: \.offset) { (_, s) in
                suggestionRow(s.degree, s.p)
            }
        }
    }

    private func suggestionRow(_ deg: Int, _ p: Double) -> some View {
        let col = fnColor(ChordSuggest.fn(deg, minor: minor))
        let name = ChordSuggest.chordName(deg, rootPC: rootPC, scaleID: scaleID, minor: minor)
        return Button { add(deg) } label: {
            HStack(spacing: 12) {
                Text(ChordSuggest.roman(deg, minor: minor)).font(FDFont.mono(11, .bold)).foregroundStyle(col).frame(width: 38, alignment: .leading)
                Text(name).font(FDFont.display(17, .bold)).foregroundStyle(settings.ink).frame(width: 56, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(settings.panel2)
                        Capsule().fill(col.opacity(0.8)).frame(width: max(4, g.size.width * p / 0.55))   // 0.55 ≈ max prob → full bar
                    }
                }.frame(height: 12)
                Text("\(Int(p * 100))%").font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkDim).frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 11).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: side panel

    private var sidePanel: some View {
        VStack(spacing: 10) {
            actionBtn("▶ Play Progression", filled: true) { playProgression() }
            Button { addToSong() } label: {
                HStack(spacing: 7) {
                    Image(systemName: added ? "checkmark.circle.fill" : "arrow.right.circle.fill").font(.system(size: 14))
                    Text(added ? "Added to Song" : "→ Use in Song").font(FDFont.ui(13.5, .semibold))
                }
                .foregroundStyle(prog.isEmpty ? settings.inkFaint : .white)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(prog.isEmpty ? AnyShapeStyle(settings.panel2) : AnyShapeStyle(settings.theme.good)))
            }.buttonStyle(.plain).disabled(prog.isEmpty)
            actionBtn("🎲 Generate 4 Chords", filled: false) { generate() }
            HStack(spacing: 8) {
                actionBtn("Undo", filled: false) { if !prog.isEmpty { prog.removeLast(); added = false } }
                actionBtn("Clear", filled: false) { prog.removeAll(); added = false }
            }
            functionLegend.padding(.top, 4)
            CoachNote("Chords that come next aren't random — the **bar length is how often that chord follows** in real songs. **V** and **IV** pull home to **I**; **vi** adds the bittersweet turn.")
            Spacer(minLength: 0)
        }
    }

    private var functionLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach([("T", "Tonic — home"), ("S", "Subdominant — away"), ("D", "Dominant — tension")], id: \.0) { (f, label) in
                HStack(spacing: 6) {
                    Circle().fill(fnColor(f)).frame(width: 9, height: 9)
                    Text(label).font(FDFont.ui(11)).foregroundStyle(settings.inkDim)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionBtn(_ s: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.ui(13.5, .semibold)).foregroundStyle(filled ? .white : settings.ink)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(filled ? AnyShapeStyle(settings.accent.ctaGradient()) : AnyShapeStyle(settings.panel2)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(filled ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func fnColor(_ f: String) -> Color { Music.functionColor(f) }

    // MARK: actions

    private func add(_ deg: Int) { prog.append(deg); added = false; playChord(deg) }

    /// Commit the progression as the song's synth/chord part, then jump to the sequencer.
    private func addToSong() {
        guard !prog.isEmpty else { return }
        let steps = 16
        let per = max(1, steps / prog.count)
        var notes: [MelodyNote] = []
        for (i, deg) in prog.enumerated() {
            let start = i * per
            if start >= steps { break }
            let dur = min(per, steps - start)
            for m in ChordSuggest.chordMidis(deg, rootPC: rootPC, scaleID: scaleID) {
                notes.append(MelodyNote(step: start, pitch: m, dur: dur, vel: 0.55))
            }
        }
        project.checkpoint("progToSong", coalesce: false)
        project.melody = notes
        project.melodyMuted = false        // make the chord part audible…
        project.trackMute["vox"] = false   // …and not gated by a muted Melody track (Song Mode)
        added = true
        openTab("sequence")
    }

    private func playChord(_ deg: Int) {
        engine.start()
        let when = engine.now() + 0.02
        for m in ChordSuggest.chordMidis(deg, rootPC: rootPC, scaleID: scaleID) {
            engine.triggerSynth(voice, midi: m, dur: 1.0, vel: 0.42, when: when)
        }
    }

    private func playProgression() {
        engine.start()
        let now = engine.now()
        for (i, d) in prog.enumerated() {
            let when = now + Double(i) * 0.62
            for m in ChordSuggest.chordMidis(d, rootPC: rootPC, scaleID: scaleID) {
                engine.triggerSynth(voice, midi: m, dur: 0.58, vel: 0.4, when: when)
            }
        }
    }

    private func generate() {
        seed += 1
        var out: [Int] = []
        var last: Int? = nil
        // deterministic-but-varying pseudo-random walk (no Date/rand dependency at build sites)
        var x = UInt64(seed) &* 0x9E3779B97F4A7C15 &+ 0x123456789
        for _ in 0..<4 {
            x ^= x >> 12; x ^= x << 25; x ^= x >> 27
            let r = Double(x % 10_000) / 10_000.0
            let d = ChordSuggest.sample(after: last, minor: minor, r: r)
            out.append(d); last = d
        }
        prog = out
        playProgression()
    }
}
