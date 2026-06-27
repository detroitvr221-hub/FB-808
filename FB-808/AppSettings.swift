//  AppSettings.swift — live look & workspace settings (ported from the tweaks
//  panel), persisted across launches via UserDefaults.

import SwiftUI
import Combine
import FD808Engine

@MainActor
final class AppSettings: ObservableObject {
    @Published var themeName: ThemeName { didSet { store.set(themeName.rawValue, forKey: "fd.theme") } }
    @Published var accentHex: String   { didSet { store.set(accentHex, forKey: "fd.accent") } }
    @Published var level: InterfaceLevel { didSet { store.set(level.rawValue, forKey: "fd.level") } }
    @Published var padLabels: Bool     { didSet { store.set(padLabels, forKey: "fd.padLabels") } }
    @Published var glow: Double        { didSet { store.set(glow, forKey: "fd.glow") } }
    @Published var mpcCoach: Bool      { didSet { store.set(mpcCoach, forKey: "fd.mpcCoach") } }
    // Audio engine prefs (applied to AudioEngine on launch + on change). Buffer = latency vs. stability;
    // polyphony bounds CPU + level; the safety limiter prevents the "loud stacks distort" problem.
    @Published var audioBufferMs: Double { didSet { store.set(audioBufferMs, forKey: "fd.audioBufferMs") } }
    @Published var polyphony: Int        { didSet { store.set(polyphony, forKey: "fd.polyphony") } }
    @Published var limiterOn: Bool       { didSet { store.set(limiterOn, forKey: "fd.limiterOn") } }
    @Published var limiterCeilingDb: Double { didSet { store.set(limiterCeilingDb, forKey: "fd.limiterCeilingDb") } }
    @Published var sampleRate: Double    { didSet { store.set(sampleRate, forKey: "fd.sampleRate") } }   // engine rate; applies on next launch
    // Audio-quality modes (opt-in; default off = current behavior). Applied to the engine live; export reads the dither flag.
    @Published var hqInterp: Bool        { didSet { store.set(hqInterp, forKey: "fd.hqInterp") } }
    @Published var equalPowerPan: Bool   { didSet { store.set(equalPowerPan, forKey: "fd.equalPowerPan") } }
    @Published var bandlimitedOsc: Bool  { didSet { store.set(bandlimitedOsc, forKey: "fd.bandlimitedOsc") } }
    @Published var exportDither: Bool    { didSet { store.set(exportDither, forKey: "fd.exportDither") } }
    // User-saved drum kits (per-pad sound maps), persisted as JSON. Shared across projects.
    @Published var userKits: [UserKitDef] { didSet { saveUserKits() } }
    // User-saved synth patches — a GLOBAL library so they persist across projects (#67, was per-project).
    @Published var savedSynths: [SynthPatch] { didSet { saveSavedSynths() } }

    private let store = UserDefaults.standard

    init() {
        let store = UserDefaults.standard
        themeName = ThemeName(rawValue: store.string(forKey: "fd.theme") ?? "") ?? .studio
        accentHex = store.string(forKey: "fd.accent") ?? "#FF6A2B"
        level = InterfaceLevel(rawValue: store.string(forKey: "fd.level") ?? "") ?? .creator
        padLabels = store.object(forKey: "fd.padLabels") as? Bool ?? true
        glow = store.object(forKey: "fd.glow") as? Double ?? 1.0
        mpcCoach = store.object(forKey: "fd.mpcCoach") as? Bool ?? false
        audioBufferMs = store.object(forKey: "fd.audioBufferMs") as? Double ?? 0   // 0 = Auto (per-route 256/512-frame policy)
        polyphony = store.object(forKey: "fd.polyphony") as? Int ?? 32   // default 32: safe on slower iPads (governor + Settings can raise it)
        limiterOn = store.object(forKey: "fd.limiterOn") as? Bool ?? true
        limiterCeilingDb = store.object(forKey: "fd.limiterCeilingDb") as? Double ?? -1.0
        sampleRate = store.object(forKey: "fd.sampleRate") as? Double ?? AudioDefaults.sampleRate
        // Anti-aliasing + dither default ON — the research-confirmed "premium" cleanliness (cubic interpolation,
        // band-limited oscillators, 16-bit dither). Equal-power pan stays OFF by default (it shifts the centre
        // level of existing mixes). All remain user-toggleable.
        hqInterp = store.object(forKey: "fd.hqInterp") as? Bool ?? true
        equalPowerPan = store.object(forKey: "fd.equalPowerPan") as? Bool ?? false
        bandlimitedOsc = store.object(forKey: "fd.bandlimitedOsc") as? Bool ?? true
        exportDither = store.object(forKey: "fd.exportDither") as? Bool ?? true
        userKits = AppSettings.loadUserKits()
        savedSynths = AppSettings.loadSavedSynths()
    }

    // MARK: user kits
    private func saveUserKits() {
        if let data = try? JSONEncoder().encode(userKits) { store.set(data, forKey: "fd.userKits") }
    }
    private static func loadUserKits() -> [UserKitDef] {
        guard let data = UserDefaults.standard.data(forKey: "fd.userKits"),
              let kits = try? JSONDecoder().decode([UserKitDef].self, from: data) else { return [] }
        return kits
    }
    @discardableResult
    func addUserKit(name: String, sounds: [String: String]) -> String {
        let id = UUID().uuidString
        let nm = name.trimmingCharacters(in: .whitespaces)
        userKits.append(UserKitDef(id: id, name: String((nm.isEmpty ? "My Kit" : nm).prefix(18)), sounds: sounds))
        return id
    }
    func deleteUserKit(_ id: String) { userKits.removeAll { $0.id == id } }

    // MARK: saved synth patches (global library, #67)
    private func saveSavedSynths() {
        if let data = try? JSONEncoder().encode(savedSynths) { store.set(data, forKey: "fd.savedSynths") }
    }
    private static func loadSavedSynths() -> [SynthPatch] {
        guard let data = UserDefaults.standard.data(forKey: "fd.savedSynths"),
              let p = try? JSONDecoder().decode([SynthPatch].self, from: data) else { return [] }
        return p
    }
    func addSavedSynth(_ patch: SynthPatch) {
        guard !savedSynths.contains(where: { $0.name == patch.name }) else { return }   // dedupe by name
        savedSynths.append(patch)
    }
    /// One-time migration: pull a project's legacy per-project saved patches into the global library.
    func mergeLegacySavedSynths(_ patches: [SynthPatch]) {
        for p in patches where !savedSynths.contains(where: { $0.name == p.name }) { savedSynths.append(p) }
    }

    var theme: Theme { Theme.make(themeName) }
    var accent: Color { Color(hex: accentHex) }
}

// Convenience accessors so views can read tokens tersely.
extension AppSettings {
    var ink: Color { theme.ink }
    var inkDim: Color { theme.inkDim }
    var inkFaint: Color { theme.inkFaint }
    var panel: Color { theme.panel }
    var panel2: Color { theme.panel2 }
    var line: Color { theme.line }
    var line2: Color { theme.line2 }
}
