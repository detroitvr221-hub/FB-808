//  SettingsSheet.swift — live look & workspace controls (theme, accent,
//  interface level, pad labels, glow). The native equivalent of the
//  prototype's Tweaks panel.

import SwiftUI
import FD808Engine   // AudioDiagnostics

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss
    @State private var showMPCBridge = false

    var body: some View {
        let th = settings.theme
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Look")
                    radioRow(title: "Theme",
                             options: ThemeName.allCases.map { ($0.rawValue.capitalized, $0.rawValue) },
                             selected: settings.themeName.rawValue) { v in
                        settings.themeName = ThemeName(rawValue: v) ?? .studio
                    }
                    accentRow

                    section("Workspace")
                    radioRow(title: "Interface level",
                             options: InterfaceLevel.allCases.map { ($0.title, $0.rawValue) },
                             selected: settings.level.rawValue) { v in
                        settings.level = InterfaceLevel(rawValue: v) ?? .creator
                    }
                    Text(settings.level.summary).font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    section("Pads")
                    Toggle(isOn: $settings.padLabels) {
                        Text("Show labels").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                    }.tint(settings.accent)
                    Toggle(isOn: $settings.mpcCoach) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MPC Coach").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Surface MPC button names as you work").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)
                    Button { showMPCBridge = true } label: {
                        Text("📖 Open MPC Bridge").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.accent)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.12)))
                    }.buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Glow").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Spacer()
                            Text(String(format: "%.1f", settings.glow)).font(FDFont.mono(13)).foregroundStyle(th.inkDim)
                        }
                        Slider(value: $settings.glow, in: 0.3...1.6, step: 0.1).tint(settings.accent)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Glow"))
                    .accessibilityValue(Text(String(format: "%.0f%%", settings.glow * 100)))

                    section("Audio")
                    radioRow(title: "Latency · buffer size",
                             options: [("Auto · 512", "0"), ("Low · 3 ms", "3"), ("Balanced · 8 ms", "8"), ("Stable · 12 ms", "12"), ("Max · 21 ms", "21")],
                             selected: "\(Int(settings.audioBufferMs))") { v in settings.audioBufferMs = Double(v) ?? 0 }
                    Text("Auto targets 512 frames (1024 on Bluetooth) — enough render headroom to avoid crackle. Lower = snappier pads but more risk of dropouts when many sounds play; higher = rock-solid.")
                        .font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint).fixedSize(horizontal: false, vertical: true)
                    radioRow(title: "Max voices · polyphony",
                             options: [("32", "32"), ("64", "64"), ("96", "96"), ("128", "128")],
                             selected: "\(settings.polyphony)") { v in settings.polyphony = Int(v) ?? 64 }
                    radioRow(title: "Sample rate · applies on restart",
                             options: AudioDefaults.supportedSampleRates.map { (String(format: "%gk", $0 / 1000), "\(Int($0))") },
                             selected: "\(Int(settings.sampleRate))") { v in settings.sampleRate = Double(v) ?? AudioDefaults.sampleRate }
                    Text("Higher rates reduce aliasing for cleaner synths; the engine adopts the new rate next launch.")
                        .font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint).fixedSize(horizontal: false, vertical: true)

                    section("Audio Quality")
                    Toggle(isOn: $settings.hqInterp) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HQ sample interpolation").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Smoother pitched/chopped samples (cubic) — costs a little CPU").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)
                    Toggle(isOn: $settings.equalPowerPan) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Equal-power panning").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Constant loudness across the stereo field (centre sits ~3 dB lower)").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)
                    Toggle(isOn: $settings.bandlimitedOsc) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Band-limited oscillators").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Cleaner high synth notes — removes saw/square aliasing (PolyBLEP)").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)
                    Toggle(isOn: $settings.exportDither) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("16-bit export dither").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Cleaner quiet tails in WAV exports (TPDF dither)").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)

                    Toggle(isOn: $settings.limiterOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Master limiter").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                            Text("Keeps loud stacks clean instead of distorting").font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint)
                        }
                    }.tint(settings.accent)
                    if settings.limiterOn {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Ceiling").font(FDFont.ui(15, .medium)).foregroundStyle(th.ink)
                                Spacer()
                                Text(String(format: "%.1f dB", settings.limiterCeilingDb)).font(FDFont.mono(13)).foregroundStyle(th.inkDim)
                            }
                            Slider(value: $settings.limiterCeilingDb, in: -6...0, step: 0.5).tint(settings.accent)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text("Ceiling"))
                        .accessibilityValue(Text(String(format: "%.1f decibels", settings.limiterCeilingDb)))
                    }

                    section("Diagnostics")
                    diagnosticsPanel

                    section("Progress")
                    radioRow(title: "Daily XP goal",
                             options: [("Casual · 20", "20"), ("Regular · 60", "60"), ("Intense · 120", "120")],
                             selected: "\(progress.dailyGoal)") { v in progress.dailyGoal = Int(v) ?? 60 }
                    achievementsGrid
                }
                .padding(24)
            }
            .sheet(isPresented: $showMPCBridge) { MPCBridgeView(onClose: { showMPCBridge = false }) }
            .background(th.bg.ignoresSafeArea())
            .navigationTitle("Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(settings.accent)
                }
            }
        }
    }

    private func section(_ s: String) -> some View {
        Text(s.uppercased()).font(FDFont.mono(11, .bold)).tracking(1.6).foregroundStyle(settings.inkFaint)
    }

    // Live engine telemetry (Phase 0). engine.diag refreshes ~5 Hz; the view re-renders automatically.
    private var diagnosticsPanel: some View {
        let d = engine.diag
        let loadPct = Int((d.cpuLoad * 100).rounded())
        let loadColor: Color = d.cpuLoad > 0.9 ? settings.theme.miss : (d.cpuLoad > 0.6 ? settings.theme.perfect : settings.theme.good)
        return VStack(spacing: 7) {
            diagRow("Render load", "\(loadPct)%  ·  \(String(format: "%.2f/%.2f ms", d.renderMs, d.budgetMs))", loadColor)
            diagRow("Active voices", "\(d.activeVoices) / \(settings.polyphony)", settings.ink)
            diagRow("Peak", String(format: "%.2f", d.peak), d.peak >= 1.04 ? settings.theme.perfect : settings.ink)
            diagRow("Underruns · clips · steals · dropped", "\(d.overruns) · \(d.clips) · \(d.steals) · \(d.droppedCommands)",
                    ((d.overruns > 0 || d.droppedCommands > 0) ? settings.theme.miss : settings.ink))
            diagRow("Sample rate", String(format: "%.0f Hz", d.sampleRate), settings.inkDim)
            diagRow("Route", engine.sessionMgr.summary, settings.inkDim)
            diagRow("MIDI in", midi.summary, settings.inkDim)
            diagRow("Input", engine.isMicRecording
                    ? "● \(engine.sessionMgr.inputName) · \(Int((min(1, engine.inputLevel)) * 100))%"
                    : "idle",
                    engine.isMicRecording ? settings.theme.miss : settings.inkDim)
            diagRow("Engine restarts", "\(engine.restartCount)\(engine.lastRestartReason.isEmpty ? "" : " · \(engine.lastRestartReason)")", settings.inkDim)
            let recent = Array(engine.telemetry.suffix(3))
            if !recent.isEmpty {
                Divider().overlay(settings.line)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(recent) { e in
                        Text("• \(e.kind): \(e.detail)").font(FDFont.mono(10.5)).foregroundStyle(settings.inkFaint)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            ShareLink(item: engine.telemetryReport()) {
                Text("Copy / share diagnostics").font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.accent)
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent.opacity(0.12)))
            }.padding(.top, 2)
        }
        .padding(12)
        .fdCard(12, fill: settings.panel2)
    }
    private func diagRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(FDFont.ui(12.5)).foregroundStyle(settings.inkDim)
            Spacer()
            Text(value).font(FDFont.mono(12.5, .bold)).foregroundStyle(color)
        }
    }

    // Surface the achievements that were defined but never shown anywhere (#83).
    private var achievementsGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Achievements").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                Spacer()
                Text("\(progress.achievements.count)/\(ProgressStore.allAchievements.count)")
                    .font(FDFont.mono(12, .bold)).foregroundStyle(settings.inkFaint)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(ProgressStore.allAchievements, id: \.id) { a in
                    let got = progress.achievements.contains(a.id)
                    VStack(spacing: 6) {
                        Image(systemName: a.icon).font(.system(size: 22))
                            .foregroundStyle(got ? settings.theme.perfect : settings.inkFaint.opacity(0.5))
                        Text(a.label).font(FDFont.ui(11, .semibold))
                            .foregroundStyle(got ? settings.ink : settings.inkFaint)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity).frame(height: 78)
                    .background(RoundedRectangle(cornerRadius: 12).fill(got ? settings.theme.perfect.opacity(0.12) : settings.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(got ? settings.theme.perfect.opacity(0.4) : settings.line, lineWidth: 1))
                    .opacity(got ? 1 : 0.6)
                }
            }
        }
    }

    private func radioRow(title: String, options: [(String, String)], selected: String, _ onChange: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            HStack(spacing: 8) {
                ForEach(options, id: \.1) { (label, value) in
                    Button { onChange(value) } label: {
                        Text(label).font(FDFont.ui(13, .semibold))
                            .foregroundStyle(selected == value ? settings.ink : settings.inkDim)
                            .padding(.vertical, 9).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(selected == value ? settings.accent.opacity(0.2) : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected == value ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text("\(title): \(label)"))
                        .accessibilityAddTraits(selected == value ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    // Map accent hex codes to human-readable names so VoiceOver announces a colour
    // name instead of a raw hex string.
    private func accentName(_ hex: String) -> String {
        switch hex.uppercased() {
        case "#FF6A2B": return "Orange"
        case "#FF3D7F": return "Pink"
        case "#21D0B2": return "Teal"
        case "#6C7BFF": return "Blue"
        default: return hex
        }
    }

    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Accent").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            HStack(spacing: 10) {
                ForEach(Accents.options, id: \.self) { hex in
                    let isSelected = settings.accentHex == hex
                    Button { settings.accentHex = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(.white, lineWidth: isSelected ? 2.5 : 0))
                            // Non-colour cue: a checkmark marks the selected swatch so the
                            // selection isn't conveyed by colour/ring alone.
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .opacity(isSelected ? 1 : 0)
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text("Accent colour \(accentName(hex))"))
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}
