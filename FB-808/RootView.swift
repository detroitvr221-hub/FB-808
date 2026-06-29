//  RootView.swift — the workstation chassis: rail nav, header, mode routing,
//  and the settings sheet. iPad landscape, opens directly into the pads.

import SwiftUI
import Combine

// First-run guided tour / onboarding (B12). Re-openable from the rail "?" button.
struct TourOverlay: View {
    @ObservedObject var settings: AppSettings   // passed explicitly — overlay content doesn't reliably inherit @EnvironmentObject
    @Binding var show: Bool
    var onDone: () -> Void
    @State private var step = 0

    private let steps: [(icon: String, title: String, body: String)] = [
        ("square.grid.2x2.fill", "Welcome to FD·808", "A drum machine, synth, sampler and full DAW — and a place to learn how beats actually work."),
        ("square.grid.4x3.fill", "Make a beat", "Tap the Pads to play. The Sequence tab lays it on a 16-step grid — tap or drag to place hits, hold a step for probability & locks."),
        ("dial.medium.fill", "Shape the sound", "Synth builds melodies & basslines (try FM!), Sample chops & time-stretches audio, and the Mixer adds EQ, compression, sidechain & mastering."),
        ("circle.hexagongrid.fill", "Learn the theory", "The Theory tab has an interactive Circle of Fifths, a Groove Wheel, and ear-training games — tap the ? on any knob to learn what it does."),
        ("graduationcap.fill", "Build real skills", "Learn mode's guided path scores your timing, then drops the beat straight into a project to build on. Keep a daily streak going!"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(settings.accent.opacity(0.16)).frame(width: 84, height: 84)
                    Image(systemName: steps[step].icon).font(.system(size: 36)).foregroundStyle(settings.accent)
                }
                Text(steps[step].title).font(FDFont.display(24, .bold)).foregroundStyle(settings.ink)
                Text(steps[step].body).font(FDFont.ui(15)).foregroundStyle(settings.inkDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 420).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Circle().fill(i == step ? settings.accent : settings.line).frame(width: 7, height: 7)
                    }
                }.padding(.top, 4)
                HStack(spacing: 12) {
                    Button { show = false } label: {   // Skip dismisses but stays un-toured so it re-prompts next launch (#tour)
                        Text("Skip").font(FDFont.ui(15, .semibold)).foregroundStyle(settings.inkDim)
                            .padding(.horizontal, 22).frame(height: 46)
                            .fdCard(13, fill: settings.panel2)
                    }.buttonStyle(.plain)
                    Button { if step < steps.count - 1 { step += 1 } else { finish() } } label: {
                        Text(step < steps.count - 1 ? "Next" : "Start making beats").font(FDFont.ui(15, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 26).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 13).fill(settings.accent.ctaGradient()))
                    }.buttonStyle(.plain)
                }.padding(.top, 4)
            }
            .padding(EdgeInsets(top: 34, leading: 40, bottom: 30, trailing: 40))
            .frame(maxWidth: 520)
            .fdCard(26, fill: settings.panel)
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }

    private func finish() { onDone(); show = false }
}

struct AchievementToast: View {
    @ObservedObject var settings: AppSettings
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rosette").font(.system(size: 18)).foregroundStyle(settings.theme.perfect)
            VStack(alignment: .leading, spacing: 1) {
                Text("ACHIEVEMENT UNLOCKED").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                Text(label).font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Capsule().fill(settings.panel))
        .overlay(Capsule().stroke(settings.theme.perfect.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .padding(.top, 10)
    }
}

/// Pushes audio-related setting changes to the engine. Extracted from RootView.body as one modifier so
/// the (already large) body type-checks in reasonable time.
private struct AudioSettingsSync: ViewModifier {
    @ObservedObject var settings: AppSettings
    let apply: () -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: settings.audioBufferMs) { _, _ in apply() }
            .onChange(of: settings.polyphony) { _, _ in apply() }
            .onChange(of: settings.limiterOn) { _, _ in apply() }
            .onChange(of: settings.limiterCeilingDb) { _, _ in apply() }
            .onChange(of: settings.hqInterp) { _, _ in apply() }
            .onChange(of: settings.equalPowerPan) { _, _ in apply() }
            .onChange(of: settings.bandlimitedOsc) { _, _ in apply() }
            .onChange(of: settings.stereoInput) { _, _ in apply() }
            .onChange(of: settings.haptics) { _, _ in apply() }
    }
}

struct NavItem: Identifiable { let id: String; let label: String; let symbol: String }

let FD_NAV: [NavItem] = [
    NavItem(id: "pads", label: "Pads", symbol: "square.grid.2x2.fill"),
    NavItem(id: "sequence", label: "Sequence", symbol: "square.grid.4x3.fill"),
    NavItem(id: "synth", label: "Synth", symbol: "dial.medium.fill"),
    NavItem(id: "sample", label: "Sample", symbol: "waveform"),
    NavItem(id: "tracks", label: "Tracks", symbol: "rectangle.3.group.fill"),
    NavItem(id: "mixer", label: "Mixer", symbol: "slider.vertical.3"),
    NavItem(id: "theory", label: "Theory", symbol: "circle.hexagongrid.fill"),
    NavItem(id: "learn", label: "Learn", symbol: "graduationcap.fill"),
    NavItem(id: "teacher", label: "Teacher", symbol: "person.2.fill"),
]
let FD_LEVEL_NAV: [InterfaceLevel: [String]] = [
    .beginner: ["pads", "sequence", "synth", "theory", "learn"],
    .creator: ["pads", "sequence", "synth", "sample", "tracks", "mixer", "theory", "learn"],            // full production (no classroom)
    .advanced: ["pads", "sequence", "synth", "sample", "tracks", "mixer", "theory", "learn", "teacher"], // + Teacher / classroom
]

struct RootView: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var project: Project
    @EnvironmentObject var fx: PadFX
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var transport: Transport   // for follow-teacher play/stop (Step 7)
    @StateObject private var settings = AppSettings()
    @StateObject private var progress = ProgressStore()
    @StateObject private var classroom = ClassroomStore()   // persisted Teacher roster/live/feedback (#159)
    @StateObject private var session = SessionStore()       // live teacher↔student sync (SYSTEM_AUDIT Step 6)
    @StateObject private var midi = MIDIManager()           // CoreMIDI input → trigger APIs (AUDIO_ENGINE_PLAN Phase 6)

    @State private var tab = "pads"
    @State private var showSettings = false
    @State private var showProjects = false
    @State private var didAutoLoad = false
    @AppStorage("fd.toured") private var toured = false
    @State private var showTour = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var recoverSnap: ProjectSnapshot?
    @State private var missingAudio: [String] = []   // audio assets a loaded project references but can't find (Phase 8)
    @State private var exporting = false             // rail Share action — export is reachable at EVERY level (not just Tracks)
    @State private var exportFile: ExportFile?
    // Periodic autosave to the recovery slot: scenePhase isn't reliably delivered before an OOM kill, so a
    // long editing session that crashed used to lose everything since the last manual save (#audit-data).
    private let autosaveTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var allowed: [String] { FD_LEVEL_NAV[settings.level] ?? FD_LEVEL_NAV[.creator, default: FD_NAV.map(\.id)] }
    private var nav: [NavItem] { FD_NAV.filter { allowed.contains($0.id) } }

    var body: some View {
        let th = settings.theme
        HStack(spacing: 0) {
            rail(th)
            VStack(spacing: 0) {
                header(th)
                if session.isFollowing { followBanner(th) }   // live read-only mirror of the teacher
                content(th)
                    .allowsHitTesting(!session.isFollowing || session.forked)   // Follow = watch live; Try-it = edit locally
            }
        }
        .background(chassisBackground(th).ignoresSafeArea())
        .overlay(alignment: .top) {
            if let a = progress.newlyUnlocked {
                AchievementToast(settings: settings, label: a).id(a)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { progress.newlyUnlocked = nil } }
            }
        }
        .animation(.spring(response: 0.4), value: progress.newlyUnlocked)
        .tint(settings.accent)
        // Inject shared stores BEFORE sheets/overlays so presented content inherits them (#env-order).
        .environmentObject(settings)
        .environmentObject(progress)
        .environmentObject(classroom)
        .environmentObject(session)
        .environmentObject(midi)
        .overlay { if showTour { TourOverlay(settings: settings, show: $showTour) { toured = true } } }
        .onAppear {
            engine.start()
            project.pushMasterVolume()  // live master gain from the master fader (0.9 base × master.vol)
            applyAudio()                // push persisted buffer / polyphony / limiter prefs to the engine
            wireMIDI()                  // CoreMIDI input → existing trigger APIs (Phase 6); no-op when no device
            session.project = project   // received ops apply into the live project
            session.onRemoteTransport = { playing, bar, step in
                if !playing { transport.stop(); return }
                if !project.playing {
                    transport.startAt(bar: bar, step: step)            // join in time at the teacher's position
                } else {
                    let n = max(1, project.barSteps)
                    let drift = abs((project.bar * n + max(0, project.step)) - (bar * n + step))
                    if drift > 2 { transport.startAt(bar: bar, step: step) }   // re-seek only on real drift
                }
            }
            if !didAutoLoad {
                didAutoLoad = true
                // Disk reads run off the main actor (no launch hitch on large projects); the sequence below
                // stays ordered via sequential awaits on the main actor.
                Task { @MainActor in
                    await store.reload()   // populate the saved list off-main BEFORE resolving the last project
                    // Resolve the last project by STABLE ID first (survives rename/same-name collisions, #219),
                    // then fall back to the legacy name key (pre-id sessions), then to the most-recent save so
                    // the user is never silently dropped to a blank default.
                    var loaded: ProjectSnapshot? = nil
                    if let id = store.lastProjectID { loaded = await store.loadByID(id) }
                    if loaded == nil, let nm = store.lastProjectName { loaded = await store.loadByName(nm) }
                    if loaded == nil, let first = store.items.first { loaded = await store.load(first) }
                    if let snap = loaded {
                        let miss = store.missingAudioAssets(in: snap)   // warn from the RAW snap before repair clears the refs
                        project.restore(store.repaired(snap))           // load into a clean state (item 9 health repair)
                        if !miss.isEmpty { missingAudio = miss }
                    }
                    settings.mergeLegacySavedSynths(project.savedSynths)   // migrate per-project saved patches → global library (#67)
                    if store.hasFreshAutosave() { recoverSnap = await store.autosaveSnapshot() }   // crash/quit recovery
                    if recoverSnap == nil && !toured { showTour = true }
                    store.sweepOrphanWAVs()   // reclaim audio leaked by deleted clips/samples/projects
                }
            }
            if !allowed.contains(tab) { tab = allowed.first ?? "pads" }   // route to a level-allowed tab on launch (#263)
        }
        .onChange(of: scenePhase) { _, phase in
            // autosave unsaved work to the recovery slot when leaving the foreground
            if (phase == .background || phase == .inactive) && project.hasUnsavedChanges {
                project.persistSampleAudio()   // flush the sampler buffer to disk so crash-recovery can restore it (#review)
                store.autosave(project.snapshot())
            }
            if phase == .background { engine.allNotesOff() }   // release any held live notes (no stuck notes on return)
        }
        .onReceive(autosaveTick) { _ in
            // Keep the crash-recovery slot fresh during active editing (does not touch the named save).
            guard project.hasUnsavedChanges else { return }
            project.persistSampleAudio()
            store.autosave(project.snapshot())
        }
        .modifier(AudioSettingsSync(settings: settings, apply: applyAudio))
        .alert("Recover unsaved changes?", isPresented: Binding(get: { recoverSnap != nil }, set: { if !$0 { recoverSnap = nil } })) {
            Button("Recover") { if let s = recoverSnap { project.restore(store.repaired(s)) }; store.clearAutosave(); recoverSnap = nil }
            Button("Discard", role: .destructive) { store.clearAutosave(); recoverSnap = nil }
        } message: { Text("FD·808 closed with edits that were never saved. Recover them, or keep the last saved version?") }
        .alert("Some audio is missing", isPresented: Binding(get: { !missingAudio.isEmpty }, set: { if !$0 { missingAudio = [] } })) {
            Button("OK") { missingAudio = [] }
        } message: {
            Text("This project references audio that couldn't be found:\n\n• \(missingAudio.prefix(8).joined(separator: "\n• "))\n\nThe rest of the project loaded fine.")
        }
        .alert("Microphone access needed", isPresented: Binding(get: { project.micRecordFailed }, set: { if !$0 { project.micRecordFailed = false } })) {
            Button("OK") { project.micRecordFailed = false }
        } message: { Text("Recording couldn't start. Enable microphone access for FD·808 in Settings → Privacy → Microphone, then try again.") }
        .alert("Project cleaned up on load", isPresented: Binding(get: { !store.lastRepairs.isEmpty }, set: { if !$0 { store.clearRepairs() } })) {
            Button("OK") { store.clearRepairs() }
        } message: {
            Text("Some unreadable or orphaned data was removed so the project opens cleanly:\n\n• \(store.lastRepairs.prefix(8).joined(separator: "\n• "))\n\nSaving the project will make these changes permanent.")
        }
        .onChange(of: settings.level) { _, _ in
            if !allowed.contains(tab) { tab = allowed.first ?? "pads" }
        }
        .sheet(isPresented: $showSettings) {
            // Sheets don't inherit environmentObjects injected mid-hierarchy (settings/progress/midi live on
            // RootView, not the App root), so re-inject everything SettingsSheet reads — incl. midi (Phase 6).
            SettingsSheet().environmentObject(settings).environmentObject(progress).environmentObject(midi)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showProjects) {
            ProjectsSheet()
                .environmentObject(settings)
                .environmentObject(project)
                .environmentObject(store)
                .presentationDetents([.large])
        }
        .sheet(item: $exportFile) { f in ShareSheet(urls: f.urls) }
    }

    /// Bounce the song to M4A and present the share sheet — a level-independent entry point so Export is
    /// reachable even at Beginner level (where the Tracks tab, the only other export path, is hidden).
    private func quickExport() {
        guard !exporting, project.hasExportableContent else { return }
        exporting = true
        let plan = project.buildExportPlan(safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither
        Task {
            sweepExportDirs()
            let dir = fd808ExportDir()
            let url = await Task.detached(priority: .userInitiated) {
                let (l, r) = renderOffline(plan)
                return writeAudio(.m4a, left: l, right: r, sr: plan.sr, name: plan.name, dir: dir, dither: dither)
            }.value
            exporting = false
            if let url { exportFile = ExportFile(urls: [url]); progress.awardCreative("export", 10) }
        }
    }

    // MARK: chassis

    private func chassisBackground(_ th: Theme) -> some View {
        ZStack {
            LinearGradient(colors: th.chassisGradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [th.chassisGlow, .clear], center: .init(x: 0.2, y: 0), startRadius: 0, endRadius: 700)
        }
    }

    // MARK: rail

    private func rail(_ th: Theme) -> some View {
        VStack(spacing: 18) {
            // brand mark
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [settings.accent, settings.accent.darker(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                Circle().fill(.white).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 4))
            }
            .padding(.top, 22)
            .accessibilityHidden(true)   // decorative brand mark — no info for VoiceOver

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(nav) { n in
                        Button { tab = n.id } label: {
                            VStack(spacing: 5) {
                                Image(systemName: n.symbol).font(.system(size: 21))
                                    .foregroundStyle(tab == n.id ? settings.accent : th.inkFaint)
                                Text(n.label).font(FDFont.ui(11, .semibold))
                                    .foregroundStyle(tab == n.id ? th.ink : th.inkFaint)
                            }
                            .frame(width: 72, height: 66)
                            .background(RoundedRectangle(cornerRadius: 16)
                                .fill(tab == n.id ? settings.accent.opacity(0.14) : .clear))
                            .overlay(alignment: .leading) {   // non-color selected cue + a11y trait (#nav)
                                if tab == n.id {
                                    Capsule().fill(settings.accent).frame(width: 3, height: 30)
                                }
                            }
                        }.buttonStyle(.plain)
                        .accessibilityLabel(Text(n.label))
                        .accessibilityAddTraits(tab == n.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: .infinity)

            // projects + settings + led
            Button { showProjects = true } label: {
                Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(th.inkFaint)
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .topTrailing) {   // unsaved-changes indicator (#151)
                        if project.hasUnsavedChanges {
                            Circle().fill(settings.accent).frame(width: 7, height: 7)
                                .shadow(color: settings.accent, radius: 3).offset(x: -7, y: 7)
                        }
                    }
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("Projects"))
            .accessibilityValue(Text(project.hasUnsavedChanges ? "Unsaved changes" : ""))
            if project.hasExportableContent {   // bounce & share from any level (Tracks tab is hidden at Beginner)
                Button { quickExport() } label: {
                    Group {
                        if exporting { ProgressView().controlSize(.small).tint(th.inkFaint) }
                        else { Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(th.inkFaint) }
                    }.frame(width: 44, height: 44)
                }.buttonStyle(.plain).disabled(exporting)
                .accessibilityLabel(Text("Export and share this beat"))
            }
            Button { showTour = true } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 17)).foregroundStyle(th.inkFaint)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("Help"))
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundStyle(th.inkFaint)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
            Circle().fill(settings.accent).frame(width: 9, height: 9)
                .shadow(color: settings.accent, radius: 5)
                .padding(.bottom, 18)
                .accessibilityHidden(true)   // decorative status LED — not an interactive/informative element
        }
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .background(th.rail)
        .overlay(Rectangle().fill(th.line).frame(width: 1), alignment: .trailing)
    }

    // MARK: header

    private func header(_ th: Theme) -> some View {
        let level = progress.level
        let into = progress.levelProgress
        return HStack {
            styledText([("FD", th.ink, nil), ("·", settings.accent, nil), ("808", th.ink, nil)])
                .font(FDFont.display(21, .bold))
            Spacer()
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 15))
                        .foregroundStyle(progress.streak > 0 ? settings.accent : th.inkFaint)
                    Text("\(progress.streak)").font(FDFont.mono(14, .bold)).foregroundStyle(th.ink)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Daily streak"))
                .accessibilityValue(Text("\(progress.streak) \(progress.streak == 1 ? "day" : "days")"))
                // daily goal ring
                ZStack {
                    Circle().stroke(th.line, lineWidth: 3).frame(width: 26, height: 26)
                    Circle().trim(from: 0, to: progress.goalProgress)
                        .stroke(progress.goalMet ? th.good : settings.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 26, height: 26)
                    if progress.goalMet { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(th.good) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Daily goal"))
                .accessibilityValue(Text(progress.goalMet ? "Complete" : "\(Int(progress.goalProgress * 100)) percent"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("LVL \(level)").font(FDFont.mono(10, .bold)).tracking(0.8).foregroundStyle(th.inkDim)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(th.line)
                            Capsule().fill(LinearGradient(colors: [settings.accent, settings.accent.blend(th.perfect, 0.5)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * into)
                        }
                    }.frame(width: 120, height: 7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Level \(level)"))
                .accessibilityValue(Text("\(Int(into * 100)) percent to next level"))
                RoundedRectangle(cornerRadius: 13)
                    .fill(LinearGradient(colors: [Color(hex: "#6C7BFF"), Color(hex: "#21D0B2")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay(Text("M").font(FDFont.display(17, .bold)).foregroundStyle(.white))
                    .accessibilityHidden(true)   // decorative profile avatar placeholder
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 62)
        .overlay(Rectangle().fill(th.line).frame(height: 1), alignment: .bottom)
    }

    // MARK: content routing

    // Live-class read-only banner: students see the teacher's edits stream in, can't edit, can leave.
    private func followBanner(_ th: Theme) -> some View {
        HStack(spacing: 10) {
            Circle().fill(session.connected ? settings.accent : settings.inkFaint).frame(width: 8, height: 8)
            Text(session.forked ? "Trying it · \(session.roomCode)"
                 : (session.connected ? "Following live · \(session.roomCode)" : "Connecting…"))
                .font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
            Text("\(session.opsReceived) updates").font(FDFont.mono(10)).foregroundStyle(.white.opacity(0.7))
            Spacer()
            if session.forked {
                bannerBtn("Rejoin") { session.rejoin() }
            } else {
                bannerBtn("Try it") { session.tryIt() }
            }
            submitControl()   // bounce + upload + submit for review, with sending/sent/failed feedback
            bannerBtn("Leave") { session.leave() }
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background((session.forked ? settings.theme.perfect : settings.accent).opacity(0.92))
    }
    @ViewBuilder private func submitControl() -> some View {
        switch session.submitState {
        case .submitting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(settings.accent)
                Text("Sending…").font(FDFont.ui(12, .bold)).foregroundStyle(settings.accent)
            }
            .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(.white))
            .accessibilityLabel("Submitting your beat")
        case .sentWithAudio, .sentMetadataOnly:
            let withAudio = session.submitState == .sentWithAudio
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                Text(withAudio ? "Sent" : "Sent (no audio)").font(FDFont.ui(12, .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(settings.theme.good))
            .accessibilityLabel(withAudio ? "Beat sent to your teacher" : "Beat sent without audio — it was too large")
        case .failed:
            bannerBtn("Failed — Retry") { Task { await session.submitCurrentBeat() } }
        case .idle:
            bannerBtn("Submit") { Task { await session.submitCurrentBeat() } }
        }
    }
    private func bannerBtn(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(12, .bold)).foregroundStyle(settings.accent)
                .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(.white))
        }.buttonStyle(.plain)
    }

    private func applyAudio() {
        engine.applyAudioSettings(bufferSec: settings.audioBufferMs / 1000, polyphony: settings.polyphony,
                                  limiterOn: settings.limiterOn, limiterCeilingDb: settings.limiterCeilingDb)
        engine.setHQInterpolation(settings.hqInterp)        // opt-in audio-quality modes (default off)
        engine.setEqualPowerPan(settings.equalPowerPan)
        engine.setBandlimitedOsc(settings.bandlimitedOsc)
        engine.stereoCapture = settings.stereoInput         // opt-in stereo recording (applied on the next record)
        Haptics.shared.enabled = settings.haptics           // "feel the beat" haptics (F2)
    }

    /// Route CoreMIDI input onto the existing trigger APIs, then start the manager (Phase 6). Idempotent:
    /// re-setting the closures on a repeat onAppear is harmless and `midi.start()` self-guards. Mirrors the
    /// finger-tap path (trigger + visual bump + record-if-armed) so MIDI drumming records like taps.
    private func wireMIDI() {
        midi.onPad = { [weak project, weak engine, weak fx, weak transport] idx, vel in
            guard let project, let engine, idx >= 0 && idx < Kit.pads.count else { return }
            let padID = Kit.pads[idx].id
            engine.start()
            project.triggerPad(padID, accent: vel >= 0.8)
            fx?.bump(padID)
            if project.recording {
                if project.bank == "D", project.synthBank?[padID] != nil {
                    project.recordSynthPad(padID, transport?.recordFraction() ?? 0)
                } else {
                    project.recordHit(padID, transport?.recordFraction() ?? 0, vel: vel)
                }
            }
        }
        midi.onNoteOn  = { [weak project, weak engine] note, _ in engine?.start(); project?.synthNoteOn("midi-\(note)", midi: note) }
        midi.onNoteOff = { [weak project] note in project?.synthNoteOff("midi-\(note)") }
        midi.onPanic   = { [weak engine] in engine?.allNotesOff() }
        midi.start()
    }

    @ViewBuilder private func content(_ th: Theme) -> some View {
        Group {
            switch tab {
            case "pads": PadModeView(openTab: { tab = $0 })
            case "sequence": SequenceModeView()
            case "synth": SynthModeView()
            case "sample": SampleModeView()
            case "tracks": TrackModeView()
            case "mixer": MixerModeView()
            case "theory": TheoryModeView(openTab: { tab = $0 })
            case "learn": LearnModeView(engine: engine, fx: fx, onXP: { progress.addXP($0) }, openTab: { tab = $0 })
            case "teacher": TeacherModeView(openTab: { tab = $0 })
            default: PadModeView(openTab: { tab = $0 })
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
