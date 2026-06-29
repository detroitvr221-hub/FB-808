//  Glossary.swift — plain-language definitions for the production controls,
//  surfaced as tap-to-learn "?" tips on knobs (and reusable anywhere via
//  `.infoTip(_:)`). Part of the teaching layer: the whole studio doubles as a
//  passive lesson when every control can explain itself.

import SwiftUI

enum Glossary {
    // Oscillator / pitch
    static let detune = "**Detune** spreads two copies of the oscillator slightly apart in pitch for a thicker, wider sound."
    static let octave = "**Octave** shifts the whole patch up or down in octaves — twelve semitones at a time."
    static let glide  = "**Glide** (portamento) slides smoothly in pitch from the last note into the next instead of jumping."
    static let fmAmount = "**FM** sets how hard a hidden sine modulator bends the oscillator's pitch thousands of times a second. 0 is your normal waveform; push it up for metallic, bell, or clangy tones."
    static let fmRatio  = "**Ratio** is the FM modulator's frequency relative to the note. Whole numbers (2, 3, 4) sound harmonic and musical; in-between values sound metallic or atonal."

    // Filter
    static let cutoff     = "**Cutoff** sets where the low-pass filter starts removing the highs. Lower sounds darker and muffled; higher sounds brighter and more open."
    static let resonance  = "**Resonance** boosts the frequencies right at the cutoff, adding a whistly emphasis or 'squelch'. High amounts can self-oscillate."
    static let filterEnv  = "**Filter Env** sweeps the cutoff over the life of a note — the source of that classic filter 'wow' as a sound opens up or closes down."
    static let drive      = "**Drive** overdrives the signal for warmth and grit. A little adds body; a lot adds distortion."

    // Amp envelope (ADSR)
    static let attack   = "**Attack** is how long the sound takes to reach full volume. Short is punchy; long is a slow swell or fade-in."
    static let decay    = "**Decay** is how quickly the sound falls from its peak down to the sustain level."
    static let sustain  = "**Sustain** is the volume a held note settles at after the attack and decay finish."
    static let release  = "**Release** is how long the sound takes to fade out after you let go of the note."
    static let level    = "**Level** is the overall output volume of the patch."

    // Master FX
    static let reverbMix  = "**Reverb** simulates sound bouncing around a space, adding depth and ambience. **Mix** blends in that wet reflection."
    static let reverbSize = "**Size** sets how big the reverb space feels — from a tight room to a huge hall."
    static let reverbDamp = "**Damp** rolls the highs off the reverb tail so it sounds warmer and less harsh."
    static let delayMix   = "**Delay** repeats the signal as distinct echoes. **Mix** sets how loud those echoes sit."
    static let delayTime  = "**Time** is the gap between echoes. Tap the sync chips (¼, ⅛, ⅛·) to lock it to the tempo."
    static let delayFbk   = "**Feedback** feeds each echo back into the delay, so more feedback means more repeats that take longer to fade."
}

// MARK: - Info tip

/// A small "?" badge that reveals a plain-language definition in a popover.
/// Drop it next to any control, or use `.infoTip(_:)` to anchor one in a corner.
struct InfoTip: View {
    @EnvironmentObject var settings: AppSettings
    let term: String
    let detail: String
    var size: CGFloat = 16
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "questionmark")
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(settings.inkFaint)
                .frame(width: size, height: size)
                .background(Circle().fill(settings.panel2))
                .overlay(Circle().stroke(settings.line, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(term)")
        .accessibilityHint("Shows an explanation")
        .popover(isPresented: $show) {
            VStack(alignment: .leading, spacing: 8) {
                Text(term.uppercased())
                    .font(FDFont.mono(11, .bold)).tracking(1.2)
                    .foregroundStyle(settings.accent)
                Text(.init(detail))
                    .font(FDFont.ui(13)).foregroundStyle(settings.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 264)
            .background(settings.panel)
            .presentationCompactAdaptation(.popover)
        }
    }
}

