import Foundation
import SwiftUI
import Testing
import FD808Engine
@testable import FB_808

@Suite(.serialized)
struct CurrentGapsRegressionTests {
    @Test @MainActor func legacyChopSequenceKeepsItsSampleAfterRestore() throws {
        let p = Project(engine: AudioEngine())
        let audio: [Float] = [0, 0.25, -0.25, 0]
        p.setPadSample("kick", data: audio, name: "Legacy chop", bank: "A")
        let file = try #require(p.padParams["kick"]?.sampleFile)
        defer { deletePadSampleWAV(file: file) }
        p.lanes = ["kick": [1] ]
        var legacy = p.snapshot()
        legacy.version = 3
        legacy.bank = "C"
        legacy.padParams["kick"]?.sampleBank = "C"
        let loaded = Project(engine: AudioEngine())
        loaded.restore(legacy)
        let plan = loaded.buildExportPlan(loopBarsOverride: 1)
        #expect(plan.drums.first?.sampleData == audio)
    }

    @Test @MainActor func sequencedHatsKeepLiveDefaultChoke() {
        let p = Project(engine: AudioEngine())
        #expect(p.padOpts("hatClosed")?.chokeGroup == DefaultChoke.hats)
        #expect(p.padOpts("hatClosed", meta: nil)?.chokeGroup == DefaultChoke.hats)
        p.lanes = ["hatClosed": [1]]
        #expect(p.buildExportPlan(loopBarsOverride: 1).drums.first?.opts.chokeGroup == DefaultChoke.hats)
    }

    @Test @MainActor func monoPadsInDifferentBanksDoNotChokeEachOther() {
        let p = Project(engine: AudioEngine())
        p.setPadParam("C:kick") { $0.poly = false }
        p.setPadParam("D:kick") { $0.poly = false }
        #expect(p.padOpts("C:kick")?.chokeGroup != p.padOpts("D:kick")?.chokeGroup)
    }

    @Test @MainActor func fullSongOverrideUsesPinnedPatternWithToggleOff() {
        let p = Project(engine: AudioEngine())
        p.songBars = 4
        p.activeSeq = 0
        p.lanes = ["kick": [1]]
        p.sequences[1].lanes = ["snare": [1]]
        p.arrangement = [ArrItem(id: "audit", section: "verse", start: 0, len: 4, seq: 0)]
        p.clips["drums"] = [Clip(s: 0, l: 4, color: .red, seq: 1)]
        p.songMode = false
        let override = p.buildExportPlan(songModeOverride: true)
        p.songMode = true
        let normal = p.buildExportPlan()
        #expect(override.drums.map(\.sound) == normal.drums.map(\.sound))
    }

    @Test @MainActor func loopOverrideUsesCurrentLinkedPatternWithSongToggleOn() {
        let p = Project(engine: AudioEngine())
        p.activeSeq = 0
        p.lanes = ["kick": [1]]
        p.sequences[1].lanes = ["snare": [1]]
        p.arrangement = [ArrItem(id: "audit", section: "verse", start: 0, len: 4, seq: 1)]
        _ = p.sendLanesToNewTrack(rows: ["kick", "snare"])
        p.songMode = true
        let override = p.buildExportPlan(loopBarsOverride: 1)
        p.songMode = false
        let normal = p.buildExportPlan(loopBarsOverride: 1)
        #expect(override.drums.map(\.sound) == normal.drums.map(\.sound))
    }

    @Test @MainActor func freezeStillTargetsSameTrackAfterReorder() async throws {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        let gate = SuspendedRender()
        let freezing = Task { @MainActor in await p.freezeTrack(id, render: { await gate.render($0) }) }
        await gate.waitUntilStarted()
        p.moveTrack(id, up: true)
        await gate.finish()
        let result = await freezing.value
        defer { for clip in p.audioClips { deleteClipWAV(id: clip.id) } }
        #expect(result)
        #expect(p.audioClips.first?.dataR?.first == 0.05)
        #expect(p.tracks.first { $0.id == id }?.frozenToAudio == true)
        #expect(p.tracks.filter(\.frozenToAudio).map(\.id) == [id])
    }

    @Test @MainActor func exportedSampleRespondsToFilterAndEnvelope() throws {
        let p = Project(engine: AudioEngine())
        let audio = (0..<4800).map { Float(sin(2 * Double.pi * 8000 * Double($0) / 48000)) * 0.5 }
        p.setPadSample("C:kick", data: audio, name: "Audit tone", bank: "C")
        let file = try #require(p.padParams["C:kick"]?.sampleFile)
        defer { deletePadSampleWAV(file: file) }
        p.lanes = ["C:kick": [1]]
        let flatPlan = p.buildExportPlan(loopBarsOverride: 1)
        p.setPadParam("C:kick") { $0.cutoff = 200; $0.attack = 0.08 }
        let shapedPlan = p.buildExportPlan(loopBarsOverride: 1)
        #expect(flatPlan.drums.count == 1)
        #expect(flatPlan.drums.first?.sampleData?.count == audio.count)
        #expect(shapedPlan.drums.first?.opts.cutoff == 200)
        let voice = try #require(buildVoices(shapedPlan).first)
        #expect(voice.extCutoff == 200)
        #expect(voice.hasAmp)
        let flat = renderOffline(flatPlan).0
        let shaped = renderOffline(shapedPlan).0
        #expect(flat.count > 1)
        #expect(flat.contains { abs($0) > 0.001 })
        // Filtering can shorten the audible tail. Compare the whole outputs with silence padding;
        // zip would compare only their common prefix (possibly just the silent first frame).
        var delta: Float = 0
        for i in 0..<max(flat.count, shaped.count) {
            let a: Float = i < flat.count ? flat[i] : 0
            let b: Float = i < shaped.count ? shaped[i] : 0
            delta = max(delta, abs(a - b))
        }
        #expect(delta > 0.001)
    }

    @Test @MainActor func offlineChokeChangesTheRenderedAudio() {
        let p = Project(engine: AudioEngine())
        p.lanes = ["hatOpen": [1, 0], "hatClosed": [0, 1]]
        p.setPadParam("hatOpen") { $0.choke = 1 }
        p.setPadParam("hatClosed") { $0.choke = 1 }
        let choked = p.buildExportPlan(loopBarsOverride: 1)
        var flat = choked
        for i in flat.drums.indices { flat.drums[i].opts.chokeGroup = 0 }
        let a = renderOffline(choked).0
        let b = renderOffline(flat).0
        let delta = zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(delta > 0.001)
    }

    @Test @MainActor func sendingPadToTrackKeepsExportedLayers() {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        p.setPadParam("kick") { $0.layers = [PadLayer(sound: "clap")] }
        let before = p.buildExportPlan(loopBarsOverride: 1)
        _ = p.sendLanesToNewTrack(rows: ["kick"])
        let after = p.buildExportPlan(loopBarsOverride: 1)
        #expect(before.drums.map(\.sound).sorted() == after.drums.map(\.sound).sorted())
    }
}
