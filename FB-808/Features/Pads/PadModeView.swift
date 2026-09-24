//  PadModeView.swift — expanded performance: banks A–D, Full Level,
//  16 Levels, Note Repeat, record-into-pattern. Ported from mode-pad.jsx.

import SwiftUI

private let REPEAT_DIVS = ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"]
private let DIV_BEATS: [String: Double] = ["1/4": 1, "1/8": 0.5, "1/8T": 1.0/3, "1/16": 0.25,
                                           "1/16T": 1.0/6, "1/32": 0.125, "1/32T": 1.0/12, "1/64": 0.0625]
private let LEVEL_PARAMS = ["velocity", "pitch", "pan", "filter"]

struct PadModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var fx: PadFX
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transport: Transport
    @EnvironmentObject var progress: ProgressStore
    var openTab: (String) -> Void = { _ in }

    @State private var repeatTimers: [String: Timer] = [:]
    @State private var longTimer: Timer?
    /// The one pad whose long-press can currently open the editor. Keyed per pad (not one shared timer)
    /// so another finger's hit-down or release can't cancel a pending press (finding 38).
    @State private var longPressPad: String?
    /// How many live touches each pad has, from the grid's onDown/onUp. The timer body consults this so
    /// the editor opens only for a pad that is STILL held when the hold fires.
    @State private var heldPads: [String: Int] = [:]
    @State private var editMode = false
    @State private var editPadID: String?
    @State private var showSaveKit = false
    @State private var showKits = false
    @State private var newKitName = ""
    @State private var toast: String?
    @State private var showMPCBridge = false
    @State private var confirmDeleteKit: UserKitDef?   // deleting a saved kit is outside the project undo system → confirm first

    /// The selected pad's SLOT in the bank being viewed. `selectedRow` is one project-wide value, so on a
    /// bank switch it still names the old bank's pad; resolving the slot keeps the selection on the same
    /// position instead of pointing at a pad that is not on screen.
    private var sel: String { Kit.slotKey(bank: project.bank, pad: project.selectedRow) }

    private func flashToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { if toast == msg { toast = nil } }
    }

    var body: some View {
        VStack(spacing: 16) {
            TransportBar()
            StageSplit(sideWidth: 268) { stacked in
                // stacked (portrait / narrow): the grid gets the full width instead of ~a third
                stage(maxSide: stacked ? 820 : 600)
            } side: { stacked in
                side(stacked: stacked)
            }
        }
        .overlay {
            if let id = editPadID, let pad = Kit.banks[project.bank]?.pads.first(where: { $0.id == id }) ?? Kit.padByID[id] {
                PadInspectorView(pad: pad, onClose: { editPadID = nil })
            }
        }
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
        .sheet(isPresented: $showMPCBridge) { MPCBridgeView(onClose: { showMPCBridge = false }) }
        .sheet(isPresented: $showKits) { KitBrowserView() }
        .onDisappear {
            repeatTimers.values.forEach { $0.invalidate() }
            repeatTimers.removeAll()
            longTimer?.invalidate()
            longTimer = nil
            longPressPad = nil
            heldPads.removeAll()
        }
        .alert("Save Kit", isPresented: $showSaveKit) {
            TextField("Kit name", text: $newKitName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let id = settings.addUserKit(name: newKitName, sounds: project.currentPadSounds())
                project.activeKit = "user:\(id)"
            }
        } message: { Text("Saves the current pad sounds as a reusable kit.") }
        .alert(item: $confirmDeleteKit) { uk in
            Alert(title: Text("Delete “\(uk.name)”?"),
                  message: Text("This removes the saved kit. It can't be undone."),
                  primaryButton: .destructive(Text("Delete")) {
                      if project.activeKit == "user:\(uk.id)" { project.activeKit = "" }
                      settings.deleteUserKit(uk.id)
                  },
                  secondaryButton: .cancel())
        }
    }

    // MARK: stage

    private var bankPads: [PadDef] {
        let base = Kit.banks[project.bank]?.pads ?? Kit.pads
        if project.sixteenLevels, let selPad = Kit.padByID[sel] {
            return base.map { var p = $0; p.label = selPad.label; p.color = selPad.color; return p }
        }
        // apply pad-inspector color/label overrides
        return base.map { p in
            guard let o = project.padParams[p.id], o.colorHex != nil || o.label != nil else { return p }
            var np = p
            if let l = o.label { np.label = l }
            if let c = o.color { np.color = c }
            return np
        }
    }
    /// True when the current bank is a user-content bank (C slices / D synth) with nothing assigned yet.
    private var bankIsEmpty: Bool {
        let ids = (Kit.banks[project.bank]?.pads ?? []).map(\.id)
        switch project.bank {
        case "C": return (project.sliceBank?.isEmpty ?? true) && ids.allSatisfy { !project.padSampleActive($0) }   // bank-scoped samples (F0)
        case "D": return project.synthBank?.isEmpty ?? true
        default:  return false
        }
    }
    /// Shown in the header AND as the tap toast while a C/D bank has nothing on it.
    private var emptyBankHint: String {
        project.bank == "C" ? "Bank C is empty · chop a sample in the Sample tab to fill these pads"
                            : "Bank D is empty · map a synth sound from the Synth tab to fill these pads"
    }
    private var badges: [String: String]? {
        guard project.sixteenLevels else { return nil }
        var b: [String: String] = [:]
        for p in Kit.banks[project.bank]?.pads ?? Kit.pads { b[p.id] = String(p.index + 1) }
        return b
    }

    private func stage(maxSide: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ModeHead(title: "Pads",
                     eyebrow: "Bank \(project.bank) · \(Kit.banks[project.bank]?.name ?? "")",
                     hint: bankIsEmpty ? emptyBankHint : editMode ? "✎ Tap a pad to open its editor" : (project.recording ? "● Recording into pattern" : "Tap to play · hit ● to record — it shows up on the Sequence grid too · long-press a pad to edit"))
                .padding(.bottom, 12)
            MPCCoachStrip(section: "Playing the Pads").padding(.bottom, 10)   // Settings → MPC Coach
            PadGridView(pads: bankPads,
                        showLabels: settings.padLabels && !project.sixteenLevels,
                        badges: badges,
                        mutedIDs: project.muteMode ? Set(project.rowMute.filter { $0.value }.keys) : [],
                        emptyIDs: bankIsEmpty ? Set(bankPads.map(\.id)) : [],   // dashed "EMPTY" pads, no look-alike drums
                        touchVelocity: settings.padTouchVelocity,
                        maxSide: maxSide,
                        onHit: onHit, onUp: onUp)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: side panel

    /// Control panel content. StageSplit owns the scrolling (it decides whether this sits beside the
    /// stage or under it). Beside the stage it is one column; stacked under it (portrait / narrow) the
    /// cards spread over two columns, because a single 830 pt-wide column of nine cards left the user
    /// scrolling five screens of mostly empty card width (MAIN_SCREEN_AUDIT_2026-09-16 #4).
    private func side(stacked: Bool) -> some View {
        Group {
            if stacked {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                    GridItem(.flexible(), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) { cards }
            } else {
                VStack(spacing: 14) { cards }
            }
        }
    }

    @ViewBuilder private var cards: some View {
            PanelCard(title: "Pad Banks") {
                HStack(spacing: 8) {
                    ForEach(Kit.bankOrder, id: \.self) { b in
                        bankButton(b)
                    }
                }
            }
            if bankIsEmpty {   // C/D with nothing assigned yet — the guidance comes FIRST, not below the fold
                PanelCard(title: project.bank == "C" ? "Empty Slice Bank" : "Empty Synth Bank") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(project.bank == "C"
                             ? "Bank C plays your own chopped samples. Record or import audio in the Sample tab, then chop it into slices — they'll land on these pads."
                             : "Bank D plays synth voices. Build or pick a sound in the Synth tab and map it across these pads.")
                            .font(FDFont.ui(12.5)).foregroundStyle(settings.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { openTab(project.bank == "C" ? "sample" : "synth") } label: {
                            HStack(spacing: 6) {
                                Image(systemName: project.bank == "C" ? "waveform" : "dial.medium.fill").font(.system(size: 13))
                                Text(project.bank == "C" ? "Open Sample tab" : "Open Synth tab").font(FDFont.ui(12.5, .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent))
                        }.buttonStyle(.plain)
                    }
                }
            }
            PanelCard(title: "Sound Kits") {
                Button { showKits = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 15))
                        Text("Browse & Download Kits").font(FDFont.ui(13, .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 11).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain)
                Text("Download sound kits and load them straight onto your pads.")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            }
            if project.bank != "C" && project.bank != "D" {   // C=slices, D=synth — drum kits don't apply there
                PanelCard(title: "Drum Kit") {
                    VStack(spacing: 6) {
                        ForEach(Kit.drumKits) { kit in kitRow(kit) }
                        ForEach(settings.userKits) { uk in userKitRow(uk) }
                        Button { newKitName = ""; showSaveKit = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").font(.system(size: 13))
                                Text("Save Current Kit").font(FDFont.ui(12.5, .semibold))
                            }
                            .foregroundStyle(settings.accent)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
                        }.buttonStyle(.plain)
                    }
                    Text("Swaps every pad's sound. Tune, layers & per-pad samples are kept.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
                }
            }
            PanelCard(title: "Pad Play") {
                let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: cols, spacing: 8) {
                    perfButton("Full Level", on: project.fullLevel) { project.setFullLevel(!project.fullLevel) }
                    perfButton("Mute", on: project.muteMode) { project.muteMode.toggle() }
                    perfButton("16 Levels", on: project.sixteenLevels) { project.sixteenLevels.toggle() }
                    perfButton("Note Repeat", on: project.noteRepeat) { project.noteRepeat.toggle() }
                }
                Text("Your MPC **PAD PLAY** row. **Mute** drops sounds in & out live · **16 Levels** spreads one sound across all pads · **Note Repeat** machine-guns a held pad · **Full Level** locks max velocity.")
                    .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
            }
            if project.muteMode {
                PanelCard(title: "Mute Mode") {
                    Text("Tap any pad to mute it (turns **red**) or unmute it — live, while the beat plays. Build drops and breakdowns without erasing anything.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                    perfButton("Unmute All", on: false) { project.unmuteAllRows() }
                        .padding(.top, 6)
                }
            }
            if project.noteRepeat {
                PanelCard(title: "Repeat Rate") {
                    let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(REPEAT_DIVS, id: \.self) { d in divButton(d, on: project.repeatDiv == d) { project.repeatDiv = d } }
                    }
                    Text("Hold a pad to machine-gun it in time. Great for hi-hat rolls and 808 stutters.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
                }
            }
            if project.sixteenLevels {
                PanelCard(title: "16 Levels · \(sel.uppercased())") {
                    let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
                    LazyVGrid(columns: cols, spacing: 6) {
                        ForEach(LEVEL_PARAMS, id: \.self) { p in
                            divButton(p.capitalized, on: project.levelsParam == p) { project.levelsParam = p }
                        }
                    }
                    Text("Each pad plays \(sel) at a different \(project.levelsParam) — pad 1 softest, pad 16 loudest.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
                }
            }
            PanelCard(title: "Resample") {
                perfButton("⟳ Resample → \(Kit.padByID[sel]?.label ?? sel.uppercased())", on: false) {
                    engine.start()
                    Task { @MainActor in
                        guard await project.resampleToPad(sel) else { return }
                        progress.awardCreative("resample", 6)
                        flashToast("Resampled your beat onto \(Kit.padByID[sel]?.label ?? sel) — now chop or play it")
                    }
                }
                if project.padSampleData[sel]?.isEmpty == false {   // only pads that actually hold sample data (F1)
                    perfButton("✂︎ Edit in Sampler", on: false) { editInSampler(sel) }
                }
                Text("Bounce your whole beat onto the selected pad as a new sample — then chop it, retune it, or stack it. The classic MPC flip.")
                    .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
            }
            PanelCard(title: "Send to Tracks") {
                perfButton("→ New Track from Pattern", on: false) {
                    let id = project.sendLanesToNewTrack()
                    if !id.isEmpty { progress.awardCreative("sendTrack", 6) }
                    flashToast(id.isEmpty ? "Program or record some hits first — nothing to send"
                                          : "Sent your pattern to a new layered track — open Tracks to arrange it")
                }
                Text("Capture the pads you've programmed (or recorded) into their **own track** on the arrangement timeline — stack up to 99 layers, mute them, or build a full song.")
                    .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
            }
            PanelCard(title: "Pad Editor") {
                perfButton(editMode ? "Tap a pad to edit…" : "✎ Edit a Pad", on: editMode) { editMode.toggle() }
                Text("Or **long-press** any pad. Set its sound, tune, choke group, layers, color & name.")
                    .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
            }
            PanelCard(title: "Moving to an MPC?") {
                perfButton("📖 MPC Bridge", on: false) { showMPCBridge = true }
                Text("See where every FD-808 control lives on a real Akai MPC — Pad Play, Chop, Resample, Flex Beat & more.")
                    .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).padding(.top, 4)
            }
            CoachNote("**Choke groups** let one sound cut another — like a closed hat silencing an open hat. Open the pad editor to set them.")
    }

    // MARK: interactions

    /// Long-press-to-edit rules (finding 38), kept pure so the multi-touch conflict is regression-tested.
    /// ONE pad is the candidate at a time; a second finger's hit-down neither replaces nor cancels it, and
    /// a take / Note Repeat roll never arms it at all.
    nonisolated static func shouldArmLongPress(noteRepeat: Bool, recording: Bool, armedPad: String?) -> Bool {
        !noteRepeat && !recording && armedPad == nil
    }
    /// Only the pad that armed the press may cancel it when released. Every finger's release used to
    /// invalidate the single shared timer, so holding pad A while drumming pad B killed A's editor.
    nonisolated static func onUpCancelsLongPress(releasedPad: String, armedPad: String?) -> Bool {
        armedPad == releasedPad
    }
    /// The editor opens only if that same pad is STILL held when the hold fires (the timer's captured
    /// pad used to be trusted blindly, so a quick tap-and-lift still popped the modal).
    nonisolated static func longPressFires(armedPad: String?, stillHeld: Bool) -> Bool {
        armedPad != nil && stillHeld
    }
    /// A deliberate hold, comfortably above UIKit's 0.5 s default. The shipped 0.48 s was an ordinary
    /// sustained 808/sub hold and dropped a full-screen modal over the pads mid-performance.
    static let longPressDelay: TimeInterval = 0.6

    private func onHit(_ padID: String, _ vel: Double = 0.85) {
        engine.start()
        heldPads[padID, default: 0] += 1
        if bankIsEmpty && !editMode {
            // Nothing is assigned on this bank: don't fall through to Bank A's drum under a "SLICE n" label
            // (and don't record that drum into the lanes). Say what fills the bank instead; a long-press
            // still opens the editor so a one-shot can be imported right here (MAIN_SCREEN_AUDIT #2).
            fx.bump(padID)
            if toast == nil { flashToast(emptyBankHint) }
            armLongPress(padID)
            return
        }
        if project.muteMode {   // Mute mode: tap toggles the pad's mute live (no trigger)
            project.toggleRowMute(padID)   // checkpointed: undoable + dirty (mirrors the Sequence/Track mutes)
            fx.bump(padID)
            return
        }
        if project.sixteenLevels, let pad = Kit.padByID[padID] {
            let lvl = Double(pad.index + 1) / 16
            let v = 0.15 + lvl * 0.85   // normalized 0.15→1.0 ramp so the top levels don't clip (#PADS-04)
            // Route through triggerPad so padGain / choke-opts / mute-solo are honored (was a raw engine.trigger
            // that ignored all of them), and record the played level like a normal hit (#PADS-04).
            project.triggerPad(sel, vel: v)
            fx.bump(padID)
            if project.recording {
                if project.bank == "D", project.synthBank?[sel] != nil { project.recordSynthPad(sel, transport.recordFraction()) }
                else { project.recordHit(sel, transport.recordFraction(), vel: v) }
            }
            return
        }
        fx.bump(padID)
        if editMode { editMode = false; editPadID = padID; return }
        project.triggerPad(padID, accent: project.fullLevel, vel: vel)   // finger pressure → dynamics (#PADS-01)
        if project.recording {
            // quantize to the step the user actually heard (audio clock), honoring the bar length.
            // Bank-D synth pads record as melody notes (sequence/export as synth); others as drum hits.
            if project.bank == "D", project.synthBank?[padID] != nil {
                project.recordSynthPad(padID, transport.recordFraction())
            } else {
                project.recordHit(padID, transport.recordFraction(), vel: project.fullLevel ? 1.0 : vel)   // capture the played dynamics (#PADS-01)
            }
        }
        if project.noteRepeat { startRepeat(padID) }
        // Long-press opens the pad editor — but NOT while holding for a Note Repeat roll or during a take,
        // where a sustained hold is intentional and popping the full-screen editor would break the performance.
        // (The editor is still reachable via the "Edit a Pad" button and the Edit-mode toggle.)
        // The candidate is keyed to this one pad so any other pad's hit-down or release leaves it alone,
        // and the timer body re-checks that the pad is still held before opening anything.
        armLongPress(padID)
    }

    private func armLongPress(_ padID: String) {
        guard Self.shouldArmLongPress(noteRepeat: project.noteRepeat, recording: project.recording, armedPad: longPressPad) else { return }
        longPressPad = padID
        longTimer?.invalidate()
        longTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressDelay, repeats: false) { _ in
            Task { @MainActor in
                longTimer = nil
                let pending = longPressPad
                longPressPad = nil
                let stillHeld = pending.map { (heldPads[$0] ?? 0) > 0 } ?? false
                if Self.longPressFires(armedPad: pending, stillHeld: stillHeld) { editPadID = pending }
            }
        }
    }

    private func onUp(_ padID: String) {
        stopRepeat(padID)
        if let n = heldPads[padID] {
            if n <= 1 { heldPads[padID] = nil } else { heldPads[padID] = n - 1 }
        }
        // Cancel only the press THIS pad armed: another finger's release must not kill it (finding 38).
        if Self.onUpCancelsLongPress(releasedPad: padID, armedPad: longPressPad) {
            longTimer?.invalidate()
            longTimer = nil
            longPressPad = nil
        }
    }

    /// F1: push a pad's one-shot into the sampler for chopping — closes the loop the Resample toast
    /// promises ("now chop it"). Undoable: mutateSample captures the prior sampler buffer first.
    private func editInSampler(_ padID: String) {
        guard let data = project.padSampleData[padID], !data.isEmpty else { return }
        engine.start()
        let name = project.padParams[padID]?.sampleName ?? (Kit.padByID[padID]?.label ?? "Pad")
        project.mutateSample("padToSampler") {
            let r = engine.importBuffer(data)
            project.sample = SampleState(name: name, kind: "pad", dur: r.dur, wave: r.wave, transients: r.transients)
            project.sliceBank = nil
        }
        openTab("sample")
    }

    private func startRepeat(_ padID: String) {
        stopRepeat(padID)
        // The grid may run at Link's session tempo, not project.bpm — follow the transport (#transport-7).
        func interval() -> Double { (60.0 / max(40, transport.effectiveBpm)) * (DIV_BEATS[project.repeatDiv] ?? 0.25) }
        let now = engine.now()
        func barDuration() -> Double { (60.0 / max(40, transport.effectiveBpm)) * Double(project.barSteps) / 4 }
        var anchor = transport.playing ? now - transport.recordFraction() * barDuration() : now
        var anchored = transport.playing && project.step >= 0   // false during a count-in: the grid isn't known yet
        var spacing = interval()
        var next = anchor + (floor((now - anchor) / spacing) + 1) * spacing
        // The timer only fills a short lookahead window; audio onsets use the engine clock.
        let t = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            Task { @MainActor in
                guard self.project.noteRepeat, self.repeatTimers[padID] != nil else { self.stopRepeat(padID); return }
                let now = self.engine.now(), newSpacing = interval()
                if !anchored, self.transport.playing, self.project.step >= 0 {   // the grid just started — join it (round 3, transport-3)
                    anchored = true
                    anchor = now - self.transport.recordFraction() * barDuration()
                    next = anchor + (floor((now - anchor) / spacing) + 1) * spacing
                }
                if abs(newSpacing - spacing) > 0.000001 {
                    spacing = newSpacing
                    // The bar line itself moved with the tempo — re-derive the anchor from the transport, then
                    // re-quantize to it (not to "now", and not to the stale anchor captured at key-down).
                    if self.transport.playing { anchor = now - self.transport.recordFraction() * barDuration() }
                    next = anchor + (floor((now - anchor) / spacing) + 1) * spacing
                }
                if next < now { next += ceil((now - next) / spacing) * spacing }
                guard next < now + 0.025 else { return }
                let onset = next
                next += spacing
                self.project.triggerPad(padID, accent: self.project.fullLevel, when: onset)
                self.fx.bump(padID)
                if self.project.recording {
                    let fraction = self.transport.recordFraction(at: onset)
                    if self.project.bank == "D", self.project.synthBank?[padID] != nil {
                        self.project.recordSynthPad(padID, fraction)
                    } else {
                        self.project.recordHit(padID, fraction, vel: self.project.fullLevel ? 1.0 : 0.85)
                    }
                }
            }
        }
        repeatTimers[padID] = t
    }
    private func stopRepeat(_ padID: String) {
        repeatTimers[padID]?.invalidate()
        repeatTimers[padID] = nil
    }

    // MARK: controls

    private func bankButton(_ b: String) -> some View {
        let on = project.bank == b
        return Button { project.setBank(b) } label: {
            VStack(spacing: 1) {
                Text(b).font(FDFont.display(18, .bold)).foregroundStyle(on ? settings.accent : settings.ink)
                Text((Kit.banks[b]?.name ?? "").split(separator: " ").first.map(String.init)?.uppercased() ?? "")
                    .font(FDFont.mono(8, .bold)).foregroundStyle(settings.inkDim)
            }
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? settings.accent.opacity(0.18) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? settings.accent.opacity(0.45) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
            .accessibilityLabel(Text("Bank \(b) \(Kit.banks[b]?.name ?? "")"))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func kitRow(_ kit: Kit.DrumKitPreset) -> some View {
        let on = project.activeKit == kit.id
        return Button { engine.start(); project.applyDrumKit(kit.id) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kit.name).font(FDFont.ui(13, .semibold)).foregroundStyle(on ? settings.ink : settings.inkDim)
                    Text(kit.desc).font(FDFont.ui(10)).foregroundStyle(settings.inkFaint).lineLimit(1)
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(settings.accent) }
            }
            .padding(.horizontal, 10).frame(height: 42).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.14) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func userKitRow(_ uk: UserKitDef) -> some View {
        let on = project.activeKit == "user:\(uk.id)"
        return HStack(spacing: 6) {
            Button { engine.start(); project.applyUserKit(uk.id, uk.sounds) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.square").font(.system(size: 11)).foregroundStyle(settings.inkFaint)
                    Text(uk.name).font(FDFont.ui(13, .semibold)).foregroundStyle(on ? settings.ink : settings.inkDim).lineLimit(1)
                    Spacer(minLength: 4)
                    if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(settings.accent) }
                }
                .padding(.horizontal, 10).frame(height: 42).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? settings.accent.opacity(0.14) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Button { confirmDeleteKit = uk } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(settings.inkFaint)
                    .frame(width: 32, height: 42)
                    .fdCard(10, fill: settings.panel2)
            }.buttonStyle(.plain)
        }
    }

    private func perfButton(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        // Strip leading decorative glyphs (⟳ ✎ 📖 → and arrows) so VoiceOver reads the words, not the symbol.
        let spoken = label.trimmingCharacters(in: CharacterSet(charactersIn: "⟳✎📖→⟶➜✂︎… ")).trimmingCharacters(in: .whitespaces)
        return Button(action: action) {
            Text(label).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? settings.accent.opacity(0.2) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(spoken.isEmpty ? label : spoken))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func divButton(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.mono(12, .bold)).foregroundStyle(on ? .white : settings.inkDim)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? .clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(on ? "On" : "Off"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
