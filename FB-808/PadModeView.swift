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

    @State private var repeatTimers: [String: Timer] = [:]
    @State private var longTimer: Timer?
    @State private var editMode = false
    @State private var editPadID: String?
    @State private var showSaveKit = false
    @State private var newKitName = ""
    @State private var toast: String?
    @State private var showMPCBridge = false

    private var sel: String { project.selectedRow }

    private func flashToast(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { if toast == msg { toast = nil } }
    }

    var body: some View {
        VStack(spacing: 16) {
            TransportBar()
            HStack(spacing: 22) {
                stage
                side.frame(width: 268)
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
        .onDisappear {
            repeatTimers.values.forEach { $0.invalidate() }
            repeatTimers.removeAll()
            longTimer?.invalidate()
        }
        .alert("Save Kit", isPresented: $showSaveKit) {
            TextField("Kit name", text: $newKitName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let id = settings.addUserKit(name: newKitName, sounds: project.currentPadSounds())
                project.activeKit = "user:\(id)"
            }
        } message: { Text("Saves the current pad sounds as a reusable kit.") }
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
    private var badges: [String: String]? {
        guard project.sixteenLevels else { return nil }
        var b: [String: String] = [:]
        for p in Kit.pads { b[p.id] = String(p.index + 1) }
        return b
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModeHead(title: "Pads",
                     eyebrow: "Bank \(project.bank) · \(Kit.banks[project.bank]?.name ?? "")",
                     hint: editMode ? "✎ Tap a pad to open its editor" : (project.recording ? "● Recording into pattern" : "Tap to play · long-press to edit"))
                .padding(.bottom, 12)
            PadGridView(pads: bankPads,
                        showLabels: settings.padLabels && !project.sixteenLevels,
                        badges: badges,
                        mutedIDs: project.muteMode ? Set(project.rowMute.filter { $0.value }.keys) : [],
                        onHit: onHit, onUp: onUp)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: side panel

    private var side: some View {
        ScrollView {
            VStack(spacing: 14) {
                PanelCard(title: "Pad Banks") {
                    HStack(spacing: 8) {
                        ForEach(Kit.bankOrder, id: \.self) { b in
                            bankButton(b)
                        }
                    }
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
                        perfButton("Full Level", on: project.fullLevel) { project.fullLevel.toggle() }
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
                        perfButton("Unmute All", on: false) { for k in project.rowMute.keys { project.rowMute[k] = false } }
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
                        project.resampleToPad(sel)
                        progress.awardCreative("resample", 6)
                        flashToast("Resampled your beat onto \(Kit.padByID[sel]?.label ?? sel) — now chop or play it")
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
        }
        .scrollIndicators(.hidden)
    }

    // MARK: interactions

    private func onHit(_ padID: String) {
        engine.start()
        if project.muteMode {   // Mute mode: tap toggles the pad's mute live (no trigger)
            project.rowMute[padID] = !(project.rowMute[padID] ?? false)
            fx.bump(padID)
            return
        }
        if project.sixteenLevels, let pad = Kit.padByID[padID] {
            let lvl = Double(pad.index + 1) / 16
            engine.trigger(sel, vel: 0.15 + lvl * 1.05)
            fx.bump(padID)
            return
        }
        fx.bump(padID)
        if editMode { editMode = false; editPadID = padID; return }
        project.triggerPad(padID, accent: project.fullLevel)
        if project.recording {
            // quantize to the step the user actually heard (audio clock), honoring the bar length.
            // Bank-D synth pads record as melody notes (sequence/export as synth); others as drum hits.
            if project.bank == "D", project.synthBank?[padID] != nil {
                project.recordSynthPad(padID, transport.recordFraction())
            } else {
                project.recordHit(padID, transport.recordFraction(), vel: project.fullLevel ? 1.0 : 0.85)
            }
        }
        if project.noteRepeat { startRepeat(padID) }
        // Long-press opens the pad editor — but NOT while holding for a Note Repeat roll or during a take,
        // where a sustained hold is intentional and popping the full-screen editor would break the performance.
        // (The editor is still reachable via the "Edit a Pad" button and the Edit-mode toggle.)
        longTimer?.invalidate()
        if !project.noteRepeat && !project.recording {
            longTimer = Timer.scheduledTimer(withTimeInterval: 0.48, repeats: false) { _ in
                Task { @MainActor in editPadID = padID }
            }
        }
    }

    private func onUp(_ padID: String) { stopRepeat(padID); longTimer?.invalidate() }

    private func startRepeat(_ padID: String) {
        stopRepeat(padID)
        let beats = DIV_BEATS[project.repeatDiv] ?? 0.25
        let interval = (60.0 / Double(project.bpm)) * beats
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                self.project.triggerPad(padID, accent: self.project.fullLevel)
                self.fx.bump(padID)
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
            Button { if on { project.activeKit = "" }; settings.deleteUserKit(uk.id) } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(settings.inkFaint)
                    .frame(width: 32, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
        }
    }

    private func perfButton(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? settings.accent.opacity(0.2) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func divButton(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.mono(12, .bold)).foregroundStyle(on ? .white : settings.inkDim)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? .clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
