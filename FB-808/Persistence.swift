//  Persistence.swift — save / load FD808 projects as JSON in the Documents dir.
//  The musical arrangement is fully serialized; the live sample buffer is not.
//  Audio-track clips are stored as WAVs in FD808Audio/<clip-id>.wav, referenced
//  by lightweight metadata in the snapshot (A5 Phase 4).

import SwiftUI
import Combine
import AVFoundation

// MARK: - Audio-clip file store

nonisolated func fd808AudioDir() -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let d = docs.appendingPathComponent("FD808Audio", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

// Mono 16-bit WAV writer shared by clip + pad-sample stores.
@discardableResult
nonisolated func writeWAVData(_ data: [Float], to url: URL, sr: Double = 48_000) -> Bool {
    guard !data.isEmpty else { return false }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    try? FileManager.default.removeItem(at: url)
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let pf = file.processingFormat
        let chunk = 16_384
        var i = 0
        while i < data.count {
            let count = min(chunk, data.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(count)),
                  let ch = buf.floatChannelData else { return false }
            buf.frameLength = AVAudioFrameCount(count)
            for j in 0..<count { ch[0][j] = data[i + j] }
            try file.write(from: buf)
            i += count
        }
        return true
    } catch { print("wav write error: \(error)"); return false }
}

nonisolated func readWAVData(at url: URL) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let fmt = file.processingFormat            // mono float @ 48 kHz (as written)
    let n = AVAudioFrameCount(file.length)
    guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
    do { try file.read(into: buf) } catch { return nil }
    guard let ch = buf.floatChannelData else { return nil }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
}

@discardableResult
nonisolated func writeClipWAV(_ data: [Float], id: UUID, sr: Double = 48_000) -> Bool {
    writeWAVData(data, to: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"), sr: sr)
}
nonisolated func readClipWAV(id: UUID) -> [Float]? {
    readWAVData(at: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"))
}
nonisolated func deleteClipWAV(id: UUID) {
    try? FileManager.default.removeItem(at: fd808AudioDir().appendingPathComponent("\(id.uuidString).wav"))
}

// MARK: - Pad-sample file store (imported drum one-shots, FD808Samples/<file>)

nonisolated func fd808SampleDir() -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let d = docs.appendingPathComponent("FD808Samples", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
@discardableResult
nonisolated func writePadSampleWAV(_ data: [Float], file: String, sr: Double = 48_000) -> Bool {
    writeWAVData(data, to: fd808SampleDir().appendingPathComponent(file), sr: sr)
}
nonisolated func readPadSampleWAV(file: String) -> [Float]? {
    readWAVData(at: fd808SampleDir().appendingPathComponent(file))
}
nonisolated func deletePadSampleWAV(file: String) {
    try? FileManager.default.removeItem(at: fd808SampleDir().appendingPathComponent(file))
}

struct SavedProject: Identifiable, Hashable {
    let id: String          // filename stem (file-system identity; Identifiable/list key)
    var projectID: String?  // stable embedded UUID (#219); nil for un-migrated name-keyed files
    var name: String
    var modified: Date
    var url: URL
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var items: [SavedProject] = []

    private let dir: URL
    private let ext = "fd808json"
    private let lastKey = "fd808.lastProject"     // legacy: last project by display name (back-compat)
    private let lastIDKey = "fd808.lastProjectID" // #219: last project by stable id (survives rename/collision)
    private let autosaveStem = "__autosave__"   // crash/quit recovery slot, hidden from the saved list

    // Lightweight name/id header — decodes the JSON object without allocating the 58 heavy snapshot fields.
    private struct ProjectHeader: Decodable { var id: String?; var name: String? }
    private struct HeaderCacheEntry { var mtime: Date; var size: Int; var id: String?; var name: String }
    private var headerCache: [String: HeaderCacheEntry] = [:]   // keyed by file path; reset per launch
    private var autosaveURL: URL { dir.appendingPathComponent("\(autosaveStem).\(ext)") }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("FD808Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        return cleaned.isEmpty ? "Untitled Beat" : cleaned
    }
    private func fileURL(_ name: String) -> URL { dir.appendingPathComponent("\(sanitize(name)).\(ext)") }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var out: [SavedProject] = []
        var seenPaths = Set<String>()
        for u in urls where u.pathExtension == ext && u.deletingPathExtension().lastPathComponent != autosaveStem {
            seenPaths.insert(u.path)
            let stem = u.deletingPathExtension().lastPathComponent
            let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mod = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? -1
            // Warm path: unchanged file (same mtime + size) reuses the cached header with zero decode (#217).
            if let c = headerCache[u.path], c.mtime == mod, c.size == size {
                out.append(SavedProject(id: stem, projectID: c.id, name: c.name, modified: mod, url: u))
                continue
            }
            // Cold path: decode ONLY the tiny {id, name} header, not the full 58-field snapshot.
            var nm = stem
            var pid: String? = nil
            if let data = try? Data(contentsOf: u),
               let h = try? JSONDecoder().decode(ProjectHeader.self, from: data) {
                if let n = h.name, !n.isEmpty { nm = n }
                pid = h.id
            }
            headerCache[u.path] = HeaderCacheEntry(mtime: mod, size: size, id: pid, name: nm)
            out.append(SavedProject(id: stem, projectID: pid, name: nm, modified: mod, url: u))
        }
        headerCache = headerCache.filter { seenPaths.contains($0.key) }   // drop entries for deleted files
        items = out.sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func save(_ snap: ProjectSnapshot) -> Bool {
        let url = fileURL(snap.name)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(snap).write(to: url, options: .atomic)
            lastProjectName = snap.name
            lastProjectID = snap.id   // snapshot() always stamps a non-nil id by the time save() runs (#219)
            // If the open project was previously saved under a different name, remove the stale file so a
            // name change via Save behaves as a MOVE, not an orphaning copy that shares this projectID (#219).
            if let pid = snap.id {
                for it in items where it.projectID == pid && it.url.path != url.path {
                    try? FileManager.default.removeItem(at: it.url)
                }
            }
            refresh()
            return true
        } catch {
            print("project save error: \(error)")
            return false
        }
    }

    func load(_ item: SavedProject) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: item.url),
              let snap = try? JSONDecoder().decode(ProjectSnapshot.self, from: data) else { return nil }
        lastProjectName = snap.name
        lastProjectID = snap.id
        return snap
    }

    func loadByName(_ name: String) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(name)),
              let snap = try? JSONDecoder().decode(ProjectSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Load the saved project whose embedded stable id matches (#219). Skips un-migrated
    /// (nil-id) files so nil never matches nil. Uses the cached `items` list to pick the file.
    func loadByID(_ id: String) -> ProjectSnapshot? {
        for it in items where it.projectID == id {
            if let s = load(it) { return s }
        }
        return nil
    }

    func delete(_ item: SavedProject) {
        try? FileManager.default.removeItem(at: item.url)
        if lastProjectName == item.name { lastProjectName = nil }
        if let pid = item.projectID, lastProjectID == pid { lastProjectID = nil }
        refresh()
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(name).path) }

    private func decode(_ url: URL) -> ProjectSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectSnapshot.self, from: d)
    }
    private func writeSnap(_ snap: ProjectSnapshot, to url: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(snap).write(to: url, options: .atomic)
    }
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
        writeSnap(snap, to: newURL)
        if newURL.path != item.url.path { try? FileManager.default.removeItem(at: item.url) }
        if lastProjectName == item.name { lastProjectName = clean }
        refresh()
        return true
    }
    /// Duplicate a saved project under "<name> copy". (#211)
    func duplicate(_ item: SavedProject) {
        guard var snap = decode(item.url) else { return }
        var nm = "\(item.name) copy"; var i = 2
        while exists(nm) { nm = "\(item.name) copy \(i)"; i += 1 }
        snap.name = nm
        snap.id = UUID().uuidString   // a copy is a NEW project — fresh stable id, else loadByID is ambiguous (#219)
        // Give the copy INDEPENDENT audio. Without this both projects reference the same WAVs, so editing
        // one (re-import/clear a pad sample, remove a clip) deletes the other's audio (#review).
        var newPads = snap.padParams
        for (pad, pp) in snap.padParams {
            guard let f = pp.sampleFile, let data = readPadSampleWAV(file: f) else { continue }
            let newFile = UUID().uuidString + ".wav"
            if writePadSampleWAV(data, file: newFile) { var p = pp; p.sampleFile = newFile; newPads[pad] = p }
        }
        snap.padParams = newPads
        if var s = snap.sample, let f = s.audioFile, let data = readPadSampleWAV(file: f) {
            let newFile = UUID().uuidString + ".wav"
            if writePadSampleWAV(data, file: newFile) { s.audioFile = newFile; snap.sample = s }
        }
        if let clips = snap.audioClips {
            snap.audioClips = clips.map { clip in
                var c = clip
                if let oldUUID = UUID(uuidString: clip.id), let data = readClipWAV(id: oldUUID) {
                    let newUUID = UUID()
                    if writeClipWAV(data, id: newUUID) { c.id = newUUID.uuidString }
                }
                return c
            }
        }
        writeSnap(snap, to: fileURL(nm))
        refresh()
    }

    // MARK: - Autosave / crash recovery (#206)

    /// Write the current state to the hidden recovery slot (no list refresh, no lastProject change).
    /// Cheap to call on scenePhase changes; the arrangement is what matters (sample WAVs aren't re-flushed here).
    func autosave(_ snap: ProjectSnapshot) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(snap) { try? data.write(to: autosaveURL, options: .atomic) }
    }
    func autosaveSnapshot() -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: autosaveURL) else { return nil }
        return try? JSONDecoder().decode(ProjectSnapshot.self, from: data)
    }
    /// True when a recovery file exists and is newer than every named save — i.e. the app was quit
    /// or crashed with unsaved edits. (`items` is sorted newest-first and excludes the recovery slot.)
    func hasFreshAutosave() -> Bool {
        guard let amod = try? autosaveURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        let newestNamed = items.first?.modified ?? .distantPast
        return amod > newestNamed.addingTimeInterval(1)
    }
    func clearAutosave() { try? FileManager.default.removeItem(at: autosaveURL) }

    // MARK: - Orphan WAV garbage collection (#209/#225)

    /// Delete WAVs in FD808Audio / FD808Samples that NO saved project (or the autosave slot) references,
    /// reclaiming storage leaked by deleted clips/samples/projects. Cheap one-shot; call on launch.
    func sweepOrphanWAVs() {
        var audioFiles = Set<String>()    // FD808Audio/<uuid>.wav
        var sampleFiles = Set<String>()   // FD808Samples/<file>
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in urls where u.pathExtension == ext {
            guard let data = try? Data(contentsOf: u),
                  let snap = try? JSONDecoder().decode(ProjectSnapshot.self, from: data) else { continue }
            for c in snap.audioClips ?? [] { audioFiles.insert("\(c.id).wav") }
            for (_, pp) in snap.padParams { if let f = pp.sampleFile { sampleFiles.insert(f) } }
            if let f = snap.sample?.audioFile { sampleFiles.insert(f) }
        }
        sweep(fd808AudioDir(), keep: audioFiles)
        sweep(fd808SampleDir(), keep: sampleFiles)
    }
    private func sweep(_ d: URL, keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "wav" && !keep.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
