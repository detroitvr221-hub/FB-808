//  SynthModeView.swift — the merged Synth Maker.
//  Knobs are the primary surface (oscillator / filter / amp envelope + scope),
//  and the play area toggles between a live Keyboard and the Piano Roll, so you
//  can either play the patch or "press out" notes into the loop. Both are driven
//  by the same knob-shaped patch.

import SwiftUI
import FD808Engine

struct SynthModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore

    @State private var playMode = "keys"     // "keys" | "roll"
    @State private var kbOct = 4
    @State private var lit: Set<Int> = []
    @State private var showHelp = false      // one toggle reveals every knob's "?" (declutter)
    @State private var detail: String?       // tapped-knob detail section: "filter" | "env" | "osc" | nil
    @State private var showBrowser = false   // full two-pane preset browser
    @State private var browseCat = "BASS"    // selected category in the browser
    @State private var toast: String?

    private func flashToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { if toast == msg { toast = nil } }
    }

    private var patch: SynthPatch { project.editPatch }                  // the active part's patch
    private func up<T>(_ kp: WritableKeyPath<SynthPatch, T>, _ v: T) { project.checkpoint("synth"); project.editPatch[keyPath: kp] = v }

    // In-scale keys for the song key/scale (used when Scale Lock is on).
    private var scaleKeys: [Int] {
        let intervals = Music.intervals(project.melodyScale)
        let root = kbOct * 12 + 12 + project.melodyKey
        var n: [Int] = []
        for o in 0..<2 { for iv in intervals { n.append(root + 12 * o + iv) } }
        n.append(root + 24)
        return n
    }
    private func keyDown(_ midi: Int) {
        engine.start()
        if !lit.contains(midi) { lit.insert(midi); project.synthNoteOn("k\(midi)", midi: midi) }
    }
    private func keyUp(_ midi: Int) {
        if lit.contains(midi) { lit.remove(midi); project.synthNoteOff("k\(midi)") }
    }

    var body: some View {
        VStack(spacing: 12) {
            TransportBar()
            VStack(alignment: .leading, spacing: 10) {
                presetBar
                HStack(alignment: .top, spacing: 14) {
                    rack
                    side.frame(width: 234)
                }
                .frame(maxHeight: 360)
                playArea
            }
        }
        .onAppear { if project.melody.isEmpty { project.generateMelody(checkpoint: false) } }
        .onDisappear { project.assistPanic() }   // stop the arp + release held notes when leaving
        .overlay { if showBrowser { presetBrowser } }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(settings.accent))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    // MARK: rack (knobs)

    private var rack: some View {
        VStack(spacing: 12) {
            sourceTabs
            HStack(spacing: 12) {
                soundCard
                scopeCard
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceTabs: some View {
        HStack(spacing: 8) {
            srcTab("Synth", "waveform.path", on: patch.source == "synth") { project.checkpoint("synth", coalesce: false); project.editPatch.source = "synth" }
            srcTab("Piano", "pianokeys", on: patch.source == "piano") { project.checkpoint("synth", coalesce: false); project.editPatch = SynthPresets.all.first { $0.name == "Rhodes EP" } ?? patch }
            srcTab("Sample", "waveform", on: patch.source == "sample" && patch.name != "Recorded Sound") { project.loadSampleSource("chop") }
            srcTab("Record", "mic.fill", on: patch.name == "Recorded Sound") { project.loadSampleSource("vocal") }
            srcTab("String", "guitars.fill", on: patch.source == "string") { project.checkpoint("synth", coalesce: false); project.editPatch = SynthPresets.all.first { $0.name == "Steel String" } ?? patch }
            Button { showHelp.toggle() } label: {
                Image(systemName: showHelp ? "questionmark.circle.fill" : "questionmark.circle").font(.system(size: 19))
                    .foregroundStyle(showHelp ? settings.accent : settings.inkFaint)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(showHelp ? settings.accent.opacity(0.18) : settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(showHelp ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
        }
    }
    private func srcTab(_ label: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(on ? settings.accent : settings.inkDim)
                Text(label).font(FDFont.ui(14, .semibold)).foregroundStyle(on ? settings.ink : settings.inkDim)
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? settings.accent.opacity(0.18) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var isSample: Bool { patch.source == "sample" }

    // MARK: prominent preset dropdown

    private var presetBar: some View {
        HStack(spacing: 8) {
            Text("Synth").font(FDFont.display(22, .bold)).foregroundStyle(settings.ink)
            Button { cyclePreset(-1) } label: { presetArrow("chevron.left") }
            Button { browseCat = categoryOfCurrent(); showBrowser = true } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(patch.color).frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(patch.name).font(FDFont.display(17, .bold)).foregroundStyle(settings.ink).lineLimit(1)
                        Text(categoryOfCurrent()).font(FDFont.mono(9, .bold)).tracking(0.6).foregroundStyle(settings.inkFaint)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 13)).foregroundStyle(settings.inkDim)
                }
                .padding(.horizontal, 14).frame(height: 46).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Button { cyclePreset(1) } label: { presetArrow("chevron.right") }
            Button { settings.addSavedSynth(project.editPatch) } label: { presetArrow("star") }
        }
    }
    private func presetArrow(_ icon: String) -> some View {
        Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(settings.inkDim)
            .frame(width: 46, height: 46)
            .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
    }
    private func applyPreset(_ p: SynthPatch) { project.checkpoint("synth", coalesce: false); project.editPatch = p }
    private func cyclePreset(_ dir: Int) {
        let all = SynthPresets.all
        let i = all.firstIndex { $0.name == patch.name } ?? 0
        applyPreset(all[((i + dir) % all.count + all.count) % all.count])
    }

    // MARK: two-pane preset browser (category → presets)

    private var browsePresets: [SynthPatch] {
        if browseCat == "SAVED" { return settings.savedSynths }
        return SynthPresets.categories.first { $0.name == browseCat }?.patches ?? []
    }

    private var presetBrowser: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { showBrowser = false }
            VStack(spacing: 0) {
                HStack {
                    Text("Choose a Sound").font(FDFont.display(19, .bold)).foregroundStyle(settings.ink)
                    Spacer()
                    Button { showBrowser = false } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(settings.inkDim)
                            .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                    }.buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 14))
                .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .bottom)
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(SynthPresets.categories, id: \.name) { cat in catRow(cat.name, cat.patches.count) }
                            if !settings.savedSynths.isEmpty { catRow("SAVED", settings.savedSynths.count) }
                        }.padding(10)
                    }
                    .frame(width: 200).scrollIndicators(.hidden)
                    Rectangle().fill(settings.line).frame(width: 1)
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(browsePresets, id: \.name) { p in presetBrowseRow(p) }
                        }.padding(10)
                    }.scrollIndicators(.hidden)
                }
            }
            .frame(width: 620, height: 500)
            .background(RoundedRectangle(cornerRadius: 22).fill(settings.panel))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(settings.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
    }

    private func catRow(_ name: String, _ count: Int) -> some View {
        let on = browseCat == name
        return Button { browseCat = name } label: {
            HStack(spacing: 8) {
                Text(name.capitalized).font(FDFont.ui(15, .semibold)).foregroundStyle(on ? settings.accent : settings.ink)
                Spacer()
                Text("\(count)").font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkFaint)
            }
            .padding(.horizontal, 12).frame(height: 42).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.14) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.4) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func presetBrowseRow(_ p: SynthPatch) -> some View {
        let on = patch.name == p.name
        return Button { applyPreset(p); engine.start(); project.previewNote(midi: 60) } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 4).fill(p.color).frame(width: 11, height: 11)
                Text(p.name).font(FDFont.ui(15, .semibold)).foregroundStyle(on ? settings.accent : settings.ink)
                Spacer()
                if on { Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(settings.accent) }
                else { Text(p.tag).font(FDFont.mono(9, .bold)).foregroundStyle(settings.inkFaint) }
            }
            .padding(.horizontal, 13).frame(height: 44).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.14) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: simplified sound card — wave + 4 primary knobs, tap any for its detail

    private var soundCard: some View {
        synthCard("Sound", flex: 3) {
            if !isSample {
                HStack(spacing: 5) {
                    ForEach([Wave.saw, .square, .triangle, .sine, .wavetable], id: \.self) { w in waveButton(w) }
                }
                HStack(spacing: 6) {
                    miniTog("UNISON", on: patch.unison) { up(\.unison, !patch.unison) }
                    miniTog("SUB", on: patch.sub) { up(\.sub, !patch.sub) }
                    Button { withAnimation(.easeOut(duration: 0.15)) { detail = detail == "osc" ? nil : "osc" } } label: { moreTile("Tune & FM", on: detail == "osc") }
                }
            } else {
                CoachNote("Playing **\(patch.name)** as a pitched sampler — every key repitches the clip.")
            }
            HStack(alignment: .top, spacing: 12) {
                knob("Brightness", patch.cutoff, 80, 12000, 20, fmt: fmtHz, info: Glossary.cutoff, sub: "tap → filter", size: 62, onTap: { tapDetail("filter") }) { up(\.cutoff, $0) }
                knob("Attack", patch.attack, 0.002, 2, 0.002, fmt: fmtMs, info: Glossary.attack, sub: "tap → env", size: 62, onTap: { tapDetail("env") }) { up(\.attack, $0) }
                knob("Length", patch.release, 0.02, 2.5, 0.01, fmt: fmtMs, info: Glossary.release, sub: "tap → env", size: 62, onTap: { tapDetail("env") }) { up(\.release, $0) }
                knob("Volume", patch.level, 0, 1, 0.01, fmt: fmtPct, info: Glossary.level, sub: "level", size: 62) { up(\.level, $0) }
                Spacer(minLength: 0)
            }
            if let d = detail { detailPanel(d) }
        }
    }

    private func waveButton(_ w: Wave) -> some View {
        Button { up(\.wave, w) } label: {
            WaveShape(wave: w).stroke(patch.wave == w ? settings.accent : settings.inkDim, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(height: 13).padding(.horizontal, 3)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(patch.wave == w ? settings.accent.opacity(0.16) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(patch.wave == w ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func moreTile(_ label: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 11))
            Text(label).font(FDFont.mono(9.5, .bold))
        }
        .foregroundStyle(on ? .white : settings.inkDim)
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? settings.accent : settings.panel2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.clear : settings.line, lineWidth: 1))
    }
    private func tapDetail(_ id: String) { withAnimation(.easeOut(duration: 0.15)) { detail = detail == id ? nil : id } }

    @ViewBuilder private func detailPanel(_ d: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(d == "filter" ? "FILTER" : d == "env" ? "ENVELOPE" : "OSCILLATOR").font(FDFont.mono(9, .bold)).tracking(1.2).foregroundStyle(settings.accent)
                Spacer()
                Button { tapDetail(d) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(settings.inkFaint) }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 10) {
                switch d {
                case "filter":
                    knob("Bite", patch.reso, 0, 18, 0.5, fmt: { String(format: "%.1f", $0) }, info: Glossary.resonance, sub: "reso", size: 48) { up(\.reso, $0) }
                    knob("Sweep", patch.filterEnv, 0, 1, 0.01, fmt: fmtPct, info: Glossary.filterEnv, sub: "filter env", size: 48) { up(\.filterEnv, $0) }
                    knob("Grit", patch.drive, 0, 1, 0.01, fmt: fmtPct, info: Glossary.drive, sub: "drive", size: 48) { up(\.drive, $0) }
                case "env":
                    knob("Decay", patch.decay, 0.01, 2, 0.01, fmt: fmtMs, info: Glossary.decay, sub: "fall", size: 48) { up(\.decay, $0) }
                    knob("Sustain", patch.sustain, 0, 1, 0.01, fmt: fmtPct, info: Glossary.sustain, sub: "hold", size: 48) { up(\.sustain, $0) }
                default:
                    if !isSample { knob("Detune", patch.detune, 0, 40, 1, fmt: { "\(Int($0))¢" }, info: Glossary.detune, sub: "spread", size: 48) { up(\.detune, $0) } }
                    knob("Octave", Double(patch.octave), -2, 2, 1, fmt: { ($0 > 0 ? "+" : "") + "\(Int($0))" }, info: Glossary.octave, sub: "pitch", size: 48) { up(\.octave, Int($0)) }
                    knob("Glide", patch.glide, 0, 0.3, 0.005, fmt: fmtMs, info: Glossary.glide, sub: "slide", size: 48) { up(\.glide, $0) }
                    knob("FM", patch.fmAmountV, 0, 1, 0.01, fmt: fmtPct, info: Glossary.fmAmount, sub: "metallic", size: 48) { up(\.fmAmountV, $0) }
                    knob("Ratio", patch.fmRatioV, 0.5, 8, 0.5, fmt: { String(format: "%.1f", $0) }, info: Glossary.fmRatio, sub: "fm tone", size: 48) { up(\.fmRatioV, $0) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2.darker(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accent.opacity(0.3), lineWidth: 1))
    }

    private var scopeCard: some View {
        synthCard("Scope", flex: 1.1) {
            ScopeView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 11).fill(settings.panel2.darker(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.line2, lineWidth: 1))
        }
    }

    private func synthCard<C: View>(_ title: String, flex: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
            content()
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(Double(flex))
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }

    private func knob(_ label: String, _ value: Double, _ lo: Double, _ hi: Double, _ step: Double,
                      fmt: @escaping (Double) -> String, info: String? = nil, sub: String? = nil,
                      size: CGFloat = 56, onTap: (() -> Void)? = nil, _ onChange: @escaping (Double) -> Void) -> some View {
        KnobView(label: label, value: value, min: lo, max: hi, step: step, color: settings.accent, format: fmt,
                 onChange: onChange, info: showHelp ? info : nil, sub: sub, size: size, onTap: onTap)
    }

    private func miniTog(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.mono(10, .bold)).tracking(0.5).foregroundStyle(on ? .white : settings.inkFaint)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: side (presets + save)

    private var side: some View {
        ScrollView {
            VStack(spacing: 12) {
                playAssistCard
                PanelCard(title: "Instrument Layers") {
                    VStack(spacing: 5) {
                        ForEach(project.partList, id: \.id) { p in partRow(p) }
                    }
                    HStack(spacing: 6) {
                        layerGenBtn("Bass") { engine.start(); project.genBassLayer() }
                        layerGenBtn("Chords") { engine.start(); project.genChordLayer() }
                        layerGenBtn("Arp") { engine.start(); project.genArpLayer() }
                    }
                    Text("Each layer is its own instrument — tap to edit its notes & knobs; the others show as ghosts in the roll.")
                        .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                }
                PanelCard(title: "Save & Map") {
                    TextField("Patch name", text: Binding(get: { project.editPatch.name }, set: { project.editPatch.name = $0 }))
                        .font(FDFont.display(15, .semibold)).foregroundStyle(settings.ink)
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
                    Button { project.mapSynthToPads(); flashToast("Mapped this sound across Bank D — finger-drum it on the Pads") } label: {
                        Text("→ Map to Pads (Bank D)").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.24)], startPoint: .top, endPoint: .bottom)))
                    }.buttonStyle(.plain)
                    Button {
                        let id = project.promotePartToTrack(project.activePart)
                        if !id.isEmpty { progress.awardCreative("sendTrack", 6) }
                        flashToast(id.isEmpty ? "Draw some notes in the roll first — nothing to send"
                                              : "Promoted this part to its own track — arrange it in Tracks")
                    } label: {
                        Text("→ Send to New Track").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(LinearGradient(colors: [Color(hex: "#21D0B2"), Color(hex: "#21D0B2").darker(0.24)], startPoint: .top, endPoint: .bottom)))
                    }.buttonStyle(.plain)
                    Button { settings.addSavedSynth(project.editPatch) } label: {
                        Text("★ Save to Synth Bank").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: 11).fill(settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Play Assist (chord mode + arpeggiator, Domain E)

    private var playAssistCard: some View {
        PanelCard(title: "Play Assist") {
            Text("CHORD").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            assistSeg([("off", "Off"), ("triad", "Triad"), ("7th", "7th"), ("power", "5th"), ("octave", "Oct")], sel: project.chordMode) {
                project.chordMode = $0
            }
            Text("ARPEGGIATOR").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint).padding(.top, 2)
            assistSeg([("off", "Off"), ("up", "Up"), ("down", "Down"), ("updown", "Up-Dn"), ("random", "Rnd")], sel: project.arpMode) {
                project.arpMode = $0
                if $0 == "off" { project.assistPanic() } else if !project.assistHeld.isEmpty { project.restartArp() }
            }
            if project.arpMode != "off" {
                assistSeg([("1/8", "⅛"), ("1/16", "1/16"), ("1/16T", "16T"), ("1/32", "1/32")], sel: project.arpRate) {
                    project.arpRate = $0; if !project.assistHeld.isEmpty { project.restartArp() }
                }
                HStack(spacing: 5) {
                    Text("OCT").font(FDFont.mono(9, .bold)).foregroundStyle(settings.inkFaint)
                    ForEach(1...3, id: \.self) { o in
                        Button { project.arpOct = o; if !project.assistHeld.isEmpty { project.restartArp() } } label: {
                            Text("\(o)").font(FDFont.mono(11, .bold)).foregroundStyle(project.arpOct == o ? .white : settings.inkDim)
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 8).fill(project.arpOct == o ? settings.accent : settings.panel2))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(project.arpOct == o ? Color.clear : settings.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Hold keys — **Chord** plays the scale's triad; **Arp** rolls them in time at \(project.bpm) BPM.")
                .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func partRow(_ p: (id: String, name: String, muted: Bool, color: Color)) -> some View {
        let active = project.activePart == p.id
        return HStack(spacing: 6) {
            Button { project.selectPart(p.id) } label: {
                HStack(spacing: 7) {
                    Circle().fill(p.color).frame(width: 9, height: 9)
                    Text(p.name).font(FDFont.ui(12.5, .semibold)).foregroundStyle(active ? settings.ink : settings.inkDim)
                    Spacer(minLength: 2)
                    if active { Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(settings.accent) }
                }
                .padding(.horizontal, 9).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(active ? settings.accent.opacity(0.14) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Button { project.togglePartMute(p.id) } label: {
                Image(systemName: p.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 11))
                    .foregroundStyle(p.muted ? settings.theme.miss : settings.inkFaint)
                    .frame(width: 28, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 8).stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            if p.id != "lead" {
                Button { project.removePart(p.id) } label: {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(settings.inkFaint)
                        .frame(width: 26, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 8).stroke(settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private func layerGenBtn(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(label).font(FDFont.ui(12.5, .semibold))
            }
            .foregroundStyle(settings.accent)
            .frame(maxWidth: .infinity).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.accent.opacity(0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func assistSeg(_ opts: [(String, String)], sel: String, _ action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(opts, id: \.0) { (id, label) in
                Button { action(id) } label: {
                    Text(label).font(FDFont.mono(10, .bold)).foregroundStyle(sel == id ? .white : settings.inkDim)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(sel == id ? settings.accent : settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel == id ? Color.clear : settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    /// The category that holds the currently-selected patch (so it opens by default).
    private func categoryOfCurrent() -> String {
        for cat in SynthPresets.categories where cat.patches.contains(where: { $0.name == patch.name }) { return cat.name }
        if settings.savedSynths.contains(where: { $0.name == patch.name }) { return "SAVED" }
        return SynthPresets.categories.first?.name ?? "BASS"
    }

    // MARK: play area (keyboard <-> roll)

    private var playArea: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                segTab("Keyboard", "pianokeys", on: playMode == "keys") { playMode = "keys" }
                segTab("Piano Roll", "square.grid.3x2.fill", on: playMode == "roll") { playMode = "roll" }
                segTab("Free", "scribble.variable", on: playMode == "free") { playMode = "free" }
                Spacer()
                if playMode == "roll" { rollToolbar }
            }
            switch playMode {
            case "keys": keyboardArea
            case "free": FreeRollView()
            default:     SynthRoll()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func segTab(_ label: String, _ icon: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(FDFont.ui(13.5, .semibold))
            }
            .foregroundStyle(on ? settings.ink : settings.inkDim)
            .padding(.horizontal, 16).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.18) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // the design's ".keys-side" panel: octave control + lock/key/scale + hint
    private var keysSide: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                octBtn("–") { kbOct = max(1, kbOct - 1) }
                Text("C\(kbOct)").font(FDFont.mono(15, .bold)).foregroundStyle(settings.ink).frame(maxWidth: .infinity)
                octBtn("+") { kbOct = min(6, kbOct + 1) }
            }
            sideToggle(project.scaleLock ? "lock.fill" : "lock.open", "Scale Lock", on: project.scaleLock) { project.scaleLock.toggle() }
            sideCycle("Key", Music.noteNames[project.melodyKey]) { project.checkpoint("key", coalesce: false); project.melodyKey = (project.melodyKey + 1) % 12; project.generateMelody() }
            sideCycle("Scale", Music.scales.first { $0.id == project.melodyScale }?.name ?? "Major") {
                project.checkpoint("key", coalesce: false)
                let i = Music.scales.firstIndex { $0.id == project.melodyScale } ?? 0
                project.melodyScale = Music.scales[(i + 1) % Music.scales.count].id; project.generateMelody()
            }
            Text(project.scaleLock ? "Every key stays in \(Music.noteNames[project.melodyKey]) \(Music.scales.first { $0.id == project.melodyScale }?.name ?? ""). Map a patch to pads to finger-drum it."
                                   : "Play the keys. Map a patch to pads (Bank D) to finger-drum it.")
                .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(width: 132)
    }

    private func octBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 19, weight: .bold)).foregroundStyle(settings.ink)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func sideToggle(_ icon: String, _ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(FDFont.ui(13, .semibold))
                Spacer()
            }
            .foregroundStyle(on ? settings.ink : settings.inkDim)
            .padding(.horizontal, 12).frame(height: 36).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.2) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func sideCycle(_ label: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                Spacer()
                Text(value).font(FDFont.mono(12.5, .bold)).foregroundStyle(settings.accent)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private var rollToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(settings.inkFaint)
                ForEach([(1, "1/16"), (2, "1/8"), (4, "1/4"), (8, "1/2"), (16, "1/1")], id: \.0) { (len, lbl) in
                    Button { project.rollLen = len } label: {
                        Text(lbl).font(FDFont.mono(11, .bold)).foregroundStyle(project.rollLen == len ? .white : settings.inkDim)
                            .padding(.horizontal, 8).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(project.rollLen == len ? settings.accent : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(project.rollLen == len ? .clear : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Button { engine.start(); project.checkpoint("genMelody", coalesce: false); project.generateMelody() } label: {
                Text("✦ Generate").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.22)], startPoint: .top, endPoint: .bottom)))
            }.buttonStyle(.plain)
            Button { project.clearMelody() } label: {
                Text("Clear").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            rollCycle("Key", Music.noteNames[project.melodyKey]) { project.checkpoint("key", coalesce: false); project.melodyKey = (project.melodyKey + 1) % 12; project.generateMelody() }
            rollCycle("Scale", Music.scales.first { $0.id == project.melodyScale }?.name ?? "Major") {
                project.checkpoint("key", coalesce: false)
                let i = Music.scales.firstIndex { $0.id == project.melodyScale } ?? 0
                project.melodyScale = Music.scales[(i + 1) % Music.scales.count].id; project.generateMelody()
            }
        }
    }
    private func rollCycle(_ label: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            styledText([("\(label) ", settings.inkDim, nil), (value, settings.accent, nil)])
                .font(FDFont.ui(12.5, .semibold))
                .padding(.horizontal, 11).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func stepperBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 17, weight: .bold)).foregroundStyle(settings.inkDim)
                .frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var keyboardArea: some View {
        HStack(spacing: 14) {
            keysSide
            Group {
                if project.scaleLock {
                    ScaleKeyboard(notes: scaleKeys, key: project.melodyKey, lit: lit, onDown: keyDown, onUp: keyUp)
                } else {
                    SynthKeyboard(base: kbOct * 12 + 12, octaves: 2, lit: lit, onDown: keyDown, onUp: keyUp)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }
}

// MARK: - In-key scale keyboard (every key is a scale tone)

struct ScaleKeyboard: View {
    @EnvironmentObject var settings: AppSettings
    let notes: [Int]
    let key: Int
    let lit: Set<Int>
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void
    @State private var current: Int?     // currently-held midi (one gesture for the whole keyboard → correct hit-testing + slides)

    var body: some View {
        GeometryReader { g in
            let slot = g.size.width / CGFloat(max(1, notes.count))
            HStack(spacing: 3) {
                ForEach(Array(notes.enumerated()), id: \.offset) { (_, midi) in keyView(midi) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let idx = max(0, min(notes.count - 1, Int(v.location.x / slot)))
                    let midi = notes[idx]
                    if current != midi { if let c = current { onUp(c) }; current = midi; onDown(midi) }
                }
                .onEnded { _ in if let c = current { onUp(c); current = nil } })
        }
    }

    private func keyView(_ midi: Int) -> some View {
        let isRoot = ((midi - key) % 12 + 12) % 12 == 0
        let down = lit.contains(midi)
        let cream: [Color] = isRoot ? [Color(hex: "#fff3e9"), Color(hex: "#f0d9c4")] : [Color(hex: "#fbfaf6"), Color(hex: "#e6e3d8")]
        return UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
            .fill(down ? LinearGradient(colors: [settings.accent.lighter(0.3), settings.accent], startPoint: .top, endPoint: .bottom)
                       : LinearGradient(colors: cream, startPoint: .top, endPoint: .bottom))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .center, endPoint: .bottom)))
            .overlay(alignment: .top) {
                if isRoot && !down { RoundedRectangle(cornerRadius: 2).fill(settings.accent).frame(height: 4).padding(.horizontal, 6).padding(.top, 5) }
            }
            .overlay(alignment: .bottom) {
                Text(Music.noteNames[((midi % 12) + 12) % 12])
                    .font(FDFont.mono(9, isRoot ? .bold : .regular))
                    .foregroundStyle(down ? .white : .black.opacity(isRoot ? 0.6 : 0.38))
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Formatters

private func fmtHz(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))" }
private func fmtMs(_ v: Double) -> String { v < 1 ? "\(Int(v * 1000))" : String(format: "%.1fs", v) }
private func fmtPct(_ v: Double) -> String { "\(Int(v * 100))" }

// MARK: - Knob

struct KnobView: View {
    let label: String
    let value: Double
    let min: Double
    let max: Double
    let step: Double
    let color: Color
    let format: (Double) -> String
    let onChange: (Double) -> Void
    var info: String? = nil
    var sub: String? = nil       // technical sub-name shown under the plain label
    var size: CGFloat = 50       // dial diameter
    var onTap: (() -> Void)? = nil   // fired on a tap (no drag) — used to reveal detail controls
    @EnvironmentObject var settings: AppSettings
    @State private var dragStart: Double?
    @State private var moved = false

    private var n: Double { Swift.max(0, Swift.min(1, (value - min) / (max - min))) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(settings.panel2.darker(0.1)).overlay(Circle().stroke(settings.line, lineWidth: 1))
                Circle().trim(from: 0, to: 0.75).stroke(settings.line.opacity(1), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135)).padding(4)
                Circle().trim(from: 0, to: 0.75 * n).stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135)).padding(4)
                Circle().fill(RadialGradient(colors: [settings.panel2, settings.panel2.darker(0.36)], center: .init(x: 0.5, y: 0.34), startRadius: 0, endRadius: 24))
                    .padding(9)
                Capsule().fill(color).frame(width: 2.5, height: size * 0.22)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + n * 270))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if Swift.abs(v.translation.height) > 4 || Swift.abs(v.translation.width) > 4 { moved = true }
                    if dragStart == nil { dragStart = value }
                    guard moved else { return }   // a tap (no movement) shouldn't nudge the value
                    var nv = (dragStart ?? value) - (v.translation.height / 160) * (max - min)
                    if step > 0 { nv = (nv / step).rounded() * step }
                    onChange(Swift.max(min, Swift.min(max, nv)))
                }
                .onEnded { _ in
                    if !moved, let onTap { onTap() }   // tapped, not dragged → open detail
                    dragStart = nil; moved = false
                })
            Text(format(value)).font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
            VStack(spacing: 0) {
                Text(label.uppercased()).font(FDFont.mono(9, .bold)).tracking(0.5).foregroundStyle(settings.inkDim)
                if let sub { Text(sub).font(FDFont.mono(7.5)).tracking(0.3).foregroundStyle(settings.inkFaint).lineLimit(1) }
            }
        }
        .frame(width: size + 16)
        .overlay(alignment: .topTrailing) {
            if let info { InfoTip(term: label, detail: info, size: 15).offset(x: 3, y: -1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(format(value)))
        .accessibilityAdjustableAction { dir in
            let d = step > 0 ? step : (max - min) / 20
            switch dir {
            case .increment: onChange(Swift.min(max, value + d))
            case .decrement: onChange(Swift.max(min, value - d))
            default: break
            }
        }
    }
}

// MARK: - Wave glyph

struct WaveShape: Shape {
    let wave: Wave
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, mid = r.midY
        switch wave {
        case .saw:
            p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w * 0.33, y: 0))
            p.addLine(to: CGPoint(x: w * 0.33, y: h)); p.addLine(to: CGPoint(x: w * 0.66, y: 0))
            p.addLine(to: CGPoint(x: w * 0.66, y: h)); p.addLine(to: CGPoint(x: w, y: 0))
        case .square:
            p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w * 0.33, y: 0)); p.addLine(to: CGPoint(x: w * 0.33, y: h))
            p.addLine(to: CGPoint(x: w * 0.66, y: h)); p.addLine(to: CGPoint(x: w * 0.66, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
        case .triangle:
            p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w * 0.25, y: 0))
            p.addLine(to: CGPoint(x: w * 0.5, y: mid)); p.addLine(to: CGPoint(x: w * 0.75, y: h))
            p.addLine(to: CGPoint(x: w, y: mid))
        case .sine:
            p.move(to: CGPoint(x: 0, y: mid))
            let steps = 24
            for i in 0...steps {
                let x = w * Double(i) / Double(steps)
                let y = mid - sin(Double(i) / Double(steps) * 2 * .pi) * h * 0.42
                p.addLine(to: CGPoint(x: x, y: y))
            }
        case .wavetable:
            p.move(to: CGPoint(x: 0, y: mid))
            let steps = 40
            for i in 0...steps {
                let ph = Double(i) / Double(steps)
                let s = sin(2 * .pi * ph) + 0.5 * sin(4 * .pi * ph) + 0.33 * sin(6 * .pi * ph)
                p.addLine(to: CGPoint(x: w * ph, y: mid - s / 1.83 * h * 0.42))
            }
        }
        return p
    }
}

// MARK: - Oscilloscope

struct ScopeView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                let samples = engine.scopeSnapshot()
                guard samples.count > 1 else { return }
                var path = Path()
                let mid = size.height / 2
                let n = samples.count
                for x in 0..<Int(size.width) {
                    let si = Swift.min(n - 1, x * n / Swift.max(1, Int(size.width)))
                    let y = mid - Double(samples[si]) * size.height * 0.42
                    let pt = CGPoint(x: Double(x), y: y)
                    if x == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(settings.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }
}

// MARK: - Piano roll (programs notes into the synth track)

struct SynthRoll: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @State private var drawDrag: (pitch: Int, start: Int)?   // active draw; start = -1 means erasing

    private var ladder: [Int] {
        let intervals = Music.intervals(project.melodyScale)
        let base = 60 + project.melodyKey + 12 * project.melodyOctave
        var l: [Int] = []
        for o in 0..<2 { for iv in intervals { l.append(base + 12 * o + iv) } }
        l.append(base + 24)
        return l.reversed()
    }
    // Polyphonic: a note covers cell key = pitch*16 + step. `startVel` carries each note's velocity.
    private func rollData() -> (covered: Set<Int>, startVel: [Int: Double]) {
        var covered = Set<Int>(), startVel = [Int: Double]()
        for note in project.activeNotes {
            for k in 0..<note.dur {
                let c = note.step + k
                if c < 16 { covered.insert(note.pitch * 16 + c); if k == 0 { startVel[note.pitch * 16 + c] = note.vel } }
            }
        }
        return (covered, startVel)
    }
    /// Cells occupied by the OTHER instrument parts — drawn as faint ghosts (Tier 2 layering).
    private func otherCells() -> Set<Int> {
        var s = Set<Int>()
        var arrays = project.parts.filter { $0.id != project.activePart }.map { $0.notes }
        if project.activePart != "lead" { arrays.append(project.melody) }
        for arr in arrays { for n in arr { for k in 0..<n.dur { let c = n.step + k; if c < 16 { s.insert(n.pitch * 16 + c) } } } }
        return s
    }

    /// Drum "ghost" behind the roll: kick = warm, snare = amber — shows the groove so
    /// melodies you write lock to the beat (FL-style ghost notes, Tier 1).
    private func ghost(_ s: Int, _ kick: [Double], _ snare: [Double]) -> Color? {
        if s < kick.count && kick[s] > 0 { return Color(hex: "#FF5A3C") }
        if s < snare.count && snare[s] > 0 { return Color(hex: "#FFC23C") }
        return nil
    }

    var body: some View {
        let data = rollData()
        let others = otherCells()
        let color = project.editPatch.color
        let kick = project.lanes["kick"] ?? []
        let snare = project.lanes["snare"] ?? []
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ladder, id: \.self) { pitch in
                        HStack(spacing: 2) {
                            Text(Music.noteNames[((pitch % 12) + 12) % 12])
                                .font(FDFont.mono(8, .bold)).foregroundStyle(settings.inkFaint)
                                .frame(width: 28, alignment: .trailing)
                            GeometryReader { g in
                                HStack(spacing: 2) {
                                    ForEach(0..<16, id: \.self) { s in
                                        let key = pitch * 16 + s
                                        cell(pitch: pitch, s: s, covered: data.covered.contains(key), startVel: data.startVel[key], other: others.contains(key), color: color, ghost: ghost(s, kick, snare))
                                    }
                                }
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { v in rowDrag(pitch, v.location.x, g.size.width) }
                                    .onEnded { _ in drawDrag = nil })
                            }
                            .frame(height: 16)
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            velocityLane(color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }

    /// Click-drag in a pitch row: tap an empty cell to draw a 1-step note, drag right to lengthen,
    /// tap an existing note to erase it. (Per-note length — FL-style draw.)
    private func rowDrag(_ pitch: Int, _ x: CGFloat, _ width: CGFloat) {
        let cell = max(0, min(15, Int(x / max(1.0, width / 16.0))))
        if drawDrag == nil {
            engine.start()
            if project.activeNotes.contains(where: { $0.pitch == pitch && cell >= $0.step && cell < $0.step + $0.dur }) {
                project.eraseActiveNote(pitch: pitch, step: cell); drawDrag = (pitch, -1)
            } else {
                drawDrag = (pitch, cell)
                project.drawActiveNote(pitch: pitch, start: cell, len: 1)
                project.previewNote(midi: pitch)
            }
        } else if drawDrag!.start >= 0 {
            project.drawActiveNote(pitch: drawDrag!.pitch, start: drawDrag!.start, len: max(1, cell - drawDrag!.start + 1))
        }
    }

    private func velocityLane(_ color: Color) -> some View {
        HStack(spacing: 2) {
            Text("VEL").font(FDFont.mono(7.5, .bold)).foregroundStyle(settings.inkFaint).frame(width: 28, alignment: .trailing)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<16, id: \.self) { s in
                        let v = project.activeNoteVel(at: s)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(settings.panel2.darker(0.1))
                            if v > 0 { RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.85)).frame(height: max(2, CGFloat(v) * 34)) }
                        }.frame(maxWidth: .infinity)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { dv in
                    let s = max(0, min(15, Int(dv.location.x / max(1.0, g.size.width / 16.0))))
                    let frac = max(0.0, min(1.0, Double(dv.location.y) / 34.0))
                    project.setActiveNoteVel(step: s, 1.0 - frac)
                })
            }.frame(height: 34)
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func cell(pitch: Int, s: Int, covered: Bool, startVel: Double?, other: Bool, color: Color, ghost: Color?) -> some View {
        let beat = s % 4 == 0
        let ph = project.step == s && project.playing
        let root = ((pitch - project.melodyKey) % 12 + 12) % 12 == 0
        let baseFill = root ? settings.panel2.darker(0.02) : (beat ? settings.panel2.darker(0.06) : settings.panel2.darker(0.14))
        // start cells brighten with velocity; continuation cells are dimmer
        let coverFill = startVel.map { color.opacity(0.5 + 0.5 * $0) } ?? color.opacity(0.55)
        return RoundedRectangle(cornerRadius: 4)
            .fill(covered ? coverFill : (ghost?.opacity(0.16) ?? baseFill))
            .overlay { if other && !covered { RoundedRectangle(cornerRadius: 4).fill(settings.inkFaint.opacity(0.4)) } }   // ghost of the other parts
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(ph ? settings.accent.opacity(0.7) : settings.line2, lineWidth: ph ? 1.5 : 1))
            .frame(maxWidth: .infinity).frame(height: 16)
            .contentShape(Rectangle())
    }
}

// MARK: - Sustained piano keyboard

struct SynthKeyboard: View {
    @EnvironmentObject var settings: AppSettings
    let base: Int
    let octaves: Int
    let lit: Set<Int>
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void

    private let whiteSemis = [0, 2, 4, 5, 7, 9, 11]
    private let blackMap: [(Int, Int)] = [(0, 1), (1, 3), (3, 6), (4, 8), (5, 10)]
    @State private var current: Int?

    var body: some View {
        GeometryReader { g in
            let nW = 7 * octaves
            let slot = g.size.width / CGFloat(nW)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach(0..<nW, id: \.self) { i in
                        whiteKey(base + 12 * (i / 7) + whiteSemis[i % 7])
                    }
                }
                ForEach(blackKeys(), id: \.0) { (midi, gw) in
                    blackKey(midi, w: slot * 0.58, x: CGFloat(gw + 1) * slot, h: g.size.height * 0.6)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let midi = midiAt(v.location, g.size, slot: slot)
                    if current != midi { if let c = current { onUp(c) }; current = midi; onDown(midi) }
                }
                .onEnded { _ in if let c = current { onUp(c); current = nil } })
        }
    }
    /// Hit-test a touch → key. Black keys win in the upper 60%, else the white key under x.
    private func midiAt(_ loc: CGPoint, _ size: CGSize, slot: CGFloat) -> Int {
        let nW = 7 * octaves
        if loc.y < size.height * 0.6 {
            for (midi, gw) in blackKeys() where abs(loc.x - CGFloat(gw + 1) * slot) < slot * 0.32 { return midi }
        }
        let i = max(0, min(nW - 1, Int(loc.x / slot)))
        return base + 12 * (i / 7) + whiteSemis[i % 7]
    }
    private func blackKeys() -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for o in 0..<octaves { for (d, semi) in blackMap { out.append((base + 12 * o + semi, o * 7 + d)) } }
        return out
    }
    private func whiteKey(_ midi: Int) -> some View {
        let down = lit.contains(midi)
        let isC = midi % 12 == 0
        return UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
            .fill(down ? LinearGradient(colors: [settings.accent.lighter(0.3), settings.accent], startPoint: .top, endPoint: .bottom)
                       : LinearGradient(colors: [Color(hex: "#fbfaf6"), Color(hex: "#e6e3d8")], startPoint: .top, endPoint: .bottom))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .center, endPoint: .bottom)))
            .overlay(alignment: .bottom) {
                Text(isC ? Music.name(midi) : Music.noteNames[midi % 12])
                    .font(FDFont.mono(8.5, isC ? .bold : .regular))
                    .foregroundStyle(down ? .white : .black.opacity(isC ? 0.55 : 0.34)).padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
            .allowsHitTesting(false)
    }
    private func blackKey(_ midi: Int, w: CGFloat, x: CGFloat, h: CGFloat) -> some View {
        let down = lit.contains(midi)
        return UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5)
            .fill(down ? LinearGradient(colors: [settings.accent.darker(0.1), settings.accent.darker(0.38)], startPoint: .top, endPoint: .bottom)
                       : LinearGradient(colors: [Color(hex: "#2a2a32"), Color(hex: "#111116")], startPoint: .top, endPoint: .bottom))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5).stroke(.white.opacity(0.06), lineWidth: 1))
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
            .position(x: x, y: h / 2)
            .allowsHitTesting(false)
    }
}
