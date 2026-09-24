import Foundation
import SwiftUI
import Testing
import FD808Engine
@testable import FB_808

// End-to-end model and renderer regressions for the September 24 workflow audit.
@Suite(.serialized)
struct WorkflowRegressionTests {
    @Test @MainActor func blankMeansNoDemoMusic() {
        let p = Project(engine: AudioEngine())
        p.startFromTemplate("blank")
        #expect(p.lanes.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(p.sequences.allSatisfy { $0.lanes.values.allSatisfy { $0.allSatisfy { $0 == 0 } } })
        #expect(p.arrangement.isEmpty)
        #expect(p.clips.values.allSatisfy { $0.isEmpty })
    }

    @Test @MainActor func newProjectClearsOldRecordingAndLaunchState() {
        let p = Project(engine: AudioEngine())
        p.recording = true
        p.audioArmedTrack = p.addTrack(.audio)
        p.queuedSeq = 2
        p.startFromTemplate("blank")
        #expect(!p.recording)
        #expect(p.audioArmedTrack == nil)
        #expect(p.queuedSeq == nil)
    }

    @Test @MainActor func separateSongsSaveAndReloadIndependently() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let p = Project(engine: AudioEngine())
        p.startFromTemplate("blank"); p.name = "Song One"
        p.setBpm(101); p.setStepVel("kick", 1, 0.31)
        let firstID = p.projectID
        #expect(await store.save(p.savePayload(), touchLastOpened: false))
        p.startFromTemplate("blank"); p.name = "Song Two"
        p.setBpm(137); p.setStepVel("kick", 1, 0.79)
        let secondID = p.projectID
        #expect(firstID != secondID)
        #expect(await store.save(p.savePayload(), touchLastOpened: false))
        await store.reload()
        #expect(store.items.count == 2)
        let first = try #require(ProjectStore.decodeSnapshot(dir.appendingPathComponent("Song One.fd808json")))
        let second = try #require(ProjectStore.decodeSnapshot(dir.appendingPathComponent("Song Two.fd808json")))
        p.restore(first)
        #expect(p.projectID == firstID && p.bpm == 101 && p.lanes["kick"]?[1] == 0.31)
        p.restore(second)
        #expect(p.projectID == secondID && p.bpm == 137 && p.lanes["kick"]?[1] == 0.79)
    }

    @Test @MainActor func arrangedSongCanExportWhileEditingEmptyPattern() throws {
        let p = Project(engine: AudioEngine())
        p.switchSequence(3)
        p.songMode = true
        #expect(!p.buildExportPlan().drums.isEmpty)
        #expect(p.hasExportableContent)
        p.arrangement = []  // unpinned clips still resolve to A outside any section
        #expect(!p.buildExportPlan().drums.isEmpty)
        #expect(p.hasExportableContent)
    }

    @Test @MainActor func groupMuteAndSoloAffectItsChildren() {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1] + Array(repeating: 0, count: 15)]
        let child = p.sendLanesToNewTrack(rows: ["kick"])
        let bus = p.addTrack(.bus)
        p.setTrackBusParent(child, bus)
        #expect(!p.buildExportPlan().drums.isEmpty)
        p.toggleTrackMute(bus)
        #expect(p.buildExportPlan().drums.isEmpty)
        p.toggleTrackMute(bus)
        p.toggleTrackSolo(bus)
        #expect(!p.buildExportPlan().drums.isEmpty)
    }

    @Test @MainActor func audioTrackFaderAffectsRecordedClip() throws {
        let p = Project(engine: AudioEngine())
        let id = p.addTrack(.audio)
        p.audioClips = [AudioClip(track: id, startBar: 0, data: [0.1, 0.2], wave: [], name: "Take", durSec: 2 / 48000)]
        let before = try #require(p.buildExportPlan().audioClips.first).gain
        p.setTrackVol(id, AudioDefaults.unityGain * 0.25)
        let after = try #require(p.buildExportPlan().audioClips.first).gain
        #expect(abs(after - before * 0.25) < 0.00001)
    }

    @Test @MainActor func seededTrackFaderAffectsItsDrums() throws {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1] + Array(repeating: 0, count: 15)]
        let before = try #require(p.buildExportPlan().drums.first).vel
        p.setTrackVol("drums", AudioDefaults.unityGain * 0.25)
        let after = try #require(p.buildExportPlan().drums.first).vel
        #expect(abs(after - before * 0.25) < 0.00001)
    }

    @Test @MainActor func addingAChordToneKeepsTheExistingPitch() {
        let p = Project(engine: AudioEngine())
        p.melody = [MelodyNote(step: 0, pitch: 60, dur: 4, vel: 0.8)]
        p.drawActiveNote(pitch: 64, start: 0, len: 4)
        #expect(Set(p.melody.map(\.pitch)) == Set([60, 64]))
    }

    @Test @MainActor func mappedPadRecordingRetainsTheMappedInstrument() throws {
        let p = Project(engine: AudioEngine())
        p.lanes = [:]; p.melody = []
        p.synthPatch.name = "Mapped Instrument"
        p.mapSynthToPads()
        let id = try #require(Kit.banks["D"]?.pads.first?.id)
        p.synthPatch.name = "Different Lead"
        p.recordSynthPad(id, 0)
        let plan = p.buildExportPlan()
        #expect(!plan.synths.isEmpty)
        #expect(plan.synths.allSatisfy { $0.patch.name == "Mapped Instrument" })
    }

    @Test @MainActor func soundFontSurvivesColdProjectReload() throws {
        let p = Project(engine: AudioEngine())
        #expect(p.loadSoundFont(FlowSF2Fixture.build(pitchCorrection: 0)) != nil)
        #expect(!p.engine.core.instrumentSources().regions.isEmpty)
        let saved = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(p.snapshot()))
        let reopened = Project(engine: AudioEngine())
        reopened.restore(saved)
        #expect(!reopened.engine.core.instrumentSources().regions.isEmpty)
        #expect(reopened.engine.core.instrumentSources().resolveSample(patch: reopened.editPatch, midi: 60, sampleRate: 48000) != nil)
    }

    @Test @MainActor func soundFontUndoRestoresThePreviousInstrument() throws {
        let p = Project(engine: AudioEngine())
        #expect(p.loadSoundFont(FlowSF2Fixture.build(pitchCorrection: 0)) != nil)
        let first = try #require(p.engine.core.instrumentSources().resolveSample(patch: p.editPatch, midi: 60, sampleRate: 48000)).rate
        #expect(p.loadSoundFont(FlowSF2Fixture.build(pitchCorrection: 100)) != nil)
        p.undo()
        let restored = try #require(p.engine.core.instrumentSources().resolveSample(patch: p.editPatch, midi: 60, sampleRate: 48000)).rate
        #expect(abs(first - restored) < 0.00001)
    }

    @Test @MainActor func deleteTimeRangeRemovesTakesThatStartInsideIt() {
        let p = Project(engine: AudioEngine())
        p.audioClips = [AudioClip(track: "audio", startBar: 3, data: [0.1], wave: [], name: "Inside deleted bars", durSec: 1 / 48000)]
        p.arrangeDeleteSpace(at: 2, len: 2)
        #expect(p.audioClips.isEmpty)
    }

    @Test @MainActor func loopExportDoesNotStackThePreviousTake() throws {
        let p = Project(engine: AudioEngine())
        p.lanes = [:]; p.melody = []; p.parts = []; p.bpm = 120
        let framesPerBar = Int(p.engine.sampleRate * 2)
        p.audioClips = [AudioClip(track: "audio", startBar: 0,
                                 data: Array(repeating: 0.1, count: framesPerBar * 2),
                                 wave: [], name: "Two bar take", durSec: 4)]
        let plan = p.buildExportPlan(loopBarsOverride: 2)
        let voices = buildVoices(plan).sorted { $0.startSample < $1.startSample }
        #expect(voices.count == 2)
        let first = try #require(voices.first)
        // Live calls stopClips() at the next bar. Its prior take must not still sound in the bounce.
        for _ in 0..<framesPerBar { _ = first.next(plan.sr) }
        #expect(first.finished || first.next(plan.sr) == 0)
    }

    @Test @MainActor func removingBusClearsChildRouting() {
        let p = Project(engine: AudioEngine())
        let one = p.addTrack(.bus)
        let two = p.addTrack(.bus)
        let child = p.sendLanesToNewTrack(rows: ["kick"])
        p.setTrackBusParent(child, one)
        p.removeTrack(one)
        #expect(p.tracks.first { $0.id == child }?.busParent == nil)
        #expect(p.busOrder.contains(two))
    }
    @Test @MainActor func staleLocalImportsDoNotReplaceTheNewDestination() {
        let p = Project(engine: AudioEngine())
        let old = p.operationDestination()
        p.startFromTemplate("blank")
        #expect(!p.commitSamplerImport(destination: old, data: [0.2], name: "Old sample"))
        #expect(p.sample == nil)
        let bank = p.operationDestination()
        p.bank = "B"
        #expect(!p.commitPadImport(destination: bank, padID: "kick", data: [0.2], name: "Old pad"))
        #expect(p.padSampleData.isEmpty)
    }

    @Test @MainActor func permissionResponseCannotStartCaptureAfterNewSong() {
        let p = Project(engine: AudioEngine())
        let owner = AudioEngine.MicOwner.sampler(p.projectID)
        var reply: ((Bool) -> Void)?
        var completed = false
        p.engine.startMicRecording(owner: owner, finish: {}, requestPermission: { reply = $0 }) { _ in completed = true }
        #expect(p.engine.micOwner == owner)
        p.engine.finishMicCapture(owner: .track(project: p.projectID, track: "audio"))
        #expect(p.engine.micOwner == owner, "Another capture destination cannot consume this request")
        p.startFromTemplate("blank")
        reply?(true)
        #expect(p.engine.micOwner == nil && !p.engine.isMicRecording && !completed)
    }

    @Test @MainActor func newSongCallsTransportStopAndResetsAllArms() {
        let p = Project(engine: AudioEngine())
        var stops = 0
        p.beforeProjectReplacement = { stops += 1 }
        p.playing = true; p.countingIn = true; p.midiArmed = true
        p.startFromTemplate("blank")
        #expect(stops == 1)
        #expect(!p.playing && !p.countingIn && !p.midiArmed)
    }

    @Test @MainActor func movingAndPlacingChordNotesPreservesOtherPitches() {
        let p = Project(engine: AudioEngine())
        p.melody = [MelodyNote(step: 0, pitch: 60, dur: 4, vel: 0.4), MelodyNote(step: 4, pitch: 64, dur: 4, vel: 0.8)]
        p.moveActiveNote(pitch: 60, from: 0, to: 4)
        #expect(Set(p.melody.map(\.pitch)) == [60, 64])
        #expect(p.melody.first { $0.pitch == 60 }?.vel == 0.4)
        p.placeMelodyNote(step: 4, pitch: 67, len: 4)
        #expect(Set(p.melody.map(\.pitch)) == [60, 64, 67])
        p.undo()
        #expect(Set(p.melody.map(\.pitch)) == [60, 64])
    }

    @Test @MainActor func keyboardRecordingKeepsVelocityAndHonorsCountIn() {
        let p = Project(engine: AudioEngine())
        p.melody = []; p.midiArmed = true; p.playing = true; p.countingIn = true
        p.playAndRecordNote("midi-1-60", midi: 60, velocity: 0.31, fraction: 0.25)
        #expect(p.melody.isEmpty)
        p.countingIn = false
        p.playAndRecordNote("midi-2-64", midi: 64, velocity: 0.31, fraction: 0.25)
        #expect(p.melody.count == 1 && p.melody[0].pitch == 64 && p.melody[0].step == 4)
        #expect(p.melody[0].vel == 0.31)
        p.assistPanic(); p.engine.allNotesOff()
    }

    @Test @MainActor func independentSoundFontsSurviveArchiveAndPresetRecall() async throws {
        let p = Project(engine: AudioEngine())
        p.loadSoundFont(FlowSF2Fixture.build(pitchCorrection: 0))
        let lead = p.editPatch
        p.addEmptyPart(name: "Second")
        p.loadSoundFont(FlowSF2Fixture.build(pitchCorrection: 100))
        let part = p.editPatch
        #expect(lead.instrumentID != part.instrumentID)
        let sources = p.engine.core.instrumentSources()
        let a = try #require(sources.resolveSample(patch: lead, midi: 60, sampleRate: 48000)).rate
        let b = try #require(sources.resolveSample(patch: part, midi: 60, sampleRate: 48000)).rate
        #expect(abs(b / a - pow(2, 100.0 / 1200)) < 1e-9)
        #expect(p.persistPresetInstrument(lead))
        let fontID = try #require(lead.instrumentID)
        defer { try? FileManager.default.removeItem(at: fd808DocsSubdir("FD808Instruments").appendingPathComponent(fontID + ".sf2")) }
        let another = Project(engine: AudioEngine())
        #expect(another.applyInstrumentPreset(lead))
        #expect(another.engine.core.instrumentSources().resolveSample(patch: lead, midi: 60, sampleRate: 48000) != nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let archive = try #require(await store.exportArchive(p.snapshot()))
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let restored = try #require(await store.importArchive(from: archive))
        another.restore(restored)
        #expect(another.soundFontAssets.count == 2)
        let restoredRate = try #require(another.engine.core.instrumentSources().resolveSample(patch: part, midi: 60, sampleRate: 48000)).rate
        #expect(abs(restoredRate - b) < 1e-9)
    }

    @Test @MainActor func trackAndGroupControlsReachMonoAndStereoPlans() throws {
        let p = Project(engine: AudioEngine())
        let track = p.addTrack(.audio), group = p.addTrack(.bus)
        p.setTrackBusParent(track, group)
        p.setTrackVol(group, AudioDefaults.unityGain * 0.5)
        p.setTrackPan(track, 1)
        p.audioClips = [AudioClip(track: track, startBar: 0, data: [0.5, 0.5], dataR: [0.25, 0.25], wave: [], name: "Stereo", durSec: 2 / p.engine.sampleRate)]
        let plan = p.buildExportPlan(loopBarsOverride: 1)
        let clip = try #require(plan.audioClips.first)
        #expect(clip.gain == 0.5 && clip.pan == 1 && plan.busOrder[clip.channel] == group)
        let voices = buildVoices(plan).compactMap { $0 as? AudioClipVoice }
        #expect(voices.first { $0.pan == -1 }?.gain == 0)
        #expect(voices.first { $0.pan == 1 }?.gain == 0.5)
        p.toggleTrackMute(group)
        #expect(p.buildExportPlan().audioClips.isEmpty)
        p.undo()
        #expect(!p.buildExportPlan().audioClips.isEmpty)
    }

    @Test @MainActor func freezeKeepsLevelAndPanAdjustableAfterReload() async throws {
        let p = Project(engine: AudioEngine())
        p.lanes = ["kick": [1]]
        let id = p.sendLanesToNewTrack(rows: ["kick"])
        p.setTrackVol(id, AudioDefaults.unityGain * 0.5); p.setTrackPan(id, 0.4)
        let before = p.tracks.first { $0.id == id }!
        let dry = p.buildSoloTrackPlan(before)
        p.setTrackVol(id, AudioDefaults.unityGain)
        #expect(dry.drums.map(\.vel) == p.buildSoloTrackPlan(p.tracks.first { $0.id == id }!).drums.map(\.vel))
        #expect(await p.freezeTrack(id, render: { _ in ([0.1, 0.2, 0.3], [0.3, 0.2, 0.1]) }))
        let ids = p.audioClips.map(\.id)
        defer { ids.forEach { deleteClipWAV(id: $0) } }
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(p.snapshot()))
        p.restore(snap)
        #expect(p.trackMix(id).pan == 0 && p.trackMix(id).gain == 1)
        p.setTrackVol(id, AudioDefaults.unityGain * 0.25)
        #expect(p.buildExportPlan().audioClips.first?.gain == 0.25)
        p.unfreezeTrack(id)
        #expect(p.audioClips.isEmpty && p.tracks.first { $0.id == id }?.playsAdditively == true)
    }

    @Test @MainActor func rangeDeletionSplitsStereoAndUndoRestoresItsOriginalAudio() throws {
        let p = Project(engine: AudioEngine())
        p.bpm = 120; p.barSteps = 4
        let frames = Int(p.engine.sampleRate / 2)
        let left = Array(repeating: Float(0.1), count: frames * 4)
        #expect(p.addAudioClip(track: "audio", startBar: 0, data: left, dataR: left.map { -$0 }, name: "Four bars"))
        let original = try #require(p.audioClips.first)
        p.songAutoTarget = "filter"; p.songAuto = (0..<16).map { Double($0) / 16 }
        let oldAuto = p.songAuto
        p.arrangeDeleteSpace(at: 1, len: 2)
        let newIDs = p.audioClips.map(\.id)
        defer { (newIDs + [original.id]).forEach { deleteClipWAV(id: $0) } }
        #expect(p.audioClips.count == 2)
        #expect(p.audioClips.map(\.startBar).sorted() == [0, 1])
        #expect(p.audioClips.allSatisfy { $0.data.count == frames && $0.dataR?.count == frames })
        #expect(p.songAuto[1] == oldAuto[3])
        p.undo()
        #expect(p.audioClips.count == 1 && p.audioClips[0].id == original.id)
        #expect(p.audioClips[0].data.count == frames * 4 && p.songAuto == oldAuto)
        p.redo()
        #expect(p.audioClips.count == 2 && p.audioClips.allSatisfy(\.isStereo))
    }

    @Test @MainActor func rangeDuplicateCopiesAudioAndAutomation() {
        let p = Project(engine: AudioEngine())
        p.bpm = 120; p.barSteps = 4
        let frames = Int(p.engine.sampleRate / 2)
        p.audioClips = [AudioClip(track: "audio", startBar: 1, data: Array(repeating: 0.2, count: frames), wave: [], name: "Bar", durSec: 0.5)]
        let original = p.audioClips[0].id
        p.songAutoTarget = "delay"; p.songAuto[1] = 0.4
        p.arrangeDuplicate(from: 1, len: 1)
        defer { p.audioClips.filter { $0.id != original }.forEach { deleteClipWAV(id: $0.id) } }
        #expect(p.audioClips.map(\.startBar).sorted() == [1, 2])
        #expect(p.songAuto[1] == 0.4 && p.songAuto[2] == 0.4)
    }

    @Test @MainActor func buildSongUsesCurrentPatternAndFitsItsTimelineInOneUndo() {
        let p = Project(engine: AudioEngine())
        p.startFromTemplate("blank"); p.switchSequence(3); p.setStepVel("kick", 0, 1)
        p.songBars = 4
        p.buildSong()
        #expect(p.songBars >= 16 && p.arrangement.allSatisfy { $0.seq == 3 })
        #expect(!p.buildExportPlan().drums.isEmpty)
        p.undo()
        #expect(p.songBars == 4 && p.arrangement.isEmpty)
    }

    @Test @MainActor func newTrackGetsAnEditableInstrumentSource() {
        let p = Project(engine: AudioEngine())
        let id = p.addTrack(.synthPart)
        p.chooseTrackSource(id, newPart: true)
        p.captureNote(pitch: 60, step: 0, velocity: 0.4)
        let track = p.tracks.first { $0.id == id }!
        #expect(track.isLinked && p.trackNotes(track, atBar: 0)?.0.first?.pitch == 60)
    }

    @Test @MainActor func unavailablePluginStateSurvivesSaveButNotNewSong() async throws {
        let p = Project(engine: AudioEngine())
        let effect = HostedEffectState(id: UUID(), name: "Missing test effect",
                                       // B2: nonzero, non-existent codes — 0 is a Core Audio wildcard, not "missing".
                                       type: 0x6175_6678 /* aufx */, subtype: 0x7A7A_7A7A, manufacturer: 0x4644_3858,
                                       state: Data([1, 2, 3]))
        var snap = p.snapshot(); snap.hostedEffects = [effect]
        p.restore(snap)
        await Task.yield()
        let saved = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(p.snapshot()))
        #expect(saved.hostedEffects == [effect])
        p.startFromTemplate("blank")
        await Task.yield()
        #expect(p.engine.masterChainSnapshot().isEmpty)
    }

    @Test @MainActor func recoveryHistoryKeepsThreeVersionsPerSong() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let p = Project(engine: AudioEngine())
        p.name = "First"
        for tempo in [100, 101, 102, 103] {
            p.bpm = tempo
            let payload = p.savePayload()
            await withCheckedContinuation { continuation in store.autosave(payload) { continuation.resume() } }
        }
        p.startFromTemplate("blank"); p.name = "Second"
        let payload = p.savePayload()
        await withCheckedContinuation { continuation in store.autosave(payload) { continuation.resume() } }
        await store.reloadRecoveries()
        #expect(store.recoveryItems.filter { $0.name == "First" }.count == 3)
        #expect(store.recoveryItems.filter { $0.name == "Second" }.count == 1)
        let versions = store.recoveryItems.filter { $0.name == "First" }.compactMap { ProjectStore.decodeSnapshot($0.url)?.bpm }
        #expect(Set(versions) == [101, 102, 103])
        await store.reload()
        #expect(store.items.isEmpty, "History must not masquerade as saved projects")
    }

    @Test func stereoImportPreservesChannelsAndMonoIsAnExplicitDownmix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let left = Array(repeating: Float(0.5), count: 1000), right = Array(repeating: Float(-0.25), count: 1000)
        let url = try writeAudio(.wav, left: left, right: right, sr: 48000, name: "Stereo", dir: dir).get()
        let stereo = try #require(SampleEngine.decodeChannels(url: url, targetSR: 48000, stereo: true))
        #expect(stereo.right?.count == 1000)
        #expect(abs(stereo.left[10] - 0.5) < 0.0001)
        #expect(abs(stereo.right![10] + 0.25) < 0.0001)
        let mono = try #require(SampleEngine.decodeChannels(url: url, targetSR: 48000, stereo: false))
        #expect(mono.right == nil)
        #expect(abs(mono.left[10] - 0.125) < 0.001)
    }

}

    private enum FlowSF2Fixture {
        static func build(pitchCorrection: Int8, coarseTune: Int = 0, fineTune: Int = 0,
                          rootKey: Int = 60, sampleFrames: Int = 256, sampleRate: Int = 48_000) -> Data {
            func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
            func u32(_ v: Int) -> Data {
                Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
            }
            func i16(_ v: Int) -> Data { u16(v & 0xFFFF) }
            func name20(_ s: String) -> Data {
                var d = Data(s.utf8.prefix(19)); d.append(Data(repeating: 0, count: 20 - d.count)); return d
            }
            func chunk(_ id: String, _ body: Data) -> Data {
                var d = Data(id.utf8); d.append(u32(body.count)); d.append(body)
                if body.count % 2 == 1 { d.append(0) }   // chunks are word-aligned
                return d
            }
            func list(_ form: String, _ body: Data) -> Data { chunk("LIST", Data(form.utf8) + body) }

            // sdta▸smpl — 16-bit mono PCM, a quiet tone so the zone is not silent.
            var smpl = Data()
            for i in 0..<sampleFrames {
                let v = Int((sin(Double(i) * 0.05) * 8000).rounded())
                smpl.append(i16(v))
            }

            // pdta▸shdr — one sample header (46 bytes).
            var shdr = name20("tone")
            shdr.append(u32(0))                     // start
            shdr.append(u32(sampleFrames))          // end
            shdr.append(u32(0))                     // loop start
            shdr.append(u32(sampleFrames))          // loop end
            shdr.append(u32(sampleRate))
            shdr.append(UInt8(rootKey & 0xFF))      // byOriginalPitch
            shdr.append(UInt8(bitPattern: pitchCorrection))
            shdr.append(u16(0))                     // sample link
            shdr.append(u16(1))                     // mono sample

            // pdta▸inst — instrument 0 (bag 0) + the terminal record.
            var inst = name20("inst"); inst.append(u16(0))
            inst.append(name20("EOI")); inst.append(u16(1))

            // pdta▸ibag — one real bag (gens 0..<4) + the terminal bag.
            var ibag = u16(0); ibag.append(u16(0))
            ibag.append(u16(4)); ibag.append(u16(0))

            // pdta▸igen — keyRange, coarseTune, fineTune, sampleID (the parser's terminal generator).
            var igen = Data()
            igen.append(u16(43)); igen.append(u16(0 | (127 << 8)))   // keyRange 0…127
            igen.append(u16(51)); igen.append(u16(coarseTune & 0xFFFF))
            igen.append(u16(52)); igen.append(u16(fineTune & 0xFFFF))
            igen.append(u16(53)); igen.append(u16(0))                // sampleID

            var pdtaBody = Data("pdta".utf8)
            pdtaBody.append(chunk("shdr", shdr))
            pdtaBody.append(chunk("inst", inst))
            pdtaBody.append(chunk("ibag", ibag))
            pdtaBody.append(chunk("igen", igen))
            let pdta = chunk("LIST", pdtaBody)
            let sdta = list("sdta", chunk("smpl", smpl))
            var body = Data("sfbk".utf8)
            body.append(pdta)
            body.append(sdta)
            return Data("RIFF".utf8) + u32(body.count) + body
        }
    }
