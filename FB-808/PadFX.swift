//  PadFX.swift — transient pad visual state shared across the grid:
//  press ripples, follow-the-lights target rings, and hit feedback.

import SwiftUI
import Combine

struct LitInfo: Equatable { var leadMs: Double; var tk: Int }
struct FBInfo: Equatable { var result: String; var tk: Int }   // perfect / good / miss

@MainActor
final class PadFX: ObservableObject {
    @Published var press: [String: Int] = [:]
    @Published var lit: [String: LitInfo] = [:]
    @Published var feedback: [String: FBInfo] = [:]

    func bump(_ id: String) { press[id, default: 0] += 1 }

    func setLit(_ id: String, leadMs: Double, tk: Int) { lit[id] = LitInfo(leadMs: leadMs, tk: tk) }
    func clearLit(_ id: String, tk: Int) { if lit[id]?.tk == tk { lit[id] = nil } }
    func clearAllLit() { lit.removeAll() }

    func showFeedback(_ id: String, _ result: String, tk: Int) { feedback[id] = FBInfo(result: result, tk: tk) }
    func clearFeedback(_ id: String) { feedback[id] = nil }
    func reset() { press.removeAll(); lit.removeAll(); feedback.removeAll() }
}
