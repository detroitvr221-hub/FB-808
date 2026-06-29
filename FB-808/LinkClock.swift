//  LinkClock.swift — Ableton Link (A17) wireless tempo + beat sync.
//  Thin Swift wrapper over the LinkKit C API (ABLLink*, reached via the app
//  bridging header). Host-app ONLY — never import this from the FD808AU plugin.
//
//  Link works in mach host-time; FD-808's Transport schedules in engine
//  sample-time. `HostClock` bridges the two. All Link reads happen on the main
//  queue (the same queue the lookahead scheduler runs on), so we use the
//  *App* session-state API, not the real-time audio-thread one.

import Foundation
import Combine

// mach_absolute_time is the clock domain LinkKit expects for "host time at output".
enum HostClock {
    private static let tb: mach_timebase_info_data_t = {
        var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return i
    }()
    static func now() -> UInt64 { mach_absolute_time() }
    /// Convert a duration in seconds to mach ticks (the units of mach_absolute_time).
    static func ticks(forSeconds s: Double) -> UInt64 {
        guard s > 0 else { return 0 }
        let ns = s * 1_000_000_000.0
        return UInt64(ns * Double(tb.denom) / Double(tb.numer))
    }
}

@MainActor
final class LinkClock: ObservableObject {
    @Published private(set) var enabled = false      // user toggled Link on (this app)
    @Published private(set) var connected = false    // ≥1 other peer in the session
    @Published private(set) var tempo: Double = 120  // shared session tempo (for the UI)

    let quantum: Double = 4                           // 4 beats = one 4/4 bar
    private var link: OpaquePointer?                  // ABLLinkRef

    init(bpm: Double) {
        tempo = bpm
        link = ABLLinkNew(bpm)
        installCallbacks()
    }
    deinit { if let link { ABLLinkDelete(link) } }

    // MARK: state

    var isOn: Bool { guard let link else { return false }; return ABLLinkIsEnabled(link) }

    // Link invokes these on the main thread, so assumeIsolated is valid + synchronous.
    private func installCallbacks() {
        guard let link else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        ABLLinkSetSessionTempoCallback(link, { t, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<LinkClock>.fromOpaque(ctx).takeUnretainedValue().tempo = t }
        }, ctx)
        ABLLinkSetIsConnectedCallback(link, { c, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<LinkClock>.fromOpaque(ctx).takeUnretainedValue().connected = c }
        }, ctx)
        ABLLinkSetIsEnabledCallback(link, { e, ctx in
            guard let ctx else { return }
            MainActor.assumeIsolated { Unmanaged<LinkClock>.fromOpaque(ctx).takeUnretainedValue().enabled = e }
        }, ctx)
    }

    // MARK: scheduler reads (main queue) — App session state

    /// Current shared session tempo, or nil when Link is off.
    func sessionTempo() -> Double? {
        guard let link, ABLLinkIsEnabled(link) else { return nil }
        return ABLLinkGetTempo(ABLLinkCaptureAppSessionState(link))
    }
    /// Bar phase (0 ..< quantum) at a future host time, or nil when Link is off.
    func phase(atHostTime ht: UInt64) -> Double? {
        guard let link, ABLLinkIsEnabled(link) else { return nil }
        return ABLLinkPhaseAtTime(ABLLinkCaptureAppSessionState(link), ht, quantum)
    }
    /// Propose a tempo to the whole session (when the user changes FD-808's BPM).
    func proposeTempo(_ bpm: Double, atHostTime ht: UInt64) {
        guard let link, ABLLinkIsEnabled(link) else { return }
        let st = ABLLinkCaptureAppSessionState(link)
        ABLLinkSetTempo(st, bpm, ht)
        ABLLinkCommitAppSessionState(link, st)
    }
}
