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

    var quantum: Double = 4                           // beats per bar — Transport sets it from barSteps (3/4 = 3)
    private var link: OpaquePointer?                  // ABLLinkRef

    init(bpm: Double) {
        tempo = bpm
        link = ABLLinkNew(bpm)
        installCallbacks()
    }
    deinit { if let link { ABLLinkDelete(link) } }

    // MARK: state

    /// The app-defaults key LinkKit's constructor reads for its "Link enabled" preference
    /// (`boolForKey:` in ABLLink.o). ABLLinkIsEnabled is documented as only user-controllable, so this key
    /// is the flag every Link path is really gated on — nothing in the app wrote it. (#20)
    static let enabledDefaultsKey = "ABLLinkEnabledKey"

    /// The persisted enable flag, factored over a defaults store so the plumbing is testable without a live
    /// Link session (ABLLinkIsEnabled is a C call into the network stack).
    static func linkEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }
    static func setLinkEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledDefaultsKey)
    }

    var isOn: Bool { guard let link else { return false }; return ABLLinkIsEnabled(link) }

    /// Turn Link on/off from the UI. Writes the flag LinkKit reads (the only programmatic path to
    /// ABLLinkIsEnabled — it is documented as user-controlled and cached at construction), participates in
    /// the session network, and rebuilds the Link object so the change takes effect immediately instead of
    /// at the next launch. Without this the feature was unreachable dead code: no UI, no writer. (#20)
    func setEnabled(_ on: Bool, in defaults: UserDefaults = .standard) {
        Self.setLinkEnabled(on, in: defaults)
        enabled = on
        guard let old = link else { return }
        ABLLinkSetActive(old, on)
        rebuild(oldTempo: sessionTempo() ?? tempo)
    }

    /// Recreate the underlying Link object so its constructor re-reads the persisted enable flag, carrying
    /// the current session tempo over. Callbacks are reinstalled on the new instance.
    private func rebuild(oldTempo: Double) {
        if let old = link { ABLLinkDelete(old) }
        link = ABLLinkNew(oldTempo)
        installCallbacks()
        enabled = isOn
    }

    // LinkKit documents these session-state callbacks as "Invoked on the main thread" (ABLLink.h),
    // so assumeIsolated is valid. `passUnretained` is safe because `self` is app-lifetime and outlives
    // the Link object (ABLLinkDelete in deinit tears the callbacks down before self is released).
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

    /// The raw LinkKit handle, for LinkKit's own settings panel (peer name, Start/Stop Sync). (#20)
    var linkRef: OpaquePointer? { link }
}

#if canImport(UIKit)
import SwiftUI

/// LinkKit's own settings panel — the sanctioned UI for the Link options it owns (peer name, Start/Stop
/// Sync). Unlike the enable flag (mirrored by the Settings toggle), these have no C setter. (#20)
struct LinkSettingsView: UIViewControllerRepresentable {
    let clock: LinkClock

    func makeUIViewController(context: Context) -> UIViewController {
        guard let ref = clock.linkRef else { return UIViewController() }
        return ABLLinkSettingsViewController.instance(ref)
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#endif
