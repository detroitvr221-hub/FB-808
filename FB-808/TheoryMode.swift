//  TheoryMode.swift — the Theory tab: hosts the Circle of Fifths (harmony) and
//  the Groove Wheel (a circular, Groove-Pizza-style rhythm view) so beat-making
//  theory is visible and playable. Part of the teaching layer (B5 + B7).

import SwiftUI
import FD808Engine

struct TheoryModeView: View {
    @EnvironmentObject var settings: AppSettings
    var openTab: (String) -> Void = { _ in }
    @State private var mode = "fifths"   // "fifths" | "rhythm"

    var body: some View {
        VStack(spacing: 12) {
            TransportBar()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Theory").font(FDFont.display(26, .bold)).foregroundStyle(settings.ink)
                    HStack(spacing: 8) {
                        seg("Circle of Fifths", "fifths")
                        seg("Progression", "prog")
                        seg("Groove Wheel", "rhythm")
                        seg("Ear Training", "ear")
                    }
                    Spacer()
                    Text(mode == "fifths" ? "Tap a key to hear its scale & chords"
                         : mode == "prog" ? "Build a progression — bars show how likely each next chord is"
                         : mode == "rhythm" ? "Tap dots to build a beat — the shape IS the rhythm"
                         : "Name the interval you hear")
                        .font(FDFont.ui(12.5)).foregroundStyle(settings.inkFaint).lineLimit(1)
                }
                Group {
                    switch mode {
                    case "prog": ChordSuggestView(openTab: openTab)
                    case "rhythm": CircularRhythmView()
                    case "ear": EarTrainingView()
                    default: CircleOfFifthsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func seg(_ label: String, _ id: String) -> some View {
        let selected = mode == id
        return Button { mode = id } label: {
            Text(label).font(FDFont.ui(13.5, .semibold))
                .foregroundStyle(selected ? settings.ink : settings.inkDim)
                .padding(.horizontal, 14).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? settings.accent.opacity(0.18) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Groove Wheel (circular rhythm — Groove Pizza style, B7)

struct CircularRhythmView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings

    private let ringPads = ["kick", "snare", "clap", "hatClosed", "hatOpen", "perc"]
    private var stepCount: Int { max(1, project.barSteps) }   // honour the time signature (A13)

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            wheel
            detail.frame(width: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: wheel

    private var wheel: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let rOut = size * 0.46
            let rIn = size * 0.12
            let n = ringPads.count
            let gap = (rOut - rIn) / CGFloat(n)
            ZStack {
                // shape polygons (the "rhythm necklace") per ring
                Canvas { ctx, _ in
                    for (r, padID) in ringPads.enumerated() {
                        let radius = rOut - (CGFloat(r) + 0.5) * gap
                        let lane = project.lanes[padID] ?? []
                        let color = Kit.padByID[padID]?.color ?? settings.accent
                        var hits: [CGPoint] = []
                        for i in 0..<stepCount where i < lane.count && lane[i] > 0 { hits.append(pt(c, radius, i)) }
                        guard hits.count >= 2 else { continue }
                        var path = Path()
                        path.move(to: hits[0])
                        for p in hits.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                        ctx.stroke(path, with: .color(color.opacity(0.45)), lineWidth: 2)
                    }
                }
                // step dots (interactive)
                ForEach(Array(ringPads.enumerated()), id: \.offset) { (r, padID) in
                    let radius = rOut - (CGFloat(r) + 0.5) * gap
                    let lane = project.lanes[padID] ?? []
                    let color = Kit.padByID[padID]?.color ?? settings.accent
                    ForEach(Array(0..<stepCount), id: \.self) { i in
                        let on = i < lane.count && lane[i] > 0
                        let ph = project.playing && project.step == i
                        let beat = i % 4 == 0
                        let padLabel = Kit.padByID[padID]?.label ?? padID
                        Circle()
                            .fill(on ? color : settings.panel2)
                            .frame(width: on ? 15 : (beat ? 9 : 6), height: on ? 15 : (beat ? 9 : 6))
                            .overlay(Circle().stroke(ph ? settings.ink : (on ? .clear : settings.line), lineWidth: ph ? 2 : 1))
                            .shadow(color: on ? color.opacity(0.6) : .clear, radius: 4)
                            .position(pt(c, radius, i))
                            .accessibilityElement()
                            .accessibilityLabel("\(padLabel) step \(i + 1)")
                            .accessibilityValue(on ? "On" : "Off")
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction {
                                engine.start()
                                project.toggleStep(padID, i)
                                if (project.lanes[padID]?[safe: i] ?? 0) > 0 { project.triggerPad(padID) }
                            }
                    }
                }
                // rotating playhead
                if project.playing && project.step >= 0 {
                    let a = ang(project.step)
                    Path { p in p.move(to: c); p.addLine(to: CGPoint(x: c.x + rOut * cos(a), y: c.y + rOut * sin(a))) }
                        .stroke(settings.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in toggle(at: v.location, c: c, rOut: rOut, gap: gap, n: n) })
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ang(_ i: Int) -> CGFloat { (-90 + CGFloat(i) * (360 / CGFloat(stepCount))) * .pi / 180 }
    private func pt(_ c: CGPoint, _ r: CGFloat, _ i: Int) -> CGPoint {
        let a = ang(i); return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }
    private func toggle(at loc: CGPoint, c: CGPoint, rOut: CGFloat, gap: CGFloat, n: Int) {
        let dx = loc.x - c.x, dy = loc.y - c.y
        let r = Int((((rOut - hypot(dx, dy)) / gap) - 0.5).rounded())
        guard r >= 0 && r < n else { return }
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let step = Int((deg / (360 / Double(stepCount))).rounded()) % stepCount
        let padID = ringPads[r]
        engine.start()
        project.toggleStep(padID, step)
        if (project.lanes[padID]?[safe: step] ?? 0) > 0 { project.triggerPad(padID) }
    }

    // MARK: detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelCard(title: "Rings (outer → inner)") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ringPads, id: \.self) { padID in
                        if let pad = Kit.padByID[padID] {
                            HStack(spacing: 9) {
                                Circle().fill(pad.color).frame(width: 12, height: 12)
                                Text(pad.label).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                                Spacer()
                                Text("\((project.lanes[padID] ?? []).filter { $0 > 0 }.count)")
                                    .font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkFaint)
                            }
                        }
                    }
                }
            }
            CoachNote("Each **ring** is one drum; each **dot** is a 16th-note. Evenly-spaced shapes (triangles, squares) make grooves that feel good — that's why a four-on-the-floor kick draws a perfect square.")
            Button {
                engine.start()
                if !project.playing { transportToggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: project.playing ? "pause.fill" : "play.fill").font(.system(size: 13))
                    Text(project.playing ? "Playing" : "Play the wheel").font(FDFont.ui(13.5, .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 11).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.24)], startPoint: .top, endPoint: .bottom)))
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    @EnvironmentObject var transport: Transport
    private func transportToggle() { transport.toggle() }
}

// MARK: - Ear training: interval recognition (B6)

struct EarTrainingView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @State private var root = 60
    @State private var interval = 7
    @State private var answered: Int?
    @State private var score = 0
    @State private var total = 0
    @State private var started = false

    private let options: [(semi: Int, name: String)] = [
        (2, "Major 2nd"), (3, "Minor 3rd"), (4, "Major 3rd"),
        (5, "Perfect 4th"), (7, "Perfect 5th"), (9, "Major 6th"), (12, "Octave"),
    ]
    private var voice: SynthPatch {
        var p = SynthPatch(); p.name = "Ear"; p.wave = .triangle; p.unison = false; p.sub = false
        p.cutoff = 5000; p.reso = 1; p.filterEnv = 0.2; p.drive = 0.05
        p.attack = 0.005; p.decay = 0.5; p.sustain = 0.3; p.release = 0.4; p.level = 0.5
        return p
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                if !started {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Train your ear").font(FDFont.display(28, .bold)).foregroundStyle(settings.ink)
                        Text("You'll hear two notes. Pick the interval between them. The more you play, the faster you'll recognise melodies and basslines by ear.")
                            .font(FDFont.ui(14)).foregroundStyle(settings.inkDim).fixedSize(horizontal: false, vertical: true)
                        Button { started = true; newRound() } label: {
                            Text("Start").font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 28).frame(height: 46)
                                .background(RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: 440, alignment: .leading)
                } else {
                    HStack(spacing: 14) {
                        Text("\(score)/\(total)").font(FDFont.display(30, .bold)).foregroundStyle(settings.accent)
                        Text("correct").font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkFaint)
                        Spacer()
                        Button { play() } label: {
                            HStack(spacing: 7) { Image(systemName: "speaker.wave.2.fill").font(.system(size: 13)); Text("Hear again").font(FDFont.ui(14, .semibold)) }
                                .foregroundStyle(settings.ink).padding(.horizontal, 16).frame(height: 40)
                                .fdCard(11, fill: settings.panel2)
                        }.buttonStyle(.plain)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(options, id: \.semi) { opt in optionButton(opt) }
                    }
                    if answered != nil {
                        Button { newRound() } label: {
                            Text("Next  →").font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background(RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
            }
            .frame(width: 420)
            Spacer()
        }
    }

    private func optionButton(_ opt: (semi: Int, name: String)) -> some View {
        let isAnswer = opt.semi == interval
        let chosen = answered == opt.semi
        let graded = answered != nil
        let fill: Color = graded ? (isAnswer ? settings.theme.good.opacity(0.85) : (chosen ? settings.theme.miss.opacity(0.7) : settings.panel2)) : settings.panel2
        return Button { guess(opt.semi) } label: {
            Text(opt.name).font(FDFont.ui(14, .semibold)).foregroundStyle(graded && (isAnswer || chosen) ? .white : settings.ink)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(graded)
    }

    private func newRound() {
        root = [55, 57, 60, 62, 64].randomElement() ?? 60
        interval = options.randomElement()?.semi ?? 7
        answered = nil
        play()
    }
    private func play() {
        engine.start()
        let now = engine.now() + 0.05
        engine.triggerSynth(voice, midi: root, dur: 0.55, vel: 0.5, when: now)
        engine.triggerSynth(voice, midi: root + interval, dur: 0.6, vel: 0.5, when: now + 0.5)
    }
    private func guess(_ semi: Int) {
        guard answered == nil else { return }
        answered = semi
        total += 1
        if semi == interval { score += 1 }
    }
}
