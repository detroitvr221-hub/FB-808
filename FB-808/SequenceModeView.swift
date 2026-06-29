//  SequenceModeView.swift — step sequencer: 16 rows, 16 steps, velocity lane,
//  swing, randomize. Ported from mode-seq.jsx.

import SwiftUI

private let QUANTS = ["1/8", "1/16", "1/32"]
private let SWINGS = [0.0, 0.12, 0.25, 0.4, 0.55]
private let SIGS = [16, 12, 8]   // steps per bar → 4/4, 3/4, 2/4

struct SequenceModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore
    @State private var confirmClear = false

    @State private var painting: (val: Double, lastCol: Int)?
    @State private var velDragStart: Double?
    @State private var showEuclid = false
    @State private var euclidPulses = 4
    @State private var euclidRotate = 0
    @State private var editStep: Int?
    @State private var showGenerate = false
    @State private var genStyle = "boombap"
    @State private var genDensity = 0.5

    private let labelW: CGFloat = 132
    private let gap: CGFloat = 4

    private var sel: String { project.selectedRow }
    private var sigLabel: String {
        switch project.barSteps { case 12: return "3/4"; case 8: return "2/4"; default: return "4/4" }
    }

    var body: some View {
        VStack(spacing: 12) {
            TransportBar()
            VStack(alignment: .leading, spacing: 12) {
                ModeHead(title: "Sequence", eyebrow: "1 Bar · \(project.barSteps) Steps · \(sigLabel)",
                         hint: "Tap to place · drag to paint · hold a velocity bar for probability / conditions / locks")
                tools
                gridWrap
            }
        }
        .alert("Clear the whole pattern?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { project.clearAll() }
        } message: { Text("Erases every step on all rows of this sequence. You can undo it afterwards.") }
    }

    // MARK: tools

    private var tools: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("SEQ").font(FDFont.mono(10, .bold)).foregroundStyle(settings.inkFaint)
                ForEach(Array(project.sequences.enumerated()), id: \.offset) { (i, slot) in
                    Button { project.switchSequence(i) } label: {
                        Text(slot.name).font(FDFont.mono(12, .bold))
                            .foregroundStyle(project.activeSeq == i ? .white : settings.inkDim)
                            .frame(width: 30, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(project.activeSeq == i ? settings.accent : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(project.activeSeq == i ? .clear : settings.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Sequence \(slot.name)"))
                    .accessibilityValue(Text(project.activeSeq == i ? "Selected" : "Not selected"))
                    .accessibilityAddTraits(project.activeSeq == i ? [.isButton, .isSelected] : .isButton)
                }
            }
            Rectangle().fill(settings.line).frame(width: 1, height: 22)
            chip(styledText([("Swing ", settings.ink, nil), ("\(Int(project.swing * 100))%", settings.accent, nil)]), arrow: true) {
                project.checkpoint("swing", coalesce: false)
                project.swing = SWINGS.next(after: project.swing)
            }
            chip(styledText([("Humanize ", settings.ink, nil), ("\(Int(project.humanize * 100))%", settings.accent, nil)]), arrow: true) {
                project.checkpoint("humanize", coalesce: false)
                project.humanize = [0, 0.25, 0.5, 0.75, 1.0].next(after: project.humanize)
            }
            chip(styledText([("Groove ", settings.ink, nil), (Groove.byID(project.grooveID).name, settings.accent, nil)]), arrow: true) {
                project.checkpoint("groove", coalesce: false)
                project.grooveID = Groove.all.map(\.id).next(after: project.grooveID)
            }
            chip(styledText([("Quantize ", settings.ink, nil), (project.quantize, settings.accent, nil)]), arrow: true) {
                project.checkpoint("quant", coalesce: false)
                project.quantize = QUANTS.next(after: project.quantize)
            }
            chip(styledText([("Sig ", settings.ink, nil), (sigLabel, settings.accent, nil)]), arrow: true) {
                project.checkpoint("sig", coalesce: false)
                project.barSteps = SIGS.next(after: project.barSteps)
            }
            chip(Text("✨ Generate").foregroundStyle(settings.accent)) { showGenerate = true }
                .popover(isPresented: $showGenerate) { generatePanel }
            chip(Text("🎲 Randomize \(sel)").foregroundStyle(settings.ink)) { randomize() }
            chip(Text("◓ Euclid").foregroundStyle(settings.ink)) { showEuclid = true }
                .accessibilityLabel(Text("Euclidean fill"))
                .popover(isPresented: $showEuclid) { euclidPanel }
            chip(Text("Clear \(sel)").foregroundStyle(settings.ink)) { project.clearRow(sel) }
            chip(Text("Clear all").foregroundStyle(settings.ink)) { confirmClear = true }
            chip(styledText([("Auto ", settings.ink, nil), (autoLabel, settings.accent, nil)]), arrow: true) { cycleAuto() }
            Spacer()
        }
    }

    // MARK: Generate beat (D8)

    private var generatePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Beat").font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
            Text("Pick a style — fills the grid with an editable groove. Tap again to vary.")
                .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(Project.beatStyles) { st in
                    Button { genStyle = st.id } label: {
                        Text(st.name).font(FDFont.ui(12.5, .semibold))
                            .foregroundStyle(genStyle == st.id ? .white : settings.ink)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 9).fill(genStyle == st.id ? settings.accent : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(st.name) style"))
                    .accessibilityValue(Text(genStyle == st.id ? "Selected" : "Not selected"))
                    .accessibilityAddTraits(genStyle == st.id ? [.isButton, .isSelected] : .isButton)
                }
            }
            HStack(spacing: 8) {
                Text("Density").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.inkDim)
                ForEach([("Sparse", 0.25), ("Medium", 0.5), ("Busy", 0.85)], id: \.0) { name, d in
                    Button { genDensity = d } label: {
                        Text(name).font(FDFont.ui(11.5, .semibold))
                            .foregroundStyle(abs(genDensity - d) < 0.01 ? .white : settings.inkDim)
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(abs(genDensity - d) < 0.01 ? settings.accent : settings.panel2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(name) density"))
                    .accessibilityValue(Text(abs(genDensity - d) < 0.01 ? "Selected" : "Not selected"))
                    .accessibilityAddTraits(abs(genDensity - d) < 0.01 ? [.isButton, .isSelected] : .isButton)
                }
            }
            Button { project.generateBeat(style: genStyle, density: genDensity); progress.awardCreative("genBeat", 8) } label: {
                Text("✨ Generate / Vary").font(FDFont.ui(14, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent))
            }.buttonStyle(.plain)
        }
        .padding(16).frame(width: 320)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Euclidean fill

    private var euclidPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Euclidean Fill").font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
            Text("\(Kit.padByID[sel]?.label ?? sel) · spreads N hits evenly over \(project.barSteps) steps")
                .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            euclidStepper("Pulses", min(euclidPulses, project.barSteps), 0, project.barSteps) { euclidPulses = $0; applyEuclid() }
            euclidStepper("Rotate", min(euclidRotate, project.barSteps - 1), 0, project.barSteps - 1) { euclidRotate = $0; applyEuclid() }
        }
        .padding(16).frame(width: 250)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func euclidStepper(_ label: String, _ value: Int, _ lo: Int, _ hi: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.inkDim)
            Spacer()
            stepperBtn("–") { set(max(lo, value - 1)) }
            Text("\(value)").font(FDFont.mono(15, .bold)).foregroundStyle(settings.ink).frame(minWidth: 28)
            stepperBtn("+") { set(min(hi, value + 1)) }
        }
    }
    private func stepperBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 17, weight: .bold)).foregroundStyle(settings.inkDim)
                .frame(width: 30, height: 30)
                .fdCard(8, fill: settings.panel2)
        }.buttonStyle(.plain)
    }

    /// Bjorklund-style even distribution of `k` pulses over the bar's steps, with rotation.
    private func applyEuclid() {
        let n = max(1, project.barSteps)
        var lane = Kit.emptyLane()
        let k = max(0, min(n, euclidPulses))
        if k > 0 {
            var bucket = 0
            var hits = [Bool](repeating: false, count: n)
            for i in 0..<n {
                bucket += k
                if bucket >= n { bucket -= n; hits[i] = true }
            }
            let r = ((euclidRotate % n) + n) % n
            for i in 0..<n where hits[i] { lane[(i + r) % n] = 0.85 }
        }
        project.setRowLane(sel, lane)
    }

    private func chip(_ label: Text, arrow: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                label.font(FDFont.ui(12.5, .semibold))
                if arrow { Text("▸").font(.system(size: 13, weight: .bold)).foregroundStyle(settings.inkDim) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .fdCard(10, fill: settings.panel2)
        }.buttonStyle(.plain)
    }

    // MARK: grid

    private var gridWrap: some View {
        VStack(spacing: 0) {
            stepHeader
            rowsScroll
            velocityLane
            if project.autoTarget != "" { automationLane }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fdCard(16, fill: settings.panel)
    }

    private var stepHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: labelW)
            HStack(spacing: gap) {
                ForEach(0..<16, id: \.self) { i in
                    Text("\(i + 1)").font(FDFont.mono(9, i % 4 == 0 ? .bold : .regular))
                        .foregroundStyle(i % 4 == 0 ? settings.inkDim : settings.inkFaint)
                        .frame(maxWidth: .infinity)
                        .opacity(i < project.barSteps ? 1 : 0.3)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var rowsScroll: some View {
        ScrollView {
            VStack(spacing: gap) {
                ForEach(Kit.pads) { pad in row(pad) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ pad: PadDef) -> some View {
        let lane = project.lanes[pad.id] ?? Kit.emptyLane()
        let selected = sel == pad.id
        return HStack(spacing: 8) {
            // label
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(pad.color).frame(width: 10, height: 10)
                    .shadow(color: pad.color.opacity(0.55), radius: 4)
                Button { project.selectedRow = pad.id } label: {
                    Text(pad.label).font(FDFont.mono(11, .bold))
                        .foregroundStyle(selected ? settings.ink : settings.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                }.buttonStyle(.plain)
                rowFlag("M", on: project.rowMute[pad.id] ?? false, color: settings.theme.miss) {
                    project.checkpoint("rowmute", coalesce: false)
                    project.rowMute[pad.id] = !(project.rowMute[pad.id] ?? false)
                }
                rowFlag("S", on: project.rowSolo[pad.id] ?? false, color: settings.theme.good) {
                    project.checkpoint("rowsolo", coalesce: false)
                    project.rowSolo[pad.id] = !(project.rowSolo[pad.id] ?? false)
                }
            }
            .frame(width: labelW)

            // cells with paint drag
            GeometryReader { g in
                HStack(spacing: gap) {
                    ForEach(0..<16, id: \.self) { i in
                        cell(pad: pad, i: i, vel: i < lane.count ? lane[i] : 0)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let col = max(0, min(15, Int(v.location.x / (g.size.width / 16))))
                        if col >= project.barSteps { return }   // don't place hits outside the bar (A13)
                        paint(pad.id, col)
                    }
                    .onEnded { _ in painting = nil })
            }
            .frame(height: 30)
        }
    }

    private func cell(pad: PadDef, i: Int, vel: Double) -> some View {
        let on = vel > 0
        let beat = i % 4 == 0
        let ph = project.step == i && project.playing
        return RoundedRectangle(cornerRadius: 7)
            .fill(on ? pad.color : (beat ? settings.panel2.darker(0.04) : settings.panel2.darker(0.12)))
            .overlay(
                Group {
                    if on {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [.white.opacity(0.22 * (0.35 + vel * 0.65)), .clear], startPoint: .top, endPoint: .center))
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? .clear : settings.line2, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(ph ? settings.ink.opacity(0.65) : .clear, lineWidth: 2))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .opacity(i < project.barSteps ? 1 : 0.28)   // dim steps outside the bar length (A13)
            // VoiceOver: each step is a togglable cell (the sighted paint gesture lives on the row)
            .accessibilityElement()
            .accessibilityLabel(Text("\(pad.label) step \(i + 1)"))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { project.toggleStep(pad.id, i) }
    }

    private func rowFlag(_ s: String, on: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(9, .bold))
                .foregroundStyle(on ? (s == "S" ? FDPalette.soloInk : .white) : settings.inkFaint)
                .frame(width: 19, height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? .clear : settings.line, lineWidth: 1))
                // non-color cue: a small slash/check glyph in the corner when active (in addition to the color fill)
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: s == "S" ? "checkmark" : "speaker.slash.fill")
                            .font(.system(size: 6, weight: .black))
                            .foregroundStyle(s == "S" ? FDPalette.soloInk : .white)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(s == "S" ? "Solo" : "Mute"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: velocity lane

    private var velocityLane: some View {
        let lane = project.lanes[sel] ?? Kit.emptyLane()
        let c = Kit.padByID[sel]?.color ?? settings.accent
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("VELOCITY").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                Text(Kit.padByID[sel]?.label ?? "").font(FDFont.mono(12, .bold)).foregroundStyle(settings.inkDim)
            }
            .frame(width: labelW, alignment: .leading)

            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<16, id: \.self) { i in
                    let v = i < lane.count ? lane[i] : 0
                    velBar(i: i, v: v, color: c)
                        .opacity(i < project.barSteps ? 1 : 0.28)
                        .allowsHitTesting(i < project.barSteps)
                }
            }
            .frame(height: 62)
        }
        .padding(.top, 8)
        .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .top)
        .frame(height: 78)
        .popover(isPresented: Binding(get: { editStep != nil }, set: { if !$0 { editStep = nil } })) {
            if let step = editStep { stepInspector(step) }
        }
    }

    // MARK: per-step inspector (probability / conditions / p-locks)

    private let stepConds: [(String, String)] = [
        ("", "OFF"), ("1:2", "1:2"), ("2:2", "2:2"), ("1:3", "1:3"),
        ("1:4", "1:4"), ("fill", "FILL"), ("!fill", "¬FILL"),
    ]
    private func hz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
    // VoiceOver-friendly spoken name for a trig condition (the on-screen glyphs are cryptic)
    private func condLabel(_ c: String, _ lbl: String) -> String {
        switch c {
        case "": return "Condition off"
        case "1:2": return "Every 2nd loop"
        case "2:2": return "Other 2nd loop"
        case "1:3": return "Every 3rd loop"
        case "1:4": return "Every 4th loop"
        case "fill": return "Fill only"
        case "!fill": return "Not on fill"
        default: return lbl
        }
    }

    @ViewBuilder private func stepInspector(_ step: Int) -> some View {
        let meta = project.stepMeta[sel]?[step] ?? StepMeta()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(Kit.padByID[sel]?.label ?? sel) · Step \(step + 1)").font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
                Spacer()
                Button { project.clearStepMeta(sel, step); editStep = nil } label: {
                    Text("Clear").font(FDFont.mono(10, .bold)).foregroundStyle(settings.inkDim)
                        .padding(.horizontal, 8).frame(height: 24)
                        .fdCard(6, fill: settings.panel2)
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Probability").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                    Spacer()
                    Text("\(Int(meta.prob * 100))%").font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
                }
                Slider(value: Binding(get: { project.stepMeta[sel]?[step]?.prob ?? 1 },
                                      set: { v in project.setStepMeta(sel, step) { $0.prob = v } }), in: 0...1).tint(settings.accent)
            }
            Text("CONDITION").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                ForEach(stepConds, id: \.0) { (c, lbl) in
                    let on = (project.stepMeta[sel]?[step]?.cond ?? "") == c
                    Button { project.setStepMeta(sel, step) { $0.cond = c } } label: {
                        Text(lbl).font(FDFont.mono(10, .bold)).foregroundStyle(on ? .white : settings.inkDim)
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(on ? settings.accent : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.clear : settings.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(condLabel(c, lbl)))
                    .accessibilityValue(Text(on ? "Selected" : "Not selected"))
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            Text("PARAMETER LOCKS").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            plockRow("Pitch", \.pitch, step, -12, 12, 0) { "\(Int($0)) st" }
            plockRow("Cutoff", \.cutoff, step, 200, 12000, 4000) { hz($0) + " Hz" }
            plockRow("Decay", \.decay, step, 0.02, 1.5, 0.2) { "\(Int($0 * 1000)) ms" }
            plockRow("Pan", \.pan, step, -1, 1, 0) { Music.panLabel($0) }
        }
        .padding(16).frame(width: 290)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func plockRow(_ label: String, _ kp: WritableKeyPath<StepMeta, Double?>, _ step: Int,
                          _ lo: Double, _ hi: Double, _ def: Double, _ fmt: @escaping (Double) -> String) -> some View {
        let cur = project.stepMeta[sel]?[step]?[keyPath: kp]
        let on = cur != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { project.setStepMeta(sel, step) { $0[keyPath: kp] = on ? nil : def } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: on ? "lock.fill" : "lock.open").font(.system(size: 10))
                        Text(label).font(FDFont.ui(12.5, .semibold))
                    }.foregroundStyle(on ? settings.accent : settings.inkDim)
                }.buttonStyle(.plain)
                Spacer()
                if on { Text(fmt(cur ?? def)).font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink) }
            }
            if on {
                Slider(value: Binding(get: { project.stepMeta[sel]?[step]?[keyPath: kp] ?? def },
                                      set: { v in project.setStepMeta(sel, step) { $0[keyPath: kp] = v } }), in: lo...hi).tint(settings.accent)
            }
        }
    }

    private func velBar(i: Int, v: Double, color: Color) -> some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(settings.panel2.darker(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(settings.line2, lineWidth: 1))
                RoundedRectangle(cornerRadius: 4).fill(color)
                    .frame(height: max(3, h * (v > 0 ? (0.12 + v * 0.88) : 0.08)))
                    .opacity(v > 0 ? 1 : 0.25)
            }
            // marker when this step has probability / condition / p-locks
            .overlay(alignment: .top) {
                if project.stepMeta[sel]?[i] != nil {
                    Circle().fill(settings.theme.perfect).frame(width: 5, height: 5).padding(.top, 2)
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { val in
                    if velDragStart == nil {
                        if v > 0 { velDragStart = v }
                        else { velDragStart = 0.85; engine.start(); project.triggerPad(sel) }
                    }
                    let nv = max(0.04, min(1, (velDragStart ?? 0.85) - val.translation.height / 70))
                    project.setStepVel(sel, i, nv)
                }
                .onEnded { _ in velDragStart = nil })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in editStep = i })
            // VoiceOver: the velocity drag never fires, so expose the bar as an adjustable control.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(Kit.padByID[sel]?.label ?? sel) step \(i + 1) velocity"))
            .accessibilityValue(Text("\(Int(v * 100)) percent"))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: project.setStepVel(sel, i, min(1, (v > 0 ? v : 0.04) + 0.05))
                case .decrement: project.setStepVel(sel, i, max(0.04, v - 0.05))
                default: break
                }
            }
            .accessibilityAction(named: Text("Edit step")) { editStep = i }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: automation lane (A11)

    private var autoLabel: String {
        switch project.autoTarget { case "filter": return "Filter"; case "reverb": return "Reverb"; case "delay": return "Delay"; default: return "Off" }
    }
    private func cycleAuto() {
        project.setAutoTarget(["", "filter", "reverb", "delay"].next(after: project.autoTarget))
    }

    private var automationLane: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AUTOMATION").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                Text(autoLabel.uppercased()).font(FDFont.mono(12, .bold)).foregroundStyle(settings.accent)
            }
            .frame(width: labelW, alignment: .leading)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<16, id: \.self) { i in
                    autoBar(i: i, v: i < project.autoLane.count ? project.autoLane[i] : 1)
                        .opacity(i < project.barSteps ? 1 : 0.28)
                        .allowsHitTesting(i < project.barSteps)
                }
            }
            .frame(height: 50)
        }
        .padding(.top, 8)
        .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .top)
        .frame(height: 66)
    }

    private func autoBar(i: Int, v: Double) -> some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(settings.panel2.darker(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(settings.line2, lineWidth: 1))
                RoundedRectangle(cornerRadius: 4).fill(settings.theme.perfect).frame(height: max(2, h * v))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { val in project.setAutoStep(i, Double(1 - val.location.y / h)) })
            // VoiceOver: the automation drag never fires, so expose the bar as an adjustable control.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(autoLabel) automation step \(i + 1)"))
            .accessibilityValue(Text("\(Int(v * 100)) percent"))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: project.setAutoStep(i, min(1, v + 0.05))
                case .decrement: project.setAutoStep(i, max(0, v - 0.05))
                default: break
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: actions

    private func paint(_ padID: String, _ col: Int) {
        if painting == nil {
            let on = (project.lanes[padID]?[col] ?? 0) != 0
            let val = on ? 0.0 : 0.85
            painting = (val, col)
            project.setStepVel(padID, col, val)
            if val > 0 { engine.start(); project.triggerPad(padID) }
        } else if let current = painting, current.lastCol != col {
            project.setStepVel(padID, col, current.val)
            if current.val > 0 { project.triggerPad(padID) }
            painting = (current.val, col)
        }
    }

    private func randomize() {
        var lane = Kit.emptyLane()
        let density = sel == "hatClosed" ? 0.55 : (sel == "kick" ? 0.3 : 0.35)
        for i in 0..<max(1, project.barSteps) where Double.random(in: 0..<1) < density { lane[i] = 0.5 + Double.random(in: 0..<0.5) }
        project.setRowLane(sel, lane)
    }
}
