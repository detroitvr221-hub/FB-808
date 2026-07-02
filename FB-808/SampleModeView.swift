//  SampleModeView.swift — record/import, waveform trim, real destructive edits,
//  shaping (gain/pitch), transient slicing → pads, and sample → playable synth.

import SwiftUI
import UIKit
import FD808Engine
import UniformTypeIdentifiers
import Waveform   // AudioKit GPU waveform (vendored, MIT) — true min/max draw of the sample buffer

private let SLICE_COUNTS = [4, 8, 16]   // capped at 16 — the audition grid and pad assignment are 16 slots (F2)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var stemBusy = false          // a stem split is running — disable buttons + show progress (no double-run, no UI freeze)
    @State private var stemTask: Task<Void, Never>?   // the running split, so the Cancel button can end it (S1)
    @State private var stemProgress: Double?     // 0…1 chunk progress from the 4-stem loop; nil = indeterminate (S2)
    @State private var stemError: String?        // persistent inline failure line — a 1.9 s toast is missable (S3)
    @State private var analysisBusy = false      // detect/tune/stretch running off-main — disable re-entry + show busy (P2)
    @State private var pendingSplit: StemSplitKind?   // which stem split awaits the "replace pad sounds?" confirmation
    @State private var gpuBuf: SampleBuffer?     // memoized GPU waveform buffer (rebuilt only when the audio changes, not on trim drags)
    @State private var gpuSig = ""               // signature gpuBuf was built from — skips the rebuild on re-entering the tab (P3)
    @State private var gainDragging = false      // GPU rebuild is debounced to gain-drag end; the CPU canvas stays live meanwhile (P1)
    // Waveform zoom window (C2): the visible slice of the sample is [waveStart, waveStart + 1/waveZoom]
    // in normalized 0…1 audio position. All overlay geometry maps through waveX/waveFrac.
    @State private var waveZoom = 1.0
    @State private var waveStart = 0.0
    @State private var pinchBase: Double?            // waveZoom at pinch start
    @State private var panBase: Double?              // waveStart at pan start
    @State private var trimDragOrig: [String: Double] = [:]   // trim value at drag start, per side (C5 — drag by delta, no teleport)
    @State private var sliceDrag: (idx: Int, orig: Double)?   // slice fraction at drag start (C3)

    private var sample: SampleState? { project.sample }
    private var has: Bool { sample != nil }

    /// Identity of the underlying AUDIO (not the trim window) — rebuild the GPU buffer only when this changes,
    /// so dragging the trim handles never re-uploads the whole sample to the GPU.
    private var sampleSig: String {
        guard let s = project.sample else { return "" }
        let tools = s.tools.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "\(s.name)|\(String(format: "%.4f", s.dur))|\(s.gain)|\(tools)"   // reverseSlices dropped — it doesn't alter audio (P3)
    }
    private func refreshGPUWave() {
        gpuSig = sampleSig
        guard project.sample != nil else { gpuBuf = nil; return }
        let data = engine.currentSampleData()
        gpuBuf = data.isEmpty ? nil : SampleBuffer(samples: data)
    }

    // MARK: waveform zoom window (C2)

    /// Normalized audio fraction → x in the wave box.
    private func waveX(_ f: Double, _ width: Double) -> Double { (f - waveStart) * waveZoom * width }
    /// x in the wave box → normalized audio fraction.
    private func waveFrac(_ x: Double, _ width: Double) -> Double { waveStart + x / (width * waveZoom) }
    /// Full view … a ~50 ms window.
    private var maxWaveZoom: Double { max(1, (sample?.dur ?? 1) / 0.05) }
    /// Set zoom keeping the audio under `anchor` (fraction of view width) fixed on screen.
    private func setWaveZoom(_ z: Double, anchor: Double = 0.5) {
        let nz = min(maxWaveZoom, max(1, z))
        let f = waveStart + anchor / waveZoom
        waveZoom = nz
        waveStart = min(max(0, f - anchor / nz), 1 - 1 / nz)
    }
    private func resetWaveZoom() {
        withAnimation(.easeOut(duration: 0.15)) { waveZoom = 1; waveStart = 0 }
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
        // MicCapture silently stops appending at the cap — auto-stop instead so the user isn't
        // "recording" dead air. inputLevel publishes ~5 Hz while recording, so this checks often enough.
        .onReceive(engine.$inputLevel) { _ in
            guard engine.isMicRecording, engine.now() - engine.micStartTime >= AudioDefaults.maxSampleSeconds else { return }
            toggleMic()
            flash("Hit the \(Int(AudioDefaults.maxSampleSeconds))s limit — recording saved")
        }
        .overlay(alignment: .bottom) { if let c = confirm { toast(c) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { handleImport($0) }
        .fileImporter(isPresented: $sf2Importing, allowedContentTypes: [UTType(filenameExtension: "sf2") ?? .data], allowsMultipleSelection: false) { handleSF2($0) }
        .confirmationDialog("Replace pad sounds?", isPresented: Binding(get: { pendingSplit != nil }, set: { if !$0 { pendingSplit = nil } }), titleVisibility: .visible) {
            let kind = pendingSplit
            Button("Split & Replace") { if kind == .four { splitFourStems() } else { splitStems() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stems replace the sounds on the first \(pendingSplit == .four ? 4 : 2) pads in Bank \(project.bank). You can undo it."
                 + (pendingSplit == .four ? " Only the first \(Int(FourStemSeparator.maxSeconds))s is separated." : ""))
        }
    }

    enum StemSplitKind { case two, four }

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
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16).fill(settings.panel)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
                if let s = sample {
                    sampleWaveLayer(s, size: g.size)
                    waveOverlays(s, size: g.size)
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
                    // VO route into the zoom the pinch gesture provides (C2 a11y) — lives on the always-present button.
                    .accessibilityAction(named: Text("Zoom in")) { setWaveZoom(waveZoom * 2) }
                    .accessibilityAction(named: Text("Zoom out")) { setWaveZoom(waveZoom / 2) }
                    .accessibilityAction(named: Text("Reset zoom")) { resetWaveZoom() }
                } else {
                    Text("Record, import or resample audio to start chopping. Slices map straight onto your pads, or play the whole sample chromatically as an instrument.")
                        .font(FDFont.ui(14)).foregroundStyle(settings.inkDim)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "wave")
            .contentShape(Rectangle())
            // Pinch to zoom around the pinch point; child gestures (handles, slice marks, button) win over these.
            .gesture(MagnifyGesture()
                .onChanged { v in
                    guard has else { return }
                    let base = pinchBase ?? waveZoom
                    pinchBase = base
                    setWaveZoom(base * v.magnification, anchor: max(0, min(1, v.startLocation.x / w)))
                }
                .onEnded { _ in pinchBase = nil })
            // One-finger pan when zoomed in (no-op at ×1, so it never fights the trim/slice columns' drags).
            .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .named("wave"))
                .onChanged { v in
                    guard has, waveZoom > 1.001 else { return }
                    let base = panBase ?? waveStart
                    panBase = base
                    waveStart = min(max(0, base - v.translation.width / (w * waveZoom)), 1 - 1 / waveZoom)
                }
                .onEnded { _ in panBase = nil })
            .onTapGesture(count: 2) { resetWaveZoom() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if gpuBuf == nil || gpuSig != sampleSig { refreshGPUWave() } }   // cached by signature — no full rebuild on every tab entry (P3)
        .onChange(of: sampleSig) { _, _ in
            guard !gainDragging else { return }   // debounced to drag end (P1) — setGain's onEditingChanged rebuilds once
            refreshGPUWave()
        }
        // New or re-cut audio (import, crop, stretch) → show the whole thing again.
        .onChange(of: "\(sample?.name ?? "")|\(String(format: "%.4f", sample?.dur ?? 0))") { _, _ in
            waveZoom = 1; waveStart = 0
        }
    }

    /// Trim dims, slice marks, handles, playhead and zoom HUD — all mapped through the zoom window (C2).
    @ViewBuilder private func waveOverlays(_ s: SampleState, size: CGSize) -> some View {
        let w = size.width
        let trim = s.trim
        let tx0 = min(max(0, waveX(trim[0], w)), w)
        let tx1 = min(max(0, waveX(trim[1], w)), w)
        dim(x: 0, w: tx0)
        dim(x: tx1, w: w - tx1)
        ForEach(Array(s.slices.enumerated()), id: \.offset) { (i, p) in
            if waveX(p, w) > -30, waveX(p, w) < w + 30 { sliceMark(i: i, f: p, width: w) }
        }
        // Off-window handles are hidden (not pinned) so an edge column always drags the edge it shows.
        if waveX(trim[0], w) > -40, waveX(trim[0], w) < w + 40 { handle(side: "l", f: trim[0], width: w) }
        if waveX(trim[1], w) > -40, waveX(trim[1], w) < w + 40 { handle(side: "r", f: trim[1], width: w) }
        if let pp = playPos, waveX(pp, w) >= 0, waveX(pp, w) <= w {
            Rectangle().fill(.white).frame(width: 2).shadow(color: .white, radius: 4)
                .position(x: waveX(pp, w), y: size.height / 2).frame(height: size.height)
                .allowsHitTesting(false)
        }
        if waveZoom > 1.001 { zoomHUD(width: w) }
    }

    /// "×N" chip (tap to reset) + a mini-map bar showing which part of the sample is on screen.
    @ViewBuilder private func zoomHUD(width: Double) -> some View {
        let inset: Double = 12
        Capsule().fill(settings.line.opacity(0.55)).frame(width: max(0, width - inset * 2), height: 3)
            .offset(x: inset, y: 7).allowsHitTesting(false).accessibilityHidden(true)
        Capsule().fill(settings.accent.opacity(0.9))
            .frame(width: max(10, (width - inset * 2) / waveZoom), height: 3)
            .offset(x: inset + waveStart * (width - inset * 2), y: 7)
            .allowsHitTesting(false).accessibilityHidden(true)
        HStack {
            Spacer()
            Button { resetWaveZoom() } label: {
                Text(String(format: waveZoom >= 9.95 ? "×%.0f" : "×%.1f", waveZoom))
                    .font(FDFont.mono(10, .bold)).foregroundStyle(settings.ink)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(settings.panel2.opacity(0.92)))
                    .overlay(Capsule().stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("Waveform zoom"))
            .accessibilityValue(Text(String(format: "%.1f times", waveZoom)))
            .accessibilityHint(Text("Adjust to zoom, or double-tap to reset"))
            .accessibilityAdjustableAction { dir in
                setWaveZoom(dir == .increment ? waveZoom * 2 : waveZoom / 2)
            }
        }
        .padding(.top, 14).padding(.trailing, 12)
    }

    /// Base waveform layer: the AudioKit GPU Waveform (true min/max of the edited buffer, themed to the
    /// accent) when the raw buffer is available; falls back to the CPU peak Canvas (e.g. right after a
    /// project restore before the engine buffer is rehydrated). Overlays (trim/slices/playhead) sit on top.
    @ViewBuilder private func sampleWaveLayer(_ s: SampleState, size: CGSize) -> some View {
        if gainDragging {
            waveCanvas(s, size: size)   // live CPU amplitude while the gain drag suppresses GPU rebuilds (P1)
        } else if let buf = gpuBuf, buf.count > 1 {
            // Zoom = a start/length window into the SAME SampleBuffer — the renderer identity-checks
            // the buffer, so pinch/pan never rebuilds the Metal mip pyramid (C2).
            let len = max(2, min(buf.count, Int(Double(buf.count) / waveZoom)))
            let st = max(0, min(buf.count - len, Int(waveStart * Double(buf.count))))
            Waveform(samples: buf, start: st, length: len)
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
                let f = waveFrac(x, sz.width)   // honor the zoom window (C2)
                let amp = s.wave[max(0, min(n - 1, Int(f * Double(n))))]
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
    private func sliceMark(i: Int, f: Double, width: Double) -> some View {
        let hitW: Double = 26   // narrow drag column centred on the mark — nudgeable without swallowing the pan (C3)
        return ZStack(alignment: .top) {
            Rectangle().fill(settings.theme.perfect.opacity(0.9)).frame(width: 2).frame(maxHeight: .infinity)
            Text("\(i + 1)").font(FDFont.mono(9)).foregroundStyle(settings.theme.perfect).offset(x: 8, y: 4)
        }
        .frame(width: hitW).frame(maxHeight: .infinity).contentShape(Rectangle())
        .offset(x: waveX(f, width) - hitW / 2)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("wave"))
            .onChanged { v in
                guard var s = project.sample, i < s.slices.count else { return }
                if sliceDrag?.idx != i {
                    _ = project.checkpoint("sliceDrag", coalesce: false)   // one undo step per drag
                    sliceDrag = (i, s.slices[i])
                }
                let nf = (sliceDrag?.orig ?? s.slices[i]) + v.translation.width / (width * waveZoom)
                s.slices[i] = clampSliceFrac(nf, at: i, in: s)
                s.count = 0   // hand-tuned — no longer an equal-region grid
                project.sample = s
            }
            .onEnded { _ in sliceDrag = nil; snapSlice(i) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Slice \(i + 1) marker"))
        .accessibilityValue(Text("\(Int(f * 100)) percent"))
        .accessibilityHint(Text("Adjust to move the slice point"))
        .accessibilityAdjustableAction { dir in
            guard var s = project.sample, i < s.slices.count else { return }
            _ = project.checkpoint("sliceDrag", coalesce: true)   // merge repeated VO steps into one undo
            let nf = s.slices[i] + (dir == .increment ? 0.01 : -0.01)
            s.slices[i] = clampSliceFrac(nf, at: i, in: s)
            s.count = 0
            project.sample = s
        }
    }
    /// Keep a dragged slice between its neighbors (with a hair of daylight).
    private func clampSliceFrac(_ f: Double, at i: Int, in s: SampleState) -> Double {
        let lo = i > 0 ? s.slices[i - 1] + 0.004 : 0
        let hi = i + 1 < s.slices.count ? s.slices[i + 1] - 0.004 : 0.999
        return max(lo, min(hi, f))
    }
    /// Snap a just-moved slice to the nearest zero crossing within ±5 ms (SAMPLING-04). Slice fractions
    /// index the FORWARD pristine buffer (Reverse-tool mirroring happens at use — sliceWindow).
    private func snapSlice(_ i: Int) {
        guard var s = project.sample, i < s.slices.count else { return }
        let buf = engine.currentSampleOriginal()
        guard buf.count > 1 else { return }
        let idx = Project.nearestZeroCross(buf, near: Int(s.slices[i] * Double(buf.count)),
                                           within: Int(0.005 * engine.sampleRate))
        s.slices[i] = clampSliceFrac(Double(idx) / Double(buf.count), at: i, in: s)
        project.sample = s
    }
    /// Snap a released trim edge to the nearest zero crossing within ±5 ms (SAMPLING-04). Trim fractions
    /// index the EDITED buffer (that's the playback + crop geometry). Edges parked at 0/1 stay put.
    private func snapTrim(_ side: String) {
        guard var s = project.sample else { return }
        let i = side == "l" ? 0 : 1
        guard s.trim[i] > 0.001, s.trim[i] < 0.999 else { return }
        let buf = engine.currentSampleData()
        guard buf.count > 1 else { return }
        let idx = Project.nearestZeroCross(buf, near: Int(s.trim[i] * Double(buf.count)),
                                           within: Int(0.005 * engine.sampleRate))
        let f = Double(idx) / Double(buf.count)
        if side == "l" { s.trim[0] = max(0, min(f, s.trim[1] - 0.02)) } else { s.trim[1] = min(1, max(f, s.trim[0] + 0.02)) }
        project.sample = s
    }
    private func handle(side: String, f: Double, width: Double) -> some View {
        let hw: Double = 30   // hit-column width — must stay narrow so it doesn't swallow the whole waveform
        return ZStack {
            // Distinct chrome (C4): full-height white stem + white grip with an ink ridge — readable
            // over full-height accent peaks, unlike the old accent-on-accent fill.
            Rectangle().fill(.white.opacity(0.85)).frame(width: 2).frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: 5).fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.55), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 1).fill(.black.opacity(0.55)).frame(width: 2, height: 16))
                .frame(width: 14, height: 40)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
        .frame(width: hw).frame(maxHeight: .infinity).contentShape(Rectangle())
        .offset(x: max(0, min(width - hw, waveX(f, width) - hw / 2)))   // narrow column centred on the trim edge
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave"))
            .onChanged { v in
                guard var s = project.sample else { return }
                // Drag by delta from where the finger landed (C5) — no teleport to location.x.
                let orig = trimDragOrig[side] ?? (side == "l" ? s.trim[0] : s.trim[1])
                trimDragOrig[side] = orig
                let nf = orig + v.translation.width / (width * waveZoom)
                if side == "l" { s.trim[0] = max(0, min(nf, s.trim[1] - 0.02)) }
                else { s.trim[1] = min(1, max(nf, s.trim[0] + 0.02)) }
                project.sample = s
            }
            .onEnded { _ in trimDragOrig[side] = nil; snapTrim(side) })
        .accessibilityLabel(Text(side == "l" ? "Trim start" : "Trim end"))
        .accessibilityValue(Text("\(Int((side == "l" ? (project.sample?.trim[0] ?? 0) : (project.sample?.trim[1] ?? 1)) * 100)) percent"))
        .accessibilityHint(Text("Drag to adjust the sample trim region"))
        .accessibilityAdjustableAction { dir in   // A1 — the one adjustable-action gap the VO pass missed
            guard var s = project.sample else { return }
            let step = dir == .increment ? 0.01 : -0.01
            if side == "l" { s.trim[0] = max(0, min(s.trim[0] + step, s.trim[1] - 0.02)) }
            else { s.trim[1] = min(1, max(s.trim[1] + step, s.trim[0] + 0.02)) }
            project.sample = s
        }
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
                if engine.isMicRecording { recordingMeter }   // elapsed time + live input level next to Stop
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
                // E1: the six tones collapsed behind one menu so the row fits on-screen — they were
                // stranded past an invisible horizontal scroll.
                Menu {
                    ForEach(SOURCES, id: \.kind) { src in
                        Button { loadSource(src.kind, src.label) } label: {
                            Label(src.label, systemImage: src.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(settings.accent)
                        Text("Demo Tones").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                        Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(settings.inkDim)
                    }
                    .padding(.horizontal, 14).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                        SOURCES.contains { $0.kind == sample?.kind } ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                }
                .accessibilityLabel(Text("Demo tones"))
                .accessibilityHint(Text("Load a built-in synthesized tone to chop and stretch"))
            }
        }
        // Overflow affordance (E1): content that scrolls off fades out instead of cutting mid-button.
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [settings.theme.bg.opacity(0), settings.theme.bg.opacity(0.85)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 26)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Elapsed time + live input level while the mic is recording (re-rendered by the ~5 Hz
    /// `inputLevel` publishes). Warns as the shared max-length cap approaches.
    private var recordingMeter: some View {
        let elapsed = max(0, engine.now() - engine.micStartTime)
        let cap = AudioDefaults.maxSampleSeconds
        let nearCap = elapsed >= cap - 10
        return HStack(spacing: 10) {
            Text(String(format: "%d:%04.1f", Int(elapsed) / 60, elapsed.truncatingRemainder(dividingBy: 60)))
                .font(FDFont.mono(13, .bold)).foregroundStyle(nearCap ? settings.theme.miss : settings.ink)
            ZStack(alignment: .leading) {
                Capsule().fill(settings.panel)
                Capsule().fill(engine.inputLevel > 0.9 ? settings.theme.miss : settings.accent)
                    .frame(width: 64 * CGFloat(min(1, engine.inputLevel)))
            }
            .frame(width: 64, height: 6)
            if nearCap {
                Text("\(Int(cap))s max").font(FDFont.mono(9, .bold)).foregroundStyle(settings.theme.miss)
            }
        }
        .padding(.horizontal, 14).frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.theme.miss.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording"))
        .accessibilityValue(Text("\(Int(elapsed)) seconds\(nearCap ? ", near the \(Int(cap)) second limit" : "")"))
    }

    // MARK: side

    private var side: some View {
        ScrollView {
            // E2/A2: no sample → one explanatory card instead of a dimmed wall of ~25 disabled controls
            // (which VoiceOver had to swipe through one by one). The real panels return in place on load.
            if has { editPanels } else { emptySidePanel }
        }
        .scrollIndicators(.hidden)
    }

    private var emptySidePanel: some View {
        PanelCard(title: "Editor") {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus").font(.system(size: 30)).foregroundStyle(settings.inkFaint)
                Text("Load or record a sample to unlock editing")
                    .font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                    .multilineTextAlignment(.center)
                Text("Trim, shape and chop it here — then send slices to the pads or play it on the Synth.")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
    }

    private var editPanels: some View {
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
                        // C8: labelled for what it actually does — clears edits on the CURRENT audio.
                        // It can't resurrect pre-crop audio; Undo is that path (the ring keeps the import).
                        actionButton("↺ Clear Edits") { reset() }
                    }
                }

                PanelCard(title: "Shape") {
                    sliderRow("Gain", value: Binding(get: { sample?.gain ?? 1 }, set: { setGain($0) }), range: 0...2,
                              readout: "\(Int((sample?.gain ?? 1) * 100))%",
                              onEditingChanged: { editing in   // debounce the GPU-pyramid rebuild to drag end (P1)
                                  gainDragging = editing
                                  if !editing { refreshGPUWave() }
                              })
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
                        }.buttonStyle(.plain).disabled(!has || analysisBusy).opacity(has && !analysisBusy ? 1 : 0.4)
                        if let off = sample?.tuneOffset, off != 0 {
                            Text("Tuned \(off > 0 ? "+" : "")\(off) st — kept on top of the Pitch slider")
                                .font(FDFont.mono(10, .bold)).foregroundStyle(settings.accent)
                        }
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
                        if analysisBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Analyzing…").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.accent)
                            }.accessibilityElement().accessibilityLabel(Text("Analyzing sample, please wait"))
                        }
                        Text("Pitch-preserving (WSOLA). Fit Tempo snaps the loop to whole beats at \(project.bpm) BPM. Detect analyzes the sample and sets the song tempo + key.")
                            .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(analysisBusy)
                    .opacity(analysisBusy ? 0.75 : 1)

                    PanelCard(title: "Stem Split") {
                        actionButton("⎘ Split → Drums / Melody", wide: true) { pendingSplit = .two }
                            .disabled(stemBusy).opacity(stemBusy ? 0.5 : 1)
                        actionButton("⎙ Split → 4 Stems", wide: true) { pendingSplit = .four }
                            .disabled(stemBusy).opacity(stemBusy ? 0.5 : 1)
                        if stemBusy {
                            HStack(spacing: 8) {
                                if let p = stemProgress {   // determinate chunk progress from the 4-stem loop (S2)
                                    ProgressView(value: p).progressViewStyle(.linear).tint(settings.accent)
                                    Text("\(Int(p * 100))%").font(FDFont.mono(11, .bold)).foregroundStyle(settings.accent)
                                } else {
                                    ProgressView().controlSize(.small)
                                    Text("Separating stems…").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.accent)
                                    Spacer(minLength: 4)
                                }
                                Button { stemTask?.cancel() } label: {   // a slow model download shouldn't be a wall (S1)
                                    Text("Cancel").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.inkDim)
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .fdCard(8, fill: settings.panel2)
                                }.buttonStyle(.plain)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(stemProgress.map { "Separating stems, \(Int($0 * 100)) percent" } ?? "Separating stems, please wait"))
                        }
                        if let err = stemError {   // persistent — the toast alone evaporates in 1.9 s (S3)
                            Text(err).font(FDFont.ui(11.5, .semibold)).foregroundStyle(settings.theme.miss)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Drums/Melody is on-device, no model. 4 Stems (vocals/drums/bass/other) uses a Core ML model downloaded once on first use, then separates the first \(Int(FourStemSeparator.maxSeconds))s on the Neural Engine (a few seconds).")
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
                        // Relocated from the source row (E5): it never produced a sample — it loads an
                        // instrument onto the Synth keyboard, so it lives with the other → Synth actions.
                        Button { sf2Importing = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "pianokeys")
                                Text("Load .sf2 → Synth").font(FDFont.ui(12, .semibold))
                            }
                            .foregroundStyle(settings.ink)
                            .frame(maxWidth: .infinity).frame(height: 40)
                            .fdCard(10, fill: settings.panel2)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(Text("Load SoundFont onto the Synth keyboard"))
                        Text("**Play Chromatically** repitches the whole sample (sampler). **Wavetable** grabs one cycle → a true live oscillator. **Load .sf2** puts a SoundFont instrument on the Synth keyboard.")
                            .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                }

                CoachNote("**Transients** are the sharp attacks at the start of each sound. Slicing on transients keeps chops tight and on-beat.")
            }
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
    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String,
                           onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(FDFont.ui(12.5, .medium)).foregroundStyle(settings.inkDim)
                Spacer()
                Text(readout).font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
            }
            Slider(value: value, in: range, onEditingChanged: onEditingChanged).tint(settings.accent).disabled(!has)
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
    /// Both passes autocorrelate the whole buffer — seconds of work on a long sample, so they run
    /// off-main with a busy state and apply on the main actor (P2; splitStems is the template).
    private func detectTempoKey() {
        guard sample != nil, !analysisBusy else { return }
        analysisBusy = true
        let src = engine.currentSampleForStems()   // same original buffer the old on-main path analyzed
        Task.detached(priority: .userInitiated) {
            let bpm = SynthCore.detectTempo(src.data, sr: src.sr)
            let key = SynthCore.detectKey(src.data, sr: src.sr)
            await MainActor.run {
                analysisBusy = false
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
        }
    }
    /// Split the loaded sample into drums + melody stems and drop them onto the first two pads (D1).
    private func splitStems() {
        guard sample != nil, !stemBusy else { return }
        stemBusy = true; stemError = nil; stemProgress = nil; flash("Separating stems…")
        let src = engine.currentSampleForStems()   // grab the buffer on-main, then do the heavy STFT off-main
        stemTask = Task.detached(priority: .userInitiated) {
            let (h, p) = StemSplit.harmonicPercussive(src.data, sr: src.sr)   // was a synchronous main-actor call → UI freeze
            await MainActor.run {
                stemBusy = false; stemTask = nil
                guard !Task.isCancelled else { flash("Stem split cancelled"); return }
                guard !p.isEmpty, !h.isEmpty else {
                    stemError = "Couldn't split this sample — try a longer or louder region."
                    flash("Couldn't split this sample"); return
                }
                let drumID = Kit.pads[0].id, melID = Kit.pads[1].id
                project.setPadSamples([(drumID, p, "Drums"), (melID, h, "Melody")], bank: project.bank)   // one undo step, this bank only (F0)
                flash("Split → Drums on \(Kit.padByID[drumID]?.label ?? "pad 1") · Melody on \(Kit.padByID[melID]?.label ?? "pad 2")")
            }
        }
    }
    /// Split into 4 stems via the Core ML model, downloading it on demand (On-Demand Resource) the first
    /// time. Falls back to the 2-way split if the model can't be fetched or run. Off-main; applies on main.
    /// Cancellable between inference chunks (S1); reports determinate chunk progress (S2).
    private func splitFourStems() {
        guard sample != nil, !stemBusy else { return }
        stemBusy = true; stemError = nil; stemProgress = nil
        flash(FourStemSeparator.modelAvailable ? "Separating 4 stems… this can take a moment" : "Getting the 4-stem model…")
        let src = engine.currentSampleForStems()
        stemTask = Task.detached(priority: .userInitiated) {
            guard await FourStemSeparator.ensureModel() else {   // downloads the ODR model if not present
                await MainActor.run {
                    stemBusy = false; stemTask = nil
                    if Task.isCancelled { flash("Stem split cancelled"); return }
                    stemError = "Couldn't get the 4-stem model — check the connection and retry. Used Drums/Melody instead."
                    flash("Couldn't get the 4-stem model — using Drums/Melody")
                    splitStems()
                }
                return
            }
            if Task.isCancelled {
                await MainActor.run { stemBusy = false; stemTask = nil; flash("Stem split cancelled") }
                return
            }
            await MainActor.run { flash("Separating 4 stems… this can take a moment") }
            let stems = FourStemSeparator.separate(src.data, engineSR: src.sr) { p in
                Task { @MainActor in if stemBusy { stemProgress = p } }
            }
            await MainActor.run {
                stemBusy = false; stemTask = nil; stemProgress = nil
                guard !Task.isCancelled else { flash("Stem split cancelled"); return }
                // The model can fail to run where there's no Neural Engine (e.g. the Simulator) or under a
                // compute error — fall back to the on-device 2-way split instead of a dead end.
                guard let stems, !stems.isEmpty else {
                    stemError = "The 4-stem model couldn't run on this device — used Drums/Melody instead."
                    flash("4-stem model couldn't run here — using Drums/Melody")
                    splitStems()
                    return
                }
                project.setPadSamples(stems.prefix(Kit.pads.count).enumerated().map { (Kit.pads[$0].id, $1.audio, $1.name) },
                                      bank: project.bank)   // one undo step, this bank only (F0)
                let srcSec = Double(src.data.count) / src.sr
                let trimmed = srcSec > FourStemSeparator.maxSeconds + 0.25 ? " · first \(Int(FourStemSeparator.maxSeconds))s" : ""
                flash("Split into \(stems.count) stems → first \(min(stems.count, Kit.pads.count)) pads\(trimmed)")
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
        Task {   // off-main decode so the UI doesn't hitch on a long file (Phase 2)
            guard let data = await engine.decodeAudioFileAsync(url: url, maxSeconds: AudioDefaults.maxSampleSeconds),
                  !data.isEmpty else { flash("Couldn't read that audio file"); return }
            // Checkpoint only on decode SUCCESS (C7): mutateSample captures the prior buffer right before
            // importBuffer replaces it, so a failed decode leaves no junk undo step and an edit made
            // during a long decode can't interleave between capture and apply.
            var dur = 0.0
            project.mutateSample("import") {
                let r = engine.importBuffer(data)
                project.sample = SampleState(name: name.isEmpty ? "Imported" : name, kind: "import",
                                             dur: r.dur, wave: r.wave, transients: r.transients)
                project.sliceBank = nil
                dur = r.dur
            }
            // Surface truncation instead of silently keeping only the first N seconds (#SAMPLING-03).
            if dur >= AudioDefaults.maxSampleSeconds - 0.25 {
                flash("Imported \(name) · trimmed to \(Int(AudioDefaults.maxSampleSeconds))s")
            } else {
                flash("Imported \(name) · \(String(format: "%.1f", dur))s")
            }
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
                openTab("synth")   // land where the instrument actually went, like toSynthKeys (E5)
            } else {
                flash("Couldn't parse that SoundFont")
            }
        }
    }

    /// Capture the last few seconds of the live studio output (all tabs) into a new sample.
    private func resampleMix() {
        stopAudition()
        engine.start()
        // E3: a capture with no real signal must NOT replace the loaded sample — trim + threshold first,
        // and only commit (undoably) when there's something worth keeping.
        guard let d = engine.captureMixOutput() else { flash("Play a beat, then Resample Mix"); return }
        project.mutateSample("resample") {   // captures the prior sample's audio BEFORE importBuffer overwrites it
            let r = engine.importBuffer(d)
            project.sample = SampleState(name: "Resampled Mix", kind: "mix", dur: r.dur, wave: r.wave, transients: r.transients)
            project.sliceBank = nil
        }
        flash("Captured \(String(format: "%.1f", Double(d.count) / engine.sampleRate))s of the mix")
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
            // Zero-cross-snap the crop boundaries so the new sample can't start/end on a click (SAMPLING-04) —
            // covers trims set by VoiceOver steps or restored state that never went through a drag release.
            let buf = engine.currentSampleData()
            if buf.count > 1 {
                let n = Double(buf.count), zc = Int(0.005 * engine.sampleRate)
                if s.trim[0] > 0.001 { s.trim[0] = Double(Project.nearestZeroCross(buf, near: Int(s.trim[0] * n), within: zc)) / n }
                if s.trim[1] < 0.999 { s.trim[1] = Double(Project.nearestZeroCross(buf, near: Int(s.trim[1] * n), within: zc)) / n }
            }
            let r = engine.cropSample(trim: s.trim)
            s.dur = r.dur; s.wave = r.wave; s.trim = [0, 1]; s.slices = []; s.count = 0
            s.tools = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]; s.gain = 1
            project.sample = s
            flash("Cropped to \(String(format: "%.2f", r.dur))s")
        }
    }
    private func applyStretch(_ ratio: Double) {
        guard project.sample != nil, abs(ratio - 1) > 0.01, !analysisBusy else { return }
        analysisBusy = true
        // WSOLA over the full buffer is seconds of work on a long sample — run it off-main and commit
        // on the main actor (P2). Stretch bakes the current edits, like the old stretchSample path.
        let src = (data: engine.currentSampleData(), sr: engine.sampleRate)
        Task.detached(priority: .userInitiated) {
            let stretched = wsolaStretch(src.data, ratio: ratio, sr: src.sr)
            await MainActor.run {
                analysisBusy = false
                guard !stretched.isEmpty else { flash("Couldn't stretch this sample"); return }
                project.mutateSample("stretch") {
                    guard var s = project.sample else { return }
                    let r = engine.importBuffer(stretched)
                    s.dur = r.dur; s.wave = r.wave; s.transients = r.transients; s.trim = [0, 1]; s.slices = []; s.count = 0
                    s.tools = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]; s.gain = 1
                    project.sample = s
                    flash("Stretched to \(String(format: "%.2f", r.dur))s")
                }
                stretchRatio = 1.0
            }
        }
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
            s.pitch = 0; s.tuneOffset = 0; s.loop = false   // C8: "Clear Edits" clears ALL the shaping, consistently
            project.sample = s
        }
        if looping { stopAudition() }
        flash("Edits cleared — Undo steps back through earlier versions")
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
        engine.stopSampleAudition()   // actually silence the sounding sample voice, not just the UI timer (#SAMPLING-05)
    }

    private func audition() {
        if looping { stopAudition(); return }       // Audition is "Stop" while looping
        guard let s = sample else { return }
        engine.start()
        looping = s.loop
        playOnce(s)
        auditionTask?.cancel()
        auditionTask = Task { @MainActor in
            // C6: track the ENGINE clock, not Date() — the playhead can't drift against what's sounding,
            // and loop re-triggers are scheduled ahead on the audio clock, so they land sample-accurately.
            var start = engine.now() + 0.003   // playBuffer's default start latency
            var scheduledNext = false
            let tick: UInt64 = reduceMotion ? 100_000_000 : 33_000_000   // ~30 Hz UI; slower under Reduce Motion
            let lookahead = reduceMotion ? 0.25 : 0.1                    // ≥ 2 ticks, so the schedule window can't be missed
            while !Task.isCancelled {
                guard let cur = project.sample else { break }
                let dur = (cur.trim[1] - cur.trim[0]) * cur.dur
                let rate = pow(2, effPitch(cur) / 12.0)
                let outDur = max(0.05, dur / rate)
                let e = engine.now() - start
                if cur.loop, !scheduledNext, e >= outDur - lookahead {
                    playOnce(cur, at: start + outDur)   // queue the next pass in advance — no re-trigger jitter
                    scheduledNext = true
                }
                if e >= outDur {
                    if cur.loop { start += outDur; scheduledNext = false }
                    else { playPos = nil; looping = false; return }
                } else if e >= 0 {
                    playPos = cur.trim[0] + (e * rate) / cur.dur
                }
                try? await Task.sleep(nanoseconds: tick)
            }
        }
    }
    /// Playback pitch = user Pitch slider + the Tune-to-Key offset, applied additively (UX #63).
    private func effPitch(_ s: SampleState) -> Double { Double(s.pitch + s.tuneOffset) }

    private func playOnce(_ s: SampleState, at when: Double? = nil) {
        let off = s.trim[0] * s.dur, dur = (s.trim[1] - s.trim[0]) * s.dur
        engine.playBuffer(offset: off, dur: dur, vel: 0.95, when: when, pitch: effPitch(s))
        if s.harmonize { for h in harmonyOffsets() { engine.playBuffer(offset: off, dur: dur, vel: 0.55, when: when, pitch: effPitch(s) + Double(h)) } }
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
        guard let s0 = project.sample, s0.dur > 0.05 else { flash("Load a sample first"); return }
        guard !analysisBusy else { return }
        analysisBusy = true
        let src = (data: engine.currentSampleData(), sr: engine.sampleRate)
        Task.detached(priority: .userInitiated) {   // pitch detect off-main, like the sibling analyses (P2)
            let hz = SynthCore.autocorrelationPitch(src.data, sr: src.sr)
            await MainActor.run {
                analysisBusy = false
                guard hz > 20 else { flash("Couldn't detect a clear pitch"); return }
                guard var s = project.sample else { return }
                let midi = Int((69 + 12 * log2(hz / 440)).rounded())
                let snapped = nearestScaleMidi(midi)
                let delta = snapped - midi
                project.checkpoint("tune", coalesce: false)   // C1 — was the screen's only non-undoable sample mutation
                // The correction lives in its own tuneOffset, NOT the ±12 Pitch slider field, so a later
                // slider touch can't silently destroy the tuning (UX #63).
                s.tuneOffset = max(-12, min(12, delta))
                project.sample = s
                let note = Music.noteName(snapped)
                flash("\(Int(hz)) Hz → \(note) (\(delta >= 0 ? "+" : "")\(delta) st)")
                playOnce(s)
            }
        }
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
    /// A slice's window on the CURRENT (edited) buffer. A baked Reverse tool flips the audio while
    /// slices/transients were detected on the forward buffer — mirror the window so audition, extract
    /// and assign all cut where the transient actually is (F3). (Reverse slice ORDER is separate.)
    private func sliceWindow(_ s: SampleState, _ i: Int) -> (a: Double, b: Double) {
        let a = s.slices[i], b = i + 1 < s.slices.count ? s.slices[i + 1] : 1
        return (s.tools["reverse"] ?? false) ? (1 - b, 1 - a) : (a, b)
    }

    /// Extract the selected slice's audio as a new one-shot on the matching pad (MPC SHIFT+B1 Extract).
    private func extractSlice() {
        guard let s = project.sample, let i = selectedSlice, i < s.slices.count else { return }
        let buf = engine.currentSampleData()   // the EDITED buffer, so extracted chops match what was auditioned (#SAMPLING-02)
        guard !buf.isEmpty else { flash("No audio to extract"); return }
        let (a, b) = sliceWindow(s, i)
        var lo = max(0, min(buf.count, Int(a * Double(buf.count))))
        var hi = max(lo, min(buf.count, Int(b * Double(buf.count))))
        let zc = Int(0.005 * engine.sampleRate)   // click-free chop edges (SAMPLING-04)
        if lo > 0 { lo = Project.nearestZeroCross(buf, near: lo, within: zc) }
        if hi < buf.count { hi = Project.nearestZeroCross(buf, near: hi, within: zc) }
        guard hi > lo else { return }
        let padID = Kit.pads[min(i, Kit.pads.count - 1)].id
        project.setPadSample(padID, data: Array(buf[lo..<hi]), name: "Chop \(i + 1)", bank: "C")   // chops live on Bank C (F0)
        flash("Extracted slice \(i + 1) → pad \(min(i, Kit.pads.count - 1) + 1) on Bank C")
    }
    private func equalSlices(_ n: Int) {
        guard var s = project.sample else { return }
        project.checkpoint("slices", coalesce: false)
        s.slices = (0..<n).map { Double($0) / Double(n) }; s.count = n; project.sample = s
    }
    private func playSlice(_ idx: Int) {
        guard let s = sample else { return }
        engine.start()
        let (a, b) = sliceWindow(s, idx)
        let off = a * s.dur, dur = (b - a) * s.dur
        engine.playBuffer(offset: off, dur: dur, vel: 0.95, pitch: effPitch(s))
        if s.harmonize { for h in harmonyOffsets() { engine.playBuffer(offset: off, dur: dur, vel: 0.55, pitch: effPitch(s) + Double(h)) } }
    }
    private func assignToPads() {
        guard let s = sample, !s.slices.isEmpty else { return }
        // Extract each slice's audio onto its pad as a real one-shot — so the chops are playable
        // in the sequencer and bounce into export (not the old bank-C-only sliceBank dead-end).
        // Assignment is Bank-C-scoped (F0): the Bank A/B drum kit keeps its sounds.
        let n = project.assignSlicesToPads(buffer: engine.currentSampleData(), slices: s.slices,
                                           reverse: s.reverseSlices, mirror: s.tools["reverse"] ?? false)   // EDITED buffer → chops match audition + export (#SAMPLING-02)
        guard n > 0 else { flash("No audio to slice"); return }
        project.setBank("C")
        flash("\(n) chops on Bank C — tap to play, sequence them & they’ll export")
        openTab("pads")
    }
}
