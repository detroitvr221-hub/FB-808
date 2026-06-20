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

/// What a track plays. Only the fields meaningful for the track's `type` are used.
/// A FROZEN track (created by Add Track / send-to-track) carries its own captured content;
/// a LIVE legacy track leaves the frozen fields nil and is played by Transport's classic paths.
struct TrackSource: Codable {
    var padRows: [String] = []                 // drumPattern: informational / future routing
    var partID: String? = nil                  // synthPart: "lead" or a parts[].id (legacy "vox" only)
    var lanes: [String: [Double]]? = nil       // drumPattern FROZEN capture (new tracks)
    var notes: [MelodyNote]? = nil             // synthPart FROZEN capture (new tracks)
    var patch: SynthPatch? = nil               // synthPart FROZEN patch (new tracks)
    var samplePad: String? = nil               // sampler (reserved)

    init(padRows: [String] = [], partID: String? = nil,
         lanes: [String: [Double]]? = nil, notes: [MelodyNote]? = nil,
         patch: SynthPatch? = nil, samplePad: String? = nil) {
        self.padRows = padRows; self.partID = partID
        self.lanes = lanes; self.notes = notes; self.patch = patch; self.samplePad = samplePad
    }
    enum CodingKeys: String, CodingKey { case padRows, partID, lanes, notes, patch, samplePad }
    init(from d: Decoder) throws {                 // tolerant — every field optional so old/new saves coexist
        let c = try d.container(keyedBy: CodingKeys.self)
        padRows   = (try? c.decodeIfPresent([String].self, forKey: .padRows)) ?? [] ?? []
        partID    = try? c.decodeIfPresent(String.self, forKey: .partID)
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
    var vol: Double = 0.82
    var pan: Double = 0
    var height: CGFloat = 64
    var ownsBus: Bool = false        // G3: the track has its own DSP insert-FX strip (channelFX[id])
    var busParent: String? = nil     // G3.4: route this track's voices into a `.bus` group track's strip
    var frozenToAudio: Bool = false  // bus-freeze: live synthesis is bounced to an AudioClip (this track plays it instead)

    var color: Color { Color(hex: colorHex) }
    /// A frozen track owns its own captured content (played by Transport's additive pass);
    /// a live legacy track does not (played by the classic drum/melody paths).
    var isFrozen: Bool { source.lanes != nil || source.notes != nil }

    init(id: String, name: String, type: TrackType, source: TrackSource = .init(),
         colorHex: String, vol: Double = 0.82, pan: Double = 0, height: CGFloat = 64) {
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
        vol = (try? c.decode(Double.self, forKey: .vol)) ?? 0.82
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
        tracks[i].vol = max(0, min(1.4, v))
    }
    func setTrackPan(_ id: String, _ p: Double) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
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
    func freezeTrack(_ id: String) -> Bool {
        guard let i = tracks.firstIndex(where: { $0.id == id }),
              tracks[i].isFrozen, !tracks[i].frozenToAudio else { return false }
        let plan = buildSoloTrackPlan(tracks[i])
        guard !plan.drums.isEmpty || !plan.synths.isEmpty else { return false }
        let (l, r) = renderOffline(plan)
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

    func moveTrack(from: Int, to: Int) {
        guard tracks.indices.contains(from), to >= 0, to <= tracks.count, from != to else { return }
        checkpoint("movetrack", coalesce: false)
        let t = tracks.remove(at: from)
        tracks.insert(t, at: min(to, tracks.count))
    }

    // MARK: routing workflows (the cohesion goals)

    /// Capture the live drum lanes (rows that have any hit, or a chosen subset) into a NEW frozen
    /// drumPattern track + a clip on the timeline. This is goal #1: pad take → step grid → its own track.
    @discardableResult
    func sendLanesToNewTrack(rows: [String]? = nil, name: String? = nil,
                             startBar: Int = 0, lenBars: Int = 2) -> String {
        guard tracks.count < Project.maxTracks else { return "" }
        let picked = rows ?? lanes.compactMap { (pad, lane) in lane.contains { $0 != 0 } ? pad : nil }
        guard !picked.isEmpty else { return "" }
        checkpoint("padToTrack", coalesce: false)
        var frozen: [String: [Double]] = [:]
        for pad in picked { if let lane = lanes[pad], lane.contains(where: { $0 != 0 }) { frozen[pad] = lane } }
        guard !frozen.isEmpty else { return "" }
        let id = freshTrackID("drum")
        let color = nextColor()
        tracks.append(Track(id: id, name: name ?? uniqueTrackName("Pad Take"),
                            type: .drumPattern, source: .init(padRows: picked, lanes: frozen), colorHex: color))
        clips[id, default: []].append(Clip(s: max(0, min(songBars - 1, startBar)),
                                           l: max(1, min(songBars, lenBars)), color: Color(hex: color)))
        return id
    }

    /// Promote a synth part (Lead or an extra part) into its OWN frozen synthPart track + a clip.
    /// This is goal #2: piano-roll melody → its own independently-arrangeable track.
    @discardableResult
    func promotePartToTrack(_ partID: String, name: String? = nil,
                            startBar: Int = 0, lenBars: Int = 4) -> String {
        guard tracks.count < Project.maxTracks else { return "" }
        let notes: [MelodyNote]
        let patch: SynthPatch
        let baseName: String
        if partID == "lead" {
            notes = melody; patch = synthPatch; baseName = "Lead"
        } else if let p = parts.first(where: { $0.id == partID }) {
            notes = p.notes; patch = p.patch; baseName = p.name
        } else { return "" }
        guard !notes.isEmpty else { return "" }
        checkpoint("partToTrack", coalesce: false)
        let id = freshTrackID("synth")
        let color = patch.color.toHex()
        tracks.append(Track(id: id, name: name ?? uniqueTrackName(baseName),
                            type: .synthPart, source: .init(notes: notes, patch: patch), colorHex: color))
        clips[id, default: []].append(Clip(s: max(0, min(songBars - 1, startBar)),
                                           l: max(1, min(songBars, lenBars)), color: Color(hex: color)))
        return id
    }
}
