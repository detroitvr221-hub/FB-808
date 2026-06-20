//  SoundFont.swift — minimal SF2 (.sf2) parser → a playable multisample instrument
//  (FL-Mobile DirectWave / SoundFont-Player parity, Phase 3). Parses the RIFF/sfbk
//  structure: sdta▸smpl (16-bit PCM) + pdta▸{shdr, inst, ibag, igen} (the "hydra"),
//  and builds the FIRST instrument's key-mapped regions. Preset layer is skipped —
//  the instrument is the playable unit, which covers the vast majority of fonts.

import Foundation

/// One key-mapped sample zone of a SoundFont instrument.
struct SFRegion {
    var loKey: Int, hiKey: Int          // MIDI key range this sample covers
    var rootKey: Int                    // the MIDI note the sample plays at original pitch
    var tuneCents: Int                  // fine pitch correction
    var loopStart: Int, loopEnd: Int    // sample-frame loop points (relative to pcm)
    var loopOn: Bool
    var sampleRate: Double
    var pcm: [Float]                    // mono PCM, −1..1
}

struct SFInstrument {
    var name: String
    var regions: [SFRegion]
    /// The region whose key range covers `key` (nearest by root if none match).
    func region(for key: Int) -> SFRegion? {
        regions.first { key >= $0.loKey && key <= $0.hiKey }
            ?? regions.min { abs($0.rootKey - key) < abs($1.rootKey - key) }
    }
}

enum SoundFont {

    // little-endian readers over Data
    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) }
    private static func i16(_ d: Data, _ o: Int) -> Int { let v = u16(d, o); return v >= 0x8000 ? v - 0x10000 : v }
    private static func u32(_ d: Data, _ o: Int) -> Int { Int(d[o]) | (Int(d[o + 1]) << 8) | (Int(d[o + 2]) << 16) | (Int(d[o + 3]) << 24) }
    private static func tag(_ d: Data, _ o: Int) -> String { String(bytes: d[o..<o + 4], encoding: .ascii) ?? "" }
    private static func name(_ d: Data, _ o: Int, _ len: Int = 20) -> String {
        var bytes = [UInt8](); for i in 0..<len { let b = d[o + i]; if b == 0 { break }; bytes.append(b) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Walk top-level (and LIST) chunks, returning (id, dataOffset, size) for each.
    private static func chunks(_ d: Data, from: Int, to: Int) -> [(id: String, off: Int, size: Int)] {
        var out: [(String, Int, Int)] = []
        var p = from
        while p + 8 <= to {
            let id = tag(d, p), size = u32(d, p + 4)
            let body = p + 8
            if id == "LIST" {
                out.append((tag(d, body), body + 4, size - 4))   // report the LIST's form-type + inner range
            } else {
                out.append((id, body, size))
            }
            p = body + size + (size & 1)   // chunks are word-aligned
        }
        return out
    }

    static func load(_ data: Data) -> SFInstrument? {
        let d = data
        guard d.count > 12, tag(d, 0) == "RIFF", tag(d, 8) == "sfbk" else { return nil }
        // top-level LISTs: INFO, sdta, pdta
        var smplOff = 0, smplLen = 0
        var pdtaRanges: [String: (Int, Int)] = [:]
        for c in chunks(d, from: 12, to: 8 + u32(d, 4)) {
            if c.id == "sdta" {
                for s in chunks(d, from: c.off, to: c.off + c.size) where s.id == "smpl" { smplOff = s.off; smplLen = s.size }
            } else if c.id == "pdta" {
                for s in chunks(d, from: c.off, to: c.off + c.size) { pdtaRanges[s.id] = (s.off, s.size) }
            }
        }
        guard smplLen > 0, let shdrR = pdtaRanges["shdr"], let instR = pdtaRanges["inst"],
              let ibagR = pdtaRanges["ibag"], let igenR = pdtaRanges["igen"] else { return nil }

        // sample headers (46 bytes each)
        struct SH { var start: Int; var end: Int; var loopS: Int; var loopE: Int; var rate: Int; var root: Int; var corr: Int }
        var shdr: [SH] = []
        var o = shdrR.0
        while o + 46 <= shdrR.0 + shdrR.1 {
            shdr.append(SH(start: u32(d, o + 20), end: u32(d, o + 24), loopS: u32(d, o + 28), loopE: u32(d, o + 32),
                           rate: u32(d, o + 36), root: Int(d[o + 40]), corr: Int(Int8(bitPattern: d[o + 41]))))
            o += 46
        }
        // instruments (22 bytes) → bag index; ibag (4 bytes) → gen index; igen (4 bytes) → (oper, amount)
        let instCount = max(0, instR.1 / 22)
        guard instCount >= 2 else { return nil }   // ≥1 real instrument + terminal
        let firstBag = u16(d, instR.0 + 20), nextBag = u16(d, instR.0 + 22 + 20)   // instrument[0] bags

        func igen(_ idx: Int) -> (oper: Int, amt: Int) { (u16(d, igenR.0 + idx * 4), u16(d, igenR.0 + idx * 4 + 2)) }

        var regions: [SFRegion] = []
        for bag in firstBag..<max(firstBag, nextBag) {
            let gLo = u16(d, ibagR.0 + bag * 4)
            let gHi = u16(d, ibagR.0 + (bag + 1) * 4)
            var loKey = 0, hiKey = 127, root = -1, sampleID = -1, loopOn = false
            for g in gLo..<max(gLo, gHi) {
                let (oper, amt) = igen(g)
                switch oper {
                case 43: loKey = amt & 0xFF; hiKey = (amt >> 8) & 0xFF      // keyRange
                case 58: root = amt                                         // overridingRootKey
                case 54: loopOn = (amt & 1) == 1 || (amt & 3) == 1          // sampleModes (1/3 = loop)
                case 53: sampleID = amt                                     // sampleID — TERMINAL generator
                default: break
                }
            }
            guard sampleID >= 0, sampleID < shdr.count else { continue }   // skip global zone
            let sh = shdr[sampleID]
            guard sh.end > sh.start, smplOff + sh.end * 2 <= smplOff + smplLen else { continue }
            var pcm = [Float](repeating: 0, count: sh.end - sh.start)
            for i in 0..<pcm.count { pcm[i] = Float(i16(d, smplOff + (sh.start + i) * 2)) / 32768.0 }
            regions.append(SFRegion(loKey: loKey, hiKey: hiKey,
                                    rootKey: root >= 0 ? root : sh.root,
                                    tuneCents: sh.corr,
                                    loopStart: max(0, sh.loopS - sh.start), loopEnd: max(0, sh.loopE - sh.start),
                                    loopOn: loopOn, sampleRate: Double(max(8000, sh.rate)), pcm: pcm))
        }
        guard !regions.isEmpty else { return nil }
        return SFInstrument(name: name(d, instR.0), regions: regions)
    }
}
