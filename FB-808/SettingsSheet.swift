//  SettingsSheet.swift — live look & workspace controls (theme, accent,
//  interface level, pad labels, glow). The native equivalent of the
//  prototype's Tweaks panel. Sections are grouped into cards; audio options
//  the hardware can't honor (low-tier voice/rate caps) are shown disabled
//  instead of silently clamped.

import SwiftUI
import FD808Engine   // AudioDiagnostics

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var midi: MIDIManager
    @Environment(\.dismiss) private var dismiss
    @State private var showMPCBridge = false
    @State private var showResetConfirm = false

    private var lowTier: Bool { DeviceTier.current == .low }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    lookCard
                    workspaceCard
                    padsCard
                    audioCard
                    qualityCard
                    diagnosticsCard
                    progressCard
                    footer
                }
                .padding(20)
            }
            .sheet(isPresented: $showMPCBridge) { MPCBridgeView(onClose: { showMPCBridge = false }) }
            .background(settings.theme.bg.ignoresSafeArea())
            .navigationTitle("Tweaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(settings.accent)
                }
            }
            .confirmationDialog("Reset all settings?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset to defaults", role: .destructive) { settings.resetToDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Look, workspace, and audio preferences go back to their defaults. Your saved kits, synth patches, and projects are not touched.")
            }
        }
    }

    // MARK: - Section cards

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(settings.accent)
                Text(title.uppercased()).font(FDFont.mono(11, .bold)).tracking(1.6).foregroundStyle(settings.inkFaint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fdCard(14, fill: settings.panel)
    }

    private var lookCard: some View {
        card("Look", icon: "paintbrush.fill") {
            radioRow(title: "Theme",
                     options: ThemeName.allCases.map { ($0.rawValue.capitalized, $0.rawValue) },
                     selected: settings.themeName.rawValue) { v in
                settings.themeName = ThemeName(rawValue: v) ?? .studio
            }
            accentRow
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Glow").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Spacer()
                    Text(String(format: "%.1f", settings.glow)).font(FDFont.mono(13)).foregroundStyle(settings.inkDim)
                }
                Slider(value: $settings.glow, in: 0.3...1.6, step: 0.1).tint(settings.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Glow"))
            .accessibilityValue(Text(String(format: "%.0f%%", settings.glow * 100)))
        }
    }

    private var workspaceCard: some View {
        card("Workspace", icon: "square.grid.2x2.fill") {
            radioRow(title: "Interface level",
                     options: InterfaceLevel.allCases.map { ($0.title, $0.rawValue) },
                     selected: settings.level.rawValue) { v in
                settings.level = InterfaceLevel(rawValue: v) ?? .creator
            }
            Text(settings.level.summary).font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var padsCard: some View {
        card("Pads", icon: "square.grid.4x3.fill") {
            Toggle(isOn: $settings.padLabels) {
                Text("Show labels").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            }.tint(settings.accent)
            Toggle(isOn: $settings.mpcCoach) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MPC Coach").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Surface MPC button names as you work").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Button { showMPCBridge = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "book.fill").font(.system(size: 12, weight: .semibold))
                    Text("Open MPC Bridge").font(FDFont.ui(13, .semibold))
                }
                .foregroundStyle(settings.accent)
                .frame(maxWidth: .infinity).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.opacity(0.12)))
            }.buttonStyle(.plain)
        }
    }

    private var audioCard: some View {
        card("Audio", icon: "waveform") {
            radioRow(title: "Latency · buffer size",
                     options: [("Auto", "0"), ("Low · 3 ms", "3"), ("Balanced · 8 ms", "8"), ("Stable · 12 ms", "12"), ("Max · 21 ms", "21")],
                     selected: "\(Int(settings.audioBufferMs))") { v in settings.audioBufferMs = Double(v) ?? 0 }
            footnote("Auto targets \(lowTier ? 1024 : 512) frames\(lowTier ? " on this iPad" : " (1024 on Bluetooth)") — enough render headroom to avoid crackle. Lower = snappier pads but more risk of dropouts when many sounds play; higher = rock-solid.")
            radioRow(title: "Max voices · polyphony",
                     options: [("32", "32"), ("64", "64"), ("96", "96"), ("128", "128")],
                     selected: "\(lowTier ? min(settings.polyphony, 32) : settings.polyphony)",
                     disabled: lowTier ? ["64", "96", "128"] : []) { v in settings.polyphony = Int(v) ?? 64 }
            radioRow(title: "Sample rate · applies on restart",
                     options: AudioDefaults.supportedSampleRates.map { (String(format: "%gk", $0 / 1000), "\(Int($0))") },
                     selected: "\(Int(lowTier ? min(settings.sampleRate, AudioDefaults.sampleRate) : settings.sampleRate))",
                     disabled: lowTier ? ["88200", "96000"] : []) { v in settings.sampleRate = Double(v) ?? AudioDefaults.sampleRate }
            if lowTier {
                footnote("This iPad is a lower-power model, so voices are capped at 32 and the rate at 48 kHz — playback stays glitch-free instead of crackling.")
            } else {
                footnote("Higher rates reduce aliasing for cleaner synths; the engine adopts the new rate next launch.")
            }
            inputPicker
            Toggle(isOn: $settings.stereoInput) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stereo recording").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Capture both channels of a stereo interface. Off = mono (uses the left/first input).").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Toggle(isOn: $settings.haptics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Feel the beat (haptics)").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("A haptic pulse on each beat while playing — feel the rhythm as well as hear it.").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
        }
    }

    // Audio input device — native iOS 26 picker (built-in mic / wired / USB-C interface / Bluetooth).
    private var inputPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Recording input").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            AudioInputPicker(prepare: { engine.prepareInputSelection() }) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.and.signal.meter.fill").font(.system(size: 15)).foregroundStyle(settings.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Choose input device").font(FDFont.ui(14, .semibold)).foregroundStyle(settings.ink)
                        Text(engine.inputName).font(FDFont.mono(11)).foregroundStyle(settings.inkFaint).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(settings.inkDim)
                }
                .padding(.horizontal, 14).frame(height: 52)
                .frame(maxWidth: .infinity)
                .fdCard(12, fill: settings.panel2)
            }
            footnote("Record through a built-in mic, headset, or a USB-C / Bluetooth audio interface (e.g. Focusrite). The system remembers your choice per app.")
        }
    }

    private var qualityCard: some View {
        card("Sound Quality", icon: "sparkles") {
            Toggle(isOn: $settings.hqInterp) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HQ sample interpolation").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Smoother pitched/chopped samples (cubic) — costs a little CPU").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Toggle(isOn: $settings.equalPowerPan) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equal-power panning").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Constant loudness across the stereo field (centre sits ~3 dB lower)").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Toggle(isOn: $settings.bandlimitedOsc) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Band-limited oscillators").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Cleaner high synth notes — removes saw/square aliasing (PolyBLEP)").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Toggle(isOn: $settings.exportDither) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("16-bit export dither").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Cleaner quiet tails in WAV exports (TPDF dither)").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            Toggle(isOn: $settings.limiterOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Master limiter").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                    Text("Keeps loud stacks clean instead of distorting").font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
            }.tint(settings.accent)
            if settings.limiterOn {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ceiling").font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
                        Spacer()
                        Text(String(format: "%.1f dB", settings.limiterCeilingDb)).font(FDFont.mono(13)).foregroundStyle(settings.inkDim)
                    }
                    Slider(value: $settings.limiterCeilingDb, in: -6...0, step: 0.5).tint(settings.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Ceiling"))
                .accessibilityValue(Text(String(format: "%.1f decibels", settings.limiterCeilingDb)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: settings.limiterOn)
    }

    private var diagnosticsCard: some View {
        card("Diagnostics", icon: "stethoscope") {
            diagnosticsPanel
        }
    }

    private var progressCard: some View {
        card("Progress", icon: "trophy.fill") {
            radioRow(title: "Daily XP goal",
                     options: [("Casual · 20", "20"), ("Regular · 60", "60"), ("Intense · 120", "120")],
                     selected: "\(progress.dailyGoal)") { v in progress.dailyGoal = Int(v) ?? 60 }
            achievementsGrid
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(role: .destructive) { showResetConfirm = true } label: {
                Text("Reset all settings").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.theme.miss)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(settings.theme.miss.opacity(0.1)))
            }.buttonStyle(.plain)
            Text("FD-808 · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(FDFont.mono(10.5)).foregroundStyle(settings.inkFaint)
        }
        .padding(.top, 6)
    }

    private func footnote(_ s: String) -> some View {
        Text(s).font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Diagnostics

    // Live engine telemetry (Phase 0). engine.diag refreshes ~5 Hz; the view re-renders automatically.
    private var diagnosticsPanel: some View {
        let d = engine.diag
        let loadPct = Int((d.cpuLoad * 100).rounded())
        let loadColor: Color = d.cpuLoad > 0.9 ? settings.theme.miss : (d.cpuLoad > 0.6 ? settings.theme.perfect : settings.theme.good)
        let thermal = ProcessInfo.processInfo.thermalState
        return VStack(spacing: 7) {
            diagRow("Render load", "\(loadPct)%  ·  \(String(format: "%.2f/%.2f ms", d.renderMs, d.budgetMs))", loadColor)
            diagRow("Active voices", "\(d.activeVoices) / \(settings.polyphony)", settings.ink)
            diagRow("Peak", String(format: "%.2f", d.peak), d.peak >= 1.04 ? settings.theme.perfect : settings.ink)
            diagRow("Underruns · clips · steals · dropped", "\(d.overruns) · \(d.clips) · \(d.steals) · \(d.droppedCommands)",
                    ((d.overruns > 0 || d.droppedCommands > 0) ? settings.theme.miss : settings.ink))
            diagRow("Sample rate", String(format: "%.0f Hz", d.sampleRate), settings.inkDim)
            diagRow("Route", engine.sessionMgr.summary, settings.inkDim)
            diagRow("Device", tierSummary, settings.inkDim)
            diagRow("Thermal", thermalLabel(thermal), thermal == .serious || thermal == .critical ? settings.theme.miss : settings.inkDim)
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
    }

    private var tierSummary: String {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let tier: String
        switch DeviceTier.current {
        case .low:  tier = "Low-power"
        case .mid:  tier = "Mid"
        case .high: tier = "High"
        }
        return "\(tier) · \(String(format: "%.0f", gib.rounded())) GB RAM"
    }

    private func thermalLabel(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Hot — voices reduced"
        case .critical: return "Critical — voices reduced"
        @unknown default: return "—"
        }
    }

    private func diagRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(label).font(FDFont.ui(12.5)).foregroundStyle(settings.inkDim)
            Spacer()
            Text(value).font(FDFont.mono(12.5, .bold)).foregroundStyle(color)
        }
    }

    // MARK: - Achievements

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

    // MARK: - Shared controls

    private func radioRow(title: String, options: [(String, String)], selected: String,
                          disabled: Set<String> = [], _ onChange: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(FDFont.ui(15, .medium)).foregroundStyle(settings.ink)
            HStack(spacing: 8) {
                ForEach(options, id: \.1) { (label, value) in
                    let off = disabled.contains(value)
                    Button { onChange(value) } label: {
                        Text(label).font(FDFont.ui(13, .semibold))
                            .foregroundStyle(selected == value ? settings.ink : settings.inkDim)
                            .padding(.vertical, 9).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(selected == value ? settings.accent.opacity(0.2) : settings.panel2))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected == value ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
                    }.buttonStyle(.plain)
                        .disabled(off)
                        .opacity(off ? 0.35 : 1)
                        .accessibilityLabel(Text("\(title): \(label)"))
                        .accessibilityHint(off ? Text("Not available on this iPad") : Text(""))
                        .accessibilityAddTraits(selected == value ? [.isButton, .isSelected] : .isButton)
                }
            }
            .sensoryFeedback(.selection, trigger: selected)
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
