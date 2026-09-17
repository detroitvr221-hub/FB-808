//  FeatureFlags.swift — build-time switches for features that are finished in code but gated on
//  something outside the codebase (an Apple entitlement, a backend rollout).
//
//  Keep this file tiny and obvious: each flag says what unblocks it, so turning it on is a decision
//  someone can make without re-deriving the history.

import Foundation

enum FDFeature {
    /// Ableton Link (A17). The integration is complete — LinkKit is linked, `LinkClock` drives the
    /// real `ABLLink*` API, and Settings → Sync is written — but Link discovers peers over multicast
    /// UDP (group 224.76.78.75, port 20808), which iOS refuses without the RESTRICTED entitlement
    /// `com.apple.developer.networking.multicast`. That entitlement has to be requested from Apple at
    /// https://developer.apple.com/contact/request/networking-multicast and granted against the Team
    /// ID; reports put approval at roughly two weeks.
    ///
    /// Until it is granted, shipping the Sync card would give people a toggle that turns on and then
    /// reads "Peers · Searching…" forever with no explanation, so the card is hidden instead
    /// (RELEASE_AUDIT_2026-09-17 finding 2).
    ///
    /// To turn Link back on, BOTH steps are required, in this order:
    ///   1. Apple grants the entitlement, then add to `FB-808/FB-808.entitlements`:
    ///        <key>com.apple.developer.networking.multicast</key><true/>
    ///      Adding the key BEFORE it is granted breaks device builds and archives — a restricted
    ///      entitlement that is not on the Team ID cannot go into a provisioning profile. Simulator
    ///      builds keep working either way, so the simulator will not warn you.
    ///   2. Flip this flag to `true`.
    static let link = false
}
