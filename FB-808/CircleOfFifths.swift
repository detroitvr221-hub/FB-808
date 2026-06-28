//  CircleOfFifths.swift — an interactive Circle of Fifths theory screen.
//  Tap a key to hear its scale and diatonic chords, see its key signature, and
//  send it to the project as the song key. A teaching tool that plays through
//  the real engine, so what you learn here is the same key the rest of the app
//  is locked to.

import SwiftUI
import FD808Engine

// One position on the wheel: a major key, its relative minor, and its signature.
private struct CofKey: Identifiable {
    let id: Int
    let major: String      // display (may carry ♯/♭)
    let majorPC: Int       // pitch class 0..11 of the major root
    let minor: String      // "Am", "F♯m" …
    var minorPC: Int { (majorPC + 9) % 12 }   // relative minor is a minor-3rd down
    let sharps: Int        // +n sharps, −n flats, 0 = natural
}

// Clockwise from the top (12 o'clock = C), moving by perfect fifths.
private let COF: [CofKey] = [
    CofKey(id: 0,  major: "C",  majorPC: 0,  minor: "Am",  sharps: 0),
    CofKey(id: 1,  major: "G",  majorPC: 7,  minor: "Em",  sharps: 1),
    CofKey(id: 2,  major: "D",  majorPC: 2,  minor: "Bm",  sharps: 2),
    CofKey(id: 3,  major: "A",  majorPC: 9,  minor: "F♯m", sharps: 3),
    CofKey(id: 4,  major: "E",  majorPC: 4,  minor: "C♯m", sharps: 4),
    CofKey(id: 5,  major: "B",  majorPC: 11, minor: "G♯m", sharps: 5),
    CofKey(id: 6,  major: "G♭", majorPC: 6,  minor: "E♭m", sharps: -6),
    CofKey(id: 7,  major: "D♭", majorPC: 1,  minor: "B♭m", sharps: -5),
    CofKey(id: 8,  major: "A♭", majorPC: 8,  minor: "Fm",  sharps: -4),
    CofKey(id: 9,  major: "E♭", majorPC: 3,  minor: "Cm",  sharps: -3),
    CofKey(id: 10, major: "B♭", majorPC: 10, minor: "Gm",  sharps: -2),
    CofKey(id: 11, major: "F",  majorPC: 5,  minor: "Dm",  sharps: -1),
]

private struct DiatonicChord: Identifiable {
    let id: Int
    let roman: String
    let name: String
    let fn: String        // harmonic function: T (tonic) | S (subdominant) | D (dominant)
    let midis: [Int]
}

struct CircleOfFifthsView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings

    @State private var sel = 0           // index into COF
    @State private var minorMode = false // false = major key, true = relative minor

    // A clean, neutral voice so the theory sounds the same regardless of the
    // user's current synth patch.
    private var voice: SynthPatch {
        var p = SynthPatch()
        p.name = "Theory"; p.source = "synth"; p.wave = .triangle
        p.unison = false; p.sub = false; p.octave = 0; p.glide = 0
        p.cutoff = 5200; p.reso = 1; p.filterEnv = 0.22; p.drive = 0.05
        p.attack = 0.004; p.decay = 0.55; p.sustain = 0.26; p.release = 0.5; p.level = 0.5
        return p
    }

    private var k: CofKey { COF[sel] }
    private var scaleID: String { minorMode ? "minor" : "major" }
    private var rootPC: Int { minorMode ? k.minorPC : k.majorPC }
    private var rootName: String { minorMode ? String(k.minor.dropLast()) : k.major }
    private var keyTitle: String { rootName + (minorMode ? " Minor" : " Major") }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            wheel
            detail.frame(width: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: wheel

    private var wheel: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let rMaj = side * 0.40
            let rMin = side * 0.255
            ZStack {
                Circle().stroke(settings.line, lineWidth: 1)
                    .frame(width: side * 0.86, height: side * 0.86).position(c)
                Circle().stroke(settings.line2, lineWidth: 1)
                    .frame(width: side * 0.52, height: side * 0.52).position(c)
                ForEach(COF) { key in
                    let majSel = sel == key.id && !minorMode
                    let minSel = sel == key.id && minorMode
                    chip(text: key.major, selected: majSel,
                         major: true, d: side * 0.155)
                        .position(pos(key.id, center: c, r: rMaj))
                        .onTapGesture { choose(key.id, minor: false) }
                        // VoiceOver: the tap gesture never fires under VoiceOver, so expose the chip as a button.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(key.major) major"))
                        .accessibilityAddTraits(majSel ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { choose(key.id, minor: false) }
                    chip(text: key.minor, selected: minSel,
                         major: false, d: side * 0.118)
                        .position(pos(key.id, center: c, r: rMin))
                        .onTapGesture { choose(key.id, minor: true) }
                        // VoiceOver: the tap gesture never fires under VoiceOver, so expose the chip as a button.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(key.minor) minor"))
                        .accessibilityAddTraits(minSel ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { choose(key.id, minor: true) }
                }
                center(side: side).position(c)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pos(_ i: Int, center c: CGPoint, r: CGFloat) -> CGPoint {
        let theta = (-90.0 + Double(i) * 30.0) * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(cos(theta)), y: c.y + r * CGFloat(sin(theta)))
    }

    private func chip(text: String, selected: Bool, major: Bool, d: CGFloat) -> some View {
        Text(text)
            .font(FDFont.display(d * (major ? 0.34 : 0.30), .bold))
            .foregroundStyle(selected ? .white : (major ? settings.ink : settings.inkDim))
            .frame(width: d, height: d)
            .background(Circle().fill(selected ? settings.accent
                                               : (major ? settings.panel2 : settings.panel2.darker(0.12))))
            .overlay(Circle().stroke(selected ? Color.clear : settings.line, lineWidth: 1))
            .shadow(color: selected ? settings.accent.opacity(0.5) : .clear, radius: 6)
            .contentShape(Circle())
    }

    private func center(side: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(rootName).font(FDFont.display(side * 0.085, .bold)).foregroundStyle(settings.accent)
            Text(minorMode ? "minor" : "major").font(FDFont.mono(side * 0.026, .bold))
                .tracking(1).foregroundStyle(settings.inkFaint)
            Text(signatureShort).font(FDFont.mono(side * 0.03, .bold)).foregroundStyle(settings.inkDim)
                .padding(.top, 2)
        }
        .frame(width: side * 0.30, height: side * 0.30)
        .background(Circle().fill(settings.panel))
        .overlay(Circle().stroke(settings.line, lineWidth: 1))
    }

    // MARK: detail panel

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            // title + major/minor toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(keyTitle).font(FDFont.display(22, .bold)).foregroundStyle(settings.ink)
                    Text(minorMode ? "relative major: \(k.major)" : "relative minor: \(k.minor)")
                        .font(FDFont.ui(12)).foregroundStyle(settings.inkFaint)
                }
                Spacer()
                HStack(spacing: 6) {
                    modeChip("MAJOR", on: !minorMode) { choose(sel, minor: false) }
                    modeChip("MINOR", on: minorMode) { choose(sel, minor: true) }
                }
            }

            PanelCard(title: "Key Signature", trailing: signatureShort) {
                if k.sharps == 0 {
                    Text("No sharps or flats — all natural notes.")
                        .font(FDFont.ui(12.5)).foregroundStyle(settings.inkDim)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Array(accidentalNotes.enumerated()), id: \.offset) { (_, s) in
                            Text(s).font(FDFont.mono(13, .bold)).foregroundStyle(settings.ink)
                                .frame(width: 38, height: 30)
                                .fdCard(8, fill: settings.panel2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            PanelCard(title: "Diatonic Chords", trailing: "tap to play") {
                let cols = [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7),
                            GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)]
                LazyVGrid(columns: cols, spacing: 7) {
                    ForEach(chords) { ch in chordChip(ch) }
                }
                functionLegend.padding(.top, 2)
            }

            HStack(spacing: 8) {
                actionButton("▶ Scale", filled: true) { playScale() }
                actionButton(minorMode ? "▶ i–VI–III–VII" : "▶ I–V–vi–IV", filled: false) { playProgression() }
            }
            Button { useAsSongKey() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "key.fill").font(.system(size: 12))
                    Text("Use as Song Key").font(FDFont.ui(13, .semibold))
                }
                .foregroundStyle(isSongKey ? .white : settings.ink)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(isSongKey ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(isSongKey ? Color.clear : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)

            CoachNote("The **circle of fifths** orders keys by how closely they're related. Keys that sit next to each other share almost all their notes, so their chords blend smoothly — a quick map for picking chords that belong together.")
            Spacer(minLength: 0)
        }
    }

    private func modeChip(_ s: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(10, .bold)).tracking(0.8)
                .foregroundStyle(on ? .white : settings.inkDim)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func chordChip(_ ch: DiatonicChord) -> some View {
        let col = fnColor(ch.fn)
        return Button { playChord(ch.midis) } label: {
            VStack(spacing: 3) {
                Text(ch.roman).font(FDFont.mono(10, .bold)).foregroundStyle(col)
                Text(ch.name).font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(col.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(col.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var functionLegend: some View {
        HStack(spacing: 10) {
            ForEach([("T", "Tonic — home"), ("S", "Subdominant — away"), ("D", "Dominant — tension")], id: \.0) { (f, label) in
                HStack(spacing: 5) {
                    Circle().fill(fnColor(f)).frame(width: 9, height: 9)
                    Text(label).font(FDFont.ui(10.5)).foregroundStyle(settings.inkDim)
                }
            }
        }
    }

    private func actionButton(_ s: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.ui(13.5, .semibold)).foregroundStyle(filled ? .white : settings.ink)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 11)
                    .fill(filled ? AnyShapeStyle(LinearGradient(colors: [settings.accent, settings.accent.darker(0.24)], startPoint: .top, endPoint: .bottom))
                                 : AnyShapeStyle(settings.panel2)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(filled ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: theory

    /// Roots stay in a comfortable middle-register window.
    private var rootMidi: Int {
        var m = 60 + rootPC
        if m > 66 { m -= 12 }
        return m
    }

    private var chords: [DiatonicChord] {
        let iv = Music.intervals(scaleID)
        let n = iv.count
        let romans = minorMode ? ["i", "ii°", "III", "iv", "v", "VI", "VII"]
                               : ["I", "ii", "iii", "IV", "V", "vi", "vii°"]
        let suffix = minorMode ? ["m", "°", "", "m", "m", "", ""]
                               : ["", "m", "m", "", "", "m", "°"]
        // harmonic function per scale degree (where the chord "pulls")
        let fns = minorMode ? ["T", "S", "T", "S", "D", "S", "D"]
                            : ["T", "S", "T", "S", "D", "T", "D"]
        func tone(_ idx: Int) -> Int { iv[idx % n] + 12 * (idx / n) }
        return (0..<n).map { d in
            let offs = [tone(d), tone(d + 2), tone(d + 4)]
            let name = Music.spelled((rootPC + iv[d]) % 12, preferFlats: k.sharps < 0) + suffix[d]
            return DiatonicChord(id: d, roman: romans[d], name: name, fn: fns[d], midis: offs.map { rootMidi + $0 })
        }
    }
    private func fnColor(_ f: String) -> Color {
        switch f { case "T": return Color(hex: "#4D8AF0"); case "S": return Color(hex: "#21D0B2"); default: return Color(hex: "#FF6A2B") }
    }

    private var signatureShort: String {
        if k.sharps == 0 { return "♮" }
        return "\(abs(k.sharps))\(k.sharps > 0 ? "♯" : "♭")"
    }

    private var accidentalNotes: [String] {
        let sharpOrder = ["F", "C", "G", "D", "A", "E", "B"]
        let flatOrder  = ["B", "E", "A", "D", "G", "C", "F"]
        let n = abs(k.sharps)
        guard n > 0 else { return [] }
        let glyph = k.sharps > 0 ? "♯" : "♭"
        let order = k.sharps > 0 ? sharpOrder : flatOrder
        return order.prefix(n).map { $0 + glyph }
    }

    private var isSongKey: Bool { project.melodyKey == rootPC && project.melodyScale == scaleID }

    // MARK: actions

    private func choose(_ i: Int, minor: Bool) {
        sel = i; minorMode = minor
        playChord(chords[0].midis)   // tonic chord = instant feedback
    }

    private func playChord(_ midis: [Int]) {
        engine.start()
        let when = engine.now() + 0.02
        for m in midis { engine.triggerSynth(voice, midi: m, dur: 1.1, vel: 0.42, when: when) }
    }

    private func playScale() {
        engine.start()
        let now = engine.now()
        let iv = Music.intervals(scaleID)
        var midis = iv.map { rootMidi + $0 }
        midis.append(rootMidi + 12)
        for (i, m) in midis.enumerated() {
            engine.triggerSynth(voice, midi: m, dur: 0.32, vel: 0.5, when: now + Double(i) * 0.16)
        }
    }

    private func playProgression() {
        engine.start()
        let now = engine.now()
        let c = chords
        let order = minorMode ? [0, 5, 2, 6] : [0, 4, 5, 3]   // i–VI–III–VII / I–V–vi–IV
        for (i, d) in order.enumerated() {
            let when = now + Double(i) * 0.6
            for m in c[d].midis { engine.triggerSynth(voice, midi: m, dur: 0.56, vel: 0.4, when: when) }
        }
    }

    private func useAsSongKey() {
        project.checkpoint("key", coalesce: false)
        project.melodyKey = rootPC
        project.melodyScale = scaleID
        // Only auto-generate a starting melody when there's none — don't silently overwrite the user's
        // existing melody (the button promises a key change, not a rewrite). Undoable either way.
        if project.melody.isEmpty { project.generateMelody(checkpoint: false) }
    }
}
