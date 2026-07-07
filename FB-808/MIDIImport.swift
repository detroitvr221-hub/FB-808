//  MIDIImport.swift — minimal Standard MIDI File (SMF) reader → MelodyNotes, quantized to the app's
//  16th-note grid (one bar). Complements MIDIExport (which only writes). Used to load a kit's .mid loops
//  into the active piano-roll part.

import Foundation

enum MIDIImport {
    /// Parse an SMF into MelodyNotes on a `barSteps`-step grid. Note-ons past the first bar are dropped.
    static func parse(_ url: URL, barSteps: Int = 16) -> [MelodyNote]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let b = [UInt8](data); let n = b.count
        guard n > 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else { return nil }  // "MThd"
        var i = 8                                          // skip MThd + length
        i += 2                                             // format
        let ntrks = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2
        let division = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2
        guard division > 0 else { return nil }             // SMPTE timing unsupported
        let ticksPer16 = Double(division) / 4.0

        struct On { let tick: Int; let vel: Int }
        var notes: [MelodyNote] = []

        for _ in 0..<max(1, ntrks) {
            guard i + 8 <= n, b[i] == 0x4D, b[i + 1] == 0x54, b[i + 2] == 0x72, b[i + 3] == 0x6B else { break }  // "MTrk"
            i += 4
            let len = (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3]); i += 4
            let end = min(n, i + len)
            var tick = 0, status: UInt8 = 0
            var pending: [Int: [On]] = [:]

            func varlen() -> Int { var v = 0; while i < end { let c = b[i]; i += 1; v = (v << 7) | Int(c & 0x7F); if c & 0x80 == 0 { break } }; return v }

            while i < end {
                tick += varlen()
                guard i < end else { break }
                let peek = b[i]
                if peek == 0xFF {                          // meta: FF type varlen data
                    i += 1; guard i < end else { break }; i += 1; let l = varlen(); i += l; continue
                }
                if peek == 0xF0 || peek == 0xF7 { i += 1; let l = varlen(); i += l; continue }  // sysex
                var st = peek
                if peek & 0x80 != 0 { status = peek; i += 1 } else { st = status }               // running status
                let hi = st & 0xF0
                switch hi {
                case 0x90, 0x80:
                    guard i + 1 < end else { i = end; break }
                    let pitch = Int(b[i]), vel = Int(b[i + 1]); i += 2
                    if hi == 0x90 && vel > 0 {
                        pending[pitch, default: []].append(On(tick: tick, vel: vel))
                    } else if var stack = pending[pitch], let on = stack.popLast() {
                        pending[pitch] = stack
                        let step = Int((Double(on.tick) / ticksPer16).rounded())
                        let dur = max(1, Int((Double(tick - on.tick) / ticksPer16).rounded()))
                        if step >= 0 && step < barSteps {
                            notes.append(MelodyNote(step: step, pitch: pitch, dur: min(barSteps - step, dur), vel: min(1, Double(on.vel) / 110)))
                        }
                    }
                case 0xA0, 0xB0, 0xE0: i += 2              // 2-data channel messages
                case 0xC0, 0xD0: i += 1                    // 1-data channel messages
                default: i += 1
                }
            }
            i = end
        }
        return notes.isEmpty ? nil : notes
    }
}
