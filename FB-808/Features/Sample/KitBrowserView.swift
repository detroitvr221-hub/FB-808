//  KitBrowserView.swift — in-app browser for the Supabase-hosted downloadable kits (KitStore). Lists the
//  catalog, and for a chosen kit shows its samples by category with tap-to-preview, per-sample "→ Pad"
//  assignment, and a one-tap "Auto-map to Pads" that loads a full drum kit. Samples stream individually
//  from the public bucket — no zip.

import SwiftUI

struct KitBrowserView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var kits: [KitStore.RemoteKit] = []
    @State private var loading = true
    @State private var loadError = false
    @State private var selected: KitStore.RemoteKit?
    @StateObject private var detailLoader = KitDetailLoader()
    private var samples: [KitStore.KitSample] { detailLoader.samples }
    private var loadingSamples: Bool { detailLoader.loading }
    @State private var operationID = UUID()
    @State private var busy: String?        // path (or "auto") currently downloading; toggling it re-renders rows
    @State private var autoProgress: Double = 0
    @State private var toast: String?

    private var th: Theme { settings.theme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(settings.line)
            Group {
                if let kit = selected { detail(kit) }
                else if loading { spinner("Loading kits…") }
                else if loadError { message("Couldn't reach the kit store. Check your connection.") }
                else if kits.isEmpty { message("No kits available yet.") }
                else { catalog }
            }
        }
        .background(th.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { if let t = toast { toastView(t) } }
        .task { await loadCatalog() }
        .onDisappear { detailLoader.reset(); cancelOperation() }
        .onChange(of: project.projectID) { _, _ in cancelOperation() }
        .onChange(of: project.bank) { _, _ in cancelOperation() }
        .onChange(of: detailLoader.error) { _, error in if let error { flash(error) } }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            if selected != nil {
                Button { selected = nil; detailLoader.reset(); cancelOperation() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundStyle(settings.ink)
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text("Back to kits"))
            }
            Text(selected?.name ?? "Download Kits").font(FDFont.display(19, .bold)).foregroundStyle(settings.ink)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(settings.inkFaint) }.buttonStyle(.plain)
                .accessibilityLabel(Text("Close kit browser"))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: catalog

    private var catalog: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(kits) { kit in
                    Button { open(kit) } label: { kitCard(kit) }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func kitCard(_ kit: KitStore.RemoteKit) -> some View {
        HStack(spacing: 14) {
            cover(kit, side: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(kit.name).font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
                if let a = kit.artist { Text("by \(a)").font(FDFont.ui(12)).foregroundStyle(settings.accent) }
                Text("\(kit.file_count ?? 0) sounds · \(mb(kit.size_bytes))").font(FDFont.mono(11)).foregroundStyle(settings.inkFaint)
            }
            Spacer()
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(settings.accent)
        }
        .padding(12)
        .fdCard(14, fill: settings.panel)
    }

    // MARK: detail

    @ViewBuilder private func detail(_ kit: KitStore.RemoteKit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    cover(kit, side: 76)
                    VStack(alignment: .leading, spacing: 4) {
                        if let a = kit.artist { Text("by \(a)").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.accent) }
                        if let d = kit.description { Text(d).font(FDFont.ui(11.5)).foregroundStyle(settings.inkDim).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                }
                Button { autoMap(kit) } label: {
                    ZStack(alignment: .leading) {
                        if busy == "auto" {   // fill the button as each category loads
                            GeometryReader { g in RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.25)).frame(width: g.size.width * autoProgress) }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "square.grid.3x3.fill")
                            Text(busy == "auto" ? "Loading… \(Int(autoProgress * 100))%" : "Auto-map to Pads").font(FDFont.ui(14, .semibold))
                        }
                        .foregroundStyle(.white).frame(maxWidth: .infinity)
                    }
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain).disabled(busy != nil)

                if loadingSamples { spinner("Loading samples…").frame(height: 120) }
                else {
                    ForEach(categoriesInOrder, id: \.self) { cat in
                        let items = samples.filter { $0.category == cat }
                        if !items.isEmpty {
                            Text(cat.uppercased()).font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint).padding(.top, 4)
                            ForEach(items) { s in sampleRow(s) }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private func sampleRow(_ s: KitStore.KitSample) -> some View {
        let isMIDI = s.category == "MIDI"
        HStack(spacing: 9) {
            if isMIDI {
                Image(systemName: "pianokeys").font(.system(size: 16)).foregroundStyle(settings.accent).frame(width: 22)
            } else {
                Button { preview(s) } label: {
                    Image(systemName: busy == s.path ? "hourglass" : "play.circle.fill").font(.system(size: 20)).foregroundStyle(settings.accent)
                }.buttonStyle(.plain).disabled(busy != nil)
            }
            Text(prettyName(s.name)).font(FDFont.ui(12.5)).foregroundStyle(settings.ink).lineLimit(1)
            if KitStore.isCached(s.path) {   // downloaded indicator (re-evaluated when `busy` toggles)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(settings.theme.good)
            }
            Spacer(minLength: 6)
            if isMIDI {
                Button { loadMIDI(s) } label: { chipLabel("→ Roll") }.buttonStyle(.plain).disabled(busy != nil)
            } else {
                Menu {
                    ForEach(Kit.pads, id: \.id) { pad in Button(pad.label) { assign(s, to: pad.id) } }
                } label: { chipLabel("→ Pad") }.disabled(busy != nil)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .fdCard(9, fill: settings.panel)
    }

    // MARK: pieces

    private func cover(_ kit: KitStore.RemoteKit, side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(settings.panel2)
            .overlay {
                if let p = kit.cover_path {
                    AsyncImage(url: KitStore.publicURL(p)) { img in img.resizable().scaledToFill() } placeholder: { Image(systemName: "waveform").foregroundStyle(settings.inkFaint) }
                } else { Image(systemName: "waveform").foregroundStyle(settings.inkFaint) }
            }
            .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func spinner(_ t: String) -> some View {
        VStack(spacing: 10) { ProgressView().tint(settings.accent); Text(t).font(FDFont.ui(12)).foregroundStyle(settings.inkFaint) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func chipLabel(_ t: String) -> some View {
        Text(t).font(FDFont.mono(10, .bold)).foregroundStyle(settings.inkDim)
            .padding(.horizontal, 9).frame(height: 28).fdCard(7, fill: settings.panel2)
    }
    private func message(_ t: String) -> some View {
        Text(t).font(FDFont.ui(13)).foregroundStyle(settings.inkFaint).multilineTextAlignment(.center)
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func toastView(_ t: String) -> some View {
        Text(t).font(FDFont.ui(12.5, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(settings.accent)).padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: actions

    private func loadCatalog() async {
        loading = true; loadError = false
        do { kits = try await KitStore.fetchCatalog() } catch { loadError = true }
        loading = false
    }
    private func cancelOperation() { operationID = UUID(); busy = nil }
    private func open(_ kit: KitStore.RemoteKit) {
        cancelOperation(); selected = kit; detailLoader.open(kit)
    }
    private func preview(_ s: KitStore.KitSample) {
        let request = UUID(); operationID = request
        let destination = project.operationDestination()
        busy = s.path
        Task { @MainActor in
            defer { if operationID == request { busy = nil } }
            guard let url = await KitStore.localFile(s.path), let data = await engine.decodeAudioFileAsync(url: url) else { if operationID == request, destination.matches(project) { flash("Download failed") }; return }
            guard operationID == request, destination.matches(project) else { return }
            engine.playReviewClip(data)
        }
    }
    private func assign(_ s: KitStore.KitSample, to padID: String) {
        let request = UUID(); operationID = request
        let destination = project.operationDestination()
        busy = s.path
        Task { @MainActor in
            defer { if operationID == request { busy = nil } }
            guard let url = await KitStore.localFile(s.path), let data = await engine.decodeAudioFileAsync(url: url) else { if operationID == request, destination.matches(project) { flash("Download failed") }; return }
            guard operationID == request, destination.matches(project) else { return }
            let prepared = await Project.preparePadSamples([(padID, data, prettyName(s.name))], sampleRate: engine.sampleRate)
            guard operationID == request, destination.matches(project) else { Project.discardPreparedPadSamples(prepared); return }
            guard project.commitPreparedPadSamples(prepared, bank: destination.bank, destination: destination) > 0 else { flash("Couldn't save sample"); return }
            flash("Loaded → \(Kit.padByID[padID]?.label ?? padID)")
        }
    }
    private func autoMap(_ kit: KitStore.RemoteKit) {
        let request = UUID(); operationID = request
        let destination = project.operationDestination()
        let sourceSamples = samples
        busy = "auto"; autoProgress = 0
        Task { @MainActor in
            defer { if operationID == request { busy = nil } }
            await Task.detached(priority: .utility) { KitStore.trimCache() }.value   // BEFORE the downloads, in this task (round 3, export-1)
            let cats = KitStore.categoryToPad.filter { cat, _ in sourceSamples.contains { $0.category == cat } }
            var items: [(id: String, data: [Float], name: String)] = []
            var done = 0
            for (cat, padID) in cats {
                if let s = sourceSamples.first(where: { $0.category == cat }),
                   let url = await KitStore.localFile(s.path),
                   let data = await engine.decodeAudioFileAsync(url: url) {
                    items.append((padID, data, prettyName(s.name)))
                }
                guard operationID == request, destination.matches(project) else { return }
                done += 1; withAnimation { autoProgress = Double(done) / Double(max(1, cats.count)) }
            }
            guard !items.isEmpty else { flash("Nothing to load"); return }
            guard operationID == request, destination.matches(project) else { return }
            let prepared = await Project.preparePadSamples(items, sampleRate: engine.sampleRate)
            guard operationID == request, destination.matches(project) else { Project.discardPreparedPadSamples(prepared); return }
            let count = project.commitPreparedPadSamples(prepared, bank: destination.bank, destination: destination)
            guard count > 0 else { flash("Couldn't save samples"); return }
            flash("Loaded \(count) sounds onto the pads")
        }
    }
    private func loadMIDI(_ s: KitStore.KitSample) {
        let request = UUID(); operationID = request
        let destination = project.operationDestination()
        busy = s.path
        Task { @MainActor in
            defer { if operationID == request { busy = nil } }
            guard let url = await KitStore.localFile(s.path),
                  let notes = MIDIImport.parse(url, barSteps: project.barSteps) else { if operationID == request, destination.matches(project) { flash("Couldn't read that MIDI") }; return }
            guard operationID == request, destination.matches(project) else { return }
            project.replaceActiveNotes(notes)
            flash("Loaded \(notes.count) notes into the roll")
        }
    }
    private func flash(_ t: String) {
        withAnimation { toast = t }
        Task { @MainActor in try? await Task.sleep(nanoseconds: 2_200_000_000); withAnimation { if toast == t { toast = nil } } }
    }

    // MARK: helpers

    private var categoriesInOrder: [String] {
        ["Kicks", "808", "Snares", "Claps", "Hats", "O-Hat", "Perc", "Chants", "SFX", "Loops", "MIDI"]
            .filter { c in samples.contains { $0.category == c } }
    }
    private func mb(_ bytes: Int?) -> String { bytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "—" }
    /// Trim the "Sludge … _ @slapdat.xyz" boilerplate to the sound's descriptive middle.
    private func prettyName(_ n: String) -> String {
        var s = n
        if let r = s.range(of: " _ @") { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
