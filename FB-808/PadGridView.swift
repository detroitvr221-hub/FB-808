//  PadGridView.swift — the 4x4 MPC pad grid and a single tactile pad with
//  press ripple, follow-the-lights target ring, and hit feedback.

import SwiftUI

struct PadGridView: View {
    let pads: [PadDef]
    var showLabels: Bool = true
    var badges: [String: String]? = nil
    var mutedIDs: Set<String> = []     // pads shown as muted (red/dim) in Mute mode
    var maxSide: CGFloat = 600
    var onHit: (String, Double) -> Void   // padID, 0…1 strike velocity (#PADS-01)
    var onUp: ((String) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let side = min(min(geo.size.width, geo.size.height), maxSide)
            let gap: CGFloat = 16
            let cell = (side - gap * 3) / 4
            VStack(spacing: gap) {
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<4, id: \.self) { c in
                            let pad = pads[r * 4 + c]
                            // The SwiftUI pad is the VoiceOver/tap fallback (no pressure) → fixed default velocity;
                            // real strike velocity comes from the MultiTouchGrid overlay below.
                            PadView(pad: pad, showLabel: showLabels, badge: badges?[pad.id], muted: mutedIDs.contains(pad.id), onHit: { onHit($0, 0.85) }, onUp: onUp)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            // True multi-touch input layer (F6) — one UIKit surface over the grid so simultaneous hits /
            // rolls all sound; the visual pads below render hit feedback via PadFX.
            .overlay(MultiTouchGrid(cols: 4, rows: 4, cell: cell, gap: gap,
                                    padIDs: pads.map(\.id), onDown: onHit, onUp: onUp))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PadView: View {
    @EnvironmentObject var fx: PadFX
    @EnvironmentObject var settings: AppSettings
    let pad: PadDef
    var showLabel: Bool = true
    var badge: String? = nil
    var muted: Bool = false
    var onHit: (String) -> Void
    var onUp: ((String) -> Void)? = nil

    var body: some View {
        let th = settings.theme
        let glow = settings.glow
        let lit = fx.lit[pad.id]
        let fb = fx.feedback[pad.id]
        let pressCount = fx.press[pad.id] ?? 0
        let isLit = lit != nil

        ZStack {
            RoundedRectangle(cornerRadius: 19)
                .fill(LinearGradient(colors: [th.capA, th.capB], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 19)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center))
            RoundedRectangle(cornerRadius: 19).stroke(.black.opacity(0.5), lineWidth: 1)

            if isLit {
                RoundedRectangle(cornerRadius: 19)
                    .fill(RadialGradient(colors: [pad.color.opacity(0.55 * glow), .clear], center: .center, startRadius: 0, endRadius: 80))
                RoundedRectangle(cornerRadius: 19).stroke(pad.color, lineWidth: 2)
            }

            face(th)

            if pressCount > 0 {
                RippleView(color: pad.color, glow: glow).id(pressCount)
            }
            if let lit {
                TargetRing(color: pad.color, leadMs: lit.leadMs).id(lit.tk)
            }
            if let fb {
                FeedbackText(result: fb.result, theme: th).id(fb.tk)
            }
            if muted {   // Mute mode: red wash + border, like an MPC muted pad
                RoundedRectangle(cornerRadius: 19).fill(Color(hex: "#FF3B30").opacity(0.22))
                RoundedRectangle(cornerRadius: 19).stroke(Color(hex: "#FF3B30").opacity(0.9), lineWidth: 2)
                // Non-color cue so the muted state is conveyed without relying on red alone.
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: "#FF3B30"))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 13))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .compositingGroup()
        .opacity(muted ? 0.6 : 1)
        .shadow(color: isLit ? pad.color.opacity(0.5) : .black.opacity(0.4),
                radius: isLit ? 22 * glow : 8, x: 0, y: isLit ? 0 : 6)
        .contentShape(RoundedRectangle(cornerRadius: 19))
        // Touch input is handled by the grid-wide MultiTouchGrid surface (F6 multi-touch); this view only
        // renders (hit feedback comes from PadFX). Press animation follows the lit/feedback state.
        .scaleEffect(isLit ? 0.984 : 1)
        .animation(.easeOut(duration: 0.07), value: isLit)
        // VoiceOver: the touch surface isn't an a11y element, so expose each pad as a button with an action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(badge != nil ? "\(pad.label) level \(badge!)" : pad.label))
        .accessibilityValue(Text(muted ? "Muted" : ""))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onHit(pad.id); onUp?(pad.id) }
    }

    // Context-aware VoiceOver hint reflecting the active pad mode.
    private var accessibilityHintText: String {
        if muted { return "Muted pad. Double-tap to unmute." }
        if badge != nil { return "Velocity level pad. Double-tap to play." }
        return "Drum pad. Double-tap to play."
    }

    private func face(_ th: Theme) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 5).fill(pad.color)
                    .frame(width: 13, height: 13)
                    .shadow(color: pad.color.opacity(0.6), radius: 5)
                Spacer(minLength: 0)
                if showLabel {
                    Text(pad.label).font(FDFont.mono(12, .bold)).tracking(0.7)
                        .foregroundStyle(th.ink.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Text(badge ?? pad.key).font(FDFont.mono(11, .bold)).foregroundStyle(th.inkFaint)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 13, trailing: 13))
        .allowsHitTesting(false)
    }
}

// MARK: - FX layers

struct RippleView: View {
    let color: Color
    let glow: Double
    @State private var anim = false
    var body: some View {
        RoundedRectangle(cornerRadius: 19)
            .fill(RadialGradient(colors: [color.blend(.white, 0.1), color.opacity(0.7), .clear],
                                 center: .center, startRadius: 0, endRadius: 90))
            .opacity(anim ? 0 : 0.95 * glow)
            .scaleEffect(anim ? 1.04 : 1)
            .blendMode(.screen)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.42)) { anim = true } }
    }
}

struct TargetRing: View {
    let color: Color
    let leadMs: Double
    @State private var anim = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(color, lineWidth: 3)
            .shadow(color: color.opacity(0.5), radius: 7)
            .padding(6)
            .scaleEffect(anim ? 1 : 1.75)
            .opacity(anim ? 0.85 : 0.15)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.linear(duration: max(0.05, leadMs / 1000))) { anim = true } }
    }
}

struct FeedbackText: View {
    let result: String
    let theme: Theme
    @State private var up = false
    private var color: Color {
        switch result {
        case "perfect": return theme.good            // on time → green
        case "early": return Color(hex: "#FF9F1C")    // rushed → orange
        case "late": return Color(hex: "#C77DFF")     // dragged → purple
        case "good": return theme.perfect
        default: return theme.miss
        }
    }
    var body: some View {
        Text(result.uppercased())
            .font(FDFont.display(18, .bold))
            .foregroundStyle(color)
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            .offset(y: up ? -30 : -6)
            .opacity(up ? 0 : 1)
            .scaleEffect(up ? 1 : 0.9)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { up = true } }
    }
}
