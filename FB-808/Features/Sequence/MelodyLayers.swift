//  MelodyLayers.swift — Tier 2 multi-part instruments: Lead (= melody/synthPatch) plus
//  extra parts (Bass, Chords…), each with its OWN patch + note lane, all playing together.
//  The Synth UI edits whichever part is "active" via editPatch / activeNotes / placeActiveNote,
//  so the existing knobs & roll need almost no change. Parts are per-sequence (each pattern A/B/C/D
//  keeps its own parts), so they arrange per-section in Song Mode like the drum lanes and melody.

import SwiftUI
import FD808Engine

struct InstrumentPart: Identifiable, Codable {
    var id: String
    var name: String
    var patch: SynthPatch
    var notes: [MelodyNote]
    var muted: Bool = false
}

extension Project {

    // MARK: editing indirection — the Synth UI targets the active part

    /// The patch the knobs/preset list edit: the Lead's `synthPatch` or the active extra part's.
    var editPatch: SynthPatch {
        get { activePart == "lead" ? synthPatch : (parts.first { $0.id == activePart }?.patch ?? synthPatch) }
        set {
            if activePart == "lead" { synthPatch = newValue }
            else if let i = parts.firstIndex(where: { $0.id == activePart }) { parts[i].patch = newValue }
        }
    }
    /// Load a SoundFont (.sf2) as a playable multisample on the active synth part.
    /// Returns the instrument name, or nil if the file couldn't be parsed.
    @discardableResult
    func loadSoundFont(_ data: Data) -> String? {
        guard let inst = SoundFont.load(data) else { return nil }
        return installSoundFont(data, instrument: inst)
    }

    @discardableResult
    func installSoundFont(_ data: Data, instrument inst: SFInstrument) -> String {
        checkpoint("loadSF2", coalesce: false)
        let id = UUID().uuidString
        soundFontAssets[id] = data
        decodedSoundFonts[id] = Self.soundFontRegions(inst)
        engine.core.setInstrumentBanks(decodedSoundFonts)
        engine.setMultiSample(decodedSoundFonts[id] ?? [])   // compatibility for unbound legacy patches
        var p = editPatch
        p.source = "multisample"
        p.instrumentID = id
        p.name = inst.name.isEmpty ? "SoundFont" : String(inst.name.prefix(18))
        editPatch = p
        return p.name
    }

    /// The notes the piano roll shows/edits for the active part.
    var activeNotes: [MelodyNote] {
        activePart == "lead" ? melody : (parts.first { $0.id == activePart }?.notes ?? [])
    }

    /// Clamp a newly created note's start and length to a bar of `barSteps`: it never starts at or past
    /// the last step of the bar, and never extends past it. Every write path used a hard-coded 16, so
    /// shrinking the bar to 12 (3/4) or 8 (2/4) left notes on steps the transport never visits —
    /// unplayable ghosts that the Free editor also drew outside its own canvas (finding 28).
    nonisolated static func boundedNote(step: Int, len: Int, barSteps: Int) -> (step: Int, dur: Int) {
        let n = max(1, min(16, barSteps))
        let s = max(0, min(n - 1, step))
        return (s, max(1, min(len, n - s)))
    }

    /// Clamp a MOVE destination so a dragged note keeps its own length inside the bar (a move is not a
    /// re-draw: the length the user already chose must survive wherever it still fits).
    nonisolated static func boundedMoveStep(_ to: Int, dur: Int, barSteps: Int) -> Int {
        let n = max(1, min(16, barSteps))
        return max(0, min(n - max(1, min(dur, n)), to))
    }
    /// Mutate whichever note array the roll is editing (Lead = `melody`, else the active part).
    private func mutateActiveNotes(_ f: (inout [MelodyNote]) -> Void) {
        if activePart == "lead" { f(&melody) }
        else if let i = parts.firstIndex(where: { $0.id == activePart }) { f(&parts[i].notes) }
    }
    /// Replace the active part's notes wholesale — used by the free-form PianoRoll editor, which edits a
    /// whole model rather than one cell. Coalesced into a single undo step; kept step-sorted for the roll.
    func replaceActiveNotes(_ notes: [MelodyNote]) {
        checkpoint("freeroll")
        mutateActiveNotes { $0 = notes.sorted { $0.step < $1.step } }
    }
    /// Draw (or extend) a note of `len` steps at `start` — used by the piano-roll click-drag.
    func drawActiveNote(pitch: Int, start: Int, len: Int) {
        let (start, dur) = Self.boundedNote(step: start, len: len, barSteps: barSteps)
        let lo = start, hi = start + dur
        checkpoint("drawnote")   // coalesces a drag into one undo
        mutateActiveNotes { n in
            n.removeAll { $0.pitch == pitch && $0.step < hi && $0.step + $0.dur > lo }
            n.append(MelodyNote(step: start, pitch: pitch, dur: dur, vel: start % 4 == 0 ? 0.95 : 0.8))
        }
    }
    func eraseActiveNote(pitch: Int, step: Int) {
        checkpoint("erasenote", coalesce: false)
        mutateActiveNotes { n in n.removeAll { $0.pitch == pitch && step >= $0.step && step < $0.step + $0.dur } }
    }
    /// Slide the note at (pitch, `from`) to a new start `to`, keeping its length + velocity — the roll's
    /// drag-to-move. Clamps to the bar and clears whatever sits at the destination span. Coalesced into
    /// one undo across a drag.
    func moveActiveNote(pitch: Int, from: Int, to: Int) {
        checkpoint("movenote")
        mutateActiveNotes { n in
            guard let idx = n.firstIndex(where: { $0.pitch == pitch && from >= $0.step && from < $0.step + $0.dur }) else { return }
            let note = n.remove(at: idx)
            let bar = max(1, min(16, barSteps))
            let dur = max(1, min(note.dur, bar))
            let start = Self.boundedMoveStep(to, dur: dur, barSteps: bar)
            let lo = start, hi = start + dur
            n.removeAll { $0.pitch == pitch && $0.step < hi && $0.step + $0.dur > lo }   // clear the destination span
            n.append(MelodyNote(step: start, pitch: pitch, dur: dur, vel: note.vel))
        }
    }
    /// MIDI record capture: overdub a live-played note into the active part at `step`, snapped to the grid.
    /// Replaces any note already sounding at that pitch+step. Coalesced so a whole take is a few undos.
    func captureNote(pitch: Int, step: Int, len: Int = 1, wrapped: Bool = false, velocity: Double? = nil) {
        let (s, dur) = Self.boundedNote(step: step, len: len, barSteps: barSteps)
        checkpoint("reccapture")
        let write: (inout [MelodyNote]) -> Void = { n in
            n.removeAll { $0.pitch == pitch && s >= $0.step && s < $0.step + $0.dur }
            n.append(MelodyNote(step: s, pitch: pitch, dur: dur, vel: velocity.map { max(0.05, min(1, $0)) } ?? (s % 4 == 0 ? 0.9 : 0.8)))
        }
        // Song Mode: the keyboard records into the sequence SOUNDING at this bar, like the pads (round 2, transport-1).
        if let target = recordTargetSequence(track: "vox", wrapToNextBar: wrapped) {
            if activePart == "lead" { write(&sequences[target].melody); return }
            if let i = sequences[target].parts.firstIndex(where: { $0.id == activePart }) { write(&sequences[target].parts[i].notes); return }
            // The active part does not exist in that sequence yet: carry it over (empty) so the note has a
            // home instead of vanishing after the checkpoint already dirtied the project (round 3, undo-2).
            if var copy = parts.first(where: { $0.id == activePart }) {
                copy.notes = []
                sequences[target].parts.append(copy)
                write(&sequences[target].parts[sequences[target].parts.count - 1].notes)
                return
            }
        }
        mutateActiveNotes(write)
    }
    /// Clear the notes of the part the roll is currently editing (one-tap "clear this"). Undoable.
    func clearActiveNotes() {
        checkpoint("clearpart", coalesce: false)
        mutateActiveNotes { $0 = [] }
    }
    /// Clear every melodic part's notes (all instrument parts + the lead melody), keeping drums + sounds.
    func clearAllParts() {
        checkpoint("clearparts", coalesce: false)
        melody = []
        for i in parts.indices { parts[i].notes = [] }
    }
    /// Fresh canvas: empty the drum pattern AND every melodic part, keeping the loaded kit / sounds / tempo.
    func clearEverything() {
        checkpoint("clearall", coalesce: false)
        for k in Array(lanes.keys) { lanes[k] = Kit.emptyLane() }
        stepMeta = [:]
        melody = []
        for i in parts.indices { parts[i].notes = [] }
    }

    /// Set the velocity of the note covering `step` (the piano-roll velocity lane).
    func setActiveNoteVel(step: Int, _ vel: Double) {
        checkpoint("notevel")
        mutateActiveNotes { n in
            if let i = n.firstIndex(where: { step >= $0.step && step < $0.step + $0.dur }) { n[i].vel = max(0.05, min(1, vel)) }
        }
    }
    /// Velocity of the active-part note covering `step`, or 0 if empty.
    func activeNoteVel(at step: Int) -> Double {
        activeNotes.first { step >= $0.step && step < $0.step + $0.dur }?.vel ?? 0
    }

    /// Place/remove a note in the active part (mirrors `placeMelodyNote`).
    func placeActiveNote(step: Int, pitch: Int, len: Int) {
        if activePart == "lead" { placeMelodyNote(step: step, pitch: pitch, len: len); return }
        guard let i = parts.firstIndex(where: { $0.id == activePart }) else { return }
        checkpoint("partnote", coalesce: false)
        if let j = parts[i].notes.firstIndex(where: { $0.pitch == pitch && step >= $0.step && step < $0.step + $0.dur }) {
            parts[i].notes.remove(at: j); return
        }
        let (step, dur) = Self.boundedNote(step: step, len: len, barSteps: barSteps)
        let lo = step, hi = step + dur
        parts[i].notes.removeAll { $0.pitch == pitch && $0.step < hi && $0.step + $0.dur > lo }
        parts[i].notes.append(MelodyNote(step: step, pitch: pitch, dur: dur, vel: step % 4 == 0 ? 0.95 : 0.8))
    }

    // MARK: part management

    /// Lead + every extra part, for the part switcher (id, name, muted).
    var partList: [(id: String, name: String, muted: Bool, color: Color)] {
        [("lead", "Lead", melodyMuted, synthPatch.color)]
            + parts.map { ($0.id, $0.name, $0.muted, $0.patch.color) }
    }
    func selectPart(_ id: String) { activePart = id }
    func togglePartMute(_ id: String) {
        checkpoint("partmute:\(id)", coalesce: false)
        if id == "lead" { melodyMuted.toggle() }
        else if let i = parts.firstIndex(where: { $0.id == id }) { parts[i].muted.toggle() }
    }
    func removePart(_ id: String) {
        guard id != "lead" else { return }
        // Bake any track live-linked to this part into a frozen copy FIRST — otherwise deleting the part
        // orphans the track into an unrecoverable silent zombie (#review).
        for t in tracks where t.source.link?.kind == .part && t.source.link?.partID == id {
            _ = freezeLinkToCopy(t.id)
        }
        checkpoint("rmpart", coalesce: false)
        parts.removeAll { $0.id == id }
        if activePart == id { activePart = "lead" }
    }
    /// Add a NEW empty layer (its own sound + roll) and select it — the "build another part from scratch"
    /// flow. Inherits the current edit sound as a starting point; pick a new sound for it from the browser.
    @discardableResult
    func addEmptyPart(name: String? = nil) -> String {
        checkpoint("addpart", coalesce: false)
        let id = "part-\(UUID().uuidString.prefix(6))"
        parts.append(InstrumentPart(id: id, name: name ?? "Layer \(parts.count + 1)", patch: editPatch, notes: []))
        activePart = id
        return id
    }

    /// Create or refresh a named part with a preset patch + notes, and select it.
    private func setPart(_ id: String, _ name: String, patch patchName: String, notes: [MelodyNote]) {
        checkpoint("gen:\(id)", coalesce: false)
        let patch = SynthPresets.all.first { $0.name == patchName } ?? SynthPresets.default
        if let i = parts.firstIndex(where: { $0.id == id }) { parts[i].notes = notes; parts[i].muted = false }
        else { parts.append(InstrumentPart(id: id, name: name, patch: patch, notes: notes)) }
        activePart = id
    }

    // MARK: generators (I-V-vi-IV / i-VI-III-VII)

    private var layerDegrees: [Int] { melodyScale == "minor" ? [0, 5, 2, 6] : [0, 4, 5, 3] }
    private func chordPCs(_ deg: Int) -> [Int] {
        let iv = Music.intervals(melodyScale); let n = iv.count
        guard n >= 5 else { return [melodyKey % 12] }
        return [iv[deg % n], iv[(deg + 2) % n], iv[(deg + 4) % n]].map { (melodyKey + $0) % 12 }
    }

    /// Bass part (Sub Bass patch) — root notes with an 8th pulse.
    func genBassLayer() {
        var notes: [MelodyNote] = []
        for (i, deg) in layerDegrees.enumerated() {
            let root = 36 + (chordPCs(deg).first ?? 0)
            notes.append(MelodyNote(step: i * 4, pitch: root, dur: 2, vel: 0.62))
            notes.append(MelodyNote(step: i * 4 + 2, pitch: root, dur: 2, vel: 0.5))
        }
        setPart("bass", "Bass", patch: "Sub Bass", notes: notes)
    }
    /// Chords part (Warm Pad patch) — block triads.
    func genChordLayer() {
        var notes: [MelodyNote] = []
        for (i, deg) in layerDegrees.enumerated() {
            for pc in chordPCs(deg) { notes.append(MelodyNote(step: i * 4, pitch: 60 + pc, dur: 4, vel: 0.42)) }
        }
        setPart("chords", "Chords", patch: "Warm Pad", notes: notes)
    }
    /// Arp lead — fills the main Lead melody.
    func genArpLayer() {
        checkpoint("genArp", coalesce: false)
        var notes: [MelodyNote] = []
        for (i, deg) in layerDegrees.enumerated() {
            let tones = chordPCs(deg).map { 72 + $0 }
            for s in 0..<4 { notes.append(MelodyNote(step: i * 4 + s, pitch: tones[s % tones.count], dur: 1, vel: 0.45)) }
        }
        melody = notes; melodyMuted = false; activePart = "lead"
    }
}
