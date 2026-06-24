//  TrackModeView.swift — arrangement timeline: song sections, draggable clips,
//  animated playhead. Ported from mode-track.jsx.

import SwiftUI
import UniformTypeIdentifiers

private let LABEL_W: CGFloat = 116
// The six seeded tracks are wired into Transport/Export/Build Song, so they can be renamed &
// recolored but not deleted; user-added tracks are fully removable.
private let LEGACY_TRACK_IDS: Set<String> = ["drums", "hats", "bass", "perc", "vox", "audio"]

struct TrackModeView: View {
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
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var renameID: String?
    @State private var renameText = ""
    @State private var importTrackID = "audio"
    @State private var confirmBuildSong = false
    @State private var confirmDeleteTrack: Track?
    @State private var confirmDeleteSpace = false

    private var phPos: Double {
        guard project.playing else { return 0 }
        let frac = project.step < 0 ? 0 : Double(project.step) / Double(max(1, project.barSteps))
        return (Double(project.bar) + frac) / Double(BARS)
    }

    var body: some View {
        VStack(spacing: 10) {
            TransportBar()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Tracks").font(FDFont.display(26, .bold)).foregroundStyle(settings.ink)
                    Eyebrow(text: "Arrangement · \(BARS) Bars")
                    Spacer()
                    Text(project.audioArmedTrack != nil ? "Audio armed · press ● to record over the beat"
                         : (project.songMode ? "Song Mode · clips build the arrangement" : "Tap a lane to add · drag to move · tap a clip to edit"))
                        .font(FDFont.ui(12.5)).foregroundStyle(project.audioArmedTrack != nil ? settings.theme.miss : settings.inkFaint).lineLimit(1)
                    if project.audioArmedTrack != nil { punchControl; recOffset }
                    songAutoButton
                    rangeButton
                    buildSongButton
                    songToggle
                    exportButton
                }
                arrBox
                if project.songAutoTarget != "" { automationLane }
                palette
            }
        }
        .sheet(item: $exportFile) { f in
            ShareSheet(urls: f.urls)
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: false) { handleAudioImport($0) }
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
    }

    private func handleAudioImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let trackID = importTrackID, name = url.deletingPathExtension().lastPathComponent
        Task {   // off-main decode so importing a long take never hitches the UI (Phase 2)
            guard let data = await engine.decodeAudioFileAsync(url: url), !data.isEmpty else { return }
            project.addAudioClip(track: trackID, startBar: 0, data: data, name: name)
        }
    }

    private var exportButton: some View {
        Menu {
            Button { exportSong(.m4a) } label: { Label("M4A · AAC (compressed)", systemImage: "waveform") }
            Button { exportSong(.wav) } label: { Label("WAV · lossless", systemImage: "waveform.path") }
            Button { exportStems() } label: { Label("Stems · per-track WAV (pre-master, FX-dry)", systemImage: "square.stack.3d.up") }
            Button { sweepExportDirs(); if let url = project.exportMIDIFile() { exportFile = ExportFile(urls: [url]) } } label: { Label("MIDI · .mid", systemImage: "pianokeys") }
        } label: {
            HStack(spacing: 7) {
                if exporting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                }
                Text(exporting ? "Rendering…" : "Export").font(FDFont.ui(13, .semibold))
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

    private func exportSong(_ format: ExportFormat) {
        guard !exporting else { return }
        exporting = true
        let plan = project.buildExportPlan(safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither   // captured on the main actor before detaching
        Task {
            sweepExportDirs()            // reclaim PRIOR batches first → never deletes the dir we're about to share (#227)
            let dir = fd808ExportDir()   // one unique batch dir → re-exports never collide
            let url = await Task.detached(priority: .userInitiated) {
                let (l, r) = renderOffline(plan)
                return writeAudio(format, left: l, right: r, sr: plan.sr, name: plan.name, dir: dir, dither: dither)
            }.value
            exporting = false
            if let url { exportFile = ExportFile(urls: [url]); progress.awardCreative("export", 10) }
        }
    }

    private func exportStems() {
        guard !exporting else { return }
        exporting = true
        let plan = project.buildExportPlan(safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither   // captured on the main actor before detaching
        Task {
            sweepExportDirs()            // reclaim PRIOR batches first (#227)
            let dir = fd808ExportDir()   // all stems of this batch share one dir
            let urls = await Task.detached(priority: .userInitiated) { () -> [URL] in
                renderStems(plan).compactMap { stem in
                    writeAudio(.wav, left: stem.left, right: stem.right, sr: plan.sr, name: "\(plan.name) - \(stem.name)", dir: dir, dither: dither)
                }
            }.value
            exporting = false
            if !urls.isEmpty { exportFile = ExportFile(urls: urls); progress.awardCreative("export", 10) }
        }
    }

    private var arrBox: some View {
        VStack(spacing: 0) {
            ruler
            lanes
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxHeight: .infinity)
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Text("SECTIONS").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
                .frame(width: LABEL_W, alignment: .leading).padding(.horizontal, 12)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    ForEach(project.arrangement) { a in
                        if let sec = Kit.section(a.section) {
                            HStack(spacing: 5) {
                                Text(sec.name).font(FDFont.display(12, .bold)).foregroundStyle(.white).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(seqName(a.seq)).font(FDFont.mono(9, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.25)))
                            }
                            .padding(.horizontal, 8)
                            .frame(width: max(0, Double(a.len) / Double(BARS) * g.size.width - 2), height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(sec.color))
                            .offset(x: Double(a.start) / Double(BARS) * g.size.width, y: 5)
                            .contentShape(Rectangle())
                            .onTapGesture { cycleSeq(a.id) }
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
                        Button { project.audioArmedTrack = project.audioArmedTrack == t.id ? nil : t.id } label: {
                            Image(systemName: project.audioArmedTrack == t.id ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(project.audioArmedTrack == t.id ? settings.theme.miss : settings.inkFaint)
                        }.buttonStyle(.plain)
                        Button { importTrackID = t.id; importingAudio = true } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(settings.accent)
                        }.buttonStyle(.plain)
                    }
                    laneFlag("M", on: project.trackMute[t.id] ?? false, color: settings.theme.miss) {
                        project.checkpoint("trackmute", coalesce: false)
                        project.trackMute[t.id] = !(project.trackMute[t.id] ?? false)
                    }
                    laneFlag("S", on: project.trackSolo[t.id] ?? false, color: settings.theme.good) {
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
            Button { renameID = t.id; renameText = t.name } label: { Label("Rename", systemImage: "pencil") }
            Menu {
                ForEach(Track.palette, id: \.self) { hex in
                    Button { project.setTrackColor(t.id, hex) } label: { Label(hex, systemImage: "circle.fill") }
                }
            } label: { Label("Color", systemImage: "paintpalette") }
            if t.playsAdditively {   // linked or frozen — both are real arrangeable tracks
                Button { project.tracks.contains { $0.id == t.id } ? sendClipFull(t) : () } label: { Label("Add Clip (full song)", systemImage: "rectangle.badge.plus") }
                if !project.busTracks.isEmpty {   // route this track's audio into a group bus (G3.4)
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
                    Button { _ = project.freezeTrack(t.id) } label: { Label("Freeze to Audio", systemImage: "snowflake") }
                }
            }
            if !LEGACY_TRACK_IDS.contains(t.id) {
                Divider()
                Button(role: .destructive) { confirmDeleteTrack = t } label: { Label("Delete Track", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundStyle(settings.inkFaint).frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
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
        let barPx = width / CGFloat(BARS)
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
                        project.checkpoint("clip", coalesce: false)
                        project.clips[t.id, default: []].append(Clip(s: bar, l: 2, color: t.color))
                    })
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

    private func seqName(_ i: Int) -> String { project.sequences.indices.contains(i) ? project.sequences[i].name : "A" }
    private func cycleSeq(_ id: String) {
        guard let idx = project.arrangement.firstIndex(where: { $0.id == id }) else { return }
        project.checkpoint("arrseq", coalesce: false)
        project.arrangement[idx].seq = (project.arrangement[idx].seq + 1) % max(1, project.sequences.count)
    }

    private var punchControl: some View {
        HStack(spacing: 4) {
            Text("PUNCH").font(FDFont.mono(8.5, .bold)).tracking(0.5).foregroundStyle(settings.inkFaint)
            Button { project.punchInBar = max(0, project.punchInBar - 1) } label: { offsetStep("–") }
            Text("\(project.punchInBar + 1)").font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink).frame(minWidth: 22)
            Button { project.punchInBar = min(BARS - 1, project.punchInBar + 1) } label: { offsetStep("+") }
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
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
        .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(settings.line, lineWidth: 1))
    }
    private func offsetStep(_ s: String) -> some View {
        Text(s).font(.system(size: 15, weight: .bold)).foregroundStyle(settings.inkDim).frame(width: 22, height: 24)
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
                .background(RoundedRectangle(cornerRadius: 8).fill(settings.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(settings.line, lineWidth: 1))
            }
        }
    }

    /// One-tap full song: Intro→Verse→Hook→Verse→Outro with track dynamics (Song Mode).
    /// Each section only plays the tracks listed, so the arrangement actually breathes.
    private func buildSong() {
        project.checkpoint("buildsong", coalesce: false)
        let hookSeq = max(0, min(1, project.sequences.count - 1))
        let structure: [(sec: String, len: Int, seq: Int, tracks: [String])] = [
            ("intro", 2, 0,       ["drums", "hats"]),
            ("verse", 4, 0,       ["drums", "hats", "bass", "vox"]),
            ("hook",  4, hookSeq, ["drums", "hats", "bass", "perc", "vox"]),
            ("verse", 4, 0,       ["drums", "hats", "bass", "vox"]),
            ("outro", 2, 0,       ["drums"]),
        ]
        var arr: [ArrItem] = []
        var clipMap: [String: [Clip]] = [:]
        var start = 0
        for (i, s) in structure.enumerated() {
            let seq = max(0, min(s.seq, project.sequences.count - 1))
            arr.append(ArrItem(id: "sng\(i)", section: s.sec, start: start, len: s.len, seq: seq))
            for t in s.tracks { clipMap[t, default: []].append(Clip(s: start, l: s.len, color: colorFor(t))) }
            start += s.len
        }
        project.arrangement = arr
        project.clips = clipMap
        project.songMode = true
    }

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

    private func laneFlag(_ s: String, on: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(9, .bold))
                .foregroundStyle(on ? (s == "S" ? Color(hex: "#08240f") : .white) : settings.inkFaint)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? .clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func addSection(_ sec: Kit.Section) {
        let last = project.arrangement.reduce(0) { max($0, $1.start + $1.len) }
        if last >= BARS { return }
        project.checkpoint("addsection", coalesce: false)
        project.arrangement.append(ArrItem(id: "a\(Int(Date().timeIntervalSince1970 * 1000))", section: sec.id, start: last, len: 2))
    }
}

extension TrackModeView {
    // MARK: audio track (A5)

    func audioTrackArea(track t: Track, width: CGFloat) -> some View {
        let barPx = width / CGFloat(BARS)
        let barSec = (60.0 / Double(project.bpm)) * 4
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
                    project.punchInBar = max(0, min(BARS - 1, Int(v.location.x / barPx)))
                })
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
                if audioDrag == nil { audioDrag = (clip.id, clip.startBar) }
                let nb = max(0, min(BARS - 1, Int((CGFloat(orig) * barPx + v.translation.width) / barPx + 0.5)))
                project.moveAudioClip(clip.id, toBar: nb)
            }
            .onEnded { _ in audioDrag = nil })
        .onTapGesture { editClip = clip.id }
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
