//  SettingsSheet.swift — live look & workspace controls (theme, accent,
//  interface level, pad labels, glow). The native equivalent of the
//  prototype's Tweaks panel.

import SwiftUI
import FD808Engine   // AudioDiagnostics

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var engine: AudioEngine
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
                             options: InterfaceLevel.allCases.map { ($0.rawValue.capitalized, $0.rawValue) },
                             selected: settings.level.rawValue) { v in
                        settings.level = InterfaceLevel(rawValue: v) ?? .creator
                    }

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

                    section("Audio")
                    radioRow(title: "Latency · buffer size",
                             options: [("Auto · 256", "0"), ("Low · 3 ms", "3"), ("Balanced · 8 ms", "8"), ("Stable · 12 ms", "12"), ("Max · 21 ms", "21")],
                             selected: "\(Int(settings.audioBufferMs))") { v in settings.audioBufferMs = Double(v) ?? 0 }
                    Text("Auto targets 256 frames (512 on Bluetooth). Lower = snappier pads; higher = fewer glitches when many sounds play at once.")
                        .font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint).fixedSize(horizontal: false, vertical: true)
                    radioRow(title: "Max voices · polyphony",
                             options: [("32", "32"), ("64", "64"), ("96", "96"), ("128", "128")],
                             selected: "\(settings.polyphony)") { v in settings.polyphony = Int(v) ?? 64 }
                    radioRow(title: "Sample rate · applies on restart",
                             options: [("44.1k", "44100"), ("48k", "48000"), ("88.2k", "88200"), ("96k", "96000")],
                             selected: "\(Int(settings.sampleRate))") { v in settings.sampleRate = Double(v) ?? 48000 }
                    Text("Higher rates reduce aliasing for cleaner synths; the engine adopts the new rate next launch.")
                        .font(FDFont.ui(11.5)).foregroundStyle(th.inkFaint).fixedSize(horizontal: false, vertical: true)
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
            diagRow("Overruns · clips · steals", "\(d.overruns) · \(d.clips) · \(d.steals)",
                    (d.overruns > 0 ? settings.theme.miss : settings.ink))
            diagRow("Sample rate", String(format: "%.0f Hz", d.sampleRate), settings.inkDim)
            diagRow("Route", engine.sessionMgr.summary, settings.inkDim)
            diagRow("Engine restarts", "\(engine.restartCount)\(engine.lastRestartReason.isEmpty ? "" : " · \(engine.lastRestartReason)")", settings.inkDim)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
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
                }
            }
        }
    }

    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Accent").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            HStack(spacing: 10) {
                ForEach(Accents.options, id: \.self) { hex in
                    Button { settings.accentHex = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                            .overlay(Circle().stroke(.white, lineWidth: settings.accentHex == hex ? 2.5 : 0))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
