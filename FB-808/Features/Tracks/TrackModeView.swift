//  TrackModeView.swift — arrangement timeline: song sections, draggable clips,
//  animated playhead. Ported from mode-track.jsx.

import SwiftUI
import AVFoundation
import Combine
import os
import UniformTypeIdentifiers

// 116 left ~50pt for the name once the dot, the ⋯ menu and the padding took their share, so even
// "Drums" truncated to "Dru…" (and the type line under it to "Dr..").
private let LABEL_W: CGFloat = 148
// The six seeded tracks are wired into Transport/Export/Build Song, so they can be renamed &
// recolored but not deleted; user-added tracks are fully removable.
private let LEGACY_TRACK_IDS: Set<String> = ["drums", "hats", "bass", "perc", "vox", "audio"]

struct TrackModeView: View {
    /// Jump to the Sequence tab. RootView owns the tab selection, so arranging can hand the user
    /// straight to the pattern they just tapped instead of making them find it
    /// (SEQUENCE_TRACKS_AUDIT finding 5). Optional so previews and tests can construct the view bare.
    var openSequenceTab: (() -> Void)? = nil
    var openSynthTab: (() -> Void)? = nil

    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore

    // Single source of truth for the arrangement length (matches Project.songBars & the transport wrap).
    private var BARS: Int { project.songBars }

    @State private var drag: (track: String, idx: Int, orig: Int)?
    @State private var audioDrag: (id: UUID, orig: Int)?
    @State private var resizeDrag: (track: String, idx: Int, orig: Int)?
    @State private var editClip: UUID?
    @State private var showRange = false
    @State private var rangeStart = 0
    @State private var rangeLen = 2
    @State private var importingAudio = false
    @State private var pendingAudioURL: URL?
    @State private var importTask: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var exportError: String?   // surface a failed render instead of silently stopping the spinner
    @State private var loopBars = 4                   // loop-mode export length (buildExportPlan loopBarsOverride)
    /// One export pipeline for audio, stems and MIDI: solo/mute confirm → song-vs-loop prompt → run (#export-1/3).
    fileprivate enum ExportJob { case audio(ExportFormat), stems, midi }
    @State private var pendingGate: ExportJob?        // solo/mute is on → "export as heard?"
    @State private var pendingJob: ExportJob?         // Song Mode off + arrangement → song vs loop
    @StateObject private var exportProg = ExportProgressBox()
    @State private var importNotice: String?          // what happened to an imported take (mono / trimmed)
    @State private var fullSection: Kit.Section?      // addSection hit the end of the timeline → offer to extend
    @State private var renameID: String?
    @State private var renameText = ""
    @State private var importTrackID = "audio"
    @State private var confirmBuildSong = false
    @State private var confirmDeleteTrack: Track?
    @State private var confirmDeleteSpace = false

    /// Header control cluster. `fixedSize`: on a narrow window the header used to squeeze these buttons
    /// until their labels broke mid-word ("Rang/e", "Expo/rt") — the hint text is dropped instead
    /// (ModeHead handles that), so the controls always render at their natural size.
    private var headControls: some View {
        HStack(spacing: 8) {
            if project.audioArmedTrack != nil {
                // compact armed cue — the full sentence used to live in the header and shove the row wide
                HStack(spacing: 5) {
                    Circle().fill(settings.theme.miss).frame(width: 7, height: 7)
                    Text("ARMED").font(FDFont.mono(10, .bold)).tracking(0.6).foregroundStyle(settings.theme.miss)
                }
                .padding(.horizontal, 9).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(settings.theme.miss.opacity(0.14)))
                .accessibilityLabel(Text("Audio armed — press record to record over the beat"))
                punchControl; recOffset
            }
            lengthButton
            songAutoButton
            rangeButton
            buildSongButton
            songToggle
            exportButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var phPos: Double {
        guard project.playing else { return 0 }
        let frac = project.step < 0 ? 0 : Double(project.step) / Double(max(1, project.barSteps))
        return (Double(project.bar) + frac) / Double(BARS)
    }

    var body: some View {
        VStack(spacing: 10) {
            TransportBar()
            VStack(alignment: .leading, spacing: 10) {
                ModeHead(title: "Tracks", eyebrow: "\(BARS) Bars",
                         hint: project.songMode ? "Song Mode · clips build the arrangement"
                                                : "Tap a lane to add a clip, drag to move") {
                    headControls
                }
                arrBox
                if project.songAutoTarget != "" { automationLane }
                palette
            }
        }
        .sheet(item: $exportFile) { f in
            ShareSheet(urls: f.urls)
        }
        .onDisappear { cancelAudioImport() }
        .onChange(of: project.projectID) { _, _ in cancelAudioImport() }
        .overlay(alignment: .top) {
            if importTask != nil {
                HStack { ProgressView(); Text("Importing audio…"); Button("Cancel") { cancelAudioImport() } }
                    .padding().background(.regularMaterial, in: Capsule())
            }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result { pendingAudioURL = urls.first }
        }
        .modifier(AudioImportChoice(url: $pendingAudioURL, maxSeconds: 60, allowsStereo: true) { url, stereo in
            handleAudioImport(.success([url]), stereo: stereo)
        })
        .alert("Rename Track", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let id = renameID { project.renameTrack(id, renameText) }; renameID = nil }
            Button("Cancel", role: .cancel) { renameID = nil }
        }
        .alert("Build a full song?", isPresented: $confirmBuildSong) {
            Button("Cancel", role: .cancel) {}
            Button("Build Song") { buildSong() }
        } message: { Text("Replaces the current arrangement with an Intro→Verse→Hook→Verse→Outro layout and turns on Song Mode. You can undo it afterwards.") }
        .alert("Delete “\(confirmDeleteTrack?.name ?? "track")”?", isPresented: Binding(get: { confirmDeleteTrack != nil }, set: { if !$0 { confirmDeleteTrack = nil } })) {
            Button("Cancel", role: .cancel) { confirmDeleteTrack = nil }
            Button("Delete", role: .destructive) { if let t = confirmDeleteTrack { project.removeTrack(t.id) }; confirmDeleteTrack = nil }
        } message: { Text("Removes the track and all its clips, automation, and recorded takes. You can undo it afterwards.") }
        .alert("Delete \(rangeLen) bar\(rangeLen == 1 ? "" : "s")?", isPresented: $confirmDeleteSpace) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { project.arrangeDeleteSpace(at: rangeStart, len: rangeLen) }
        } message: { Text("Removes these bars across every track and section and closes the gap. You can undo it afterwards.") }
        .modifier(ExportPrompts(exportError: $exportError, pendingJob: $pendingJob, pendingGate: $pendingGate,
                                importNotice: $importNotice, bars: BARS, loopBars: loopBars,
                                run: { j, full in run(j, fullSong: full) }, afterGate: { j in afterGate(j) }))
        .alert("Timeline is full", isPresented: Binding(get: { fullSection != nil }, set: { if !$0 { fullSection = nil } })) {
            if BARS < 64 {
                Button("Extend to \(min(64, BARS + 16)) bars") {
                    let sec = fullSection; fullSection = nil
                    project.setSongBars(min(64, BARS + 16))
                    if let sec { addSection(sec) }
                }
            }
            Button("Cancel", role: .cancel) { fullSection = nil }
        } message: { Text("All \(BARS) bars are used. Extend the song to add more sections.") }
    }

    private func cancelAudioImport() {
        importTask?.cancel(); importTask = nil; importGeneration = UUID()
    }
    private func handleAudioImport(_ result: Result<[URL], Error>, stereo: Bool) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        cancelAudioImport()
        let trackID = project.audioArmedTrack ?? "audio"
        let destination = project.operationDestination(), generation = importGeneration
        let atBar = project.playing ? project.bar : project.punchInBar
        let sr = engine.sampleRate, name = url.deletingPathExtension().lastPathComponent
        importTask = Task {
            let decoded = await Task.detached(priority: .userInitiated) {
                SampleEngine.decodeChannels(url: url, targetSR: sr, maxSeconds: AudioDefaults.maxSampleSeconds, stereo: stereo)
            }.value
            guard !Task.isCancelled, generation == importGeneration else { return }
            defer { importTask = nil }
            guard let decoded else { importNotice = "Couldn't read that audio file."; return }
            guard project.commitImportedClip(destination: destination, trackID: trackID, startBar: atBar,
                                             data: decoded.left, dataR: decoded.right, name: name) else { return }
            if decoded.sourceSeconds > AudioDefaults.maxSampleSeconds {
                importNotice = "Imported the first \(Int(AudioDefaults.maxSampleSeconds)) seconds, as selected."
            }
        }
    }

    private var exportButton: some View {
        HStack(spacing: 6) {
            exportMenu
            if exporting {
                Button { exportProg.cancel() } label: {
                    Text("Cancel").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.inkDim)
                        .padding(.horizontal, 10).frame(height: 32).fdCard(9, fill: settings.panel2)
                }.buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel export"))
            }
        }
    }
    private var exportMenu: some View {
        Menu {
            Button { startExport(.audio(.m4a)) } label: { Label(engine.hasHostedEffects ? "M4A · without AU effects" : "M4A · AAC (compressed)", systemImage: "waveform") }
            Button { startExport(.audio(.wav)) } label: { Label(engine.hasHostedEffects ? "WAV · without AU effects" : "WAV · lossless", systemImage: "waveform.path") }
            Button { startExport(.stems) } label: { Label(engine.hasHostedEffects ? "Stems · without master / AU effects" : "Stems · per-track WAV (pre-master, FX-dry)", systemImage: "square.stack.3d.up") }
            Button { startExport(.midi) } label: { Label("MIDI · .mid", systemImage: "pianokeys") }
            if !project.songMode {
                Menu {
                    ForEach([1, 2, 4, 8], id: \.self) { n in
                        Button { loopBars = n } label: { Label("\(n) bar\(n == 1 ? "" : "s")", systemImage: loopBars == n ? "checkmark" : "") }
                    }
                } label: { Label("Loop length · \(loopBars) bar\(loopBars == 1 ? "" : "s")", systemImage: "repeat") }
            }
        } label: {
            HStack(spacing: 7) {
                if exporting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                }
                Text(exporting ? (exportProg.value > 0 ? "Rendering \(Int(exportProg.value * 100))%" : "Rendering…") : "Export").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.theme.good))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(exporting || !hasContent)   // don't let the user export silence (#275)
        .opacity(exporting || !hasContent ? 0.55 : 1)
    }

    /// True when there's anything to render — guards against exporting an empty project. (Shared with the
    /// level-independent rail Share action via Project.hasExportableContent.)
    private var hasContent: Bool { project.hasExportableContent }

    private func startExport(_ job: ExportJob) {
        guard !exporting else { return }
        if project.mixGateActive { pendingGate = job; return }   // a forgotten solo/mute shapes the file (#export-1)
        afterGate(job)
    }
    private func afterGate(_ job: ExportJob) {
        if !project.songMode && !project.arrangement.isEmpty { pendingJob = job; return }
        run(job, fullSong: false)
    }
    private func run(_ job: ExportJob, fullSong: Bool) {
        switch job {
        case .audio(let f): runExport(f, fullSong: fullSong)
        case .stems: exportStems(fullSong: fullSong)
        case .midi: exportMIDI(fullSong: fullSong)
        }
    }
    private func exportMIDI(fullSong: Bool) {
        let loop: Int? = (fullSong || project.songMode) ? nil : loopBars
        Task {
            await Task.detached(priority: .utility) { sweepExportDirs() }.value   // off the main thread (#export-5)
            if let url = project.exportMIDIFile(loopBarsOverride: loop, songModeOverride: fullSong ? true : nil) { exportFile = ExportFile(urls: [url]) }
            else { exportError = "Couldn't export MIDI. Add some drum hits or melody notes first." }
        }
    }

    private func runExport(_ format: ExportFormat, fullSong: Bool) {
        guard !exporting else { return }
        exporting = true
        let plan = project.buildExportPlan(loopBarsOverride: (fullSong || project.songMode) ? nil : loopBars,
                                           songModeOverride: fullSong ? true : nil,
                                           safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither   // captured on the main actor before detaching
        let prog = exportProg; prog.reset()
        Task {
            await Task.detached(priority: .utility) { sweepExportDirs() }.value   // PRIOR batches, off-main (#227, #export-5)
            let dir = fd808ExportDir()   // one unique batch dir → re-exports never collide
            let result: Result<URL, ExportWriteFailure>? = await Task.detached(priority: .userInitiated) {
                let (l, r) = renderOffline(plan, progress: { p in prog.report(p) }, isCancelled: { prog.cancelled })
                if prog.cancelled { return nil }
                return writeAudio(format, left: l, right: r, sr: plan.sr, name: plan.name, dir: dir, dither: dither)
            }.value
            exporting = false
            switch result {
            case .success(let url)?: exportFile = ExportFile(urls: [url]); progress.awardCreative("export", 10)
            case .failure(let failure)?: exportError = failure.message   // names a real I/O cause, not "add some sounds" (#65)
            case nil: break   // cancelled by the user
            }
        }
    }

    private func exportStems(fullSong: Bool) {
        guard !exporting else { return }
        exporting = true
        // Same length choice as the audio export — stems were hard-wired to `songMode ? songBars : 4` (#export-3).
        let plan = project.buildExportPlan(loopBarsOverride: (fullSong || project.songMode) ? nil : loopBars,
                                           songModeOverride: fullSong ? true : nil,
                                           safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither   // captured on the main actor before detaching
        let stemNames = stemDisplayNames()   // bus id → track display name (sanitized, deduped)
        let prog = exportProg; prog.reset()
        Task {
            await Task.detached(priority: .utility) { sweepExportDirs() }.value   // PRIOR batches, off-main (#227)
            let dir = fd808ExportDir()   // all stems of this batch share one dir
            let out = await Task.detached(priority: .userInitiated) { () -> (urls: [URL], failure: ExportWriteFailure?) in
                var urls: [URL] = []
                var firstFailure: ExportWriteFailure?
                // Streaming: each bus is written and released before the next renders (#export-2); a cancel
                // stops the render itself and discards what was written (round 2, export-1). Progress is by
                // bus index from inside the renderer, so skipped silent buses don't stall the ring.
                renderStems(plan, isCancelled: { prog.cancelled }, progress: { p in prog.report(p) }) { name, left, right in
                    let result = writeAudio(.wav, left: left, right: right, sr: plan.sr, name: "\(plan.name) - \(stemNames[name] ?? name)", dir: dir, dither: dither)
                    switch result {
                    case .success(let url): urls.append(url)
                    case .failure(let failure): if firstFailure == nil { firstFailure = failure }
                    }
                }
                if prog.cancelled {
                    for u in urls { try? FileManager.default.removeItem(at: u) }
                    return ([], nil)
                }
                prog.report(1)
                return (urls, firstFailure)
            }.value
            exporting = false
            if prog.cancelled { return }   // user cancelled — no share sheet, no error
            if !out.urls.isEmpty { exportFile = ExportFile(urls: out.urls); progress.awardCreative("export", 10) }
            else if let failure = out.failure {
                // Surface the real I/O cause; only a genuinely silent project gets the "no sounds" copy (#65).
                if failure == .empty { exportError = "Couldn't export stems. Make sure the project has sounds in it." }
                else { exportError = "Couldn't export stems. \(failure.message)" }
            } else { exportError = "Couldn't export stems. Make sure the project has sounds in it." }
        }
    }

    /// Stem filenames use the track's DISPLAY name, not its internal bus id — sanitized for the
    /// filesystem and deduped ("Drums", "Drums 2") so two same-named tracks can't overwrite each other.
    private func stemDisplayNames() -> [String: String] {
        var seen = Set<String>()
        var names: [String: String] = [:]
        for id in project.busOrder {
            let raw = project.tracks.first { $0.id == id }?.name ?? id
            let base = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
                .trimmingCharacters(in: .whitespaces)
            var nm = base.isEmpty ? id : base
            var i = 2
            while seen.contains(nm) { nm = "\(base) \(i)"; i += 1 }
            seen.insert(nm)
            names[id] = nm
        }
        return names
    }

    private var arrBox: some View {
        VStack(spacing: 0) {
            ruler
            lanes
        }
        .fdCard(16, fill: settings.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxHeight: .infinity)
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Text("SECTIONS").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
                .frame(width: LABEL_W, alignment: .leading).padding(.horizontal, 12)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    // Bars no section covers. They still play (pattern A), but nothing used to say so —
                    // the gap is now visible instead of silently inheriting (finding 3).
                    ForEach(uncoveredRuns(), id: \.start) { run in
                        let barW: CGFloat = g.size.width / CGFloat(Swift.max(1, BARS))
                        uncoveredMark(width: Swift.max(0, CGFloat(run.len) * barW - 2))
                            .offset(x: CGFloat(run.start) * barW, y: 5)
                            .accessibilityElement()
                            .accessibilityLabel(Text("Bars \(run.start + 1) to \(run.start + run.len) have no section"))
                            .accessibilityValue(Text("playing pattern \(seqName(0))"))
                    }
                    ForEach(project.arrangement) { a in
                        if let sec = Kit.section(a.section) {
                            // Pre-computed with explicit types: the inline arithmetic pushed this body past the
                            // type-checker's budget once the file grew.
                            let barW: CGFloat = g.size.width / CGFloat(Swift.max(1, BARS))
                            let secW: CGFloat = Swift.max(0, CGFloat(a.len) * barW - 2)
                            let secX: CGFloat = CGFloat(a.start) * barW
                            HStack(spacing: 5) {
                                // Tapping the NAME opens that pattern for editing; only the badge cycles it.
                                // A tap on a content label that silently rewrote the content was the wrong
                                // default (SEQUENCE_TRACKS_AUDIT finding 5).
                                Text(sec.name).font(FDFont.display(12, .bold)).foregroundStyle(.white).lineLimit(1)
                                    .contentShape(Rectangle())
                                    .onTapGesture { project.switchSequence(a.seq); openSequenceTab?() }
                                Spacer(minLength: 0)
                                Text(seqName(a.seq)).font(FDFont.mono(9, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.25)))
                                    .frame(minWidth: 30, minHeight: 26)     // widen the tap target; glyph unchanged
                                    .contentShape(Rectangle())
                                    .onTapGesture { cycleSeq(a.id) }
                            }
                            .padding(.horizontal, 8)
                            .frame(width: secW, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(sec.color))
                            .offset(x: secX, y: 5)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("\(sec.name) section"))
                            .accessibilityValue(Text("pattern \(seqName(a.seq))"))
                            .accessibilityHint(Text("Double-tap to edit this pattern"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { project.switchSequence(a.seq); openSequenceTab?() }
                            .accessibilityAction(named: Text("Next pattern")) { cycleSeq(a.id) }
                        }
                    }
                    if project.playing {
                        Rectangle().fill(.white).frame(width: 2).offset(x: phPos * g.size.width)
                    }
                }
            }
            .frame(height: 38)
        }
        .overlay(Rectangle().fill(settings.line).frame(height: 1), alignment: .bottom)
    }

    /// Contiguous runs of bars that no section covers, so the ruler can mark them in one shape each
    /// rather than one per bar. Only meaningful in Song Mode (Loop Mode ignores the arrangement).
    /// The dashed marker for a stretch of bars no section covers. Wide enough, it says why in words —
    /// which is what makes the "no sections at all" case readable rather than just an empty dashed box.
    private func uncoveredMark(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(settings.inkFaint.opacity(0.5))
            .frame(width: width, height: 28)
            .overlay {
                if width >= 150 {
                    Text("No section · plays \(seqName(0))")
                        .font(FDFont.mono(9, .bold)).foregroundStyle(settings.inkFaint)
                        .lineLimit(1).allowsHitTesting(false)
                }
            }
    }

    private func uncoveredRuns() -> [(start: Int, len: Int)] {
        // Deliberately NOT gated on a non-empty arrangement: with Song Mode on and no sections at all,
        // EVERY bar is uncovered, which is exactly when saying so matters most. Skipping that case left
        // the one arrangement with nothing to read as the one arrangement with no explanation.
        guard project.songMode else { return [] }
        var runs: [(start: Int, len: Int)] = []
        var bar = 0
        while bar < BARS {
            guard !project.sectionCovers(bar) else { bar += 1; continue }
            let start = bar
            while bar < BARS && !project.sectionCovers(bar) { bar += 1 }
            runs.append((start, bar - start))
        }
        return runs
    }

    private var lanes: some View {
        GeometryReader { g in
            let trackW = g.size.width - LABEL_W
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(project.tracks) { t in laneRow(t, trackW: trackW) }
                    addTrackRow(trackW: trackW)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .topLeading) {
                if showRange {   // selected bar range for the time-range ops
                    Rectangle().fill(settings.accent.opacity(0.16))
                        .overlay(Rectangle().stroke(settings.accent.opacity(0.65), lineWidth: 1.5))
                        .frame(width: Double(rangeLen) / Double(BARS) * trackW)
                        .offset(x: LABEL_W + Double(rangeStart) / Double(BARS) * trackW)
                        .allowsHitTesting(false)
                }
                if project.playing {
                    Rectangle().fill(.white).frame(width: 2)
                        .shadow(color: .white.opacity(0.7), radius: 5)
                        .offset(x: LABEL_W + phPos * trackW)
                }
            }
        }
    }

    private var rangeButton: some View {
        Button { showRange = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.and.right.square").font(.system(size: 12, weight: .semibold))
                Text("Range").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(showRange ? settings.accent : settings.ink)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(showRange ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showRange) { rangePanel }
    }

    private var rangePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Bar Range").font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
            HStack {
                Text("Start").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim); Spacer()
                Button { rangeStart = max(0, rangeStart - 1) } label: { offsetStep("–") }
                Text("\(rangeStart + 1)").font(FDFont.mono(12, .bold)).foregroundStyle(settings.ink).frame(minWidth: 30)
                Button { rangeStart = min(BARS - 1, rangeStart + 1) } label: { offsetStep("+") }
            }
            HStack {
                Text("Length").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim); Spacer()
                Button { rangeLen = max(1, rangeLen - 1) } label: { offsetStep("–") }
                Text("\(rangeLen) bar\(rangeLen == 1 ? "" : "s")").font(FDFont.mono(12, .bold)).foregroundStyle(settings.ink).frame(minWidth: 52)
                Button { rangeLen = min(BARS, rangeLen + 1) } label: { offsetStep("+") }
            }
            Rectangle().fill(settings.line).frame(height: 1).padding(.vertical, 2)
            rangeOp("Duplicate", "plus.square.on.square", settings.accent) { project.arrangeDuplicate(from: rangeStart, len: rangeLen) }
            rangeOp("Insert Space", "arrow.right.to.line", settings.inkDim) { project.arrangeInsertSpace(at: rangeStart, len: rangeLen) }
            rangeOp("Delete Space", "arrow.left.to.line", settings.theme.miss) { confirmDeleteSpace = true }
            Text("Duplicate copies the bars to the right · Insert opens a gap · Delete removes the bars and closes up. Affects all tracks + sections.")
                .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 286)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func rangeOp(_ label: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(FDFont.ui(13, .semibold)); Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 12).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func laneRow(_ t: Track, trackW: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(t.color).frame(width: 7, height: 7)
                    Text(t.name).font(FDFont.display(14, .semibold)).foregroundStyle(settings.ink).lineLimit(1)
                    // link/freeze status (Step 2): linked tracks follow their source live; frozen are detached copies
                    if t.isLinked {
                        Image(systemName: "link").font(.system(size: 9, weight: .bold)).foregroundStyle(settings.accent)
                            .accessibilityLabel(Text("Live-linked to source"))
                    } else if t.isFrozen {
                        Image(systemName: "snowflake").font(.system(size: 9, weight: .bold)).foregroundStyle(settings.inkFaint)
                            .accessibilityLabel(Text("Frozen copy"))
                    }
                    Spacer(minLength: 0)
                    trackMenu(t)
                }
                HStack(spacing: 5) {
                    // #91: the legacy `vox` lane is the shared synth line — every synth part collapses
                    // onto it (it is NOT a vocal/mic lane; the mic lane is the separate "audio" track).
                    Text(t.id == "vox" ? "Synth · all parts share this lane" : t.type.label)
                        .font(FDFont.mono(9)).foregroundStyle(settings.inkFaint).lineLimit(1)
                    Spacer()
                    if t.type == .audio {
                        let armed = project.audioArmedTrack == t.id
                        Button { project.audioArmedTrack = project.audioArmedTrack == t.id ? nil : t.id } label: {
                            Image(systemName: armed ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(armed ? settings.theme.miss : settings.inkFaint)
                                .frame(width: 22, height: 18).contentShape(Rectangle())   // widen tap region; glyph unchanged
                        }.buttonStyle(.plain)
                        .accessibilityLabel(Text(armed ? "Disarm recording" : "Arm recording"))
                        .accessibilityValue(Text(armed ? "Armed" : "Off"))
                        .accessibilityAddTraits(armed ? [.isButton, .isSelected] : .isButton)
                        Button { importTrackID = t.id; importingAudio = true } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(settings.accent)
                                .frame(width: 22, height: 18).contentShape(Rectangle())   // widen tap region; glyph unchanged
                        }.buttonStyle(.plain)
                        .accessibilityLabel(Text("Import audio into \(t.name)"))
                        .accessibilityAddTraits(.isButton)
                    }
                    laneFlag("M", on: project.trackMute[t.id] ?? false, color: settings.theme.miss,
                             a11yLabel: "Mute \(t.name)") {
                        project.checkpoint("trackmute", coalesce: false)
                        project.trackMute[t.id] = !(project.trackMute[t.id] ?? false)
                    }
                    laneFlag("S", on: project.trackSolo[t.id] ?? false, color: settings.theme.good,
                             a11yLabel: "Solo \(t.name)") {
                        project.checkpoint("tracksolo", coalesce: false)
                        project.trackSolo[t.id] = !(project.trackSolo[t.id] ?? false)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(width: LABEL_W, height: 64)
            .overlay(Rectangle().fill(settings.line).frame(width: 1), alignment: .trailing)

            if t.type == .audio { audioTrackArea(track: t, width: trackW) } else { trackArea(t, width: trackW) }
        }
        .frame(height: 64)
        .overlay(Rectangle().fill(settings.line2).frame(height: 1), alignment: .bottom)
    }

    private func trackMenu(_ t: Track) -> some View {
        Menu {
            if !t.frozenToAudio && t.type == .drumPattern {
                Menu("Choose & edit pattern") {
                    ForEach(project.sequences.indices, id: \.self) { index in
                        Button("Pattern " + project.sequences[index].name) {
                            project.chooseTrackSource(t.id, sequence: index); openSequenceTab?()
                        }
                    }
                }
            }
            if !t.frozenToAudio && t.type == .synthPart {
                Menu("Choose & edit instrument") {
                    Button("New instrument layer") {
                        project.chooseTrackSource(t.id, newPart: true); openSynthTab?()
                    }
                    ForEach(project.partList, id: \.id) { part in
                        Button(part.name) { project.chooseTrackSource(t.id, part: part.id); openSynthTab?() }
                    }
                }
            }
            Button { renameID = t.id; renameText = t.name } label: { Label("Rename", systemImage: "pencil") }
            Menu {
                ForEach(Track.palette, id: \.self) { hex in
                    Button { project.setTrackColor(t.id, hex) } label: { Label(hex, systemImage: "circle.fill") }
                }
            } label: { Label("Color", systemImage: "paintpalette") }
            Divider()
            Button { project.moveTrack(t.id, up: true) } label: { Label("Move Up", systemImage: "arrow.up") }
                .disabled(!project.canMoveTrack(t.id, up: true))
            Button { project.moveTrack(t.id, up: false) } label: { Label("Move Down", systemImage: "arrow.down") }
                .disabled(!project.canMoveTrack(t.id, up: false))
                if t.type != .bus && !project.busTracks.isEmpty {   // route this track's audio into a group bus (G3.4)
                    Menu {
                        Button { project.setTrackBusParent(t.id, nil) } label: {
                            Label("None", systemImage: t.busParent == nil ? "checkmark" : "")
                        }
                        ForEach(project.busTracks) { b in
                            Button { project.setTrackBusParent(t.id, b.id) } label: {
                                Label(b.name, systemImage: t.busParent == b.id ? "checkmark" : "rectangle.3.group")
                            }
                        }
                    } label: { Label("Route to Bus", systemImage: "arrow.triangle.merge") }
                }
            if t.playsAdditively || t.frozenToAudio {   // keep Unfreeze reachable after saving/reopening
                Button { project.tracks.contains { $0.id == t.id } ? sendClipFull(t) : () } label: { Label("Add Clip (full song)", systemImage: "rectangle.badge.plus") }
                if !t.frozenToAudio {   // live-link ⇄ independent copy (Step 2)
                    if t.isLinked {
                        Button { _ = project.freezeLinkToCopy(t.id) } label: { Label("Freeze (detach copy)", systemImage: "scissors") }
                    } else if t.isFrozen {
                        Button { _ = project.relinkTrack(t.id) } label: { Label("Re-link to source", systemImage: "link") }
                    }
                }
                if t.frozenToAudio {
                    Button { project.unfreezeTrack(t.id) } label: { Label("Unfreeze", systemImage: "arrow.counterclockwise") }
                } else {
                    Button { Task { @MainActor in _ = await project.freezeTrack(t.id) } } label: { Label("Freeze to Audio", systemImage: "snowflake") }
                }
            }
            if !LEGACY_TRACK_IDS.contains(t.id) {
                Divider()
                Button(role: .destructive) { confirmDeleteTrack = t } label: { Label("Delete Track", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundStyle(settings.inkFaint).frame(width: 28, height: 24)   // widen tap region; glyph unchanged
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel(Text("Track options for \(t.name)"))
        .accessibilityAddTraits(.isButton)
    }

    private func sendClipFull(_ t: Track) {
        project.checkpoint("clipfull", coalesce: false)
        project.clips[t.id, default: []].append(Clip(s: 0, l: BARS, color: t.color))
    }

    private func addTrackRow(trackW: CGFloat) -> some View {
        let atCap = project.tracks.count >= Project.maxTracks
        return HStack(spacing: 0) {
            Menu {
                Button { _ = project.addTrack(.drumPattern) } label: { Label("Drum Program", systemImage: "square.grid.2x2.fill") }
                Button { _ = project.addTrack(.synthPart) } label: { Label("Synth Line", systemImage: "pianokeys") }
                Button { _ = project.addTrack(.audio) } label: { Label("Audio / Mic", systemImage: "mic.fill") }
                Button { _ = project.addTrack(.bus) } label: { Label("Group Bus", systemImage: "rectangle.3.group.fill") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14))
                    Text("Add Track").font(FDFont.ui(12.5, .semibold))
                }
                .foregroundStyle(atCap ? settings.inkFaint : settings.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }
            .menuStyle(.button).buttonStyle(.plain).disabled(atCap)
            .frame(width: LABEL_W, height: 44)
            .overlay(Rectangle().fill(settings.line).frame(width: 1), alignment: .trailing)
            Text(atCap ? "99-track maximum reached"
                 : "\(project.tracks.count) / 99 · or send a pad take (Pads) or melody (Synth) here as its own track")
                .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).lineLimit(1)
                .frame(width: trackW, height: 44, alignment: .leading).padding(.leading, 10)
        }
        .frame(height: 44)
        .background(settings.panel2.opacity(0.35))
    }

    private func trackArea(_ t: Track, width: CGFloat) -> some View {
        let barPx: CGFloat = Swift.max(1, width / CGFloat(BARS))   // a zero-width lane (Slide Over) must not trap Int(inf) (#cross-7)
        return ZStack(alignment: .topLeading) {
            // grid
            ForEach(0..<BARS, id: \.self) { b in
                Rectangle().fill(b % 4 == 0 ? settings.line : settings.line2)
                    .frame(width: 1).offset(x: CGFloat(b) * barPx)
            }
            // tap-to-add hit layer — BEHIND the clips so clip drag / double-tap still reach them
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded { v in
                        guard abs(v.translation.width) < 6, abs(v.translation.height) < 6 else { return }
                        let bar = max(0, min(BARS - 2, Int(v.location.x / barPx)))
                        // don't drop a clip on top of one that's already there
                        if (project.clips[t.id] ?? []).contains(where: { bar >= $0.s && bar < $0.s + $0.l }) { return }
                        addClip(t, at: bar)
                    })
                .accessibilityLabel(Text("\(t.name) lane"))
                .accessibilityHint(Text("Add a clip"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    let taken = project.clips[t.id] ?? []
                    var bar = 0
                    while bar <= BARS - 2 && taken.contains(where: { bar >= $0.s && bar < $0.s + $0.l }) { bar += 1 }
                    guard bar <= BARS - 2 else { return }
                    addClip(t, at: bar)
                }
            // empty-lane affordance: a dashed "tap to add" ghost in bar 1 so the tap target is visible
            // (the Color.clear hit layer behind handles the actual tap).
            if (project.clips[t.id] ?? []).isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("tap to add").font(FDFont.mono(9, .bold))
                }
                .foregroundStyle(settings.inkFaint)
                .frame(width: max(barPx, 2 * barPx - 2), height: 50)
                .background(RoundedRectangle(cornerRadius: 7).stroke(settings.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                .offset(x: 1, y: 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // clips (on top, so their own drag / double-tap gestures win)
            ForEach(Array((project.clips[t.id] ?? []).enumerated()), id: \.element.id) { (i, c) in
                clipView(t, i: i, c: c, barPx: barPx)
            }
        }
        .frame(width: width, height: 64)
    }

    private func clipView(_ t: Track, i: Int, c: Clip, barPx: CGFloat) -> some View {
        let w = CGFloat(c.l) * barPx
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 7).fill(c.color)
            ClipWave().opacity(0.35).padding(.horizontal, 4)
            Text(t.name).font(FDFont.mono(10, .bold)).foregroundStyle(.white.opacity(0.95)).padding(EdgeInsets(top: 0, leading: 8, bottom: 5, trailing: 0))
        }
        .frame(width: max(barPx, w - 1), height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .opacity(c.muted ? 0.4 : 1)
        .overlay(alignment: .topTrailing) {
            // A pinned clip has to LOOK pinned — otherwise the pattern it plays is state you can only
            // discover by opening each clip in turn (re-audit, gap C).
            if let pin = c.seq {
                Text(seqName(pin)).font(FDFont.mono(9, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.top, 3).padding(.trailing, 22)   // clear of the resize handle
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            // drag the right edge to change the clip's length
            Color.white.opacity(0.001).frame(width: 20)
                .overlay(Capsule().fill(.white.opacity(0.75)).frame(width: 3, height: 16).padding(.trailing, 4))
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        let orig = (resizeDrag?.track == t.id && resizeDrag?.idx == i) ? (resizeDrag?.orig ?? c.l) : c.l
                        if resizeDrag == nil { project.checkpoint("clipresize", coalesce: false); resizeDrag = (t.id, i, c.l) }
                        let nl = max(1, min(BARS - c.s, Int((CGFloat(orig) * barPx + v.translation.width) / barPx + 0.5)))
                        if var arr = project.clips[t.id], i < arr.count, arr[i].l != nl { arr[i].l = nl; project.clips[t.id] = arr }
                    }
                    .onEnded { _ in resizeDrag = nil })
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
        .offset(x: CGFloat(c.s) * barPx + 1, y: 7)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                let orig = (drag?.track == t.id && drag?.idx == i) ? (drag?.orig ?? c.s) : c.s
                if drag == nil { project.checkpoint("clipmove", coalesce: false); drag = (t.id, i, c.s) }
                let ns = max(0, min(BARS - c.l, Int((CGFloat(orig) * barPx + v.translation.width) / barPx + 0.5)))
                if var arr = project.clips[t.id], i < arr.count { arr[i].s = ns; project.clips[t.id] = arr }
            }
            .onEnded { _ in drag = nil })
        .onTapGesture { editClip = c.id }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(t.name) clip"))
        .accessibilityValue(Text("bar \(c.s + 1), \(c.l) bar\(c.l == 1 ? "" : "s")\(c.seq.map { ", pattern \(seqName($0))" } ?? "")\(c.muted ? ", muted" : "")"))
        .accessibilityHint(Text("Adjust to move. Double-tap to edit."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { dir in
            guard var arr = project.clips[t.id], i < arr.count else { return }
            let ns: Int
            switch dir {
            case .increment: ns = min(BARS - c.l, c.s + 1)
            case .decrement: ns = max(0, c.s - 1)
            @unknown default: return
            }
            if ns != arr[i].s { project.checkpoint("clipmove", coalesce: false); arr[i].s = ns; project.clips[t.id] = arr }
        }
        .accessibilityAction(named: Text("Edit clip")) { editClip = c.id }
        .accessibilityAction(named: Text("Longer")) {
            guard var arr = project.clips[t.id], i < arr.count else { return }
            let nl = min(BARS - c.s, c.l + 1)
            if nl != arr[i].l { project.checkpoint("clipresize", coalesce: false); arr[i].l = nl; project.clips[t.id] = arr }
        }
        .accessibilityAction(named: Text("Shorter")) {
            guard var arr = project.clips[t.id], i < arr.count else { return }
            let nl = max(1, c.l - 1)
            if nl != arr[i].l { project.checkpoint("clipresize", coalesce: false); arr[i].l = nl; project.clips[t.id] = arr }
        }
        .popover(isPresented: Binding(get: { editClip == c.id }, set: { if !$0 { editClip = nil } })) {
            programClipInspector(t, c)
        }
    }

    private func programClipInspector(_ t: Track, _ c: Clip) -> some View {
        let cur = project.clips[t.id]?.first { $0.id == c.id }
        let len = cur?.l ?? c.l
        let muted = cur?.muted ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(t.name) clip").font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
                Spacer()
                Button { project.deleteClip(track: t.id, id: c.id); editClip = nil } label: {
                    Text("Delete").font(FDFont.mono(10, .bold)).foregroundStyle(settings.theme.miss)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(settings.theme.miss.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.theme.miss.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            HStack {
                Text("Length").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                Spacer()
                Button { project.setClipLength(track: t.id, id: c.id, len - 1) } label: { offsetStep("–") }
                Text("\(len) bar\(len == 1 ? "" : "s")").font(FDFont.mono(12, .bold)).foregroundStyle(settings.ink).frame(minWidth: 52)
                Button { project.setClipLength(track: t.id, id: c.id, len + 1) } label: { offsetStep("+") }
            }
            clipPatternRow(t, c, pinned: cur?.seq)
            Button { project.toggleClipMute(track: t.id, id: c.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12))
                    Text(muted ? "Muted" : "Mute").font(FDFont.ui(12.5, .semibold)); Spacer()
                }
                .foregroundStyle(muted ? settings.theme.miss : settings.inkDim)
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(muted ? settings.theme.miss.opacity(0.15) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(muted ? settings.theme.miss.opacity(0.5) : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Button { project.duplicateClip(track: t.id, id: c.id); editClip = nil } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.square.on.square").font(.system(size: 12))
                    Text("Duplicate").font(FDFont.ui(12.5, .semibold)); Spacer()
                }
                .foregroundStyle(settings.accent)
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.4), lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(16).frame(width: 250)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    /// Which pattern this clip plays. "Follow" (the default) takes the section's pattern, so a project
    /// that never touches this behaves exactly as before; picking a letter pins THIS track to THAT
    /// pattern over the clip's bars, which is how one track runs B while another stays on A.
    @ViewBuilder
    private func clipPatternRow(_ t: Track, _ c: Clip, pinned: Int?) -> some View {
        let sectionSeq = project.sequenceIndexForBar(c.s)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Pattern").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                Spacer()
                Button { project.switchSequence(pinned ?? sectionSeq); openSequenceTab?() } label: {
                    Text("Edit →").font(FDFont.mono(10, .bold)).foregroundStyle(settings.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Edit pattern \(seqName(pinned ?? sectionSeq)) in the Sequence tab"))
            }
            HStack(spacing: 5) {
                patternChip(label: "Follow", on: pinned == nil,
                            a11y: "Follow the section, currently pattern \(seqName(sectionSeq))") {
                    project.setClipSeq(track: t.id, id: c.id, nil)
                }
                ForEach(Array(project.sequences.enumerated()), id: \.offset) { (i, slot) in
                    patternChip(label: slot.name, on: pinned == i, a11y: "Pattern \(slot.name)") {
                        project.setClipSeq(track: t.id, id: c.id, i)
                    }
                }
            }
            Text(pinned == nil
                 ? "Follows the section here — pattern \(seqName(sectionSeq))."
                 : "This clip plays \(seqName(pinned!)) no matter which pattern the section uses.")
                .font(FDFont.ui(10.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func patternChip(label: String, on: Bool, a11y: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.mono(11, .bold))
                .foregroundStyle(on ? .white : settings.inkDim)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // "Follow" must not wrap to "Follo/w"
                .frame(minWidth: 26).frame(height: 30).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : settings.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(a11y))
        .accessibilityValue(Text(on ? "Selected" : "Not selected"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func seqName(_ i: Int) -> String { project.sequences.indices.contains(i) ? project.sequences[i].name : "A" }
    private func cycleSeq(_ id: String) {
        guard let idx = project.arrangement.firstIndex(where: { $0.id == id }) else { return }
        project.checkpoint("arrseq", coalesce: false)
        project.arrangement[idx].seq = (project.arrangement[idx].seq + 1) % max(1, project.sequences.count)
    }

    private var punchControl: some View {
        HStack(spacing: 4) {
            Text("PUNCH").font(FDFont.mono(8.5, .bold)).tracking(0.5).foregroundStyle(settings.inkFaint)
            Button { project.setPunchInBar(project.punchInBar - 1) } label: { offsetStep("–") }
            Text("\(project.punchInBar + 1)").font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink).frame(minWidth: 22)
            Button { project.setPunchInBar(min(BARS - 1, project.punchInBar + 1)) } label: { offsetStep("+") }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .fdCard(9, fill: settings.panel2)
    }
    private var recOffset: some View {
        HStack(spacing: 4) {
            Text("OFFSET").font(FDFont.mono(8.5, .bold)).tracking(0.5).foregroundStyle(settings.inkFaint)
            Button { project.audioRecOffsetMs -= 5 } label: { offsetStep("–") }
            Text("\(project.audioRecOffsetMs > 0 ? "+" : "")\(project.audioRecOffsetMs)ms")
                .font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink).frame(minWidth: 46)
            Button { project.audioRecOffsetMs += 5 } label: { offsetStep("+") }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .fdCard(9, fill: settings.panel2)
    }
    private func offsetStep(_ s: String) -> some View {
        // Glyph stays 15pt; widen the tap region as far as the 32pt-tall host pills allow (a full 44pt
        // box would distort those compact rows). contentShape makes the padded area tappable.
        Text(s).font(.system(size: 15, weight: .bold)).foregroundStyle(settings.inkDim)
            .frame(width: 30, height: 28).contentShape(Rectangle())
            .accessibilityLabel(Text(s == "+" ? "Increase" : "Decrease"))
    }

    private var lengthButton: some View {
        Menu {
            ForEach([16, 32, 64], id: \.self) { n in
                Button { project.setSongBars(n) } label: {
                    Label("\(n) bars", systemImage: n == BARS ? "checkmark" : "")
                }
                .disabled(n < project.usedSongBars)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ruler").font(.system(size: 12, weight: .semibold))
                Text("\(BARS) Bars").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(settings.ink)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
        }
        .menuStyle(.button).buttonStyle(.plain)
        .accessibilityLabel(Text("Song length"))
        .accessibilityValue(Text("\(BARS) bars"))
    }

    private var buildSongButton: some View {
        Button { confirmBuildSong = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars").font(.system(size: 12))
                Text("Build Song").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(settings.ink)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.accent.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func colorFor(_ track: String) -> Color { project.tracks.first { $0.id == track }?.color ?? settings.accent }

    // MARK: song-wide automation (Tier 3)

    private var songAutoLabel: String {
        switch project.songAutoTarget { case "filter": "Filter"; case "reverb": "Reverb"; case "delay": "Delay"; default: "Off" }
    }
    private var songAutoButton: some View {
        Button {
            let order = ["", "filter", "reverb", "delay"]
            let i = order.firstIndex(of: project.songAutoTarget) ?? 0
            project.checkpoint("songauto", coalesce: false)
            project.setSongAutoTarget(order[(i + 1) % order.count])
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 12, weight: .semibold))
                Text("Auto · \(songAutoLabel)").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(project.songAutoTarget != "" ? settings.accent : settings.ink)
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(project.songAutoTarget != "" ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private var automationLane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AUTOMATION · \(songAutoLabel) · drag to draw across the song (Song Mode)")
                .font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            HStack(spacing: 0) {
                Color.clear.frame(width: LABEL_W)
                GeometryReader { g in
                    let barW = g.size.width / CGFloat(BARS)
                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .bottom, spacing: 1) {
                            ForEach(0..<BARS, id: \.self) { b in
                                let v = b < project.songAuto.count ? project.songAuto[b] : 1
                                RoundedRectangle(cornerRadius: 2).fill(settings.accent.opacity(0.7))
                                    .frame(maxWidth: .infinity).frame(height: max(2, CGFloat(v) * 40))
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(Text("Dynamics bar \(b + 1)"))
                                    .accessibilityValue(Text("\(Int(v * 100))%"))
                                    .accessibilityAdjustableAction { dir in
                                        switch dir {
                                        case .increment: project.setSongAutoBar(b, min(1, v + 0.1))
                                        case .decrement: project.setSongAutoBar(b, max(0, v - 0.1))
                                        @unknown default: break
                                        }
                                    }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.vertical, 2)
                        if project.playing { Rectangle().fill(.white).frame(width: 2).offset(x: phPos * g.size.width) }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let b = max(0, min(BARS - 1, Int(v.location.x / max(1, barW))))
                        project.setSongAutoBar(b, 1 - max(0, min(1, Double(v.location.y) / 44)))
                    })
                }
                .frame(height: 44)
                .fdCard(8, fill: settings.panel)
            }
        }
    }

    private func buildSong() { project.buildSong() }

    private var songToggle: some View {
        Button { project.checkpoint("songmode", coalesce: false); project.songMode.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: project.songMode ? "music.note.list" : "repeat").font(.system(size: 12))
                Text(project.songMode ? "Song" : "Loop").font(FDFont.ui(13, .semibold))
            }
            .foregroundStyle(project.songMode ? .white : settings.inkDim)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(project.songMode ? settings.accent : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(project.songMode ? .clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var palette: some View {
        HStack(spacing: 8) {
            Text("ADD SECTION").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
            ForEach(Kit.sections) { sec in
                Button { addSection(sec) } label: {
                    Text("+ \(sec.name)").font(FDFont.display(13, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(sec.color))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func laneFlag(_ s: String, on: Bool, color: Color, a11yLabel: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(9, .bold))
                .foregroundStyle(on ? (s == "S" ? FDPalette.soloInk : .white) : settings.inkFaint)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? .clear : settings.line, lineWidth: 1))
                // keep the 18×18 visual; widen the tap region (the fixed 116×64 lane column can't host a
                // full 44pt box without distorting the row, so we enlarge the hit area as far as it allows).
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(Text(a11yLabel ?? s))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func addSection(_ sec: Kit.Section) {
        let last = project.arrangement.reduce(0) { max($0, $1.start + $1.len) }
        if last >= BARS { fullSection = sec; return }
        project.checkpoint("addsection", coalesce: false)
        if project.arrangement.isEmpty { project.songMode = true }   // first section = a new arrangement → play it as a song
        project.arrangement.append(ArrItem(id: "a\(Int(Date().timeIntervalSince1970 * 1000))", section: sec.id, start: last, len: 2))
    }

    /// Add a program clip, flipping Song Mode on for the very FIRST clip of a new arrangement
    /// (so manual arranging is actually heard/exported) — never re-flips once clips exist.
    private func addClip(_ t: Track, at bar: Int) {
        project.checkpoint("clip", coalesce: false)
        if project.clips.values.allSatisfy({ $0.isEmpty }) { project.songMode = true }
        project.clips[t.id, default: []].append(Clip(s: bar, l: 2, color: t.color))
    }
}

extension TrackModeView {
    // MARK: audio track (A5)

    func audioTrackArea(track t: Track, width: CGFloat) -> some View {
        let barPx: CGFloat = Swift.max(1, width / CGFloat(BARS))   // a zero-width lane (Slide Over) must not trap Int(inf) (#cross-7)
        let barSec = (60.0 / Double(project.bpm)) * Double(project.barSteps) / 4
        let armed = project.audioArmedTrack == t.id
        return ZStack(alignment: .topLeading) {
            ForEach(0..<BARS, id: \.self) { b in
                Rectangle().fill(b % 4 == 0 ? settings.line : settings.line2)
                    .frame(width: 1).offset(x: CGFloat(b) * barPx)
            }
            // background: tap to set the punch (record-start) bar — behind the clips
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    guard armed, abs(v.translation.width) < 6 else { return }
                    project.setPunchInBar(min(BARS - 1, Int(v.location.x / barPx)))
                })
                .accessibilityHidden(!armed)
                .accessibilityLabel(Text("Record start position"))
                .accessibilityValue(Text("bar \(project.punchInBar + 1)"))
                .accessibilityHint(Text("Adjust to move where recording begins"))
                .accessibilityAdjustableAction { dir in
                    switch dir {
                    case .increment: project.setPunchInBar(min(BARS - 1, project.punchInBar + 1))
                    case .decrement: project.setPunchInBar(project.punchInBar - 1)
                    @unknown default: break
                    }
                }
            ForEach(project.audioClips.filter { $0.track == t.id }) { clip in
                audioClipView(clip, barPx: barPx, barSec: barSec)
            }
            if armed {
                Rectangle().fill(settings.theme.miss).frame(width: 2)
                    .offset(x: CGFloat(project.punchInBar) * barPx).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 64)
    }

    private func audioClipView(_ clip: AudioClip, barPx: CGFloat, barSec: Double) -> some View {
        // clamp the drawn width to the timeline so long clips don't spill past the right edge
        let lenBars = max(1, min(BARS - clip.startBar, Int(ceil(clip.durSec / barSec))))
        let w = CGFloat(lenBars) * barPx
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 7).fill(Color(hex: "#5BD6C0"))
            AudioClipWave(peaks: clip.wave).padding(.horizontal, 4).opacity(0.6)
            Text(clip.name).font(FDFont.mono(10, .bold)).foregroundStyle(Color(hex: "#06231f"))
                .padding(EdgeInsets(top: 0, leading: 8, bottom: 5, trailing: 0)).lineLimit(1)
        }
        .frame(width: max(barPx, w - 1), height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .opacity(clip.muted ? 0.4 : 1)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
        .offset(x: CGFloat(clip.startBar) * barPx + 1, y: 7)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in
                let orig = audioDrag?.id == clip.id ? (audioDrag?.orig ?? clip.startBar) : clip.startBar
                if audioDrag == nil { audioDrag = (clip.id, clip.startBar); project.checkpoint("audioMove", coalesce: false) }   // one undo step for the whole drag (#FUNCNAV-02)
                let nb = max(0, min(BARS - 1, Int((CGFloat(orig) * barPx + v.translation.width) / barPx + 0.5)))
                project.moveAudioClip(clip.id, toBar: nb, checkpoint: false)
            }
            .onEnded { _ in audioDrag = nil })
        .onTapGesture { editClip = clip.id }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(clip.name) audio clip"))
        .accessibilityValue(Text("bar \(clip.startBar + 1)\(clip.muted ? ", muted" : "")"))
        .accessibilityHint(Text("Adjust to move. Double-tap to edit."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: project.moveAudioClip(clip.id, toBar: min(BARS - 1, clip.startBar + 1))
            case .decrement: project.moveAudioClip(clip.id, toBar: max(0, clip.startBar - 1))
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Edit clip")) { editClip = clip.id }
        .popover(isPresented: Binding(get: { editClip == clip.id }, set: { if !$0 { editClip = nil } })) {
            clipInspector(clip)
        }
    }

    private func curClip(_ clip: AudioClip) -> AudioClip? { project.audioClips.first { $0.id == clip.id } }

    private func clipInspector(_ clip: AudioClip) -> some View {
        let muted = curClip(clip)?.muted ?? false
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(clip.name).font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
                Spacer()
                Button { project.removeAudioClip(clip.id); editClip = nil } label: {
                    Text("Delete").font(FDFont.mono(10, .bold)).foregroundStyle(settings.theme.miss)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(settings.theme.miss.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.theme.miss.opacity(0.5), lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Text("Bar \(clip.startBar + 1) · \(String(format: "%.1f", clip.durSec))s")
                .font(FDFont.mono(10, .bold)).foregroundStyle(settings.inkFaint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Gain").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.inkDim)
                    Spacer()
                    Text("\(Int((curClip(clip)?.gain ?? 1) * 100))%").font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
                }
                Slider(value: Binding(get: { curClip(clip)?.gain ?? 1 },
                                      set: { v in project.updateAudioClip(clip.id) { $0.gain = v } }), in: 0...2).tint(settings.accent)
                    .accessibilityLabel(Text("Clip gain"))
                    .accessibilityValue(Text("\(Int((curClip(clip)?.gain ?? 1) * 100)) percent"))
            }
            Button { project.updateAudioClip(clip.id) { $0.muted.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 12))
                    Text(muted ? "Muted — comped out" : "Mute (comp out)").font(FDFont.ui(12.5, .semibold))
                    Spacer()
                }
                .foregroundStyle(muted ? settings.theme.miss : settings.inkDim)
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(muted ? settings.theme.miss.opacity(0.15) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(muted ? settings.theme.miss.opacity(0.5) : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Text("Stack multiple takes at the same bar, then mute the ones you don't want.")
                .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 264)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }
}

struct AudioClipWave: View {
    let peaks: [Float]
    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in
                guard peaks.count > 1 else { return }
                let mid = size.height / 2
                let cw = size.width / CGFloat(peaks.count)
                for i in peaks.indices {
                    let h = max(1, CGFloat(peaks[i]) * size.height * 0.9)
                    ctx.fill(Path(CGRect(x: CGFloat(i) * cw, y: mid - h / 2, width: max(0.6, cw - 0.4), height: h)),
                             with: .color(.black.opacity(0.5)))
                }
            }
        }
    }
}

struct ClipWave: View {
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 1) {
                ForEach(0..<28, id: \.self) { i in
                    let h = 20 + abs(sin(Double(i) * 1.3) * 60) + Double(i % 3) * 8
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.6))
                        .frame(height: g.size.height * h / 100)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}


/// Progress/cancel box shared with the detached render (the render closures are `@Sendable`; a class with a
/// main-actor published value is the clean bridge). `renderOffline` already supported both callbacks; no UI
/// used them, so a long bounce was an uninterruptible spinner (#export-4).
@MainActor
final class ExportProgressBox: ObservableObject, @unchecked Sendable {
    @Published var value: Double = 0
    // Lock-protected: written on the main actor (Cancel), read on the render thread every block.
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)
    private let lastReported = OSAllocatedUnfairLock(initialState: -1.0)
    nonisolated var cancelled: Bool { cancelLock.withLock { $0 } }
    func cancel() { cancelLock.withLock { $0 = true } }
    func reset() { value = 0; cancelLock.withLock { $0 = false }; lastReported.withLock { $0 = -1 } }
    /// Throttled to ≥1 % steps: the renderer reports every 8192 frames, which was ~750 main-actor hops and
    /// republishes per two-minute bounce (round 2, cross-6).
    nonisolated func report(_ p: Double) {
        let post = lastReported.withLock { last -> Bool in
            if p >= 1 || p - last >= 0.01 { last = p; return true }
            return false
        }
        if post { Task { @MainActor in self.value = p } }
    }
}


/// The export/import prompts, split out of `TrackModeView.body` so the (already large) chain stays inside the
/// type-checker's budget — the same pattern RootView uses for its first-run flow.
private struct ExportPrompts: ViewModifier {
    @Binding var exportError: String?
    @Binding var pendingJob: TrackModeView.ExportJob?
    @Binding var pendingGate: TrackModeView.ExportJob?
    @Binding var importNotice: String?
    let bars: Int
    let loopBars: Int
    let run: (TrackModeView.ExportJob, Bool) -> Void
    let afterGate: (TrackModeView.ExportJob) -> Void
    func body(content: Content) -> some View {
        content
            .alert("Export didn't work", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
            .confirmationDialog("Export", isPresented: Binding(get: { pendingJob != nil }, set: { if !$0 { pendingJob = nil } }), titleVisibility: .visible) {
                Button("Full song · \(bars) bars") { if let j = pendingJob { run(j, true) }; pendingJob = nil }
                Button("Current loop · \(loopBars) bar\(loopBars == 1 ? "" : "s")") { if let j = pendingJob { run(j, false) }; pendingJob = nil }
                Button("Cancel", role: .cancel) { pendingJob = nil }
            } message: { Text("You have an arrangement, but Song Mode is off. Export the whole song, or just the loop that's playing?") }
            .alert("Solo or mute is on", isPresented: Binding(get: { pendingGate != nil }, set: { if !$0 { pendingGate = nil } })) {
                Button("Export with mute/solo") { if let j = pendingGate { pendingGate = nil; afterGate(j) } }
                Button("Cancel", role: .cancel) { pendingGate = nil }
            } message: { Text("Muted and soloed-out channels, rows and tracks are excluded. Hosted AU effects are used only for live monitoring.") }
            .alert("Audio import", isPresented: Binding(get: { importNotice != nil }, set: { if !$0 { importNotice = nil } })) {
                Button("OK", role: .cancel) { importNotice = nil }
            } message: { Text(importNotice ?? "") }
    }
}
