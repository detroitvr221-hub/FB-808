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

struct FD808AUMainView: View {
    var parameterTree: ObservableAUParameterGroup
    var audioUnit: FD808AUAudioUnit?

    @State private var presetIndex = 0

    private let accent = Color(red: 1.0, green: 0.42, blue: 0.17)   // #FF6A2B
    private let keys = Array(60...72)                                // one octave, C..C

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ParameterSlider(param: parameterTree.global.gain)
            presetRow
            keyboard
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.07))
        .foregroundStyle(.white)
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
            Text(SynthPresets.all[presetIndex].name)
                .font(.system(size: 13, weight: .semibold)).frame(minWidth: 120)
            Button { step(1) } label: { Image(systemName: "chevron.right.circle.fill") }
        }
        .tint(accent)
    }

    private func step(_ delta: Int) {
        let n = SynthPresets.all.count
        presetIndex = ((presetIndex + delta) % n + n) % n
        audioUnit?.applyPatch(SynthPresets.all[presetIndex])
    }

    private var keyboard: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { midi in
                AUKey(accent: accent,
                      onDown: { audioUnit?.uiNoteOn(midi) },
                      onUp: { audioUnit?.uiNoteOff(midi) })
            }
        }
        .frame(height: 96)
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
