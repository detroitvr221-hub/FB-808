//  SampleModeView.swift — record/import, waveform trim, real destructive edits,
//  shaping (gain/pitch), transient slicing → pads, and sample → playable synth.

import SwiftUI
import UIKit
import FD808Engine
import UniformTypeIdentifiers
import Waveform   // AudioKit GPU waveform (vendored, MIT) — true min/max draw of the sample buffer

private let SLICE_COUNTS = [4, 8, 16, 32]
// Built-in DEMO tones — synthesized on the fly (not recordings), so you always have something to
// chop/stretch/slice without importing. Labelled "Tone" so none of them claims to be a real sample.
private let SOURCES: [(kind: String, label: String, icon: String)] = [
    ("vocal", "Vocal Tone", "mic.fill"),
    ("chop", "Melodic Tone", "square.and.arrow.down.fill"),
    ("bass", "808 Tone", "waveform.path"),
    ("piano", "Keys Tone", "pianokeys"),
    ("stab", "Synth Stab", "bolt.fill"),
    ("pluck", "Pluck Tone", "music.note"),
]

struct SampleModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    var openTab: (String) -> Void = { _ in }   // "send to play" actions hand off to Pads/Synth so the user lands ready to play

    @State private var playPos: Double?
    @State private var showAdvanced = false   // progressive disclosure: hide pro tools (stretch/stems/granular/etc) by default
    @State private var auditionTask: Task<Void, Never>?
    @State private var looping = false
    @State private var confirm: String?
    @State private var importing = false
    @State private var sf2Importing = false
    @State private var stretchRatio = 1.0
    @State private var chopThreshold = 0.0      // transient sensitivity: higher → fewer, wider-spaced slices
    // Granular cloud params
    @State private var grainPos = 0.3
    @State private var grainMs = 120.0
    @State private var grainDensity = 22.0
    @State private var grainSpread = 0.3
    @State private var grainPitch = 0.0
    @State private var selectedSlice: Int?      // for Split / Merge / Extract
    @State private var gpuBuf: SampleBuffer?     // memoized GPU waveform buffer (rebuilt only when the audio changes, not on trim drags)

    private var sample: SampleState? { project.sample }
    private var has: Bool { sample != nil }

    /// Identity of the underlying AUDIO (not the trim window) — rebuild the GPU buffer only when this changes,
    /// so dragging the trim handles never re-uploads the whole sample to the GPU.
    private var sampleSig: String {
        guard let s = project.sample else { return "" }
        let tools = s.tools.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "\(s.name)|\(String(format: "%.4f", s.dur))|\(s.gain)|\(s.reverseSlices)|\(tools)"
    }
    private func refreshGPUWave() {
        guard project.sample != nil else { gpuBuf = nil; return }
        let data = engine.currentSampleData()
        gpuBuf = data.isEmpty ? nil : SampleBuffer(samples: data)
    }

    var body: some View {
        VStack(spacing: 12) {
            TransportBar()
            HStack(alignment: .top, spacing: 18) {
                main
                side.frame(width: 264)
            }
        }
        .onDisappear { stopAudition() }
        .overlay(alignment: .bottom) { if let c = confirm { toast(c) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { handleImport($0) }
        .fileImporter(isPresented: $sf2Importing, allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data], allowsMultipleSelection: false) { handleSF2($0) }
    }

    // MARK: main

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModeHead(title: "Sample",
                     eyebrow: sample?.name ?? "No sample loaded",
                     hint: sample.map { String(format: "%.2fs · drag the edges to trim", $0.dur) })
            waveBox
            sourceRow
            Text("Resample the mix, import or record audio — or load a built-in **demo tone** (synthesized, not a recording) to chop and stretch.")
                .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var waveBox: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(settings.panel)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
                if let s = sample {
                    let trim = s.trim
                    sampleWaveLayer(s, size: g.size)
                    dim(x: 0, w: trim[0] * g.size.width)
                    dim(x: trim[1] * g.size.width, w: (1 - trim[1]) * g.size.width)
                    ForEach(Array(s.slices.enumerated()), id: \.offset) { (i, p) in sliceMark(i: i, x: p * g.size.width) }
                    handle(side: "l", x: trim[0] * g.size.width, width: g.size.width)
                    handle(side: "r", x: trim[1] * g.size.width, width: g.size.width)
                    if let pp = playPos {
                        Rectangle().fill(.white).frame(width: 2).shadow(color: .white, radius: 4)
                            .position(x: pp * g.size.width, y: g.size.height / 2).frame(height: g.size.height)
                    }
                    Button { audition() } label: {
                        HStack(spacing: 8) {
                            if looping { RoundedRectangle(cornerRadius: 3).fill(settings.theme.miss).frame(width: 12, height: 12) }
                            else { Triangle().fill(settings.accent).frame(width: 12, height: 14) }
                            Text(looping ? "Stop" : (s.loop ? "Loop" : "Audition"))
                        }
                        .font(FDFont.ui(14, .semibold)).foregroundStyle(settings.ink)
                        .frame(width: 120, height: 44)
                        .background(RoundedRectangle(cornerRadius: 13).fill(looping ? settings.theme.miss.opacity(0.18) : settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(looping ? settings.theme.miss.opacity(0.5) : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain).position(x: 74, y: g.size.height - 36)
                    .accessibilityLabel(Text(looping ? "Stop playback" : (s.loop ? "Loop sample" : "Audition sample")))
                    .accessibilityValue(Text(looping ? "Playing" : "Stopped"))
                } else {
                    Text("Record, import or resample audio to start chopping. Slices map straight onto your pads, or play the whole sample chromatically as an instrument.")
                        .font(FDFont.ui(14)).foregroundStyle(settings.inkDim)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "wave")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshGPUWave() }
        .onChange(of: sampleSig) { _, _ in refreshGPUWave() }
    }

    /// Base waveform layer: the AudioKit GPU Waveform (true min/max of the edited buffer, themed to the
    /// accent) when the raw buffer is available; falls back to the CPU peak Canvas (e.g. right after a
    /// project restore before the engine buffer is rehydrated). Overlays (trim/slices/playhead) sit on top.
    @ViewBuilder private func sampleWaveLayer(_ s: SampleState, size: CGSize) -> some View {
        if let buf = gpuBuf, buf.count > 0 {
            Waveform(samples: buf)
                .foregroundColor(settings.accent)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            waveCanvas(s, size: size)
        }
    }

    private func waveCanvas(_ s: SampleState, size: CGSize) -> some View {
        Canvas { ctx, sz in
            let mid = sz.height / 2
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: sz.width, height: 1)), with: .color(.white.opacity(0.08)))
            guard !s.wave.isEmpty else { return }
            let n = s.wave.count
            for x in stride(from: 0.0, to: sz.width, by: 1) {
                let amp = s.wave[min(n - 1, Int(x / sz.width * Double(n)))]
                let h = max(1.4, amp * mid * 0.92 * 2)
                ctx.fill(Path(CGRect(x: x, y: mid - h / 2, width: 1, height: h)), with: .color(settings.accent))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private func dim(x: Double, w: Double) -> some View {
        Rectangle().fill(.black.opacity(0.5)).frame(width: max(0, w)).frame(maxHeight: .infinity).offset(x: x).allowsHitTesting(false)
    }
    private func sliceMark(i: Int, x: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(settings.theme.perfect.opacity(0.9)).frame(width: 2).frame(maxHeight: .infinity)
            Text("\(i + 1)").font(FDFont.mono(9)).foregroundStyle(settings.theme.perfect).offset(x: 3, y: 4)
        }.offset(x: x).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func handle(side: String, x: Double, width: Double) -> some View {
        let hw: Double = 30   // hit-column width — must stay narrow so it doesn't swallow the whole waveform
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(settings.accent.opacity(0.7)).frame(width: 14)
            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.8)).frame(width: 3, height: 30)
        }
        .frame(width: hw).frame(maxHeight: .infinity).contentShape(Rectangle())
        .offset(x: max(0, min(width - hw, x - hw / 2)))   // narrow column centred on the trim edge
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
            .onChanged { v in
                let f = max(0, min(1, v.location.x / width))
                guard var s = project.sample else { return }
                if side == "l" { s.trim[0] = min(f, s.trim[1] - 0.02) } else { s.trim[1] = max(f, s.trim[0] + 0.02) }
                project.sample = s
            })
        .accessibilityLabel(Text(side == "l" ? "Trim start" : "Trim end"))
        .accessibilityValue(Text("\(Int((side == "l" ? (project.sample?.trim[0] ?? 0) : (project.sample?.trim[1] ?? 1)) * 100)) percent"))
        .accessibilityHint(Text("Drag to adjust the sample trim region"))
    }

    private var sourceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { resampleMix() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 16)).foregroundStyle(.white)
                        Text("Resample Mix").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain)
                Button { importing = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square.fill").font(.system(size: 16)).foregroundStyle(settings.accent)
                        Text("Import Audio").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accent.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
                Button { sf2Importing = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "pianokeys").font(.system(size: 16)).foregroundStyle(settings.accent)
                        Text("Load .sf2").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.accent.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
                Button { toggleMic() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: engine.isMicRecording ? "stop.fill" : "mic.fill").font(.system(size: 16))
                            .foregroundStyle(engine.isMicRecording ? settings.theme.miss : settings.accent)
                        Text(engine.isMicRecording ? "Stop" : "Record Mic").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(engine.isMicRecording ? settings.theme.miss.opacity(0.18) : settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(engine.isMicRecording ? settings.theme.miss.opacity(0.6) : settings.accent.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
                // Input device picker right where you record (native iOS 26 picker) — built-in / USB-C
                // interface (Focusrite) / Bluetooth. Shows the active input; the system remembers it.
                AudioInputPicker(prepare: { engine.prepareInputSelection() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.and.signal.meter.fill").font(.system(size: 16)).foregroundStyle(settings.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Input").font(FDFont.mono(8, .bold)).tracking(0.5).foregroundStyle(settings.inkFaint)
                            Text(engine.inputName).font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.ink).lineLimit(1)
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(settings.inkDim)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
                }
                ForEach(SOURCES, id: \.kind) { src in
                    Button { loadSource(src.kind, src.label) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: src.icon).font(.system(size: 16)).foregroundStyle(settings.accent)
                            Text(src.label).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                        }
                        .padding(.horizontal, 14).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(sample?.kind == src.kind ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: side

    private var side: some View {
        ScrollView {
            VStack(spacing: 12) {
                PanelCard(title: "Edit") {
                    let cols = [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)]
                    LazyVGrid(columns: cols, spacing: 7) {
                        ForEach([("normalize", "Normalize"), ("reverse", "Reverse"), ("fadeIn", "Fade In"), ("fadeOut", "Fade Out")], id: \.0) { (k, lbl) in
                            toolButton(lbl, on: sample?.tools[k] ?? false) { toggleTool(k) }
                        }
                    }
                    HStack(spacing: 7) {
                        actionButton("✂︎ Crop") { crop() }
                        actionButton("↺ Reset") { reset() }
                    }
                }

                PanelCard(title: "Shape") {
                    sliderRow("Gain", value: Binding(get: { sample?.gain ?? 1 }, set: { setGain($0) }), range: 0...2,
                              readout: "\(Int((sample?.gain ?? 1) * 100))%")
                    sliderRow("Pitch", value: Binding(get: { Double(sample?.pitch ?? 0) }, set: { setPitch(Int($0.rounded())) }), range: -12...12,
                              readout: pitchLabel(sample?.pitch ?? 0))
                    Button { toggleLoop() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "repeat").font(.system(size: 13))
                            Text("Loop").font(FDFont.ui(12.5, .semibold))
                            Spacer()
                            Text((sample?.loop ?? false) ? "ON" : "OFF").font(FDFont.mono(10, .bold))
                        }
                        .foregroundStyle((sample?.loop ?? false) ? settings.ink : settings.inkDim)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill((sample?.loop ?? false) ? settings.accent.opacity(0.2) : settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke((sample?.loop ?? false) ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain).disabled(!has)
                }

                PanelCard(title: "Slice") {
                    actionButton("⟂ Threshold Chop", wide: true) { detectTransients() }
                    sliderRow("Threshold", value: $chopThreshold, range: 0...1, readout: "\(Int(chopThreshold * 100))%")
                    Text("Higher threshold = fewer, wider slices (MPC Threshold chop). Or pick even **Regions**:")
                        .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint)
                    HStack(spacing: 6) {
                        ForEach(SLICE_COUNTS, id: \.self) { n in
                            Button { equalSlices(n) } label: {
                                Text("\(n)").font(FDFont.mono(12, .bold)).foregroundStyle(sample?.count == n ? .white : settings.inkDim)
                                    .frame(maxWidth: .infinity).frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(sample?.count == n ? settings.accent : settings.panel2))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(sample?.count == n ? .clear : settings.line, lineWidth: 1))
                            }.buttonStyle(.plain).disabled(!has)
                        }
                    }
                    toolButton("Reverse Slice Order", on: sample?.reverseSlices ?? false) { toggleReverseSlices() }
                    Button { assignToPads() } label: {
                        Text("→ Assign to Pads (Bank C)").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.ink)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.2)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.5), lineWidth: 1))
                    }.buttonStyle(.plain).opacity((sample?.slices.isEmpty == false) ? 1 : 0.4).disabled(sample?.slices.isEmpty != false)
                }

                if let s = sample, !s.slices.isEmpty {
                    PanelCard(title: "Slices · tap to select & audition") {
                        let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 4)
                        LazyVGrid(columns: cols, spacing: 5) {
                            ForEach(Array(Kit.pads.prefix(16).enumerated()), id: \.element.id) { (i, p) in
                                let hasSlice = i < s.slices.count
                                let isSel = selectedSlice == i
                                Button { if hasSlice { selectedSlice = i; playSlice(i) } } label: {
                                    Text(hasSlice ? "\(i + 1)" : "").font(FDFont.mono(10, .bold)).foregroundStyle(hasSlice ? .white : settings.inkFaint)
                                        .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(hasSlice ? p.color : settings.panel2))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSel ? .white : (hasSlice ? .clear : settings.line), lineWidth: isSel ? 2.5 : 1))
                                }.buttonStyle(.plain)
                                .accessibilityLabel(Text(hasSlice ? "Slice \(i + 1)" : "Empty slice slot"))
                                .accessibilityValue(Text(isSel ? "Selected" : ""))
                                .accessibilityHint(Text(hasSlice ? "Tap to select and audition" : ""))
                            }
                        }
                        HStack(spacing: 6) {
                            sliceEditButton("Split") { splitSlice() }
                            sliceEditButton("Merge") { mergeSlice() }
                            sliceEditButton("Extract") { extractSlice() }
                        }.padding(.top, 6).opacity(selectedSlice == nil ? 0.4 : 1).disabled(selectedSlice == nil)
                        Text(selectedSlice == nil ? "Tap a slice to edit it." : "**Split** halves it · **Merge** joins it to the previous · **Extract** sends it to a pad as its own sample.")
                            .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).padding(.top, 2)
                    }
                }

                // Progressive disclosure — pro tools (tune / stretch / stems / granular / instrument) hidden by default
                // so a beginner sees the happy path (edit → shape → chop → assign) without a wall of DSP.
                Button { withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        Text("Advanced tools").font(FDFont.ui(13, .bold))
                        Spacer()
                        Image(systemName: showAdvanced ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(settings.inkDim)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text("Advanced tools"))
                    .accessibilityValue(Text(showAdvanced ? "Expanded" : "Collapsed"))
                    .accessibilityHint(Text("Tune to key, time stretch, stem split, granular and instrument tools"))

                if showAdvanced {
                    PanelCard(title: "Tune to Key") {
                        Button { tuneToKey() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "tuningfork").font(.system(size: 13))
                                Text("Snap to \(Music.noteNames[project.melodyKey % 12]) \(project.melodyScale == "minor" ? "min" : "maj")").font(FDFont.ui(12.5, .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 40).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.ctaGradient()))
                        }.buttonStyle(.plain).disabled(!has).opacity(has ? 1 : 0.4)
                        toolButton("Harmonize · 3rd + 5th", on: sample?.harmonize ?? false) { toggleHarmonize() }
                        Text("Detects the sample's pitch and nudges it onto the song scale. Harmonize stacks diatonic voices when you audition or play slices.")
                            .font(FDFont.ui(11)).foregroundStyle(settings.inkDim).fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard(title: "Time Stretch") {
                        sliderRow("Stretch", value: $stretchRatio, range: 0.5...2, readout: String(format: "%.2fx", stretchRatio))
                        HStack(spacing: 7) {
                            actionButton("Apply") { applyStretch(stretchRatio) }
                            actionButton("Fit Tempo") { fitTempo() }
                        }
                        actionButton("⌖ Detect Tempo & Key", wide: true) { detectTempoKey() }
                        Text("Pitch-preserving (WSOLA). Fit Tempo snaps the loop to whole beats at \(project.bpm) BPM. Detect analyzes the sample and sets the song tempo + key.")
                            .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard(title: "Stem Split") {
                        actionButton("⎘ Split → Drums / Melody", wide: true) { splitStems() }
                        actionButton(FourStemSeparator.modelAvailable ? "⎙ Split → 4 Stems" : "⎙ 4 Stems (needs model)", wide: true) { splitFourStems() }
                        Text("Drums/Melody is on-device, no model. 4 Stems (vocals/drums/bass/other) uses a bundled Core ML model — drop `StemSeparator.mlpackage` into the app target to enable it (see FourStemSeparator.swift); until then it falls back to the 2-way split.")
                            .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard(title: "Granular") {
                        sliderRow("Position", value: $grainPos, range: 0...1, readout: "\(Int(grainPos * 100))%")
                        sliderRow("Grain", value: $grainMs, range: 10...400, readout: "\(Int(grainMs)) ms")
                        sliderRow("Density", value: $grainDensity, range: 1...60, readout: "\(Int(grainDensity))/s")
                        sliderRow("Spread", value: $grainSpread, range: 0...1, readout: "\(Int(grainSpread * 100))%")
                        sliderRow("Pitch", value: $grainPitch, range: -24...24, readout: "\(Int(grainPitch)) st")
                        actionButton("☁︎ Play Cloud", wide: true) {
                            engine.playGranular(pos: grainPos, grainMs: grainMs, density: grainDensity,
                                                spread: grainSpread, pitch: grainPitch, dur: 2.5)
                        }
                        Text("Sprays overlapping windowed grains from the buffer — texture, time-smear and drones. Spread randomizes grain position.")
                            .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }

                    PanelCard(title: "Instrument") {
                        Button { toSynthKeys() } label: {
                            Text("→ Play Chromatically (Synth)").font(FDFont.ui(12, .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.ctaGradient()))
                        }.buttonStyle(.plain).opacity(has ? 1 : 0.4).disabled(!has)
                        Button { toWavetable() } label: {
                            Text("∿ Use as Wavetable Oscillator").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.ink)
                                .frame(maxWidth: .infinity).frame(height: 40)
                                .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.16)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.5), lineWidth: 1))
                        }.buttonStyle(.plain).opacity(has ? 1 : 0.4).disabled(!has)
                        Text("**Play Chromatically** repitches the whole sample (sampler). **Wavetable** grabs one cycle → a true live oscillator, clean across the whole keyboard. Great for torchsynth-generated tones.")
                            .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                }

                CoachNote("**Transients** are the sharp attacks at the start of each sound. Slicing on transients keeps chops tight and on-beat.")
            }
        }
        .scrollIndicators(.hidden)
        .opacity(has ? 1 : 0.55)
    }

    private func toolButton(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(12, .semibold)).foregroundStyle(settings.ink)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.2) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!has)
    }
    private func actionButton(_ label: String, wide: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(12, .semibold)).foregroundStyle(settings.inkDim)
                .frame(maxWidth: .infinity).frame(height: 38)
                .fdCard(10, fill: settings.panel2)
        }.buttonStyle(.plain).disabled(!has)
    }
    private func sliceEditButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(12, .semibold)).foregroundStyle(settings.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .fdCard(9, fill: settings.panel2)
        }.buttonStyle(.plain)
    }
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(FDFont.ui(12.5, .medium)).foregroundStyle(settings.inkDim)
                Spacer()
                Text(readout).font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
            }
            Slider(value: value, in: range).tint(settings.accent).disabled(!has)
                .accessibilityLabel(Text(label))
                .accessibilityValue(Text(readout))
        }
    }
    private func pitchLabel(_ p: Int) -> String { p == 0 ? "0" : (p > 0 ? "+\(p)" : "\(p)") }

    private func toast(_ msg: String) -> some View {
        Text(msg).font(FDFont.ui(13.5, .semibold)).foregroundStyle(settings.theme.bg)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Capsule().fill(settings.ink.opacity(0.92)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5).padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
    /// Analyze the loaded sample → set the song tempo + key (D4). A suggestion; both are editable/undoable.
    private func detectTempoKey() {
        guard sample != nil else { return }
        let bpm = engine.detectTempo()
        let key = engine.detectKey()
        var parts: [String] = []
        if bpm > 0 { project.setBpm(Int(bpm)); parts.append("\(Int(bpm)) BPM") }
        if let k = key {
            project.checkpoint("detectKey", coalesce: false)
            project.melodyKey = k.root
            project.melodyScale = k.minor ? "minor" : "major"
            parts.append("\(Music.noteName(k.root)) \(k.minor ? "minor" : "major")")
        }
        flash(parts.isEmpty ? "Couldn't detect tempo or key" : "Detected " + parts.joined(separator: " · "))
    }
    /// Split the loaded sample into drums + melody stems and drop them onto the first two pads (D1).
    private func splitStems() {
        guard sample != nil else { return }
        flash("Separating stems…")
        let (h, p) = engine.splitStems()
        guard !p.isEmpty, !h.isEmpty else { flash("Couldn't split this sample"); return }
        let drumID = Kit.pads[0].id, melID = Kit.pads[1].id
        project.setPadSample(drumID, data: p, name: "Drums")
        project.setPadSample(melID, data: h, name: "Melody")
        flash("Split → Drums on \(Kit.padByID[drumID]?.label ?? "pad 1") · Melody on \(Kit.padByID[melID]?.label ?? "pad 2")")
    }
    /// Split into 4 stems via the bundled Core ML model (D1 full path); falls back to the 2-way split if
    /// no model is bundled. Runs off the main thread (inference can take seconds) and applies on main.
    private func splitFourStems() {
        guard sample != nil else { return }
        guard FourStemSeparator.modelAvailable else {
            flash("No 4-stem model bundled — using Drums/Melody"); splitStems(); return
        }
        flash("Separating 4 stems…")
        let src = engine.currentSampleForStems()
        Task.detached(priority: .userInitiated) {
            let stems = FourStemSeparator.separate(src.data, engineSR: src.sr)
            await MainActor.run {
                guard let stems, !stems.isEmpty else { flash("4-stem separation failed"); return }
                for (i, st) in stems.prefix(Kit.pads.count).enumerated() {
                    project.setPadSample(Kit.pads[i].id, data: st.audio, name: st.name)
                }
                flash("Split into \(stems.count) stems → first \(min(stems.count, Kit.pads.count)) pads")
            }
        }
    }
    private func flash(_ msg: String) {
        withAnimation { confirm = msg }
        UIAccessibility.post(notification: .announcement, argument: msg)
        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_900_000_000); withAnimation { confirm = nil } }
    }

    // MARK: actions

    private func loadSource(_ kind: String, _ name: String) {
        stopAudition()
        engine.start()
        // Replacing the whole sample is undoable: mutateSample captures the PRIOR sample's audio (engine
        // buffer) BEFORE makeSample overwrites it, so an accidental source tap can be undone without loss.
        project.mutateSample("loadSource") {
            let r = engine.makeSample(kind)
            project.sample = SampleState(name: name, kind: kind, dur: r.dur, wave: r.wave, transients: r.transients)
            project.sliceBank = nil
        }
    }
    /// Record from the microphone into the sampler (toggle).
    private func toggleMic() {
        if engine.isMicRecording {
            // Undoable: capture the prior sample's audio BEFORE stopMicRecording loads the take over it.
            var recordedDur: Double? = nil
            project.mutateSample("mic") {
                if let r = engine.stopMicRecording() {
                    project.sample = SampleState(name: "Mic Recording", kind: "mic", dur: r.dur, wave: r.wave, transients: r.transients)
                    project.sliceBank = nil
                    recordedDur = r.dur
                }
            }
            flash(recordedDur != nil ? "Recorded \(String(format: "%.1f", recordedDur!))s" : "Nothing recorded")
        } else {
            stopAudition()
            engine.startMicRecording { ok in
                flash(ok ? "Recording… tap Stop when done" : "Microphone unavailable or denied")
            }
        }
    }

    /// Import a user audio file (Files / iCloud) into the sampler.
    private func handleImport(_ result: Result<[URL], Error>) {
        stopAudition()
        guard case .success(let urls) = result, let url = urls.first else { return }
        engine.start()
        let name = url.deletingPathExtension().lastPathComponent
        // Checkpoint + capture the prior sample's audio for undo NOW, before the async decode loads the new
        // file over the engine buffer (mutateSample's capture must run before loadExternal replaces it).
        project.mutateSample("import") { }
        Task {   // off-main decode so the UI doesn't hitch on a long file (Phase 2)
            guard let r = await engine.importAudioAsync(url: url) else { flash("Couldn't read that audio file"); return }
            project.sample = SampleState(name: name.isEmpty ? "Imported" : name, kind: "import",
                                         dur: r.dur, wave: r.wave, transients: r.transients)
            project.sliceBank = nil
            flash("Imported \(name) · \(String(format: "%.1f", r.dur))s")
        }
    }

    /// Load a SoundFont (.sf2) → a multisample instrument on the Synth keyboard.
    private func handleSF2(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        engine.start()
        Task {
            let data: Data?
            let scoped = url.startAccessingSecurityScopedResource()
            data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let data else { flash("Couldn't read that .sf2"); return }
            if let name = project.loadSoundFont(data) {
                flash("Loaded \(name) — play it on the Synth keyboard")
            } else {
                flash("Couldn't parse that SoundFont")
            }
        }
    }

    /// Capture the last few seconds of the live studio output (all tabs) into a new sample.
    private func resampleMix() {
        stopAudition()
        engine.start()
        // Undoable: capture the prior sample's audio BEFORE resampleOutput overwrites the engine buffer.
        project.mutateSample("resample") {
            let r = engine.resampleOutput()
            project.sample = SampleState(name: "Resampled Mix", kind: "mix", dur: r.dur, wave: r.wave, transients: [])
            project.sliceBank = nil
            flash(r.dur > 0.2 ? "Captured \(String(format: "%.1f", r.dur))s of the mix" : "Play a beat, then Resample Mix")
        }
    }

    private func refreshEdits() {
        guard var s = project.sample else { return }
        s.wave = engine.applySampleEdits(reverse: s.tools["reverse"] ?? false, normalize: s.tools["normalize"] ?? false,
                                         fadeIn: s.tools["fadeIn"] ?? false, fadeOut: s.tools["fadeOut"] ?? false, gain: s.gain)
        project.sample = s
    }
    private func toggleTool(_ k: String) {
        project.mutateSample("tool:\(k)") {   // tools bake into the engine buffer → undoable via the buffer ring (#19)
            guard var s = project.sample else { return }
            s.tools[k] = !(s.tools[k] ?? false)
            project.sample = s
            refreshEdits()
        }
    }
    private func toggleReverseSlices() {
        project.checkpoint("revslices", coalesce: false)   // SampleState-only → restored by applyState
        guard var s = project.sample else { return }
        s.reverseSlices.toggle(); project.sample = s
    }
    private func setGain(_ v: Double) {
        project.mutateSample("gain", coalesce: true) {   // a slider drag = one undo step
            guard var s = project.sample else { return }
            s.gain = v; project.sample = s; refreshEdits()
        }
    }
    private func setPitch(_ v: Int) {
        project.checkpoint("samplePitch", coalesce: true)   // playback-time field → no buffer needed
        guard var s = project.sample else { return }
        s.pitch = max(-12, min(12, v)); project.sample = s
    }
    private func crop() {
        project.mutateSample("crop") {
            guard var s = project.sample else { return }
            let r = engine.cropSample(trim: s.trim)
            s.dur = r.dur; s.wave = r.wave; s.trim = [0, 1]; s.slices = []; s.count = 0
            s.tools = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]; s.gain = 1
            project.sample = s
            flash("Cropped to \(String(format: "%.2f", r.dur))s")
        }
    }
    private func applyStretch(_ ratio: Double) {
        guard project.sample != nil, abs(ratio - 1) > 0.01 else { return }
        project.mutateSample("stretch") {
            guard var s = project.sample else { return }
            let r = engine.stretchSample(ratio: ratio)
            s.dur = r.dur; s.wave = r.wave; s.trim = [0, 1]; s.slices = []; s.count = 0
            s.tools = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]; s.gain = 1
            project.sample = s
            flash("Stretched to \(String(format: "%.2f", r.dur))s")
        }
        stretchRatio = 1.0
    }
    private func fitTempo() {
        guard let s = project.sample, s.dur > 0.05 else { return }
        let beatDur = 60.0 / Double(project.bpm)
        let beats = max(1, (s.dur / beatDur).rounded())
        applyStretch(beats * beatDur / s.dur)
    }

    private func reset() {
        project.mutateSample("reset") {
            guard var s = project.sample else { return }
            s.wave = engine.resetSample()
            s.tools = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]; s.gain = 1
            project.sample = s
        }
    }
    private func toSynthKeys() {
        guard let s = sample else { return }
        engine.sampleToSynth()
        project.synthPatch.source = "sample"
        project.synthPatch.bufferKind = s.kind
        project.synthPatch.baseMidi = 60
        project.synthPatch.name = s.name
        flash("Now playing in Synth — try the keyboard")
        openTab("synth")
    }
    /// Grab a single cycle from the sample → a live wavetable oscillator on the Lead synth (D6/wavetable).
    private func toWavetable() {
        guard let s = sample, let table = engine.makeWavetableFromSample() else { flash("Couldn't build a wavetable"); return }
        project.checkpoint("wavetable", coalesce: false)
        var p = project.synthPatch
        p.source = "synth"; p.wave = .wavetable; p.wavetable = WTData(table); p.name = String(s.name.prefix(18)) + " WT"
        project.synthPatch = p
        flash("Wavetable ready in Synth — play it live")
        openTab("synth")
    }

    private func toggleLoop() {
        guard var s = project.sample else { return }
        project.checkpoint("sampleLoop", coalesce: false)
        s.loop.toggle(); project.sample = s
        if !s.loop && looping { stopAudition() }   // turning loop off stops a running loop
    }

    private func stopAudition() {
        auditionTask?.cancel(); auditionTask = nil
        playPos = nil; looping = false
    }

    private func audition() {
        if looping { stopAudition(); return }       // Audition is "Stop" while looping
        guard let s = sample else { return }
        engine.start()
        looping = s.loop
        playOnce(s)
        auditionTask?.cancel()
        auditionTask = Task { @MainActor in
            var start = Date()
            while !Task.isCancelled {
                guard let cur = project.sample else { break }
                let dur = (cur.trim[1] - cur.trim[0]) * cur.dur
                let rate = pow(2, Double(cur.pitch) / 12.0)
                let outDur = max(0.05, dur / rate)
                let e = Date().timeIntervalSince(start)
                if e >= outDur {
                    if cur.loop { playOnce(cur); start = Date() }
                    else { playPos = nil; looping = false; return }
                } else {
                    playPos = cur.trim[0] + (e * rate) / cur.dur
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
    private func playOnce(_ s: SampleState) {
        let off = s.trim[0] * s.dur, dur = (s.trim[1] - s.trim[0]) * s.dur
        engine.playBuffer(offset: off, dur: dur, vel: 0.95, pitch: Double(s.pitch))
        if s.harmonize { for h in harmonyOffsets() { engine.playBuffer(offset: off, dur: dur, vel: 0.55, pitch: Double(s.pitch + h)) } }
    }

    // MARK: D6 — tune to key + diatonic harmonizer (playback-based, reuses the sample pitch field)

    /// Diatonic 3rd + 5th (semitones above) for the song scale.
    private func harmonyOffsets() -> [Int] {
        let iv = Music.intervals(project.melodyScale)
        return iv.count >= 5 ? [iv[2], iv[4]] : [4, 7]
    }
    /// Nearest in-key MIDI note to `midi`, in the song key/scale.
    private func nearestScaleMidi(_ midi: Int) -> Int {
        let iv = Music.intervals(project.melodyScale), root = project.melodyKey
        var best = midi, bestDist = 99
        for oct in -1...1 {
            for s in iv {
                let cand = root + s + 12 * (midi / 12 + oct)
                let d = abs(cand - midi)
                if d < bestDist { bestDist = d; best = cand }
            }
        }
        return best
    }
    private func tuneToKey() {
        guard var s = project.sample, s.dur > 0.05 else { flash("Load a sample first"); return }
        let hz = engine.detectPitch()
        guard hz > 20 else { flash("Couldn't detect a clear pitch"); return }
        let midi = Int((69 + 12 * log2(hz / 440)).rounded())
        let snapped = nearestScaleMidi(midi)
        let delta = snapped - midi
        s.pitch = max(-12, min(12, s.pitch + delta))
        project.sample = s
        let note = Music.noteName(snapped)
        flash("\(Int(hz)) Hz → \(note) (\(delta >= 0 ? "+" : "")\(delta) st)")
        playOnce(s)
    }
    private func toggleHarmonize() {
        guard var s = project.sample else { return }
        project.checkpoint("harmonize", coalesce: false)
        s.harmonize.toggle(); project.sample = s
        if s.harmonize { playOnce(s) }
    }

    private func detectTransients() {
        guard var s = project.sample else { return }
        project.checkpoint("chop", coalesce: false)
        // Threshold (MPC "Threshold" chop): higher → wider min spacing → fewer slices.
        let minGap = 0.01 + chopThreshold * 0.18
        var kept: [Double] = [0]
        for t in s.transients where t > 0.01 {
            if t - (kept.last ?? -1) >= minGap { kept.append(t) }
        }
        s.slices = kept; s.count = 0; project.sample = s
        selectedSlice = nil
    }
    /// Split the selected slice into two at its midpoint (MPC SHIFT+B2 Split).
    private func splitSlice() {
        guard var s = project.sample, let i = selectedSlice, i < s.slices.count else { return }
        project.checkpoint("sliceSplit", coalesce: false)
        let a = s.slices[i], b = i + 1 < s.slices.count ? s.slices[i + 1] : 1
        s.slices.insert((a + b) / 2, at: i + 1); s.count = 0; project.sample = s
    }
    /// Merge the selected slice into the previous one (MPC SHIFT+B3 Merge).
    private func mergeSlice() {
        guard var s = project.sample, let i = selectedSlice, i > 0, i < s.slices.count else { return }
        project.checkpoint("sliceMerge", coalesce: false)
        s.slices.remove(at: i); s.count = 0; project.sample = s
        selectedSlice = i - 1
    }
    /// Extract the selected slice's audio as a new one-shot on the matching pad (MPC SHIFT+B1 Extract).
    private func extractSlice() {
        guard let s = project.sample, let i = selectedSlice, i < s.slices.count else { return }
        let buf = engine.currentSampleOriginal()
        guard !buf.isEmpty else { flash("No audio to extract"); return }
        let a = s.slices[i], b = i + 1 < s.slices.count ? s.slices[i + 1] : 1
        let lo = max(0, min(buf.count, Int(a * Double(buf.count))))
        let hi = max(lo, min(buf.count, Int(b * Double(buf.count))))
        guard hi > lo else { return }
        let padID = Kit.pads[min(i, Kit.pads.count - 1)].id
        project.setPadSample(padID, data: Array(buf[lo..<hi]), name: "Chop \(i + 1)")
        flash("Extracted slice \(i + 1) → \(Kit.padByID[padID]?.label ?? padID) pad")
    }
    private func equalSlices(_ n: Int) {
        guard var s = project.sample else { return }
        project.checkpoint("slices", coalesce: false)
        s.slices = (0..<n).map { Double($0) / Double(n) }; s.count = n; project.sample = s
    }
    private func playSlice(_ idx: Int) {
        guard let s = sample else { return }
        engine.start()
        let a = s.slices[idx]; let b = idx + 1 < s.slices.count ? s.slices[idx + 1] : 1
        let off = a * s.dur, dur = (b - a) * s.dur
        engine.playBuffer(offset: off, dur: dur, vel: 0.95, pitch: Double(s.pitch))
        if s.harmonize { for h in harmonyOffsets() { engine.playBuffer(offset: off, dur: dur, vel: 0.55, pitch: Double(s.pitch + h)) } }
    }
    private func assignToPads() {
        guard let s = sample, !s.slices.isEmpty else { return }
        // Extract each slice's audio onto its pad as a real one-shot — so the chops are playable
        // in the sequencer and bounce into export (not the old bank-C-only sliceBank dead-end).
        let n = project.assignSlicesToPads(buffer: engine.currentSampleOriginal(), slices: s.slices, reverse: s.reverseSlices)
        guard n > 0 else { flash("No audio to slice"); return }
        project.setBank("C")
        flash("\(n) chops on Bank C — tap to play, sequence them & they’ll export")
        openTab("pads")
    }
}
