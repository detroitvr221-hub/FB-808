//  Kit.swift — pads, patterns, lessons, mixer channels, banks, sections.
//  Ported from kit.js.

import SwiftUI

struct PadDef: Identifiable {
    let id: String        // stable pad id (also the synth voice id for bank A)
    var label: String
    let sound: String     // voice id used to make sound
    let family: String
    var color: Color
    let key: String       // keyboard hint shown on the cap
    var index: Int = 0
    var defaultChoke: Int = 0   // family choke group applied even with no inspector edits (e.g. open/closed hats) (#PADS-02)
}

// Reserved default choke group ids (kept clear of the 1–8 user groups and the 100+ per-pad mono self-cut range).
nonisolated enum DefaultChoke { static let hats = 20 }

// A user-saved drum kit (per-pad sound map). Persisted in AppSettings, shared across projects.
struct UserKitDef: Codable, Identifiable, Equatable { var id: String; var name: String; var sounds: [String: String] }

// Pure static kit data + lookups — nonisolated so the export/render path (off the main actor) can read it.
nonisolated enum Kit {

    // 4x4 grid, reading order top-left -> bottom-right.
    static let pads: [PadDef] = {
        var p: [PadDef] = [
            PadDef(id: "kick",      label: "KICK",    sound: "kick",      family: "boom", color: Color(hex: "#FF5A3C"), key: "1"),
            PadDef(id: "sub808",    label: "808",     sound: "sub808",    family: "boom", color: Color(hex: "#FF7A1A"), key: "2"),
            PadDef(id: "snare",     label: "SNARE",   sound: "snare",     family: "snap", color: Color(hex: "#FFC23C"), key: "3"),
            PadDef(id: "clap",      label: "CLAP",    sound: "clap",      family: "snap", color: Color(hex: "#FFD84D"), key: "4"),
            PadDef(id: "hatClosed", label: "HAT",     sound: "hatClosed", family: "hat",  color: Color(hex: "#33E0D4"), key: "Q", defaultChoke: DefaultChoke.hats),
            PadDef(id: "hatOpen",   label: "OPEN",    sound: "hatOpen",   family: "hat",  color: Color(hex: "#27C2E8"), key: "W", defaultChoke: DefaultChoke.hats),
            PadDef(id: "rim",       label: "RIM",     sound: "rim",       family: "snap", color: Color(hex: "#7AE582"), key: "E"),
            PadDef(id: "cowbell",   label: "COWBELL", sound: "cowbell",   family: "perc", color: Color(hex: "#B6E84D"), key: "R"),
            PadDef(id: "lowTom",    label: "LO TOM",  sound: "lowTom",    family: "tom",  color: Color(hex: "#4DD07A"), key: "A"),
            PadDef(id: "midTom",    label: "MID TOM", sound: "midTom",    family: "tom",  color: Color(hex: "#46C9A8"), key: "S"),
            PadDef(id: "hiTom",     label: "HI TOM",  sound: "hiTom",     family: "tom",  color: Color(hex: "#5BD6C0"), key: "D"),
            PadDef(id: "crash",     label: "CRASH",   sound: "crash",     family: "cym",  color: Color(hex: "#5B8DEF"), key: "F"),
            PadDef(id: "conga",     label: "CONGA",   sound: "conga",     family: "perc", color: Color(hex: "#C77DFF"), key: "Z"),
            PadDef(id: "perc",      label: "PERC",    sound: "perc",      family: "perc", color: Color(hex: "#E879F9"), key: "X"),
            PadDef(id: "shaker",    label: "SHAKER",  sound: "shaker",    family: "perc", color: Color(hex: "#FF7AC6"), key: "C"),
            PadDef(id: "fx",        label: "FX",      sound: "fx",        family: "fx",   color: Color(hex: "#9B8CFF"), key: "V"),
        ]
        for i in p.indices { p[i].index = i }
        return p
    }()

    /// Every pad in every bank, by id. Bank A keeps its bare ids ("kick"); Banks B–D use slot keys
    /// ("C:kick") so the 4 × 16 pads are 64 DISTINCT pads — see `slotKey`.
    static let padByID: [String: PadDef] = {
        var m = Dictionary(uniqueKeysWithValues: pads.map { ($0.id, $0) })
        for b in bankOrder where b != "A" { for p in banks[b]?.pads ?? [] { m[p.id] = p } }
        return m
    }()

    // MARK: Bank slot keys (SAMPLE_FLOW_AUDIT findings 1–2)
    //
    // The four banks used to RELABEL the same 16 pad ids, so a Bank C chop and a Bank A kick were the same
    // pad: one sample slot, one lane, and playback chose between them by whichever bank TAB was showing.
    // Now each bank's pads carry their own id. Bank A keeps the bare id, so every existing project, lane,
    // template and MIDI import is unchanged; B–D prefix it. Everything keyed by pad id — lanes, params,
    // samples, mutes, step meta — becomes per-bank automatically, because the id is where the key starts.

    /// The id for base pad `base` in `bank`: "kick" in Bank A, "C:kick" in Bank C.
    static func slotKey(bank: String, pad base: String) -> String {
        let b = baseID(base)
        return (bank == "A" || bank.isEmpty) ? b : "\(bank):\(b)"
    }
    /// The underlying Bank A pad id ("C:kick" → "kick"). What the mixer channel, arrangement track,
    /// default voice and GM drum note are defined against.
    static func baseID(_ id: String) -> String {
        guard let i = id.firstIndex(of: ":"), id.distance(from: id.startIndex, to: i) == 1 else { return id }
        return String(id[id.index(after: i)...])
    }
    /// The bank a pad id belongs to ("C:kick" → "C", "kick" → "A").
    static func bankOf(_ id: String) -> String {
        guard let i = id.firstIndex(of: ":"), id.distance(from: id.startIndex, to: i) == 1 else { return "A" }
        return String(id[..<i])
    }

    /// Stable identity for all 64 slots, including the reserved Mono self-choke groups.
    static func slotIndex(_ id: String) -> Int {
        (bankOrder.firstIndex(of: bankOf(id)) ?? 0) * pads.count + (padByID[id]?.index ?? 0)
    }

    // MARK: Drum sound catalog (assignable to any pad via the Pad Inspector)

    struct DrumSound: Identifiable, Hashable { let id: String; let label: String; let cat: String }
    static let drumSounds: [DrumSound] = [
        .init(id: "kick", label: "Kick", cat: "Kick / Bass"),
        .init(id: "punchKick", label: "Punch Kick", cat: "Kick / Bass"),
        .init(id: "deepKick", label: "Deep Kick", cat: "Kick / Bass"),
        .init(id: "sub808", label: "808", cat: "Kick / Bass"),
        .init(id: "tom808", label: "808 Tom", cat: "Kick / Bass"),
        .init(id: "snare", label: "Snare", cat: "Snare / Clap"),
        .init(id: "tightSnare", label: "Tight Snare", cat: "Snare / Clap"),
        .init(id: "clap", label: "Clap", cat: "Snare / Clap"),
        .init(id: "snap", label: "Snap", cat: "Snare / Clap"),
        .init(id: "rim", label: "Rim", cat: "Snare / Clap"),
        .init(id: "rimshot", label: "Rimshot", cat: "Snare / Clap"),
        .init(id: "hatClosed", label: "Closed Hat", cat: "Hats / Cymbals"),
        .init(id: "hatOpen", label: "Open Hat", cat: "Hats / Cymbals"),
        .init(id: "ride", label: "Ride", cat: "Hats / Cymbals"),
        .init(id: "crash", label: "Crash", cat: "Hats / Cymbals"),
        .init(id: "tamb", label: "Tambourine", cat: "Hats / Cymbals"),
        .init(id: "lowTom", label: "Low Tom", cat: "Toms"),
        .init(id: "midTom", label: "Mid Tom", cat: "Toms"),
        .init(id: "hiTom", label: "Hi Tom", cat: "Toms"),
        .init(id: "cowbell", label: "Cowbell", cat: "Percussion"),
        .init(id: "conga", label: "Conga", cat: "Percussion"),
        .init(id: "bongo", label: "Bongo", cat: "Percussion"),
        .init(id: "clave", label: "Clave", cat: "Percussion"),
        .init(id: "woodblock", label: "Woodblock", cat: "Percussion"),
        .init(id: "block", label: "Block", cat: "Percussion"),
        .init(id: "triangle", label: "Triangle", cat: "Percussion"),
        .init(id: "shaker", label: "Shaker", cat: "Percussion"),
        .init(id: "perc", label: "Perc", cat: "Percussion"),
        .init(id: "fx", label: "FX Sweep", cat: "FX / Synth"),
        .init(id: "zap", label: "Zap", cat: "FX / Synth"),
        .init(id: "laser", label: "Laser", cat: "FX / Synth"),
        .init(id: "noise", label: "Noise", cat: "FX / Synth"),
        .init(id: "click", label: "Click", cat: "FX / Synth"),
    ]
    static let drumSoundCats: [String] = ["Kick / Bass", "Snare / Clap", "Hats / Cymbals", "Toms", "Percussion", "FX / Synth"]
    static func soundLabel(_ id: String) -> String { drumSounds.first { $0.id == id }?.label ?? id }

    // Mixer-bus routing for the expanded sounds (the originals are covered by `padChannel`).
    static let soundChannel: [String: String] = [
        "punchKick": "drums", "deepKick": "bass", "tom808": "bass",
        "tightSnare": "drums", "snap": "drums", "rimshot": "drums",
        "ride": "hats", "tamb": "hats",
        "cowbell": "perc", "bongo": "perc", "clave": "perc", "woodblock": "perc",
        "block": "perc", "triangle": "perc",
        "zap": "fx", "laser": "fx", "noise": "fx",
    ]

    // MARK: Drum kits — remap all 16 pads to curated sounds via the per-pad sound override.
    // `sounds` lists only the pads that DIFFER from their default; unlisted pads revert to default.
    struct DrumKitPreset: Identifiable { let id: String; let name: String; let desc: String; let sounds: [String: String] }
    static let drumKits: [DrumKitPreset] = [
        DrumKitPreset(id: "classic", name: "FD Classic", desc: "The original 808 voices", sounds: [:]),
        DrumKitPreset(id: "trap", name: "Trap", desc: "Punchy kick, 808 toms, snaps", sounds: [
            "kick": "punchKick", "rim": "rimshot",
            "lowTom": "tom808", "midTom": "tom808", "hiTom": "tom808",
            "perc": "snap", "fx": "zap",
        ]),
        DrumKitPreset(id: "house", name: "House", desc: "Four-on-the-floor & claps", sounds: [
            "sub808": "deepKick", "snare": "clap", "perc": "tamb", "crash": "ride",
        ]),
        DrumKitPreset(id: "lofi", name: "Lo-Fi", desc: "Dusty, soft & mellow", sounds: [
            "kick": "deepKick", "snare": "tightSnare", "clap": "snap",
            "cowbell": "woodblock", "crash": "ride", "conga": "bongo", "perc": "noise", "fx": "noise",
        ]),
        DrumKitPreset(id: "acoustic", name: "Acoustic", desc: "Hand drums & live feel", sounds: [
            "sub808": "deepKick", "clap": "snap", "perc": "bongo", "fx": "woodblock",
        ]),
        DrumKitPreset(id: "electro", name: "Electro", desc: "Synthetic & FM textures", sounds: [
            "kick": "punchKick", "snare": "tightSnare", "rim": "rimshot",
            "lowTom": "tom808", "midTom": "tom808", "hiTom": "tom808",
            "cowbell": "clave", "conga": "clave", "perc": "zap", "fx": "laser",
        ]),
        DrumKitPreset(id: "perclab", name: "Perc Lab", desc: "All-percussion playground", sounds: [
            "kick": "conga", "sub808": "bongo", "snare": "clave", "clap": "woodblock",
            "hatClosed": "shaker", "hatOpen": "tamb", "rim": "block",
            "lowTom": "bongo", "midTom": "conga", "hiTom": "block",
            "crash": "triangle", "perc": "tamb", "fx": "triangle",
        ]),
    ]

    // MARK: Patterns

    struct LeadHit { let step: Int; let padID: String }
    struct Pattern: Identifiable {
        let id: String
        let name: String
        let vibe: String
        let bpm: Int
        let difficulty: Int
        let lead: [LeadHit]
        let steps: [[String]]   // 16 cells, each a list of pad ids
    }

    static func fromLanes(_ lanes: [String: [Int]]) -> [[String]] {
        var steps = Array(repeating: [String](), count: 16)
        for (padID, idxs) in lanes {
            for s in idxs where !steps[s].contains(padID) { steps[s].append(padID) }
        }
        return steps
    }

    static let patterns: [Pattern] = [
        Pattern(id: "boombap", name: "Boom Bap", vibe: "Classic head-nod hip-hop", bpm: 86, difficulty: 1,
                lead: [LeadHit(step: 0, padID: "kick"), LeadHit(step: 4, padID: "snare"),
                       LeadHit(step: 8, padID: "kick"), LeadHit(step: 12, padID: "snare")],
                steps: fromLanes(["kick": [0, 6, 8, 14], "snare": [4, 12],
                                  "hatClosed": [0, 2, 4, 6, 8, 10, 12, 14]])),
        Pattern(id: "house", name: "Four on the Floor", vibe: "Dancefloor house groove", bpm: 122, difficulty: 2,
                lead: [LeadHit(step: 0, padID: "kick"), LeadHit(step: 4, padID: "kick"),
                       LeadHit(step: 8, padID: "kick"), LeadHit(step: 12, padID: "kick"),
                       LeadHit(step: 4, padID: "clap"), LeadHit(step: 12, padID: "clap")],
                steps: fromLanes(["kick": [0, 4, 8, 12], "clap": [4, 12],
                                  "hatOpen": [2, 6, 10, 14],
                                  "hatClosed": [0, 1, 3, 5, 7, 9, 11, 13, 15]])),
        Pattern(id: "trap", name: "Trap Bounce", vibe: "Modern 808 trap", bpm: 138, difficulty: 3,
                lead: [LeadHit(step: 0, padID: "sub808"), LeadHit(step: 7, padID: "sub808"),
                       LeadHit(step: 10, padID: "sub808"), LeadHit(step: 4, padID: "clap"),
                       LeadHit(step: 12, padID: "clap")],
                steps: fromLanes(["sub808": [0, 7, 10], "kick": [0, 8], "clap": [4, 12],
                                  "hatClosed": [0, 2, 4, 6, 8, 10, 12, 14, 15]])),
    ]
    static func pattern(_ id: String) -> Pattern? { patterns.first { $0.id == id } }

    // MARK: Lessons

    struct Lesson: Identifiable {
        let id: String; let n: Int; let title: String; let sub: String
        let mins: Int; let skill: String; let patternID: String?
        let locked: Bool; let done: Bool
    }
    static let lessons: [Lesson] = [
        Lesson(id: "l1", n: 1, title: "Meet the Pads", sub: "Tap and explore your kit", mins: 3, skill: "Basics", patternID: nil, locked: false, done: true),
        Lesson(id: "l2", n: 2, title: "The Steady Beat", sub: "Keep time with the kick & snare", mins: 4, skill: "Timing", patternID: "boombap", locked: false, done: true),
        Lesson(id: "l3", n: 3, title: "Boom Bap Groove", sub: "Your first full beat", mins: 5, skill: "Grooves", patternID: "boombap", locked: false, done: false),
        Lesson(id: "l4", n: 4, title: "Four on the Floor", sub: "Make people dance", mins: 5, skill: "Grooves", patternID: "house", locked: false, done: false),
        Lesson(id: "l5", n: 5, title: "808 Trap Bounce", sub: "Ride the sub-bass", mins: 6, skill: "808s", patternID: "trap", locked: true, done: false),
        Lesson(id: "l6", n: 6, title: "Add the Swing", sub: "Loosen the grid for groove", mins: 5, skill: "Feel", patternID: "boombap", locked: true, done: false),
        Lesson(id: "l7", n: 7, title: "Layer the Clap", sub: "Stack snare + clap for power", mins: 5, skill: "Layering", patternID: "house", locked: true, done: false),
        Lesson(id: "l8", n: 8, title: "808 Glides", sub: "Slide the sub between notes", mins: 6, skill: "808s", patternID: "trap", locked: true, done: false),
        Lesson(id: "l9", n: 9, title: "Build a Song", sub: "Intro · verse · hook · outro", mins: 8, skill: "Arrange", patternID: nil, locked: true, done: false),
        Lesson(id: "l10", n: 10, title: "Build Your Own", sub: "Freestyle & record", mins: 6, skill: "Create", patternID: nil, locked: true, done: false),
    ]

    // MARK: Mixer channels (pads grouped into mixable buses)

    struct Channel: Identifiable { let id: String; let name: String; let color: Color; let pads: [String] }
    static let channels: [Channel] = [
        Channel(id: "drums", name: "Drums", color: Color(hex: "#FF5A3C"), pads: ["kick", "snare", "clap", "rim", "lowTom", "midTom", "hiTom"]),
        Channel(id: "hats",  name: "Hats",  color: Color(hex: "#33E0D4"), pads: ["hatClosed", "hatOpen"]),
        Channel(id: "perc",  name: "Perc",  color: Color(hex: "#C77DFF"), pads: ["cowbell", "conga", "perc", "shaker", "crash"]),
        Channel(id: "bass",  name: "808",   color: Color(hex: "#FF7A1A"), pads: ["sub808"]),
        Channel(id: "fx",    name: "FX",    color: Color(hex: "#9B8CFF"), pads: ["fx"]),
    ]
    static let padChannel: [String: String] = {
        var m: [String: String] = [:]
        for c in channels { for p in c.pads { m[p] = c.id } }
        return m
    }()
    static func channelOf(_ id: String) -> String { let b = baseID(id); return padChannel[b] ?? soundChannel[b] ?? soundChannel[id] ?? "drums" }
    /// The mixer channel's accent color — one source of truth so clip/track tints can't drift from it.
    static func channelColor(_ id: String) -> Color { channels.first { $0.id == id }?.color ?? .gray }

    // Which arrangement track (Track Mode) each pad belongs to — lets the Tracks
    // tab's mute/solo gate playback. ("vox" carries audio/vocal clips, no pads.)
    static let padTrack: [String: String] = {
        var m: [String: String] = [:]
        let tracks: [String: [String]] = [
            "drums": ["kick", "snare", "clap", "rim", "lowTom", "midTom", "hiTom"],
            "hats":  ["hatClosed", "hatOpen"],
            "bass":  ["sub808"],
            "perc":  ["cowbell", "conga", "perc", "shaker", "crash", "fx"],
        ]
        for (t, pads) in tracks { for p in pads { m[p] = t } }
        return m
    }()
    static func trackOf(_ id: String) -> String { padTrack[baseID(id)] ?? "drums" }

    // MARK: Pad banks

    struct Bank { let name: String; let pads: [PadDef] }
    static let bankOrder = ["A", "B", "C", "D"]
    static let banks: [String: Bank] = [
        "A": Bank(name: "Studio Kit", pads: pads),
        "B": Bank(name: "Perc Lab", pads: relabel(pads, bank: "B", [
            "kick": ("DEEP", "#FF5A3C"), "sub808": ("SUB", "#FF7A1A"), "snare": ("RIM SN", "#FFC23C"), "clap": ("SNAP", "#FFD84D"),
            "hatClosed": ("TICK", "#33E0D4"), "hatOpen": ("SIZZLE", "#27C2E8"), "rim": ("CLICK", "#7AE582"), "cowbell": ("BLOCK", "#B6E84D"),
            "lowTom": ("TABLA", "#4DD07A"), "midTom": ("DARB", "#46C9A8"), "hiTom": ("BONGO", "#5BD6C0"), "crash": ("SPLASH", "#5B8DEF"),
            "conga": ("CONGA", "#C77DFF"), "perc": ("AGOGO", "#E879F9"), "shaker": ("CABASA", "#FF7AC6"), "fx": ("ZAP", "#9B8CFF"),
        ])),
        "C": Bank(name: "Chops", pads: relabel(pads, bank: "C", [:], prefix: "SLICE")),
        "D": Bank(name: "Custom", pads: relabel(pads, bank: "D", [:], prefix: "PAD")),
    ]

    /// A bank's pads: the base pads under a bank-scoped id (see `slotKey`), relabelled. The VOICE
    /// (`sound`) is kept, so an untouched Bank B/C/D pad still sounds like its Bank A counterpart.
    static func relabel(_ base: [PadDef], bank: String, _ map: [String: (String, String)], prefix: String? = nil) -> [PadDef] {
        base.enumerated().map { (i, p) in
            // Banks C (chops) and D (synth) hold the user's own audio, so they must not inherit the kit's
            // family choke — slices 5 and 6 are arbitrary chops, not an open/closed hat pair that should
            // cut each other.
            let choke = (bank == "C" || bank == "D") ? 0 : p.defaultChoke
            var o = PadDef(id: slotKey(bank: bank, pad: p.id), label: p.label, sound: p.sound, family: p.family,
                           color: p.color, key: p.key, index: p.index, defaultChoke: choke)
            if let m = map[p.id] { o.label = m.0; o.color = Color(hex: m.1) }
            else if let pre = prefix { o.label = "\(pre) \(i + 1)" }
            return o
        }
    }

    // MARK: Song sections

    struct Section: Identifiable { let id: String; let name: String; let color: Color }
    static let sections: [Section] = [
        Section(id: "intro",  name: "Intro",  color: Color(hex: "#5B8DEF")),
        Section(id: "verse",  name: "Verse",  color: Color(hex: "#33E0D4")),
        Section(id: "hook",   name: "Hook",   color: Color(hex: "#FF6A2B")),
        Section(id: "bridge", name: "Bridge", color: Color(hex: "#C77DFF")),
        Section(id: "outro",  name: "Outro",  color: Color(hex: "#FFC23C")),
    ]
    static func section(_ id: String) -> Section? { sections.first { $0.id == id } }

    // Convert a 16-step pattern into per-pad velocity lanes.
    static func lanesFromSteps(_ steps: [[String]]) -> [String: [Double]] {
        var lanes: [String: [Double]] = [:]
        for (s, cell) in steps.enumerated() {
            for padID in cell {
                if lanes[padID] == nil { lanes[padID] = Array(repeating: 0, count: 16) }
                lanes[padID]?[s] = (padID == "kick" || padID == "snare") ? 1.0 : 0.8
            }
        }
        return lanes
    }
    static func emptyLane() -> [Double] { Array(repeating: 0, count: 16) }
}
