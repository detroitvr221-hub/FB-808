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
        engine.setMultiSample(inst.regions.map {
            MultiSampleRegion(loKey: $0.loKey, hiKey: $0.hiKey, rootKey: $0.rootKey,
                              sampleRate: $0.sampleRate, loopOn: $0.loopOn, pcm: $0.pcm)
        })
        checkpoint("loadSF2", coalesce: false)
        var p = editPatch
        p.source = "multisample"
        p.name = inst.name.isEmpty ? "SoundFont" : String(inst.name.prefix(18))
        editPatch = p
        return p.name
    }

    /// The notes the piano roll shows/edits for the active part.
    var activeNotes: [MelodyNote] {
        activePart == "lead" ? melody : (parts.first { $0.id == activePart }?.notes ?? [])
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
        let dur = max(1, min(len, 16 - start)), lo = start, hi = start + dur
        checkpoint("drawnote")   // coalesces a drag into one undo
        mutateActiveNotes { n in
            n.removeAll { $0.step < hi && $0.step + $0.dur > lo }
            n.append(MelodyNote(step: start, pitch: pitch, dur: dur, vel: start % 4 == 0 ? 0.95 : 0.8))
        }
    }
    func eraseActiveNote(pitch: Int, step: Int) {
        checkpoint("erasenote", coalesce: false)
        mutateActiveNotes { n in n.removeAll { $0.pitch == pitch && step >= $0.step && step < $0.step + $0.dur } }
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
        let dur = max(1, min(len, 16 - step)), lo = step, hi = step + dur
        parts[i].notes.removeAll { $0.step < hi && $0.step + $0.dur > lo }
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
