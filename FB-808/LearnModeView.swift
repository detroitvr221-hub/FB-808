//  LearnModeView.swift — production-connected learning: guided lessons +
//  the follow-the-lights Practice game. Ported from mode-learn.jsx,
//  app.jsx (LessonsScreen) and practice.jsx.

import SwiftUI
import Combine
import UIKit

// MARK: - Practice engine

private final class Target {
    let tk: Int
    let padID: String
    let time: Double
    var consumed = false
    var result: String?
    init(tk: Int, padID: String, time: Double) { self.tk = tk; self.padID = padID; self.time = time }
}

struct HUD { var score = 0; var combo = 0; var best = 0; var accuracy = 0.0; var prog = 0.0 }
struct PracticeResults { var acc = 0.0; var stars = 0; var perfects = 0; var goods = 0; var misses = 0; var best = 0; var xp = 0 }

@MainActor
final class PracticeModel: ObservableObject {
    let engine: AudioEngine
    let fx: PadFX
    var onXP: ((Int) -> Void)?

    @Published var stage = "menu"           // menu | ready | playing | results
    @Published var pattern: Kit.Pattern?
    @Published var hud = HUD()
    @Published var results: PracticeResults?
    @Published var count: String?
    @Published var demo = false
    @Published var speed = 1.0          // practice slower (B2)
    @Published var autoRamp = false     // bump speed up after a clean pass (Auto-BPM)

    private var targets: [Target] = []
    private var work: [DispatchWorkItem] = []
    private var loop: Task<Void, Never>?
    private var startTime = 0.0
    private var endTime = 0.0
    private var totalSteps = 0
    private var stepDur = 0.0
    private var active = false
    private var points = 0.0, combo = 0, best = 0, perfects = 0, goods = 0, misses = 0, possible = 0, prog = 0.0

    init(engine: AudioEngine, fx: PadFX) { self.engine = engine; self.fx = fx }

    func reset() { clearTimers(); stage = "menu"; pattern = nil; results = nil; count = nil; demo = false; fx.clearAllLit() }

    private func clearTimers() {
        work.forEach { $0.cancel() }; work.removeAll()
        loop?.cancel(); loop = nil
    }
    private func after(_ delay: Double, _ block: @escaping () -> Void) {
        let w = DispatchWorkItem(block: block)
        work.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: w)
    }

    // entry points
    func choose(_ p: Kit.Pattern) { pattern = p; stage = "ready" }
    func loadLesson(_ p: Kit.Pattern?) { pattern = p; if p != nil { stage = "ready" } }

    func play(_ p: Kit.Pattern) { demo = false; stage = "playing"; startRound(p, scored: true, bars: 4, leadAsBacking: false, countBeats: 4) }
    func watch(_ p: Kit.Pattern) { demo = true; stage = "playing"; startRound(p, scored: false, bars: 2, leadAsBacking: true, countBeats: 0) }

    private func schedulePlay(_ padID: String, _ time: Double) {
        let sound = Kit.padByID[padID]?.sound ?? padID
        engine.trigger(sound, vel: 0.85, when: time)
        after(time - engine.now()) { [weak self] in self?.fx.bump(padID) }
    }
    private func scheduleClick(_ time: Double, _ accent: Bool) {
        engine.trigger("click", vel: accent ? 0.95 : 0.7, when: time)
    }
    private func scheduleLight(_ t: Target, _ leadMs: Double) {
        after((t.time - leadMs / 1000) - engine.now()) { [weak self] in
            self?.fx.setLit(t.padID, leadMs: leadMs, tk: t.tk)
        }
        after((t.time + 0.13) - engine.now()) { [weak self] in
            self?.fx.clearLit(t.padID, tk: t.tk)
        }
    }
    private func showFeedback(_ padID: String, _ result: String, _ tk: Int) {
        fx.showFeedback(padID, result, tk: tk)
        // Non-visual feedback so the hit result reaches VoiceOver / no-look players:
        // result-differentiated notification haptic + a spoken announcement.
        let label = Kit.padByID[padID]?.label ?? padID
        let notif: UINotificationFeedbackGenerator.FeedbackType
        let spoken: String
        switch result {
        case "perfect": notif = .success; spoken = "Perfect, \(label)"
        case "early":   notif = .warning; spoken = "Early, \(label)"
        case "late":    notif = .warning; spoken = "Late, \(label)"
        default:        notif = .error;   spoken = "Miss, \(label)"
        }
        UINotificationFeedbackGenerator().notificationOccurred(notif)
        UIAccessibility.post(notification: .announcement, argument: spoken)
        after(0.48) { [weak self] in self?.fx.clearFeedback(padID) }
    }

    private func startRound(_ p: Kit.Pattern, scored: Bool, bars: Int, leadAsBacking: Bool, countBeats: Int) {
        clearTimers()
        engine.start()
        fx.clearAllLit(); fx.feedback.removeAll(); results = nil
        let bpm = Double(p.bpm) * speed
        stepDur = (60 / bpm) / 4
        let beatDur = 60 / bpm
        let leadMs = min(620, stepDur * 1000 * 3)
        let start = engine.now() + Double(countBeats) * beatDur + 0.18
        startTime = start
        totalSteps = bars * 16
        active = scored
        points = 0; combo = 0; best = 0; perfects = 0; goods = 0; misses = 0; possible = 0; prog = 0
        hud = HUD()

        for c in 0..<countBeats {
            let ct = engine.now() + 0.05 + Double(c) * beatDur
            scheduleClick(ct, c == 0)
            let label = (countBeats - c) == 1 ? "GO" : String(countBeats - c)
            after(ct - engine.now()) { [weak self] in self?.count = label }
        }
        if countBeats > 0 { after((start - engine.now()) + 0.12) { [weak self] in self?.count = nil } }

        var built: [Target] = []
        var tk = 0
        let leadSet = Set(p.lead.map { "\($0.step):\($0.padID)" })
        var lastTime = start
        for bar in 0..<bars {
            for s in 0..<16 {
                let time = start + Double(bar * 16 + s) * stepDur
                lastTime = time
                for padID in p.steps[s] {
                    let isLead = leadSet.contains("\(s):\(padID)")
                    if isLead && !leadAsBacking { continue }
                    schedulePlay(padID, time)
                }
                for l in p.lead where l.step == s {
                    if leadAsBacking { schedulePlay(l.padID, time); continue }
                    let t = Target(tk: tk, padID: l.padID, time: time); tk += 1
                    built.append(t)
                    scheduleLight(t, leadMs)
                }
                if s % 4 == 0 { scheduleClick(time, s == 0) }
            }
        }
        targets = built
        possible = built.count
        endTime = lastTime + 0.45

        if scored {
            loop = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let now = self.engine.now()
                    for t in self.targets where !t.consumed && now - t.time > 0.18 {
                        t.consumed = true; t.result = "miss"; self.misses += 1; self.combo = 0
                        self.showFeedback(t.padID, "miss", t.tk)
                    }
                    self.prog = max(0, min(1, (now - self.startTime) / (Double(self.totalSteps) * self.stepDur)))
                    self.updateHud()
                    if now > self.endTime { self.finish(); return }
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
            }
        } else {
            after(endTime - engine.now()) { [weak self] in
                self?.demo = false; self?.stage = "ready"; self?.fx.clearAllLit()
            }
        }
    }

    func onHit(_ padID: String) {
        let sound = Kit.padByID[padID]?.sound ?? padID
        engine.trigger(sound, vel: 0.95)
        fx.bump(padID)
        guard active else { return }
        let now = engine.now()
        let cands = targets.filter { $0.padID == padID && !$0.consumed && abs($0.time - now) <= 0.18 }
        guard let t = cands.min(by: { abs($0.time - now) < abs($1.time - now) }) else { return }
        t.consumed = true
        let dt = abs(t.time - now)
        // Melodics-grade: distinguish on-time / early (rushed) / late (dragged)
        let result: String
        if dt <= 0.05 { result = "perfect"; perfects += 1; points += 1 }
        else if t.time > now { result = "early"; goods += 1; points += 0.6 }
        else { result = "late"; goods += 1; points += 0.6 }
        t.result = result
        combo += 1; best = max(best, combo)
        showFeedback(padID, result, t.tk)
        updateHud()
    }

    private func updateHud() {
        let acc = possible > 0 ? points / Double(possible) : 0
        hud = HUD(score: Int(points * 100), combo: combo, best: best, accuracy: acc, prog: prog)
    }

    private func finish() {
        clearTimers()
        active = false
        let acc = possible > 0 ? points / Double(possible) : 0
        let stars = acc >= 0.93 ? 3 : acc >= 0.78 ? 2 : acc >= 0.55 ? 1 : 0
        let xp = Int(points * 18) + stars * 20
        fx.clearAllLit()
        if autoRamp && stars >= 2 && speed < 1.0 { speed = speed < 0.75 ? 0.75 : 1.0 }   // Auto-BPM ramp
        results = PracticeResults(acc: acc, stars: stars, perfects: perfects, goods: goods, misses: misses, best: best, xp: xp)
        stage = "results"
        // Announce the round result so VoiceOver users hear the outcome without reading the overlay.
        UIAccessibility.post(notification: .announcement,
                             argument: "Round complete. \(Int(acc * 100)) percent, \(stars) of 3 stars. \(perfects) perfect, \(goods) good, \(misses) missed.")
        onXP?(xp)
    }
}

// MARK: - Learn Mode

struct LearnModeView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var project: Project
    @EnvironmentObject var progressStore: ProgressStore   // persisted lesson completion (B8)
    var onXP: (Int) -> Void
    var openTab: (String) -> Void

    @StateObject private var model: PracticeModel
    @State private var sub = "lessons"
    @State private var lessonInProgress: String?
    @State private var lessonNote: String?   // inline message when a lesson can't start (e.g. pattern unavailable)

    init(engine: AudioEngine, fx: PadFX, onXP: @escaping (Int) -> Void, openTab: @escaping (String) -> Void) {
        self.onXP = onXP
        self.openTab = openTab
        _model = StateObject(wrappedValue: PracticeModel(engine: engine, fx: fx))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModeHead(title: "Learn", eyebrow: "Skills → Real Beats")
            CoachNote("Learning lives **inside** the studio. Pass a follow-the-lights drill and FD808 drops the pattern straight into a real project so you can build on it.")
                .padding(.top, 10)
            if let note = lessonNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(settings.accent)
                    Text(note).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    Spacer()
                    Button { lessonNote = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(settings.inkDim)
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 9).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.4), lineWidth: 1))
                .padding(.top, 8)
            }
            tabs.padding(.vertical, 14)
            Group {
                if sub == "lessons" { LessonsScreen(done: progressStore.doneLessons) { launch($0) } }
                else if sub == "challenge" { ChallengeView() }
                else if sub == "league" { LeagueView() }
                else { PracticeView(model: model, onExit: practiceExit, onBuild: buildOn) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.onXP = onXP }
        .onDisappear { model.reset() }   // stop any in-flight round/timers when leaving Learn
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            tab("Guided Lessons", id: "lessons")
            tab("Practice", id: "practice")
            tab("Challenge", id: "challenge")
            tab("League", id: "league")
        }
    }
    private func tab(_ label: String, id: String) -> some View {
        Button {
            if id == "practice" && sub != "practice" { model.reset() }
            sub = id
        } label: {
            Text(label).font(FDFont.ui(14, .semibold))
                .foregroundStyle(sub == id ? settings.ink : settings.inkDim)
                .padding(.horizontal, 18).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(sub == id ? settings.accent.opacity(0.18) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(sub == id ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func launch(_ l: Kit.Lesson) {
        let p = l.patternID.flatMap { Kit.pattern($0) }
        guard p != nil else {
            // Pattern failed to resolve — stay on the lessons screen and explain, rather than
            // silently dumping the user into the practice picker.
            lessonInProgress = nil
            lessonNote = "“\(l.title)” is coming soon — its beat isn’t available yet."
            sub = "lessons"
            return
        }
        lessonNote = nil
        lessonInProgress = l.id
        model.reset()
        model.loadLesson(p)
        sub = "practice"
    }
    private func practiceExit() {
        if let id = lessonInProgress { progressStore.completeLesson(id); lessonInProgress = nil; sub = "lessons" }
    }
    // Drop the practiced pattern into the real project and jump to the sequencer to build on it.
    private func buildOn(_ p: Kit.Pattern) {
        project.checkpoint("buildOn", coalesce: false)   // make the overwrite undoable
        project.lanes = Kit.lanesFromSteps(p.steps)
        project.bpm = p.bpm
        project.name = p.name
        if let id = lessonInProgress { progressStore.completeLesson(id); lessonInProgress = nil }
        model.reset()
        openTab("sequence")
    }
}

// MARK: - Practice view

struct PracticeView: View {
    @ObservedObject var model: PracticeModel
    @EnvironmentObject var fx: PadFX
    @EnvironmentObject var settings: AppSettings
    var onExit: () -> Void
    var onBuild: (Kit.Pattern) -> Void

    var body: some View {
        switch model.stage {
        case "menu": menu
        case "ready": ready
        default: playing
        }
    }

    private func leadPads(_ p: Kit.Pattern) -> [PadDef] {
        var seen = Set<String>(); var out: [PadDef] = []
        for l in p.lead where !seen.contains(l.padID) { seen.insert(l.padID); if let pad = Kit.padByID[l.padID] { out.append(pad) } }
        return out
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Follow the Lights")
            Text("Practice").font(FDFont.display(40, .bold)).foregroundStyle(settings.ink)
            Text("Pads light up — tap them in time. Nail the rhythm to earn stars.")
                .font(FDFont.ui(15)).foregroundStyle(settings.inkDim).padding(.top, 2)
            HStack(spacing: 18) {
                ForEach(Kit.patterns) { p in PatternCard(p: p, leadPads: leadPads(p)) { model.choose(p) } }
            }
            .padding(.top, 24)
            Spacer()
        }
    }

    private var ready: some View {
        Group {
            if let p = model.pattern {
                VStack(spacing: 0) {
                    HStack {
                        Button { model.reset() } label: {
                            Text("‹ All beats").font(FDFont.ui(14, .semibold)).foregroundStyle(settings.inkDim)
                        }.buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                    VStack(spacing: 12) {
                        Text(p.name).font(FDFont.display(32, .bold)).foregroundStyle(settings.ink)
                        Text("\(p.vibe) · \(p.bpm) BPM").font(FDFont.mono(13)).foregroundStyle(settings.inkDim)
                        VStack(spacing: 7) {
                            Text("YOU'LL PLAY").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                            HStack(spacing: 6) { ForEach(leadPads(p)) { chip($0) } }
                        }.padding(.vertical, 6)
                        Text("When a pad glows and the ring closes in — tap it right as the ring lands. The rest of the beat plays itself.")
                            .font(FDFont.ui(14)).foregroundStyle(settings.inkDim).multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                        speedRow
                        HStack(spacing: 12) {
                            Button { model.watch(p) } label: {
                                Label("Watch it first", systemImage: "eye").font(FDFont.ui(15, .semibold)).foregroundStyle(settings.ink)
                                    .padding(.vertical, 13).padding(.horizontal, 20)
                                    .fdCard(14, fill: settings.panel2)
                            }.buttonStyle(.plain)
                            Button { model.play(p) } label: {
                                HStack(spacing: 9) { Triangle().fill(.white).frame(width: 11, height: 13); Text("I'm ready") }
                                    .font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                                    .padding(.vertical, 13).padding(.horizontal, 20)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
                            }.buttonStyle(.plain)
                        }.padding(.top, 4)
                    }
                    .padding(34)
                    .frame(maxWidth: 460)
                    .fdCard(24, fill: settings.panel)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var speedRow: some View {
        VStack(spacing: 7) {
            Text("PRACTICE SPEED").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            HStack(spacing: 6) {
                speedChip(0.5, "50%"); speedChip(0.75, "75%"); speedChip(1.0, "100%")
                Button { model.autoRamp.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.autoRamp ? "checkmark.circle.fill" : "circle").font(.system(size: 12))
                        Text("Auto-ramp").font(FDFont.ui(12.5, .semibold))
                    }
                    .foregroundStyle(model.autoRamp ? settings.accent : settings.inkDim)
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9).fill(model.autoRamp ? settings.accent.opacity(0.15) : settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.autoRamp ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 2)
    }
    private func speedChip(_ s: Double, _ label: String) -> some View {
        let on = abs(model.speed - s) < 0.01
        return Button { model.speed = s } label: {
            Text(label).font(FDFont.mono(12, .bold)).foregroundStyle(on ? .white : settings.inkDim)
                .frame(width: 52, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func chip(_ pad: PadDef) -> some View {
        Text(pad.label).font(FDFont.mono(11, .bold)).foregroundStyle(pad.color)
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(pad.color.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(pad.color.opacity(0.3), lineWidth: 1))
    }

    private var playing: some View {
        ZStack {
            VStack(spacing: 18) {
                hudBar
                ZStack {
                    PadGridView(pads: Kit.pads, showLabels: true, maxSide: 520,
                                onHit: { model.onHit($0) })
                    if let c = model.count {
                        Text(c).font(FDFont.display(140, .bold)).foregroundStyle(settings.ink)
                            .shadow(color: .black.opacity(0.6), radius: 30, y: 8)
                            .id(c)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            if model.stage == "results", let r = model.results { resultsOverlay(r) }
        }
        .overlay(alignment: .topTrailing) {
            if model.stage != "results" {
                Button { fx.reset(); onExit(); model.reset() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        Text("End round").font(FDFont.ui(13, .semibold))
                    }
                    .foregroundStyle(settings.inkDim)
                    .padding(.vertical, 8).padding(.horizontal, 13)
                    .fdCard(10, fill: settings.panel2)
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.25), value: model.count)
    }

    private var hudBar: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(model.pattern?.name ?? "").font(FDFont.display(17, .semibold)).foregroundStyle(settings.ink)
                    if model.demo {
                        Text("WATCH").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.accent)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(settings.accent.opacity(0.15)))
                    }
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(settings.line)
                        Capsule().fill(settings.accent).frame(width: g.size.width * model.hud.prog)
                    }
                }.frame(height: 8).frame(maxWidth: 340)
            }
            VStack(spacing: 3) {
                Text("\(model.hud.combo)").font(FDFont.display(34, .bold))
                    .foregroundStyle(model.hud.combo >= 4 ? settings.accent : settings.ink)
                Text("COMBO").font(FDFont.mono(10)).tracking(1).foregroundStyle(settings.inkFaint)
            }
            HStack(spacing: 20) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(model.hud.score)").font(FDFont.mono(22, .bold)).foregroundStyle(settings.ink)
                    Text("SCORE").font(FDFont.mono(10)).tracking(0.8).foregroundStyle(settings.inkFaint)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(model.hud.accuracy * 100))%").font(FDFont.mono(22, .bold)).foregroundStyle(settings.ink)
                    Text("ACCURACY").font(FDFont.mono(10)).tracking(0.8).foregroundStyle(settings.inkFaint)
                }
            }
        }
    }

    private func resultsOverlay(_ r: PracticeResults) -> some View {
        ZStack {
            settings.theme.bg.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(r.stars >= 3 ? "Beat Mastered!" : r.stars == 2 ? "Nice Groove!" : r.stars == 1 ? "Good Start!" : "Keep Practicing")
                    .font(FDFont.display(26, .bold)).foregroundStyle(settings.ink)
                StarRow(n: r.stars, big: true)
                Text("\(Int(r.acc * 100))%").font(FDFont.display(54, .bold)).foregroundStyle(settings.accent)
                HStack(spacing: 26) {
                    statCell("\(r.perfects)", "Perfect"); statCell("\(r.goods)", "Good")
                    statCell("\(r.misses)", "Miss"); statCell("\(r.best)", "Best combo")
                }
                Text("+\(r.xp) XP").font(FDFont.mono(15, .bold)).foregroundStyle(settings.theme.good)
                    .padding(.vertical, 6).padding(.horizontal, 16)
                    .background(Capsule().fill(settings.theme.good.opacity(0.14)))
                if model.speed < 1.0 {
                    Text("Practice speed \(Int(model.speed * 100))%\(model.autoRamp ? " · Auto-ramp on — replays may speed up" : "")")
                        .font(FDFont.mono(11, .bold)).tracking(0.5).foregroundStyle(settings.inkFaint)
                }
                VStack(spacing: 10) {
                    if let p = model.pattern {
                        Button { fx.reset(); onBuild(p) } label: {
                            Text("✦ Build on this beat  →").font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
                        }.buttonStyle(.plain)
                    }
                    HStack(spacing: 12) {
                        Button { if let p = model.pattern { model.stage = "ready"; model.pattern = p } } label: {
                            Text("Try again").font(FDFont.ui(15, .semibold)).foregroundStyle(settings.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .fdCard(14, fill: settings.panel2)
                        }.buttonStyle(.plain)
                        Button { model.results = nil; fx.reset(); onExit(); model.reset() } label: {
                            Text("Done").font(FDFont.ui(15, .semibold)).foregroundStyle(settings.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .fdCard(14, fill: settings.panel2)
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 4)
            }
            .padding(EdgeInsets(top: 34, leading: 40, bottom: 34, trailing: 40))
            .frame(minWidth: 380)
            .fdCard(26, fill: settings.panel)
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
    }

    private func statCell(_ b: String, _ s: String) -> some View {
        VStack(spacing: 3) {
            Text(b).font(FDFont.mono(20, .bold)).foregroundStyle(settings.ink)
            Text(s.uppercased()).font(FDFont.ui(11)).tracking(0.5).foregroundStyle(settings.inkFaint)
        }
    }
}

// MARK: - Lessons screen, pattern card, stars

struct LessonsScreen: View {
    @EnvironmentObject var settings: AppSettings
    var done: Set<String>
    var onLaunch: (Kit.Lesson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Your Path")
            Text("Skill Path").font(FDFont.display(40, .bold)).foregroundStyle(settings.ink)
            Text("A guided path from your first beat to your own productions. Finish one to unlock the next.")
                .font(FDFont.ui(15)).foregroundStyle(settings.inkDim).padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Kit.lessons.enumerated()), id: \.element.id) { (i, l) in
                        pathNode(l, isLast: i == Kit.lessons.count - 1)
                    }
                }
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A lesson unlocks once its predecessor is completed (or seeded-done) — derived from live
    /// progress instead of the frozen `Kit.lessons[].locked` literal, so the Skill Path actually opens up.
    private func isUnlocked(_ l: Kit.Lesson) -> Bool {
        guard let idx = Kit.lessons.firstIndex(where: { $0.id == l.id }) else { return true }
        if idx == 0 { return true }
        let prev = Kit.lessons[idx - 1]
        return done.contains(prev.id) || prev.done
    }

    private func pathNode(_ l: Kit.Lesson, isLast: Bool) -> some View {
        let done = self.done.contains(l.id) || l.done
        let locked = !isUnlocked(l)
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(done ? settings.theme.good.opacity(0.2) : (locked ? settings.panel2 : settings.accent.opacity(0.18)))
                        .frame(width: 46, height: 46)
                        .overlay(Circle().stroke(done ? settings.theme.good : (locked ? settings.line : settings.accent), lineWidth: 2))
                    if locked { Image(systemName: "lock.fill").font(.system(size: 15)).foregroundStyle(settings.inkFaint) }
                    else if done { Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(settings.theme.good) }
                    else { Text("\(l.n)").font(FDFont.display(18, .bold)).foregroundStyle(settings.accent) }
                }
                if !isLast {
                    Rectangle().fill(done ? settings.theme.good.opacity(0.5) : settings.line)
                        .frame(width: 3).frame(maxHeight: .infinity)
                }
            }
            Button { if !locked { onLaunch(l) } } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(FDFont.display(18, .semibold)).foregroundStyle(settings.ink)
                        Text(l.sub).font(FDFont.ui(13)).foregroundStyle(settings.inkDim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(l.skill.uppercased()).font(FDFont.mono(10, .bold)).tracking(0.6).foregroundStyle(settings.accent)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background(Capsule().fill(settings.accent.opacity(0.12)))
                        Text("\(l.mins) min").font(FDFont.mono(12)).foregroundStyle(settings.inkFaint)
                    }
                    Text(locked ? "" : (done ? "Replay" : "Start")).font(FDFont.ui(14, .semibold))
                        .foregroundStyle(settings.accent).frame(width: 50, alignment: .trailing)
                }
                .padding(.vertical, 13).padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(done ? settings.theme.good.opacity(0.4) : settings.line, lineWidth: 1))
                .opacity(locked ? 0.55 : 1)
            }.buttonStyle(.plain).disabled(locked).padding(.bottom, 12)
        }
    }
}

struct PatternCard: View {
    @EnvironmentObject var settings: AppSettings
    let p: Kit.Pattern
    let leadPads: [PadDef]
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(i < p.difficulty ? settings.accent : settings.line).frame(width: 8, height: 8)
                    }
                }
                Spacer()
                styledText([("\(p.bpm) ", nil, FDFont.mono(16, .bold)), ("BPM", nil, FDFont.mono(10))])
                    .foregroundStyle(settings.ink)
            }
            Text(p.name).font(FDFont.display(24, .bold)).foregroundStyle(settings.ink)
            Text(p.vibe).font(FDFont.ui(13.5)).foregroundStyle(settings.inkDim).padding(.top, -6)
            VStack(alignment: .leading, spacing: 7) {
                Text("YOUR PART").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                HStack(spacing: 6) {
                    ForEach(leadPads) { pad in
                        Text(pad.label).font(FDFont.mono(11, .bold)).foregroundStyle(pad.color)
                            .padding(.vertical, 5).padding(.horizontal, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(pad.color.opacity(0.14)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(pad.color.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            Button(action: onStart) {
                HStack(spacing: 9) { Triangle().fill(.white).frame(width: 11, height: 13); Text("Start") }
                    .font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
            }.buttonStyle(.plain).padding(.top, 6)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .fdCard(20, fill: settings.panel)
    }
}

// MARK: - League (classroom-scoped weekly leaderboard, B9)

struct LeagueView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore

    private struct Member: Identifiable { let id = UUID(); let name: String; let xp: Int; let me: Bool }
    private static let peers: [(String, Int)] = [
        ("Maya", 720), ("Leo", 540), ("Aisha", 480), ("Sam", 410), ("Diego", 360),
        ("Priya", 300), ("Jordan", 250), ("Kim", 210), ("Tariq", 170), ("Noa", 120), ("Eli", 80), ("Zoe", 40),
    ]
    private var members: [Member] {
        var m = LeagueView.peers.map { Member(name: $0.0, xp: $0.1, me: false) }
        m.append(Member(name: "You", xp: progress.totalXP, me: true))
        return m.sorted { $0.xp > $1.xp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "This Week · Beat Lab League")
            HStack(spacing: 10) {
                Text("League").font(FDFont.display(40, .bold)).foregroundStyle(settings.ink)
                Text("SAMPLE").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.accent)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(Capsule().fill(settings.accent.opacity(0.15)))
            }
            Text("Compete with your class, not the whole world — winnable by design. Top 3 promote, bottom 3 drop a tier.")
                .font(FDFont.ui(15)).foregroundStyle(settings.inkDim)
            Text("These classmates are sample data to preview how rankings work — real classroom leagues arrive with Teacher sync.")
                .font(FDFont.ui(12.5)).foregroundStyle(settings.inkFaint)
            ScrollView {
                VStack(spacing: 7) {
                    let mem = members
                    ForEach(Array(mem.enumerated()), id: \.element.id) { (i, m) in row(rank: i + 1, m, total: mem.count) }
                }
                .padding(.top, 16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: 560, alignment: .topLeading)
    }

    private func row(rank: Int, _ m: Member, total: Int) -> some View {
        let promote = rank <= 3
        let demote = rank > total - 3
        let zone = promote ? settings.theme.good : (demote ? settings.theme.miss : settings.inkFaint)
        return HStack(spacing: 14) {
            Text("\(rank)").font(FDFont.mono(15, .bold)).foregroundStyle(zone).frame(width: 26)
            Circle().fill(m.me ? settings.accent : settings.panel2)
                .frame(width: 34, height: 34)
                .overlay(Text(String(m.name.prefix(1))).font(FDFont.display(15, .bold)).foregroundStyle(m.me ? .white : settings.inkDim))
            Text(m.name).font(FDFont.display(16, m.me ? .bold : .semibold)).foregroundStyle(m.me ? settings.accent : settings.ink)
            if promote { Image(systemName: "arrow.up.circle.fill").font(.system(size: 13)).foregroundStyle(settings.theme.good) }
            else if demote { Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(settings.theme.miss) }
            Spacer()
            Text("\(m.xp) XP").font(FDFont.mono(13, .bold)).foregroundStyle(settings.inkDim)
        }
        .padding(.vertical, 11).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(m.me ? settings.accent.opacity(0.12) : settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(m.me ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
    }
}

// MARK: - Challenge: recreate the groove (auto-graded, B10)

struct ChallengeView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @State private var patternID = "boombap"
    @State private var guess: [String: Set<Int>] = [:]
    @State private var result: Double?

    private var pattern: Kit.Pattern { Kit.pattern(patternID) ?? Kit.patterns[0] }
    private var leadPads: [String] {
        var seen: [String] = []
        for l in pattern.lead where !seen.contains(l.padID) { seen.append(l.padID) }
        return seen
    }
    private var target: [String: Set<Int>] {
        var t: [String: Set<Int>] = [:]
        for l in pattern.lead { t[l.padID, default: []].insert(l.step) }
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Recreate the Groove")
            Text("Challenge").font(FDFont.display(40, .bold)).foregroundStyle(settings.ink)
            Text("Listen to the target, then tap the steps to recreate it — green = right, orange = extra, red = missed.")
                .font(FDFont.ui(15)).foregroundStyle(settings.inkDim)
            HStack(spacing: 8) {
                ForEach(Kit.patterns) { p in
                    Button { patternID = p.id; guess = [:]; result = nil } label: {
                        Text(p.name).font(FDFont.ui(13, .semibold)).foregroundStyle(patternID == p.id ? .white : settings.inkDim)
                            .padding(.horizontal, 14).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(patternID == p.id ? settings.accent : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(patternID == p.id ? .clear : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.top, 4)
            grid
            HStack(spacing: 12) {
                ctrl("Listen", "speaker.wave.2.fill", filled: false) { listen() }
                ctrl("Check", "checkmark", filled: true) { check() }
                ctrl("Clear", "trash", filled: false) { guess = [:]; result = nil }
                Spacer()
                if let r = result {
                    HStack(spacing: 12) {
                        Text("\(Int(r * 100))%").font(FDFont.display(32, .bold)).foregroundStyle(settings.accent)
                        StarRow(n: r >= 0.95 ? 3 : r >= 0.75 ? 2 : r >= 0.5 ? 1 : 0)
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grid: some View {
        VStack(spacing: 6) {
            ForEach(leadPads, id: \.self) { padID in
                HStack(spacing: 5) {
                    Text(Kit.padByID[padID]?.label ?? padID).font(FDFont.mono(10, .bold))
                        .foregroundStyle(Kit.padByID[padID]?.color ?? settings.ink)
                        .frame(width: 72, alignment: .leading)
                    ForEach(0..<16, id: \.self) { i in cell(padID, i) }
                }
            }
        }
        .padding(12)
        .fdCard(16, fill: settings.panel)
    }

    private func cell(_ padID: String, _ i: Int) -> some View {
        let placed = guess[padID]?.contains(i) ?? false
        let inTarget = target[padID]?.contains(i) ?? false
        let beat = i % 4 == 0
        let graded = result != nil
        let base = beat ? settings.panel2.darker(0.04) : settings.panel2.darker(0.14)
        let color = Kit.padByID[padID]?.color ?? settings.accent
        let fill: Color = graded ? (placed && inTarget ? settings.theme.good : (placed ? Color(hex: "#FF9F1C") : base))
                                  : (placed ? color : base)
        let missed = graded && !placed && inTarget
        // Grading is conveyed by fill color (green/orange/red) only — add a per-state SF Symbol
        // so correct / extra / missed read without relying on color.
        let gradeGlyph: String? = graded ? (placed && inTarget ? "checkmark"
                                                              : (placed ? "plus" : (inTarget ? "circle.dashed" : nil)))
                                         : nil
        let gradeWord = graded ? (placed && inTarget ? "Correct"
                                                     : (placed ? "Extra" : (inTarget ? "Missed" : "Empty")))
                               : (placed ? "Placed" : "Empty")
        let label = Kit.padByID[padID]?.label ?? padID
        return RoundedRectangle(cornerRadius: 6).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(missed ? settings.theme.miss : settings.line2, lineWidth: missed ? 2 : 1))
            .overlay {
                if let g = gradeGlyph {
                    Image(systemName: g)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture {
                engine.start()
                if guess[padID]?.contains(i) == true { guess[padID]?.remove(i) }
                else { guess[padID, default: []].insert(i); engine.trigger(Kit.padByID[padID]?.sound ?? padID, vel: 0.9) }
                result = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(label) step \(i + 1)"))
            .accessibilityValue(Text(gradeWord))
            .accessibilityAddTraits(placed ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction {
                engine.start()
                if guess[padID]?.contains(i) == true { guess[padID]?.remove(i) }
                else { guess[padID, default: []].insert(i); engine.trigger(Kit.padByID[padID]?.sound ?? padID, vel: 0.9) }
                result = nil
            }
    }

    private func ctrl(_ label: String, _ icon: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 12)); Text(label).font(FDFont.ui(14, .semibold)) }
                .foregroundStyle(filled ? .white : settings.ink)
                .padding(.horizontal, 18).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(filled ? AnyShapeStyle(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(settings.panel2)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(filled ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func listen() {
        engine.start()
        let stepDur = (60 / Double(pattern.bpm)) / 4
        let now = engine.now() + 0.12
        for l in pattern.lead {
            engine.trigger(Kit.padByID[l.padID]?.sound ?? l.padID, vel: 0.9, when: now + Double(l.step) * stepDur)
        }
    }
    private func check() {
        var correct = 0, missed = 0, extra = 0
        for padID in leadPads {
            let t = target[padID] ?? [], g = guess[padID] ?? []
            correct += t.intersection(g).count
            missed += t.subtracting(g).count
            extra += g.subtracting(t).count
        }
        let denom = correct + missed + extra
        result = denom > 0 ? Double(correct) / Double(denom) : 0
    }
}

struct StarRow: View {
    @EnvironmentObject var settings: AppSettings
    let n: Int
    var big = false
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: big ? 46 : 20))
                    .foregroundStyle(i < n ? settings.theme.perfect : settings.line)
            }
        }
        // Collapse the three star glyphs into one labelled element so VoiceOver reads the rating, not "star, star, star".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(n) of 3 stars"))
    }
}
