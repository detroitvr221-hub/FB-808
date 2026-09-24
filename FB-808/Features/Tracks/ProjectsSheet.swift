//  ProjectsSheet.swift — save, load, rename, duplicate, and delete FD808 projects,
//  with overwrite / unsaved-changes guards.

import SwiftUI
import UniformTypeIdentifiers

struct ProjectsSheet: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: AudioEngine   // re-writing still-loaded pad samples before a repair save
    @Environment(\.dismiss) private var dismiss
    var onNewBeat: (() -> Void)? = nil   // route "New Beat" to the genre quick-start (RootView guards unsaved work)

    var continueToNew = false
    var onSavedForNew: (() -> Void)? = nil
    @State private var saveThenNew = false
    @State private var nameField = ""
    @State private var saved = false
    @State private var operation: String?
    private var isSaving: Bool { operation != nil }
    @State private var saveThenOpen: SavedProject?
    @State private var importedProject: SavedProject?
    @State private var feedback: String?
    @State private var operationError: String?
    @State private var searchText = ""
    @State private var sortByName = false
    @State private var pendingDelete: SavedProject?
    @State private var confirmNew = false
    @State private var confirmOverwrite = false
    @State private var pendingLoad: SavedProject?
    @State private var renameItem: SavedProject?
    @State private var renameText = ""
    @State private var renameOverwriteItem: SavedProject?
    @State private var renameOverwriteName = ""
    @State private var missingAudio: [String] = []
    @State private var loadFailed = false   // surface a decode/read failure instead of a dead Load button
    @State private var shareFile: ExportFile?       // .fd808 project-file share sheet
    @State private var importingProject = false     // .fd808 file importer
    @State private var importFailed = false

    private var trimmedName: String { nameField.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredProjects: [SavedProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.items.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        return matches.sorted { sortByName ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.modified > $1.modified }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            currentCard
            if let operation {
                HStack(spacing: 10) { ProgressView(); Text(operation) }
                    .font(FDFont.ui(13)).foregroundStyle(settings.ink)
                    .accessibilityElement(children: .combine)
            } else if let feedback {
                Text(feedback).font(FDFont.ui(13)).foregroundStyle(settings.inkDim)
            }
            Text("Save updates this beat. Use Duplicate in its menu to make a separate copy.")
                .font(FDFont.ui(11.5)).foregroundStyle(settings.inkDim)
            Text("SAVED PROJECTS").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkDim)
            libraryControls
            if !store.recoveryItems.isEmpty {
                DisclosureGroup("Recovery versions · last 3 per beat") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(store.recoveryItems) { version in
                                Button { open(version) } label: {
                                    HStack {
                                        Text(version.name)
                                        Spacer()
                                        Text(version.modified, format: .dateTime.month().day().hour().minute().second())
                                    }.font(FDFont.ui(12))
                                }.buttonStyle(.bordered)
                                .contextMenu {
                                    Button("Delete recovery version", role: .destructive) { pendingDelete = version }
                                }
                            }
                        }
                    }.frame(maxHeight: 150)
                }
            }
            list
        }
        .padding(24)
        .background(settings.theme.bg.ignoresSafeArea())
        .onAppear { nameField = project.name; saveThenNew = continueToNew }
        .task { await store.reloadRecoveries() }
        .onChange(of: nameField) { _, _ in saved = false; feedback = nil }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
    }

    private var saveActions: some View {
        content
        .alert("Project action failed", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            if !store.lastSaveMissing.isEmpty {
                // The explicit way out of "a referenced WAV is gone": drop those references and save (#persist-3).
                Button("Drop missing audio & save", role: .destructive) { operationError = nil; saveDroppingMissing() }
            }
            Button("OK", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "Please try again.") }
        .confirmationDialog("New project from a template", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("Blank") { startTemplate("blank") }
            ForEach(["boombap", "trap", "house", "lofi", "afrobeat"], id: \.self) { id in
                Button(Project.beatStyles.first { $0.id == id }?.name ?? id) { startTemplate(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This clears the current beat. Save it first if you want to keep it.") }
        .alert("Overwrite “\(trimmedName)”?", isPresented: $confirmOverwrite) {
            Button("Cancel", role: .cancel) { saveThenOpen = nil; saveThenNew = false }
            Button("Overwrite", role: .destructive) { doSave() }
        } message: { Text("A different saved beat already uses this name. Saving replaces it.") }
        .alert(item: $pendingDelete) { item in
            Alert(title: Text("Delete “\(item.name)”?"),
                  message: Text("This can't be undone."),
                  primaryButton: .destructive(Text("Delete")) {
                      // The live session's assets go in `protecting` so reclaiming the deleted beat's audio
                      // can never take the audio an in-session Undo still needs.
                      if !store.delete(item, protecting: project.liveAssetFilenames) {
                          operationError = "Couldn’t delete this project. Please try again."
                      }
                  },
                  secondaryButton: .cancel())
        }
        .alert("Open another beat?", isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } })) {
            if let item = pendingLoad {
                Button("Save & Open") { saveThenOpen = item; attemptSave() }
                Button("Discard & Open", role: .destructive) { doOpen(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save your current changes before opening \(pendingLoad?.name ?? "another beat").") }
        .alert("Project imported", isPresented: Binding(get: { importedProject != nil }, set: { if !$0 { importedProject = nil } })) {
            if let item = importedProject { Button("Open Beat") { open(item) } }
            Button("Keep Browsing", role: .cancel) {}
        } message: { Text("\(importedProject?.name ?? "Your beat") is saved in your library. Your current beat is still open.") }
    }

    private var libraryActions: some View {
        saveActions
        .alert("Rename Project", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let it = renameItem { attemptRename(it, renameText) }; renameItem = nil }
            Button("Cancel", role: .cancel) { renameItem = nil }
        }
        .alert("Overwrite “\(renameOverwriteName)”?", isPresented: Binding(get: { renameOverwriteItem != nil }, set: { if !$0 { renameOverwriteItem = nil } })) {
            Button("Cancel", role: .cancel) { renameOverwriteItem = nil }
            Button("Overwrite", role: .destructive) {
                if let it = renameOverwriteItem { rename(it, to: renameOverwriteName, force: true) }
                renameOverwriteItem = nil
            }
        } message: { Text("A different saved beat already uses this name. Renaming replaces it.") }
    }

    var body: some View {
        libraryActions
        .alert("Some audio is missing", isPresented: Binding(get: { !missingAudio.isEmpty }, set: { if !$0 { missingAudio = [] } })) {
            Button("OK") { missingAudio = []; dismiss() }
        } message: {
            Text("This project references audio that couldn't be found:\n\n• \(missingAudio.prefix(8).joined(separator: "\n• "))\n\nThe rest of the project loaded fine.")
        }
        .alert("Couldn't open that project", isPresented: $loadFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("The save file couldn't be read — it may be corrupted. Your other projects are unaffected.") }
        .alert("Couldn't import that file", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("The file may be incomplete, contain unreadable audio, use an unsupported version, or exceed 256 MB. Your existing projects are unaffected.") }
        .fileImporter(isPresented: $importingProject,
                      allowedContentTypes: [UTType(filenameExtension: "fd808") ?? .data],
                      allowsMultipleSelection: false) { handleProjectImport($0) }
        .sheet(item: $shareFile) { f in ShareSheet(urls: f.urls) }
    }

    /// New Beat from a template: the previous beat's unsaved edits are being discarded, so its recovery
    /// slot must go too or the next launch offers that work back and Recover can overwrite the new beat.
    private func startTemplate(_ id: String) {
        project.startFromTemplate(id)
        nameField = project.name
        store.clearAutosave(protecting: project.liveAssetFilenames)
    }

    private func handleProjectImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard !isSaving else { return }
        operation = "Importing project…"
        feedback = nil
        Task { @MainActor in
            defer { operation = nil }
            if let snapshot = await store.importArchive(from: url) {
                searchText = ""
                importedProject = store.items.first { $0.projectID == snapshot.id }
                feedback = "Imported \(snapshot.name)."
            } else { importFailed = true }
        }
    }

    /// Bundle a saved project + its audio into one shareable .fd808 file. Reads the snapshot directly
    /// (not store.load) so sharing never re-stamps the "last opened" project.
    private func shareProjectFile(_ item: SavedProject) {
        guard !isSaving else { return }
        operation = "Preparing project file…"
        feedback = nil
        let url = item.url
        Task { @MainActor in
            defer { operation = nil }
            guard let snap = await Task.detached(priority: .userInitiated, operation: { ProjectStore.decodeSnapshot(url) }).value else {
                loadFailed = true; return
            }
            await Task.detached(priority: .utility) { sweepExportDirs() }.value   // off-main (#export-5)
            if let out = await store.exportArchive(snap) { shareFile = ExportFile(urls: [out]) }
            else { operationError = "Couldn’t share this beat. Check that all its audio is available and the project file is under 256 MB." }
        }
    }

    /// Rename, but if the target name belongs to a DIFFERENT saved beat, confirm the overwrite first
    /// (mirrors the Save flow) so a rename never silently destroys another project.
    private func attemptRename(_ item: SavedProject, _ newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if store.nameCollision(with: clean, excluding: item) {
            renameOverwriteName = clean; renameOverwriteItem = item
        } else {
            rename(item, to: clean)
        }
    }

    private func rename(_ item: SavedProject, to name: String, force: Bool = false) {
        guard store.rename(item, to: name, force: force) else {
            operationError = "Couldn’t rename this project. The original save has been kept."
            return
        }
        if item.projectID == project.projectID { project.name = name; nameField = name }
    }

    private var header: some View {
        HStack {
            Text("Projects").font(FDFont.display(24, .bold)).foregroundStyle(settings.ink)
            Spacer()
            Button { importingProject = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                    Text("Import").font(FDFont.ui(13, .semibold))
                }
                .foregroundStyle(settings.inkDim)
                .padding(.horizontal, 14).frame(height: 36)
                .fdCard(9, fill: settings.panel2)
                .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("Import a project file"))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                    .foregroundStyle(settings.inkFaint)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(Text("Close"))
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CURRENT BEAT").font(FDFont.mono(10, .bold)).tracking(1.4)
                Spacer()
                Text(project.hasUnsavedChanges ? "Unsaved changes" : "No unsaved changes")
                    .font(FDFont.ui(12))
            }.foregroundStyle(settings.inkDim)
            HStack(spacing: 10) {
                TextField("Beat name", text: $nameField)
                    .font(FDFont.display(17, .semibold)).foregroundStyle(settings.ink)
                    .textFieldStyle(.plain).submitLabel(.done)
                    .onSubmit { attemptSave() }
                    .padding(.horizontal, 12).frame(height: 42)
                    .fdCard(10, fill: settings.panel2)
                    .accessibilityLabel(Text("Project name"))
                saveButton
            }
            HStack(spacing: 10) {
                Button("Save & New") { saveThenNew = true; attemptSave() }
                    .buttonStyle(.bordered).disabled(isSaving)
                Button { if let onNewBeat { dismiss(); onNewBeat() } else { confirmNew = true } } label: {
                    Label("New Beat", systemImage: "sparkles").font(FDFont.ui(13, .semibold))
                        .foregroundStyle(settings.inkDim)
                        .padding(.horizontal, 14).frame(height: 36)
                        .fdCard(9, fill: settings.panel2)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if store.wouldOverwriteDifferentProject(name: trimmedName, openID: project.projectID) {
                    Text("Overwrites an existing save").font(FDFont.ui(11.5)).foregroundStyle(settings.inkDim)
                }
                Spacer()
            }
        }
        .padding(16)
        .fdCard(14, fill: settings.panel)
    }

    /// Confirm before clobbering a DIFFERENT existing save; a plain re-save of the open project saves directly.
    /// Identity-based (vs the open project's name) so renaming the open beat to its own name never false-warns. (#221)
    private func attemptSave() {
        guard !isSaving else { return }
        // Identity-based: confirm only when the target file belongs to a DIFFERENT project (by embedded id),
        // so re-saving/renaming the open beat never false-warns, but a name collision with another beat does. (#PERSIST-03, #221)
        if store.wouldOverwriteDifferentProject(name: trimmedName.isEmpty ? "Untitled Beat" : trimmedName, openID: project.projectID) {
            confirmOverwrite = true
        } else {
            doSave()
        }
    }
    /// Save after dropping every reference whose audio is gone (the user chose this explicitly from the
    /// failed-save alert). The live project adopts the same repaired state so the next save is clean, with
    /// undo history kept so the choice is reversible.
    private func saveDroppingMissing() {
        guard !isSaving else { return }
        operation = "Saving beat…"
        Task { @MainActor in
            // A pad whose WAV is gone but whose audio is STILL loaded gets its file re-written first — dropping
            // the reference would have silenced a pad the user could hear (round 3, persist-3).
            let snap = project.snapshot()
            var byBank: [String: [(id: String, data: [Float], name: String)]] = [:]
            for (pad, pp) in snap.padParams {
                guard let f = pp.sampleFile, !store.padSampleIsReadable(f),
                      let data = project.padSampleData[pad], !data.isEmpty else { continue }
                byBank[pp.sampleBank ?? project.bank, default: []].append((pad, data, pp.sampleName ?? pad))
            }
            for (bank, items) in byBank {
                let prepared = await Project.preparePadSamples(items, sampleRate: engine.sampleRate)
                _ = project.commitPreparedPadSamples(prepared, bank: bank, destination: nil)
            }
            let repaired = store.repaired(project.snapshot())
            project.restore(repaired, keepHistory: true)
            operation = nil
            doSave()
        }
    }
    private func doSave() {
        guard !isSaving else { return }
        engine.finishMicCapture()
        operation = "Saving beat…"
        feedback = nil
        saved = false
        project.name = trimmedName.isEmpty ? "Untitled Beat" : trimmedName
        nameField = project.name
        let payload = project.savePayload()
        let revision = project.editRevision
        Task { @MainActor in
            defer { if operation == "Saving beat…" { operation = nil } }
            if await store.save(payload) {
                let unchanged = project.projectID == payload.snapshot.id && project.editRevision == revision
                if unchanged {
                    project.markSaved()
                    store.clearAutosave(protecting: project.liveAssetFilenames)
                }
                saved = unchanged
                feedback = unchanged ? "Saved \(payload.snapshot.name)." : "Saved — but you made more edits meanwhile, so those are still unsaved."
                if unchanged && saveThenNew {
                    saveThenNew = false; operation = nil; dismiss()
                    (onSavedForNew ?? onNewBeat)?()
                    return
                }
                let next = saveThenOpen
                if unchanged, let next {
                    saveThenOpen = nil
                    operation = nil
                    doOpen(next)
                } else if let next {
                    // "Save & Open" must not quietly drop the Open when an edit landed mid-save: save ONCE more
                    // inline (the sheet stays disabled — no re-enable window), then open if that stuck (#persist-4).
                    let payload2 = project.savePayload()
                    let revision2 = project.editRevision
                    saveThenOpen = nil
                    if await store.save(payload2), project.editRevision == revision2 {
                        project.markSaved()
                        store.clearAutosave(protecting: project.liveAssetFilenames)
                        saved = true
                        operation = nil
                        doOpen(next)
                    } else {
                        feedback = "Saved, but edits kept landing — your newest changes are still open. Open the beat from the list when you're ready."
                    }
                }
            } else {
                saveThenOpen = nil
                let missing = store.lastSaveMissing
                operationError = missing.isEmpty
                    ? "Couldn’t save your beat. Your changes are still open. Check that there is enough free storage, then try again."
                    : "Couldn’t save your beat because \(missing.count) audio file\(missing.count == 1 ? " is" : "s are") missing: \(missing.prefix(4).joined(separator: ", ")). Your changes are still open — you can save without the missing audio."
            }
        }
    }

    private var saveButton: some View {
        Button { attemptSave() } label: {
            HStack(spacing: 7) {
                Image(systemName: (saved && !project.hasUnsavedChanges) ? "checkmark" : "square.and.arrow.down.fill").font(.system(size: 14, weight: .bold))
                Text(operation == "Saving beat…" ? "Saving…" : (saved && !project.hasUnsavedChanges) ? "Saved" : saveThenNew ? "Save & New" : "Save").font(FDFont.ui(14, .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill((saved && !project.hasUnsavedChanges) ? settings.theme.good : settings.accent))
        }.buttonStyle(.plain)
    }

    private func duplicate(_ item: SavedProject) {
        guard !isSaving else { return }
        operation = "Duplicating beat…"
        feedback = nil
        Task { @MainActor in
            defer { operation = nil }
            if await store.duplicate(item) {
                searchText = ""
                feedback = "Duplicated \(item.name). The copy is in your library."
            } else {
                operationError = "Couldn’t duplicate this project. Check that its audio is available and there is enough free storage. The original is unchanged."
            }
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(settings.inkDim)
                TextField("Search saved beats", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search saved beats")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(12).fdCard(10, fill: settings.panel2)
            Picker("Sort projects", selection: $sortByName) {
                Text("Recent").tag(false)
                Text("Name").tag(true)
            }.pickerStyle(.menu)
        }.font(FDFont.ui(13)).foregroundStyle(settings.ink)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                if store.items.isEmpty {
                    Text("No saved projects yet. Name your beat and tap Save.")
                        .font(FDFont.ui(13)).foregroundStyle(settings.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                }
                if !store.items.isEmpty && filteredProjects.isEmpty {
                    Text("No beats match your search. Try another name.")
                        .font(FDFont.ui(13)).foregroundStyle(settings.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                }
                ForEach(filteredProjects) { item in row(item) }
            }
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func row(_ item: SavedProject) -> some View {
        // id-based so two same-named saves don't both show OPEN; falls back to false for un-migrated items. (#219)
        let isCurrent = item.projectID != nil && item.projectID == project.projectID
        return HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(settings.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(FDFont.display(15, .semibold)).foregroundStyle(settings.ink).lineLimit(1)
                Text(item.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(FDFont.mono(10)).foregroundStyle(settings.inkDim)
            }
            Spacer()
            if isCurrent {
                Text("OPEN").font(FDFont.mono(9, .bold)).foregroundStyle(settings.theme.good)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(settings.theme.good.opacity(0.16)))
            }
            Button { open(item) } label: {
                Text(isCurrent ? "Reopen" : "Open").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(Text("Open \(item.name)"))
            Menu {
                Button { renameText = item.name; renameItem = item } label: { Label("Rename", systemImage: "pencil") }
                Button { duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { shareProjectFile(item) } label: { Label("Share Project File", systemImage: "square.and.arrow.up") }
                Divider()
                Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(settings.inkDim)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(Text("More actions for \(item.name)"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? settings.accent.opacity(0.4) : settings.line, lineWidth: 1))
    }

    private func open(_ item: SavedProject) {
        if project.hasUnsavedChanges { pendingLoad = item } else { doOpen(item) }
    }
    private func doOpen(_ item: SavedProject) {
        guard !isSaving else { return }
        operation = "Opening \(item.name)…"
        feedback = nil
        Task { @MainActor in
            defer { operation = nil }
            guard let snap = await store.load(item) else { loadFailed = true; return }   // surface a corrupt/unreadable save
            // Opening a beat replaces the live project, so the recovery slot (the beat being left behind,
            // or a stale one) is no longer this session's unsaved work — never offer it back for the beat
            // the user just opened, where Recover would overwrite it (#RECOVERY-SLOT). Cleared only after a
            // successful load, so a failed open still leaves the rescue path intact.
            store.clearAutosave(protecting: project.liveAssetFilenames)   // the only call that forgot `protecting:` (#persist-5)
            let missing = await store.missingAudioAssetsAsync(in: snap)   // off-main (round 2, persist-M3)
            project.restore(store.repaired(snap))   // item 9: load into a clean, repaired state
            nameField = project.name
            if missing.isEmpty {
                dismiss()
            } else {
                missingAudio = missing
            }
        }
    }
}
