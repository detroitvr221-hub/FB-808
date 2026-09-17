//  Persistence.swift — save / load FD808 projects as JSON in the Documents dir.
//  The musical arrangement is fully serialized; the live sample buffer is not.
//  Audio-track clips are stored as WAVs in FD808Audio/<clip-id>.wav, referenced
//  by lightweight metadata in the snapshot (A5 Phase 4).

import SwiftUI
import FD808Engine
import Combine
import CryptoKit
import os
@preconcurrency import AVFoundation

// MARK: - Audio-clip file store

/// `Documents/<name>/`, created if missing — one home for the app's on-disk subdirectories.
nonisolated func fd808DocsSubdir(_ name: String) -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let d = docs.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

nonisolated func fd808AudioDir() -> URL { fd808DocsSubdir("FD808Audio") }

// Mono 16-bit WAV writer shared by clip + pad-sample stores.
@discardableResult
nonisolated func writeWAVData(_ data: [Float], to url: URL, sr: Double = AudioDefaults.sampleRate) -> Bool {
    guard !data.isEmpty else { return false }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    // Write to a temp sibling then atomically replace the destination, so a mid-write kill (backgrounding,
    // OOM) never leaves a truncated/partial WAV that decodes nil on next launch (#PERSIST-04).
    let tmp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp.wav")
    try? FileManager.default.removeItem(at: tmp)
    do {
        let file = try AVAudioFile(forWriting: tmp, settings: settings)
        let pf = file.processingFormat
        let chunk = 16_384
        var i = 0
        while i < data.count {
            let count = min(chunk, data.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(count)),
                  let ch = buf.floatChannelData else { try? FileManager.default.removeItem(at: tmp); return false }
            buf.frameLength = AVAudioFrameCount(count)
            for j in 0..<count { ch[0][j] = data[i + j] }
            try file.write(from: buf)
            i += count
        }
    } catch { fdLog.error("wav write error: \(error.localizedDescription, privacy: .public)"); try? FileManager.default.removeItem(at: tmp); return false }
    // AVAudioFile finalized on scope exit above; now swap it into place.
    do {
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try FileManager.default.moveItem(at: tmp, to: url) }
        return true
    } catch { fdLog.error("wav rename error: \(error.localizedDescription, privacy: .public)"); try? FileManager.default.removeItem(at: tmp); return false }
}

nonisolated func readWAVData(at url: URL, targetSR: Double? = nil) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let fmt = file.processingFormat
    let n = AVAudioFrameCount(file.length)
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
    do { try file.read(into: buf) } catch { return nil }
    if let targetSR, abs(fmt.sampleRate - targetSR) > 0.5 {
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: fmt, to: outFmt) else { return nil }
        let cap = AVAudioFrameCount(Double(n) * targetSR / fmt.sampleRate) + 2048
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
    guard let ch = buf.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
}

@discardableResult
nonisolated func writeClipWAV(_ data: [Float], id: UUID, sr: Double = AudioDefaults.sampleRate) -> Bool {
    writeWAVData(data, to: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"), sr: sr)
}
nonisolated func readClipWAV(id: UUID, targetSR: Double? = nil) -> [Float]? {
    readWAVData(at: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"), targetSR: targetSR)
}
// Stereo clips store the RIGHT channel as a paired `<id>.R.wav` (left stays in `<id>.wav`), so all the
// existing mono WAV I/O is reused and old mono clips (no .R file) keep loading unchanged.
@discardableResult
nonisolated func writeClipWAVRight(_ data: [Float], id: UUID, sr: Double = AudioDefaults.sampleRate) -> Bool {
    writeWAVData(data, to: fd808AudioDir().appendingPathComponent("\(id.uuidString).R.wav"), sr: sr)
}
nonisolated func readClipWAVRight(id: UUID, targetSR: Double? = nil) -> [Float]? {
    let url = fd808AudioDir().appendingPathComponent("\(id.uuidString).R.wav")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return readWAVData(at: url, targetSR: targetSR)
}
nonisolated func deleteClipWAV(id: UUID) {
    try? FileManager.default.removeItem(at: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"))
    try? FileManager.default.removeItem(at: fd808AudioDir().appendingPathComponent("\(id.uuidString).R.wav"))
}

// MARK: - Pad-sample file store (imported drum one-shots, FD808Samples/<file>)

nonisolated func fd808SampleDir() -> URL { fd808DocsSubdir("FD808Samples") }
@discardableResult
nonisolated func writePadSampleWAV(_ data: [Float], file: String, sr: Double = AudioDefaults.sampleRate) -> Bool {
    writeWAVData(data, to: fd808SampleDir().appendingPathComponent(file), sr: sr)
}
nonisolated func readPadSampleWAV(file: String, targetSR: Double? = nil) -> [Float]? {
    readWAVData(at: fd808SampleDir().appendingPathComponent(file), targetSR: targetSR)
}
nonisolated func deletePadSampleWAV(file: String) {
    try? FileManager.default.removeItem(at: fd808SampleDir().appendingPathComponent(file))
}

/// Captured on the main actor; audio is committed before the snapshot can reference it.
nonisolated struct ProjectSavePayload: Sendable {
    var snapshot: ProjectSnapshot
    var samplerAudio: [Float] = []
    var sampleRate: Double = AudioDefaults.sampleRate
}

struct SavedProject: Identifiable, Hashable, Sendable {
    let id: String          // filename stem (file-system identity; Identifiable/list key)
    var projectID: String?  // stable embedded UUID (#219); nil for un-migrated name-keyed files
    var name: String
    var modified: Date
    var url: URL
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var items: [SavedProject] = []
    /// Assets that blocked the most recent `save` (empty after a successful save) — see save() (#persist-3).
    @Published private(set) var lastSaveMissing: [String] = []
    @Published private(set) var lastRepairs: [String] = []   // what the last repaired() load cleaned up (health check)
    func clearRepairs() { lastRepairs = [] }                 // called when the user acknowledges the cleanup notice

    private let dir: URL
    private let audioDir: URL
    private let sampleDir: URL
    private let persistenceQueue = DispatchQueue(label: "fd808.project.persistence", qos: .utility)
    private let ext = "fd808json"
    private let lastKey = "fd808.lastProject"     // legacy: last project by display name (back-compat)
    private let lastIDKey = "fd808.lastProjectID" // #219: last project by stable id (survives rename/collision)
    private let autosaveStem = "__autosave__"   // crash/quit recovery slot, hidden from the saved list

    // Lightweight name/id header — decodes the JSON object without allocating the 58 heavy snapshot fields.
    nonisolated struct ProjectHeader: Decodable, Sendable { var id: String?; var name: String? }
    private struct HeaderCacheEntry: Sendable { var mtime: Date; var size: Int; var id: String?; var name: String }
    private var headerCache: [String: HeaderCacheEntry] = [:]   // keyed by file path; reset per launch
    private var autosaveURL: URL { dir.appendingPathComponent("\(autosaveStem).\(ext)") }

    init(directory: URL? = nil, audioDirectory: URL? = nil, sampleDirectory: URL? = nil) {
        dir = directory ?? fd808DocsSubdir("FD808Projects")
        audioDir = audioDirectory ?? fd808AudioDir()
        sampleDir = sampleDirectory ?? fd808SampleDir()
        refresh()
    }

    var lastProjectName: String? {
        get { UserDefaults.standard.string(forKey: lastKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastKey) }
    }
    var lastProjectID: String? {
        get { UserDefaults.standard.string(forKey: lastIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastIDKey) }
    }

    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        if cleaned == autosaveStem { return "Untitled Beat" }
        return cleaned.isEmpty ? "Untitled Beat" : cleaned
    }
    /// APFS/HFS+ cap one path component at 255 UTF-8 bytes. Nothing clamped the stem before, so pasting a
    /// long name made every Save fail with ENAMETOOLONG — reported to the user as a storage problem they
    /// could not act on (#PERSIST-NAME). The display name is untouched; only the filename is shortened.
    nonisolated private static let maxComponentBytes = 255
    /// Cut a sanitized filename stem so `stem.<ext>` fits the filesystem's per-component budget, dropping
    /// whole Characters so a multi-byte name is never sliced mid-sequence.
    nonisolated static func trimmedStem(_ stem: String, ext: String) -> String {
        let budget = maxComponentBytes - (ext.utf8.count + 1)   // 1 for the "."
        guard budget > 0 else { return stem }
        var out = stem
        while out.utf8.count > budget, !out.isEmpty { out.removeLast() }
        return out.isEmpty ? "Untitled Beat" : out
    }
    /// A stem with room left for a " copy N" / " (imported N)" suffix. The uniquing loops used to vary only
    /// the suffix of an over-length name, so every candidate truncated to the SAME 245-byte stem and
    /// `fileExists` stayed true forever — spinning the serial persistence queue (#persist-1).
    nonisolated static func uniqueBase(_ name: String, ext: String, reserve: Int = 24) -> String {
        let budget = maxComponentBytes - (ext.utf8.count + 1) - reserve
        var out = name
        while out.utf8.count > budget, !out.isEmpty { out.removeLast() }
        return out.isEmpty ? "Untitled Beat" : out
    }
    private func fileURL(_ name: String) -> URL {
        dir.appendingPathComponent("\(Self.trimmedStem(sanitize(name), ext: ext)).\(ext)")
    }

    /// Fire-and-forget UI refresh of the saved-project list (post save/delete/rename). The directory scan +
    /// cold-path header decode run OFF the main actor; `items` updates when done.
    func refresh() { Task { await reload() } }

    /// Awaitable variant: scans off the main actor and resolves once `items` is populated. The launch path
    /// awaits this so it can resolve the last project against a ready list (loadByID / items.first).
    @discardableResult
    func reload() async -> [SavedProject] {
        let dirURL = dir, fileExt = ext, autoStem = autosaveStem
        let cache = headerCache
        let result = await Task.detached(priority: .utility) {
            Self.scanProjects(dir: dirURL, ext: fileExt, autosaveStem: autoStem, cache: cache)
        }.value
        headerCache = result.cache
        items = result.items
        return result.items
    }

    /// Pure off-main scan: directory listing + per-file {id,name} header decode, reusing `cache` for unchanged
    /// files (same mtime+size → zero decode, #217). Returns the newest-first list + the pruned cache.
    nonisolated private static func scanProjects(dir: URL, ext: String, autosaveStem: String,
                                                 cache: [String: HeaderCacheEntry]) -> (items: [SavedProject], cache: [String: HeaderCacheEntry]) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var out: [SavedProject] = []
        var newCache: [String: HeaderCacheEntry] = [:]
        for u in urls where u.pathExtension == ext && u.deletingPathExtension().lastPathComponent != autosaveStem {
            let stem = u.deletingPathExtension().lastPathComponent
            let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? -1
            if let c = cache[u.path], c.mtime == mod, c.size == size {   // warm: unchanged → reuse cached header
                newCache[u.path] = c
                out.append(SavedProject(id: stem, projectID: c.id, name: c.name, modified: mod, url: u))
                continue
            }
            var nm = stem; var pid: String? = nil   // cold: decode ONLY the tiny {id,name} header
            if let data = try? Data(contentsOf: u),
               let h = try? JSONDecoder().decode(ProjectHeader.self, from: data) {
                if let n = h.name, !n.isEmpty { nm = n }
                pid = h.id
            }
            newCache[u.path] = HeaderCacheEntry(mtime: mod, size: size, id: pid, name: nm)
            out.append(SavedProject(id: stem, projectID: pid, name: nm, modified: mod, url: u))
        }
        return (out.sorted { $0.modified > $1.modified }, newCache)
    }

    /// JSON encode + atomic write run OFF the main actor (the save hitch for large projects); the
    /// bookkeeping + refresh resume on the main actor. ProjectSnapshot is Sendable so it crosses cleanly.
    @discardableResult
    func save(_ snap: ProjectSnapshot, touchLastOpened: Bool = true) async -> Bool {
        await save(ProjectSavePayload(snapshot: snap), touchLastOpened: touchLastOpened)
    }

    @discardableResult
    func save(_ payload: ProjectSavePayload, touchLastOpened: Bool = true) async -> Bool {
        let snap = payload.snapshot
        let url = fileURL(snap.name), samples = sampleDir, audio = audioDir
        let ok = await withCheckedContinuation { continuation in
            persistenceQueue.async {
                continuation.resume(returning: Self.writePayload(payload, to: url, samples: samples, audio: audio, pretty: true))
            }
        }
        // The refusal on missing audio is deliberate and stays (#PERSIST-CLIP — the WAV may be an in-flight
        // write that lands a moment later). What changed: the caller can now SEE which assets blocked the save
        // and offer an explicit "drop missing audio & save" instead of being stuck for the session (#persist-3).
        if ok { lastSaveMissing = [] } else {
            var check = snap
            if !payload.samplerAudio.isEmpty { check.sample?.audioFile = nil }
            lastSaveMissing = missingAudioAssets(in: check)
        }
        guard ok else { fdLog.error("project save error"); return false }
        // Importing a shared beat saves it into the library but must NOT become "the project the user was
        // working on": the import alert promises "Your current beat is still open", and on launch the app
        // resolves lastProjectID first, so rewriting these keys jumped the user into the imported beat (#IMPORT-LAST).
        if touchLastOpened {
            lastProjectName = snap.name
            lastProjectID = snap.id   // snapshot() always stamps a non-nil id by the time save() runs (#219)
        }
        // If the open project was previously saved under a different name, remove the stale file so a
        // name change via Save behaves as a MOVE, not an orphaning copy that shares this projectID (#219).
        if let pid = snap.id {
            for it in items where it.projectID == pid && it.url.path != url.path {
                try? FileManager.default.removeItem(at: it.url)
            }
        }
        refresh()
        return true
    }
    nonisolated static func writePayload(_ payload: ProjectSavePayload, to url: URL, samples: URL, audio: URL? = nil, pretty: Bool) -> Bool {
        var snapshot = payload.snapshot
        var writtenAudio: URL?
        // Refuse to publish a snapshot that references audio which is not on disk. Without this a Save could
        // report success while the take/sample it names was never written (or was deleted), and the loss only
        // surfaced after relaunch, once the in-memory PCM was gone. A fresh sampler buffer is exempt because
        // it is written (and re-pointed) below. (#PERSIST-CLIP)
        do {
            // Check clips + pad samples ALWAYS; only the sampler buffer is exempt when it is being written
            // below (the old whole-check skip let dangling clip refs through whenever a sample was loaded).
            var check = snapshot
            if !payload.samplerAudio.isEmpty { check.sample?.audioFile = nil }
            let missing = missingAudioAssets(in: check, audioDir: audio ?? fd808AudioDir(), sampleDir: samples)
            guard missing.isEmpty else {
                fdLog.error("project save refused: \(missing.count, privacy: .public) missing audio asset(s), first: \(missing.first ?? "", privacy: .public)")
                return false
            }
        }
        if !payload.samplerAudio.isEmpty {
            guard snapshot.sample != nil else { return false }
            // Immutable, content-addressed audio avoids rewriting a long take every autosave tick.
            // Include project identity and sample rate so unrelated projects never share mutable assets.
            var hash = SHA256()
            payload.samplerAudio.withUnsafeBytes { hash.update(bufferPointer: $0) }
            hash.update(data: Data("\(payload.sampleRate):\(snapshot.id ?? "")".utf8))
            let file = "sampler-" + hash.finalize().map { String(format: "%02x", $0) }.joined() + ".wav"
            let target = samples.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: target.path) {
                guard writeWAVData(payload.samplerAudio, to: target, sr: payload.sampleRate) else { return false }
                writtenAudio = target
            }
            snapshot.sample?.audioFile = file
        }
        guard writeSnapshot(snapshot, to: url, pretty: pretty) else {
            if let writtenAudio { try? FileManager.default.removeItem(at: writtenAudio) }
            return false
        }
        return true
    }

    /// Pure encode+atomic-write, safe to call off the main actor (no actor state touched).
    nonisolated static func writeSnapshot(_ snap: ProjectSnapshot, to url: URL, pretty: Bool) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        do { try enc.encode(snap).write(to: url, options: .atomic); return true } catch { return false }
    }
    /// Pure read+decode, safe to call off the main actor.
    nonisolated static func decodeSnapshot(_ url: URL) -> ProjectSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectSnapshot.self, from: d)
    }
    /// Read ONLY the tiny {id,name} header — no full-snapshot decode. Safe off the main actor.
    nonisolated static func decodeHeader(_ url: URL) -> ProjectHeader? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectHeader.self, from: d)
    }

    /// Read + decode OFF the main actor (no open hitch on large projects), then stamp the "last opened"
    /// keys back on the main actor.
    func load(_ item: SavedProject) async -> ProjectSnapshot? {
        let url = item.url
        guard let snap = await Task.detached(priority: .userInitiated, operation: { Self.decodeSnapshot(url) }).value else { return nil }
        lastProjectName = snap.name
        lastProjectID = snap.id
        return snap
    }

    func loadByName(_ name: String) async -> ProjectSnapshot? {
        let url = fileURL(name)
        return await Task.detached(priority: .userInitiated, operation: { Self.decodeSnapshot(url) }).value
    }

    /// Load the saved project whose embedded stable id matches (#219). Skips un-migrated
    /// (nil-id) files so nil never matches nil. Uses the cached `items` list to pick the file.
    func loadByID(_ id: String) async -> ProjectSnapshot? {
        for it in items where it.projectID == id {
            if let s = await load(it) { return s }
        }
        return nil
    }

    @discardableResult
    func delete(_ item: SavedProject, protecting: Set<String> = []) -> Bool {
        // A recovery slot holding THIS beat's unsaved edits must die with it: leaving it offered the deleted
        // work back at the next launch ("This can't be undone" was a lie) and let Recover overwrite whatever
        // beat was open then. A slot belonging to a DIFFERENT (open) beat must be left untouched (#RECOVERY-SLOT).
        let ownsRecoverySlot = Self.recoverySlotBelongsTo(item, slot: autosaveURL)
        do { try FileManager.default.removeItem(at: item.url) } catch { return false }
        if lastProjectName == item.name { lastProjectName = nil }
        if let pid = item.projectID, lastProjectID == pid { lastProjectID = nil }
        // Reclaim the deleted beat's audio NOW — deleting beats is the only thing the UI offers a full-disk
        // user, so waiting for a later launch's sweep (or for every other file to decode) freed nothing in
        // time. `protecting` carries the live session's asset names, which the sweep's 24h grace exists for
        // (undo restores a removed clip by re-reading its WAV — #PERSIST-01/02).
        if ownsRecoverySlot { clearAutosave(protecting: protecting) } else { reclaimOrphans(protecting: protecting) }
        refresh()
        return true
    }

    /// True when the hidden recovery slot holds `item`'s own unsaved work (stable id, falling back to the
    /// display name for un-migrated saves). Header-only decode — never a full snapshot read.
    nonisolated static func recoverySlotBelongsTo(_ item: SavedProject, slot: URL) -> Bool {
        guard let h = decodeHeader(slot) else { return false }
        if let id = h.id { return item.projectID == id }
        return h.name == item.name
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(name).path) }
    /// True when saving under `name` would clobber a DIFFERENT project — i.e. the target file exists and its
    /// embedded projectID differs from the open project's. Catches the sanitize-collision case the name-only
    /// guard missed (new project sharing a saved beat's name silently overwrote it) (#PERSIST-03).
    func wouldOverwriteDifferentProject(name: String, openID: String) -> Bool {
        let url = fileURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Fast path: the scanned list already holds the embedded id, so re-evaluating `body` while the typed
        // name resolves to an existing file must not full-read and fully decode a 99-track project on the
        // main thread (#PERSIST-HITCH). A legacy (nil-id) entry means "identity unknown" → confirm, as before.
        if let known = items.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
            guard let pid = known.projectID else { return true }
            return pid != openID
        }
        guard let pid = Self.decodeHeader(url)?.id else { return true }   // unreadable/legacy → be safe, confirm
        return pid != openID
    }

    private func decode(_ url: URL) -> ProjectSnapshot? { Self.decodeSnapshot(url) }   // rename/duplicate (infrequent, sync)
    private func writeSnap(_ snap: ProjectSnapshot, to url: URL) -> Bool { Self.writeSnapshot(snap, to: url, pretty: true) }
    /// True when `name` resolves to a file that belongs to a DIFFERENT project than `item`
    /// (so a rename to it would overwrite). sanitize() can collapse distinct names onto one file,
    /// so this checks the resolved path, not the raw string.
    func nameCollision(with name: String, excluding item: SavedProject) -> Bool {
        let url = fileURL(name)
        return url.path != item.url.path && FileManager.default.fileExists(atPath: url.path)
    }
    /// Rename a saved project (moves the file + rewrites the embedded name). (#211)
    /// Returns false WITHOUT writing if the target name belongs to a different project and `force` is
    /// false — the caller must confirm the overwrite first (mirrors the Save-overwrite flow), so a
    /// rename can never silently destroy another saved beat.
    @discardableResult
    func rename(_ item: SavedProject, to newName: String, force: Bool = false) -> Bool {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, var snap = decode(item.url) else { return false }
        if !force && nameCollision(with: clean, excluding: item) { return false }
        snap.name = clean
        let newURL = fileURL(clean)
        guard writeSnap(snap, to: newURL) else { return false }
        if newURL.path != item.url.path { try? FileManager.default.removeItem(at: item.url) }
        if lastProjectName == item.name { lastProjectName = clean }
        refresh()
        return true
    }
    /// Duplicate a saved project under "<name> copy". (#211)
    @discardableResult
    func duplicate(_ item: SavedProject) async -> Bool {
        let source = item.url, projects = dir, audio = audioDir, samples = sampleDir, fileExt = ext
        let ok = await withCheckedContinuation { continuation in
            persistenceQueue.async {
                guard let snap = Self.decodeSnapshot(source) else { continuation.resume(returning: false); return }
                let base = Self.uniqueBase(item.name, ext: fileExt)
                var name = "\(base) copy", i = 2
                func target(_ name: String) -> URL {
                    let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
                    // Same 255-byte component budget as fileURL: a long-named beat must stay duplicate-able.
                    return projects.appendingPathComponent("\(Self.trimmedStem(safe, ext: fileExt)).\(fileExt)")
                }
                while FileManager.default.fileExists(atPath: target(name).path) {
                    if i > 999 { name = "\(base) copy \(UUID().uuidString.prefix(6))"; break }   // bounded (#persist-1)
                    name = "\(base) copy \(i)"; i += 1
                }
                continuation.resume(returning: Self.duplicateSnapshot(snap, name: name, target: target(name), audioDir: audio, sampleDir: samples))
            }
        }
        if ok { refresh() }
        return ok
    }

    nonisolated private static func duplicateSnapshot(_ source: ProjectSnapshot, name: String, target: URL, audioDir: URL, sampleDir: URL) -> Bool {
        var snap = source
        snap.name = name
        snap.id = UUID().uuidString
        // Copy original WAV bytes rather than decode/re-encode: preserve sample rate and fidelity.
        var created: [URL] = []
        var committed = false
        defer { if !committed { for url in created { try? FileManager.default.removeItem(at: url) } } }
        func copy(_ source: URL, to target: URL) throws {
            try FileManager.default.copyItem(at: source, to: target)
            created.append(target)
        }
        do {
            var remapped: [String: String] = [:]
            func copySample(_ old: String) throws -> String {
                guard Self.isAssetFilename(old) else { throw CocoaError(.fileReadInvalidFileName) }
                if let new = remapped[old] { return new }
                let new = UUID().uuidString + ".wav"
                try copy(sampleDir.appendingPathComponent(old), to: sampleDir.appendingPathComponent(new))
                remapped[old] = new
                return new
            }
            for (pad, param) in snap.padParams {
                if let old = param.sampleFile { snap.padParams[pad]?.sampleFile = try copySample(old) }
            }
            if let old = snap.sample?.audioFile { snap.sample?.audioFile = try copySample(old) }
            if var clips = snap.audioClips {
                for i in clips.indices {
                    guard UUID(uuidString: clips[i].id) != nil else { return false }
                    let old = clips[i].id, new = UUID().uuidString
                    try copy(audioDir.appendingPathComponent("\(old).wav"), to: audioDir.appendingPathComponent("\(new).wav"))
                    let right = audioDir.appendingPathComponent("\(old).R.wav")
                    if FileManager.default.fileExists(atPath: right.path) {
                        try copy(right, to: audioDir.appendingPathComponent("\(new).R.wav"))
                    } else {
                        clips[i].isStereo = false   // only the left channel was copied → the copy is honestly mono
                    }
                    clips[i].id = new
                }
                snap.audioClips = clips
            }
            guard Self.writeSnapshot(snap, to: target, pretty: true) else { return false }
            committed = true
        } catch { return false }
        return true
    }

    // MARK: - Project-file share / import (.fd808)

    /// One self-contained shareable file: the snapshot plus every referenced audio asset (recorded
    /// takes, pad one-shots, the sampler buffer) as raw WAV bytes. JSON container — no archive
    /// framework needed, tolerant to future fields, and safe to validate on import.
    nonisolated struct ProjectArchive: Codable, Sendable {
        var version = 1
        var snapshot: ProjectSnapshot
        var clipWAVs: [String: Data] = [:]       // FD808Audio/<id>.wav (+ .R.wav) → file bytes
        var padSampleWAVs: [String: Data] = [:]  // FD808Samples/<file> → file bytes
    }

    /// Bundle a snapshot + its audio into a shareable `.fd808` file in a fresh export batch dir.
    func exportArchive(_ snap: ProjectSnapshot) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            guard let data = Self.buildArchive(snap) else { return nil }
            let safe = snap.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            let url = fd808ExportDir().appendingPathComponent("\(safe.isEmpty ? "FD808 Beat" : safe).fd808")
            do { try data.write(to: url); return url } catch { return nil }
        }.value
    }

    nonisolated static func buildArchive(_ snap: ProjectSnapshot) -> Data? {
        var arc = ProjectArchive(snapshot: snap)
        let audioDir = fd808AudioDir(), sampleDir = fd808SampleDir()
        for c in snap.audioClips ?? [] {
            guard UUID(uuidString: c.id) != nil,
                  let left = try? Data(contentsOf: audioDir.appendingPathComponent("\(c.id).wav")), !left.isEmpty else { return nil }
            arc.clipWAVs["\(c.id).wav"] = left
            let right = audioDir.appendingPathComponent("\(c.id).R.wav")
            if FileManager.default.fileExists(atPath: right.path) {
                guard let bytes = try? Data(contentsOf: right) else { return nil }
                arc.clipWAVs["\(c.id).R.wav"] = bytes
            }
        }
        var sampleFiles = Set<String>()
        for (_, pp) in snap.padParams { if let f = pp.sampleFile { sampleFiles.insert(f) } }
        if let f = snap.sample?.audioFile { sampleFiles.insert(f) }
        for f in sampleFiles {
            guard Self.isAssetFilename(f), let d = try? Data(contentsOf: sampleDir.appendingPathComponent(f)), !d.isEmpty else { return nil }
            arc.padSampleWAVs[f] = d
        }
        guard let data = try? JSONEncoder().encode(arc), data.count <= 256 * 1024 * 1024 else { return nil }
        return data
    }

    /// Import a shared `.fd808` file as a NEW saved project — fresh stable id, fresh asset filenames
    /// and a unique name, so an import can never overwrite or cross-link an existing project.
    /// Returns the saved snapshot, or nil if the file couldn't be read/validated.
    func importArchive(from url: URL) async -> ProjectSnapshot? {
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 256 * 1024 * 1024 else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data else { return nil }
        guard var snap = await Task.detached(priority: .userInitiated, operation: { Self.unpackArchive(data) }).value else { return nil }
        if exists(snap.name) {
            let base = Self.uniqueBase(snap.name, ext: ext)
            var nm = "\(base) (imported)"; var i = 2
            while exists(nm) {
                if i > 999 { nm = "\(base) (imported \(UUID().uuidString.prefix(6)))"; break }   // bounded (#persist-1)
                nm = "\(base) (imported \(i))"; i += 1
            }
            snap.name = nm
        }
        guard await save(snap, touchLastOpened: false) else {
            // unpackArchive minted every filename; none belongs to an existing project.
            for clip in snap.audioClips ?? [] {
                if let id = UUID(uuidString: clip.id) { deleteClipWAV(id: id) }
            }
            for param in snap.padParams.values { if let file = param.sampleFile { deletePadSampleWAV(file: file) } }
            if let file = snap.sample?.audioFile { deletePadSampleWAV(file: file) }
            return nil
        }
        return snap
    }

    nonisolated static func unpackArchive(_ data: Data) -> ProjectSnapshot? {
        guard data.count <= 256 * 1024 * 1024,
              let arc = try? JSONDecoder().decode(ProjectArchive.self, from: data), arc.version == 1 else { return nil }
        var snap = arc.snapshot
        snap.id = UUID().uuidString
        let audioDir = fd808AudioDir(), sampleDir = fd808SampleDir()
        var created: [URL] = []
        var committed = false
        defer { if !committed { for url in created { try? FileManager.default.removeItem(at: url) } } }
        func write(_ bytes: Data?, to url: URL) throws {
            guard let bytes, !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try bytes.write(to: url, options: .atomic)
            created.append(url)
            guard (try? AVAudioFile(forReading: url)) != nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        do {
            if var clips = snap.audioClips {
                for i in clips.indices {
                    let old = clips[i].id, new = UUID().uuidString
                    try write(arc.clipWAVs["\(old).wav"], to: audioDir.appendingPathComponent("\(new).wav"))
                    if let right = arc.clipWAVs["\(old).R.wav"] {
                        try write(right, to: audioDir.appendingPathComponent("\(new).R.wav"))
                    } else {
                        clips[i].isStereo = false   // the archive carried no right channel → import as mono
                    }
                    clips[i].id = new
                }
                snap.audioClips = clips
            }
            var remapped: [String: String] = [:]
            func imported(_ old: String) throws -> String {
                if let new = remapped[old] { return new }
                let new = UUID().uuidString + ".wav"
                try write(arc.padSampleWAVs[old], to: sampleDir.appendingPathComponent(new))
                remapped[old] = new
                return new
            }
            for (pad, param) in snap.padParams {
                if let old = param.sampleFile { snap.padParams[pad]?.sampleFile = try imported(old) }
            }
            if let old = snap.sample?.audioFile { snap.sample?.audioFile = try imported(old) }
        } catch { return nil }
        committed = true
        return snap
    }

    // MARK: - Autosave / crash recovery (#206)

    /// Write the current state to the hidden recovery slot (no list refresh, no lastProject change).
    /// Cheap to call on scenePhase changes; the arrangement is what matters (sample WAVs aren't re-flushed here).
    func autosave(_ snap: ProjectSnapshot) { autosave(ProjectSavePayload(snapshot: snap)) }
    func autosave(_ payload: ProjectSavePayload, completion: (@Sendable () -> Void)? = nil) {
        let url = autosaveURL, samples = sampleDir, audio = audioDir
        persistenceQueue.async { [weak self] in
            let ok = Self.writePayload(payload, to: url, samples: samples, audio: audio, pretty: false)
            if !ok { fdLog.error("Recovery save failed; keeping previous recovery file") }
            // Report the outcome to the UI: a full disk silently killed the crash safety net (#PERSIST-RECOVERY).
            Task { @MainActor in self?.noteRecoveryWrite(ok) }
            completion?()
        }
    }
    /// Consecutive recovery-slot write failures. RootView surfaces this as a banner — the periodic slot is
    /// the only protection for a long unsaved session, so it must never stop working invisibly.
    @Published private(set) var recoveryWriteFailures = 0
    var recoveryWriteFailed: Bool { recoveryWriteFailures > 0 }
    /// Record the outcome of a recovery write: consecutive failures raise the banner, one success clears it.
    func noteRecoveryWrite(_ ok: Bool) {
        if ok { recoveryWriteFailures = 0 } else { recoveryWriteFailures += 1 }
    }
    func autosaveSnapshot() async -> ProjectSnapshot? {
        let url = autosaveURL
        return await withCheckedContinuation { continuation in
            persistenceQueue.async { continuation.resume(returning: Self.decodeSnapshot(url)) }
        }
    }
    /// Recovery is compared to the matching project, never an unrelated recent save.
    func hasFreshAutosave() -> Bool {
        guard let snap = Self.decodeSnapshot(autosaveURL),
              let modified = try? autosaveURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        let matching = items.filter { item in
            if let id = snap.id { return item.projectID == id }
            return item.name == snap.name
        }
        return modified > (matching.map(\.modified).max() ?? .distantPast)
    }
    /// Drop the recovery slot. The slot's payload may have written a content-addressed sampler WAV that
    /// nothing else references, so the files only the slot needed are reclaimed immediately instead of
    /// lingering until a later launch's sweep. `protecting` carries the live session's assets, which the
    /// launch sweep's grace exists for (undo restores a removed clip from its WAV — #PERSIST-01/02).
    func clearAutosave(protecting: Set<String> = []) {
        let url = autosaveURL, projectDir = dir, projectExt = ext, audio = audioDir, samples = sampleDir
        persistenceQueue.async {
            try? FileManager.default.removeItem(at: url)
            Self.sweepOrphanWAVs(projectDir: projectDir, ext: projectExt, audioDir: audio, sampleDir: samples,
                                 grace: 0, protecting: protecting)
        }
    }
    /// Reclaim unreferenced WAVs now (no 24h grace) — used after an explicit user deletion, the one action
    /// the UI offers a full-disk user.
    func reclaimOrphans(protecting: Set<String> = []) {
        let projectDir = dir, projectExt = ext, audio = audioDir, samples = sampleDir
        persistenceQueue.async {
            Self.sweepOrphanWAVs(projectDir: projectDir, ext: projectExt, audioDir: audio, sampleDir: samples,
                                 grace: 0, protecting: protecting, force: true)   // explicit delete path
        }
    }
    /// A pad sample WAV is present and non-empty in this store's sample directory.
    func padSampleIsReadable(_ file: String) -> Bool { Self.readableAudio(sampleDir.appendingPathComponent(file)) }
    nonisolated static func isAssetFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    // MARK: - Orphan WAV garbage collection (#209/#225)

    /// Delete WAVs in FD808Audio / FD808Samples that NO saved project (or the autosave slot) references,
    /// reclaiming storage leaked by deleted clips/samples/projects. Cheap one-shot; call on launch.
    func sweepOrphanWAVs() {
        let projectDir = dir, projectExt = ext, audio = audioDir, samples = sampleDir
        Task.detached(priority: .utility) {
            Self.sweepOrphanWAVs(projectDir: projectDir, ext: projectExt, audioDir: audio, sampleDir: samples)
        }
    }

    /// `grace` is the minimum age before an unreferenced file may be reclaimed: the launch sweep keeps 24h
    /// so a WAV still reachable from an in-session undo stack survives, while an explicit delete passes 0
    /// with the live session's names in `protecting`. A project file that cannot be read is SKIPPED, never
    /// fatal — the old `return` let ONE bad save disable reclamation for the whole library (#PERSIST-GC).
    nonisolated static func sweepOrphanWAVs(projectDir dir: URL, ext: String,
                                            audioDir: URL? = nil, sampleDir: URL? = nil,
                                            grace: TimeInterval = 86_400, protecting: Set<String> = [],
                                            force: Bool = false) {
        let refs = referencedAssets(projectDir: dir, ext: ext)
        // One undecodable project file (corrupt, or written by a newer build) means the keep-set is
        // incomplete — sweeping would delete the very WAVs that could rebuild it. Skip until it decodes (#persist-2).
        // Only an EXPLICIT project delete (`force`) overrides that — a corrupt sibling must not disable the one
        // storage action a full-disk user has (#PERSIST-GC); the routine grace-0 sweeps after every save/open
        // stay gated (round 3, persist-1).
        guard refs.complete || force else { fdLog.error("orphan sweep skipped: a project file could not be decoded"); return }
        sweepDir(audioDir ?? fd808AudioDir(), keep: refs.audio.union(protecting), grace: grace)
        sweepDir(sampleDir ?? fd808SampleDir(), keep: refs.samples.union(protecting), grace: grace)
    }

    /// Asset filenames referenced by every project file in `dir` (the hidden recovery slot included).
    /// Purely a read; an unreadable project file is skipped so the others still count as referenced.
    nonisolated static func referencedAssets(projectDir dir: URL, ext: String) -> (audio: Set<String>, samples: Set<String>, complete: Bool) {
        var audioFiles = Set<String>()    // FD808Audio/<uuid>.wav (+ the paired .R.wav)
        var sampleFiles = Set<String>()   // FD808Samples/<file>
        var complete = true
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return (audioFiles, sampleFiles, false) }
        for u in urls where u.pathExtension == ext {
            guard let data = try? Data(contentsOf: u),
                  let snap = try? JSONDecoder().decode(ProjectSnapshot.self, from: data) else { complete = false; continue }
            for c in snap.audioClips ?? [] { audioFiles.insert("\(c.id).wav"); audioFiles.insert("\(c.id).R.wav") }   // keep the paired stereo right channel
            for (_, pp) in snap.padParams { if let f = pp.sampleFile { sampleFiles.insert(f) } }
            if let f = snap.sample?.audioFile { sampleFiles.insert(f) }
        }
        return (audioFiles, sampleFiles, complete)
    }
    nonisolated static func sweepDir(_ d: URL, keep: Set<String>, grace: TimeInterval = 86_400) {
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date().addingTimeInterval(-grace)
        for f in files where f.pathExtension == "wav" && !keep.contains(f.lastPathComponent) {
            guard let date = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - Load-time audio integrity check (Phase 8)

    /// Which audio assets a snapshot references but are MISSING on disk — the inverse of `sweepOrphanWAVs`'s
    /// enumeration. Returns human-readable names so the app can warn ("3 audio files missing") rather than
    /// silently playing nothing. Purely a read; never deletes or mutates. `writePayload` uses the same check
    /// to refuse a save that would publish references to absent audio (#PERSIST-CLIP).
    /// Present AND readable with at least one frame — a 0-frame or truncated WAV passed the old
    /// existence-only check, loaded as silence and was never reported (#persist-8).
    nonisolated static func readableAudio(_ url: URL) -> Bool {
        // Size-based on purpose: every save/autosave runs this over every referenced asset, and opening an
        // AVAudioFile per file was ~36 decoder inits per 15 s tick on a take-heavy project (round 2, cross-3).
        // A WAV with nothing after its 44-byte header is the "present but empty" corruption this catches.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue else { return false }
        return size > 44
    }
    /// Off-main variant for the load paths (RootView launch load, ProjectsSheet open).
    func missingAudioAssetsAsync(in snap: ProjectSnapshot) async -> [String] {
        let a = audioDir, s = sampleDir
        return await Task.detached(priority: .userInitiated) { Self.missingAudioAssets(in: snap, audioDir: a, sampleDir: s) }.value
    }
    nonisolated static func missingAudioAssets(in snap: ProjectSnapshot, audioDir: URL, sampleDir: URL) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for c in snap.audioClips ?? [] {
            let label = c.name.isEmpty ? "Audio clip" : c.name
            let left = readableAudio(audioDir.appendingPathComponent("\(c.id).wav"))
            // A stereo take whose right file is gone (interrupted write/import) is NOT intact: it silently
            // plays back as mono. Checking only the left file reported such a project as healthy (#PERSIST-STEREO).
            let right = c.isStereo != true || fm.fileExists(atPath: audioDir.appendingPathComponent("\(c.id).R.wav").path)
            if !left { missing.append("\(label) (recorded take)") }
            else if !right { missing.append("\(label) (right channel)") }
        }
        for (pad, pp) in snap.padParams {
            guard let f = pp.sampleFile, !readableAudio(sampleDir.appendingPathComponent(f)) else { continue }
            missing.append("\(pp.sampleName ?? pad) (pad sample)")
        }
        if let f = snap.sample?.audioFile, !readableAudio(sampleDir.appendingPathComponent(f)) {
            missing.append("sampler buffer")
        }
        return missing
    }

    func missingAudioAssets(in snap: ProjectSnapshot) -> [String] {
        Self.missingAudioAssets(in: snap, audioDir: audioDir, sampleDir: sampleDir)
    }

    // MARK: - Project health check + repair (item 9)

    /// Return a structurally-repaired copy of a loaded snapshot so a corrupt/partial/stale project loads
    /// into a CLEAN state instead of dangling: clears dead sample-file refs (so they don't persist as
    /// orphans on the next save), drops orphaned audio clips, de-duplicates track/part IDs, and clamps
    /// out-of-range indices. `missingAudioAssets` still drives the user-facing "audio missing" warning
    /// (compute it on the RAW snapshot before calling this). Records what it fixed in `lastRepairs`.
    func repaired(_ snap: ProjectSnapshot) -> ProjectSnapshot {
        var s = snap
        s.synthPatch = s.synthPatch.validated()
        s.savedSynths = s.savedSynths.map { $0.validated() }
        var log: [String] = []
        let cleanMixer = s.mixer.mapValues { $0.sanitized() }
        if cleanMixer != s.mixer { s.mixer = cleanMixer; log.append("clamped out-of-range mixer levels") }   // (#cross-2)
        // Repair against THIS store's stores, not the global defaults, so a store pointed at a custom
        // library dir repairs the files it actually reads from.
        let sampleDir = self.sampleDir, audioDir = self.audioDir

        if let f = s.sample?.audioFile, !Self.readableAudio(sampleDir.appendingPathComponent(f)) {
            s.sample?.audioFile = nil; log.append("cleared dead sampler audio ref")
        }
        for (pad, pp) in s.padParams {
            if let f = pp.sampleFile, !Self.readableAudio(sampleDir.appendingPathComponent(f)) {
                s.padParams[pad]?.sampleFile = nil; s.padParams[pad]?.sampleName = nil; s.padParams[pad]?.sampleBank = nil
                log.append("cleared dead pad sample (\(pad))")
            }
        }
        if let clips = s.audioClips {
            var kept: [AudioClipMeta] = []
            var dropped = 0, changed = false
            for c in clips {
                guard Self.readableAudio(audioDir.appendingPathComponent("\(c.id).wav")) else { dropped += 1; changed = true; continue }
                if c.isStereo == true && !Self.readableAudio(audioDir.appendingPathComponent("\(c.id).R.wav")) {
                    // The right channel is gone, but the left take is real audio: keep it as an honest mono
                    // clip and say so, instead of leaving a "stereo" take that plays one channel (#PERSIST-STEREO).
                    var mono = c; mono.isStereo = false
                    kept.append(mono); changed = true
                    log.append("right channel missing on \(c.name.isEmpty ? c.id : c.name) — kept as mono")
                } else {
                    kept.append(c)
                }
            }
            if dropped > 0 { log.append("dropped \(dropped) orphan audio clip(s)") }
            if changed { s.audioClips = kept }
        }
        if let tracks = s.tracks {
            var seen = Set<String>(); let deduped = tracks.filter { seen.insert($0.id).inserted }
            if deduped.count != tracks.count { s.tracks = deduped; log.append("removed \(tracks.count - deduped.count) duplicate track id(s)") }
        }
        if let parts = s.parts {
            var seen = Set<String>(); let deduped = parts.filter { seen.insert($0.id).inserted }
            if deduped.count != parts.count { s.parts = deduped; log.append("removed \(parts.count - deduped.count) duplicate part id(s)") }
        }
        if let ap = s.activePart, ap != "lead", !(s.parts ?? []).contains(where: { $0.id == ap }) {
            s.activePart = "lead"; log.append("reset orphaned active part")
        }
        if !s.sequences.isEmpty, s.activeSeq < 0 || s.activeSeq >= s.sequences.count {
            s.activeSeq = min(max(0, s.activeSeq), s.sequences.count - 1); log.append("clamped out-of-range active sequence")
        }
        let cb = max(40, min(220, s.bpm)); if cb != s.bpm { s.bpm = cb; log.append("clamped out-of-range tempo") }
        let cbs = max(1, min(16, s.barSteps ?? 16)); if cbs != (s.barSteps ?? 16) { s.barSteps = cbs; log.append("clamped out-of-range step count") }
        lastRepairs = log
        return s
    }
}
