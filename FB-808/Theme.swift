//  Theme.swift — design tokens ported from the FD808 prototype CSS.
//  Three chassis themes (studio / arcade / cream), accent options, and the
//  font roles (Fredoka → rounded, Space Grotesk → default, Space Mono → monospaced).

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Color helpers

extension Color {
    nonisolated init(hex: String) {   // pure hex parser — usable from the nonisolated render/data paths
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        default: // RRGGBB
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Approximates CSS `color-mix(in oklab, self, other amount%)` with an sRGB lerp.
    /// (Named `blend` to avoid clashing with SwiftUI's built-in `mix(with:by:)`.)
    func blend(_ other: Color, _ amount: Double) -> Color {
        let a = RGBA(self), b = RGBA(other)
        let t = max(0, min(1, amount))
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t,
                     opacity: a.o + (b.o - a.o) * t)
    }

    func darker(_ amount: Double) -> Color { blend(.black, amount) }
    func lighter(_ amount: Double) -> Color { blend(.white, amount) }

    /// The standard top→bottom CTA fill (e.g. filled buttons): the color over a slightly darker shade.
    /// One source of truth so the ~two-dozen call sites stop drifting (they used 0.22/0.24/0.28).
    func ctaGradient() -> LinearGradient {
        LinearGradient(colors: [self, darker(0.22)], startPoint: .top, endPoint: .bottom)
    }

    /// "#RRGGBB" for persistence.
    func toHex() -> String {
        let c = RGBA(self)
        let r = Int((c.r * 255).rounded()), g = Int((c.g * 255).rounded()), b = Int((c.b * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    struct RGBA { var r = 0.0, g = 0.0, b = 0.0, o = 1.0
        init(_ c: Color) {
            #if canImport(UIKit)
            let ui = UIColor(c)
            var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            ui.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
            r = rr; g = gg; b = bb; o = aa
            #endif
        }
    }
}

// MARK: - Theme

enum ThemeName: String, CaseIterable, Identifiable {
    case studio, arcade, cream
    var id: String { rawValue }
}

struct Theme {
    var name: ThemeName

    // tokens
    var bg: Color
    var rail: Color
    var panel: Color
    var panel2: Color
    var capA: Color
    var capB: Color
    var ink: Color
    var inkDim: Color
    var inkFaint: Color
    var line: Color
    var line2: Color

    // semantic
    let good = Color(hex: "#7BE08A")
    let perfect = Color(hex: "#FFD36B")
    let miss = Color(hex: "#FF6B6B")
    let meterLow = Color(hex: "#4DD07A")

    /// Bottom→top level-meter gradient (green→amber→red), shared by the channel + track meters.
    var meterGradient: LinearGradient {
        LinearGradient(colors: [meterLow, perfect, miss], startPoint: .bottom, endPoint: .top)
    }

    var chassisGradient: [Color]   // diagonal base
    var chassisGlow: Color         // radial highlight

    static func make(_ name: ThemeName) -> Theme {
        switch name {
        case .studio:
            return Theme(
                name: .studio,
                bg: Color(hex: "#15151c"), rail: Color(hex: "#0e0e14"),
                panel: Color(hex: "#1d1f28"), panel2: Color(hex: "#23262f"),
                capA: Color(hex: "#2b2e3a"), capB: Color(hex: "#191b23"),
                ink: Color(hex: "#F2EEE3"), inkDim: Color(hex: "#9598a6"), inkFaint: Color(hex: "#8a8da0"),   // inkFaint lifted to clear WCAG AA (4.6:1)
                line: Color.white.opacity(0.08), line2: Color.white.opacity(0.05),
                chassisGradient: [Color(hex: "#1b1c24"), Color(hex: "#121319")],
                chassisGlow: Color.white.opacity(0.04))
        case .arcade:
            return Theme(
                name: .arcade,
                bg: Color(hex: "#08080e"), rail: Color(hex: "#06060c"),
                panel: Color(hex: "#0e0f1a"), panel2: Color(hex: "#15172a"),
                capA: Color(hex: "#1a1c30"), capB: Color(hex: "#0b0c16"),
                ink: Color(hex: "#EDEFFF"), inkDim: Color(hex: "#8a8db0"), inkFaint: Color(hex: "#8488ad"),   // inkFaint lifted to clear WCAG AA (5.1:1)
                line: Color.white.opacity(0.09), line2: Color.white.opacity(0.05),
                chassisGradient: [Color(hex: "#0c0d18"), Color(hex: "#06060d")],
                chassisGlow: Color(hex: "#6C7BFF").opacity(0.14))
        case .cream:
            return Theme(
                name: .cream,
                bg: Color(hex: "#e7dec8"), rail: Color(hex: "#ddd2b7"),
                panel: Color(hex: "#f4eede"), panel2: Color(hex: "#efe7d2"),
                capA: Color(hex: "#34363f"), capB: Color(hex: "#202229"),
                ink: Color(hex: "#2c2820"), inkDim: Color(hex: "#5f5746"), inkFaint: Color(hex: "#6f6755"),   // both darkened to clear WCAG AA on cream (6.2 / 4.8:1)
                line: Color(hex: "#3c321e").opacity(0.14), line2: Color(hex: "#3c321e").opacity(0.08),
                chassisGradient: [Color(hex: "#efe7d3"), Color(hex: "#e2d8be")],
                chassisGlow: Color.white.opacity(0.5))
        }
    }
}

// Accent swatch options offered in Settings (matches the prototype tweaks panel).
enum Accents {
    static let options = ["#FF6A2B", "#FF3D7F", "#21D0B2", "#6C7BFF"]
}

enum InterfaceLevel: String, CaseIterable, Identifiable {
    case beginner, creator, advanced
    var id: String { rawValue }
    var title: String {
        switch self { case .beginner: "Beginner"; case .creator: "Creator"; case .advanced: "Advanced" }
    }
    /// One-line description of what this tier reveals — rendered under the picker so the control isn't opaque.
    var summary: String {
        switch self {
        case .beginner: "Pads, Sequence, Synth, Theory, Learn"
        case .creator: "+ Sample, Tracks, Mixer (full production)"
        case .advanced: "+ Teacher / classroom hosting (everything)"
        }
    }
}

// MARK: - Fonts

enum FDFont {
    /// Scale a base point size with the user's Dynamic Type setting, **clamped** so this dense
    /// iPad-workstation layout (fixed-height pads / knobs / faders) doesn't overflow. At the default
    /// content size category the factor is ~1.0, so the app is pixel-identical to before; larger
    /// accessibility sizes scale up to ~1.35× rather than breaking the grid. (a11y Dynamic Type)
    static func scaled(_ size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let full = UIFontMetrics.default.scaledValue(for: size)
        let factor = Swift.max(1.0, Swift.min(1.35, full / size))
        return (size * factor).rounded()
        #else
        return size
        #endif
    }
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: scaled(size), weight: weight, design: .rounded)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: scaled(size), weight: weight, design: .monospaced)
    }
}

// MARK: - Design tokens (Batch E)

/// Canonical corner radii — values mirror the magic numbers already used across the app.
enum FDRadius {
    static let sm: CGFloat = 7
    static let md: CGFloat = 9
    static let xl: CGFloat = 14
}

/// One source of truth for the synth/melody bus label + swatch so Mixer, Tracks
/// and Perform read the same name & color (was "Melody"/#E879F9 in Tracks vs "Synth"/#9B8CFF in Mixer).
enum FDPalette {
    static let melodyName = "Synth"
    static let melody = Color(hex: "#B794F6")
    /// Dark ink used for text/glyphs on the bright "solo" (yellow) fill — one source of truth.
    static let soloInk = Color(hex: "#08240f")
}

extension Comparable {
    /// Clamp into a closed range — replaces the scattered `max(lo, min(hi, x))` idiom.
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
