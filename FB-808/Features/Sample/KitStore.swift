//  KitStore.swift — downloadable sound-kit catalog hosted on Supabase Storage. Reads the public `kits`
//  table (catalog) + each kit's `manifest.json`, and downloads individual sample WAVs on demand (preview
//  or load-onto-pads). Public bucket → sample downloads need no auth; the catalog query uses the app's
//  existing anon key (SyncConfig). No zip decoding needed — samples are hosted individually.

import Foundation
import Combine
import CryptoKit
import FD808Engine

nonisolated enum KitStore {
    private static let downloads = AssetDownloadCache()
    nonisolated static var base: String { "https://\(SyncConfig.projectRef).supabase.co" }
    nonisolated private static var key: String { SyncConfig.anonKey }
    nonisolated private static func isOK(_ response: URLResponse) -> Bool {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return 200..<300 ~= status
    }

    nonisolated struct RemoteKit: Decodable, Identifiable, Equatable, Sendable {
        let slug: String
        let name: String
        let artist: String?
        let artist_url: String?
        let description: String?
        let categories: [String: Int]?
        let cover_path: String?
        let archive_path: String?
        let manifest_path: String?
        let size_bytes: Int?
        let file_count: Int?
        var id: String { slug }
    }
    nonisolated struct KitSample: Decodable, Identifiable, Hashable, Sendable {
        let category: String
        let name: String
        let path: String
        var id: String { path }
    }
    nonisolated private struct Manifest: Decodable { let samples: [KitSample] }

    /// Public URL for any object in the `kits` bucket (bucket is public-read).
    nonisolated static func publicURL(_ path: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?%")
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        // A malformed base/path must fail the download, not crash the app (round 3, cross-7).
        return URL(string: "\(base)/storage/v1/object/public/kits/\(encodedPath)") ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Fetch the kit catalog (the `public.kits` table via PostgREST).
    nonisolated static func fetchCatalog() async throws -> [RemoteKit] {
        guard let catalogURL = URL(string: "\(base)/rest/v1/kits?select=*&order=created_at.desc") else { throw URLError(.badURL) }
        var req = URLRequest(url: catalogURL)
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard isOK(response) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode([RemoteKit].self, from: data)
    }

    /// Fetch a kit's sample list from its manifest.json.
    nonisolated static func fetchSamples(_ kit: RemoteKit) async throws -> [KitSample] {
        let path = kit.manifest_path ?? "\(kit.slug)/manifest.json"
        let (data, response) = try await URLSession.shared.data(from: publicURL(path))
        guard isOK(response) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Manifest.self, from: data).samples
    }

    /// Persistent on-disk cache so a downloaded sample is never re-fetched.
    nonisolated private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KitFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static func cachedURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let readable = path
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
            ?? "sample"
        return cacheDir.appendingPathComponent("\(digest)-\(readable)")
    }
    nonisolated static func isCached(_ path: String) -> Bool { FileManager.default.fileExists(atPath: cachedURL(for: path).path) }

    /// Keep the on-disk kit cache under `maxBytes` (newest files win). Nothing ever evicted it before, so a
    /// browsing session could fill the device's storage (#export-7).
    nonisolated static func trimCache(maxBytes: Int = 512 * 1024 * 1024) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        for u in urls {
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            entries.append((u, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0))
        }
        entries.sort { $0.date > $1.date }   // newest first
        let recent = Date().addingTimeInterval(-600)   // never evict what an install in flight may be about to read
        var total = 0
        for e in entries {
            total += e.size
            if total > maxBytes && e.date < recent { try? fm.removeItem(at: e.url) }
        }
    }

    /// Return a local file URL for a storage object, downloading + caching it on first use. Returns nil on failure.
    nonisolated static func localFile(_ path: String) async -> URL? {
        let url = try? await downloads.file(from: publicURL(path), to: cachedURL(for: path))
        // Every path that fills the cache (preview, assign, MIDI, auto-map) keeps it bounded (round 3, export-2).
        if url != nil { Task.detached(priority: .utility) { trimCache() } }
        return url
    }

    /// Map a kit category to the drum pad it best fits (for one-tap "Auto-map to Pads").
    nonisolated static let categoryToPad: [String: String] = [
        "Kicks": "kick", "808": "sub808", "Snares": "snare", "Claps": "clap",
        "Hats": "hatClosed", "O-Hat": "hatOpen", "Perc": "perc", "SFX": "fx", "Chants": "conga",
    ]
}

/// Owns request ordering separately from SwiftUI so an older response cannot replace a newer kit.
@MainActor
final class KitDetailLoader: ObservableObject {
    @Published private(set) var samples: [KitStore.KitSample] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let fetch: @Sendable (KitStore.RemoteKit) async throws -> [KitStore.KitSample]
    init(fetch: @escaping @Sendable (KitStore.RemoteKit) async throws -> [KitStore.KitSample] = { try await KitStore.fetchSamples($0) }) {
        self.fetch = fetch
    }
    func reset() {
        task?.cancel(); task = nil; generation = UUID()
        samples = []; loading = false; error = nil
    }
    func open(_ kit: KitStore.RemoteKit) {
        reset(); loading = true
        let request = generation, fetch = fetch
        task = Task { [weak self] in
            do {
                let result = try await fetch(kit)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.samples = result; self.loading = false; self.task = nil
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.loading = false; self.task = nil
            }
        }
    }
}
