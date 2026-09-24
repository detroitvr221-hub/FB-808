import Foundation
import Testing
import FD808Engine
@testable import FB_808

extension CurrentGapsRegressionTests {
    @Test @MainActor func migrationMovesEveryMusicalReferenceAndSurvivesReload() throws {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [0.8]]
        var meta = StepMeta(); meta.pitch = 7; meta.prob = 0.5
        p.stepMeta = ["kick": [0: meta]]
        p.rowMute = ["kick": true]; p.rowSolo = ["kick": true]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        var old = p.snapshot(); old.version = 3; old.bank = "C"
        old.sequences[1].lanes = ["kick": [0.5]]
        old.sequences[1].stepMeta = ["kick": [0: meta]]
        let migrated = old.migratedPadSlots()
        #expect(migrated.version == 4)
        #expect(migrated.lanes["kick"] == nil)
        #expect(migrated.lanes["C:kick"] == [0.8])
        #expect(migrated.stepMeta?["C:kick"]?[0] == meta)
        #expect(migrated.rowMute["C:kick"] == true)
        #expect(migrated.rowSolo["C:kick"] == true)
        #expect(migrated.sequences[1].lanes["C:kick"] == [0.5])
        #expect(migrated.sequences[1].stepMeta["C:kick"]?[0] == meta)
        #expect(migrated.tracks?.first { $0.id == id }?.source.link?.rows == ["C:kick"])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(migrated)
        let restored = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(try encoder.encode(restored.migratedPadSlots()) == data)
        p.restore(restored)
        #expect(p.lanes["C:kick"] == [0.8])
    }

    @Test @MainActor func migrationPreservesFrozenRowsAndExistingScopedDevelopmentSaves() {
        let p = Project(engine: AudioEngine())
        var old = p.snapshot(); old.version = 3; old.bank = "B"
        var source = TrackSource()
        source.lanes = ["snare": [1]]; source.padRows = ["snare"]; source.samplePad = "snare"
        old.tracks = [Track(id: "frozen", name: "Copy", type: .drumPattern, source: source, colorHex: "#ffffff")]
        let migrated = old.migratedPadSlots()
        #expect(migrated.tracks?.first?.source.lanes?["B:snare"] == [1])
        #expect(migrated.tracks?.first?.source.padRows == ["B:snare"])
        #expect(migrated.tracks?.first?.source.samplePad == "B:snare")
        old.lanes = ["kick": [1], "C:snare": [0.7]]
        #expect(old.migratedPadSlots().lanes == old.lanes)
    }

    @Test @MainActor func legacyBackupPreservesExactBytesAndReferencedSamples() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("legacy.fd808json")
        var old = Project(engine: AudioEngine()).snapshot(); old.version = 3
        var param = PadParam(); param.sampleFile = "old.wav"; param.sampleBank = "C"
        old.padParams = ["kick": param]
        let data = try JSONEncoder().encode(old)
        try data.write(to: url)
        #expect(ProjectStore.decodeSnapshot(url, preservingLegacy: true) != nil)
        #expect(ProjectStore.decodeSnapshot(url, preservingLegacy: true) != nil)
        let backups = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent(".pad-v3-backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == data)
        var updated = old.migratedPadSlots(); updated.padParams = [:]
        #expect(ProjectStore.writeSnapshot(updated, to: url, pretty: false))
        let refs = ProjectStore.referencedAssets(projectDir: dir, ext: "fd808json")
        #expect(refs.complete)
        #expect(refs.samples.contains("old.wav"))
    }

    @Test @MainActor func monoSelfCutSlotsHaveDistinctGroupsWhileFamilyChokesStayShared() {
        let p = Project(engine: AudioEngine())
        var groups = Set<Int>()
        for bank in Kit.bankOrder {
            for pad in Kit.banks[bank]!.pads {
                p.setPadParam(pad.id) { $0.poly = false }
                let group = p.padOpts(pad.id)?.chokeGroup ?? 0
                if pad.defaultChoke == 0 { groups.insert(group) }
                else { #expect(group == pad.defaultChoke) }
            }
        }
        #expect(groups.count == 60)
        #expect(!groups.contains(0))
        #expect(!groups.contains(DefaultChoke.hats))
    }

    @Test @MainActor func mappedSynthPadKeepsItsInstrumentInPlansAndMIDI() throws {
        let p = Project(engine: AudioEngine())
        p.synthBank = ["D:kick": SynthBankSlot(midi: 67, patch: SynthPresets.default)]
        p.lanes = ["D:kick": [1]]
        let hits = p.padPlaybackHits("D:kick", velocity: 0.8)
        if case .synth(let slot) = hits.first?.source { #expect(slot.midi == 67) }
        else { Issue.record("Mapped pad lost its synth source") }
        let classic = p.buildExportPlan(loopBarsOverride: 1)
        #expect(classic.drums.isEmpty)
        #expect(classic.synths.map(\.midi) == [67])
        let id = p.sendLanesToNewTrack(rows: ["D:kick"])
        #expect(p.buildExportPlan(loopBarsOverride: 1).synths.map(\.midi) == [67])
        let track = try #require(p.tracks.first { $0.id == id })
        #expect(p.buildSoloTrackPlan(track).synths.allSatisfy { $0.midi == 67 })
        let url = try #require(p.exportMIDIFile(loopBarsOverride: 1))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(MIDIImport.parse(url)?.map(\.pitch) == [67])
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(bytes.indices.dropLast(2).contains { bytes[$0] == 0x90 && bytes[$0 + 1] == 67 })
    }

    @Test @MainActor func layerRoutingAndFreezeKeepPanAndInstruments() throws {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        p.setPadParam("kick") { $0.layers = [PadLayer(sound: "clap", vol: 0.5, pitch: 3, pan: -0.2)] }
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        p.setTrackPan(id, 0.4)
        #expect(p.toggleTrackBus(id))
        let track = try #require(p.tracks.first { $0.id == id })
        let plan = p.buildExportPlan(loopBarsOverride: 1)
        #expect(Set(plan.drums.map(\.sound)) == ["kick", "clap"])
        #expect(plan.drums.allSatisfy { $0.busKey == id })
        #expect(abs((plan.drums.first { $0.sound == "clap" }?.opts.pan ?? 100) - 0.2) < 0.0001)
        let freeze = p.buildSoloTrackPlan(track)
        #expect(Set(freeze.drums.map(\.sound)) == ["kick", "clap"])
        #expect(freeze.drums.filter { $0.sound == "clap" }.allSatisfy { abs($0.opts.pan - 0.2) < 0.0001 })
    }

    @Test @MainActor func explicitMIDIExportModeIgnoresMonitorToggle() throws {
        let p = Project(engine: AudioEngine())
        p.songBars = 4; p.lanes = ["kick": [1]]
        p.sequences[1].lanes = ["snare": [1]]
        p.arrangement = [ArrItem(id: "verse", section: "verse", start: 0, len: 4, seq: 1)]
        p.songMode = false
        let song = try #require(p.exportMIDIFile(songModeOverride: true))
        defer { try? FileManager.default.removeItem(at: song.deletingLastPathComponent()) }
        #expect(MIDIImport.parse(song)?.map(\.pitch) == [38])
        _ = p.sendLanesToNewTrack(rows: ["kick", "snare"])
        p.songMode = true
        let loop = try #require(p.exportMIDIFile(loopBarsOverride: 1))
        defer { try? FileManager.default.removeItem(at: loop.deletingLastPathComponent()) }
        #expect(MIDIImport.parse(loop)?.map(\.pitch) == [36])
    }

    @Test @MainActor func sampledChokeAffectsBothMixAndStems() throws {
        let p = Project(engine: AudioEngine())
        var plan = p.buildExportPlan(loopBarsOverride: 1, safetyEnabled: false)
        let tone = (0..<12000).map { Float(sin(Double($0) * 0.07)) * 0.3 }
        plan.totalFrames = 14000; plan.master = 1
        plan.drums = [
            ExportDrum(sound: "smp:C:kick", vel: 1, opts: TriggerOpts(chokeGroup: 8), atSample: 0, sampleData: tone),
            ExportDrum(sound: "smp:C:sub808", vel: 1, opts: TriggerOpts(chokeGroup: 8), atSample: 2000, sampleData: [Float](repeating: 0, count: 64))
        ]
        plan.synths = []; plan.audioClips = []
        var open = plan
        for i in open.drums.indices { open.drums[i].opts.chokeGroup = 0 }
        func difference(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
        }
        #expect(difference(renderOffline(plan).0, renderOffline(open).0) > 0.01)
        let stems = renderStems(plan), openStems = renderStems(open)
        let a = try #require(stems.first { $0.name == "drums" })
        let b = try #require(openStems.first { $0.name == "drums" })
        #expect(difference(a.left, b.left) > 0.01)
        let voices = buildVoices(plan)
        #expect(voices.allSatisfy { $0 is SampleVoice && $0.chokeGroup == 8 })
    }
}
