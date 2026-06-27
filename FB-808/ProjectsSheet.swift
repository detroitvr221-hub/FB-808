//  ProjectsSheet.swift — save, load, rename, duplicate, and delete FD808 projects,
//  with overwrite / unsaved-changes guards.

import SwiftUI

struct ProjectsSheet: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var nameField = ""
    @State private var saved = false
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

    private var trimmedName: String { nameField.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            currentCard
            Text("SAVED PROJECTS").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkDim)
            list
        }
        .padding(24)
        .background(settings.theme.bg.ignoresSafeArea())
        .onAppear { nameField = project.name }
        .alert("Start a new project?", isPresented: $confirmNew) {
            Button("Cancel", role: .cancel) {}
            Button("New Project", role: .destructive) {
                project.resetToDefault(); nameField = project.name
            }
        } message: { Text("This clears the current beat. Save it first if you want to keep it.") }
        .alert("Overwrite “\(trimmedName)”?", isPresented: $confirmOverwrite) {
            Button("Cancel", role: .cancel) {}
            Button("Overwrite", role: .destructive) { doSave() }
        } message: { Text("A different saved beat already uses this name. Saving replaces it.") }
        .alert(item: $pendingDelete) { item in
            Alert(title: Text("Delete “\(item.name)”?"),
                  message: Text("This can't be undone."),
                  primaryButton: .destructive(Text("Delete")) { store.delete(item) },
                  secondaryButton: .cancel())
        }
        .alert(item: $pendingLoad) { item in
            Alert(title: Text("Load “\(item.name)”?"),
                  message: Text("You have unsaved changes that will be lost. Save first, or load anyway?"),
                  primaryButton: .destructive(Text("Load Anyway")) { doOpen(item) },
                  secondaryButton: .cancel())
        }
        .alert("Rename Project", isPresented: Binding(get: { renameItem != nil }, set: { if !$0 { renameItem = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let it = renameItem { attemptRename(it, renameText) }; renameItem = nil }
            Button("Cancel", role: .cancel) { renameItem = nil }
        }
        .alert("Overwrite “\(renameOverwriteName)”?", isPresented: Binding(get: { renameOverwriteItem != nil }, set: { if !$0 { renameOverwriteItem = nil } })) {
            Button("Cancel", role: .cancel) { renameOverwriteItem = nil }
            Button("Overwrite", role: .destructive) {
                if let it = renameOverwriteItem { store.rename(it, to: renameOverwriteName, force: true) }
                renameOverwriteItem = nil
            }
        } message: { Text("A different saved beat already uses this name. Renaming replaces it.") }
        .alert("Some audio is missing", isPresented: Binding(get: { !missingAudio.isEmpty }, set: { if !$0 { missingAudio = [] } })) {
            Button("OK") { missingAudio = []; dismiss() }
        } message: {
            Text("This project references audio that couldn't be found:\n\n• \(missingAudio.prefix(8).joined(separator: "\n• "))\n\nThe rest of the project loaded fine.")
        }
        .alert("Couldn't open that project", isPresented: $loadFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("The save file couldn't be read — it may be corrupted. Your other projects are unaffected.") }
    }

    /// Rename, but if the target name belongs to a DIFFERENT saved beat, confirm the overwrite first
    /// (mirrors the Save flow) so a rename never silently destroys another project.
    private func attemptRename(_ item: SavedProject, _ newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if store.nameCollision(with: clean, excluding: item) {
            renameOverwriteName = clean; renameOverwriteItem = item
        } else {
            store.rename(item, to: clean)
        }
    }

    private var header: some View {
        HStack {
            Text("Projects").font(FDFont.display(24, .bold)).foregroundStyle(settings.ink)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                    .foregroundStyle(settings.inkFaint)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(Text("Close"))
        }
    }

    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CURRENT BEAT").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkDim)
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
                Button { confirmNew = true } label: {
                    Label("New", systemImage: "doc.badge.plus").font(FDFont.ui(13, .semibold))
                        .foregroundStyle(settings.inkDim)
                        .padding(.horizontal, 14).frame(height: 36)
                        .fdCard(9, fill: settings.panel2)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if store.exists(nameField.trimmingCharacters(in: .whitespaces)) {
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
        if !trimmedName.isEmpty && store.exists(trimmedName) && trimmedName != project.name {
            confirmOverwrite = true
        } else {
            doSave()
        }
    }
    private func doSave() {
        project.name = trimmedName.isEmpty ? "Untitled Beat" : trimmedName
        nameField = project.name
        project.persistSampleAudio()   // flush the sampler buffer to disk so it reloads with the project
        let snap = project.snapshot()  // capture on the main actor; encode/write happen off-main inside save()
        Task { @MainActor in
            if await store.save(snap) {
                project.markSaved()
                store.clearAutosave()   // explicit save supersedes any recovery file
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { saved = false }
            }
        }
    }

    private var saveButton: some View {
        Button { attemptSave() } label: {
            HStack(spacing: 7) {
                Image(systemName: saved ? "checkmark" : "square.and.arrow.down.fill").font(.system(size: 14, weight: .bold))
                Text(saved ? "Saved" : "Save").font(FDFont.ui(14, .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(saved ? settings.theme.good : settings.accent))
        }.buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                if store.items.isEmpty {
                    Text("No saved projects yet. Name your beat and tap Save.")
                        .font(FDFont.ui(13)).foregroundStyle(settings.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                }
                ForEach(store.items) { item in row(item) }
            }
        }
        .scrollIndicators(.hidden)
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
                Text("Load").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(Text("Load \(item.name)"))
            Menu {
                Button { renameText = item.name; renameItem = item } label: { Label("Rename", systemImage: "pencil") }
                Button { store.duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
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
        Task { @MainActor in
            guard let snap = await store.load(item) else { loadFailed = true; return }   // surface a corrupt/unreadable save
            let missing = store.missingAudioAssets(in: snap)
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
