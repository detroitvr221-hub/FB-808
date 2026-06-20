//  MPCBridge.swift — the "seamless transition" teaching layer. A reference sheet that
//  maps every FD-808 pad-side control/gesture to its equivalent on the Akai MPC Sample,
//  so a learner who masters FD-808 already knows where everything lives on the hardware.

import SwiftUI

struct MPCBridgeRow { let fd: String; let mpc: String }
struct MPCBridgeSection { let title: String; let icon: String; let rows: [MPCBridgeRow] }

enum MPCBridge {
    static let sections: [MPCBridgeSection] = [
        .init(title: "Playing the Pads", icon: "square.grid.2x2.fill", rows: [
            .init(fd: "Tap a pad", mpc: "Strike a pad (Sample Mode)"),
            .init(fd: "Long-press / ✎ Edit a Pad", mpc: "SHIFT + SAMPLE → select & view a pad"),
            .init(fd: "Pad Play card", mpc: "The PAD PLAY button row"),
            .init(fd: "Full Level", mpc: "SHIFT + PAD 1 (FULL LEVEL)"),
            .init(fd: "Mute mode", mpc: "MUTE button"),
            .init(fd: "16 Levels (Velocity/Pitch/Pan/Filter)", mpc: "16 LEVELS + TYPE (Velocity/Filter/Tune)"),
            .init(fd: "Note Repeat + Rate", mpc: "NOTE REPEAT (hold) · SHIFT = triplets"),
            .init(fd: "⟳ Resample → pad", mpc: "SHIFT + PAD 11 (RESAMPLE)"),
        ]),
        .init(title: "Pad Editor", icon: "slider.horizontal.3", rows: [
            .init(fd: "One-Shot / Gate / Hold", mpc: "One Shot · Note On (SHIFT+CHOP) · Loop (LOOP)"),
            .init(fd: "Polyphony: Poly / Mono", mpc: "Play ▸ Polyphony"),
            .init(fd: "Choke Group", mpc: "Play ▸ Mute Group"),
            .init(fd: "Offset (lay-back)", mpc: "Play ▸ Offset"),
            .init(fd: "Vel Sens", mpc: "Amp Env ▸ Vel Sens"),
            .init(fd: "Tune", mpc: "Tune ▸ Semi / Fine Tune"),
            .init(fd: "Volume · Pan", mpc: "Mix ▸ Volume · Pan"),
            .init(fd: "Cutoff · Reso", mpc: "Filter ▸ Cutoff · Reso"),
            .init(fd: "Attack/Decay/Sustain/Release", mpc: "Amp Env ▸ A/D/R"),
            .init(fd: "Layers", mpc: "Play ▸ Pad Link"),
        ]),
        .init(title: "Sampling & Chopping", icon: "waveform", rows: [
            .init(fd: "⟂ Threshold Chop + Threshold slider", mpc: "CHOP ▸ Threshold (SHIFT+K3)"),
            .init(fd: "Regions 4 / 8 / 16 / 32", mpc: "CHOP ▸ Regions 4 / 8 / 16"),
            .init(fd: "Split · Merge · Extract", mpc: "SHIFT + B2 · B3 · B1 (in Chop)"),
            .init(fd: "Reverse", mpc: "SHIFT + LOOP (Reverse)"),
            .init(fd: "Loop", mpc: "LOOP button"),
            .init(fd: "Time Stretch / Pitch", mpc: "WARP (SHIFT + PAD 15)"),
            .init(fd: "→ Assign to Pads (Bank C)", mpc: "Slices map onto the pads"),
            .init(fd: "Record Mic", mpc: "SAMPLE RECORD"),
        ]),
        .init(title: "Sequencing & Song", icon: "music.note.list", rows: [
            .init(fd: "Quantize", mpc: "Time Correct ▸ Q"),
            .init(fd: "Swing", mpc: "Time Correct ▸ Swing"),
            .init(fd: "Humanize", mpc: "Time Correct ▸ Shift (feel)"),
            .init(fd: "✨ Generate Beat", mpc: "— (FD-808 extra)"),
            .init(fd: "◓ Euclid fill", mpc: "— (FD-808 extra)"),
            .init(fd: "Tracks ▸ Build Song / Song Mode", mpc: "SHIFT + PAD 12 (SONG)"),
            .init(fd: "Count-In", mpc: "SHIFT + PAD 4 (COUNT-IN)"),
            .init(fd: "TAP", mpc: "TAP TEMPO"),
        ]),
        .init(title: "Perform", icon: "dial.medium.fill", rows: [
            .init(fd: "Flex Beat (Gate/Stutter/Reverse)", mpc: "FLEX BEAT (SHIFT + PAD FX)"),
            .init(fd: "Knob FX (Reverb/Delay/Filter)", mpc: "KNOB FX"),
            .init(fd: "Performance Filter", mpc: "Knob FX ▸ LP Filter"),
            .init(fd: "Launch Pattern", mpc: "Sequence select"),
            .init(fd: "Pad Banks A–D", mpc: "Pad Banks (MPC: A–H)"),
        ]),
    ]

    // Why FD-808's 4 banks differ from the MPC's 8 — shown at the foot of the sheet.
    static let bankNote = "FD-808 has four role-banks — A Studio Kit · B Perc Lab · C Chops · D Custom — instead of the MPC's eight identical sample banks. Same idea (switch pad layouts), organized by purpose."
}

struct MPCBridgeView: View {
    @EnvironmentObject var settings: AppSettings
    let onClose: () -> Void

    var body: some View {
        let s = settings
        ZStack {
            s.theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FD-808 → MPC Sample").font(FDFont.display(22, .bold)).foregroundStyle(s.ink)
                        Text("Where every control lives on the hardware").font(FDFont.ui(12.5)).foregroundStyle(s.inkFaint)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 26)).foregroundStyle(s.inkDim)
                    }.buttonStyle(.plain)
                }
                .padding(20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 0) {
                            Text("ON FD-808").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(s.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("ON YOUR MPC").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(s.inkFaint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(MPCBridge.sections, id: \.title) { sec in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: sec.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(s.accent)
                                    Text(sec.title).font(FDFont.display(15, .bold)).foregroundStyle(s.ink)
                                }
                                VStack(spacing: 0) {
                                    ForEach(Array(sec.rows.enumerated()), id: \.offset) { (i, r) in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(r.fd).font(FDFont.ui(12.5, .semibold)).foregroundStyle(s.ink)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(r.mpc).font(FDFont.ui(12.5)).foregroundStyle(s.inkDim)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 7).padding(.horizontal, 12)
                                        .background(i % 2 == 0 ? s.panel2.opacity(0.5) : Color.clear)
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12).fill(s.panel))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(s.line, lineWidth: 1))
                            }
                        }
                        Text(MPCBridge.bankNote).font(FDFont.ui(11.5)).foregroundStyle(s.inkFaint)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 28)
                }
            }
        }
    }
}
