//  Privacy policy, support and open-source acknowledgements (App Review 5.1.1(i); MIT notice for the
//  bundled Demucs-derived stem model and the vendored AudioKit packages).

import SwiftUI

enum AppLinks {
    /// The published policy (also the App Store Connect Privacy Policy URL). The in-app summary below
    /// mirrors it so it is readable offline.
    static let privacyPolicy = URL(string: "https://github.com/detroitvr221-hub/FB-808/blob/main/PRIVACY.md")!
    static let support = URL(string: "https://github.com/detroitvr221-hub/FB-808/issues")!
}

struct LegalView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Privacy") {
                    para("Your beats, samples and recordings stay on this iPad. FD-808 has no accounts, ads, analytics or tracking.")
                    para("Live classes are optional. Joining one shares a class code, a random device identifier, the display name you choose and any beats you submit with our hosting provider (Supabase) so the teacher can see them. Teachers can remove students, delete submissions or delete a whole class; anything left is deleted automatically 30 days after the class was last active.")
                    para("Crash reports stay on this iPad unless you share them from Settings → Diagnostics.")
                    Link("Read the full privacy policy", destination: AppLinks.privacyPolicy)
                        .font(FDFont.ui(13, .semibold)).tint(settings.accent)
                }
                section("Support") {
                    para("Questions, bug reports and deletion requests. Never post a student's name publicly; the class code is enough.")
                    Link("Contact support", destination: AppLinks.support)
                        .font(FDFont.ui(13, .semibold)).tint(settings.accent)
                }
                section("Acknowledgements") {
                    notice("Stem separation model",
                           "Converted from Demucs (htdemucs). Copyright (c) Meta Platforms, Inc. and affiliates. MIT License.")
                    notice("PianoRoll, Waveform", "Copyright (c) 2022 AudioKit. MIT License.")
                    notice("Ableton Link", "Link and the Link logo are trademarks of Ableton AG.")
                    para(Self.mitText).font(FDFont.mono(10))
                }
            }
            .padding(20)
        }
        .background(settings.theme.bg.ignoresSafeArea())
        .navigationTitle("Privacy & Legal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(FDFont.mono(11, .bold)).tracking(1.6).foregroundStyle(settings.inkFaint)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fdCard(14, fill: settings.panel)
    }

    private func para(_ s: String) -> Text {
        Text(s).font(FDFont.ui(12.5)).foregroundStyle(settings.inkDim)
    }

    private func notice(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.ink)
            Text(body).font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
        }
    }

    static let mitText = """
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation \
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and \
    to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions \
    of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO \
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER \
    DEALINGS IN THE SOFTWARE.
    """
}
