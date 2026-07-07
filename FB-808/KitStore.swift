//  KitStore.swift — downloadable sound-kit catalog hosted on Supabase Storage. Reads the public `kits`
//  table (catalog) + each kit's `manifest.json`, and downloads individual sample WAVs on demand (preview
//  or load-onto-pads). Public bucket → sample downloads need no auth; the catalog query uses the app's
//  existing anon key (SyncConfig). No zip decoding needed — samples are hosted individually.

import Foundation

enum KitStore {
    static var base: String { "https://\(SyncConfig.projectRef).supabase.co" }
    private static var key: String { SyncConfig.anonKey }

    struct RemoteKit: Decodable, Identifiable, Equatable {
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
    struct KitSample: Decodable, Identifiable, Hashable {
        let category: String
        let name: String
        let path: String
        var id: String { path }
    }
    private struct Manifest: Decodable { let samples: [KitSample] }

    /// Public URL for any object in the `kits` bucket (bucket is public-read).
    static func publicURL(_ path: String) -> URL { URL(string: "\(base)/storage/v1/object/public/kits/\(path)")! }

    /// Fetch the kit catalog (the `public.kits` table via PostgREST).
    static func fetchCatalog() async throws -> [RemoteKit] {
        var req = URLRequest(url: URL(string: "\(base)/rest/v1/kits?select=*&order=created_at.desc")!)
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode([RemoteKit].self, from: data)
    }

    /// Fetch a kit's sample list from its manifest.json.
    static func fetchSamples(_ kit: RemoteKit) async throws -> [KitSample] {
        let path = kit.manifest_path ?? "\(kit.slug)/manifest.json"
        let (data, _) = try await URLSession.shared.data(from: publicURL(path))
        return try JSONDecoder().decode(Manifest.self, from: data).samples
    }

    /// Persistent on-disk cache so a downloaded sample is never re-fetched.
    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KitFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func cachedURL(for path: String) -> URL {
        cacheDir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }
    static func isCached(_ path: String) -> Bool { FileManager.default.fileExists(atPath: cachedURL(for: path).path) }

    /// Return a local file URL for a storage object, downloading + caching it on first use. Returns nil on failure.
    static func localFile(_ path: String) async -> URL? {
        let dest = cachedURL(for: path)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: publicURL(path))
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch { return nil }
    }

    /// Map a kit category to the drum pad it best fits (for one-tap "Auto-map to Pads").
    static let categoryToPad: [String: String] = [
        "Kicks": "kick", "808": "sub808", "Snares": "snare", "Claps": "clap",
        "Hats": "hatClosed", "O-Hat": "hatOpen", "Perc": "perc", "SFX": "fx", "Chants": "conga",
    ]
}
