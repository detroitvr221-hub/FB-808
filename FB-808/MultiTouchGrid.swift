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
    let onDown: (String) -> Void
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
            haptic.prepare()
            for t in touches where padIndex(at: t.location(in: self)) != nil {
                let idx = padIndex(at: t.location(in: self))!
                held[ObjectIdentifier(t)] = idx
                c.onDown(c.padIDs[idx])
                haptic.impactOccurred(intensity: 0.7)
            }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let c = cfg else { return }
            for t in touches {
                let key = ObjectIdentifier(t)
                let now = padIndex(at: t.location(in: self))
                if now != held[key] {                            // slid across cells → release old, hit new
                    if let was = held[key] { c.onUp?(c.padIDs[was]) }
                    if let n = now { c.onDown(c.padIDs[n]); held[key] = n; haptic.impactOccurred(intensity: 0.6) }
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
