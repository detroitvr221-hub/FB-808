//  AudioInputPicker.swift — SwiftUI bridge to the iOS 26 system audio-input picker.
//
//  2026 best practice (WWDC25 "Enhance your app's audio recording capabilities"): present
//  `AVInputPickerInteraction` so people switch input device IN-APP — built-in mic, wired, USB-C
//  interfaces (Focusrite etc.), Bluetooth — with live sound-level metering, microphone-mode
//  selection, and per-app persistence, all handled by the system (no trip to Settings, no custom
//  enumeration of the playback-vs-record session state). The app deploys to iOS 26.2, so the
//  native picker is always available.

import SwiftUI
import UIKit
import AVKit

/// A SwiftUI button that presents the system audio-input picker. Render any `label`; the system
/// sheet anchors to the button. The chosen input persists per-app and is applied to the engine's
/// record session automatically by the OS.
struct AudioInputPicker<Label: View>: View {
    var prepare: () -> Void = {}        // configure a record-capable session before presenting (WWDC25)
    var onDismiss: () -> Void = {}      // put the session back (`prepare` switches it to play-and-record)
    @ViewBuilder var label: Label
    @State private var host = InputPickerHost()

    var body: some View {
        Button { prepare(); host.present() } label: { label }
            .buttonStyle(.plain)
            // The interaction must live on a view sized/positioned like the button so the picker
            // anchors to it; it doesn't take touches (the SwiftUI Button drives `present()`).
            .overlay(InputPickerAnchor(host: host, onDismiss: onDismiss).allowsHitTesting(false))
            .accessibilityLabel(Text("Choose audio input device"))
            .accessibilityHint(Text("Pick the microphone or interface to record from"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Owns the interaction so `present()` survives view updates.
private final class InputPickerHost {
    let interaction = AVInputPickerInteraction()
    func present() { interaction.present() }
}

/// Hosts the `AVInputPickerInteraction` on a real UIView so the system picker has an anchor.
private struct InputPickerAnchor: UIViewRepresentable {
    let host: InputPickerHost
    let onDismiss: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        host.interaction.delegate = context.coordinator
        v.addInteraction(host.interaction)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onDismiss = onDismiss }
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    /// The dismissal callback is the only reason this delegate exists: `prepare` puts the session into
    /// play-and-record (HFP allowed, speaker default) so the picker can enumerate inputs, and nothing
    /// else would switch it back until the next route change (SETTINGS_AUDIT_2026-09-16 #2).
    final class Coordinator: NSObject, AVInputPickerInteraction.Delegate {
        var onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) { onDismiss() }
    }
}
