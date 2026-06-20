//  AUHostView.swift — UI for the AUv3 host (A15). Browse installed 3rd-party
//  audio-effect plugins, insert them on the master bus, and open their own UI.
//  Note: the iOS Simulator registers no 3rd-party AUv3s — test on a device.

import SwiftUI
import AVFoundation
import CoreAudioKit

struct AUPluginsSheet: View {
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var available: [AVAudioUnitComponent] = []
    @State private var loadingName: String?
    @State private var openAU: AudioEngine.HostedAU?

    var body: some View {
        NavigationStack {
            List {
                Section("Master inserts") {
                    if engine.masterAUs.isEmpty {
                        Text("No plugins loaded").foregroundStyle(.secondary)
                    }
                    ForEach(engine.masterAUs) { au in
                        HStack {
                            Text(au.name)
                            Spacer()
                            Button { openAU = au } label: { Image(systemName: "slider.horizontal.3") }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) { engine.removeMasterAU(au.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Available effects") {
                    if available.isEmpty {
                        Text("No AUv3 effects found. Install some on your iPad — none register in the Simulator.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(available, id: \.self) { comp in
                        Button {
                            loadingName = comp.name
                            Task { _ = await engine.addMasterAU(comp); loadingName = nil }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(comp.name)
                                    Text(comp.manufacturerName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if loadingName == comp.name { ProgressView() }
                                else { Image(systemName: "plus.circle") }
                            }
                        }
                        .disabled(loadingName != nil)
                    }
                }
            }
            .navigationTitle("Plugins · AUv3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { available = AudioEngine.availableEffects() }
        .sheet(item: $openAU) { au in
            AUViewControllerHost(unit: au.unit).ignoresSafeArea()
        }
    }
}

/// Hosts a loaded plugin's own view controller (or CoreAudioKit's generic
/// parameter UI when the plugin ships no custom view).
struct AUViewControllerHost: UIViewControllerRepresentable {
    let unit: AVAudioUnit

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let au = unit.auAudioUnit
        au.requestViewController { vc in
            DispatchQueue.main.async {
                let child: UIViewController
                if let vc { child = vc }
                else {
                    let generic = AUGenericViewController()
                    generic.auAudioUnit = au
                    child = generic
                }
                container.addChild(child)
                child.view.frame = container.view.bounds
                child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.view.addSubview(child.view)
                child.didMove(toParent: container)
            }
        }
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
