//
//  ObservableAUParameter.swift
//  FD808AU
//
//  Created by Dev 101 on 6/17/26.
//

import SwiftUI
import AudioToolbox
import os

private let log = Logger(subsystem: "com.FB-808.FD808AU", category: "ObservableAUParameter")

/// Address used by `ObservableAUParameter.detached()`. Far outside the address space this AU's
/// parameter tree uses (the spec only defines `gain == 0`), and never registered with a tree.
private let FD808AUUnavailableParameterAddress: AUParameterAddress = 0xFFFF_FFFF

/// Base-class for SwiftUI-capable AUParameterNodes
///
/// This implementation provides a central point AUParameterGroup nodes to build a set of
/// observable children, and also enables us to traverse the parameter tree using dynamicMemberLookup
/// and subscript notation (i.e. parameterTree.paramGroup.parameter)
///
/// This does *not* provide any of Swift's usual type-safety benefits: every accessor below degrades
/// to an inert node (and logs) when the tree does not contain what the caller asked for, because
/// this code runs inside the host's process and must never take the host's UI down with it.
@MainActor
@dynamicMemberLookup
class ObservableAUParameterNode {

    /// Create an ObservableAUParameterNode
    ///
    /// This creates the appropriate subclass, depending on the type of the passed in AUParameterNode
    class func create(_ parameterNode: AUParameterNode) -> ObservableAUParameterNode {
        switch parameterNode {
        case let parameter as AUParameter:
            return ObservableAUParameter(parameter)
        case let group as AUParameterGroup:
            return ObservableAUParameterGroup(group)
        default:
            // A malformed/unknown node type must NOT crash the extension UI — degrade to an empty group.
            log.error("Unexpected AUParameterNode subclass: \(String(describing: type(of: parameterNode)), privacy: .public)")
            return ObservableAUParameterGroup.empty()
        }
    }

    /// Nothing to release by default; subclasses that registered AUParameter observers override this.
    func tearDown() {}

    /// Best-effort stand-in for a node that is missing, malformed or of an unexpected type. Returns a
    /// detached, inert parameter (and an empty group for the group case) so every access path below
    /// can degrade instead of trapping inside the host's UI process.
    fileprivate static func degraded<T: ObservableAUParameterNode>() -> T? {
        if let parameter = ObservableAUParameter.detached() as? T { return parameter }
        if let group = ObservableAUParameterGroup.empty() as? T { return group }
        return nil
    }

    /// Degrading accessor used when the caller asks for a concrete node type (the chained access the
    /// plugin UI performs). A missing child or a type mismatch yields an inert node, never a trap.
    subscript<T: ObservableAUParameterNode>(dynamicMember identifier: String) -> T {
        if let groupSelf = self as? ObservableAUParameterGroup {
            if let node = groupSelf.children[identifier] {
                if let subNode = node as? T { return subNode }
                log.error("Parameter node '\(identifier, privacy: .public)' cannot be converted to the requested type")
            } else {
                log.error("Parameter group has no child '\(identifier, privacy: .public)' (have: \(groupSelf.children.keys.sorted().joined(separator: ", "), privacy: .public))")
            }
        } else {
            log.error("dynamicMember subscript is only valid on a group; called on \(String(describing: self), privacy: .public)")
        }
        guard let degraded: T = Self.degraded() else {
            // Only reachable if `T` is a node subclass this module does not define; every node type
            // the tree can produce is covered above.
            fatalError("Parameter node named \(identifier) cannot be converted to \(T.self)")
        }
        return degraded
    }

    subscript(dynamicMember identifier: String) -> ObservableAUParameterNode {
        guard let groupSelf = self as? ObservableAUParameterGroup else {
            log.error("dynamicMember subscript is only valid on a group; called on \(String(describing: self), privacy: .public)")
            return ObservableAUParameterGroup.empty()
        }
        guard let parameter = groupSelf.children[identifier] else {
            // Missing child (e.g. a malformed/incomplete tree) → empty node instead of a crash; chained
            // accesses keep degrading to no-ops rather than killing the extension UI.
            log.error("Parameter group has no child '\(identifier, privacy: .public)' (have: \(groupSelf.children.keys.sorted().joined(separator: ", "), privacy: .public))")
            return ObservableAUParameterGroup.empty()
        }
        return parameter
    }

    subscript(dynamicMember keyPath: ReferenceWritableKeyPath<ObservableAUParameter, Float>) -> Float {
        get {
            guard let p = self as? ObservableAUParameter else {
                log.error("value read on non-parameter node \(String(describing: self), privacy: .public)")
                return 0
            }
            return p[keyPath: keyPath]
        }
        set { (self as? ObservableAUParameter)?[keyPath: keyPath] = newValue }   // no-op on a non-parameter node
    }
}

/// An Observable version of AUParameterGroup
///
/// The primary purpose here is to expose observable versions of the group's child parameters.
///
final class ObservableAUParameterGroup: ObservableAUParameterNode {

    private(set) var children: [String: ObservableAUParameterNode]

    init(_ parameterGroup: AUParameterGroup) {
        children = parameterGroup.children.reduce(
            into: [String: ObservableAUParameterNode]()
        ) { dict, node in
            let observableNode = ObservableAUParameterNode.create(node)
            dict[node.identifier] = observableNode
        }
    }

    private init(empty: Void) { children = [:] }
    /// Safe fallback node for malformed/incomplete parameter trees (see ObservableAUParameterNode.create
    /// and the dynamicMember subscripts) — renders nothing instead of crashing the extension UI.
    static func empty() -> ObservableAUParameterGroup { ObservableAUParameterGroup(empty: ()) }

    /// Revoke every child's AUParameter observer (recursively).
    override func tearDown() { children.values.forEach { $0.tearDown() } }
}

/// An Observable version of AUParameter
///
/// ObservableAUParameter is intended to be used directly in SwiftUI views as an ObservedObject,
/// allowing us to expose a binding to the parameter's value, as well as associated parameter data,
/// like the minimum, maximum, and default values for the parameter.
///
/// The ObservableAUParameter can also manage automation event types by calling
/// `onEditingChanged()` whenever a UI element will change its editing state.
@Observable
final class ObservableAUParameter: ObservableAUParameterNode {

    private weak var parameter: AUParameter?
    private var observerToken: AUParameterObserverToken?
    private var editingState: EditingState = .inactive

    let min: AUValue
    let max: AUValue
    let displayName: String
    let defaultValue: AUValue
    let unit: AudioUnitParameterUnit

    init(_ parameter: AUParameter) {
        self.parameter = parameter
        self.value = parameter.value
        self.min = parameter.minValue
        self.max = parameter.maxValue
        self.displayName = parameter.displayName
        // AUParameter has no defaultValue property; the tree initializes its value from the spec.
        self.defaultValue = parameter.value
        self.unit = parameter.unit
        super.init()

        /// Use the parameter.token(byAddingParameterObserver:) function to monitor for parameter
        /// changes from the host. The only role of this callback is to update the UI if the value is changed by the host.
        /// The closure captures `self` weakly: the AUParameter owns the closure, so a strong capture
        /// would keep this object (and its view state) alive for the life of the audio unit, long
        /// after the tree that created it was replaced.
        self.observerToken = parameter.token { @Sendable [weak self] (_ address: AUParameterAddress, _ auValue: AUValue) in

            DispatchQueue.main.async { [weak self] in
                guard let self, address == self.parameter?.address else { return }
                
                // Don't update the UI if the user is currently interacting
                guard self.editingState == .inactive else { return }

                self.editingState = .hostUpdate
                self.value = auValue
                self.editingState = .inactive
            }
        }
    }

    /// A detached, inert parameter for malformed/incomplete trees: nothing is registered with a tree,
    /// writes go nowhere and no observer ever fires, so a host that hands us an unexpected tree still
    /// gets a (disabled-looking) control instead of a crash.
    static func detached() -> ObservableAUParameter {
        let orphan = AUParameterTree.createParameter(
            withIdentifier: "fd808Unavailable",   // AUParameter identifiers must be alphanumeric
            name: "Unavailable",
            address: FD808AUUnavailableParameterAddress,
            min: 0,
            max: 1,
            unit: .linearGain,
            unitName: nil,
            flags: [AudioUnitParameterOptions.flag_IsReadable, AudioUnitParameterOptions.flag_IsWritable],
            valueStrings: nil,
            dependentParameters: nil
        )
        return ObservableAUParameter(orphan)
    }

    /// Revoke the AUParameter observer. Idempotent. Without this the (host-owned) AUParameter keeps
    /// the observer registration alive after the ObservableAUParameter is gone.
    override func tearDown() {
        guard let token = observerToken else { return }
        observerToken = nil
        parameter?.removeParameterObserver(token)
    }

    var value: AUValue {
        didSet {
            /// If the editing state is .hostUpdate, don't propagate this back to the host
            guard editingState != .hostUpdate else { return }

            let automationEventType = resolveEventType()
            parameter?.setValue(
                value,
                originator: observerToken,
                atHostTime: 0,
                eventType: automationEventType
            )
        }
    }

    var boolValue: Bool {
       get {
		   value >= 0.5
        }
        set {
            value = newValue ? 1.0 : 0.0
        }
    }

    /// A callback for UI elements to notify the Parameter when UI editing state changes
    ///
    /// This is the core mechanism for ensuring correct automation behavior. With native SwiftUI elements like `Slider`,
    /// this method should be passed directly into the `onEditingChanged:` argument.
    ///
    /// As long as the UI Element correctly sets the editing state, then the ObservableAUParameter's calls to
    /// AUParameter.setValue will contain the correct automation event type.
    ///
    /// `onEditingChanged` should be called with `true` before the first value is sent, so that it can be sent with a
    /// `.touch` event. It's expected that `onEditingChanged` is called with a value of `false` to mark the end
    /// of interaction *after* the last value has been sent, since this is how SwiftUI's `Slider` and `Stepper` views behave.
    func onEditingChanged(_ editing: Bool) {
        if editing {
            editingState = .began
        } else {
            editingState = .ended

            // We set the value here again to prompt its `didSet` implementation, so that we can send the appropriate `.release` event.
            value = value
        }
    }

    private func resolveEventType() -> AUParameterAutomationEventType {
        let eventType: AUParameterAutomationEventType
        switch editingState {
        case .began:
            eventType = .touch
            editingState = .active
        case .ended:
            eventType = .release
            editingState = .inactive
        default:
            eventType = .value
        }
        return eventType
    }

    private enum EditingState {
        case inactive
        case began
        case active
        case ended
        case hostUpdate
    }
}

extension AUAudioUnit {
    // Can we subclass the Parameter tree to set that on the AUAudioUnit?

    @MainActor var observableParameterTree: ObservableAUParameterGroup? {
        guard let paramTree = self.parameterTree else { return nil }
        return ObservableAUParameterGroup(paramTree)
    }
}
