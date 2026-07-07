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

    /// Download a sample WAV to a temp file (AVAudioFile decode needs a local URL). Returns nil on failure.
    static func downloadToTemp(_ path: String) async -> URL? {
        do {
            let (tmp, _) = try await URLSession.shared.download(from: publicURL(path))
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
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
