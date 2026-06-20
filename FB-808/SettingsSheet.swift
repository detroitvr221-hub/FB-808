//  SettingsSheet.swift — live look & workspace controls (theme, accent,
//  interface level, pad labels, glow). The native equivalent of the
//  prototype's Tweaks panel.

import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore
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
