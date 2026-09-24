import Foundation
import Testing
import FD808Engine
@testable import FB_808

// Production-readiness audio findings (B2, M2, M6) — app-side regressions.
@Suite(.serialized)
struct AudioReliabilityRegressionTests {
    private func zeroEffect() -> HostedEffectState {
        HostedEffectState(id: UUID(), name: "Zeroed effect", type: 0, subtype: 0, manufacturer: 0, state: Data([9, 9]))
    }

    /// B2: 0 is a Core Audio wildcard — a zeroed description must never resolve to an installed AU.
    @Test func allZeroOrPartiallyZeroDescriptionIsRefused() {
        #expect(!zeroEffect().hasConcreteDescription)
        #expect(AudioEngine.installedComponent(for: zeroEffect()) == nil)
        var partial = zeroEffect(); partial.type = 0x6175_6678   // 'aufx' with wildcard subtype/manufacturer
        #expect(!partial.hasConcreteDescription)
        #expect(AudioEngine.installedComponent(for: partial) == nil)
        var missing = partial; missing.subtype = 0x7A7A_7A7A; missing.manufacturer = 0x4644_3858
        #expect(missing.hasConcreteDescription)
        #expect(AudioEngine.installedComponent(for: missing) == nil)
    }

    /// B2: restoring a zeroed chain must not instantiate anything (it used to crash with
    /// "required condition is false: _auv3 != nil"); the entry is kept and the notice shown.
    @Test @MainActor func zeroedPluginRestoreKeepsSettingsWithoutInstantiating() async throws {
        let engine = AudioEngine()
        let effect = zeroEffect()
        engine.restoreProjectEffects([effect], force: true)
        for _ in 0..<200 where engine.pluginNotice == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(engine.pluginNotice != nil)
        #expect(engine.masterAUs.isEmpty)
        #expect(engine.masterChainSnapshot() == [effect])
        engine.restoreProjectEffects([], force: true)
    }

    /// M6: a preset whose SoundFont file is gone reports `.missing` (async path) and leaves the patch alone.
    @Test @MainActor func missingSoundFontPresetIsReportedAndDoesNotChangeThePatch() async {
        let p = Project(engine: AudioEngine())
        p.startFromTemplate("blank")
        let before = p.editPatch
        var patch = before; patch.name = "Ghost SF2"; patch.instrumentID = UUID().uuidString
        #expect(await p.applyInstrumentPresetAsync(patch) == .missing)
        #expect(p.editPatch == before)
        var plain = before; plain.name = "Plain preset"; plain.instrumentID = nil
        #expect(await p.applyInstrumentPresetAsync(plain) == .applied)
        #expect(p.editPatch.name == "Plain preset")
    }

    /// M2: with no split running, the memory-warning purge succeeds (and is safe with nothing loaded).
    @Test @MainActor func memoryWarningPurgeIsSafeWhenIdle() {
        #expect(FourStemSeparator.purgeForMemoryPressure())
        AudioEngine().handleMemoryWarning()
    }
}
