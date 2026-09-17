//
//  ParameterSlider.swift
//  FD808AU
//
//  Created by Dev 101 on 6/17/26.
//

import SwiftUI
import AudioToolbox

/// A SwiftUI Slider container which is bound to an ObservableAUParameter
///
/// This view wraps a SwiftUI Slider, and provides it relevant data from the Parameter, like the minimum and maximum values.
struct ParameterSlider: View {
    /// The parameter-tree node to drive. Deliberately the *base* node type: a missing or malformed
    /// child arrives here as an empty group (never a concrete parameter), so a tree the AU did not
    /// expect renders nothing instead of trapping inside the host's UI process.
    let param: ObservableAUParameterNode

    /// The concrete parameter to drive, or nil when the tree handed us a node that is not a parameter.
    var resolved: ObservableAUParameter? { param as? ObservableAUParameter }

    private func specifier(for unit: AudioUnitParameterUnit) -> String {
        switch unit {
        case .midiNoteNumber:
            return "%.0f"
        default:
            return "%.2f"
        }
    }

    var body: some View {
        if let param = resolved {
            let specifier = specifier(for: param.unit)
            VStack {
                Slider(
                    value: Binding(get: { param.value }, set: { param.value = $0 }),
                    in: param.min...param.max,
                    onEditingChanged: { param.onEditingChanged($0) },
                    minimumValueLabel: Text("\(param.min, specifier: specifier)"),
                    maximumValueLabel: Text("\(param.max, specifier: specifier)")
                ) {
                    EmptyView()
                }
                .accessibility(identifier: param.displayName)
                Text("\(param.displayName): \(param.value, specifier: specifier)")
            }
            .padding()
        }
    }
}
