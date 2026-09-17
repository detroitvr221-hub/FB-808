//
//  FD808AUMainView.swift
//  FD808AU
//
//  Branded plugin UI: output gain (host parameter), a preset stepper over the
//  full SynthPresets bank, and a small test keyboard so the instrument is
//  playable without an external MIDI controller.
//

import SwiftUI
import FD808Engine

/// Layout maths for the editor's fixed rows.
///
/// The content used to be a non-scrolling stack of fixed-height rows, so a host that gave the
/// plug-in a short window simply clipped the keyboard away. The rows now scroll vertically, and the
/// keys keep Apple's 44 pt minimum touch target: a narrow window scrolls the keyboard horizontally
/// instead of shrinking each key below a usable size.
enum FD808AULayout {
    static let minimumKeyWidth: CGFloat = 44
    static let keySpacing: CGFloat = 3
    static let keyboardHeight: CGFloat = 96

    /// Smallest editor the rows can still be used at; below this the content scrolls.
    static let minimumContentSize = CGSize(width: 360, height: 300)
    /// What the editor asks the host for.
    static let preferredContentSize = CGSize(width: 480, height: 340)

    struct KeyboardLayout: Equatable {
        var keyWidth: CGFloat
        var contentWidth: CGFloat
        var needsHorizontalScroll: Bool
    }

    /// Size `keyCount` keys into `availableWidth`, never below the touch-target minimum.
    static func keyboardLayout(keyCount: Int, availableWidth: CGFloat) -> KeyboardLayout {
        guard keyCount > 0 else {
            return KeyboardLayout(keyWidth: minimumKeyWidth, contentWidth: 0, needsHorizontalScroll: false)
        }
        let count = CGFloat(keyCount)
        let spacing = keySpacing * (count - 1)
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        let keyWidth = max(minimumKeyWidth, (width - spacing) / count)
        let contentWidth = keyWidth * count + spacing
        return KeyboardLayout(keyWidth: keyWidth,
                              contentWidth: contentWidth,
                              needsHorizontalScroll: contentWidth > width + 0.5)
    }
}

struct FD808AUMainView: View {
    var parameterTree: ObservableAUParameterGroup
    var audioUnit: FD808AUAudioUnit?

    @State private var presetIndex = 0

    private let accent = Color(red: 1.0, green: 0.42, blue: 0.17)   // #FF6A2B
    private let keys = Array(60...72)                                // one octave, C..C
    private let presets = SynthPresets.all

    /// The preset shown by the stepper: whatever the audio unit is actually playing.
    private var currentPresetIndex: Int {
        if let index = audioUnit?.factoryPresetIndex { return index }
        return presets.indices.contains(presetIndex) ? presetIndex : 0
    }

    var body: some View {
        // Scrolling keeps the preset row and the keyboard reachable in a short host window.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                header
                ParameterSlider(param: parameterTree.global.gain)
                presetRow
                keyboard
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.07))
        .foregroundStyle(.white)
        .onAppear { presetIndex = currentPresetIndex }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(accent).frame(width: 30, height: 30)
                .overlay(Text("808").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black))
            VStack(alignment: .leading, spacing: 1) {
                Text("FD-808").font(.system(size: 20, weight: .heavy))
                Text("AUv3 INSTRUMENT").font(.system(size: 9, weight: .bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private var presetRow: some View {
        HStack(spacing: 12) {
            Text("PRESET").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left.circle.fill") }
            Text(presets.indices.contains(currentPresetIndex) ? presets[currentPresetIndex].name : audioUnit?.patchName ?? "")
                .font(.system(size: 13, weight: .semibold)).frame(minWidth: 120)
            Button { step(1) } label: { Image(systemName: "chevron.right.circle.fill") }
        }
        .tint(accent)
    }

    private func step(_ delta: Int) {
        let n = presets.count
        guard n > 0 else { return }
        let next = ((currentPresetIndex + delta) % n + n) % n
        presetIndex = next
        // Route the selection through the audio unit so its reported preset stays in sync with the
        // patch it is actually playing.
        if let unit = audioUnit, unit.factoryPresets.indices.contains(next) {
            unit.currentPreset = unit.factoryPresets[next]
        } else {
            audioUnit?.applyPatch(presets[next])
        }
    }

    private var keyboard: some View {
        GeometryReader { proxy in
            let layout = FD808AULayout.keyboardLayout(keyCount: keys.count, availableWidth: proxy.size.width)
            ScrollView(.horizontal, showsIndicators: layout.needsHorizontalScroll) {
                HStack(spacing: FD808AULayout.keySpacing) {
                    ForEach(keys, id: \.self) { midi in
                        AUKey(accent: accent,
                              onDown: { audioUnit?.uiNoteOn(midi) },
                              onUp: { audioUnit?.uiNoteOff(midi) })
                            .frame(width: layout.keyWidth)
                    }
                }
                .frame(width: layout.contentWidth, alignment: .leading)
            }
        }
        .frame(height: FD808AULayout.keyboardHeight)
    }
}

/// A momentary key: note-on on touch-down, note-off on release.
private struct AUKey: View {
    let accent: Color
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var down = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(down ? accent : Color(white: 0.18))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !down { down = true; onDown() } }
                    .onEnded { _ in down = false; onUp() }
            )
    }
}
