//  PadInspectorView.swift — the per-pad editor referenced across the app.
//  Long-press a pad (or tap Edit) to retune, shape, choke, layer, recolor & rename.
//  Ported from mode-pad-inspector.jsx; audio-wired through PadParam / TriggerOpts.

import SwiftUI
import FD808Engine
import UniformTypeIdentifiers

private let PI_COLORS = ["#FF5A3C", "#FF7A1A", "#FFC23C", "#FFD84D", "#7AE582", "#33E0D4",
                        "#27C2E8", "#5B8DEF", "#6C7BFF", "#9B8CFF", "#C77DFF", "#E879F9", "#FF7AC6"]
private let PI_MODES = [("oneshot", "One-Shot"), ("gate", "Gate"), ("loop", "Hold")]

private func piSemi(_ v: Double) -> String { (v > 0 ? "+" : "") + "\(Int(v.rounded()))" }
private func piHz(_ v: Double) -> String { v >= 17999 ? "OPEN" : (v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v))") }
private func piMs(_ v: Double) -> String { v < 1 ? "\(Int(v * 1000))m" : String(format: "%.2fs", v) }
private func piPct(_ v: Double) -> String { "\(Int(v * 100))" }
private func piPan(_ v: Double) -> String { Music.panLabel(v) }

struct PadInspectorView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    let pad: PadDef
    var onClose: () -> Void

    @State private var previewFlash = false
    @State private var showImporter = false
    @State private var importError: String?

    private var pp: PadParam { project.getPadParam(pad.id) }
    private var label: String { pp.label ?? pad.label }
    private var color: Color { pp.color ?? pad.color }
    private var dirty: Bool { project.padParams[pad.id] != nil }
    private func up(_ mutate: @escaping (inout PadParam) -> Void) { project.setPadParam(pad.id, mutate) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .accessibilityHidden(true)
            modal
                .frame(maxWidth: 880)
                .padding(20)
                .accessibilityAddTraits(.isModal)
        }
    }

    private var modal: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 14) {
                leftColumn.frame(width: 264)
                rightColumn
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(color.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false, onCompletion: importSample)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PAD EDITOR · \(pad.key)").font(FDFont.mono(10, .bold)).tracking(1.6).foregroundStyle(settings.accent)
                TextField("Name", text: Binding(get: { label }, set: { v in up { $0.label = String(v.prefix(12)).uppercased() } }))
                    .font(FDFont.display(24, .bold)).foregroundStyle(settings.ink)
                    .textFieldStyle(.plain)
            }
            Spacer()
            Button { project.clearPadParam(pad.id) } label: {
                Text("Reset").font(FDFont.ui(13, .semibold)).foregroundStyle(dirty ? settings.ink : settings.inkFaint)
                    .padding(.horizontal, 14).frame(height: 34)
                    .fdCard(10, fill: settings.panel2)
            }.buttonStyle(.plain).disabled(!dirty).opacity(dirty ? 1 : 0.5)
            Button { onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(settings.inkDim)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
            }.buttonStyle(.plain).padding(.leading, 8)
            .accessibilityLabel("Close pad editor")
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 16))
        .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .bottom)
    }

    // MARK: left

    private var leftColumn: some View {
        VStack(spacing: 12) {
            // preview pad
            Button {
                engine.start(); project.triggerPad(pad.id)
                previewFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { previewFlash = false }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [settings.theme.capA, settings.theme.capB], startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 18).fill(RadialGradient(colors: [color.opacity(previewFlash ? 0.8 : 0.35), .clear], center: .center, startRadius: 0, endRadius: 90))
                    RoundedRectangle(cornerRadius: 18).stroke(color, lineWidth: 2)
                    VStack(spacing: 6) {
                        Text(label).font(FDFont.mono(15, .bold)).foregroundStyle(settings.ink)
                        Text("TAP TO HEAR").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                    }
                    RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 13, height: 13)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
                }
                .frame(height: 116)
            }.buttonStyle(.plain)
            .scaleEffect(previewFlash ? 0.97 : 1).animation(.easeOut(duration: 0.12), value: previewFlash)

            card("Color") {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 7), count: 7)
                LazyVGrid(columns: cols, spacing: 7) {
                    ForEach(PI_COLORS, id: \.self) { hex in
                        Button { up { $0.colorHex = hex } } label: {
                            Circle().fill(Color(hex: hex)).frame(height: 24)
                                .overlay(Circle().stroke(.white, lineWidth: (pp.colorHex ?? colorHexOf(pad.color)) == hex ? 2.5 : 0))
                        }.buttonStyle(.plain)
                    }
                }
            }

            card("Playback") {
                seg(PI_MODES, selected: pp.mode) { v in up { $0.mode = v } }
                Text("POLYPHONY").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint).padding(.top, 4)
                seg([("poly", "Poly"), ("mono", "Mono")], selected: pp.polyV ? "poly" : "mono") { v in up { $0.poly = (v == "poly") } }
                Text("CHOKE GROUP").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint).padding(.top, 4)
                seg([("0", "Off"), ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4")], selected: "\(pp.choke)") { v in up { $0.choke = Int(v) ?? 0 } }
                HStack(spacing: 6) {
                    knob("Offset", pp.offsetV, 0, 1, 0.01, piPct) { v in up { $0.offset = v } }
                    knob("Vel Sens", pp.velSensV, 0, 1, 0.01, piPct) { v in up { $0.velSens = v } }
                    Spacer()
                }
                Text("**Mono** cuts the pad's own previous hit. **Choke** cuts other pads (open/closed hat). **Offset** lays the hit back; **Vel Sens** sets how much velocity moves the level.")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: right

    private var rightColumn: some View {
        VStack(spacing: 12) {
            soundCard
            card("Tune & Level") {
                HStack(spacing: 6) {
                    knob("Tune", pp.pitch, -12, 12, 1, piSemi) { v in up { $0.pitch = v } }
                    knob("Volume", pp.vol, 0, 1.1, 0.01, piPct) { v in up { $0.vol = v } }
                    knob("Pan", pp.pan, -1, 1, 0.02, piPan) { v in up { $0.pan = v } }
                    Spacer()
                }
            }
            card("Filter") {
                HStack(spacing: 6) {
                    knob("Cutoff", pp.cutoff, 200, 18000, 50, piHz) { v in up { $0.cutoff = v } }
                    knob("Reso", pp.reso, 0.5, 16, 0.5, { String(format: "%.1f", $0) }) { v in up { $0.reso = v } }
                    Spacer()
                }
            }
            card("Envelope") {
                HStack(spacing: 6) {
                    knob("Attack", pp.attack, 0.0005, 0.4, 0.001, piMs) { v in up { $0.attack = v } }
                    knob("Decay", pp.decay, 0, 1.2, 0.01, piMs) { v in up { $0.decay = v } }
                    knob("Sustain", pp.sustain, 0, 1, 0.01, piPct) { v in up { $0.sustain = v } }
                    knob("Release", pp.release, 0.03, 2.5, 0.01, piMs) { v in up { $0.release = v } }
                    Spacer()
                }
            }
            layersCard
        }
    }

    // MARK: sound source (swap to any built-in drum, or import a one-shot)

    private var currentSoundText: String {
        if pp.sampleFile != nil { return pp.sampleName ?? "Imported Sample" }
        if let s = pp.sound { return Kit.soundLabel(s) }
        return "Default · " + Kit.soundLabel(pad.sound)
    }

    private var soundCard: some View {
        card("Sound") {
            HStack(spacing: 8) {
                Menu {
                    Button { project.setPadSound(pad.id, nil) } label: {
                        Label("Default · \(Kit.soundLabel(pad.sound))", systemImage: pp.sound == nil && pp.sampleFile == nil ? "checkmark" : "")
                    }
                    ForEach(Kit.drumSoundCats, id: \.self) { cat in
                        Section(cat) {
                            ForEach(Kit.drumSounds.filter { $0.cat == cat }) { ds in
                                Button { project.setPadSound(pad.id, ds.id) } label: {
                                    Label(ds.label, systemImage: pp.sound == ds.id && pp.sampleFile == nil ? "checkmark" : "")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pp.sampleFile != nil ? "waveform" : "dial.medium").font(.system(size: 13))
                        Text(currentSoundText).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    .padding(.horizontal, 12).frame(height: 38).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(settings.theme.panel.darker(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
                }

                Button { showImporter = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
                        .font(FDFont.ui(12, .semibold)).foregroundStyle(settings.accent)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }

            if pp.sampleFile != nil {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill").foregroundStyle(settings.accent)
                    Text(pp.sampleName ?? "Sample").font(FDFont.ui(11, .semibold)).foregroundStyle(settings.inkDim).lineLimit(1)
                    Spacer()
                    Button { project.clearPadSampleFor(pad.id) } label: {
                        Text("Remove").font(FDFont.ui(11, .semibold)).foregroundStyle(settings.inkFaint)
                    }.buttonStyle(.plain)
                }
            } else if let err = importError {
                Text(err).font(FDFont.ui(11)).foregroundStyle(Color(hex: "#FF7A6B")).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Swap this pad to any built-in drum, or import your own one-shot (WAV / AIFF / MP3 / M4A).")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func importSample(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let padID = pad.id, name = url.deletingPathExtension().lastPathComponent
        Task {   // decode off the main thread so a big file never hitches the UI (Phase 2)
            let data = await engine.decodeAudioFileAsync(url: url, maxSeconds: 12)
            guard let data, !data.isEmpty else { importError = "Couldn't read that file."; return }
            project.setPadSample(padID, data: data, name: name)
        }
    }

    private var layersCard: some View {
        card("Layers") {
            HStack {
                Spacer()
                Button { addLayer() } label: {
                    Text("+ Add").font(FDFont.ui(12, .semibold)).foregroundStyle(pp.layers.count >= 3 ? settings.inkFaint : settings.accent)
                }.buttonStyle(.plain).disabled(pp.layers.count >= 3)
            }
            .overlay(alignment: .leading) {
                if pp.layers.isEmpty {
                    Text("Stack a second sound — a clap on a snare, or a sub under a kick.")
                        .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint)
                }
            }
            ForEach(Array(pp.layers.enumerated()), id: \.element.id) { (i, ly) in
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { ly.sound }, set: { s in up { $0.layers[i].sound = s } })) {
                        ForEach(Kit.pads) { p in Text(p.label).tag(p.sound) }
                    }.pickerStyle(.menu).tint(settings.ink).frame(width: 96, alignment: .leading)
                    Text("VOL").font(FDFont.mono(8, .bold)).foregroundStyle(settings.inkFaint)
                    Slider(value: Binding(get: { ly.vol }, set: { v in up { $0.layers[i].vol = v } }), in: 0...1).tint(settings.accent)
                    Button { up { $0.layers.remove(at: i) } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(settings.inkFaint).frame(width: 24, height: 24)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func addLayer() {
        var used = Set([pad.sound] + pp.layers.map { $0.sound })
        let next = Kit.pads.first { !used.contains($0.sound) } ?? Kit.pads[0]
        used.insert(next.sound)
        up { $0.layers.append(PadLayer(sound: next.sound)) }
    }

    // MARK: helpers

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fdCard(14, fill: settings.panel2)
    }

    private func knob(_ label: String, _ value: Double, _ lo: Double, _ hi: Double, _ step: Double,
                      _ fmt: @escaping (Double) -> String, _ onChange: @escaping (Double) -> Void) -> some View {
        KnobView(label: label, value: value, min: lo, max: hi, step: step, color: color, format: fmt, onChange: onChange)
    }

    private func seg(_ options: [(String, String)], selected: String, _ action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.0) { (v, l) in
                Button { action(v) } label: {
                    Text(l).font(FDFont.ui(12, .semibold)).foregroundStyle(selected == v ? settings.ink : settings.inkDim)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected == v ? settings.accent.opacity(0.2) : settings.theme.panel.darker(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected == v ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private func colorHexOf(_ c: Color) -> String {
        // base pad colors are authored as hex; match against the swatch list
        for hex in PI_COLORS where Color(hex: hex) == c { return hex }
        return ""
    }
}
