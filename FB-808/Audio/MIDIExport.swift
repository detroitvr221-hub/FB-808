//  MIDIExport.swift — write the beat (drum lanes + melody) to a Standard MIDI
//  File so it opens in any DAW. Drums land on GM channel 10; melody on channel 1.

import Foundation

private func varlen(_ value: Int) -> [UInt8] {
    var v = max(0, value)
    var out = [UInt8(v & 0x7F)]
    v >>= 7
    while v > 0 { out.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
    return out
}

// FD-808 pad → General MIDI percussion note (channel 10).
private let GM_DRUM: [String: UInt8] = [
    "kick": 36, "sub808": 35, "snare": 38, "clap": 39, "rim": 37, "cowbell": 56,
    "hatClosed": 42, "hatOpen": 46, "lowTom": 45, "midTom": 47, "hiTom": 50,
    "crash": 49, "conga": 63, "perc": 62, "shaker": 70, "fx": 81,
]

extension Project {
    /// Render the project to a format-0 `.mid` file in the temp directory.
    /// Same length choice as the audio export (#export-3): `loopBarsOverride` bounces the pattern for N bars,
    /// `songModeOverride` forces the arrangement.
    func exportMIDIFile(loopBarsOverride: Int? = nil, songModeOverride: Bool? = nil) -> URL? {
        let ppq = 480, tick16 = ppq / 4
        let n = max(1, barSteps)              // steps per bar (honor the time signature, not a literal 16)
        let songMode = loopBarsOverride == nil ? (songModeOverride ?? self.songMode) : false
        let totalBars = loopBarsOverride ?? (songMode ? songBars : 4)
        // Swing: playback delays every off-beat 16th by swing·0.66 of a step (Transport.scheduler), applied
        // to the whole step — so MIDI offsets any note on an odd step by the same amount to match the groove.
        // Per-step micro-timing in ticks: the named groove feel (E4), else the Swing slider — matches playback.
        let groove = Groove.byID(grooveID)
        let swingTk = Int((Double(tick16) * swing * 0.66).rounded())
        func pushTicks(_ step: Int) -> Int {
            grooveID == "straight" ? (step % 2 == 1 ? swingTk : 0) : Int((Double(tick16) * groove.push[step % 16]).rounded())
        }
        func onTick(_ bar: Int, _ step: Int) -> Int { max(0, bar * n * tick16 + step * tick16 + pushTicks(step)) }

        var events: [(tick: Int, data: [UInt8])] = []
        let mpq = 60_000_000 / max(1, bpm)   // microseconds per quarter note
        events.append((0, [0xFF, 0x51, 0x03, UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]))
        // track name + time signature so the file opens cleanly in a DAW
        let nameBytes = Array(name.prefix(120).utf8)
        events.append((0, [0xFF, 0x03] + varlen(nameBytes.count) + nameBytes))
        events.append((0, [0xFF, 0x58, 0x04, UInt8(max(1, n / 4)), 2, 24, 8]))   // numerator = steps/4, denom = quarter

        // Emit a drum hit / melodic note with swing-aware timing.
        func drum(_ note: UInt8, _ vel01: Double, bar: Int, step: Int) {
            let vel = UInt8(max(1, min(127, Int(vel01 * 127))))
            let on = onTick(bar, step)
            events.append((on, [0x99, note, vel]))
            events.append((on + tick16 / 2, [0x89, note, 0]))
        }
        func melodic(_ pitch: Int, _ vel01: Double, dur: Int, bar: Int, step: Int) {
            let note = UInt8(max(0, min(127, pitch)))
            let vel = UInt8(max(1, min(127, Int(vel01 * 127))))
            let on = onTick(bar, step)
            events.append((on, [0x90, note, vel]))
            events.append((on + max(1, dur) * tick16, [0x80, note, 0]))
        }

        // Structural per-step gates (A9): probability + conditions decide whether a note EXISTS, so MIDI must
        // honor them or it exports notes the audio bounce suppresses. Mirrors Export.swift's deterministic seed
        // exactly so the .mid and the .wav agree. Mix gates (mute/solo) are left out on purpose — MIDI keeps raw
        // notes for re-mixing in a DAW.
        func stepPasses(_ sm: StepMeta?, _ padID: String, _ step: Int, bar: Int) -> Bool {
            guard let sm else { return true }
            if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { return false }
            if sm.prob < 0.999 {
                var seed = UInt64(bar &* 16 &+ step) &+ 1
                for ch in padID.unicodeScalars { seed = seed &* 31 &+ UInt64(ch.value) }
                if Double(seed % 997) / 997.0 > sm.prob { return false }
            }
            return true
        }
        func stepSounds(_ padID: String, _ step: Int, bar: Int, meta: [String: [Int: StepMeta]]) -> Bool {
            stepPasses(meta[padID]?[step], padID, step, bar: bar)
        }

        // Content the .mid emits for a track. A baked-to-audio ("Freeze to Audio") track has no captured
        // copy — only its rendering became a clip — so its notes still live in the linked source. (#15)
        // These resolve a LINKED track's content for export, so they must honour the same clip pattern
        // pin playback does — otherwise a pinned track exports the section's pattern and the MIDI file
        // disagrees with what the app plays (re-audit, gap E).
        func midiLanes(_ track: Track, atBar bar: Int) -> [String: [Double]]? {
            if let link = track.source.link, track.isLinked || track.frozenToAudio {
                return resolvedLanes(link, atBar: bar, pinnedSeq: clipSeq(track: track.id, atBar: bar))
            }
            return track.source.lanes
        }
        func midiNotes(_ track: Track, atBar bar: Int) -> [MelodyNote]? {
            if let link = track.source.link, track.isLinked || track.frozenToAudio {
                return resolvedNotes(link, atBar: bar, pinnedSeq: clipSeq(track: track.id, atBar: bar))?.notes
            }
            return track.source.notes
        }

        for bar in 0..<totalBars {
            // Same clip-pin fold as playback and the audio bounce, so all three agree.
            let pins = songMode ? clipSeqOverrides(atBar: bar) : [:]
            let curLanes = Transport.foldClipPins(base: songMode ? lanesForBar(bar) : lanes, overrides: pins,
                                                  lanesOfSeq: { self.lanesOfSeq($0) }, trackOf: { Kit.trackOf($0) })
            let curMelody = songMode ? melodyForTrack("vox", atBar: bar) : melody
            let curParts = songMode ? partsForTrack("vox", atBar: bar) : parts
            var curMeta = songMode ? stepMetaForBar(bar) : stepMeta
            for (tk, si) in pins {
                let src = stepMetaOfSeq(si)
                for pad in Set(curMeta.keys).union(src.keys) where Kit.trackOf(pad) == tk { curMeta[pad] = src[pad] }
            }
            // Sources a track reproduces from its own content are suppressed here and emitted from the track
            // below, so a sent / promoted / frozen pattern lands in the .mid ONCE — matching live playback
            // and the WAV bounce instead of duplicating every note. (#15)
            var ownedRows = Set<String>()
            var ownedLeadMelody = false
            var ownedPartIDs = Set<String>()
            for track in tracks where track.playsAdditively || track.frozenToAudio {
                let owned = trackOwnership(track)
                if owned.allLanes { ownedRows.formUnion(curLanes.keys) } else { ownedRows.formUnion(owned.rows) }
                ownedLeadMelody = ownedLeadMelody || owned.leadMelody
                ownedPartIDs.formUnion(owned.partIDs)
            }
            for (padID, lane) in curLanes where !ownedRows.contains(padID) {
                guard let note = GM_DRUM[padID] else { continue }
                for s in 0..<min(n, lane.count) where lane[s] > 0 && stepSounds(padID, s, bar: bar, meta: curMeta) {
                    drum(note, lane[s], bar: bar, step: s)
                }
            }
            if !ownedLeadMelody {
                for nt in curMelody { melodic(nt.pitch, nt.vel, dur: nt.dur, bar: bar, step: nt.step) }
            }
            for part in curParts where !part.muted && !ownedPartIDs.contains(part.id) {   // extra instrument parts on channel 1 too (were dropped)
                for nt in part.notes { melodic(nt.pitch, nt.vel, dur: nt.dur, bar: bar, step: nt.step) }
            }
            // Arrangement tracks (promoted melodies / sent drum tracks / frozen copies / baked-to-audio
            // sources) resolve here. Honor track mute + Song-Mode clip gating (solo is a transient monitor
            // state, not arrangement, so it's intentionally ignored for export).
            for track in tracks where track.playsAdditively || track.frozenToAudio {
                if trackMute[track.id] == true { continue }
                if songMode && !trackPlaysInSong(track.id, atBar: bar) { continue }
                switch track.type {
                case .drumPattern:
                    guard let tl = midiLanes(track, atBar: bar) else { break }
                    for (padID, lane) in tl {
                        guard let note = GM_DRUM[padID] else { continue }
                        for s in 0..<min(n, lane.count) where lane[s] > 0 && stepPasses(trackStepMeta(track, padID, s, atBar: bar), padID, s, bar: bar) {
                            drum(note, lane[s], bar: bar, step: s)
                        }
                    }
                case .synthPart:
                    guard let notes = midiNotes(track, atBar: bar) else { break }
                    for nt in notes { melodic(nt.pitch, nt.vel, dur: nt.dur, bar: bar, step: nt.step) }
                default: break
                }
            }
        }

        // Order ties: meta → note-off → note-on, so nothing hangs.
        func prio(_ d: [UInt8]) -> Int { d[0] == 0xFF ? 0 : (d[0] & 0xF0 == 0x80 ? 1 : 2) }
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : prio($0.data) < prio($1.data) }

        var track: [UInt8] = []
        var last = 0
        for e in events { track += varlen(e.tick - last); track += e.data; last = e.tick }
        track += [0x00, 0xFF, 0x2F, 0x00]   // end of track

        var file = Array("MThd".utf8)
        file += [0, 0, 0, 6, 0, 0, 0, 1, UInt8((ppq >> 8) & 0xFF), UInt8(ppq & 0xFF)]
        file += Array("MTrk".utf8)
        let len = track.count
        file += [UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        file += track

        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = fd808ExportDir().appendingPathComponent("\(safe.isEmpty ? "FD808 Beat" : safe).mid")   // unique batch dir (#227)
        do { try Data(file).write(to: url); return url } catch { return nil }
    }
}
