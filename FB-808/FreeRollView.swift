//  FreeRollView.swift — a FREE-FORM (chromatic) note editor for the active synth part, built on the
//  vendored AudioKit PianoRoll (MIT). Complements the existing scale-laddered `SynthRoll`: this surface
//  lets you place/drag/resize notes anywhere chromatically, drawn in the active patch's color and themed
//  to the app tokens. It bridges PianoRoll's abstract model ↔ our `MelodyNote` array two-ways, guarded by
//  content signatures so there's no feedback loop, and rebuilds only on explicit context switches (appear /
//  part change) so a live drag is never reassigned out from under the gesture.

import SwiftUI
import PianoRoll

struct FreeRollView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings

    // Visible pitch window: C3…C6 (3 octaves). Notes outside are pulled to the nearest edge on first open.
    private let loMidi = 48
    private let rows = 37

    @State private var model = PianoRollModel(notes: [], length: 16, height: 37)

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            PianoRoll(
                model: $model,
                noteColor: project.editPatch.color,
                gridColor: settings.line,
                gridSize: CGSize(width: 46, height: 22),
                layout: .horizontal,
                rowBackgroundColor: { rowPitch in
                    let midi = rowPitch - 1 + loMidi
                    return midi % 12 == 0 ? settings.accent.opacity(0.07)            // C rows
                         : (midi % 12 == 5 ? settings.inkFaint.opacity(0.05) : nil)  // F rows (visual quartering)
                },
                noteContent: { _, active in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(project.editPatch.color.opacity(active ? 1 : 0.85))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(active ? 0.9 : 0.25), lineWidth: 1))
                }
            )
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Text("Tap to add · drag to move · drag the right edge to resize · tap a note to delete")
                .font(FDFont.ui(10.5)).foregroundStyle(settings.inkFaint)
                .padding(8).allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { rebuild() }
        .onChange(of: project.activePart) { _, _ in rebuild() }
        .onChange(of: model) { _, m in pushBack(m) }
    }

    // MARK: model bridge

    /// Build the PianoRoll model from the active part's notes. Pitch is mapped to a 1-based row.
    private func rebuild() {
        let prNotes = project.activeNotes.map { n in
            PianoRollNote(start: Double(n.step),
                          length: Double(max(1, n.dur)),
                          pitch: max(1, min(rows, n.pitch - loMidi + 1)),
                          color: project.editPatch.color)
        }
        model = PianoRollModel(notes: prNotes, length: max(1, project.barSteps), height: rows)
    }

    /// Write edits back to the project — only when the musical content actually differs, so the rebuild
    /// triggered by our own write doesn't recurse (the round-trip is exact for in-range notes).
    private func pushBack(_ m: PianoRollModel) {
        let mapped = m.notes.map { pr -> MelodyNote in
            let step = max(0, Int(pr.start.rounded()))
            let dur = max(1, Int(pr.length.rounded()))
            let midi = Int(pr.pitch) - 1 + loMidi
            return MelodyNote(step: step, pitch: midi, dur: dur,
                              vel: project.activeNoteVel(at: step) > 0 ? project.activeNoteVel(at: step)
                                                                       : (step % 4 == 0 ? 0.95 : 0.8))
        }
        if sig(mapped) != sig(project.activeNotes) { project.replaceActiveNotes(mapped) }
    }

    /// Order-independent content signature (ignores note identity / velocity) for loop-free comparison.
    private func sig(_ n: [MelodyNote]) -> String {
        n.map { "\($0.step):\($0.pitch):\($0.dur)" }.sorted().joined(separator: ",")
    }
}
