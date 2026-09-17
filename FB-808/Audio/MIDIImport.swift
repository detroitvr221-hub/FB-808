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
        let headerLength = (Int(b[4]) << 24) | (Int(b[5]) << 16) | (Int(b[6]) << 8) | Int(b[7])
        guard headerLength >= 6, headerLength <= n - 8 else { return nil }
        var i = 8                                          // skip MThd + length
        i += 2                                             // format
        let ntrks = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2
        let division = (Int(b[i]) << 8) | Int(b[i + 1]); i += 2
        guard division > 0, division & 0x8000 == 0, ntrks > 0 else { return nil }
        i = 8 + headerLength             // SMPTE timing unsupported
        let ticksPer16 = Double(division) / 4.0

        struct On { let tick: Int; let vel: Int }
        var notes: [MelodyNote] = []

        for _ in 0..<max(1, ntrks) {
            guard i + 8 <= n, b[i] == 0x4D, b[i + 1] == 0x54, b[i + 2] == 0x72, b[i + 3] == 0x6B else { break }  // "MTrk"
            i += 4
            let len = (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3]); i += 4
            guard len <= n - i else { return nil }
            let end = i + len
            var tick = 0, status: UInt8 = 0
            var pending: [Int: [On]] = [:]

            func varlen() -> Int? {
                var value = 0
                for _ in 0..<4 {
                    guard i < end else { return nil }
                    let byte = b[i]; i += 1
                    value = (value << 7) | Int(byte & 0x7F)
                    if byte & 0x80 == 0 { return value }
                }
                return nil
            }

            while i < end {
                guard let delta = varlen(), tick <= Int.max - delta else { return nil }
                tick += delta
                guard i < end else { break }
                let peek = b[i]
                if peek == 0xFF {                          // meta: FF type varlen data
                    i += 1; guard i < end else { return nil }; i += 1
                    guard let l = varlen(), l <= end - i else { return nil }
                    i += l; status = 0; continue
                }
                if peek == 0xF0 || peek == 0xF7 {
                    i += 1
                    guard let l = varlen(), l <= end - i else { return nil }
                    i += l; status = 0; continue
                }  // sysex
                var st = peek
                if peek & 0x80 != 0 { status = peek; i += 1 } else { st = status }               // running status
                guard st >= 0x80, st < 0xF0 else { return nil }
                let hi = st & 0xF0
                let width = hi == 0xC0 || hi == 0xD0 ? 1 : 2
                guard width <= end - i, b[i..<(i + width)].allSatisfy({ $0 < 0x80 }) else { return nil }
                switch hi {
                case 0x90, 0x80:
                    guard i + 1 < end else { i = end; break }
                    let pitch = Int(b[i]), vel = Int(b[i + 1]); i += 2
                    let key = Int(st & 0x0F) * 128 + pitch
                    if hi == 0x90 && vel > 0 {
                        pending[key, default: []].append(On(tick: tick, vel: vel))
                    } else if var stack = pending[key], let on = stack.popLast() {
                        pending[key] = stack
                        let step = Int((Double(on.tick) / ticksPer16).rounded())
                        let dur = max(1, Int((Double(tick - on.tick) / ticksPer16).rounded()))
                        if step >= 0 && step < barSteps {
                            notes.append(MelodyNote(step: step, pitch: pitch, dur: min(barSteps - step, dur), vel: min(1, Double(on.vel) / 127.0)))
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
