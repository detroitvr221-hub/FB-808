//  Track.swift — first-class arrangement tracks (the "99 layered tracks" foundation).
//
//  The six legacy lanes (drums/hats/bass/perc/vox/audio) become six seeded `Track`s so old
//  projects load and play exactly as before — they keep reading the live Project.lanes/melody
//  via Transport's existing paths. NEW tracks created by "Add Track" or the send-to-track
//  actions carry a FROZEN capture of content (lanes for drums, notes+patch for synths) and are
//  played by an additive Transport pass, gated by the same mute/solo/clip rules. This lets the
//  user stack many independent, arrangeable layers without touching the existing playback graph.

import SwiftUI
import FD808Engine

enum TrackType: String, Codable {
    case drumPattern   // plays a set of pad lanes (live for the 4 seeded drum tracks; frozen for new ones)
    case synthPart     // plays a melody/part through a SynthPatch (live "lead" for vox; frozen for promoted)
    case sampler       // reserved (Phase 5)
    case audio         // plays recorded/imported AudioClip buffers
    case bus           // reserved (Phase 6 group bus)

    var label: String {
        switch self {
        case .drumPattern: return "Drum Program"
        case .synthPart:   return "Synth Line"
        case .sampler:     return "Sampler"
        case .audio:       return "Mic / Import"
        case .bus:         return "Group Bus"
        }
    }
    var glyph: String {
        switch self {
        case .drumPattern: return "square.grid.2x2.fill"
        case .synthPart:   return "pianokeys"
        case .sampler:     return "waveform"
        case .audio:       return "mic.fill"
        case .bus:         return "rectangle.3.group.fill"
        }
    }
}

/// What musical element a LIVE-LINKED track points at. The track owns no content; Transport/Export
/// dereference this at play time, so editing the source updates the track everywhere it's used.
/// (SYSTEM_AUDIT.md Step 1 — the single `LinkRef` both the local and future remote layers consume.)
enum LinkKind: String, Codable {
    case lanes            // live Project.lanes, filtered to `rows`
    case melody           // live Project.melody + synthPatch (the lead)
    case part             // live parts[partID].notes + .patch (or lead when partID == "lead")
    case sequenceLanes    // sequences[seqIndex].lanes (Song-Mode bank) — Step 3
    case sequenceMelody   // sequences[seqIndex].melody — Step 3
}

struct LinkRef: Codable, Equatable {
    var kind: LinkKind
    var rows: [String]? = nil       // which pad rows a drum track shows (subset of lanes)
    var partID: String? = nil       // "lead" → melody/synthPatch; else parts[].id
    var seqIndex: Int? = nil        // for sequenceLanes / sequenceMelody
}

/// What a track plays. Only the fields meaningful for the track's `type` are used.
/// A LIVE-LINKED track carries a `link` and no copy (edits to the source flow through); a FROZEN
/// track carries its own captured `lanes`/`notes` (an independent copy); a LIVE legacy seeded track
/// has neither and is played by Transport's classic paths.
struct TrackSource: Codable {
    var padRows: [String] = []                 // drumPattern: informational / future routing
    var partID: String? = nil                  // synthPart: "lead" or a parts[].id (legacy "vox" only)
    var link: LinkRef? = nil                   // LIVE-LINK reference (new default for created tracks)
    var lanes: [String: [Double]]? = nil       // drumPattern FROZEN capture (detached copy)
    var notes: [MelodyNote]? = nil             // synthPart FROZEN capture (detached copy)
    var patch: SynthPatch? = nil               // synthPart FROZEN patch (detached copy)
    var samplePad: String? = nil               // sampler (reserved)

    init(padRows: [String] = [], partID: String? = nil, link: LinkRef? = nil,
         lanes: [String: [Double]]? = nil, notes: [MelodyNote]? = nil,
         patch: SynthPatch? = nil, samplePad: String? = nil) {
        self.padRows = padRows; self.partID = partID; self.link = link
        self.lanes = lanes; self.notes = notes; self.patch = patch; self.samplePad = samplePad
    }
    enum CodingKeys: String, CodingKey { case padRows, partID, link, lanes, notes, patch, samplePad }
    init(from d: Decoder) throws {                 // tolerant — every field optional so old/new saves coexist
        let c = try d.container(keyedBy: CodingKeys.self)
        padRows   = (try? c.decodeIfPresent([String].self, forKey: .padRows)) ?? []
        partID    = try? c.decodeIfPresent(String.self, forKey: .partID)
        link      = try? c.decodeIfPresent(LinkRef.self, forKey: .link)   // nil for old saves → frozen, as before
        lanes     = try? c.decodeIfPresent([String: [Double]].self, forKey: .lanes)
        notes     = try? c.decodeIfPresent([MelodyNote].self, forKey: .notes)
        patch     = try? c.decodeIfPresent(SynthPatch.self, forKey: .patch)
        samplePad = try? c.decodeIfPresent(String.self, forKey: .samplePad)
    }
}

struct Track: Identifiable, Codable {
    var id: String                  // legacy ids ("drums"/"hats"/…) so old clips/mixer keys resolve
    var name: String
    var type: TrackType
    var source: TrackSource = .init()
    var colorHex: String
    var vol: Double = AudioDefaults.unityGain
    var pan: Double = 0
    var height: CGFloat = 64
    var ownsBus: Bool = false        // G3: the track has its own DSP insert-FX strip (channelFX[id])
    var busParent: String? = nil     // G3.4: route this track's voices into a `.bus` group track's strip
    var frozenToAudio: Bool = false  // bus-freeze: live synthesis is bounced to an AudioClip (this track plays it instead)

    var color: Color { Color(hex: colorHex) }
    /// A LIVE-LINKED track references its source and is resolved live by the additive pass; editing
    /// the source updates it. `link` is the authority — Freeze captures a copy and clears the link.
    var isLinked: Bool { source.link != nil && !frozenToAudio }
    /// A frozen track owns its own captured content (played by Transport's additive pass);
    /// a live legacy track does not (played by the classic drum/melody paths). Unchanged meaning.
    var isFrozen: Bool { source.lanes != nil || source.notes != nil }
    /// True for any non-seeded track the additive pass must play (linked OR frozen, not baked-to-audio).
    var playsAdditively: Bool { (isLinked || isFrozen) && !frozenToAudio }

    init(id: String, name: String, type: TrackType, source: TrackSource = .init(),
         colorHex: String, vol: Double = AudioDefaults.unityGain, pan: Double = 0, height: CGFloat = 64) {
        self.id = id; self.name = name; self.type = type; self.source = source
        self.colorHex = colorHex; self.vol = vol; self.pan = pan; self.height = height
    }
    enum CodingKeys: String, CodingKey { case id, name, type, source, colorHex, vol, pan, height, ownsBus, busParent, frozenToAudio }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(TrackType.self, forKey: .type)) ?? .drumPattern
        source = (try? c.decodeIfPresent(TrackSource.self, forKey: .source)) ?? TrackSource()
        colorHex = (try? c.decode(String.self, forKey: .colorHex)) ?? "#8A8F98"
        vol = (try? c.decode(Double.self, forKey: .vol)) ?? AudioDefaults.unityGain
        pan = (try? c.decode(Double.self, forKey: .pan)) ?? 0
        height = (try? c.decode(CGFloat.self, forKey: .height)) ?? 64
        ownsBus = (try? c.decode(Bool.self, forKey: .ownsBus)) ?? false
        busParent = try? c.decodeIfPresent(String.self, forKey: .busParent)
        frozenToAudio = (try? c.decode(Bool.self, forKey: .frozenToAudio)) ?? false
    }

    // Distinct colors for new tracks; cycles as the list grows.
    static let palette: [String] = [
        "#FF5A3C", "#33E0D4", "#FF7A1A", "#C77DFF", "#E879F9", "#5BD6C0",
        "#5B8DEF", "#FFC23C", "#7AE582", "#FF7AC6", "#9B8CFF", "#46C9A8",
    ]
}

extension Project {

    static let maxTracks = 99
    /// Per-pad drive into the mix bus. Kept a touch below the old hard-coded 1.3 so the master safety
    /// limiter has headroom and only engages on genuine stacks (not on every moderate hit). Shared by
    /// live playback (Transport) and bounces (Export) so they stay level-matched.
    static let padDrive = 1.15

    /// The default six-track layout, reproducing today's fixed arrangement exactly.
    /// Drum tracks own their pad rows (inverted from Kit.padTrack); "vox" is the live Lead synth line.
    static func seedTracks() -> [Track] {
        var rows: [String: [String]] = [:]
        for (pad, tk) in Kit.padTrack { rows[tk, default: []].append(pad) }
        return [
            Track(id: "drums", name: "Drums",  type: .drumPattern, source: .init(padRows: rows["drums"] ?? []), colorHex: "#FF5A3C"),
            Track(id: "hats",  name: "Hats",   type: .drumPattern, source: .init(padRows: rows["hats"] ?? []),  colorHex: "#33E0D4"),
            Track(id: "bass",  name: "808",    type: .drumPattern, source: .init(padRows: rows["bass"] ?? []),  colorHex: "#FF7A1A"),
            Track(id: "perc",  name: "Perc",   type: .drumPattern, source: .init(padRows: rows["perc"] ?? []),  colorHex: "#C77DFF"),
            Track(id: "vox",   name: "Melody", type: .synthPart,   source: .init(partID: "lead"),               colorHex: "#E879F9"),
            Track(id: "audio", name: "Audio",  type: .audio,                                                    colorHex: "#5BD6C0"),
        ]
    }

    private func freshTrackID(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8))" }
    private func nextColor() -> String { Track.palette[tracks.count % Track.palette.count] }
    /// Unique "<Base> N" name across existing tracks.
    private func uniqueTrackName(_ base: String) -> String {
        var n = tracks.filter { $0.name.hasPrefix(base) }.count + 1
        var name = "\(base) \(n)"
        while tracks.contains(where: { $0.name == name }) { n += 1; name = "\(base) \(n)" }
        return name
    }

    // MARK: add / remove / edit

    /// Append an empty track of `type`. Returns its id, or "" if at the 99 cap.
    @discardableResult
    func addTrack(_ type: TrackType) -> String {
        guard tracks.count < Project.maxTracks else { return "" }
        checkpoint("addtrack", coalesce: false)
        let id = freshTrackID(type.rawValue)
        let color = nextColor()
        var src = TrackSource()
        let name: String
        switch type {
        case .drumPattern: name = uniqueTrackName("Drums");  src.lanes = [:]                 // empty frozen lanes → frozen, editable later
        case .synthPart:   name = uniqueTrackName("Synth");  src.notes = []; src.patch = SynthPresets.default
        case .sampler:     name = uniqueTrackName("Sampler")
        case .audio:       name = uniqueTrackName("Audio")
        case .bus:         name = uniqueTrackName("Bus")
        }
        tracks.append(Track(id: id, name: name, type: type, source: src, colorHex: color))
        if type == .bus { pushChannelFX() }   // a group bus owns a DSP strip → grow the engine pool
        return id
    }

    func removeTrack(_ id: String) {
        guard tracks.contains(where: { $0.id == id }) else { return }
        checkpoint("rmtrack", coalesce: false)
        tracks.removeAll { $0.id == id }
        clips[id] = nil
        trackMute[id] = nil
        trackSolo[id] = nil
        audioClips.removeAll { $0.track == id }
        if audioArmedTrack == id { audioArmedTrack = nil }
    }

    /// Reorder a track one slot up or down (drives Move Up / Move Down in the track menu).
    func moveTrack(_ id: String, up: Bool) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let j = up ? i - 1 : i + 1
        guard tracks.indices.contains(j) else { return }
        checkpoint("movetrack", coalesce: false)
        tracks.swapAt(i, j)
    }
    /// True when a track can move in the given direction (for enabling/disabling the menu items).
    func canMoveTrack(_ id: String, up: Bool) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return false }
        return tracks.indices.contains(up ? i - 1 : i + 1)
    }

    func renameTrack(_ id: String, _ name: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        checkpoint("renametrack", coalesce: false)
        tracks[i].name = String(trimmed.prefix(20))
    }

    func setTrackColor(_ id: String, _ hex: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("trackcolor", coalesce: false)
        tracks[i].colorHex = hex
    }

    func setTrackVol(_ id: String, _ v: Double) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("trackvol:\(id)", coalesce: true)   // undoable + marks dirty so a fader move autosaves
        tracks[i].vol = max(0, min(1.4, v))
    }
    func setTrackPan(_ id: String, _ p: Double) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("trackpan:\(id)", coalesce: true)
        tracks[i].pan = max(-1, min(1, p))
    }
    func toggleTrackMute(_ id: String) {
        checkpoint("trackmute:\(id)", coalesce: false)
        trackMute[id] = !(trackMute[id] ?? false)
    }
    func toggleTrackSolo(_ id: String) {
        checkpoint("tracksolo:\(id)", coalesce: false)
        trackSolo[id] = !(trackSolo[id] ?? false)
    }

    /// Toggle whether a track owns its own DSP insert-FX bus (G3). Resizes the engine bus pool.
    func toggleTrackBus(_ id: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("trackbus:\(id)", coalesce: false)
        tracks[i].ownsBus.toggle()
        if !tracks[i].ownsBus { channelFX[id] = nil }   // dropping the bus clears its inserts
        pushChannelFX()
    }
    /// Route a track's voices into a `.bus` group track's shared insert-FX strip (G3.4); nil = no group.
    func setTrackBusParent(_ id: String, _ parent: String?) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("busparent:\(id)", coalesce: false)
        tracks[i].busParent = (parent == id) ? nil : parent   // never self-route
    }
    /// The `.bus` group tracks, for the "Route to Bus" picker.
    var busTracks: [Track] { tracks.filter { $0.type == .bus } }

    // MARK: bus-freeze (render a heavy track to one audio voice)

    /// Bounce a frozen drum/synth track's content to an AudioClip on itself; live synthesis is then
    /// skipped (plays the clip → one voice instead of N). Best in Song Mode (renders the arrangement).
    @discardableResult
    func freezeTrack(_ id: String) async -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }),
              (tracks[i].isFrozen || tracks[i].isLinked), !tracks[i].frozenToAudio else { return false }
        let plan = buildSoloTrackPlan(tracks[i])   // resolves the link to live content if linked
        guard !plan.drums.isEmpty || !plan.synths.isEmpty else { return false }
        isBouncing = true; defer { isBouncing = false }
        let (l, r) = await Task.detached { renderOffline(plan) }.value   // off the main actor so the UI stays live (#ARCH-01)
        guard !l.isEmpty else { return false }
        var mono = [Float](repeating: 0, count: l.count)
        for k in 0..<l.count { mono[k] = (l[k] + r[k]) * 0.5 }
        addAudioClip(track: id, startBar: 0, data: mono, name: "\(tracks[i].name) (frozen)")   // checkpoints pre-state
        tracks[i].frozenToAudio = true
        return true
    }
    func unfreezeTrack(_ id: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].frozenToAudio else { return }
        if let clip = audioClips.first(where: { $0.track == id }) { removeAudioClip(clip.id) }   // checkpoints
        tracks[i].frozenToAudio = false
    }

    // MARK: link ⇄ freeze (Step 2 — detach a live-linked track into an independent copy, or re-link)

    /// FREEZE: capture a live-linked track's current resolved content into an independent copy and
    /// clear the link. The track stops following the source (DAW-style "freeze"). Undoable.
    @discardableResult
    func freezeLinkToCopy(_ id: String) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].isLinked,
              let link = tracks[i].source.link else { return false }
        // Resolve BEFORE mutating. If the source is gone (e.g. its part was deleted), abort with the link
        // intact rather than baking an empty, unrecoverable "frozen" zombie (#review).
        switch tracks[i].type {
        case .drumPattern:
            guard let lanesCopy = resolvedLanes(link, atBar: 0) else { return false }
            checkpoint("freezeLink:\(id)", coalesce: false)
            tracks[i].source.lanes = lanesCopy
            tracks[i].source.notes = nil; tracks[i].source.patch = nil
        case .synthPart:
            guard let (notes, patch) = resolvedNotes(link, atBar: 0) else { return false }
            checkpoint("freezeLink:\(id)", coalesce: false)
            tracks[i].source.notes = notes; tracks[i].source.patch = patch
            tracks[i].source.lanes = nil
        default:
            return false
        }
        tracks[i].source.link = nil
        return true
    }

    /// RE-LINK: reconnect a frozen copy to its live source (drum lanes by its rows, or its part),
    /// discarding the independent copy so edits to the source flow again. Undoable.
    @discardableResult
    func relinkTrack(_ id: String) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].isFrozen,
              !tracks[i].frozenToAudio else { return false }
        checkpoint("relink:\(id)", coalesce: false)
        switch tracks[i].type {
        case .drumPattern:
            let rows = tracks[i].source.padRows.isEmpty
                ? Array((tracks[i].source.lanes ?? [:]).keys) : tracks[i].source.padRows
            tracks[i].source.link = LinkRef(kind: .lanes, rows: rows)
            tracks[i].source.lanes = nil
        case .synthPart:
            tracks[i].source.link = LinkRef(kind: .part, partID: tracks[i].source.partID ?? "lead")
            tracks[i].source.notes = nil; tracks[i].source.patch = nil
        default: return false
        }
        return true
    }


    // MARK: routing workflows (the cohesion goals)

    /// Send the live drum lanes (rows that have any hit, or a chosen subset) to a NEW LIVE-LINKED
    /// drumPattern track + a clip on the timeline. Goal #1: pad take → step grid → its own track.
    /// The track REFERENCES the live lanes (filtered to `picked` rows) — editing the pattern in
    /// Pads/Sequence updates this track everywhere it plays. Freeze it later to detach a copy.
    @discardableResult
    func sendLanesToNewTrack(rows: [String]? = nil, name: String? = nil,
                             startBar: Int = 0, lenBars: Int = 2) -> String {
        guard tracks.count < Project.maxTracks else { return "" }
        let picked = rows ?? lanes.compactMap { (pad, lane) in lane.contains { $0 != 0 } ? pad : nil }
        guard !picked.isEmpty else { return "" }
        checkpoint("padToTrack", coalesce: false)
        let id = freshTrackID("drum")
        let color = nextColor()
        let link = LinkRef(kind: .lanes, rows: picked)   // LIVE-LINK to the source pattern
        tracks.append(Track(id: id, name: name ?? uniqueTrackName("Pad Take"),
                            type: .drumPattern, source: .init(padRows: picked, link: link), colorHex: color))
        clips[id, default: []].append(Clip(s: max(0, min(songBars - 1, startBar)),
                                           l: max(1, min(songBars, lenBars)), color: Color(hex: color)))
        return id
    }

    /// Promote a synth part (Lead or an extra part) into its OWN LIVE-LINKED synthPart track + a clip.
    /// Goal #2: piano-roll melody → its own independently-arrangeable track. The track REFERENCES the
    /// live part (notes + patch) — editing the melody/part updates it. Freeze it later to detach.
    @discardableResult
    func promotePartToTrack(_ partID: String, name: String? = nil,
                            startBar: Int = 0, lenBars: Int = 4) -> String {
        guard tracks.count < Project.maxTracks else { return "" }
        let patch: SynthPatch
        let baseName: String
        let hasNotes: Bool
        if partID == "lead" {
            patch = synthPatch; baseName = "Lead"; hasNotes = !melody.isEmpty
        } else if let p = parts.first(where: { $0.id == partID }) {
            patch = p.patch; baseName = p.name; hasNotes = !p.notes.isEmpty
        } else { return "" }
        guard hasNotes else { return "" }
        checkpoint("partToTrack", coalesce: false)
        let id = freshTrackID("synth")
        let color = patch.color.toHex()
        let link = LinkRef(kind: .part, partID: partID)   // LIVE-LINK to the source part
        tracks.append(Track(id: id, name: name ?? uniqueTrackName(baseName),
                            type: .synthPart, source: .init(partID: partID, link: link), colorHex: color))
        clips[id, default: []].append(Clip(s: max(0, min(songBars - 1, startBar)),
                                           l: max(1, min(songBars, lenBars)), color: Color(hex: color)))
        return id
    }

    // MARK: live-link resolution (the heart of Step 1 — dereference a link to LIVE content)

    /// Resolve a drum link to the live lanes it points at (filtered to its rows). Returns nil for
    /// non-drum kinds. Call ONCE PER BAR (not per step) — the additive scheduler hoists this.
    func resolvedLanes(_ link: LinkRef, atBar bar: Int) -> [String: [Double]]? {
        switch link.kind {
        case .lanes:
            // In Song Mode resolve through the bar's arranged sequence so a linked track mirrors the same
            // per-bar pattern the seeded drums play (lanesForBar returns the live buffer for active-seq bars,
            // so single-sequence / non-song projects are unaffected). (#review)
            let src = songMode ? lanesForBar(bar) : lanes
            guard let rows = link.rows else { return src }
            return src.filter { rows.contains($0.key) }
        case .sequenceLanes:
            guard let si = link.seqIndex, sequences.indices.contains(si) else { return nil }
            let src = sequences[si].lanes
            guard let rows = link.rows else { return src }
            return src.filter { rows.contains($0.key) }
        default: return nil
        }
    }
    /// Resolve a melody/part link to the live notes + patch it points at. Returns nil for non-synth kinds.
    func resolvedNotes(_ link: LinkRef, atBar bar: Int) -> (notes: [MelodyNote], patch: SynthPatch)? {
        switch link.kind {
        case .melody:
            return (songMode ? melodyForBar(bar) : melody, synthPatch)
        case .part:
            if link.partID == nil || link.partID == "lead" { return (songMode ? melodyForBar(bar) : melody, synthPatch) }
            let pool = songMode ? partsForBar(bar) : parts
            guard let p = pool.first(where: { $0.id == link.partID }) else { return nil }
            return (p.notes, p.patch)
        case .sequenceMelody:
            guard let si = link.seqIndex, sequences.indices.contains(si) else { return nil }
            return (sequences[si].melody, synthPatch)
        default: return nil
        }
    }
    /// Effective lanes for an additively-played drum track (link-resolved if linked, else the frozen copy).
    func trackLanes(_ track: Track, atBar bar: Int) -> [String: [Double]]? {
        track.isLinked ? (track.source.link.flatMap { resolvedLanes($0, atBar: bar) }) : track.source.lanes
    }
    /// Effective notes+patch for an additively-played synth track (link-resolved if linked, else frozen).
    func trackNotes(_ track: Track, atBar bar: Int) -> (notes: [MelodyNote], patch: SynthPatch)? {
        if track.isLinked { return track.source.link.flatMap { resolvedNotes($0, atBar: bar) } }
        if let n = track.source.notes, let p = track.source.patch { return (n, p) }
        return nil
    }
    /// Live per-step probability/condition/p-locks for a LINKED drum track's pad, from the same source
    /// as its lanes — so a linked track keeps the authored stepMeta the live grid has (Step 3). Frozen
    /// copies have no stepMeta (a captured snapshot never carried it).
    func trackStepMeta(_ track: Track, _ pad: String, _ step: Int, atBar bar: Int) -> StepMeta? {
        guard track.isLinked, let link = track.source.link else { return nil }
        switch link.kind {
        case .lanes:         return (songMode ? stepMetaForBar(bar) : stepMeta)[pad]?[step]
        case .sequenceLanes: return link.seqIndex.flatMap { sequences.indices.contains($0) ? sequences[$0].stepMeta[pad]?[step] : nil }
        default:             return nil
        }
    }
}
