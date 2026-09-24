//  PersistenceReliabilityTests.swift — production-readiness findings in persistence / project loading
//  (H2 delete vs shared audio, H3 forward-compat guard, H5 async audio restore, M5, extra .bak generation).

import Testing
import Foundation
import FD808Engine
@testable import FB_808

@Suite(.serialized) @MainActor
struct PersistenceReliabilityTests {
    private func fixture(version: Int = 4) throws -> ProjectSnapshot {
        let json = #"""
        {"name":"Original","bpm":120,"swing":0,"quantize":"16",
         "bank":"A","fullLevel":false,"lanes":{},"selectedRow":"kick",
         "rowMute":{},"rowSolo":{},"sequences":[],"activeSeq":0,"mixer":{},
         "arrangement":[],"clips":{},"trackMute":{},"trackSolo":{},"songMode":false,
         "melody":[],"melodyKey":0,"melodyScale":"major","melodyOctave":4,
         "melodyDensity":"medium","scaleLock":true,"rollLen":16,"synthPatch":{},
         "savedSynths":[],"padParams":{},"id":"test-project"}
        """#
        var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["version"] = version
        object["synthPatch"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SynthPatch()))
        return try JSONDecoder().decode(ProjectSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func clip(_ id: UUID, name: String = "Take") -> AudioClipMeta {
        AudioClipMeta(id: id.uuidString, track: "audio", startBar: 0, name: name, gain: 1, muted: false, durSec: 0.1)
    }
    private func age(_ urls: [URL]) throws {
        for f in urls {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: f.path)
        }
    }
    private func failure<T, E: Error>(_ r: Result<T, E>) -> E? {
        if case .failure(let e) = r { return e }
        return nil
    }
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    /// A snapshot JSON a FUTURE build might write: higher version and a field shape this build can't decode.
    private func newerFormatJSON(id: String, name: String, clipID: UUID) -> Data {
        Data("""
        {"version":99,"id":"\(id)","name":"\(name)","bpm":{"tempoMap":[120]},
         "audioClips":[{"id":"\(clipID.uuidString)","future":true}]}
        """.utf8)
    }

    /// H2: with an undecodable sibling, deleting a beat reclaims ONLY its own unshared takes — never a blanket
    /// sweep that could eat audio the unreadable file (or another beat) still needs.
    @Test func deleteWithIncompleteLibraryReclaimsOnlyTheDeletedBeatsUnsharedAudio() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        let own = UUID(), shared = UUID()
        var a = try fixture(); a.id = "id-A"; a.name = "A"; a.audioClips = [clip(own), clip(shared)]
        var b = try fixture(); b.id = "id-B"; b.name = "B"; b.audioClips = [clip(shared)]
        #expect(ProjectStore.writeSnapshot(a, to: dir.appendingPathComponent("A.fd808json"), pretty: false))
        #expect(ProjectStore.writeSnapshot(b, to: dir.appendingPathComponent("B.fd808json"), pretty: false))
        try Data("not a project".utf8).write(to: dir.appendingPathComponent("Corrupt.fd808json"))
        let ownURL = audio.appendingPathComponent("\(own.uuidString).wav")
        let sharedURL = audio.appendingPathComponent("\(shared.uuidString).wav")
        let unrelated = audio.appendingPathComponent("unrelated.wav")   // might belong to the corrupt file
        for u in [ownURL, sharedURL, unrelated] { #expect(writeWAVData([0.1, 0.2], to: u)) }
        try age([ownURL, sharedURL, unrelated])
        await store.reload()
        let itemA = try #require(store.items.first { $0.projectID == "id-A" })
        #expect(store.delete(itemA))
        await waitUntil { !FileManager.default.fileExists(atPath: ownURL.path) }
        #expect(!FileManager.default.fileExists(atPath: ownURL.path))       // the deleted beat's own take is freed
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))     // B still uses it
        #expect(FileManager.default.fileExists(atPath: unrelated.path))     // incomplete keep-set → no blanket sweep
    }

    /// H3: a newer-format file refuses to open (clear reason, bytes untouched), and still protects its audio.
    @Test func newerVersionProjectsAreRefusedAndProtectTheirAudio() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let store = ProjectStore(directory: dir, audioDirectory: audio, sampleDirectory: dir)
        let futureClip = UUID(), ownClip = UUID()
        let futureURL = dir.appendingPathComponent("Future.fd808json")
        let bytes = newerFormatJSON(id: "id-future", name: "Future", clipID: futureClip)
        try bytes.write(to: futureURL)
        // Even a newer file this build COULD decode must be refused, not opened and resaved in the old format.
        var decodable = try fixture(); decodable.version = ProjectSnapshot.currentVersion + 1; decodable.id = "id-next"; decodable.name = "Next"
        #expect(ProjectStore.writeSnapshot(decodable, to: dir.appendingPathComponent("Next.fd808json"), pretty: false))
        #expect(failure(ProjectStore.decodeSnapshotResult(futureURL)) == .newerVersion(99))
        #expect(ProjectStore.decodeSnapshot(dir.appendingPathComponent("Next.fd808json")) == nil)
        await store.reload()
        let item = try #require(store.items.first { $0.projectID == "id-future" })
        #expect(await store.load(item) == nil)
        #expect(store.lastLoadFailure == .newerVersion(99))
        #expect(store.lastLoadFailure?.message(for: "Future").contains("newer version") == true)
        #expect(try Data(contentsOf: futureURL) == bytes)
        // Its take survives an unrelated delete even though the file can't be decoded.
        var mine = try fixture(); mine.id = "id-mine"; mine.name = "Mine"; mine.audioClips = [clip(ownClip)]
        #expect(ProjectStore.writeSnapshot(mine, to: dir.appendingPathComponent("Mine.fd808json"), pretty: false))
        let futureWAV = audio.appendingPathComponent("\(futureClip.uuidString).wav")
        let ownWAV = audio.appendingPathComponent("\(ownClip.uuidString).wav")
        let orphan = audio.appendingPathComponent("orphan.wav")
        for u in [futureWAV, ownWAV, orphan] { #expect(writeWAVData([0.1], to: u)) }
        try age([futureWAV, ownWAV, orphan])
        let refs = ProjectStore.referencedAssets(projectDir: dir, ext: "fd808json")
        #expect(!refs.complete)
        #expect(refs.audio.contains("\(futureClip.uuidString).wav"))
        // The routine sweep skips entirely while a newer-format file exists.
        ProjectStore.sweepOrphanWAVs(projectDir: dir, ext: "fd808json", audioDir: audio, sampleDir: dir, grace: 0)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        await store.reload()
        let mineItem = try #require(store.items.first { $0.projectID == "id-mine" })
        #expect(store.delete(mineItem))
        await waitUntil { !FileManager.default.fileExists(atPath: ownWAV.path) }
        #expect(!FileManager.default.fileExists(atPath: ownWAV.path))
        #expect(FileManager.default.fileExists(atPath: futureWAV.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// H3: archive import refuses a newer snapshot/container with a reason, instead of "damaged".
    @Test func newerVersionArchivesAreRefused() throws {
        var snap = try fixture(); snap.version = ProjectSnapshot.currentVersion + 1
        let decodable = try JSONEncoder().encode(ProjectStore.ProjectArchive(snapshot: snap))
        #expect(failure(ProjectStore.unpackArchiveResult(decodable)) == .newerVersion)
        let future = Data(#"{"version":2,"snapshot":{"version":99},"clipWAVs":{},"padSampleWAVs":{}}"#.utf8)
        #expect(failure(ProjectStore.unpackArchiveResult(future)) == .newerVersion)
        #expect(failure(ProjectStore.unpackArchiveResult(Data("junk".utf8))) == .unreadable)
        #expect(ProjectStore.archiveMaxBytes <= 128 * 1024 * 1024)   // M3: jetsam-safe on 4 GB iPads
    }

    /// Extra: explicit Save keeps one previous generation; it's a reference holder and dies with the beat.
    /// Also covers the B3-family path bug: re-saving must never delete the file it just wrote.
    @Test func explicitSaveKeepsOnePreviousGeneration() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        let lastName = store.lastProjectName, lastID = store.lastProjectID
        defer { store.lastProjectName = lastName; store.lastProjectID = lastID }
        var snap = try fixture(); snap.id = "id-S"; snap.name = "Song"; snap.bpm = 100
        #expect(await store.save(snap))
        await store.reload()
        snap.bpm = 130
        #expect(await store.save(snap))
        await store.reload()
        let url = dir.appendingPathComponent("Song.fd808json")
        let bak = ProjectStore.previousGenerationURL(url)
        #expect(ProjectStore.decodeSnapshot(url)?.bpm == 130)
        #expect(ProjectStore.decodeSnapshot(bak)?.bpm == 100)
        #expect(store.items.count == 1)                                     // the .bak is not a listed beat
        snap.bpm = 140
        #expect(await store.save(snap))                                     // still exactly one generation
        #expect(ProjectStore.decodeSnapshot(bak)?.bpm == 130)
        #expect(FileManager.default.fileExists(atPath: url.path))
        var withAsset = try #require(ProjectStore.decodeSnapshot(bak))
        var pp = PadParam(); pp.sampleFile = "bak-only.wav"; withAsset.padParams = ["kick": pp]
        #expect(ProjectStore.writeSnapshot(withAsset, to: bak, pretty: false))
        #expect(ProjectStore.referencedAssets(projectDir: dir, ext: "fd808json").samples.contains("bak-only.wav"))
        await store.reload()
        #expect(store.delete(try #require(store.items.first)))
        await waitUntil { !FileManager.default.fileExists(atPath: bak.path) }
        #expect(!FileManager.default.fileExists(atPath: bak.path))
    }

    /// M5: the launch freshness check is async (persistence queue, header-only).
    @Test func freshAutosaveCheckRunsOffMain() async throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProjectStore(directory: dir, audioDirectory: dir, sampleDirectory: dir)
        #expect(await store.hasFreshAutosave() == false)
        var snap = try fixture(); snap.id = "id-unsaved"; snap.name = "Unsaved"
        store.autosave(snap)
        #expect(await store.hasFreshAutosave())
    }

    /// H5: an async restore keeps unapplied takes in snapshot() (a save mid-decode loses nothing), lands them
    /// after awaitAudioRestore(), and a stale decode never lands in a beat opened after it.
    @Test func asyncAudioRestoreIsCompleteAndGenerationGuarded() async throws {
        let id = UUID()
        #expect(writeClipWAV([0.1, 0.2, 0.3, 0.4], id: id))
        defer { deleteClipWAV(id: id) }
        let p = Project(engine: AudioEngine())
        var a = try fixture(); a.id = "id-async-A"; a.name = "A"; a.audioClips = [clip(id, name: "Take A")]
        p.restore(a, decodeAudioAsync: true)
        #expect(p.snapshot().audioClips?.map(\.id) == [id.uuidString])   // pending, but never dropped from a save
        await p.awaitAudioRestore()
        #expect(p.audioClips.map(\.id) == [id])
        #expect(p.audioClips.first?.data.isEmpty == false)
        #expect(!p.isRestoringAudio)
        // Stale guard: start a decode, switch beats before it lands.
        let q = Project(engine: AudioEngine())
        q.restore(a, decodeAudioAsync: true)
        let stale = q.audioRestoreTask
        var b = try fixture(); b.id = "id-async-B"; b.name = "B"
        q.restore(b)
        await stale?.value
        #expect(q.audioClips.isEmpty)
        #expect(q.snapshot().audioClips?.isEmpty ?? true)
    }
}
