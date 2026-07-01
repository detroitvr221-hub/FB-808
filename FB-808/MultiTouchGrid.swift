//  MultiTouchGrid.swift — true multi-touch finger drumming (F6).
//
//  SwiftUI per-view gestures can't reliably deliver SIMULTANEOUS touches to sibling pads (each pad's
//  own DragGesture serializes), so two-hand drumming and rolls drop hits. This is a single UIKit
//  surface laid over the 4×4 grid: it tracks EVERY active UITouch, hit-tests each to a pad, and fires
//  onDown/onUp per touch — so any number of pads sound at once. Sliding a finger onto a new pad
//  retriggers it (MPC-style rolls). VoiceOver is unaffected: the surface is not an accessibility
//  element, so VO still reaches each pad's `.accessibilityAction` underneath.

import SwiftUI
import UIKit

struct MultiTouchGrid: UIViewRepresentable {
    let cols: Int
    let rows: Int
    let cell: CGFloat
    let gap: CGFloat
    let padIDs: [String]
    let onDown: (String, Double) -> Void   // padID, 0…1 strike velocity (#PADS-01)
    let onUp: ((String) -> Void)?

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        v.apply(self)
        return v
    }
    func updateUIView(_ v: TouchView, context: Context) { v.apply(self) }

    final class TouchView: UIView {
        private var cfg: MultiTouchGrid?
        private var held: [ObjectIdentifier: Int] = [:]          // touch → pad index currently down
        private let haptic = UIImpactFeedbackGenerator(style: .rigid)

        func apply(_ c: MultiTouchGrid) { cfg = c }

        /// 0…1 strike velocity from finger pressure: 3D-touch/Pencil force when available, else contact
        /// radius (a flatter/harder hit reads wider), else a musical default. (#PADS-01)
        private func velocity(_ t: UITouch) -> Double {
            if t.maximumPossibleForce > 0, t.force > 0 {
                return max(0.15, min(1.0, Double(t.force / t.maximumPossibleForce)))
            }
            let r = Double(t.majorRadius)
            if r > 0 { return max(0.4, min(1.0, 0.4 + (r - 8) / 40)) }   // ~8pt→0.4 … ~48pt→1.0
            return 0.85
        }

        /// Map a point in the grid's own coordinates to a pad index, rejecting the gutters between cells.
        private func padIndex(at p: CGPoint) -> Int? {
            guard let c = cfg else { return nil }
            let stride = c.cell + c.gap
            guard stride > 0 else { return nil }
            let col = Int(p.x / stride), row = Int(p.y / stride)
            guard col >= 0, col < c.cols, row >= 0, row < c.rows else { return nil }
            guard p.x - CGFloat(col) * stride <= c.cell, p.y - CGFloat(row) * stride <= c.cell else { return nil }
            let idx = row * c.cols + col
            return idx < c.padIDs.count ? idx : nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let c = cfg else { return }
            let hapticsOn = Haptics.shared.enabled   // honor Settings → Haptics (was always-on here) (#PADS-05)
            if hapticsOn { haptic.prepare() }
            for t in touches where padIndex(at: t.location(in: self)) != nil {
                let idx = padIndex(at: t.location(in: self))!
                held[ObjectIdentifier(t)] = idx
                let v = velocity(t)
                c.onDown(c.padIDs[idx], v)
                if hapticsOn { haptic.impactOccurred(intensity: CGFloat(0.4 + v * 0.6)) }   // firmer hit → stronger tap
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let c = cfg else { return }
            for t in touches {
                let key = ObjectIdentifier(t)
                let now = padIndex(at: t.location(in: self))
                if now != held[key] {                            // slid across cells → release old, hit new
                    if let was = held[key] { c.onUp?(c.padIDs[was]) }
                    if let n = now { c.onDown(c.padIDs[n], velocity(t)); held[key] = n; if Haptics.shared.enabled { haptic.impactOccurred(intensity: 0.6) } }
                    else { held[key] = nil }
                }
            }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
        private func release(_ touches: Set<UITouch>) {
            guard let c = cfg else { return }
            for t in touches {
                let key = ObjectIdentifier(t)
                if let idx = held[key] { c.onUp?(c.padIDs[idx]); held[key] = nil }
            }
        }
    }
}
