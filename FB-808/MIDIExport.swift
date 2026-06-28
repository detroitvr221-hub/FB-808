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
    func exportMIDIFile() -> URL? {
        let ppq = 480, tick16 = ppq / 4
        let n = max(1, barSteps)              // steps per bar (honor the time signature, not a literal 16)
        let totalBars = songMode ? songBars : 4
        // Swing: playback delays every off-beat 16th by swing·0.66 of a step (Transport.scheduler), applied
        // to the whole step — so MIDI offsets any note on an odd step by the same amount to match the groove.
        // Per-step micro-timing in ticks: the named groove feel (E4), else the Swing slider — matches playback.
        let groove = Groove.byID(grooveID)
        let swingTk = Int((Double(tick16) * swing * 0.66).rounded())
        func pushTicks(_ step: Int) -> Int {
            grooveID == "straight" ? (step % 2 == 1 ? swingTk : 0) : Int((Double(tick16) * groove.push[step % 16]).rounded())
        }
        func onTick(_ bar: Int, _ step: Int) -> Int { bar * n * tick16 + step * tick16 + pushTicks(step) }

        var events: [(tick: Int, data: [UInt8])] = []
        let mpq = 60_000_000 / max(1, bpm)   // microseconds per quarter note
        events.append((0, [0xFF, 0x51, 0x03, UInt8((mpq >> 16) & 0xFF), UInt8((mpq >> 8) & 0xFF), UInt8(mpq & 0xFF)]))
        // track name + time signature so the file opens cleanly in a DAW
        let nameBytes = Array(name.prefix(120).utf8)
        events.append((0, [0xFF, 0x03, UInt8(nameBytes.count)] + nameBytes))
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

        for bar in 0..<totalBars {
            let curLanes = songMode ? lanesForBar(bar) : lanes
            let curMelody = songMode ? melodyForBar(bar) : melody
            let curParts = songMode ? partsForBar(bar) : parts
            for (padID, lane) in curLanes {
                guard let note = GM_DRUM[padID] else { continue }
                for s in 0..<min(n, lane.count) where lane[s] > 0 { drum(note, lane[s], bar: bar, step: s) }
            }
            for nt in curMelody { melodic(nt.pitch, nt.vel, dur: nt.dur, bar: bar, step: nt.step) }
            for part in curParts where !part.muted {   // extra instrument parts on channel 1 too (were dropped)
                for nt in part.notes { melodic(nt.pitch, nt.vel, dur: nt.dur, bar: bar, step: nt.step) }
            }
            // FROZEN arrangement tracks (promoted melodies / sent drum tracks) — their captured content
            // lives in track.source, NOT in lanes/melody/parts, so it was previously omitted. Linked tracks
            // are already covered by the classic walk above; only frozen additive tracks are added here, so
            // there's no double-count. Honor track mute + Song-Mode clip gating (solo is a transient monitor
            // state, not arrangement, so it's intentionally ignored for export).
            for track in tracks where track.isFrozen && track.playsAdditively {
                if trackMute[track.id] == true { continue }
                if songMode && !trackPlaysInSong(track.id, atBar: bar) { continue }
                switch track.type {
                case .drumPattern:
                    guard let tl = trackLanes(track, atBar: bar) else { break }
                    for (padID, lane) in tl {
                        guard let note = GM_DRUM[padID] else { continue }
                        for s in 0..<min(n, lane.count) where lane[s] > 0 { drum(note, lane[s], bar: bar, step: s) }
                    }
                case .synthPart:
                    guard let (notes, _) = trackNotes(track, atBar: bar) else { break }
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
