//  SyncConfig.swift — Supabase project endpoints for the live-classroom sync (SYSTEM_AUDIT Step 5/6).
//
//  The publishable (anon) key is a CLIENT key by design — it is safe to ship in the app because
//  Row-Level Security on the Postgres tables is the real trust boundary (a student can only read
//  their own room / write their own submission). The realtime BROADCAST hot path carries only
//  musical ops + a sanitized display name — never email or PII.

import Foundation

nonisolated enum SyncConfig {
    /// Supabase project ref + publishable (anon) key. Overridable at build time via Info.plist keys
    /// (`FDSupabaseProjectRef` / `FDSupabaseAnonKey`) so the key/ref can rotate without an app release —
    /// CI injects those values; the literals are dev fallbacks.
    /// An Info.plist value that is actually set. An undefined build setting expands to an EMPTY string
    /// rather than a missing key, and an unexpanded `$(…)` survives verbatim — either would otherwise be
    /// taken as a real endpoint and point the app at nothing (RELEASE_AUDIT finding 1).
    nonisolated private static func override(_ key: String) -> String? {
        guard let v = (Bundle.main.infoDictionary?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }
    static let projectRef: String = override("FDSupabaseProjectRef") ?? "caepbjuhwnglbyvlsowz"
    static let anonKey: String = override("FDSupabaseAnonKey") ?? "sb_publishable_I9C4_DndDxdxcVbv7ubtQQ_jKa8-Ddw"
    static let url = URL(string: "https://\(projectRef).supabase.co")!

    /// Realtime WebSocket endpoint (Phoenix channels protocol).
    static var realtimeURL: URL {
        URL(string: "wss://\(projectRef).supabase.co/realtime/v1/websocket?apikey=\(anonKey)&vsn=1.0.0")!
    }
    static func channelTopic(_ roomCode: String) -> String { "realtime:room:\(roomCode)" }
}
