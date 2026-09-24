import Foundation

/// A project's monitoring chain, including unavailable plugins so reopening on a different device
/// does not silently erase its settings. Property-list data preserves AU fullState value types.
nonisolated struct HostedEffectState: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var type: UInt32
    var subtype: UInt32
    var manufacturer: UInt32
    var state: Data?
}
