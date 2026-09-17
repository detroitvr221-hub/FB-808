//  FreeRollView.swift — a FREE-FORM (chromatic) note editor for the active synth part, built on the
//  vendored AudioKit PianoRoll (MIT). Complements the existing scale-laddered `SynthRoll`: this surface
//  lets you place/drag/resize notes anywhere chromatically, drawn in the active patch's color and themed
//  to the app tokens. It bridges PianoRoll's abstract model ↔ our `MelodyNote` array two-ways, guarded by
//  content signatures so there's no feedback loop, and rebuilds only on explicit context switches (appear /
//  part change) so a live drag is never reassigned out from under the gesture. On open it auto-scrolls to
//  the populated note range, and placing a note auditions its pitch through the active patch.

import SwiftUI
import PianoRoll
import UIKit

struct FreeRollView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var settings: AppSettings

    // Visible pitch window: at least C3…C6 (3 octaves), widened to contain every pitch the active part
    // actually uses. A fixed C3…C6 window cannot represent the Bass layer this app generates (MIDI 36–47):
    // its notes were pulled to the bottom row for display and then written back from that row, silently
    // transposing the whole line to C3 and persisting it (#FREEROLL-01). The window is recomputed from the
    // notes on (re)build; `pitchTruth` still carries each note's true MIDI, so a display row can never be
    // mistaken for a pitch even if the window is stale.
    private let cellW: CGFloat = 46, cellH: CGFloat = 22, pad: CGFloat = 10

    @State private var listEditor = UIAccessibility.isVoiceOverRunning
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = PianoRollModel(notes: [], length: 16, height: 37)
    @State private var loMidi = 48
    @State private var rows = 37
    /// Real MIDI behind each grid note's row: PianoRollNote.id → (the row it was built at, its true pitch).
    /// A row is a projection of the window, never the pitch, so `pushBack` must not re-derive pitch from it.
    /// PianoRollNote.id is stable across the grid's move/resize edits, so the map survives a drag.
    @State private var pitchTruth: [UUID: (row: Int, midi: Int)] = [:]
    /// Velocity behind each grid note: PianoRollNote.id → that note's own `vel`. Keyed by identity (which
    /// survives a grid move/resize) so a written-back note keeps the velocity it was given in the VEL lane
    /// instead of having one invented from a step-keyed lookup that ignores pitch and matches only the
    /// first covering note — which flattened chords and corrupted untouched notes (#FREEROLL-VEL).
    @State private var velTruth: [UUID: Double] = [:]
    /// The (step, dur) behind each grid note, for the same reason as `pitchTruth`: a note whose tail the
    /// grid had to clamp to the bar line must still write back its true length while it is untouched, so
    /// simply opening the editor cannot shorten it (finding 28).
    @State private var durTruth: [UUID: (step: Int, dur: Int)] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("List editor", isOn: $listEditor)
                .font(FDFont.ui(14, .semibold))
                .accessibilityHint("Edit note pitch, position, and duration using labeled controls")
            if outOfBarCount > 0 {
                // Honest affordance for notes the bar cannot play (finding 28): they are preserved in the
                // project, never silently re-timed by this editor, but they are not shown on the grid.
                Text("\(outOfBarCount) note\(outOfBarCount == 1 ? "" : "s") outside this \(barSteps)-step bar — not shown or played")
                    .font(FDFont.ui(11, .semibold)).foregroundStyle(settings.accent)
                    .accessibilityLabel("\(outOfBarCount) notes are outside this bar and are not played. Switch to a longer bar to edit them.")
            }
            if listEditor { accessibleEditor } else { pianoEditor }
        }
    }

    /// The steps this grid can represent. `project.barSteps` is the same value Transport loops over.
    private var barSteps: Int { max(1, project.barSteps) }
    /// Notes stranded past the end of the bar by an earlier, wider bar (or a 16-hardcoded write path).
    /// They are untouched in the project but have no column here, so they are counted and surfaced.
    private var outOfBarCount: Int { Self.splitByBar(project.activeNotes, barSteps: barSteps).outOfBar.count }

    private var accessibleEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Add note") {
                    var notes = project.activeNotes
                    notes.append(MelodyNote(step: 0, pitch: 60, dur: 1, vel: 0.85))
                    project.replaceActiveNotes(notes)
                }
                if project.activeNotes.isEmpty { Text("No notes yet. Add a note to start your melody.") }
                ForEach(project.activeNotes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("Pitch: MIDI \(note.pitch)", value: noteValue(note.id, \.pitch, fallback: note.pitch), in: 0...127)
                        Stepper("Step: \(note.step + 1)", value: noteValue(note.id, \.step, fallback: note.step), in: 0...max(0, project.barSteps - 1))
                        Stepper("Length: \(note.dur) steps", value: noteValue(note.id, \.dur, fallback: note.dur), in: 1...max(1, project.barSteps - note.step))
                        HStack {
                            Button("Preview note") { project.previewNote(midi: note.pitch) }
                            Spacer()
                            Button("Delete note", role: .destructive) {
                                project.replaceActiveNotes(project.activeNotes.filter { $0.id != note.id })
                            }
                        }
                    }
                    .padding(12).fdCard(10, fill: settings.panel2)
                }
            }.padding(12)
        }.font(FDFont.ui(14)).foregroundStyle(settings.ink)
    }

    private func noteValue(_ id: UUID, _ keyPath: WritableKeyPath<MelodyNote, Int>, fallback: Int) -> Binding<Int> {
        Binding(get: { project.activeNotes.first { $0.id == id }?[keyPath: keyPath] ?? fallback }, set: { value in
            var notes = project.activeNotes
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
            notes[index][keyPath: keyPath] = value
            notes[index].dur = min(notes[index].dur, max(1, project.barSteps - notes[index].step))
            project.replaceActiveNotes(notes)
        })
    }

    private var pianoEditor: some View {
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
            .fdCard(16, fill: settings.panel)
            .overlay(alignment: .topTrailing) {
                Text("Tap to add · drag to move · drag the right edge to resize · tap a note to delete")
                    .font(FDFont.ui(10.5)).foregroundStyle(settings.inkFaint)
                    .padding(8).allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { rebuild(); focus(proxy) }
            .onChange(of: project.activePart) { _, _ in rebuild(); focus(proxy) }
            .onChange(of: model) { _, m in pushBack(m) }
            // A bar-length change (16→12→8) re-sizes the grid: the canvas IS `length * cellW`, so the model
            // must be re-bounded at the same moment or its notes draw outside the scrollable content.
            .onChange(of: project.barSteps) { _, _ in rebuild(); focus(proxy) }
            // Undo/Redo, "Clear this part" and a project load all rewrite the part without touching
            // `activePart`, so the grid used to keep showing (and then write back) the stale notes.
            // `editRevision` is bumped by every checkpoint/state apply, so it catches all of them.
            .onChange(of: project.editRevision) { _, _ in syncIfNeeded() }
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("row\(rowFromTop)", anchor: .center) }
        }
    }

    // MARK: model bridge

    /// Lowest MIDI + row count for a set of pitches: the union of the default C3…C6 span and every pitch the
    /// part uses, so nothing the part plays is ever pulled to an edge it does not really sit on. Pure, so the
    /// window (and therefore the row mapping) can be unit-tested without a UI.
    nonisolated static func pitchWindow(for pitches: [Int]) -> (lo: Int, rows: Int) {
        let defaultLo = 48, defaultHi = 84   // C3…C6
        let lo = min(defaultLo, pitches.min() ?? defaultLo)
        let hi = max(defaultHi, pitches.max() ?? defaultHi)
        return (lo, max(1, hi - lo + 1))
    }

    /// The true MIDI a grid note writes back: its original pitch while it still sits on the row it was built
    /// at, otherwise the pitch its (new) row denotes. This is the whole fix for the open-the-editor
    /// transposition — a note at MIDI 36 shown on row 1 must write back 36, never row 1's pitch (#FREEROLL-01).
    nonisolated static func writeBackPitch(row: Int, trueRow: Int?, trueMidi: Int?, loMidi: Int) -> Int {
        if let trueRow, let trueMidi, trueRow == row { return trueMidi }
        return row - 1 + loMidi
    }

    /// The part's notes split into the ones this grid can show (inside the bar) and the ones it cannot.
    /// The grid's canvas is `length * cellW`, so a note at or past `barSteps` has no column, is never
    /// triggered by Transport, and used to be drawn outside the ScrollView's content width — reachable
    /// only by scrolling past the grid, or not at all (finding 28).
    nonisolated static func splitByBar(_ notes: [MelodyNote], barSteps: Int) -> (inBar: [MelodyNote], outOfBar: [MelodyNote]) {
        let bar = max(1, barSteps)
        var inBar: [MelodyNote] = [], outOfBar: [MelodyNote] = []
        for n in notes { if n.step >= 0 && n.step < bar { inBar.append(n) } else { outOfBar.append(n) } }
        return (inBar, outOfBar)
    }

    /// The length a written-back grid note carries. The grid clamps a tail that crosses the bar line to
    /// the columns it can draw, but the note it was built from is the truth: while the note is still that
    /// same note (same start, same clamped length) it writes back its TRUE length, so merely opening the
    /// editor cannot shorten a note (finding 28). A note the user re-positioned or re-sized takes the
    /// grid's value, exactly like `writeBackPitch`.
    nonisolated static func writeBackDuration(gridStep: Int, gridDur: Int,
                                              trueStep: Int?, trueDur: Int?, barSteps: Int) -> Int {
        guard let trueStep, let trueDur else { return gridDur }   // a genuinely new note: the grid's length
        return (gridStep == trueStep && gridDur == clampedProjection(trueStep, trueDur, barSteps: barSteps))
            ? trueDur : gridDur
    }

    /// How the grid draws `dur` steps starting at `step` inside a `barSteps` bar.
    nonisolated static func clampedProjection(_ step: Int, _ dur: Int, barSteps: Int) -> Int {
        let bar = max(1, barSteps)
        let s = max(0, min(bar - 1, step))
        return max(1, min(dur, bar - s))
    }

    /// The part as it must be stored after an edit here: the grid's in-bar notes plus every note the grid
    /// cannot represent, untouched. Without the merge, hiding an out-of-bar note from the model would
    /// silently delete it the next time the grid wrote back.
    nonisolated static func mergePreserving(_ mapped: [MelodyNote], project: [MelodyNote], barSteps: Int) -> [MelodyNote] {
        splitByBar(project, barSteps: barSteps).outOfBar + mapped
    }

    /// Build the PianoRoll model from the active part's notes. Pitch is mapped to a 1-based row inside the
    /// part's window; `pitchTruth` records the real MIDI behind each row so it can be written back verbatim,
    /// and `velTruth` records each grid note's own velocity for the same reason (#FREEROLL-VEL).
    /// Only in-bar notes are modelled, each clamped to the bar so it cannot be drawn off the canvas
    /// (finding 28); `durTruth` remembers the length to write back while the note is untouched.
    private func rebuild() {
        let bar = barSteps
        let notes = Self.splitByBar(project.activeNotes, barSteps: bar).inBar
        let (lo, r) = Self.pitchWindow(for: notes.map(\.pitch))
        loMidi = lo
        rows = r
        var truth: [UUID: (row: Int, midi: Int)] = [:]
        var vels: [UUID: Double] = [:]
        var durs: [UUID: (step: Int, dur: Int)] = [:]
        let prNotes = notes.map { n -> PianoRollNote in
            let row = max(1, min(r, n.pitch - lo + 1))
            let pr = PianoRollNote(start: Double(n.step),
                                   length: Double(Self.clampedProjection(n.step, n.dur, barSteps: bar)),
                                   pitch: row,
                                   color: project.editPatch.color)
            truth[pr.id] = (row, n.pitch)
            vels[pr.id] = n.vel
            durs[pr.id] = (n.step, n.dur)
            return pr
        }
        pitchTruth = truth
        velTruth = vels
        durTruth = durs
        model = PianoRollModel(notes: prNotes, length: bar, height: r)
    }

    /// The velocity a written-back grid note carries. The note's own velocity wins whenever it has one
    /// (identity survives move/resize), so accents set in the VEL lane are preserved; the step-keyed
    /// lookup / step default applies only to a genuinely new note (#FREEROLL-VEL).
    nonisolated static func writeBackVelocity(gridID: UUID, stepLookup: Double,
                                              velTruth: [UUID: Double], step: Int) -> Double {
        if let own = velTruth[gridID] { return own }
        return stepLookup > 0 ? stepLookup : defaultVelocity(step: step)
    }

    /// The historical step default, kept for a note the grid has just created.
    nonisolated static func defaultVelocity(step: Int) -> Double { step % 4 == 0 ? 0.95 : 0.8 }

    /// Order-independent content signature (step : pitch : dur) for loop-free comparison. Velocity and
    /// note identity are deliberately excluded: a velocity nudge is not a geometry change.
    nonisolated static func contentSignature(_ n: [MelodyNote]) -> String {
        n.map { "\($0.step):\($0.pitch):\($0.dur)" }.sorted().joined(separator: ",")
    }

    /// Same as `contentSignature`, but including velocity — used only for the resync decision, where a
    /// velocity edited from the VEL lane must also refresh the grid's side map.
    nonisolated static func voicedSignature(_ n: [MelodyNote]) -> String {
        n.map { "\($0.step):\($0.pitch):\($0.dur):\($0.vel)" }.sorted().joined(separator: ",")
    }

    /// Should the grid rebuild from the project? True when the part's notes no longer match what the grid
    /// would write back — undo/redo, "Clear this part", a project load or a VEL-lane edit. A
    /// self-inflicted write leaves the two signatures equal, so this can neither loop nor fight a drag.
    nonisolated static func needsResync(modelSig: String, projectSig: String) -> Bool {
        modelSig != projectSig
    }

    /// The exact mapping the grid writes back to the project. Shared by `pushBack` and the resync check so
    /// the two can never disagree — that equality is what keeps the resync from fighting a live edit.
    nonisolated static func mapBack(_ m: PianoRollModel,
                                    pitchTruth: [UUID: (row: Int, midi: Int)],
                                    velTruth: [UUID: Double],
                                    durTruth: [UUID: (step: Int, dur: Int)],
                                    rows: Int, loMidi: Int, barSteps: Int,
                                    stepLookup: (Int) -> Double) -> [MelodyNote] {
        m.notes.map { pr -> MelodyNote in
            let step = max(0, Int(pr.start.rounded()))
            let gridDur = max(1, Int(pr.length.rounded()))
            let row = max(1, min(rows, Int(pr.pitch)))
            let truth = pitchTruth[pr.id]
            let midi = Self.writeBackPitch(row: row, trueRow: truth?.row, trueMidi: truth?.midi, loMidi: loMidi)
            let trueDur = durTruth[pr.id]
            let dur = Self.writeBackDuration(gridStep: step, gridDur: gridDur,
                                             trueStep: trueDur?.step, trueDur: trueDur?.dur, barSteps: barSteps)
            return MelodyNote(step: step, pitch: midi, dur: dur,
                              vel: Self.writeBackVelocity(gridID: pr.id, stepLookup: stepLookup(step),
                                                          velTruth: velTruth, step: step))
        }
    }

    /// The grid as the project would receive it.
    private func mappedBack() -> [MelodyNote] {
        Self.mapBack(model, pitchTruth: pitchTruth, velTruth: velTruth, durTruth: durTruth,
                     rows: rows, loMidi: loMidi, barSteps: barSteps,
                     stepLookup: { project.activeNoteVel(at: $0) })
    }

    /// The whole part as this editor would store it: the grid's write-back merged with the notes the bar
    /// cannot represent, which are preserved untouched (finding 28).
    private func storedFromModel() -> [MelodyNote] {
        Self.mergePreserving(mappedBack(), project: project.activeNotes, barSteps: barSteps)
    }

    /// Rebuild from the project when the part changed from outside this editor (#FREEROLL-STALE).
    private func syncIfNeeded() {
        guard Self.needsResync(modelSig: Self.voicedSignature(storedFromModel()),
                               projectSig: Self.voicedSignature(project.activeNotes)) else { return }
        rebuild()
    }

    /// Write edits back to the project — only when the musical content actually differs, so the rebuild
    /// triggered by our own write doesn't recurse (the round-trip is exact for in-range notes). A note
    /// newly placed by a tap is auditioned through the active patch for immediate feedback.
    /// The row→pitch derivation only applies to a note the user actually re-pitched (its row moved); a note
    /// still on the row it was built at keeps its true MIDI. That is what stops opening the editor from
    /// transposing every out-of-window note (#FREEROLL-01).
    private func pushBack(_ m: PianoRollModel) {
        let mapped = Self.mapBack(m, pitchTruth: pitchTruth, velTruth: velTruth, durTruth: durTruth,
                                  rows: rows, loMidi: loMidi, barSteps: barSteps,
                                  stepLookup: { project.activeNoteVel(at: $0) })
        let merged = Self.mergePreserving(mapped, project: project.activeNotes, barSteps: barSteps)
        guard Self.contentSignature(merged) != Self.contentSignature(project.activeNotes) else { return }
        // Audition a freshly-placed note (the grid grew) so editing isn't silent.
        let previousInBar = Self.splitByBar(project.activeNotes, barSteps: barSteps).inBar.count
        if mapped.count > previousInBar {
            let oldKeys = Set(project.activeNotes.map { "\($0.step):\($0.pitch)" })
            if let added = mapped.first(where: { !oldKeys.contains("\($0.step):\($0.pitch)") }) {
                project.previewNote(midi: added.pitch)
            }
        }
        project.replaceActiveNotes(merged)
    }
}
