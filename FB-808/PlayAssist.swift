//  PlayAssist.swift — creative-assist for the synth keyboard (Domain E):
//  one-finger chords (E2/E5) and an arpeggiator (E3). Built on the existing
//  scale-lock so chords stay diatonic in the song key. State lives on Project.

import Foundation

extension Project {

    // MARK: chords (E2)

    /// The notes a single key should sound, given the current chord mode. Triad/7th
    /// build the *diatonic* chord in the song scale (stacked scale-thirds); power/octave
    /// are fixed intervals. Off-scale notes fall back to a plain major chord.
    func chordTones(_ midi: Int) -> [Int] {
        switch chordMode {
        case "octave": return [midi, midi + 12]
        case "power":  return [midi, midi + 7]
        case "triad", "7th":
            let iv = Music.intervals(melodyScale)
            let n = iv.count
            guard n >= 3 else { return [midi] }
            let pc = Music.pitchClass(midi - melodyKey)
            guard let deg = iv.firstIndex(of: pc) else {
                return chordMode == "7th" ? [midi, midi + 4, midi + 7, midi + 11]
                                          : [midi, midi + 4, midi + 7]
            }
            func tone(_ d: Int) -> Int { midi + iv[d % n] + 12 * (d / n) - iv[deg] }
            var t = [tone(deg), tone(deg + 2), tone(deg + 4)]
            if chordMode == "7th" { t.append(tone(deg + 6)) }
            return t
        default: return [midi]
        }
    }

    // MARK: note routing

    func assistNoteOn(_ key: String, _ midi: Int) {
        let tones = chordTones(midi)
        assistHeld[key] = tones
        if arpMode == "off" {
            for t in tones { engine.synthOn("\(key)#\(t)", midi: t, patch: editPatch, vel: synthGain) }
        } else {
            restartArp()   // (re)seed the arp clock with the new held set
        }
    }

    func assistNoteOff(_ key: String) {
        let tones = assistHeld[key] ?? []
        assistHeld[key] = nil
        if arpMode == "off" {
            for t in tones { engine.synthOff("\(key)#\(t)") }
        } else if assistHeld.isEmpty {
            stopArp()
        }
    }

    /// Release everything and stop the clock — call when leaving the synth or toggling arp off.
    func assistPanic() {
        stopArp()
        for (key, tones) in assistHeld { for t in tones { engine.synthOff("\(key)#\(t)") } }
        assistHeld.removeAll()
    }

    // MARK: arpeggiator (E3)

    /// Beats-per-step for the current arp rate.
    private var arpBeats: Double {
        switch arpRate { case "1/8": return 0.5; case "1/16T": return 1.0 / 6; case "1/32": return 0.125; default: return 0.25 }
    }
    func arpStepSec() -> Double { (60.0 / Double(max(40, bpm))) * arpBeats }

    /// The note order the arp walks through, from the held chord tones × octaves × direction.
    func arpNotes() -> [Int] {
        let base = Array(Set(assistHeld.values.flatMap { $0 })).sorted()
        guard !base.isEmpty else { return [] }
        var up: [Int] = []
        for o in 0..<max(1, arpOct) { up += base.map { $0 + 12 * o } }
        switch arpMode {
        case "down": return up.reversed()
        case "updown": return up.count <= 1 ? up : up + up.dropFirst().dropLast().reversed()
        default: return up   // "up" and "random" both index into ascending order
        }
    }

    func restartArp() {
        arpTimer?.invalidate()
        arpIdx = 0
        arpNextTime = engine.now() + 0.02            // first note just ahead of the clock
        arpPump()                                    // schedule the first batch immediately
        // Fixed 20ms pump (NOT one-fire-per-note): notes are scheduled at absolute engine times with
        // lookahead, so timer jitter no longer shifts the onsets — the arp is now sample-anchored.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.arpPump() }
        }
        arpTimer = timer
    }

    func stopArp() { arpTimer?.invalidate(); arpTimer = nil; arpIdx = 0 }

    /// Schedule every arp note whose time falls within the lookahead window, at its absolute engine time.
    private func arpPump() {
        let notes = arpNotes()
        guard !notes.isEmpty else { stopArp(); return }
        let ahead = engine.now() + 0.1               // 100ms lookahead (survives a main-thread stall)
        if arpNextTime < engine.now() { arpNextTime = engine.now() + 0.005 }   // never schedule in the past
        let step = max(0.02, arpStepSec())           // re-read each pump → live BPM changes apply immediately
        while arpNextTime < ahead {
            let idx = arpMode == "random" ? Int.random(in: 0..<notes.count) : (arpIdx % notes.count)
            if arpMode != "random" { arpIdx += 1 }
            engine.triggerSynth(editPatch, midi: notes[idx], dur: step * 0.9, vel: synthGain, when: arpNextTime)
            arpNextTime += step
        }
    }
}
