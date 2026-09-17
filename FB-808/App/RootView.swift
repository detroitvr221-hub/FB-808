//  RootView.swift — the workstation chassis: rail nav, header, mode routing,
//  and the settings sheet. iPad landscape, opens directly into the pads.

import SwiftUI
import FD808Engine
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
                    Button { finish() } label: {   // Skip still completes onboarding — persists `toured` and shows the genre picker
                        Text("Skip").font(FDFont.ui(15, .semibold)).foregroundStyle(settings.inkDim)
                            .padding(.horizontal, 22).frame(height: 46)
                            // NB: inline chrome (not .fdCard) — this overlay doesn't inherit @EnvironmentObject,
                            // so .fdCard's env lookup would crash on first run; use the explicit `settings`.
                            .background(RoundedRectangle(cornerRadius: 13).fill(settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(settings.line, lineWidth: 1))
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
            // inline chrome (not .fdCard): overlay doesn't inherit @EnvironmentObject — see note above.
            .background(RoundedRectangle(cornerRadius: 26).fill(settings.panel))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(settings.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .animation(.easeOut(duration: 0.2), value: step)
    }

    private func finish() { onDone(); show = false }
}

// Genre-first quick start (UX flow): the documented antidote to beginner overwhelm — pick a vibe and get a
// playable starter beat immediately instead of a blank grid. Wraps Project.startFromTemplate (kit + tempo +
// swing + a pattern). Shown on first run after the tour, and re-openable as "New beat".
struct GenrePicker: View {
    @ObservedObject var settings: AppSettings   // overlays don't reliably inherit @EnvironmentObject — pass it
    let onPick: (String) -> Void                // a BeatGenerator style id, or "blank"
    var onClose: (() -> Void)? = nil

    private struct Genre { let id: String; let name: String; let vibe: String; let bpm: Int }
    private let genres: [Genre] = [
        .init(id: "boombap",  name: "Boom Bap",  vibe: "Classic head-nod hip-hop", bpm: 88),
        .init(id: "trap",     name: "Trap",      vibe: "Hard 808s & rolling hats",  bpm: 140),
        .init(id: "lofi",     name: "Lo-Fi",     vibe: "Dusty, mellow, chill",      bpm: 78),
        .init(id: "house",    name: "House",     vibe: "Four-on-the-floor dance",   bpm: 124),
        .init(id: "drill",    name: "Drill",     vibe: "Sliding 808s, dark & moody", bpm: 142),
        .init(id: "afrobeat", name: "Afrobeat",  vibe: "Syncopated global groove",  bpm: 108),
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("What do you want to make?").font(FDFont.display(26, .bold)).foregroundStyle(settings.ink)
                    Text("Pick a vibe — we'll start a beat that's already playing, then you tweak it.")
                        .font(FDFont.ui(14)).foregroundStyle(settings.inkDim).multilineTextAlignment(.center)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(genres, id: \.id) { g in
                        Button { onPick(g.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(g.name).font(FDFont.display(20, .bold)).foregroundStyle(settings.ink)
                                Text(g.vibe).font(FDFont.ui(12)).foregroundStyle(settings.inkDim)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text("\(g.bpm) BPM").font(FDFont.mono(10, .bold)).foregroundStyle(settings.accent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                        .accessibilityLabel(Text("\(g.name), \(g.vibe), \(g.bpm) BPM"))
                    }
                }
                .frame(maxWidth: 560)
                Button { onPick("blank") } label: {
                    Text("Start from scratch").font(FDFont.ui(14, .semibold)).foregroundStyle(settings.inkDim)
                        .padding(.horizontal, 20).frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .padding(34).frame(maxWidth: 640)
            .background(RoundedRectangle(cornerRadius: 26).fill(settings.panel))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(settings.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .overlay(alignment: .topTrailing) {
                if let onClose {
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(settings.inkFaint)
                    }.buttonStyle(.plain).padding(12).accessibilityLabel(Text("Close"))
                }
            }
        }
    }
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

/// First-run / quick-start flow (tour → genre picker → coaching nudge) as one modifier so the (already
/// large) RootView body stays type-checkable.
private struct FirstRunFlow: ViewModifier {
    @ObservedObject var settings: AppSettings
    @Binding var showTour: Bool
    @Binding var showGenre: Bool
    @Binding var coachTip: String?
    @Binding var confirmNewBeat: Bool
    @Binding var pendingGenre: String?   // a genre picked while the current beat has unsaved changes — confirm first
    @Binding var exportErr: String?
    var onSaveFirst: () -> Void
    var onTourDone: () -> Void
    var onPick: (String) -> Void
    var onReplace: (String) -> Void      // the confirmed, destructive path
    func body(content: Content) -> some View {
        content
            .overlay { if showTour { TourOverlay(settings: settings, show: $showTour, onDone: onTourDone) } }
            .overlay { if showGenre { GenrePicker(settings: settings, onPick: onPick, onClose: { showGenre = false }) } }
            .alert("Start a new beat?", isPresented: $confirmNewBeat) {
                Button("Save First") { onSaveFirst() }
                Button("Discard & start new", role: .destructive) { showGenre = true }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This clears your current beat. Save it first if you want to keep it.") }
            // The genre cards used to replace the project outright — reachable from Help → tour → Skip with
            // unsaved work and no undo (MAIN_SCREEN_AUDIT_2026-09-16 #1).
            .alert("Replace your current beat?", isPresented: Binding(get: { pendingGenre != nil }, set: { if !$0 { pendingGenre = nil } })) {
                Button("Save First") { pendingGenre = nil; onSaveFirst() }
                Button("Replace", role: .destructive) { if let g = pendingGenre { pendingGenre = nil; onReplace(g) } }
                Button("Cancel", role: .cancel) { pendingGenre = nil }
            } message: { Text("Starting a new beat clears the one you're working on, and that can't be undone. Save it first if you want to keep it.") }
            .alert("Export didn't work", isPresented: Binding(get: { exportErr != nil }, set: { if !$0 { exportErr = nil } })) {
                Button("OK", role: .cancel) { exportErr = nil }
            } message: { Text(exportErr ?? "") }
            .overlay(alignment: .top) {
                if let tip = coachTip {
                    Text(tip).font(FDFont.ui(13.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Capsule().fill(settings.accent))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5).padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { withAnimation { if coachTip == tip { coachTip = nil } } } }
                }
            }
            .animation(.spring(response: 0.4), value: coachTip)
    }
}

struct NavItem: Identifiable { let id: String; let label: String; let symbol: String }

/// Width of the fixed nav rail — one source of truth so the content column can be sized to exactly
/// the remaining width (see RootView.body).
let RAIL_W: CGFloat = 92

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
    @EnvironmentObject var link: LinkClock        // Ableton Link toggle lives in Settings (#20)
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
    @State private var showGenre = false        // genre-first quick-start overlay
    @State private var coachTip: String?        // transient first-beat coaching nudge
    @State private var confirmNewBeat = false   // guard the genre quick-start against clobbering unsaved work
    @State private var pendingGenre: String?    // genre picked with unsaved changes → "Replace your current beat?"
    @State private var exportErr: String?       // surface a failed header export (the only export path at Beginner level)
    @Environment(\.scenePhase) private var scenePhase
    @State private var recoverSnap: ProjectSnapshot?
    @State private var missingAudio: [String] = []   // audio assets a loaded project references but can't find (Phase 8)
    @State private var exporting = false             // rail Share action — export is reachable at EVERY level (not just Tracks)
    @State private var exportFile: ExportFile?
    @State private var pendingQuickExport: ExportFormat?   // Song Mode off + arrangement exists → ask song vs loop first
    @State private var pendingMixGate: ExportFormat?       // solo/mute active → "export as heard?" first (#export-1)
    @StateObject private var quickExportProg = ExportProgressBox()   // rail bounce: progress ring + tap-to-cancel
    // Periodic autosave to the recovery slot: scenePhase isn't reliably delivered before an OOM kill, so a
    // long editing session that crashed used to lose everything since the last manual save (#audit-data).
    private let autosaveTick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var allowed: [String] { FD_LEVEL_NAV[settings.level] ?? FD_LEVEL_NAV[.creator, default: FD_NAV.map(\.id)] }
    private var nav: [NavItem] { FD_NAV.filter { allowed.contains($0.id) } }

    var body: some View {
        let th = settings.theme
        // The content column is sized to EXACTLY the space left by the rail. Previously a mode whose
        // controls couldn't compress (e.g. the Sequence tools row in portrait) grew the HStack past the
        // screen and shoved the rail off the left edge — navigation was unreachable and rail-area taps
        // landed on the transport. Now over-wide content is clipped inside its own column instead.
        GeometryReader { g in
            HStack(spacing: 0) {
                rail(th)
                VStack(spacing: 0) {
                    header(th)
                    // The periodic recovery slot is the only protection for a long unsaved session; a write
                    // failure used to be a log line only, so on a full disk the safety net died silently.
                    if store.recoveryWriteFailed { recoveryBanner(th) }
                    if let failure = engine.audioFailure { audioFailureBanner(th, failure) }   // engine couldn't start — say so
                    if session.isFollowing { followBanner(th) }   // live read-only mirror of the teacher
                    content(th)
                        .allowsHitTesting(!session.isFollowing || session.forked)   // Follow = watch live; Try-it = edit locally
                }
                // .leading: if a mode still can't fit, lose the right edge rather than centering the
                // overflow and clipping the labels off the left as well.
                .frame(width: max(0, g.size.width - RAIL_W), height: g.size.height, alignment: .leading)
                .clipped()
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
        .modifier(FirstRunFlow(settings: settings, showTour: $showTour, showGenre: $showGenre, coachTip: $coachTip,
                               confirmNewBeat: $confirmNewBeat, pendingGenre: $pendingGenre, exportErr: $exportErr,
                               onSaveFirst: { showProjects = true },
                               // Only the FIRST tour flows into the genre picker. Replaying it from the rail's Help
                               // button used to land on the picker too — one tap from wiping the current beat.
                               onTourDone: { if !toured { toured = true; showGenre = true } },
                               onPick: pickGenre, onReplace: applyGenre))
        .onAppear {
            engine.start()
            project.pushMasterVolume()  // live master gain from the master fader (0.9 base × master.vol)
            applyAudio()                // push persisted buffer / polyphony / limiter prefs to the engine
            wireMIDI()                  // CoreMIDI input → existing trigger APIs (Phase 6); no-op when no device
            session.project = project   // received ops apply into the live project
            // Joining replaces the beat (#sync-1). Explicit weak captures: an implicit `self` here retained the
            // view's session box from the session's own closure (round 3, cross-4).
            session.onBeforeJoin = { [weak project, weak store] in
                guard let project, let store, project.hasUnsavedChanges else { return }
                store.autosave(project.savePayload()) { Task { @MainActor in _ = await SharedPatchStore.flush() } }
            }
            session.onRemoteTransport = { playing, bar, step in
                // Follower policy (position comparison, deadband, re-seek) lives in Transport.followerAction
                // so the cyclic-drift rule is unit-tested instead of re-derived here. (#19)
                switch Transport.followerAction(playing: playing, bar: bar, step: step,
                                                localPlaying: project.playing, localBar: project.bar,
                                                localStep: max(0, project.step),
                                                barSteps: project.barSteps, songBars: project.songBars) {
                case .ignore:
                    break
                case .stop:
                    transport.stop()
                case .start(let b, let s), .reseek(let b, let s):
                    transport.startAt(bar: b, step: s)   // join in time at the teacher's position
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
                        let miss = await store.missingAudioAssetsAsync(in: snap)   // RAW snap, off-main (round 2, persist-M3)
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
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        // Session/autosave observers live in a ViewModifier: `body` is at the type-checker's limit (see below).
        .modifier(ClassSessionSync(session: session, project: project, autosaveTick: autosaveTick,
                                   onTick: saveRecovery, onClassEnded: classEnded))
        .modifier(AudioSettingsSync(settings: settings, apply: applyAudio))
        .alert("Recover unsaved changes?", isPresented: Binding(get: { recoverSnap != nil }, set: { if !$0 { recoverSnap = nil } })) {
            Button("Recover") { if let s = recoverSnap { project.restore(store.repaired(s)); project.checkpoint("recovered", coalesce: false) }; recoverSnap = nil }
            Button("Discard", role: .destructive) { store.clearAutosave(protecting: project.liveAssetFilenames); recoverSnap = nil }
            Button("Decide later", role: .cancel) { recoverSnap = nil }   // keeps the slot — a mis-tap can't destroy the session
        } message: { Text("FD·808 closed with unsaved edits to “\(recoverSnap?.name ?? "a beat")”. Recover them, keep the last saved version, or decide later (the recovery copy stays until you save or discard).") }
        .alert("Some audio is missing", isPresented: Binding(get: { !missingAudio.isEmpty }, set: { if !$0 { missingAudio = [] } })) {
            Button("OK") { missingAudio = [] }
        } message: {
            Text("This project references audio that couldn't be found:\n\n• \(missingAudio.prefix(8).joined(separator: "\n• "))\n\nThe rest of the project loaded fine.")
        }
        .alert("Microphone access needed", isPresented: Binding(get: { project.micRecordFailed }, set: { if !$0 { project.micRecordFailed = false } })) {
            Button("OK") { project.micRecordFailed = false }
        } message: { Text("Recording couldn't start. Enable microphone access for FD·808 in Settings → Privacy → Microphone, then try again.") }
        // Applied through a small ViewModifier rather than inline: `body` is already a very long
        // modifier chain, and inlining this alert pushed the expression past the type-checker's
        // limit ("unable to type-check this expression in reasonable time" at body's opening line).
        .modifier(SaveAudioFailureAlert(failed: project.audioWriteFailed) { project.audioWriteFailed = false })
        .alert("Project cleaned up on load", isPresented: Binding(get: { !store.lastRepairs.isEmpty }, set: { if !$0 { store.clearRepairs() } })) {
            Button("OK") { store.clearRepairs() }
        } message: {
            Text("Some unreadable or orphaned data was removed so the project opens cleanly:\n\n• \(store.lastRepairs.prefix(8).joined(separator: "\n• "))\n\nSaving the project will make these changes permanent.")
        }
        .onChange(of: settings.level) { _, _ in
            if !allowed.contains(tab) { tab = allowed.first ?? "pads" }
        }
        .onOpenURL { url in importSharedBeat(url) }
        .alert("Solo or mute is on", isPresented: Binding(get: { pendingMixGate != nil }, set: { if !$0 { pendingMixGate = nil } })) {
            Button("Export as heard") { if let f = pendingMixGate { pendingMixGate = nil; quickExportAfterGate(f) } }
            Button("Cancel", role: .cancel) { pendingMixGate = nil }
        } message: { Text("The export follows the mixer exactly — soloed-out or muted channels, rows and tracks will be missing from the file.") }
        .sheet(isPresented: $showSettings) {
            // Sheets don't inherit environmentObjects injected mid-hierarchy (settings/progress/midi live on
            // RootView, not the App root), so re-inject everything SettingsSheet reads — incl. midi (Phase 6).
            SettingsSheet().environmentObject(settings).environmentObject(progress).environmentObject(midi)
                .environmentObject(link)   // the Link toggle is the only writer of LinkKit's enable flag (#20)
                .presentationSizing(.page)   // full page sheet — the card sections need the height
        }
        .sheet(isPresented: $showProjects) {
            ProjectsSheet(onNewBeat: requestNewBeat)
                .environmentObject(settings)
                .environmentObject(project)
                .environmentObject(store)
                .presentationDetents([.large])
        }
        .sheet(item: $exportFile) { f in ShareSheet(urls: f.urls) }
        .confirmationDialog("Share your beat", isPresented: Binding(get: { pendingQuickExport != nil }, set: { if !$0 { pendingQuickExport = nil } }), titleVisibility: .visible) {
            Button("Full song · \(project.songBars) bars") { if let f = pendingQuickExport { runQuickExport(f, fullSong: true) }; pendingQuickExport = nil }
            Button("Current loop · 4 bars") { if let f = pendingQuickExport { runQuickExport(f, fullSong: false) }; pendingQuickExport = nil }
            Button("Cancel", role: .cancel) { pendingQuickExport = nil }
        } message: { Text("You have an arrangement, but Song Mode is off. Share the whole song, or just the loop that's playing?") }
    }

    /// Bounce the song to M4A and present the share sheet — a level-independent entry point so Export is
    /// reachable even at Beginner level (where the Tracks tab, the only other export path, is hidden).
    /// "New Beat" entry → genre quick-start, guarding unsaved work (the picker's startFromTemplate clears it).
    private func handleScenePhase(_ phase: ScenePhase) {
        if (phase == .background || phase == .inactive) && project.hasUnsavedChanges && !session.isFollowing {
            saveRecovery()
        }
        if phase == .background {
            engine.allNotesOff()
            Task { _ = await SharedPatchStore.flush() }
            // Idle in the background: with the audio background mode the engine would otherwise render
            // silence and tick its timers indefinitely. Playing or recording keeps running (round 2, lifecycle-4).
            if !transport.playing && !engine.isMicRecording { engine.suspend() }
        }
        if phase == .active, !engine.isRunning {
            engine.restartAudio()   // coming back from another app with the engine stopped
        }
    }

    /// The host ended the class: put the student's own beat back and say so (round 3, sync-1).
    private func classEnded() {
        session.acknowledgeClassEnded()
        coachTip = project.restorePreJoin() ? "The teacher ended the class — your own beat is back."
                                            : "The teacher ended the class."
    }
    private func saveRecovery() {
        let payload = project.savePayload()
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save beat", expirationHandler: nil)
        store.autosave(payload) {
            Task { @MainActor in
                _ = await SharedPatchStore.flush()
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private func requestNewBeat() {
        if project.hasUnsavedChanges { confirmNewBeat = true } else { showGenre = true }
    }

    /// Genre quick-start pick. With unsaved work this is destructive and not undoable (`startFromTemplate`
    /// restores a fresh snapshot and clears the recovery slot), so it goes through a confirm first.
    private func pickGenre(_ id: String) {
        if project.hasUnsavedChanges { pendingGenre = id } else { applyGenre(id) }
    }
    /// Seed the starter beat, auto-play it ("already grooving"), land on Pads, and nudge the first-time
    /// user toward the next step (jam / tweak / share).
    private func applyGenre(_ id: String) {
        showGenre = false
        project.startFromTemplate(id)
        // The previous beat's edits are discarded by the template switch, so its recovery slot must go with
        // it (and its now-unreferenced audio is reclaimed) instead of being offered back at the next launch.
        store.clearAutosave(protecting: project.liveAssetFilenames)
        tab = "pads"
        if id == "blank" {
            coachTip = "Tap the pads to play. Hit ● to record your beat, or draw it on the Sequence grid."
        } else {
            transport.start()
            coachTip = "Your beat's playing! Tap the pads to jam, open Sequence to tweak it, or Share when you're proud."
        }
    }

    private func quickExport(_ format: ExportFormat) {
        guard !exporting, project.hasExportableContent else { return }
        if project.mixGateActive { pendingMixGate = format; return }   // solo/mute would silently shape the file (#export-1)
        quickExportAfterGate(format)
    }
    private func quickExportAfterGate(_ format: ExportFormat) {
        if !project.songMode && !project.arrangement.isEmpty { pendingQuickExport = format; return }
        runQuickExport(format, fullSong: false)
    }
    /// A shared `.fd808` opened from Files / AirDrop / Mail: import it into the library and open the
    /// Projects sheet — never replace the current beat unasked (#export-8).
    private func importSharedBeat(_ url: URL) {
        guard url.pathExtension.lowercased() == "fd808" else { return }
        Task { @MainActor in
            let snap = await store.importArchive(from: url)
            // iOS copies an opened document into Documents/Inbox; without this every AirDropped beat stayed
            // there as a duplicate archive — including failed ones (round 2 export-3, round 3 export-5).
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            if let snap {
                coachTip = "Imported “\(snap.name)” into your beats — open it from Projects."
                showProjects = true
            } else {
                coachTip = "Couldn't import that beat file — it may be damaged or over 256 MB."
            }
        }
    }

    private func runQuickExport(_ format: ExportFormat, fullSong: Bool) {
        guard !exporting else { return }
        exporting = true
        let plan = project.buildExportPlan(songModeOverride: fullSong ? true : nil,
                                           safetyEnabled: settings.limiterOn, safetyCeilingDb: settings.limiterCeilingDb)
        let dither = settings.exportDither
        let prog = quickExportProg; prog.reset()
        Task {
            await Task.detached(priority: .utility) { sweepExportDirs() }.value   // off-main (#export-5)
            let dir = fd808ExportDir()
            let result: Result<URL, ExportWriteFailure>? = await Task.detached(priority: .userInitiated) {
                let (l, r) = renderOffline(plan, progress: { p in prog.report(p) }, isCancelled: { prog.cancelled })
                if prog.cancelled { return nil }
                return writeAudio(format, left: l, right: r, sr: plan.sr, name: plan.name, dir: dir, dither: dither)
            }.value
            exporting = false
            switch result {
            case .success(let url)?: exportFile = ExportFile(urls: [url]); progress.awardCreative("export", 10)
            case .failure(let failure)?: exportErr = failure.message   // names a real I/O cause, not "add some sounds" (#65)
            case nil: break   // cancelled
            }
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
            if exporting {
                // Rendering: a determinate ring that cancels on tap (the rail bounce used to be an
                // uninterruptible spinner — round 2, export-5).
                Button { quickExportProg.cancel() } label: {
                    ZStack {
                        Circle().stroke(th.line, lineWidth: 3).frame(width: 26, height: 26)
                        Circle().trim(from: 0, to: quickExportProg.value)
                            .stroke(settings.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 26, height: 26)
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(th.inkFaint)
                    }.frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel export"))
                .accessibilityValue(Text("\(Int(quickExportProg.value * 100)) percent"))
            } else if project.hasExportableContent {   // bounce & share from any level (Tracks tab is hidden at Beginner)
                Menu {
                    Button { quickExport(.m4a) } label: { Label("M4A · easy to share", systemImage: "waveform") }
                    Button { quickExport(.wav) } label: { Label("WAV · lossless", systemImage: "waveform.path") }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17)).foregroundStyle(th.inkFaint)
                        .frame(width: 44, height: 44)
                }
                .menuStyle(.button).buttonStyle(.plain)
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
        .frame(width: RAIL_W)
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

    // The periodic recovery slot stopped writing (full disk / unwritable container). Unsaved work is no
    // longer protected by the crash safety net, so say so plainly and route the user to Save.
    /// The engine could not start (session refused, route held by another app). Before this, the pads
    /// flashed and the playhead moved with no sound and no message (SYSTEMS_GAP_AUDIT #lifecycle-3).
    private func audioFailureBanner(_ th: Theme, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash.fill").font(.system(size: 13, weight: .bold))
            Text("No sound — \(detail)").font(FDFont.ui(13, .semibold)).lineLimit(1)
            Spacer()
            bannerBtn("Retry") { engine.restartAudio() }
        }
        .padding(.horizontal, 16).frame(height: 40)
        .foregroundStyle(.white)
        .background(th.miss.opacity(0.92))
        .accessibilityElement(children: .combine)
    }

    private func recoveryBanner(_ th: Theme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .bold))
            Text("Auto-recovery is paused — save your beat").font(FDFont.ui(13, .semibold))
            Spacer()
            bannerBtn("Save") { showProjects = true }
        }
        .padding(.horizontal, 16).frame(height: 40)
        .foregroundStyle(.white)
        .background(th.miss.opacity(0.92))
        .accessibilityElement(children: .combine)
    }

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
            if session.forked { submitControl() }   // only the student's OWN work is submittable (round 3, sync-5)
            bannerBtn("Leave") {
                session.leave()
                if project.restorePreJoin() { coachTip = "Your own beat is back. Undo brings the class version." }
            }
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
        // Publish the same values for the AUv3: a plugin instance renders through its own SynthCore, so
        // without this it keeps the engine's raw defaults (naive oscillator, 64 voices) and does not match
        // the app for the same patch (finding 55).
        SharedAudioSettingsStore.save(settings.sharedAudioSettings)
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
        midi.onNoteOn  = { [weak project, weak engine] note, vel, channel in engine?.start(); project?.synthNoteOn("midi-\(channel)-\(note)", midi: note, vel: vel) }   // pass controller velocity (#MIDI-02)
        midi.onNoteOff = { [weak project] note, channel in project?.synthNoteOff("midi-\(channel)-\(note)") }
        midi.onPanic   = { [weak engine, weak project] in
            project?.assistHeld.removeAll(); project?.stopArp(); engine?.allNotesOff()
        }
        midi.start()
    }

    @ViewBuilder private func content(_ th: Theme) -> some View {
        Group {
            switch tab {
            case "pads": PadModeView(openTab: { tab = $0 })
            case "sequence": SequenceModeView()
            case "synth": SynthModeView()
            case "sample": SampleModeView(openTab: { tab = $0 })
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

/// Surfaces a failed audio write (audit finding 2). Extracted from `RootView.body` to keep that
/// expression inside the type-checker's budget; the value is read on every render, so the binding
/// always reflects the current flag.
private struct SaveAudioFailureAlert: ViewModifier {
    let failed: Bool
    let clear: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Couldn't save your audio", isPresented: Binding(get: { failed }, set: { if !$0 { clear() } })) {
                Button("OK", action: clear)
            } message: {
                Text("A recording or sample couldn't be written to storage, so it was not kept. Free up some space and try again.")
            }
    }
}

/// Class-session + periodic-autosave observers, split out of `RootView.body` (type-checker budget).
private struct ClassSessionSync: ViewModifier {
    @ObservedObject var session: SessionStore
    @ObservedObject var project: Project
    let autosaveTick: Publishers.Autoconnect<Timer.TimerPublisher>
    let onTick: () -> Void
    let onClassEnded: () -> Void
    func body(content: Content) -> some View {
        content
            .onReceive(autosaveTick) { _ in
                // Keep the crash-recovery slot fresh during active editing (does not touch the named save).
                // Not for the whole class session (forked included): the slot holds the student's OWN beat from
                // the join; a fork's autosave overwrote it (round 2 sync-3, round 3 sync-2).
                guard project.hasUnsavedChanges, !session.isFollowing else { return }
                onTick()
            }
            .onChange(of: session.classEndedByHost) { _, ended in if ended { onClassEnded() } }
            .onChange(of: session.isFollowing) { _, _ in project.editingLocked = session.isFollowing && !session.forked }
            .onChange(of: session.forked) { _, _ in project.editingLocked = session.isFollowing && !session.forked }
    }
}
