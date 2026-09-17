import Combine
import Foundation
import SwiftUI
import Testing
import FD808Engine
@testable import FB_808

@Suite(.serialized)
struct FB_808Tests {
    @Test @MainActor func delayedOperationRejectsChangedDestination() {
        let project = Project(engine: AudioEngine())
        let initial = project.operationDestination()
        #expect(initial.matches(project))
        project.bank = "B"
        #expect(!initial.matches(project))
        let bank = project.operationDestination()
        project.clearAll()
        #expect(!bank.matches(project))
        let revision = project.operationDestination()
        project.projectID = UUID().uuidString
        #expect(!revision.matches(project))
    }

    @Test @MainActor func exportPlanCapturesSampleSource() {
        let engine = AudioEngine()
        let project = Project(engine: engine)
        _ = engine.core.loadExternal([0, 0.25, -0.5, 0]); engine.core.sampleToSynth()
        var plan = project.buildExportPlan()
        let freeze = project.buildSoloTrackPlan(Track(id: "test", name: "Test", type: .synthPart, colorHex: "#FFFFFF"))
        #expect(freeze.instrumentSources.sample == [0, 0.25, -0.5, 0])
        _ = engine.core.loadExternal([1, 1]); engine.core.sampleToSynth()
        #expect(plan.instrumentSources.sample == [0, 0.25, -0.5, 0])
        var patch = SynthPatch(); patch.source = "sample"
        plan.drums = []; plan.audioClips = []
        plan.synths = [.init(patch: patch, midi: 60, dur: 1, vel: 1, atSample: 0)]
        #expect(buildVoices(plan).first is SampleSynthVoice)
    }

    @Test @MainActor func stalePreparedSamplesAreDiscardedWithoutChangingPads() async throws {
        let project = Project(engine: AudioEngine())
        let destination = project.operationDestination()
        let prepared = await Project.preparePadSamples([("kick", [0.1, -0.1, 0.2], "Old result")], sampleRate: 48000)
        let sample = try #require(prepared.first)
        defer { deletePadSampleWAV(file: sample.file) }
        #expect(readPadSampleWAV(file: sample.file) != nil)
        project.projectID = UUID().uuidString
        #expect(project.commitPreparedPadSamples(prepared, bank: destination.bank, destination: destination) == 0)
        #expect(project.padParams["kick"]?.sampleFile != sample.file)
        #expect(readPadSampleWAV(file: sample.file) == nil)
    }

    @Test @MainActor func kitDetailsIgnoreLatePreviousResponse() async throws {
        actor Replies {
            var pending: [String: CheckedContinuation<[KitStore.KitSample], Never>] = [:]
            func fetch(_ key: String) async -> [KitStore.KitSample] {
                await withCheckedContinuation { pending[key] = $0 }
            }
            func has(_ key: String) -> Bool { pending[key] != nil }
            func finish(_ key: String) {
                pending.removeValue(forKey: key)?.resume(returning: [.init(category: "Kicks", name: key, path: key)])
            }
        }
        let replies = Replies()
        let loader = KitDetailLoader { await replies.fetch($0.slug) }
        func kit(_ slug: String) throws -> KitStore.RemoteKit {
            try JSONDecoder().decode(KitStore.RemoteKit.self, from: Data("{\"slug\":\"\(slug)\",\"name\":\"\(slug)\"}".utf8))
        }
        loader.open(try kit("old"))
        let deadline = Date().addingTimeInterval(5)
        while !(await replies.has("old")), Date() < deadline { await Task.yield() }
        let oldStarted = await replies.has("old"); try #require(oldStarted)
        loader.open(try kit("new"))
        while !(await replies.has("new")), Date() < deadline { await Task.yield() }
        let newStarted = await replies.has("new"); try #require(newStarted)
        await replies.finish("new")
        while loader.loading, Date() < deadline { await Task.yield() }
        try #require(!loader.loading)
        await replies.finish("old")
        for _ in 0..<10 { await Task.yield() }
        #expect(loader.samples.map(\.name) == ["new"])
        #expect(loader.error == nil)
        loader.reset()
        #expect(loader.samples.isEmpty)
    }

    private func fixture() throws -> ProjectSnapshot {
        let json = #"""
        {"version":3,"name":"Original","bpm":120,"swing":0,"quantize":"16",
         "bank":"A","fullLevel":false,"lanes":{},"selectedRow":"kick",
         "rowMute":{},"rowSolo":{},"sequences":[],"activeSeq":0,"mixer":{},
         "arrangement":[],"clips":{},"trackMute":{},"trackSolo":{},"songMode":false,
         "melody":[],"melodyKey":0,"melodyScale":"major","melodyOctave":4,
         "melodyDensity":"medium","scaleLock":true,"rollLen":16,"synthPatch":{},
         "savedSynths":[],"padParams":{},"id":"test-project"}
        """#
        var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["synthPatch"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SynthPatch()))
        return try JSONDecoder().decode(ProjectSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test @MainActor func failedRenamePreservesOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("Original.fd808json")
        let snap = try fixture()
        #expect(ProjectStore.writeSnapshot(snap, to: original, pretty: false))
        // A directory at the destination forces the atomic file write to fail.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Blocked.fd808json"), withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir)
        let item = SavedProject(id: "Original", projectID: snap.id, name: snap.name, modified: .now, url: original)
        #expect(!store.rename(item, to: "Blocked", force: true))
        #expect(ProjectStore.decodeSnapshot(original)?.name == "Original")
    }

    @Test @MainActor func missingDeleteReportsFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(directory: dir)
        let item = SavedProject(id: "missing", name: "Missing", modified: .now, url: dir.appendingPathComponent("missing.fd808json"))
        #expect(!store.delete(item))
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func a15MemoryPolicyBoundsProcessingCost() {
        let tier = DeviceTier.forMemory(4 * 1_073_741_824)
        #expect(tier == .mid)
        #expect(tier.maximumVoices == 64)
        #expect(tier.sampleRate(96_000) == 48_000)
        #expect(tier.sampleRate(.nan) == 48_000)
        #expect(tier.automaticBufferFrames == 512)
        #expect(DeviceTier.forMemory(8 * 1_073_741_824).sampleRate(96_000) == 96_000)
    }

    @Test @MainActor func autosavesStayOrderedAndClearCannotBeUndoneByPendingWrite() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir)
        var snap = try fixture()
        for i in 0..<20 { snap.bpm = 100 + i; store.autosave(snap) }
        let latest = await store.autosaveSnapshot()
        #expect(latest?.bpm == 119)
        store.autosave(snap)
        store.clearAutosave()
        let cleared = await store.autosaveSnapshot()
        #expect(cleared == nil)
    }

    @Test @MainActor func samplerWriteFailureDoesNotPublishProject() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, sampleDirectory: dir.appendingPathComponent("missing"))
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "new.wav")
        let ok = await store.save(ProjectSavePayload(snapshot: snap, samplerAudio: [0.1, 0.2]))
        #expect(!ok)
        #expect(!store.exists(snap.name))
    }

    /// A save must never report success for a snapshot naming a recorded take whose WAV is not on disk:
    /// the in-memory PCM dies with the process, so "Saved." here would be a lie and the take unrecoverable
    /// after relaunch (#PERSIST-CLIP).
    @Test @MainActor func saveRefusesMissingClipWAVAndSucceedsOnceItExists() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("clips")
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        var snap = try fixture()
        let id = UUID()
        snap.audioClips = [AudioClipMeta(id: id.uuidString, track: "audio", startBar: 0,
                                         name: "Take", gain: 1, muted: false, durSec: 0.1)]
        #expect(await !store.save(ProjectSavePayload(snapshot: snap)))
        #expect(!store.exists(snap.name))
        // The same snapshot saves once its take really exists on disk.
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        #expect(writeWAVData([0.1, -0.2, 0.3], to: audio.appendingPathComponent("\(id.uuidString).wav")))
        #expect(await store.save(ProjectSavePayload(snapshot: snap)))
        #expect(store.exists(snap.name))
    }

    /// The same guard covers pad one-shots (snapshot.padParams[].sampleFile) and a stale sampler buffer
    /// reference — the two other audio assets a project can point at (#PERSIST-CLIP).
    @Test @MainActor func saveRefusesMissingPadSampleAndSamplerAssets() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        var padSnap = try fixture()
        var pad = PadParam()
        pad.sampleFile = "gone.wav"; pad.sampleName = "Kick one-shot"
        padSnap.padParams["kick"] = pad
        #expect(await !store.save(ProjectSavePayload(snapshot: padSnap)))
        #expect(!store.exists(padSnap.name))
        var samplerSnap = try fixture()
        samplerSnap.name = "Sampler Beat"
        samplerSnap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "gone.wav")
        #expect(await !store.save(ProjectSavePayload(snapshot: samplerSnap)))
        #expect(!store.exists(samplerSnap.name))
    }

    /// Mute-mode pad taps and "Unmute All" must checkpoint like the Sequence/Track mute controls: undoable,
    /// dirty, and one undo step for the batch — not a direct `rowMute` write (#MUTE-01).
    @Test @MainActor func rowMuteEditsAreUndoableAndMarkDirty() {
        let project = Project(engine: AudioEngine())
        project.markSaved()
        #expect(!project.hasUnsavedChanges)
        project.toggleRowMute("kick")
        #expect(project.rowMute["kick"] == true)
        #expect(project.hasUnsavedChanges)
        #expect(project.canUndo)
        project.undo()
        #expect(project.rowMute["kick"] ?? false == false)
        project.toggleRowMute("kick")
        project.toggleRowMute("snare")
        project.markSaved()
        #expect(!project.hasUnsavedChanges)
        project.unmuteAllRows()
        #expect(project.rowMute.values.allSatisfy { !$0 })
        #expect(project.hasUnsavedChanges)
        project.undo()   // one undo restores every row "Unmute All" cleared
        #expect(project.rowMute["kick"] == true && project.rowMute["snare"] == true)
        // A no-op Unmute All must not dirty a clean project or push an empty undo entry.
        project.unmuteAllRows()
        project.markSaved()
        let canUndoBefore = project.canUndo
        project.unmuteAllRows()
        #expect(!project.hasUnsavedChanges)
        #expect(project.canUndo == canUndoBefore)
    }

    /// The Free editor's window includes every pitch the part uses, and a note that has not been re-pitched
    /// writes back its true MIDI — not the pitch of the display row it was clamped onto. This is the
    /// open-the-editor-transposes-the-bass defect, reduced to its two pure rules (#FREEROLL-01).
    @Test @MainActor func freeRollRoundTripKeepsOutOfWindowPitches() {
        // Default window is C3…C6. The app's own Bass generator writes MIDI 36–47, so the window widens
        // down to the part's lowest note instead of clamping it onto row 1 of a fixed C3–C6 grid.
        let empty = FreeRollView.pitchWindow(for: [])
        #expect(empty.lo == 48 && empty.rows == 37)
        let bass = FreeRollView.pitchWindow(for: [36, 38, 43, 47])
        #expect(bass.lo == 36 && bass.rows == 49)
        let high = FreeRollView.pitchWindow(for: [90])
        #expect(high.lo == 48 && high.rows == 43)
        // MIDI 36 sits on row 1 and round-trips to 36 even if the window says 48 — the regression guard.
        #expect(FreeRollView.writeBackPitch(row: 1, trueRow: 1, trueMidi: 36, loMidi: 36) == 36)
        #expect(FreeRollView.writeBackPitch(row: 1, trueRow: 1, trueMidi: 36, loMidi: 48) == 36)
        // A note the user actually dragged to another row takes that row's pitch.
        #expect(FreeRollView.writeBackPitch(row: 5, trueRow: 1, trueMidi: 36, loMidi: 36) == 40)
        // A newly tapped note has no recorded truth and derives from its row.
        #expect(FreeRollView.writeBackPitch(row: 13, trueRow: nil, trueMidi: nil, loMidi: 48) == 60)
    }

    @Test @MainActor func samplerIsWrittenBeforeSuccessfulSave() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, sampleDirectory: dir)
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "new.wav")
        let ok = await store.save(ProjectSavePayload(snapshot: snap, samplerAudio: [0.1, 0.2], sampleRate: 44_100))
        #expect(ok)
        let saved = try #require(ProjectStore.decodeSnapshot(dir.appendingPathComponent("Original.fd808json")))
        let file = try #require(saved.sample?.audioFile)
        #expect(readWAVData(at: dir.appendingPathComponent(file))?.count == 2)
        #expect(try Data(contentsOf: dir.appendingPathComponent(file)).prefix(4) == Data("RIFF".utf8))
        #expect(await store.save(ProjectSavePayload(snapshot: snap, samplerAudio: [0.1, 0.2], sampleRate: 44_100)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }.count == 1)
    }

    @Test @MainActor func duplicatePreservesWAVBytesAndUsesIndependentFiles() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "source.wav")
        let source = dir.appendingPathComponent("source.wav")
        #expect(writeWAVData([0.1, -0.2, 0.3], to: source, sr: 44_100))
        let original = dir.appendingPathComponent("Original.fd808json")
        #expect(ProjectStore.writeSnapshot(snap, to: original, pretty: false))
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let item = SavedProject(id: "Original", projectID: snap.id, name: snap.name, modified: .now, url: original)
        #expect(await store.duplicate(item))
        let copy = try #require(ProjectStore.decodeSnapshot(dir.appendingPathComponent("Original copy.fd808json")))
        let file = try #require(copy.sample?.audioFile)
        #expect(file != "source.wav")
        #expect(copy.id != snap.id)
        #expect(try Data(contentsOf: source) == Data(contentsOf: dir.appendingPathComponent(file)))
    }

    @Test @MainActor func duplicateMissingAudioLeavesNoPartialProject() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "missing.wav")
        let original = dir.appendingPathComponent("Original.fd808json")
        #expect(ProjectStore.writeSnapshot(snap, to: original, pretty: false))
        let store = ProjectStore(directory: dir, sampleDirectory: dir)
        let item = SavedProject(id: "Original", projectID: snap.id, name: snap.name, modified: .now, url: original)
        #expect(await !store.duplicate(item))
        #expect(!store.exists("Original copy"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test @MainActor func midiRejectsOverlongVariableLengthField() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.mid")
        let header: [UInt8] = Array("MThd".utf8) + [0,0,0,6,0,0,0,1,1,224]
        let track: [UInt8] = Array("MTrk".utf8) + [0,0,0,6,255,255,255,255,255,0]
        try Data(header + track).write(to: url)
        #expect(MIDIImport.parse(url) == nil)
    }

    @Test @MainActor func midiUnicodeNameRoundTrip() throws {
        let project = Project(engine: AudioEngine())
        project.name = String(repeating: "é", count: 80)
        project.melody = [MelodyNote(step: 0, pitch: 60, dur: 2, vel: 0.8)]
        let url = try #require(project.exportMIDIFile())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let notes = try #require(MIDIImport.parse(url))
        #expect(notes.contains { $0.pitch == 60 && $0.step == 0 && $0.dur == 2 })
    }

    @Test @MainActor func recordQuantizationWrapsAndRejectsInvalidPositions() {
        for steps in [4, 8, 12, 16] {
            for quantize in ["1/8", "1/16", "1/32"] {
                for position in [-1.0, -0.1, 0, 0.2, 0.5, 0.999, 1, 1e100] {
                    let step = Project.quantizedStep(position, barSteps: steps, quantize: quantize)
                    #expect(step != nil && (0..<steps).contains(step!))
                    if quantize == "1/8" { #expect(step! % 2 == 0) }
                }
            }
        }
        #expect(Project.quantizedStep(1, barSteps: 16, quantize: "1/16") == 0)
        #expect(Project.quantizedStep(.nan, barSteps: 16, quantize: "1/16") == nil)
        #expect(Project.quantizedStep(.infinity, barSteps: 16, quantize: "1/16") == nil)
    }

    @Test @MainActor func snapshotRepairClampsInvalidSettings() throws {
        var snap = try fixture()
        snap.bpm = 9999; snap.barSteps = 99; snap.activePart = "missing"
        let repaired = ProjectStore().repaired(snap)
        #expect(repaired.bpm == 220)
        #expect(repaired.barSteps == 16)
        #expect(repaired.activePart == "lead")
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(repaired))
        #expect(decoded.id == snap.id)
        #expect(decoded.bpm == repaired.bpm)
    }

    @Test @MainActor func audioClipRemoveUndoRestoresAudio() throws {
        let project = Project(engine: AudioEngine())
        project.addAudioClip(track: "audio", startBar: 0, data: [0.1, -0.2, 0.3], name: "Regression take")
        let clip = try #require(project.audioClips.last)
        defer { deleteClipWAV(id: clip.id) }
        project.removeAudioClip(clip.id)
        #expect(!project.audioClips.contains { $0.id == clip.id })
        project.undo()
        #expect(project.audioClips.contains { $0.id == clip.id && !$0.data.isEmpty })
        #expect(readClipWAV(id: clip.id) != nil)
    }

    @Test @MainActor func archiveRejectsMissingAudioAndFutureVersion() throws {
        var snap = try fixture()
        snap.sample = SampleState(name: "Missing", kind: "mic", dur: 1, audioFile: "absent.wav")
        var archive = ProjectStore.ProjectArchive(snapshot: snap)
        #expect(ProjectStore.unpackArchive(try JSONEncoder().encode(archive)) == nil)
        archive.snapshot.sample = nil; archive.version = 999
        #expect(ProjectStore.unpackArchive(try JSONEncoder().encode(archive)) == nil)
    }

    @Test @MainActor func sustainPedalReleasesOnlyItsChannel() {
        let midi = MIDIManager()
        var released: [String] = []
        midi.onNoteOff = { note, channel in released.append("\(channel):\(note)") }
        midi.dispatch(.init(status: 0xB0, d1: 64, d2: 127))
        midi.dispatch(.init(status: 0x80, d1: 60, d2: 0))
        #expect(released.isEmpty)
        midi.dispatch(.init(status: 0x81, d1: 60, d2: 0))
        #expect(released == ["1:60"])
        midi.dispatch(.init(status: 0xB0, d1: 64, d2: 0))
        #expect(released == ["1:60", "0:60"])
    }

    @Test @MainActor func arrangementClipIdentitySurvivesRoundTrip() throws {
        let clip = Clip(s: 0, l: 2, color: .orange)
        let copy = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(copy.id == clip.id)
        let legacy = try JSONDecoder().decode(Clip.self, from: Data(##"{"s":0,"l":2,"color":"#FF8800"}"##.utf8))
        #expect(legacy.l == 2)
    }

    // MARK: - #15 frozen tracks must not double-trigger their source

    /// The suppression set every playback path (live Transport cache, WAV plan, .mid) is built from: a live
    /// link owns its rows/part, a frozen copy keeps owning what it captured (derived from the copy itself,
    /// so projects saved before this rule still don't double), and an empty new track owns nothing.
    @Test @MainActor func trackOwnershipTracksFreezeRelinkAndEmptyTracks() throws {
        let project = Project(engine: AudioEngine())
        project.lanes["kick"] = [0.9] + Array(repeating: 0.0, count: 15)
        project.lanes["snare"] = [0.0, 0.9] + Array(repeating: 0.0, count: 14)
        let id = project.sendLanesToNewTrack(rows: ["kick"])
        try #require(!id.isEmpty)
        let linked = try #require(project.tracks.first { $0.id == id })
        #expect(project.trackOwnership(linked).rows == ["kick"])            // live link owns its rows only
        #expect(project.freezeLinkToCopy(id))                              // detach a copy
        let frozen = try #require(project.tracks.first { $0.id == id })
        #expect(project.trackOwnership(frozen).rows == ["kick"])           // …and still owns them
        #expect(project.relinkTrack(id))
        let relinked = try #require(project.tracks.first { $0.id == id })
        #expect(project.trackOwnership(relinked).rows == ["kick"])
        // A freshly added, empty track owns nothing, so it can never silence the seeded lanes.
        let empty = project.addTrack(.drumPattern)
        let emptyTrack = try #require(project.tracks.first { $0.id == empty })
        #expect(project.trackOwnership(emptyTrack).isEmpty)
        // A promoted part owns the lead line (or its own part id).
        project.melody = [MelodyNote(step: 0, pitch: 60, dur: 2, vel: 0.8)]
        let partID = project.promotePartToTrack("lead")
        try #require(!partID.isEmpty)
        let promoted = try #require(project.tracks.first { $0.id == partID })
        #expect(project.trackOwnership(promoted).leadMelody)
        #expect(project.freezeLinkToCopy(partID))
        let frozenPart = try #require(project.tracks.first { $0.id == partID })
        #expect(project.trackOwnership(frozenPart).leadMelody)
    }

    /// Freezing a live-linked track to a copy must not make the source play a second time: the frozen copy
    /// still owns the rows it captured, so a "send to track → Freeze (detach copy)" pattern is heard once
    /// live, once in the WAV bounce, and once in the .mid.
    @Test @MainActor func frozenCopyStillSuppressesItsSourceInBounceAndMIDI() throws {
        let project = Project(engine: AudioEngine())
        project.lanes["kick"] = [0.9] + Array(repeating: 0.0, count: 15)
        let id = project.sendLanesToNewTrack(rows: ["kick"])
        try #require(!id.isEmpty)
        func kickCount() -> Int {
            project.buildExportPlan(loopBarsOverride: 1).drums.filter { $0.sound == "kick" }.count
        }
        #expect(kickCount() == 1)                       // live-linked: the source row is owned, not doubled
        #expect(project.freezeLinkToCopy(id))           // "Freeze (detach copy)"
        #expect(kickCount() == 1)                       // ← the frozen copy still owns the source row
        let url = try #require(project.exportMIDIFile())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let notes = try #require(MIDIImport.parse(url))
        #expect(notes.filter { $0.pitch == 36 }.count == 1)   // …and the .mid has one kick, not two
    }

    /// "Freeze to Audio" replaces a track's live synthesis with its bounce clip; the source rows it copied
    /// must stay suppressed for as long as the clip is what plays (they used to resume and double the clip).
    @Test @MainActor func freezeToAudioSuppressesTheLiveSourceItReplaces() throws {
        let project = Project(engine: AudioEngine())
        project.lanes["kick"] = [0.9] + Array(repeating: 0.0, count: 15)
        let id = project.sendLanesToNewTrack(rows: ["kick"])
        try #require(!id.isEmpty)
        let i = try #require(project.tracks.firstIndex { $0.id == id })
        project.tracks[i].frozenToAudio = true          // what freezeTrack() sets once its bounce landed
        project.audioClips.append(AudioClip(track: id, startBar: 0, data: [0.5, 0.5], wave: [], name: "frozen", durSec: 0.001))
        let plan = project.buildExportPlan(loopBarsOverride: 1)
        #expect(plan.drums.filter { $0.sound == "kick" }.isEmpty)   // live synthesis is replaced by the clip
        #expect(plan.audioClips.count == 1)                          // …which is what plays instead
    }

    // MARK: - #16 Loop-Mode clip scheduling

    /// Loop Mode loops ONE bar, so the arrangement bar never advances. Every clip must still sound (a take
    /// punched at bar > 0 used to never fire live), wrapped to the top of the loop, and the clip layer must
    /// restart each pass so a take longer than the loop cannot stack on itself.
    @Test @MainActor func loopModeWrapsEveryClipToTheLoopAndRestartsTheLayer() {
        let early = AudioClip(track: "audio", startBar: 0, data: [0.1], wave: [], name: "early", durSec: 1)
        let late = AudioClip(track: "audio", startBar: 2, data: [0.1], wave: [], name: "late", durSec: 1)
        let muted = AudioClip(track: "audio", startBar: 0, data: [0.1], wave: [], name: "muted", durSec: 1, muted: true)
        let song = Transport.audioClipsToFire([early, late, muted], atBar: 0, songMode: true)
        #expect(song.clips.map(\.name) == ["early"])                  // Song Mode: only this bar's clip
        #expect(!song.restart)                                        // …and the layer keeps running
        let loop = Transport.audioClipsToFire([early, late, muted], atBar: 0, songMode: false)
        #expect(loop.clips.map(\.name) == ["early", "late"])          // Loop Mode: wrapped to the loop top
        #expect(loop.restart)                                         // …restarted so nothing stacks
        #expect(Transport.audioClipsToFire([], atBar: 0, songMode: false).clips.isEmpty)
    }

    /// The BOUNCE must place clips exactly where live playback does. Live wraps every clip to the loop top
    /// in Loop Mode, so a take punched at bar > 0 has to be exported at sample 0. It used to be placed at
    /// its arrangement bar — and dropped entirely once that bar exceeded the loop length — so a beat
    /// approved in Loop Mode sounded wrong in the share: live and the WAV disagreed. (#16)
    @Test @MainActor func loopBouncePlacesEveryClipAtTheLoopTopLikeLivePlayback() throws {
        let project = Project(engine: AudioEngine())
        project.audioClips.append(AudioClip(track: "audio", startBar: 3, data: [0.5, 0.5],
                                            wave: [], name: "punch", durSec: 0.001))

        let loop = project.buildExportPlan(loopBarsOverride: 1)
        #expect(loop.audioClips.count == 1)            // not dropped for sitting past the 1-bar loop
        #expect(loop.audioClips.first?.atSample == 0)  // wrapped to the loop top, matching live

        // Song Mode still honours the arrangement position.
        let song = project.buildExportPlan(songModeOverride: true)
        let at = try #require(song.audioClips.first?.atSample)
        #expect(at > 0)
    }

    // MARK: - #17 mic-take alignment

    /// A take must be trimmed to the downbeat of the punch bar: the count-in still to elapse is part of the
    /// anchor, and when punching in over a running beat the remaining steps come from the scheduler's own
    /// (bar, step) grid — not from a hard-coded "punch bars from here".
    @Test @MainActor func micTakeAnchorIncludesCountInAndSchedulerGrid() {
        let sps = 0.125   // 120 BPM, 16 steps / bar
        // Stopped transport + 2-bar count-in: the grid starts 32 steps after nextStepTime.
        #expect(Transport.micAnchor(nextStepTime: 100, step16: 0, barCount: 0, countSteps: 32,
                                    barSteps: 16, songBars: 16, songMode: true, secPerStep: sps, targetBar: 0) == 104)
        // Already playing in Song Mode at bar 3 step 5 → bar 4's downbeat is 11 steps ahead, not 64.
        #expect(Transport.micAnchor(nextStepTime: 100, step16: 5, barCount: 3, countSteps: 0,
                                    barSteps: 16, songBars: 16, songMode: true, secPerStep: sps, targetBar: 4) == 101.375)
        // A punch bar that already passed wraps to the next pass instead of landing in the past.
        #expect(Transport.micAnchor(nextStepTime: 100, step16: 5, barCount: 6, countSteps: 0,
                                    barSteps: 16, songBars: 4, songMode: true, secPerStep: sps, targetBar: 1) == 100 + 43 * sps)
        // Loop Mode has no arrangement bar: PUNCH counts bars of count-in from the next loop top.
        #expect(Transport.micAnchor(nextStepTime: 100, step16: 5, barCount: 0, countSteps: 0,
                                    barSteps: 16, songBars: 16, songMode: false, secPerStep: sps, targetBar: 2) == 100 + 43 * sps)
    }

    // MARK: - #18 count-in propagation

    /// The host must not announce "playing" while it is still counting in: followers used to start the
    /// pattern 1-4 bars early and then be yanked back mid-bar by the heartbeat.
    @Test @MainActor func playIsAnnouncedOnlyAfterTheCountIn() {
        #expect(!Transport.shouldAnnouncePlay(countSteps: 32))
        #expect(!Transport.shouldAnnouncePlay(countSteps: 1))
        #expect(Transport.shouldAnnouncePlay(countSteps: 0))
    }

    // MARK: - #19 follower seek lead + cyclic drift

    /// A follower's seek target must include its own start lead (otherwise every late joiner and every
    /// post-seek follower sits 50-175 ms behind the teacher), and the drift guard must compare cyclically
    /// so a broadcast near the song end does not read as a song-length drift and force a restart.
    @Test @MainActor func followerSeekCompensatesLeadAndDriftCompareWraps() {
        let sps = 0.2   // 75 BPM, 16 steps / bar
        #expect(Transport.followerStartLead == 0.05)
        #expect(Transport.followerTargetStep(bar: 0, step: 0, elapsed: 0.28, secPerStep: sps,
                                             barSteps: 16, songBars: 16) == 2)   // 0.28 s + 0.05 lead → 1.65 steps
        // Follower on the last step of bar 15, teacher wrapped to bar 0 step 0 → one step apart, not a song.
        #expect(Transport.followerAction(playing: true, bar: 0, step: 0, localPlaying: true,
                                         localBar: 15, localStep: 15, barSteps: 16, songBars: 16) == .ignore)
        // A genuine mid-song drift still re-seeks.
        #expect(Transport.followerAction(playing: true, bar: 0, step: 0, localPlaying: true,
                                         localBar: 3, localStep: 0, barSteps: 16, songBars: 16) == .reseek(bar: 0, step: 0))
        #expect(Transport.followerAction(playing: false, bar: 0, step: 0, localPlaying: true,
                                         localBar: 3, localStep: 0, barSteps: 16, songBars: 16) == .stop)
        #expect(Transport.followerAction(playing: true, bar: 2, step: 4, localPlaying: false,
                                         localBar: 0, localStep: 0, barSteps: 16, songBars: 16) == .start(bar: 2, step: 4))
    }

    // MARK: - #20 Ableton Link enable flag + tempo precision

    /// Link's enable flag is the app-defaults key LinkKit's constructor reads; nothing in the app wrote it,
    /// so every Link path was dead code. The UI toggle must actually write it.
    @Test @MainActor func linkToggleWritesTheFlagLinkKitReads() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: LinkClock.enabledDefaultsKey)
        defaults.removeObject(forKey: LinkClock.enabledDefaultsKey)   // fresh install: nothing ever wrote it
        defer {
            if let prior { defaults.set(prior, forKey: LinkClock.enabledDefaultsKey) }
            else { defaults.removeObject(forKey: LinkClock.enabledDefaultsKey) }
        }
        #expect(LinkClock.enabledDefaultsKey == "ABLLinkEnabledKey")   // the key LinkKit's constructor reads
        #expect(!LinkClock.linkEnabled())
        let link = LinkClock(bpm: 120)
        #expect(!link.isOn)                        // ← shipped state: Link can never turn on
        link.setEnabled(true)                      // the Settings toggle's action
        #expect(LinkClock.linkEnabled())           // the persisted flag
        #expect(link.enabled)
        #expect(link.isOn)                         // ABLLinkIsEnabled — the gate on every Link path
    }

    /// The shared session tempo is a Double: following a 120.4 BPM session must not round it to 120 first.
    @Test @MainActor func linkSessionTempoStaysADouble() {
        #expect(Transport.stepDuration(bpm: 120, linkTempo: nil) == 0.125)
        let followed = Transport.stepDuration(bpm: 120, linkTempo: 120.4)
        #expect(followed != 0.125)
        #expect(abs(followed - (60.0 / 120.4) / 4) < 1e-12)
    }

    // MARK: - Finding 5: the Free editor's write-back must keep each note's own velocity

    /// Every grid write-back rebuilt the whole part from a step-keyed lookup that ignores pitch and returns
    /// only the first covering note: dragging a note to step 5 stored the step default (0.95 at step 4, 0.8
    /// at 5) instead of the velocity the user set in the VEL lane, chords were flattened to one value, and
    /// an untouched overlapping note could inherit a neighbour's velocity. Reduced to its pure policy.
    /// The SwiftUI wiring (`rebuild` filling the map, `pushBack` consulting it) is not executed by a test.
    @Test @MainActor func freeRollWriteBackKeepsEachNotesVelocity() {
        let movedID = UUID(), chordA = UUID(), chordB = UUID(), freshID = UUID()
        let velTruth: [UUID: Double] = [movedID: 0.4, chordA: 0.3, chordB: 0.9]
        // A note dragged to step 5: nothing covers step 5 in the pre-edit part, so the step lookup is 0 —
        // the shipped code wrote 0.8 here and lost the 0.4 the VEL lane had set.
        #expect(FreeRollView.writeBackVelocity(gridID: movedID, stepLookup: 0, velTruth: velTruth, step: 5) == 0.4)
        // A chord on one step keeps each note's own velocity, not whichever note the lookup returned first.
        #expect(FreeRollView.writeBackVelocity(gridID: chordA, stepLookup: 0.9, velTruth: velTruth, step: 4) == 0.3)
        #expect(FreeRollView.writeBackVelocity(gridID: chordB, stepLookup: 0.3, velTruth: velTruth, step: 4) == 0.9)
        // A genuinely new tap has no entry: the step lookup, then the historical step default.
        #expect(FreeRollView.writeBackVelocity(gridID: freshID, stepLookup: 0.62, velTruth: velTruth, step: 7) == 0.62)
        #expect(FreeRollView.writeBackVelocity(gridID: freshID, stepLookup: 0, velTruth: velTruth, step: 4) == 0.95)
        #expect(FreeRollView.writeBackVelocity(gridID: freshID, stepLookup: 0, velTruth: velTruth, step: 5) == 0.8)
        #expect(FreeRollView.defaultVelocity(step: 0) == 0.95 && FreeRollView.defaultVelocity(step: 1) == 0.8)
    }

    // MARK: - Finding 6: the Free editor must resync when the project's notes change from elsewhere

    /// Undo/Redo, "Clear this part" and a project load rewrite the part without changing `activePart`, so
    /// the grid kept the stale notes and wrote them back on the next touch. The fix resyncs whenever the
    /// grid no longer maps back to the project — but a self-inflicted write leaves the two signatures equal,
    /// so it can neither loop nor fight a live gesture. Reduced to its pure decision; the `.onChange`
    /// wiring itself is not executed by a test.
    @Test @MainActor func freeRollResyncsOnlyWhenTheProjectMoved() {
        let grid = [MelodyNote(step: 0, pitch: 60, dur: 2, vel: 0.8),
                    MelodyNote(step: 4, pitch: 64, dur: 1, vel: 0.4)]
        let gridSig = FreeRollView.contentSignature(grid)
        // Our own write: the project now holds exactly what the grid maps back to → no rebuild.
        #expect(!FreeRollView.needsResync(modelSig: gridSig, projectSig: FreeRollView.contentSignature(grid)))
        // "Clear this part", or an undo of the edit: the project no longer has the grid's notes.
        #expect(FreeRollView.needsResync(modelSig: gridSig, projectSig: FreeRollView.contentSignature([])))
        // An undo of an earlier edit left a different part than the grid shows.
        #expect(FreeRollView.needsResync(modelSig: gridSig,
                                         projectSig: FreeRollView.contentSignature([MelodyNote(step: 0, pitch: 60, dur: 2, vel: 0.8)])))
        // `replaceActiveNotes` sorts by step, so the project's order must not read as a change.
        let reordered = [grid[1], grid[0]]
        #expect(!FreeRollView.needsResync(modelSig: gridSig, projectSig: FreeRollView.contentSignature(reordered)))
        // A VEL-lane edit is a real change: the grid's velocity side map has to refresh with it.
        var bumped = grid; bumped[1].vel = 0.9
        #expect(FreeRollView.needsResync(modelSig: FreeRollView.voicedSignature(grid),
                                         projectSig: FreeRollView.voicedSignature(bumped)))
        #expect(!FreeRollView.needsResync(modelSig: FreeRollView.voicedSignature(grid),
                                          projectSig: FreeRollView.voicedSignature(grid)))
    }

    // MARK: - Finding 12: trim edits must be undoable/dirty, and a no-op snap must not write

    /// The waveform trim grip (drag, and the VoiceOver adjustable action) wrote `project.sample` bare: the
    /// trim moved but `hasUnsavedChanges` stayed false, so autosave/recovery never captured it and one Undo
    /// reverted an unrelated earlier edit. The grip's `minimumDistance: 0` also means a plain tap runs the
    /// zero-crossing snap, which used to rewrite the sample even when the edge did not move. Pure decisions;
    /// the gesture wiring itself is not executed by a test.
    @Test @MainActor func sampleTrimWriteBackCheckpointsOnceAndSkipsNoOpSnaps() {
        // No drag open yet → this write starts one (one undo step per drag; the first frame owns it).
        #expect(SampleModeView.trimNeedsCheckpoint(orig: nil))
        #expect(!SampleModeView.trimNeedsCheckpoint(orig: 0.25))
        // A snap that does not move the edge must not rewrite project.sample.
        #expect(SampleModeView.snappedTrim(side: "l", snapped: 0.25, current: [0.25, 1.0]) == nil)
        #expect(SampleModeView.snappedTrim(side: "r", snapped: 0.75, current: [0.0, 0.75]) == nil)
        // A real snap still writes, clamped inside the opposite edge.
        func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        #expect(close(SampleModeView.snappedTrim(side: "l", snapped: 0.30, current: [0.25, 0.9]), 0.30))
        #expect(close(SampleModeView.snappedTrim(side: "l", snapped: 0.95, current: [0.25, 0.9]), 0.88))
        #expect(close(SampleModeView.snappedTrim(side: "r", snapped: 0.10, current: [0.25, 0.9]), 0.27))
    }

    /// The trim handle uses `minimumDistance: 0`, so a plain TAP fires `onChanged` once with zero
    /// translation. That frame must be a complete no-op: no checkpoint, no dirty flag, no undo entry.
    /// Checking in on the drag's first FRAME rather than its first MOVE marked the project dirty and
    /// burned redo history on a tap that changed nothing — the defect of finding 40. (#TRIM-UNDO)
    @Test @MainActor func trimTapDoesNotDirtyTheProjectButTheFirstMoveDoes() {
        #expect(!SampleModeView.trimFrameShouldApply(moved: false, dragOpen: false))  // the tap frame
        #expect(SampleModeView.trimFrameShouldApply(moved: true, dragOpen: false))    // first real move
        // Later frames always apply — one that nets back to the current value must still write — and
        // `trimNeedsCheckpoint` is what keeps them from opening a second undo step.
        #expect(SampleModeView.trimFrameShouldApply(moved: false, dragOpen: true))
        #expect(SampleModeView.trimFrameShouldApply(moved: true, dragOpen: true))
        #expect(SampleModeView.trimNeedsCheckpoint(orig: nil))       // first frame of the drag
        #expect(!SampleModeView.trimNeedsCheckpoint(orig: 0.25))     // every later frame
    }

    // MARK: - Persistence / project-library wave: findings 32, 33, 34, 35, 62, 63, 64

    /// Spin the main actor until `condition` holds. The store queues its disk work on a utility queue, so a
    /// test observes the result instead of assuming an async side effect already happened. The generous
    /// timeout keeps it honest on a machine running other suites (it only costs time on a genuine failure).
    @MainActor private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// #32: deleting a beat is the action the UI tells a full-disk user to take, but `delete` never swept
    /// its audio — the bytes came back only at a later launch, and only if every other project file
    /// decoded. Worse, ONE unreadable file aborted the whole sweep (`return`), so a single bad save
    /// disabled reclamation for the entire library. Delete must reclaim the beat's now-unreferenced WAVs
    /// immediately, keep the WAVs another project still names, and tolerate the corrupt sibling.
    @Test @MainActor func deletingAProjectReclaimsItsAudioEvenWithACorruptSibling() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        var snap = try fixture(); snap.id = "id-good"
        let goodURL = dir.appendingPathComponent("Good.fd808json")
        #expect(ProjectStore.writeSnapshot(snap, to: goodURL, pretty: false))
        // A SECOND saved beat whose take must survive the deleted beat's cleanup.
        let otherID = UUID()
        var other = try fixture(); other.id = "id-other"; other.name = "Other"
        other.audioClips = [AudioClipMeta(id: otherID.uuidString, track: "audio", startBar: 0,
                                          name: "Other Take", gain: 1, muted: false, durSec: 0.1)]
        #expect(ProjectStore.writeSnapshot(other, to: dir.appendingPathComponent("Other.fd808json"), pretty: false))
        try Data("this is not a project".utf8).write(to: dir.appendingPathComponent("Corrupt.fd808json"))
        let keep = audio.appendingPathComponent("\(otherID.uuidString).wav")
        let orphan = audio.appendingPathComponent("orphan.wav")
        #expect(writeWAVData([0.1, -0.2], to: keep))
        #expect(writeWAVData([0.3], to: orphan))
        // The 24h grace is what lets an unreferenced WAV survive for a live undo stack; both files are old,
        // so only the keep/reference rule (not the age rule) can decide their fate here.
        for f in [keep, orphan] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: f.path)
        }
        await store.reload()
        let item = try #require(store.items.first { $0.projectID == "id-good" })
        #expect(store.delete(item))
        #expect(!FileManager.default.fileExists(atPath: goodURL.path))
        await waitUntil { !FileManager.default.fileExists(atPath: orphan.path) }
        #expect(!FileManager.default.fileExists(atPath: orphan.path))     // freed by the delete, not "next launch"
        #expect(FileManager.default.fileExists(atPath: keep.path))        // the corrupt sibling must not disable GC
    }

    /// #32 companion: the launch sweep's 24h grace is load-bearing (undo restores a removed clip by
    /// re-reading its WAV), so the fix must not turn the launch sweep into an immediate one.
    @Test @MainActor func launchSweepKeepsRecentOrphansForInSessionUndo() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        let fresh = audio.appendingPathComponent("fresh-orphan.wav")
        #expect(writeWAVData([0.1, -0.2], to: fresh))
        store.sweepOrphanWAVs()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// #32: the recovery slot writes a content-addressed sampler WAV; dropping the slot left that WAV
    /// behind forever (nothing else references it).
    @Test @MainActor func clearingTheRecoverySlotReclaimsItsSamplerAudio() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = dir.appendingPathComponent("samples")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: samples)
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "pending.wav")
        store.autosave(ProjectSavePayload(snapshot: snap, samplerAudio: [0.1, 0.2], sampleRate: 44_100))
        _ = await store.autosaveSnapshot()   // barrier: the slot and its sampler WAV are on disk
        #expect((try? FileManager.default.contentsOfDirectory(atPath: samples.path))?.count == 1)
        store.clearAutosave()
        await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: samples.path))?.isEmpty == true }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: samples.path))?.isEmpty == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasSuffix(".fd808json") } != true)
    }

    /// #33: importArchive saves through `save`, which rewrote the "last opened" keys — so relaunching after
    /// an import opened someone else's shared beat instead of the beat the user was working on, even though
    /// the success alert promises "Your current beat is still open."
    @Test @MainActor func importingABeatDoesNotStealTheLastOpenedKeys() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let previousName = store.lastProjectName, previousID = store.lastProjectID
        defer { store.lastProjectName = previousName; store.lastProjectID = previousID }
        store.lastProjectName = "My Beat"
        store.lastProjectID = "open-beat-id"
        var shared = try fixture(); shared.id = "archive-id"; shared.name = "Shared Beat"
        let url = dir.appendingPathComponent("Shared.fd808")
        try JSONEncoder().encode(ProjectStore.ProjectArchive(snapshot: shared)).write(to: url)
        let imported = await store.importArchive(from: url)
        #expect(imported?.name == "Shared Beat")
        #expect(store.exists("Shared Beat"))
        #expect(store.lastProjectID == "open-beat-id")   // importing is not "opening"
        #expect(store.lastProjectName == "My Beat")
    }

    /// #34: 'Discard & Open' / Delete left the recovery slot alone, so the edits the user explicitly threw
    /// away were offered back at the next launch and "Recover" could overwrite the beat just opened. A slot
    /// belonging to the deleted beat must die with it; a slot belonging to a DIFFERENT (open) beat must not.
    @Test @MainActor func deleteDropsTheRecoverySlotOnlyForTheDeletedBeat() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        var a = try fixture(); a.id = "id-A"; a.name = "A"
        var b = try fixture(); b.id = "id-B"; b.name = "B"
        #expect(ProjectStore.writeSnapshot(a, to: dir.appendingPathComponent("A.fd808json"), pretty: false))
        #expect(ProjectStore.writeSnapshot(b, to: dir.appendingPathComponent("B.fd808json"), pretty: false))
        await store.reload()
        let itemA = try #require(store.items.first { $0.projectID == "id-A" })
        let itemB = try #require(store.items.first { $0.projectID == "id-B" })
        store.autosave(b)
        #expect(await store.autosaveSnapshot() != nil)          // barrier: B's recovery slot is on disk
        #expect(store.delete(itemA))
        #expect(await store.autosaveSnapshot() != nil)          // A's delete must not touch B's recovery slot
        #expect(store.delete(itemB))
        #expect(await store.autosaveSnapshot() == nil)          // the deleted beat's slot dies with it
    }

    /// #35: the integrity check looked only at `<id>.wav`, so a stereo take whose right file was gone (an
    /// interrupted write or import) loaded as a silent mono clip with no warning. Built through JSON so the
    /// stereo flag travels exactly as a real save writes it.
    @Test @MainActor func missingStereoRightChannelIsReportedAndRepaired() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let id = UUID()
        #expect(writeWAVData([0.1, -0.2, 0.3], to: audio.appendingPathComponent("\(id.uuidString).wav")))
        var snap = try fixture()
        let meta = """
        {"id":"\(id.uuidString)","track":"audio","startBar":0,"name":"Stereo Take","gain":1,\
        "muted":false,"durSec":0.1,"isStereo":true}
        """
        snap.audioClips = [try JSONDecoder().decode(AudioClipMeta.self, from: Data(meta.utf8))]
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        // Left channel present → the old check reported the project intact while it played back as mono.
        #expect(store.missingAudioAssets(in: snap).contains { $0.contains("right channel") })
        let repaired = try #require(store.repaired(snap).audioClips?.first)
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(repaired)) as? [String: Any]
        #expect(fields?["isStereo"] as? Bool == false)           // degraded to a real mono take, not a phantom stereo
        #expect(store.lastRepairs.contains { $0.contains("right channel") })
    }

    /// #62: the filename is the sanitized name + ".fd808json" and nothing clamped it, so a long pasted name
    /// made every Save fail with ENAMETOOLONG, which the UI reported as a storage problem the user could not
    /// act on. The stem must be cut to the filesystem's 255-byte component budget — on a Character boundary.
    @Test @MainActor func overlongProjectNamesSaveInsteadOfFailingAsStorageErrors() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        var ascii = try fixture()
        ascii.name = String(repeating: "a", count: 300)
        ascii.id = "long-ascii"
        #expect(await store.save(ProjectSavePayload(snapshot: ascii)))   // before: ENAMETOOLONG → false
        #expect(store.exists(ascii.name))
        var multibyte = try fixture()
        multibyte.name = String(repeating: "é", count: 300)             // 2 UTF-8 bytes per Character
        multibyte.id = "long-multibyte"
        #expect(await store.save(ProjectSavePayload(snapshot: multibyte)))
        #expect(store.exists(multibyte.name))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".fd808json") }
        #expect(files.count == 2)
        // APFS on macOS is normalization-insensitive and stores NFD, which inflates a multi-byte name's
        // byte count on disk; the budget the fix must meet is on the name as written (NFC).
        let overBudget = files.filter { $0.precomposedStringWithCanonicalMapping.utf8.count > 255 }
        #expect(overBudget.isEmpty, "over the 255-byte component budget: \(overBudget.map { ($0, $0.utf8.count) })")
        let asciiFile = try #require(files.first { $0.hasPrefix("aaa") })
        #expect(asciiFile.utf8.count == 255)     // the full 245-byte stem budget, + "." + "fd808json"
        // The name the user typed is preserved in full inside the file; only the filename was shortened.
        for f in files {
            let saved = try #require(ProjectStore.decodeSnapshot(dir.appendingPathComponent(f)))
            #expect(saved.name.count == 300)
        }
    }

    /// #63: the periodic recovery write only logged on failure. On a full disk the safety net silently
    /// stopped protecting unsaved work, and a crash/OOM then lost the whole session with no warning.
    @Test @MainActor func recoveryWriteFailureIsSurfacedAndClearsOnSuccess() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        var snap = try fixture()
        snap.sample = SampleState(name: "Take", kind: "mic", dur: 0.1, audioFile: "pending.wav")
        let payload = ProjectSavePayload(snapshot: snap, samplerAudio: [0.1, 0.2], sampleRate: 44_100)
        #expect(!store.recoveryWriteFailed)
        // A directory where the recovery file belongs forces the atomic write to fail (same trick as the
        // rename regression test).
        let slot = dir.appendingPathComponent("__autosave__.fd808json")
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        store.autosave(payload)
        await waitUntil { store.recoveryWriteFailed }
        #expect(store.recoveryWriteFailed)
        try FileManager.default.removeItem(at: slot)
        store.autosave(payload)
        await waitUntil { !store.recoveryWriteFailed }
        #expect(!store.recoveryWriteFailed)     // the next success clears the warning
        #expect(await store.autosaveSnapshot() != nil)
    }

    /// #64: the overwrite guard full-read and fully decoded the target project on the main thread, even
    /// though the scanned list already holds its embedded id — a hitch proportional to the whole file on
    /// every body invalidation while the typed name matched an existing save.
    @Test @MainActor func overwriteGuardUsesTheScannedIdentityWithoutFullDecode() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let snap = try fixture()
        let url = dir.appendingPathComponent("Original.fd808json")
        #expect(ProjectStore.writeSnapshot(snap, to: url, pretty: false))
        await store.reload()
        #expect(store.items.first?.projectID == "test-project")
        // The scanned list already knows the identity. Once the file can no longer be fully decoded, the
        // guard must still answer from that cached identity instead of falling back to "confirm".
        try Data("not json".utf8).write(to: url)
        #expect(!store.wouldOverwriteDifferentProject(name: "Original", openID: "test-project"))
        #expect(store.wouldOverwriteDifferentProject(name: "Original", openID: "someone-else"))
        // With no scanned list the same unreadable file is still reported as "confirm" (safe default).
        let cold = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        #expect(cold.wouldOverwriteDifferentProject(name: "Original", openID: "test-project"))
    }

    // MARK: - Finding 46: a mid-playback time-signature change must still fire the bar line

    /// The bar line is the wrap out of the last step of the bar. `barSteps` is re-read every tick, so
    /// changing the signature mid-bar left `prev` on the OLD grid: 4/4 → 3/4 at step 12..15 wraps without
    /// prev ever equalling n-1 = 11 (barCount/project.bar/the Song-Mode clip gate/condPass all stalled a
    /// bar), and 3/4 → 4/4 played four extra steps before the line. The fix realigns on the new downbeat.
    @Test @MainActor func barLineSurvivesAMidPlaybackTimeSignatureChange() {
        // Steady grids are unchanged: the line is the wrap from the last step.
        #expect(Transport.advanceStep(step16: 0, prevBarSteps: 16, barSteps: 16) == StepAdvance(step: 1, barLine: false))
        #expect(Transport.advanceStep(step16: 15, prevBarSteps: 16, barSteps: 16) == StepAdvance(step: 0, barLine: true))
        #expect(Transport.advanceStep(step16: 11, prevBarSteps: 12, barSteps: 12) == StepAdvance(step: 0, barLine: true))
        #expect(Transport.advanceStep(step16: 7, prevBarSteps: 8, barSteps: 8) == StepAdvance(step: 0, barLine: true))
        // 4/4 → 3/4 with step16 already past the new bar length: without the realign `prev` can never
        // reach n-1 again, so this wrap is silently NOT a bar line and the counters stall for a bar.
        #expect(Transport.advanceStep(step16: 12, prevBarSteps: 16, barSteps: 12) == StepAdvance(step: 0, barLine: true))
        #expect(Transport.advanceStep(step16: 15, prevBarSteps: 16, barSteps: 12) == StepAdvance(step: 0, barLine: true))
        // 3/4 → 4/4 at step 12: the shipped predicate keeps counting 12,13,14,15 before wrapping.
        #expect(Transport.advanceStep(step16: 12, prevBarSteps: 12, barSteps: 16) == StepAdvance(step: 0, barLine: true))
        // 2/4 → 3/4 from step 4 likewise.
        #expect(Transport.advanceStep(step16: 4, prevBarSteps: 8, barSteps: 12) == StepAdvance(step: 0, barLine: true))
        // A change that lands exactly ON a downbeat needs no realign: that wrap already fired under the old
        // length, so the new bar must simply continue — no second bar line, no repeated step 0.
        #expect(Transport.advanceStep(step16: 0, prevBarSteps: 16, barSteps: 12) == StepAdvance(step: 1, barLine: false))
        #expect(Transport.advanceStep(step16: 0, prevBarSteps: 12, barSteps: 16) == StepAdvance(step: 1, barLine: false))
    }

    // MARK: - Finding 47: the 6 s resync must be a no-op when nothing changed and reuse decoded audio

    /// The host re-broadcast the whole project every 6 s and every follower re-applied it through
    /// `restore()` — re-decoding every clip/pad WAV on the main actor and clearing undo — even when nothing
    /// had changed. The heartbeat must skip an unchanged revision (join/reconnect/Rejoin still force one),
    /// and a restore must decode only what it does not already hold.
    @Test @MainActor func fullSyncIsSkippedWhenNothingChangedAndOnlyNewAudioIsDecoded() {
        #expect(SessionStore.shouldSendFullSync(force: false, revision: 7, lastSentRevision: nil))   // first send
        #expect(!SessionStore.shouldSendFullSync(force: false, revision: 7, lastSentRevision: 7))    // nothing changed
        #expect(SessionStore.shouldSendFullSync(force: false, revision: 8, lastSentRevision: 7))     // a real edit
        #expect(SessionStore.shouldSendFullSync(force: true, revision: 7, lastSentRevision: 7))      // join / Rejoin

        let a = UUID(), b = UUID()
        func meta(_ id: UUID) -> AudioClipMeta {
            AudioClipMeta(id: id.uuidString, track: "audio", startBar: 0, name: "Take", gain: 1, muted: false, durSec: 1)
        }
        let metas = [meta(a), meta(b)]
        #expect(Project.clipIDsNeedingDecode(metas, cached: [a, b]).isEmpty)   // every take already decoded
        #expect(Project.clipIDsNeedingDecode(metas, cached: [a]) == [b])
        #expect(Project.clipIDsNeedingDecode(metas, cached: []).count == 2)
        #expect(!Project.padSamplesNeedReload(decoded: ["kick": "k.wav"], live: ["kick": "k.wav"]))
        #expect(Project.padSamplesNeedReload(decoded: ["kick": "k.wav"], live: ["kick": "k2.wav"]))
        #expect(Project.padSamplesNeedReload(decoded: [:], live: ["kick": "k.wav"]))
        #expect(!Project.samplerNeedsReload(file: "take.wav", decoded: "take.wav"))
        #expect(Project.samplerNeedsReload(file: "take.wav", decoded: nil))
        #expect(Project.samplerNeedsReload(file: nil, decoded: "take.wav"))
        // The heartbeat's change detector hashes the SNAPSHOT: identical state must hash identically (so the
        // skip fires) and a real edit must move it — including swing/groove/time-signature, which are
        // @Published edits that never bump editRevision and whose only live carrier IS fullSync.
        let project = Project(engine: AudioEngine())
        let before = SessionStore.snapshotFingerprint(project.snapshot())
        #expect(SessionStore.snapshotFingerprint(project.snapshot()) == before)
        project.swing = 0.25
        let afterSwing = SessionStore.snapshotFingerprint(project.snapshot())
        #expect(afterSwing != before)
        project.barSteps = 12
        #expect(SessionStore.snapshotFingerprint(project.snapshot()) != afterSwing)
    }

    /// A restore of state the session already holds must not reach for the WAVs. Before the fix the
    /// follower's fullSync path re-read every take, so a clip whose file was gone (swept, or on the
    /// teacher's device only) was dropped from the live project even though its audio was in memory.
    @Test @MainActor func restoringTheSameSnapshotReusesDecodedAudio() throws {
        let project = Project(engine: AudioEngine())
        #expect(project.addAudioClip(track: "audio", startBar: 0, data: [0.1, -0.2, 0.3], name: "Take"))
        let clip = try #require(project.audioClips.last)
        let snap = project.snapshot()
        deleteClipWAV(id: clip.id)
        project.restore(snap)
        #expect(project.audioClips.count == 1)                       // ← shipped: re-read failed, take dropped
        #expect(project.audioClips.first?.data == [0.1, -0.2, 0.3])  // the decoded buffer is reused
    }

    /// Same rule for imported pad one-shots: an unchanged `sampleFile` must keep the engine's buffer.
    @Test @MainActor func restoringTheSameSnapshotKeepsDecodedPadSamples() throws {
        let project = Project(engine: AudioEngine())
        project.setPadSample("kick", data: [0.1, 0.2], name: "One", bank: nil)
        let file = try #require(project.padParams["kick"]?.sampleFile)
        let snap = project.snapshot()
        deletePadSampleWAV(file: file)   // the file is gone, but its audio is still decoded in memory
        project.restore(snap)
        #expect(project.padSampleData["kick"] == [0.1, 0.2])   // ← shipped: re-read failed, sample lost
    }

    // MARK: - Finding 48: a stall longer than the lookahead must not flam the backlog

    /// The scheduler has no backlog branch: after a main-thread stall it walks the counter forward and
    /// fires every missed step at now+1 ms, so at 120 BPM a 1 s stall releases half a bar on one sample.
    /// The fix fast-forwards to the current grid position without scheduling the missed steps.
    @Test @MainActor func aStalledSchedulerFastForwardsInsteadOfFlammingTheBacklog() {
        let sps = 0.125   // 120 BPM, 16 steps / bar
        // Within the lookahead, or less than one whole step behind: nothing to skip — the late step plays.
        #expect(Transport.catchUpSteps(behind: 0.01, secPerStep: sps, step16: 3, barCount: 2, countSteps: 0,
                                       barSteps: 16, songMode: true, songBars: 16, threshold: 0.025) == nil)
        #expect(Transport.catchUpSteps(behind: 0.05, secPerStep: sps, step16: 3, barCount: 2, countSteps: 0,
                                       barSteps: 16, songMode: true, songBars: 16, threshold: 0.025) == nil)
        // A 1 s stall = 8 missed 16ths: skip them and land on the grid (step 12 + 8 → bar +1, step 4).
        let c = Transport.catchUpSteps(behind: 1.0, secPerStep: sps, step16: 12, barCount: 2, countSteps: 0,
                                       barSteps: 16, songMode: true, songBars: 16, threshold: 0.025)
        #expect(c == CatchUp(steps: 8, step16: 4, barCount: 3, countSteps: 0))
        // Loop Mode pins the arrangement bar, exactly like advance().
        #expect(Transport.catchUpSteps(behind: 1.0, secPerStep: sps, step16: 12, barCount: 0, countSteps: 0,
                                       barSteps: 16, songMode: false, songBars: 16, threshold: 0.025)
                == CatchUp(steps: 8, step16: 4, barCount: 0, countSteps: 0))
        // A stall during the count-in consumes count-in steps instead of stretching the click track.
        #expect(Transport.catchUpSteps(behind: 0.5, secPerStep: sps, step16: 0, barCount: 0, countSteps: 32,
                                       barSteps: 16, songMode: false, songBars: 16, threshold: 0.025)
                == CatchUp(steps: 4, step16: 4, barCount: 0, countSteps: 28))
        // 3/4 (12 steps per bar) and the song wrap.
        #expect(Transport.catchUpSteps(behind: 1.0, secPerStep: sps, step16: 10, barCount: 1, countSteps: 0,
                                       barSteps: 12, songMode: true, songBars: 16, threshold: 0.025)?.step16 == 6)
        #expect(Transport.catchUpSteps(behind: 1.0, secPerStep: sps, step16: 10, barCount: 15, countSteps: 0,
                                       barSteps: 12, songMode: true, songBars: 16, threshold: 0.025)?.barCount == 0)
    }

    // MARK: - Finding 49: Loop-Mode conditional trigs must advance like the bounce

    /// `BarCount` is pinned at 0 outside Song Mode, so every per-bar trig condition was frozen at bar 0
    /// live while the 4-bar bounce played them across bars — a fill the user programmed never fired, and
    /// "1:2"/"1:3"/"1:4"/"!fill" stayed permanently on. Loop Mode must evaluate conditions against the
    /// loop-pass counter, numbered from the loop top exactly like the export's bars 0..<N.
    @Test @MainActor func loopModeConditionalTrigsAdvanceLikeTheBounce() {
        let project = Project(engine: AudioEngine())
        project.lanes["kick"] = [0.9] + Array(repeating: 0.0, count: 15)
        for cond in ["fill", "1:3"] {
            project.setStepMeta("kick", 0) { $0.cond = cond }
            for bars in [1, 2, 4, 8] {
                let bounced = project.buildExportPlan(loopBarsOverride: bars).drums.filter { $0.sound == "kick" }.count
                var pass = 0, live = 0
                for _ in 0..<bars {
                    if Project.condPass(cond, bar: Transport.trigBar(songMode: false, barCount: 0, loopPass: pass)) { live += 1 }
                    pass = Transport.nextLoopPass(pass)
                }
                #expect(live == bounced, "cond \(cond) over \(bars) bars: live \(live) vs bounce \(bounced)")
            }
        }
        // Song Mode still evaluates the arrangement bar, and the loop pass is what Loop Mode reports.
        #expect(Transport.trigBar(songMode: true, barCount: 5, loopPass: 1) == 5)
        #expect(Transport.trigBar(songMode: false, barCount: 0, loopPass: 3) == 3)
        #expect(Transport.nextLoopPass(0) == 1 && Transport.nextLoopPass(31) == 32)   // unbounded: matches any loop length
        // The shipped gate (barCount pinned at 0) can never fire a fill.
        #expect(!Project.condPass("fill", bar: Transport.trigBar(songMode: true, barCount: 0, loopPass: 0)))
    }

    // MARK: - Finding 50: a joining (or rejoining) follower gets the transport immediately

    /// The join path sent only the project snapshot; the transport op rode the 6 s heartbeat, so a student
    /// who joined mid-song — or a forked student who pressed Rejoin — stayed silent for up to 6 s. The host
    /// must also re-assert the transport at the current position on (re)join.
    @Test @MainActor func aJoiningFollowerIsGivenTheTransportImmediately() {
        let live = SessionStore.joinResync(playing: true, bar: 3, step: 4)
        #expect(live.fullSync)                       // state always travels with the handshake
        #expect(live.announceTransport)              // ← shipped: snapshot only, silence until the heartbeat
        #expect(live.bar == 3 && live.step == 4)
        // Not playing: there is no transport to assert.
        #expect(!SessionStore.joinResync(playing: false, bar: 0, step: -1).announceTransport)
        // The teacher's count-in pins project.step = -1; announcing then made followers start early (#18).
        #expect(!SessionStore.joinResync(playing: true, bar: 0, step: -1).announceTransport)
    }

    // MARK: - Finding 73: the bounce must humanize synth notes like playback does

    /// Live applies Humanize to the melody (and to synth parts/tracks); the bounce humanized only drums, so
    /// a Humanized project exported with a rigid, slightly louder synth while the drums drifted. The bounce
    /// now uses the same seeded rule on every synth path.
    @Test @MainActor func theBounceHumanizesSynthNotesLikePlayback() throws {
        let project = Project(engine: AudioEngine())
        project.melody = [MelodyNote(step: 0, pitch: 60, dur: 2, vel: 0.8)]
        let dryPlan = project.buildExportPlan(loopBarsOverride: 1)
        let dry = try #require(dryPlan.synths.first)
        #expect(dry.atSample == 0)                       // Humanize off: dead on the grid
        project.humanize = 1
        let wetPlan = project.buildExportPlan(loopBarsOverride: 1)
        let wet = try #require(wetPlan.synths.first)
        #expect(wet.atSample != dry.atSample)            // ← shipped: melody was never humanized
        #expect(wet.vel != dry.vel)
        let againPlan = project.buildExportPlan(loopBarsOverride: 1)
        let again = try #require(againPlan.synths.first)
        #expect(again.atSample == wet.atSample && again.vel == wet.vel)   // deterministic, reproducible bounce
        let h = Project.humanized(seed: "melody:60", bar: 0, step: 0, amount: 1)
        #expect(abs(wet.atSample - h.timeOffset * wetPlan.sr) < 1e-9)
        #expect(abs(wet.vel - dry.vel * h.velScale) < 1e-9)

        // Extra instrument parts are a synth path too.
        let parts = Project(engine: AudioEngine())
        parts.parts = [InstrumentPart(id: "bass", name: "Bass", patch: SynthPatch(),
                                      notes: [MelodyNote(step: 0, pitch: 40, dur: 2, vel: 0.7)])]
        let partDry = try #require(parts.buildExportPlan(loopBarsOverride: 1).synths.first)
        #expect(partDry.atSample == 0)
        parts.humanize = 1
        let partWet = try #require(parts.buildExportPlan(loopBarsOverride: 1).synths.first)
        #expect(partWet.atSample != partDry.atSample)
        #expect(partWet.vel != partDry.vel)
        #expect(Project.humanized(seed: "x", bar: 0, step: 0, amount: 0) == (1, 0))   // off = exactly on the grid
    }

    // MARK: - Finding 40: a no-op touch on a drag control must not checkpoint

    /// The velocity bar, the pan knob and the fader all use `DragGesture(minimumDistance: 0)`, so a
    /// plain touch-down delivers a zero-translation frame. Every one of them wrote through
    /// `setStepVel` / `setMix` / `setTrackVol` / `setTrackPan` unconditionally, and each of those
    /// checkpointed — so merely *touching* a control marked the project dirty, pushed a restore point
    /// and wiped the redo stack although nothing changed (#MIX-UNDO). The setters must ignore a
    /// clamped value that equals the value already there.
    @Test @MainActor func aNoOpTouchOnADragControlDoesNotDirtyOrBurnRedo() {
        let project = Project(engine: AudioEngine())
        // Make one real edit, undo it, and mark clean: the redo entry a stray touch used to destroy.
        func armRedo() {
            project.toggleStep("snare", 0, vel: 0.5)
            project.undo()
            project.markSaved()
            #expect(project.canRedo)
            #expect(!project.hasUnsavedChanges)
        }

        // Velocity bar: the zero-translation frame writes back the value already there.
        armRedo()
        let vel = project.lanes["kick"]?[0] ?? 0
        project.setStepVel("kick", 0, vel)
        #expect(!project.hasUnsavedChanges)
        #expect(project.canRedo)

        // Pan knob / fader: same. The strip reads `project.mixer[ch] ?? MixChannel()`, so the "current"
        // value for a channel the project has no entry for is exactly MixChannel()'s default.
        armRedo()
        let pan = project.mixer["kick"]?.pan ?? MixChannel().pan
        project.setMix("kick") { $0.pan = pan }
        #expect(!project.hasUnsavedChanges)
        #expect(project.canRedo)
        armRedo()
        let mixVol = project.mixer["kick"]?.vol ?? MixChannel().vol
        project.setMix("kick") { $0.vol = mixVol }
        #expect(!project.hasUnsavedChanges)
        #expect(project.canRedo)

        // Track fader / pan: same.
        if let t = project.tracks.first {
            armRedo()
            project.setTrackVol(t.id, project.tracks.first?.vol ?? AudioDefaults.unityGain)
            #expect(!project.hasUnsavedChanges)
            #expect(project.canRedo)
            armRedo()
            project.setTrackPan(t.id, project.tracks.first?.pan ?? 0)
            #expect(!project.hasUnsavedChanges)
            #expect(project.canRedo)
        }

        // A real change still checkpoints (and clears redo) exactly as before.
        let cur = project.lanes["kick"]?[0] ?? 0
        let changed = cur == 0.7 ? 0.2 : 0.7
        project.setStepVel("kick", 0, changed)
        #expect(project.lanes["kick"]?[0] == changed)
        #expect(project.hasUnsavedChanges)
        #expect(!project.canRedo)
        project.setMix("kick") { $0.pan = 0.5 }
        #expect(project.mixer["kick"]?.pan == 0.5)
        if let t = project.tracks.first {
            project.setTrackVol(t.id, t.vol + 0.2)
            #expect(abs((project.tracks.first?.vol ?? 0) - (t.vol + 0.2)) < 1e-9)
            project.setTrackPan(t.id, -0.4)
            #expect(project.tracks.first?.pan == -0.4)
        }
    }

    /// The view-layer half of finding 40: a `minimumDistance: 0` drag delivers a zero-translation tap
    /// frame that must do nothing at all — no write, no checkpoint, no redo burn — while every later
    /// frame of an open drag still applies (it can legitimately net back to the start value).
    @Test @MainActor func dragControlsIgnoreTheZeroTranslationTapFrame() {
        #expect(!FDDrag.shouldApply(moved: false, dragOpen: false))   // the tap frame
        #expect(FDDrag.shouldApply(moved: true, dragOpen: false))     // first real move
        #expect(FDDrag.shouldApply(moved: false, dragOpen: true))     // later frame nets back to start
        #expect(FDDrag.shouldApply(moved: true, dragOpen: true))
        #expect(!FDDrag.moved(CGSize(width: 0, height: 0)))
        #expect(!FDDrag.moved(CGSize(width: 3, height: -3)))          // inside the touch slop
        #expect(FDDrag.moved(CGSize(width: 0, height: -8)))           // a vertical fader drag
        #expect(FDDrag.moved(CGSize(width: 9, height: 0)))            // a horizontal pan drag
    }

    // MARK: - Finding 36: persisted performance/setup state must go through a checkpoint

    /// Chord/arp/scale-lock/note-length/metronome/count-in/full-level are all `ProjectSnapshot` fields,
    /// but the views wrote them directly (`project.chordMode = $0`, `project.metronome.toggle()`, …):
    /// the edit was never undoable, never set `hasUnsavedChanges`, and was silently reverted by autosave
    /// and a project switch. Each now has a checkpointing mutator, and each is idempotent — selecting
    /// the value that is already set must not dirty a clean project or burn redo (#PERSIST-PREFS).
    @Test @MainActor func persistedPrefsAreUndoableDirtyAndIdempotent() {
        let project = Project(engine: AudioEngine())
        project.markSaved()

        project.setChordMode("triad")
        #expect(project.chordMode == "triad")
        #expect(project.hasUnsavedChanges)
        project.undo()
        #expect(project.chordMode == "off")
        project.setChordMode("triad")

        project.setArpMode("up")
        #expect(project.arpMode == "up")
        project.setArpRate("1/32")
        #expect(project.arpRate == "1/32")
        project.setArpOct(3)
        #expect(project.arpOct == 3)
        project.setScaleLock(false)
        #expect(!project.scaleLock)
        project.setRollLen(8)
        #expect(project.rollLen == 8)
        project.setFullLevel(true)
        #expect(project.fullLevel)
        project.setMetronome(true)
        #expect(project.metronome)
        project.setCountIn(2)
        #expect(project.countIn == 2)
        #expect(project.hasUnsavedChanges)

        // Re-setting the same value is not an edit: no dirty flag, no redo burn.
        project.markSaved()
        project.setChordMode("triad")
        project.setArpMode("up")
        project.setArpRate("1/32")
        project.setArpOct(3)
        project.setScaleLock(false)
        project.setRollLen(8)
        project.setFullLevel(true)
        project.setMetronome(true)
        project.setCountIn(2)
        #expect(!project.hasUnsavedChanges)

        // They are persisted fields: the values survive a save/restore round trip.
        let fresh = Project(engine: AudioEngine())
        fresh.restore(project.snapshot())
        #expect(fresh.chordMode == "triad" && fresh.arpMode == "up")
        #expect(fresh.arpRate == "1/32" && fresh.arpOct == 3)
        #expect(!fresh.scaleLock && fresh.rollLen == 8)
        #expect(fresh.fullLevel && fresh.metronome && fresh.countIn == 2)
    }

    // MARK: - Finding 38: the pad long-press is per-pad and needs the pad still held

    /// One shared `longTimer` was invalidated by ANY pad's hit-down or release, so holding pad A while
    /// drumming pad B killed A's pending editor; and the timer body captured the pad without checking it
    /// was still held. The candidate is now keyed to one pad, only that pad's release cancels it, and the
    /// editor opens only while the pad is still down. The 0.48 s hold was under UIKit's 0.5 s default and
    /// popped a full-screen modal mid-jam, so the threshold is longer too (#PAD-LONGPRESS).
    @Test @MainActor func longPressIsPerPadAndRequiresThePadStillHeld() {
        #expect(PadModeView.shouldArmLongPress(noteRepeat: false, recording: false, armedPad: nil))
        #expect(!PadModeView.shouldArmLongPress(noteRepeat: true, recording: false, armedPad: nil))
        #expect(!PadModeView.shouldArmLongPress(noteRepeat: false, recording: true, armedPad: nil))
        #expect(!PadModeView.shouldArmLongPress(noteRepeat: false, recording: false, armedPad: "kick"))

        #expect(PadModeView.onUpCancelsLongPress(releasedPad: "kick", armedPad: "kick"))
        #expect(!PadModeView.onUpCancelsLongPress(releasedPad: "snare", armedPad: "kick"))
        #expect(!PadModeView.onUpCancelsLongPress(releasedPad: "snare", armedPad: nil))

        #expect(PadModeView.longPressFires(armedPad: "kick", stillHeld: true))
        #expect(!PadModeView.longPressFires(armedPad: "kick", stillHeld: false))
        #expect(!PadModeView.longPressFires(armedPad: nil, stillHeld: true))

        #expect(PadModeView.longPressDelay >= 0.6)   // ≥ UIKit's default; 0.48 s fired mid-performance
    }

    // MARK: - Finding 39: the pad-editor colour swatches need names and a selected state

    /// The 13 swatches were 24 pt circles with no accessible name and no selected state, so VoiceOver
    /// read thirteen identical "button"s and a blind user could not tell which colour was set. Each
    /// swatch now carries a colour name, its selected state, a non-colour checkmark cue and a 44 pt hit
    /// target. The naming/selection rules are pure; the trait/frame wiring is view-layer (#PAD-SWATCH).
    @Test @MainActor func padSwatchesHaveDistinctNamesAndASelectedState() {
        #expect(PadInspectorView.swatchColors.count == 13)
        var names = Set<String>()
        for hex in PadInspectorView.swatchColors {
            let name = PadInspectorView.colorName(hex)
            #expect(!name.isEmpty)
            #expect(names.insert(name).inserted)   // no two swatches share a spoken name
            #expect(PadInspectorView.swatchAccessibilityLabel(hex) == "Pad colour \(name)")
            #expect(PadInspectorView.swatchIsSelected(hex: hex, current: hex))
            #expect(!PadInspectorView.swatchIsSelected(hex: hex, current: "#000000"))
        }
        #expect(PadInspectorView.colorName("#FF5A3C") == "Coral")
    }

    // MARK: - Finding 41: meter ticks must invalidate the meter leaf, not the whole mixer

    /// Meter levels were `@State` on `MixerModeView` and reassigned on a 1/60 s timer, so every tick
    /// re-evaluated the ENTIRE mode body — TransportBar, MasterFXBar and every strip — on the same main
    /// queue as the 25 ms lookahead scheduler. Levels now live in one ObservableObject per channel, the
    /// mode does not observe them, the tick is 30 Hz, and a tick that changes nothing publishes nothing
    /// (#METER-60FPS).
    @Test @MainActor func meterTicksPublishPerCellAndOnlyOnRealChange() {
        let meters = MixMeters()
        let kick = meters.cell("kick")
        let snare = meters.cell("snare")
        #expect(kick !== snare)                       // per-channel leaf objects, not one shared bag
        var kickPublishes = 0, snarePublishes = 0
        let kickSub = kick.objectWillChange.sink { _ in kickPublishes += 1 }
        let snareSub = snare.objectWillChange.sink { _ in snarePublishes += 1 }
        defer { kickSub.cancel(); snareSub.cancel() }

        // A silent mixer: repeated ticks publish nothing at all (the shipped code assigned every tick).
        for _ in 0..<10 { meters.decay() }
        #expect(kickPublishes == 0)
        #expect(snarePublishes == 0)

        // A hit on one channel publishes that channel's cell only.
        meters.set("kick", 0.8)
        #expect(kickPublishes == 1)
        #expect(snarePublishes == 0)
        #expect(meters.value("kick") == 0.8)
        #expect(meters.value("snare") == 0)

        meters.set("kick", 0.8)                       // same value → not a change
        #expect(kickPublishes == 1)

        meters.decay()                                // only the live cell moves
        #expect(kickPublishes == 2)
        #expect(snarePublishes == 0)

        while meters.value("kick") > 0 { meters.decay() }
        let settled = kickPublishes
        meters.decay()
        #expect(kickPublishes == settled)             // fully decayed → parked again

        #expect(MixerModeView.meterInterval >= 1.0 / 30.0)   // no longer a 60 fps publish
    }

    // MARK: - Finding 65: a real export write failure must not be reported as "add some sounds"

    /// `writeAudio` returned a bare `URL?`, so every render failure — a full disk above all — was shown as
    /// "Add some sounds first" on a project that already had sounds, and the truthful diagnostic reached
    /// only the system log. The empty render is now its own case, and a real I/O error is classified and
    /// surfaced with the actual cause.
    @Test func exportWriteFailuresNameTheRealCauseInsteadOfBlamingMissingSounds() {
        let outOfSpace = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(ExportWriteFailure.classify(outOfSpace) == .outOfSpace)
        #expect(ExportWriteFailure.classify(outOfSpace).message.localizedCaseInsensitiveContains("space"))
        #expect(!ExportWriteFailure.classify(outOfSpace).message.localizedCaseInsensitiveContains("add some sounds"))

        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(ExportWriteFailure.classify(posix) == .outOfSpace)

        // AVFoundation wraps the disk error it hit — the classifier must follow NSUnderlyingErrorKey.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: outOfSpace])
        #expect(ExportWriteFailure.classify(wrapped) == .outOfSpace)

        // An unknown failure is generic, but it still must not misdiagnose the project as empty.
        let other = ExportWriteFailure.classify(CocoaError(.fileWriteUnknown))
        #expect(other != .outOfSpace)
        #expect(!other.message.localizedCaseInsensitiveContains("add some sounds"))

        // Only a genuinely empty render offers the "add some sounds" advice.
        #expect(ExportWriteFailure.empty.message.localizedCaseInsensitiveContains("nothing to export"))
        #expect(ExportWriteFailure.empty.message.localizedCaseInsensitiveContains("add some sounds"))
    }

    /// The writer itself must return a typed failure for a real I/O error instead of a bare `nil` that is
    /// indistinguishable from an empty render.
    @Test func writeAudioReportsIOFailureAsATypedFailure() throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocked)   // a FILE where the writer needs a directory
        defer { try? FileManager.default.removeItem(at: blocked) }

        guard case .failure(let empty) = writeAudio(.wav, left: [], right: [], sr: 48_000, name: "Empty", dir: blocked) else {
            Issue.record("an empty render must fail with .empty")
            return
        }
        #expect(empty == .empty)

        let result = writeAudio(.wav, left: [0.1, -0.2], right: [0.1, -0.2], sr: 48_000, name: "Blocked", dir: blocked)
        guard case .failure(let failure) = result else {
            Issue.record("writing into a non-directory must fail")
            return
        }
        #expect(failure != .empty)   // a real I/O failure is not the empty-project case
    }

    // MARK: - Finding 67: the velocity lane must not open the step inspector mid-drag

    /// The 0.4 s long-press shares the velocity bar with the drag gesture (both are live at once). Without a
    /// gate, a user who holds a bar for 0.4 s before/while dragging gets the step-inspector popover
    /// presented over the grid while the drag state is already mutated. The inspector opens only when no
    /// velocity drag is open; a still hold keeps the documented "hold edit" affordance.
    @Test func velocityLongPressDoesNotOpenTheInspectorWhileADragIsLive() {
        #expect(SequenceModeView.shouldOpenStepInspector(dragOpen: false))
        #expect(!SequenceModeView.shouldOpenStepInspector(dragOpen: true))
    }

    // MARK: - Finding 69: beat haptics build their pulses once, not once per beat

    @MainActor
    private final class CountingPulsePlayer: HapticPulsePlayer {
        var fires = 0
        func fire() { fires += 1 }
    }

    /// `Haptics.beat(strong:)` allocated a `CHHapticEvent`, a `CHHapticPattern` and a player on the main
    /// queue on every call — four times a second at 120 BPM, on the same queue as the sampler scheduler.
    /// The strong/weak pulses are now built once and reused. This counts player constructions, i.e. the
    /// structural property, rather than measuring timing.
    @Test @MainActor func beatHapticsBuildTheirPulsesOnceAndReuseThem() {
        let haptics = Haptics()
        var built = 0
        var made: [CountingPulsePlayer] = []
        haptics.pulseFactory = { _ in
            built += 1
            let player = CountingPulsePlayer()
            made.append(player)
            return player
        }
        haptics.enabled = true

        for i in 0..<200 { haptics.beat(strong: i % 4 == 0) }

        #expect(built == 2)                 // one strong + one weak player, built once
        #expect(haptics.playersBuilt == 2)
        #expect(haptics.pulsesFired == 200)
        #expect(made.count == 2)            // no beat allocated a fresh player
        #expect(made.reduce(0) { $0 + $1.fires } == 200)   // every beat reused the cached player

        haptics.enabled = false
        haptics.beat(strong: true)          // disabled → nothing reaches a player
        #expect(haptics.pulsesFired == 200)
    }

    // MARK: - Finding 28: the Free editor must stop drawing (and re-writing) notes outside the bar

    /// The write paths clamped to a hardcoded 16 rather than the user's `barSteps` — that is how the
    /// unplayable out-of-bar notes were created in the first place. Driven through the real mutators.
    @Test @MainActor func melodyWritePathsHonorTheBarLength() {
        let project = Project(engine: AudioEngine())
        project.clearAll()
        project.barSteps = 12
        project.drawActiveNote(pitch: 60, start: 10, len: 6)
        project.captureNote(pitch: 64, step: 15, len: 2)
        project.placeActiveNote(step: 14, pitch: 67, len: 2)
        project.moveActiveNote(pitch: 60, from: 10, to: 15)
        #expect(!project.activeNotes.isEmpty)
        for n in project.activeNotes {
            #expect(n.step >= 0 && n.step < 12, "step \(n.step) escaped the 12-step bar")
            #expect(n.step + n.dur <= 12, "note \(n.step)+\(n.dur) escaped the 12-step bar")
        }
    }

    /// The exact clamp the write paths now share. 4/4 must be byte-for-byte the old hard-coded-16
    /// arithmetic — the new bound only bites when the bar is shorter than the 16 steps the code assumed.
    @Test @MainActor func noteClampHelpersMatchTheBarExactly() {
        #expect(Project.boundedNote(step: 13, len: 4, barSteps: 12).step == 11)
        #expect(Project.boundedNote(step: 13, len: 4, barSteps: 12).dur == 1)
        #expect(Project.boundedNote(step: 0, len: 16, barSteps: 12).dur == 12)
        #expect(Project.boundedNote(step: -3, len: 2, barSteps: 16).step == 0)
        #expect(Project.boundedNote(step: 0, len: 0, barSteps: 16).dur == 1)
        #expect(Project.boundedNote(step: 13, len: 4, barSteps: 16).step == 13)   // 4/4 unchanged
        #expect(Project.boundedNote(step: 13, len: 4, barSteps: 16).dur == 3)
        #expect(Project.boundedNote(step: 5, len: 2, barSteps: 8).step == 5)
        #expect(Project.boundedMoveStep(15, dur: 2, barSteps: 12) == 10)   // keeps the length in the bar
        #expect(Project.boundedMoveStep(3, dur: 2, barSteps: 12) == 3)
        #expect(Project.boundedMoveStep(11, dur: 4, barSteps: 12) == 8)
    }

    /// Shrinking the bar (4/4 → 3/4) strands notes the app's 16-hardcoded write paths put at steps
    /// 12…15. The transport only visits 0..<barSteps, so they never sound, yet the Free editor drew them
    /// past the ScrollView's content width (the canvas is `length * cellW`) where they could not be
    /// reached or removed. The grid now models only in-bar notes and merges the others back untouched, so
    /// an edit in the editor can neither resurrect them nor delete them.
    @Test @MainActor func freeRollHidesOutOfBarNotesWithoutDeletingThem() {
        let ghost = MelodyNote(step: 14, pitch: 60, dur: 2, vel: 0.8)
        let inBar = MelodyNote(step: 2, pitch: 62, dur: 2, vel: 0.8)

        let split = FreeRollView.splitByBar([inBar, ghost], barSteps: 12)
        #expect(split.inBar.count == 1 && split.inBar[0].step == 2)
        #expect(split.outOfBar.count == 1 && split.outOfBar[0].step == 14)
        #expect(FreeRollView.splitByBar([inBar, ghost], barSteps: 16).outOfBar.isEmpty)

        // Removing the in-bar note must not take the ghost with it: the grid's write-back is only the
        // in-bar part of the model, and the merge restores everything the grid cannot represent.
        let emptied = FreeRollView.mergePreserving([], project: [inBar, ghost], barSteps: 12)
        #expect(emptied.count == 1 && emptied[0].step == 14)
        // A moved in-bar note replaces the old one and still leaves the ghost alone and un-re-timed.
        let moved = MelodyNote(step: 5, pitch: 62, dur: 2, vel: 0.8)
        let merged = FreeRollView.mergePreserving([moved], project: [inBar, ghost], barSteps: 12)
        #expect(merged.count == 2)
        #expect(merged.contains { $0.step == 5 })
        #expect(merged.contains { $0.step == 14 })
        #expect(!merged.contains { $0.step == 2 })
    }

    /// The grid may have to clamp a tail that crosses the bar line to the columns it can draw, but the
    /// note it was built from is the truth: while the note is untouched it writes its TRUE length back,
    /// so opening the editor cannot silently shorten it (finding 28). The moment the user re-starts or
    /// re-sizes it, the grid's value wins — the same contract as `writeBackPitch`.
    @Test @MainActor func freeRollWriteBackKeepsTheTrueLengthOfAnUntouchedNote() {
        // A 4-step note at step 10 of a 12-step bar is drawn as 2 columns.
        #expect(FreeRollView.clampedProjection(10, 4, barSteps: 12) == 2)
        #expect(FreeRollView.writeBackDuration(gridStep: 10, gridDur: 2, trueStep: 10, trueDur: 4, barSteps: 12) == 4)
        // The user resized it → the grid's length wins.
        #expect(FreeRollView.writeBackDuration(gridStep: 10, gridDur: 1, trueStep: 10, trueDur: 4, barSteps: 12) == 1)
        // The user moved it → the grid's (re-clamped) length wins.
        #expect(FreeRollView.writeBackDuration(gridStep: 4, gridDur: 2, trueStep: 10, trueDur: 4, barSteps: 12) == 2)
        // A note that never overhung round-trips unchanged, and a new note takes the grid's length.
        #expect(FreeRollView.writeBackDuration(gridStep: 2, gridDur: 3, trueStep: 2, trueDur: 3, barSteps: 12) == 3)
        #expect(FreeRollView.writeBackDuration(gridStep: 7, gridDur: 2, trueStep: nil, trueDur: nil, barSteps: 12) == 2)
    }

    // MARK: - Finding 42: the Pad Inspector Volume knob must reach the sequencer and the bounce

    /// `padVolMul` had exactly one call site — `triggerPad`, the live tap/audition path. The sequencer
    /// (`Transport`) and both export drum paths computed their velocity without it, so a pad turned down
    /// (or to zero) in the inspector still played at full level in the pattern and in the WAV.
    @Test @MainActor func padVolumeAppliesToTheSequencerAndTheBounce() {
        let project = Project(engine: AudioEngine())
        project.clearAll()
        project.lanes["kick"] = Kit.emptyLane()
        project.lanes["kick"]?[0] = 0.9   // full-velocity hit on step 1

        let unity = project.buildExportPlan(loopBarsOverride: 1).drums.filter { $0.sound == "kick" }
        #expect(unity.count == 1)

        project.setPadParam("kick") { $0.vol = 0.425 }   // half of the 0.85 unity knob
        let quiet = project.buildExportPlan(loopBarsOverride: 1).drums.filter { $0.sound == "kick" }
        #expect(quiet.count == 1)
        let ratio = quiet[0].vel / unity[0].vel
        #expect(abs(ratio - 0.5) < 1e-9, "pad Volume moved the bounce by \(ratio)× instead of 0.5×")

        // One gain, resolved the same way everywhere: the live tap, the sequencer and the bounce can no
        // longer disagree (~0.7 dB apart before, because live used 1.25 while playback/export used 1.15).
        #expect(abs(project.padHitGain("kick") - project.padGain("kick") * 0.5) < 1e-12)
        #expect(abs(project.padGain("kick") - AudioDefaults.unityGain * Project.padDrive) < 1e-12)
        #expect(abs(quiet[0].vel - project.padVel("kick", 0.9) * project.padHitGain("kick")) < 1e-12)

        // A pad turned all the way down is silent in the pattern and the bounce, not just under a finger.
        project.setPadParam("kick") { $0.vol = 0 }
        #expect(project.padHitGain("kick") == 0)
        #expect(project.buildExportPlan(loopBarsOverride: 1).drums.allSatisfy { $0.vel == 0 })
    }

    /// MEASURED, not asserted from a chosen constant: the same pad rendered through the bounce's own
    /// `renderOffline` mixdown at two Volume settings must come out at the ratio the pad's gain says.
    /// The limiter is off and the lane is struck softly (0.1) so both renders sit in the master soft
    /// clip's linear region — a hard strike would be compressed by the always-on `tanh` and the ratio
    /// would read ~0.53× even with the gain applied correctly. That lets the measured peak be compared
    /// against the velocity the sequencer would compute (`padVel × padHitGain`, the exact expression
    /// Transport.swift evaluates per step): live tap, sequencer and WAV all resolve one gain, and the
    /// file that reaches the user proves it.
    @Test @MainActor func padVolumeMovesTheRenderedBounceLevel() {
        let project = Project(engine: AudioEngine())
        project.clearAll()
        project.lanes["kick"] = Kit.emptyLane()
        project.lanes["kick"]?[0] = 0.1   // soft strike → below the soft clip's knee

        func peak(_ plan: ExportPlan) -> Float {
            let (l, r) = renderOffline(plan)
            var p: Float = 0
            for i in 0..<min(l.count, r.count) { p = max(p, max(abs(l[i]), abs(r[i]))) }
            return p
        }

        let unityPlan = project.buildExportPlan(loopBarsOverride: 1, safetyEnabled: false)
        let unityPeak = peak(unityPlan)
        #expect(unityPeak > 0.001, "the kick must actually render for this to measure anything")
        #expect(abs(unityPlan.drums[0].vel - project.padVel("kick", 0.1) * project.padGain("kick")) < 1e-12)

        project.setPadParam("kick") { $0.vol = 0.425 }   // half of the 0.85 unity knob
        let quietPlan = project.buildExportPlan(loopBarsOverride: 1, safetyEnabled: false)
        let quietPeak = peak(quietPlan)
        // The plan's velocity IS the sequencer's expression, resolved through the shared per-hit gain.
        #expect(abs(quietPlan.drums[0].vel - project.padVel("kick", 0.1) * project.padHitGain("kick")) < 1e-12)

        let measured = Double(quietPeak / unityPeak)
        print("[finding 42] bounce peak: unity vol 0.85 → \(unityPeak), vol 0.425 → \(quietPeak), ratio \(measured)× (velocity ratio 0.5×)")
        #expect(abs(measured - 0.5) < 0.01,
                "bounce peak moved \(measured)× for a 0.5× pad Volume (unity \(unityPeak), quiet \(quietPeak))")
    }

    // MARK: - Finding 72: a pad layer is gated by the bus it actually plays on

    /// `triggerPadLayers` triggered each layer with no channel, so the engine routed it by the layer's
    /// own sound — but the mute/solo gate used only the PAD's channel. Muting the 808 strip (or soloing
    /// Drums) left a "Deep Kick" layer on the kick pad sounding, so the mixer's mute/solo was not what you
    /// heard. The bounce mirrored the same mis-gate, so this is one rule for live, sequencer and export.
    @Test @MainActor func padLayersAreGatedByTheirOwnMixerBus() {
        let project = Project(engine: AudioEngine())
        project.clearAll()
        project.lanes["kick"] = Kit.emptyLane()
        project.lanes["kick"]?[0] = 0.9
        project.setPadParam("kick") { $0.layers = [PadLayer(sound: "deepKick", vol: 1, pitch: 0, pan: 0)] }
        #expect(Kit.channelOf("kick") == "drums")
        #expect(Kit.channelOf("deepKick") == "bass")     // the layer's own bus

        let audible = project.buildExportPlan(loopBarsOverride: 1).drums
        #expect(audible.contains { $0.sound == "kick" })
        #expect(audible.contains { $0.sound == "deepKick" })
        #expect(project.audiblePadLayers("kick").count == 1)

        project.setMix("bass") { $0.mute = true }
        let muted = project.buildExportPlan(loopBarsOverride: 1).drums
        #expect(muted.contains { $0.sound == "kick" }, "the pad's own bus is still audible")
        #expect(!muted.contains { $0.sound == "deepKick" }, "the layer's own muted bus must silence it")
        // The live and sequenced paths resolve layers through the same gate.
        #expect(project.audiblePadLayers("kick").isEmpty)
        #expect(!project.channelAudible("bass") && project.channelAudible("drums"))

        // Solo is the same rule: soloing Drums must drop a layer that lives on the 808 strip.
        project.setMix("bass") { $0.mute = false }
        project.setMix("drums") { $0.solo = true }
        let soloed = project.buildExportPlan(loopBarsOverride: 1).drums
        #expect(soloed.contains { $0.sound == "kick" })
        #expect(!soloed.contains { $0.sound == "deepKick" })
    }

    // MARK: - Finding 71: one changed pad assignment must not re-read every pad sample

    /// Undo/redo (and project load) re-registered EVERY sampled pad whenever the pad→file map changed:
    /// `loadPadSamples` cleared all registrations, then re-read every assigned WAV on the main actor. A
    /// pad whose WAV is not on this device (a follower's fullSync, or a swept file) was silently dropped
    /// as collateral. Only the pads whose file actually changed may be touched.
    @Test @MainActor func padSampleReloadTouchesOnlyThePadsThatChanged() throws {
        let project = Project(engine: AudioEngine())
        project.clearAll()
        project.setPadSamples([("kick", [0.1, -0.1, 0.2], "Kick"),
                               ("snare", [0.2, -0.2, 0.3, -0.3], "Snare")], bank: "A")
        let kickFile = try #require(project.padParams["kick"]?.sampleFile)
        #expect(project.padSampleData["kick"]?.count == 3)

        // The kick's WAV is gone from this device; then an unrelated pad is reassigned and undone.
        deletePadSampleWAV(file: kickFile)
        project.setPadSamples([("snare", [0.9, -0.9], "Snare 2")], bank: "A")
        #expect(project.padSampleData["snare"]?.count == 2)
        project.undo()   // restores snare→its old file; the pad→file map changed, so a reload runs

        #expect(project.padSampleData["kick"]?.count == 3,
                "the unchanged kick pad was re-read (and lost) although its assignment never moved")
        #expect(project.padSampleData["snare"]?.count == 4, "the changed pad must still be re-read")
    }

    /// The reload plan itself: only pads whose file moved are dropped and re-read.
    @Test @MainActor func padSampleReloadPlanTouchesOnlyChangedPads() {
        let plan = Project.padSampleReloadPlan(decoded: ["kick": "a.wav", "snare": "b.wav", "hat": "c.wav"],
                                               live: ["kick": "a.wav", "snare": "d.wav"])
        #expect(plan.drop == ["hat", "snare"])   // reassigned, and no longer assigned at all
        #expect(plan.load == ["snare"])
        #expect(Project.padSampleReloadPlan(decoded: ["kick": "a.wav"], live: ["kick": "a.wav"]).drop.isEmpty)
        #expect(Project.padSampleReloadPlan(decoded: ["kick": "a.wav"], live: ["kick": "a.wav"]).load.isEmpty)
        #expect(Project.padSampleReloadPlan(decoded: [:], live: ["kick": "a.wav"]).load == ["kick"])
    }

    // MARK: - Finding 45: SoundFont pitch correction must reach the playback rate

    /// The parser read each sample header's `chPitchCorrection` byte and stored it on `SFRegion`, but the
    /// conversion into `MultiSampleRegion` dropped it (and the coarseTune/fineTune generators were not
    /// parsed at all), so every imported zone played detuned by up to ±127 cents. The rate is where the
    /// correction has to land — measured through `resolveSample`, the engine's own playback-rate path.
    @Test @MainActor func soundFontTuningReachesThePlaybackRate() throws {
        let engine = AudioEngine()
        let project = Project(engine: engine)

        func rate(pitchCorrection: Int8, coarseTune: Int = 0, fineTune: Int = 0) throws -> Double {
            let data = SF2Fixture.build(pitchCorrection: pitchCorrection, coarseTune: coarseTune,
                                        fineTune: fineTune, rootKey: 60)
            #expect(project.loadSoundFont(data) != nil, "the synthetic .sf2 must parse")
            var patch = SynthPatch(); patch.source = "multisample"
            return try #require(engine.core.instrumentSources()
                .resolveSample(patch: patch, midi: 60, sampleRate: engine.sampleRate)?.rate)
        }

        let flat = try rate(pitchCorrection: 0)
        #expect(abs(flat - 1) < 1e-9, "an uncorrected zone at its root key plays at unison")

        let header = try rate(pitchCorrection: 60)
        #expect(abs(header / flat - pow(2, 60.0 / 1200)) < 1e-9,
                "chPitchCorrection +60 must transpose the zone by exactly 60 cents")

        let coarse = try rate(pitchCorrection: 0, coarseTune: 1)
        #expect(abs(coarse / flat - pow(2, 100.0 / 1200)) < 1e-9, "coarseTune 1 = +100 cents")

        let fine = try rate(pitchCorrection: 0, fineTune: -50)
        #expect(abs(fine / flat - pow(2, -50.0 / 1200)) < 1e-9, "fineTune −50 = −50 cents")

        // A correction that cancels a root offset lands back on unison — the two paths must compose.
        let cancelling = try rate(pitchCorrection: 0, coarseTune: 1, fineTune: 0)
        #expect(abs(cancelling / pow(2, 100.0 / 1200) - 1) < 1e-9)
    }

    // MARK: - Finding 45 fixture

    /// A minimal, valid single-zone `.sf2` built in memory: RIFF▸sfbk, one LIST pdta (shdr / inst / ibag
    /// / igen) and one LIST sdta▸smpl. Only the fields the parser reads are meaningful; `pitchCorrection`
    /// and the two tune generators are the ones under test.
    private enum SF2Fixture {
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

    // MARK: - Finding 37: the StageSplit layout branch

    /// The layout branch is pure geometry, so pin it here rather than relying on the simulator
    /// rotating inside a UI test (it does not do so reliably). In portrait the side panel leaves the
    /// stage too narrow for its height, so the stage must stack above a scrolling side panel; in
    /// landscape it must stay side-by-side. `testPadSurfaceIsNeverInsideAPageScrollView` pins the
    /// structural consequence in the running app.
    @Test @MainActor func stageSplitStacksInPortraitAndNotInLandscape() {
        // iPad Pro 13-inch portrait, 1032 x 1376: stage = 1032 - 268 - 22 = 742, bound = max(520, 1032).
        #expect(StageSplit<EmptyView, EmptyView>.isStacked(width: 1032, height: 1376))
        // The same device in landscape, 1376 x 1032: stage = 1086, bound = max(520, 774) -> side-by-side.
        #expect(!StageSplit<EmptyView, EmptyView>.isStacked(width: 1376, height: 1032))
        // A genuinely narrow window stacks too — the "narrow window" half of the finding.
        #expect(StageSplit<EmptyView, EmptyView>.isStacked(width: 700, height: 1376))
        // Wide and short never stacks: the stage clears its minimum.
        #expect(!StageSplit<EmptyView, EmptyView>.isStacked(width: 1400, height: 900))
    }
}
