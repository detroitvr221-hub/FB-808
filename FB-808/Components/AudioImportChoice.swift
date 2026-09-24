import SwiftUI

struct AudioImportChoice: ViewModifier {
    @Binding var url: URL?
    let maxSeconds: Int
    let allowsStereo: Bool
    let accept: (URL, Bool) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Import audio", isPresented: Binding(get: { url != nil }, set: { if !$0 { url = nil } }), titleVisibility: .visible) {
            if allowsStereo {
                Button("Keep stereo · up to \(maxSeconds)s") { importFile(stereo: true) }
            }
            Button("Convert to mono · up to \(maxSeconds)s") { importFile(stereo: false) }
            Button("Cancel", role: .cancel) { url = nil }
        } message: {
            Text("\(url?.lastPathComponent ?? "Audio"). Longer files use only the first \(maxSeconds) seconds.\(allowsStereo ? "" : " Pads and the sampler use mono audio.")")
        }
    }

    private func importFile(stereo: Bool) {
        guard let file = url else { return }
        url = nil
        accept(file, stereo)
    }
}
