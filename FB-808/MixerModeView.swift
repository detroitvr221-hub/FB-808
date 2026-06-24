//  MixerModeView.swift — channel strips, faders, pan, live meters, mute/solo,
//  master. Ported from mode-mixer.jsx.

import SwiftUI
import FD808Engine
import Combine

private let FX_BY_CH: [String: [String]] = [
    "drums": ["EQ", "COMP", "+ FX"],
    "hats": ["EQ", "+ FX", ""],
    "perc": ["REVERB", "+ FX", ""],
    "bass": ["SAT", "EQ", "+ FX"],
    "fx": ["DELAY", "+ FX", ""],
    "melody": ["SYNTH", "REVERB", "+ FX"],
    "master": ["EQ", "COMP", "LIMITER"],
]

private func dbStr(_ v: Double) -> String {
    if v <= 0.001 { return "-∞" }
    let db = 20 * log10(v / 0.82)
    return (db >= 0 ? "+" : "") + String(format: "%.1f", db)
}

// MARK: - Insertable FX catalog (add / remove)

// One catalog entry per insertable per-channel effect. The engine runs all inserts in a FIXED
// order and bypasses any whose `*On` flag is false, so "add" = set the flag (+ default params) and
// "remove" = clear the flag and reset that effect's params (so re-adding starts clean). One instance
// of each effect per channel; processing order is fixed. `id` matches the editor `kind` strings.
struct MixerFXModule: Identifiable {
    let id: String
    let label: String        // full name (Add menu + editor title)
    let short: String        // strip chip label
    let isAdded: (ChannelFX) -> Bool
    let add: (inout ChannelFX) -> Void
    let remove: (inout ChannelFX) -> Void
}

let MIXER_FX_MODULES: [MixerFXModule] = [
    MixerFXModule(id: "eq", label: "EQ", short: "EQ",
                  isAdded: { $0.eqOn || $0.excOn }, add: { $0.eqOn = true },
                  remove: { $0.eqOn = false; $0.low = 0; $0.mid = 0; $0.high = 0; $0.excOn = false; $0.excAmount = 0 }),
    MixerFXModule(id: "comp", label: "Compressor", short: "CMP",
                  isAdded: { $0.compOn }, add: { $0.compOn = true },
                  remove: { $0.compOn = false; $0.compThresh = -18; $0.compRatio = 3; $0.compMakeup = 0 }),
    MixerFXModule(id: "drive", label: "Drive / Fold", short: "DRV",
                  isAdded: { $0.driveOn }, add: { $0.driveOn = true },
                  remove: { $0.driveOn = false; $0.drive = 0.3; $0.driveType = 0 }),
    MixerFXModule(id: "bit", label: "Bitcrusher", short: "BIT",
                  isAdded: { $0.crushOn }, add: { $0.crushOn = true },
                  remove: { $0.crushOn = false; $0.crushBits = 8; $0.crushDown = 1 }),
    MixerFXModule(id: "fuzz", label: "Fuzz", short: "FUZZ",
                  isAdded: { $0.fuzzOn }, add: { $0.fuzzOn = true },
                  remove: { $0.fuzzOn = false; $0.fuzzGain = 0.5; $0.fuzzTone = 0.7; $0.fuzzLevel = 0.6 }),
    MixerFXModule(id: "ring", label: "Ring Mod", short: "RING",
                  isAdded: { $0.ringOn }, add: { $0.ringOn = true },
                  remove: { $0.ringOn = false; $0.ringFreq = 220; $0.ringMix = 0.5 }),
    MixerFXModule(id: "mod", label: "Modulation", short: "MOD",
                  isAdded: { $0.modOn || $0.width != 1 || $0.apOn }, add: { $0.modOn = true },
                  remove: { $0.modOn = false; $0.apOn = false; $0.width = 1; $0.modType = 0
                            $0.modRate = 0.6; $0.modDepth = 0.5; $0.modFb = 0.3; $0.modMix = 0.5
                            $0.apMode = 0; $0.apRate = 4; $0.apDepth = 0.5 }),
    MixerFXModule(id: "trans", label: "Transient", short: "TRANS",
                  isAdded: { $0.transOn }, add: { $0.transOn = true },
                  remove: { $0.transOn = false; $0.transAttack = 0; $0.transSustain = 0 }),
    MixerFXModule(id: "tape", label: "Tape / Lo-Fi", short: "TAPE",
                  isAdded: { $0.tapeOn }, add: { $0.tapeOn = true },
                  remove: { $0.tapeOn = false; $0.tapeWow = 0.3; $0.tapeFlutter = 0.2; $0.tapeSat = 0.4; $0.tapeNoise = 0.15 }),
]

func mixerFXModule(_ id: String) -> MixerFXModule { MIXER_FX_MODULES.first { $0.id == id } ?? MIXER_FX_MODULES[0] }

// Shared slider used by both the Buses and Tracks FX editors.
private func mixerFXSlider(_ label: String, _ value: Binding<Double>, _ lo: Double, _ hi: Double, _ s: AppSettings, _ fmt: @escaping (Double) -> String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        HStack {
            Text(label).font(FDFont.ui(12.5, .medium)).foregroundStyle(s.inkDim)
            Spacer()
            Text(fmt(value.wrappedValue)).font(FDFont.mono(11, .bold)).foregroundStyle(s.ink)
        }
        Slider(value: value, in: lo...hi).tint(s.accent)
    }
}

private func mixerFXSegment(_ options: [String], selected: Int, _ s: AppSettings, _ pick: @escaping (Int) -> Void) -> some View {
    HStack(spacing: 6) {
        ForEach(Array(options.enumerated()), id: \.offset) { (i, nm) in
            Button { pick(i) } label: {
                Text(nm).font(FDFont.ui(11.5, .semibold)).foregroundStyle(selected == i ? .white : s.inkDim)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected == i ? s.accent : s.panel2))
            }.buttonStyle(.plain)
        }
    }
}

// The per-effect control rows, shared by both FX editors. Binding factories let each caller bind to
// its own channel id (a bus id, or a track id).
@ViewBuilder
private func mixerFXControls(_ kind: String, cfx: ChannelFX, _ s: AppSettings,
                             dbl: @escaping (WritableKeyPath<ChannelFX, Double>) -> Binding<Double>,
                             bln: @escaping (WritableKeyPath<ChannelFX, Bool>) -> Binding<Bool>,
                             setInt: @escaping (WritableKeyPath<ChannelFX, Int>, Int) -> Void) -> some View {
    switch kind {
    case "eq":
        mixerFXSlider("Low", dbl(\.low), -12, 12, s) { "\(Int($0)) dB" }
        mixerFXSlider("Mid", dbl(\.mid), -12, 12, s) { "\(Int($0)) dB" }
        mixerFXSlider("High", dbl(\.high), -12, 12, s) { "\(Int($0)) dB" }
        Rectangle().fill(s.line).frame(height: 1).padding(.vertical, 2)
        Toggle("Exciter", isOn: bln(\.excOn)).font(FDFont.ui(12.5, .semibold)).tint(s.accent)
        if cfx.excOn {
            mixerFXSlider("Amount", dbl(\.excAmount), 0, 1, s) { "\(Int($0 * 100))%" }
            mixerFXSlider("Frequency", dbl(\.excFreq), 1000, 9000, s) { "\(Int($0)) Hz" }
        }
        Text("Exciter adds saturated high-harmonic sparkle above the crossover.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    case "comp":
        mixerFXSlider("Threshold", dbl(\.compThresh), -40, 0, s) { "\(Int($0)) dB" }
        mixerFXSlider("Ratio", dbl(\.compRatio), 1, 10, s) { String(format: "%.1f:1", $0) }
        mixerFXSlider("Makeup", dbl(\.compMakeup), 0, 12, s) { "+\(Int($0)) dB" }
    case "bit":
        mixerFXSlider("Bit Depth", dbl(\.crushBits), 1, 16, s) { String(format: "%.0f bit", $0) }
        mixerFXSlider("Downsample", dbl(\.crushDown), 1, 40, s) { $0 < 1.5 ? "off" : "÷\(Int($0.rounded()))" }
        Text("Lo-fi grit — fewer bits and a held sample rate.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    case "fuzz":
        mixerFXSlider("Gain", dbl(\.fuzzGain), 0, 1, s) { "\(Int($0 * 100))%" }
        mixerFXSlider("Tone", dbl(\.fuzzTone), 0, 1, s) { "\(Int($0 * 100))%" }
        mixerFXSlider("Level", dbl(\.fuzzLevel), 0, 1, s) { "\(Int($0 * 100))%" }
        Text("Square-y exponential clip — harder than Drive.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    case "ring":
        mixerFXSlider("Frequency", dbl(\.ringFreq), 20, 2000, s) { "\(Int($0)) Hz" }
        mixerFXSlider("Mix", dbl(\.ringMix), 0, 1, s) { "\(Int($0 * 100))%" }
        Text("Metallic, clangy carrier — great on hats & stabs.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    case "mod":
        mixerFXSegment(["Chorus", "Flanger", "Phaser"], selected: cfx.modType, s) { setInt(\.modType, $0) }
        mixerFXSlider("Rate", dbl(\.modRate), 0.05, 8, s) { String(format: "%.2f Hz", $0) }
        mixerFXSlider("Depth", dbl(\.modDepth), 0, 1, s) { "\(Int($0 * 100))%" }
        if cfx.modType != 0 { mixerFXSlider("Feedback", dbl(\.modFb), 0, 1, s) { "\(Int($0 * 100))%" } }
        mixerFXSlider("Mix", dbl(\.modMix), 0, 1, s) { "\(Int($0 * 100))%" }
        Rectangle().fill(s.line).frame(height: 1).padding(.vertical, 2)
        mixerFXSlider("Stereo Width", dbl(\.width), 0, 2, s) { $0 < 0.05 ? "Mono" : "\(Int($0 * 100))%" }
        Rectangle().fill(s.line).frame(height: 1).padding(.vertical, 2)
        Toggle("Auto-Pan / Tremolo", isOn: bln(\.apOn)).font(FDFont.ui(12.5, .semibold)).tint(s.accent)
        if cfx.apOn {
            mixerFXSegment(["Tremolo", "Auto-Pan"], selected: cfx.apMode, s) { setInt(\.apMode, $0) }
            mixerFXSlider("Rate", dbl(\.apRate), 0.05, 12, s) { String(format: "%.2f Hz", $0) }
            mixerFXSlider("Depth", dbl(\.apDepth), 0, 1, s) { "\(Int($0 * 100))%" }
        }
    case "trans":
        mixerFXSlider("Attack", dbl(\.transAttack), -1, 1, s) { String(format: "%+.0f%%", $0 * 100) }
        mixerFXSlider("Sustain", dbl(\.transSustain), -1, 1, s) { String(format: "%+.0f%%", $0 * 100) }
        Text("Punch up or soften the hit vs the body — drum shaping a compressor can't do.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    case "tape":
        mixerFXSlider("Wow", dbl(\.tapeWow), 0, 1, s) { "\(Int($0 * 100))%" }
        mixerFXSlider("Flutter", dbl(\.tapeFlutter), 0, 1, s) { "\(Int($0 * 100))%" }
        mixerFXSlider("Saturation", dbl(\.tapeSat), 0, 1, s) { "\(Int($0 * 100))%" }
        mixerFXSlider("Hiss / Crackle", dbl(\.tapeNoise), 0, 1, s) { "\(Int($0 * 100))%" }
        Text("Wow+flutter wobble, tape warmth and vinyl noise — instant lo-fi.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    default:   // "drive"
        mixerFXSegment(["Soft", "Fold"], selected: cfx.driveType, s) { setInt(\.driveType, $0) }
        mixerFXSlider("Amount", dbl(\.drive), 0, 1, s) { "\(Int($0 * 100))%" }
        Text(cfx.driveType == 1 ? "Wavefolder — reflects peaks back for metallic, west-coast harmonics."
                                : "Soft-clip tanh saturation.")
            .font(FDFont.ui(11)).foregroundStyle(s.inkFaint).fixedSize(horizontal: false, vertical: true)
    }
}

struct MixerModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings

    @State private var meters: [String: Double] = [:]
    @State private var mixTab = 0   // 0 = Buses · 1 = Tracks (per-arrangement-track strips)
    // A single stable publisher (creating it inline in .onReceive would re-subscribe every render).
    @State private var meterTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            TransportBar()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    ModeHead(title: "Mixer", eyebrow: mixTab == 0 ? "\(Kit.channels.count + 1) Channels + Master" : "\(project.tracks.count) Tracks",
                             hint: "Drag faders & pan · M/S to mute or solo")
                    mixTabPicker
                }
                .padding(.bottom, 12)
                Group {
                    if mixTab == 0 {
                        HStack(spacing: 12) {
                            ForEach(Kit.channels) { c in
                                MixStrip(ch: c.id, name: c.name, color: c.color, meter: meters[c.id] ?? 0, master: false)
                            }
                            MixStrip(ch: "melody", name: FDPalette.melodyName, color: FDPalette.melody, meter: meters["melody"] ?? 0, master: false)
                            MixStrip(ch: "master", name: "MASTER", color: settings.accent, meter: meters["master"] ?? 0, master: true)
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(project.tracks) { t in
                                    TrackStrip(track: t, meter: meters[t.id == "vox" ? "melody" : t.id] ?? 0)
                                }
                                MixStrip(ch: "master", name: "MASTER", color: settings.accent, meter: meters["master"] ?? 0, master: true)
                                    .frame(width: 96)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                MasterFXBar().padding(.top, 12)
            }
        }
        .onReceive(meterTimer) { _ in
            guard !meters.isEmpty else { return }   // parks the 60 fps loop once everything has decayed
            var m = meters
            for k in Array(m.keys) {
                let nv = (m[k] ?? 0) - 0.05
                if nv <= 0.001 { m[k] = nil } else { m[k] = nv }   // remove dead meters so `meters` empties out
            }
            meters = m
        }
        .onChange(of: project.step) { _, s in bump(s) }
    }

    private var mixTabPicker: some View {
        HStack(spacing: 6) {
            ForEach(Array(["Buses", "Tracks"].enumerated()), id: \.offset) { (i, label) in
                Button { mixTab = i } label: {
                    Text(label).font(FDFont.ui(13, .semibold))
                        .foregroundStyle(mixTab == i ? settings.ink : settings.inkDim)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: FDRadius.md).fill(mixTab == i ? settings.accent.opacity(0.2) : settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: FDRadius.md).stroke(mixTab == i ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    private func bump(_ s: Int) {
        guard project.playing, s >= 0 else { return }
        var m = meters
        let solo = project.mixer.values.contains { $0.solo }
        var mx = 0.0
        for c in Kit.channels {
            var lvl = 0.0
            for pid in c.pads {
                let v = (project.lanes[pid]?[safe: s]) ?? 0
                if v > lvl { lvl = v }
            }
            let mm = project.mixer[c.id] ?? MixChannel()
            if mm.mute || (solo && !mm.solo) { lvl = 0 }
            if lvl > 0 {
                let val = min(1, lvl * mm.vol * 1.35)
                m[c.id] = val
                if val > mx { mx = val }
            }
        }
        // melody meter
        if !project.melodyMuted {
            var ml = 0.0
            for note in project.melody where note.step == s { ml = max(ml, note.vel) }
            let mm = project.mixer["melody"] ?? MixChannel()
            if mm.mute || (solo && !mm.solo) { ml = 0 }
            if ml > 0 {
                let val = min(1, ml * mm.vol * 1.3)
                m["melody"] = val
                if val > mx { mx = val }
            }
        }
        if mx > 0 { m["master"] = min(1, mx * (project.mixer["master"]?.vol ?? 0.9) * 1.1) }
        meters = m
    }
}

struct MixStrip: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: AudioEngine
    let ch: String
    let name: String
    let color: Color
    let meter: Double
    let master: Bool

    @State private var faderStart: Double?
    @State private var panStart: Double?
    @State private var fxEdit: String?
    @State private var showAU = false

    private var m: MixChannel { project.mixer[ch] ?? MixChannel() }
    private var cfx: ChannelFX { project.channelFX[ch] ?? ChannelFX() }

    var body: some View {
        let th = settings.theme
        let vol = m.vol
        let hot = meter > 0.97
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                if !master { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9) }
                Text(name).font(FDFont.display(14, .bold)).foregroundStyle(th.ink)
            }
            // fx slots — interactive per-channel inserts (master keeps static labels)
            fxSlots(th)
            // pan knob — panning the master sum is meaningless, so hide it there (matching the solo/swatch guards)
            if !master {
                knob
                Text("PAN \(panLabel)").font(FDFont.mono(8.5, .bold)).tracking(0.6).foregroundStyle(th.inkFaint)
            }
            // meter + fader
            HStack(spacing: 10) {
                meterBar
                fader(vol: vol)
            }
            .frame(maxHeight: .infinity)
            // db
            HStack(spacing: 5) {
                Circle().fill(hot ? th.miss : settings.line).frame(width: 7, height: 7)
                    .shadow(color: hot ? th.miss : .clear, radius: 4)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Clip indicator"))
                    .accessibilityValue(Text(hot ? "Clipping" : "OK"))
                // non-color cue — show "CLIP" text whenever the meter is hot
                if hot {
                    Text("CLIP").font(FDFont.mono(8, .bold)).tracking(0.5).foregroundStyle(th.miss)
                        .accessibilityHidden(true)
                }
                Text("\(dbStr(vol)) dB").font(FDFont.mono(10, .bold)).foregroundStyle(th.inkDim)
            }
            // m/s
            HStack(spacing: 6) {
                msButton("M", on: m.mute, color: th.miss) { project.setMix(ch) { $0.mute.toggle() } }
                if !master { msButton("S", on: m.solo, color: th.good) { project.setMix(ch) { $0.solo.toggle() } } }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(master ? settings.panel.blend(settings.accent, 0.06) : settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(master ? settings.accent.opacity(0.3) : settings.line, lineWidth: 1))
        .sheet(isPresented: $showAU) {
            AUPluginsSheet().environmentObject(engine).environmentObject(settings)
        }
    }

    private var panLabel: String {
        if m.pan == 0 { return "C" }
        return (m.pan > 0 ? "R" : "L") + "\(Int(abs(m.pan) * 100))"
    }

    // MARK: per-channel insert FX (EQ / comp / drive)

    @ViewBuilder private func fxSlots(_ th: Theme) -> some View {
        if FX_CHANNELS.contains(ch) {
            VStack(spacing: 5) {
                // Only the ADDED inserts show as chips; "+ FX" adds more from a menu (#mixer-fx).
                ForEach(MIXER_FX_MODULES.filter { $0.isAdded(cfx) }) { mod in
                    fxChip(mod.short, on: true) { fxEdit = mod.id }
                }
                if MIXER_FX_MODULES.contains(where: { !$0.isAdded(cfx) }) { addFXChip }
                fxChip("SND", on: cfx.send > 0 || cfx.scAmount > 0) { fxEdit = "send" }   // send is always available
            }
            .popover(isPresented: Binding(get: { fxEdit != nil }, set: { if !$0 { fxEdit = nil } })) {
                fxEditor(fxEdit ?? "eq")
            }
        } else {
            VStack(spacing: 5) {
                if master {
                    fxChip("AU FX", on: !engine.masterAUs.isEmpty) { showAU = true }
                }
                // Non-interactive indicators (no chip background) so they don't read as tappable buttons.
                ForEach(Array((FX_BY_CH[ch] ?? []).filter { !$0.isEmpty && $0 != "+ FX" }.enumerated()), id: \.offset) { (_, fx) in
                    Text(fx).font(FDFont.mono(9, .bold)).tracking(0.5).foregroundStyle(th.inkFaint.opacity(0.6))
                        .frame(maxWidth: .infinity).frame(height: 18)
                        .accessibilityLabel(Text("\(fx) (indicator)"))
                }
            }
        }
    }

    private func fxChip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.mono(9.5, .bold)).foregroundStyle(on ? settings.ink : settings.inkFaint)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? settings.accent.opacity(0.18) : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? settings.accent.opacity(0.55) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // "+ FX" — add an insert from the not-yet-added list, then open its editor.
    private var addFXChip: some View {
        Menu {
            ForEach(MIXER_FX_MODULES.filter { !$0.isAdded(cfx) }) { mod in
                Button(mod.label) { project.setChannelFX(ch) { mod.add(&$0) }; fxEdit = mod.id }
            }
        } label: {
            Text("+ FX").font(FDFont.mono(9.5, .bold)).foregroundStyle(settings.accent)
                .frame(maxWidth: .infinity).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(settings.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
        }
        .accessibilityLabel(Text("Add an effect to \(name) bus"))
    }

    @ViewBuilder private func fxEditor(_ kind: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(fxTitle(kind)).font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
                Spacer()
                if kind != "send" {   // send is permanent routing, not an addable insert
                    Button(role: .destructive) {
                        project.setChannelFX(ch) { mixerFXModule(kind).remove(&$0) }
                        fxEdit = nil
                    } label: {
                        Label("Remove", systemImage: "trash").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.theme.miss)
                    }.buttonStyle(.plain).accessibilityLabel(Text("Remove \(fxTitle(kind))"))
                }
            }
            Text("\(name) bus").font(FDFont.mono(9.5, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
            if kind == "send" {
                fxSlider("FX Send", bind(\.send), 0, 1) { "\(Int($0 * 100))%" }
                Text("Feeds the shared master reverb + delay together (one send drives both).")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                fxSlider("Sidechain", bind(\.scAmount), 0, 1) { "\(Int($0 * 100))%" }
                Text("Ducks this bus when the kick hits — the classic pump.")
                    .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
            } else {
                mixerFXControls(kind, cfx: cfx, settings, dbl: bind, bln: bbind,
                                setInt: { kp, v in project.setChannelFX(ch) { $0[keyPath: kp] = v } })
            }
        }
        .padding(16).frame(width: 260)
        .background(settings.panel)
        .presentationCompactAdaptation(.popover)
    }

    private func fxTitle(_ k: String) -> String {
        k == "send" ? "Send / Duck" : mixerFXModule(k).label
    }

    private func fxSlider(_ label: String, _ value: Binding<Double>, _ lo: Double, _ hi: Double, _ fmt: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(FDFont.ui(12.5, .medium)).foregroundStyle(settings.inkDim)
                Spacer()
                Text(fmt(value.wrappedValue)).font(FDFont.mono(11, .bold)).foregroundStyle(settings.ink)
            }
            Slider(value: value, in: lo...hi).tint(settings.accent)
        }
    }

    private func bind(_ kp: WritableKeyPath<ChannelFX, Double>) -> Binding<Double> {
        Binding(get: { cfx[keyPath: kp] }, set: { v in project.setChannelFX(ch) { $0[keyPath: kp] = v } })
    }
    private func bbind(_ kp: WritableKeyPath<ChannelFX, Bool>) -> Binding<Bool> {
        Binding(get: { cfx[keyPath: kp] }, set: { v in project.setChannelFX(ch) { $0[keyPath: kp] = v } })
    }

    private var knob: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [settings.panel2, settings.panel2.darker(0.3)], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 30))
                .overlay(Circle().stroke(settings.line, lineWidth: 1))
                .frame(width: 46, height: 46)
            Capsule().fill(settings.accent).frame(width: 2.5, height: 13)
                .offset(y: -11)
                .rotationEffect(.degrees(m.pan * 135))
        }
        .frame(width: 46, height: 46)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if panStart == nil { panStart = m.pan; project.checkpoint("mix:\(ch)", coalesce: false) }
                project.setMix(ch) { $0.pan = max(-1, min(1, (panStart ?? 0) + v.translation.width / 80)) }
            }
            .onEnded { _ in panStart = nil })
        .onTapGesture(count: 2) { project.setMix(ch) { $0.pan = 0 } }   // double-tap recenters pan
        .accessibilityElement()
        .accessibilityLabel(Text("\(name) pan"))
        .accessibilityValue(Text(panLabel))
        .accessibilityHint(Text("Double tap to center"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: project.setMix(ch) { $0.pan = max(-1, min(1, $0.pan + 0.1)) }
            case .decrement: project.setMix(ch) { $0.pan = max(-1, min(1, $0.pan - 0.1)) }
            default: break
            }
        }
    }

    private var meterBar: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6).fill(settings.panel2.darker(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.line2, lineWidth: 1))
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [settings.theme.meterLow, settings.theme.perfect, settings.theme.miss], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height * min(1, meter))
            }
        }
        .frame(width: 12)
    }

    private func fader(vol: Double) -> some View {
        GeometryReader { g in
            let H = g.size.height
            let frac = vol / 1.1
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(settings.panel2.darker(0.22)).frame(width: 6)
                RoundedRectangle(cornerRadius: 4).fill(settings.accent.opacity(0.45)).frame(width: 6, height: H * frac)
                // cap
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [settings.theme.capA, settings.theme.capB], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.5), lineWidth: 1))
                    Capsule().fill(settings.accent).frame(width: 26, height: 2)
                }
                .frame(width: 38, height: 22)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                .offset(y: -H * frac + 11)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if faderStart == nil { faderStart = m.vol; project.checkpoint("mix:\(ch)", coalesce: false) }
                        project.setMix(ch) { $0.vol = max(0, min(1.1, (faderStart ?? 0) - v.translation.height / H)) }
                    }
                    .onEnded { _ in faderStart = nil })
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { project.setMix(ch) { $0.vol = 0.82 } }   // double-tap returns the fader to 0 dB (unity)
        }
        .frame(width: 46)
        .accessibilityElement()
        .accessibilityLabel(Text("\(name) volume"))
        .accessibilityValue(Text("\(dbStr(vol)) dB"))
        .accessibilityHint(Text("Double tap to reset to 0 dB"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: project.setMix(ch) { $0.vol = max(0, min(1.1, $0.vol + 0.05)) }
            case .decrement: project.setMix(ch) { $0.vol = max(0, min(1.1, $0.vol - 0.05)) }
            default: break
            }
        }
    }

    private func msButton(_ s: String, on: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(11, .bold))
                .foregroundStyle(on ? (s == "S" ? Color(hex: "#08240f") : .white) : settings.inkFaint)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : settings.line, lineWidth: 1))
                // non-color cue so the active state reads without relying on the fill color
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: s == "M" ? "speaker.slash.fill" : "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(s == "S" ? Color(hex: "#08240f") : .white)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                }
        }.buttonStyle(.plain)
        .accessibilityLabel(Text("\(name) \(s == "M" ? "mute" : "solo")"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Master FX (reverb + delay)

struct MasterFXBar: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings

    private func pct(_ v: Double) -> String { "\(Int(v * 100))%" }
    private func ms(_ v: Double) -> String { "\(Int(v)) ms" }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                group("REVERB", color: Color(hex: "#33E0D4")) {
                    knob("Mix", project.fxSettings.reverbMix, 0, 1, 0.01, pct, info: Glossary.reverbMix) { v in project.setMasterFX("reverbMix") { $0.reverbMix = v } }
                    knob("Size", project.fxSettings.reverbSize, 0, 1, 0.01, pct, info: Glossary.reverbSize) { v in project.setMasterFX("reverbSize") { $0.reverbSize = v } }
                    knob("Damp", project.fxSettings.reverbDamp, 0, 1, 0.01, pct, info: Glossary.reverbDamp) { v in project.setMasterFX("reverbDamp") { $0.reverbDamp = v } }
                    VStack(spacing: 6) {
                        Text("TYPE").font(FDFont.mono(8.5, .bold)).tracking(0.6).foregroundStyle(settings.inkFaint)
                        ForEach(Array(["Room", "Plate"].enumerated()), id: \.offset) { (i, nm) in
                            Button { project.setMasterFX("reverbMode") { $0.reverbMode = i } } label: {
                                Text(nm).font(FDFont.mono(9.5, .bold))
                                    .foregroundStyle((project.fxSettings.reverbMode ?? 0) == i ? settings.ink : settings.inkFaint)
                                    .frame(width: 48, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 6).fill((project.fxSettings.reverbMode ?? 0) == i ? settings.accent.opacity(0.25) : settings.panel2))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke((project.fxSettings.reverbMode ?? 0) == i ? settings.accent.opacity(0.6) : settings.line, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.top, 2)
                }
                Rectangle().fill(settings.line).frame(width: 1, height: 92)
                group("DELAY", color: Color(hex: "#C77DFF")) {
                    knob("Mix", project.fxSettings.delayMix, 0, 1, 0.01, pct, info: Glossary.delayMix) { v in project.setMasterFX("delayMix") { $0.delayMix = v } }
                    knob("Time", project.fxSettings.delayTimeMs, 60, 1000, 5, ms, info: Glossary.delayTime) { v in project.setMasterFX("delayTimeMs") { $0.delayTimeMs = v } }
                    knob("F.Back", project.fxSettings.delayFeedback, 0, 0.9, 0.01, pct, info: Glossary.delayFbk) { v in project.setMasterFX("delayFeedback") { $0.delayFeedback = v } }
                    VStack(spacing: 6) {
                        Text("SYNC").font(FDFont.mono(8.5, .bold)).tracking(0.6).foregroundStyle(settings.inkFaint)
                        syncChip("¼") { setDelayDiv(1.0) }
                        syncChip("⅛") { setDelayDiv(0.5) }
                        syncChip("⅛·") { setDelayDiv(0.75) }
                    }.padding(.top, 2)
                }
                Rectangle().fill(settings.line).frame(width: 1, height: 92)
                masterGroup
                Rectangle().fill(settings.line).frame(width: 1, height: 92)
                multibandGroup
                Rectangle().fill(settings.line).frame(width: 1, height: 92)
                analyzerGroup
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.line, lineWidth: 1))
    }

    private var masterGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(settings.accent).frame(width: 9, height: 9)
                Text("MASTER").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkDim)
                masterToggle("EQ", on: project.masterBus.eqOn) { project.setMasterBus("eqOn") { $0.eqOn.toggle() } }
                masterToggle("LIM", on: project.masterBus.limiterOn) { project.setMasterBus("limiterOn") { $0.limiterOn.toggle() } }
                LUFSReadout()
            }
            HStack(alignment: .top, spacing: 8) {
                knob("Low", project.masterBus.low, -12, 12, 1, db) { v in project.setMasterBus("low") { $0.low = v } }
                knob("Mid", project.masterBus.mid, -12, 12, 1, db) { v in project.setMasterBus("mid") { $0.mid = v } }
                knob("High", project.masterBus.high, -12, 12, 1, db) { v in project.setMasterBus("high") { $0.high = v } }
                knob("Ceil", project.masterBus.ceiling, -12, 0, 0.1, db) { v in project.setMasterBus("ceiling") { $0.ceiling = v } }
            }
        }
    }

    private var multibandGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: "#7AE582")).frame(width: 9, height: 9)
                Text("MULTIBAND").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkDim)
                masterToggle("ON", on: project.masterBus.mbOn) { project.setMasterBus("mbOn") { $0.mbOn.toggle() } }
            }
            HStack(alignment: .top, spacing: 8) {
                knob("Low", project.masterBus.mbLowThresh, -48, 0, 1, db) { v in project.setMasterBus("mbLow") { $0.mbLowThresh = v } }
                knob("Mid", project.masterBus.mbMidThresh, -48, 0, 1, db) { v in project.setMasterBus("mbMid") { $0.mbMidThresh = v } }
                knob("High", project.masterBus.mbHighThresh, -48, 0, 1, db) { v in project.setMasterBus("mbHigh") { $0.mbHighThresh = v } }
                knob("Ratio", project.masterBus.mbRatio, 1, 10, 0.5, { String(format: "%.1f:1", $0) }) { v in project.setMasterBus("mbRatio") { $0.mbRatio = v } }
            }
        }
    }
    private var analyzerGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(settings.accent).frame(width: 9, height: 9)
                Text("ANALYZER").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkDim)
                Text("20 Hz → 20 kHz").font(FDFont.mono(8.5)).foregroundStyle(settings.inkFaint)
            }
            SpectrumView().frame(width: 168)
        }
    }
    private func db(_ v: Double) -> String { "\(Int(v)) dB" }
    private func masterToggle(_ s: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(8.5, .bold)).foregroundStyle(on ? .white : settings.inkFaint)
                .padding(.horizontal, 7).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? settings.accent : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Color.clear : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func group<C: View>(_ title: String, color: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
                Text(title).font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkDim)
            }
            HStack(alignment: .top, spacing: 8) { content() }
        }
    }

    private func knob(_ label: String, _ value: Double, _ lo: Double, _ hi: Double, _ step: Double,
                      _ fmt: @escaping (Double) -> String, info: String? = nil, _ onChange: @escaping (Double) -> Void) -> some View {
        KnobView(label: label, value: value, min: lo, max: hi, step: step, color: settings.accent, format: fmt, onChange: onChange, info: info)
    }

    private func syncChip(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(11, .bold)).foregroundStyle(settings.inkDim)
                .frame(width: 34, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // set the delay time to a musical division of the current tempo
    private func setDelayDiv(_ beats: Double) {
        let msv = (60.0 / Double(project.bpm)) * beats * 1000
        project.setMasterFX("delayTimeMs") { $0.delayTimeMs = max(60, min(1000, msv)) }
    }
}

// Live ITU-R BS.1770 momentary loudness readout (green near the −14 LUFS streaming target).
struct LUFSReadout: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.2)) { _ in
            let v = engine.momentaryLUFS()
            let txt = v <= -69 ? "−∞" : String(format: "%.1f", v)
            let col: Color = v > -9 ? settings.theme.miss : (v > -16 ? settings.theme.good : settings.inkDim)
            Text("\(txt) LUFS").font(FDFont.mono(10, .bold)).foregroundStyle(col)
                .padding(.horizontal, 7).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(settings.line, lineWidth: 1))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Per-track mixer strip (G1 — level/pan/mute/solo on the Track model, no new DSP bus)

struct TrackStrip: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings
    let track: Track
    let meter: Double
    @State private var faderStart: Double?
    @State private var panStart: Double?
    @State private var showFX = false
    @State private var confirmRemoveBus = false

    private var muted: Bool { project.trackMute[track.id] ?? false }
    private var soloed: Bool { project.trackSolo[track.id] ?? false }
    private var panLabel: String { track.pan == 0 ? "C" : (track.pan > 0 ? "R" : "L") + "\(Int(abs(track.pan) * 100))" }

    var body: some View {
        let th = settings.theme
        let hot = meter > 0.97
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(track.color).frame(width: 9, height: 9)
                Text(track.name).font(FDFont.display(13, .bold)).foregroundStyle(th.ink).lineLimit(1)
            }
            HStack(spacing: 4) {
                Image(systemName: track.type.glyph).font(.system(size: 10)).foregroundStyle(th.inkFaint)
                Text(track.type.label).font(FDFont.mono(8)).foregroundStyle(th.inkFaint).lineLimit(1)
            }
            panKnob
            Text("PAN \(panLabel)").font(FDFont.mono(8.5, .bold)).tracking(0.6).foregroundStyle(th.inkFaint)
            HStack(spacing: 10) { meterBar; fader }.frame(maxHeight: .infinity)
            HStack(spacing: 5) {
                Circle().fill(hot ? th.miss : settings.line).frame(width: 7, height: 7)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Clip indicator"))
                    .accessibilityValue(Text(hot ? "Clipping" : "OK"))
                // non-color cue — show "CLIP" text whenever the meter is hot
                if hot {
                    Text("CLIP").font(FDFont.mono(8, .bold)).tracking(0.5).foregroundStyle(th.miss)
                        .accessibilityHidden(true)
                }
                Text("\(dbStr(track.vol)) dB").font(FDFont.mono(10, .bold)).foregroundStyle(th.inkDim)
            }
            HStack(spacing: 6) {
                msBtn("M", on: muted, color: th.miss) { project.toggleTrackMute(track.id) }
                msBtn("S", on: soloed, color: th.good) { project.toggleTrackSolo(track.id) }
            }
            // per-track insert FX (G3) on added/frozen tracks; group `.bus` tracks always own a strip (G3.4).
            // The 6 seeded tracks use their kit/melody bus FX in the Buses tab.
            if track.isFrozen || track.isLinked || track.type == .bus {
                let hasBus = track.ownsBus || track.type == .bus
                Button {
                    if !hasBus { project.toggleTrackBus(track.id) }
                    showFX = true
                } label: {
                    Text(hasBus ? "FX ●" : "+ FX").font(FDFont.mono(9.5, .bold))
                        .foregroundStyle(hasBus ? settings.accent : settings.inkFaint)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: FDRadius.sm).fill(hasBus ? settings.accent.opacity(0.18) : settings.panel2))
                        .overlay(RoundedRectangle(cornerRadius: FDRadius.sm).stroke(hasBus ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                }.buttonStyle(.plain)
                .popover(isPresented: $showFX) { trackFXEditor() }
                .accessibilityLabel(Text("\(track.name) insert FX"))
            }
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 12, trailing: 10))
        .frame(width: 96).frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: FDRadius.xl).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: FDRadius.xl).stroke(muted ? th.miss.opacity(0.4) : settings.line, lineWidth: 1))
    }

    private var panKnob: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [settings.panel2, settings.panel2.darker(0.3)], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 30))
                .overlay(Circle().stroke(settings.line, lineWidth: 1)).frame(width: 42, height: 42)
            Capsule().fill(track.color).frame(width: 2.5, height: 12).offset(y: -10)
                .rotationEffect(.degrees(track.pan * 135))
        }
        .frame(width: 42, height: 42).contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if panStart == nil { panStart = track.pan; project.checkpoint("trackpan:\(track.id)", coalesce: false) }
                project.setTrackPan(track.id, (panStart ?? 0) + v.translation.width / 80)
            }
            .onEnded { _ in panStart = nil })
        .accessibilityElement().accessibilityLabel(Text("\(track.name) pan")).accessibilityValue(Text(panLabel))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: project.setTrackPan(track.id, track.pan + 0.1)
            case .decrement: project.setTrackPan(track.id, track.pan - 0.1)
            default: break
            }
        }
    }

    private var meterBar: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6).fill(settings.panel2.darker(0.2))
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [settings.theme.meterLow, settings.theme.perfect, settings.theme.miss], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height * min(1, meter))
            }
        }.frame(width: 12)
    }

    private var fader: some View {
        GeometryReader { g in
            let H = g.size.height
            let frac = track.vol / 1.4
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(settings.panel2.darker(0.22)).frame(width: 6)
                RoundedRectangle(cornerRadius: 4).fill(track.color.opacity(0.5)).frame(width: 6, height: H * frac)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [settings.theme.capA, settings.theme.capB], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.5), lineWidth: 1))
                    Capsule().fill(track.color).frame(width: 26, height: 2)
                }
                .frame(width: 38, height: 22).shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                .offset(y: -H * frac + 11)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if faderStart == nil { faderStart = track.vol; project.checkpoint("trackvol:\(track.id)", coalesce: false) }
                        project.setTrackVol(track.id, (faderStart ?? 0) - v.translation.height / H * 1.4)
                    }
                    .onEnded { _ in faderStart = nil })
            }.frame(maxWidth: .infinity, alignment: .center)
        }.frame(width: 46)
        .accessibilityElement().accessibilityLabel(Text("\(track.name) volume")).accessibilityValue(Text("\(dbStr(track.vol)) dB"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: project.setTrackVol(track.id, track.vol + 0.05)
            case .decrement: project.setTrackVol(track.id, track.vol - 0.05)
            default: break
            }
        }
    }

    private func msBtn(_ s: String, on: Bool, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(FDFont.mono(11, .bold))
                .foregroundStyle(on ? (s == "S" ? Color(hex: "#08240f") : .white) : settings.inkFaint)
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? color : settings.panel2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? .clear : settings.line, lineWidth: 1))
                // non-color cue so the active state reads without relying on the fill color
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: s == "M" ? "speaker.slash.fill" : "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(s == "S" ? Color(hex: "#08240f") : .white)
                            .padding(2)
                            .accessibilityHidden(true)
                    }
                }
        }.buttonStyle(.plain)
        .accessibilityLabel(Text("\(track.name) \(s == "M" ? "mute" : "solo")"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: per-track insert FX (G3) — bound to channelFX[track.id]
    @ViewBuilder private func trackFXEditor() -> some View {
        let cfx = project.channelFX[track.id] ?? ChannelFX()
        let added = MIXER_FX_MODULES.filter { $0.isAdded(cfx) }
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("\(track.name) · Insert FX").font(FDFont.display(15, .bold)).foregroundStyle(settings.ink)
                Spacer()
                if MIXER_FX_MODULES.contains(where: { !$0.isAdded(cfx) }) {
                    Menu {
                        ForEach(MIXER_FX_MODULES.filter { !$0.isAdded(cfx) }) { mod in
                            Button(mod.label) { project.setChannelFX(track.id) { mod.add(&$0) } }
                        }
                    } label: {
                        Label("Add FX", systemImage: "plus.circle.fill").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.accent)
                    }.accessibilityLabel(Text("Add an effect to \(track.name)"))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if added.isEmpty {
                        Text("No effects yet — tap Add FX to insert one.")
                            .font(FDFont.ui(12)).foregroundStyle(settings.inkFaint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    ForEach(added) { mod in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(mod.label).font(FDFont.ui(13, .bold)).foregroundStyle(settings.ink)
                                Spacer()
                                Button(role: .destructive) { project.setChannelFX(track.id) { mod.remove(&$0) } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(settings.inkFaint)
                                }.buttonStyle(.plain).accessibilityLabel(Text("Remove \(mod.label)"))
                            }
                            mixerFXControls(mod.id, cfx: cfx, settings, dbl: fxd, bln: fxb,
                                            setInt: { kp, v in project.setChannelFX(track.id) { $0[keyPath: kp] = v } })
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                    }
                    Rectangle().fill(settings.line).frame(height: 1).padding(.vertical, 2)
                    Text("SENDS").font(FDFont.mono(9, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                    fxSl("Reverb / Delay send", fxd(\.send), 0, 1)
                    fxSl("Sidechain duck", fxd(\.scAmount), 0, 1)
                }
            }.frame(maxHeight: 420)
            if track.type != .bus {   // a group bus always owns its strip — can't remove it
                Button(role: .destructive) { confirmRemoveBus = true } label: {
                    Text("Remove FX bus").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.theme.miss)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(settings.theme.miss.opacity(0.12)))
                }.buttonStyle(.plain)
                .confirmationDialog("Remove this FX bus?", isPresented: $confirmRemoveBus, titleVisibility: .visible) {
                    Button("Remove FX bus", role: .destructive) { project.toggleTrackBus(track.id); showFX = false }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Clears this track's insert effects. You can undo it afterwards.") }
            }
        }
        .padding(16).frame(width: 280).background(settings.panel).presentationCompactAdaptation(.popover)
    }
    private func fxd(_ kp: WritableKeyPath<ChannelFX, Double>) -> Binding<Double> {
        Binding(get: { project.channelFX[track.id]?[keyPath: kp] ?? ChannelFX()[keyPath: kp] },
                set: { v in project.setChannelFX(track.id) { $0[keyPath: kp] = v } })
    }
    private func fxb(_ kp: WritableKeyPath<ChannelFX, Bool>) -> Binding<Bool> {
        Binding(get: { project.channelFX[track.id]?[keyPath: kp] ?? false },
                set: { v in project.setChannelFX(track.id) { $0[keyPath: kp] = v } })
    }
    private func fxSl(_ label: String, _ val: Binding<Double>, _ lo: Double, _ hi: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(FDFont.ui(11.5)).foregroundStyle(settings.inkDim); Spacer()
                Text(String(format: "%.1f", val.wrappedValue)).font(FDFont.mono(10, .bold)).foregroundStyle(settings.ink)
            }
            Slider(value: val, in: lo...hi).tint(settings.accent)
        }
    }
}
