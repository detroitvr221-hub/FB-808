//  FreeRollView.swift — a FREE-FORM (chromatic) note editor for the active synth part, built on the
//  vendored AudioKit PianoRoll (MIT). Complements the existing scale-laddered `SynthRoll`: this surface
//  lets you place/drag/resize notes anywhere chromatically, drawn in the active patch's color and themed
//  to the app tokens. It bridges PianoRoll's abstract model ↔ our `MelodyNote` array two-ways, guarded by
//  content signatures so there's no feedback loop, and rebuilds only on explicit context switches (appear /
//  part change) so a live drag is never reassigned out from under the gesture. On open it auto-scrolls to
//  the populated note range, and placing a note auditions its pitch through the active patch.

import SwiftUI
import PianoRoll

struct FreeRollView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings

    // Visible pitch window: C3…C6 (3 octaves). Notes outside are pulled to the nearest edge on first open.
    private let loMidi = 48
    private let rows = 37
    private let cellW: CGFloat = 46, cellH: CGFloat = 22, pad: CGFloat = 10

    @State private var model = PianoRollModel(notes: [], length: 16, height: 37)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    PianoRoll(
                        model: $model,
                        noteColor: project.editPatch.color,
                        gridColor: settings.line,
                        gridSize: CGSize(width: cellW, height: cellH),
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
                    .padding(pad)
                    // Invisible per-row anchors occupying REAL layout height (offset views don't move their
                    // layout frame, so scrollTo ignores them) → scrollTo(row, .center) brings notes into view.
                    VStack(spacing: 0) {
                        ForEach(0..<rows, id: \.self) { r in Color.clear.frame(height: cellH).id("row\(r)") }
                    }
                    .padding(pad)
                    .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Text("Tap to add · drag to move · drag the right edge to resize · tap a note to delete")
                    .font(FDFont.ui(10.5)).foregroundStyle(settings.inkFaint)
                    .padding(8).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { rebuild(); focus(proxy) }
            .onChange(of: project.activePart) { _, _ in rebuild(); focus(proxy) }
            .onChange(of: model) { _, m in pushBack(m) }
        }
    }

    // MARK: scroll-to-content

    /// 1-based row to centre on: the median note's row, or C4 when empty.
    private var focusRow: Int {
        let ps = model.notes.map { Int($0.pitch) }.sorted()
        return ps.isEmpty ? max(1, min(rows, 60 - loMidi + 1)) : ps[ps.count / 2]
    }
    private func focus(_ proxy: ScrollViewProxy) {
        let rowFromTop = max(0, min(rows - 1, rows - focusRow))   // top row = highest pitch (PianoRoll layout)
        // Defer past the ScrollView's first layout pass — scrolling synchronously on appear is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("row\(rowFromTop)", anchor: .center) }
        }
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
    /// triggered by our own write doesn't recurse (the round-trip is exact for in-range notes). A note
    /// newly placed by a tap is auditioned through the active patch for immediate feedback.
    private func pushBack(_ m: PianoRollModel) {
        let mapped = m.notes.map { pr -> MelodyNote in
            let step = max(0, Int(pr.start.rounded()))
            let dur = max(1, Int(pr.length.rounded()))
            let midi = Int(pr.pitch) - 1 + loMidi
            return MelodyNote(step: step, pitch: midi, dur: dur,
                              vel: project.activeNoteVel(at: step) > 0 ? project.activeNoteVel(at: step)
                                                                       : (step % 4 == 0 ? 0.95 : 0.8))
        }
        guard sig(mapped) != sig(project.activeNotes) else { return }
        // Audition a freshly-placed note (count grew) so editing isn't silent.
        if mapped.count > project.activeNotes.count {
            let oldKeys = Set(project.activeNotes.map { "\($0.step):\($0.pitch)" })
            if let added = mapped.first(where: { !oldKeys.contains("\($0.step):\($0.pitch)") }) {
                project.previewNote(midi: added.pitch)
            }
        }
        project.replaceActiveNotes(mapped)
    }

    /// Order-independent content signature (ignores note identity / velocity) for loop-free comparison.
    private func sig(_ n: [MelodyNote]) -> String {
        n.map { "\($0.step):\($0.pitch):\($0.dur)" }.sorted().joined(separator: ",")
    }
}
