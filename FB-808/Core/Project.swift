//  Project.swift — the shared project store (single source of truth).
//  Ported from project.js. A pattern made in Pad Mode shows up in Sequence Mode,
//  plays through the Mixer, and lands on the Track timeline.

import SwiftUI
import FD808Engine
import Combine

struct MixChannel: Codable, Equatable {   // Equatable → setMix can skip a write that changes nothing (#MIX-UNDO)
    var vol: Double = AudioDefaults.unityGain
    var pan: Double = 0
    var mute: Bool = false
    var solo: Bool = false
    /// Clamp to the fader's range and replace NaN/inf. Applied on restore, on every setMix and on remote
    /// ops: a hand-edited file or a peer sending `vol: 40` was 36× master gain, and `NaN` zeroed every
    /// rendered sample for the rest of the session (SYSTEMS_GAP_AUDIT #cross-2).
    func sanitized() -> MixChannel {
        var c = self
        c.vol = c.vol.isFinite ? max(0, min(AudioDefaults.maxChannelVol, c.vol)) : AudioDefaults.unityGain   // buses stop at 1.1
        c.pan = c.pan.isFinite ? max(-1, min(1, c.pan)) : 0
        return c
    }
}

struct ArrItem: Identifiable, Codable {
    let id: String
    var section: String
    var start: Int
    var len: Int
    var seq: Int = 0          // which sequence plays in this section (Song Mode)
}

// Per-step extras: trigger probability + condition (A9) and parameter locks (A8).
// A step with no entry behaves exactly like a plain velocity hit.
struct StepMeta: Codable, Equatable {
    var prob: Double = 1            // 0..1 chance the step fires (A9)
    var cond: String = ""          // "" | "1:2" | "2:2" | "1:3" | "1:4" | "fill" | "!fill" (A9)
    var pitch: Double? = nil       // p-locks (A8) — override the base pad when set
    var cutoff: Double? = nil
    var decay: Double? = nil
    var pan: Double? = nil

    var isDefault: Bool { prob >= 0.999 && cond.isEmpty && pitch == nil && cutoff == nil && decay == nil && pan == nil }

    init() {}
    enum CodingKeys: String, CodingKey { case prob, cond, pitch, cutoff, decay, pan }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        prob = (try? c.decodeIfPresent(Double.self, forKey: .prob)) ?? 1
        cond = (try? c.decodeIfPresent(String.self, forKey: .cond)) ?? ""
        pitch = (try? c.decodeIfPresent(Double.self, forKey: .pitch)) ?? nil
        cutoff = (try? c.decodeIfPresent(Double.self, forKey: .cutoff)) ?? nil
        decay = (try? c.decodeIfPresent(Double.self, forKey: .decay)) ?? nil
        pan = (try? c.decodeIfPresent(Double.self, forKey: .pan)) ?? nil
    }
}

// A sequence = one beat (drum lanes + synth melody + per-step extras). A project holds several.
struct SeqSlot: Codable {
    var name: String
    var lanes: [String: [Double]]
    var melody: [MelodyNote]
    var stepMeta: [String: [Int: StepMeta]] = [:]
    var parts: [InstrumentPart] = []   // Tier 2 extra instruments, per-sequence (optional → old saves load)

    init(name: String, lanes: [String: [Double]], melody: [MelodyNote], stepMeta: [String: [Int: StepMeta]] = [:], parts: [InstrumentPart] = []) {
        self.name = name; self.lanes = lanes; self.melody = melody; self.stepMeta = stepMeta; self.parts = parts
    }
    enum CodingKeys: String, CodingKey { case name, lanes, melody, stepMeta, parts }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        lanes = try c.decode([String: [Double]].self, forKey: .lanes)
        melody = try c.decode([MelodyNote].self, forKey: .melody)
        stepMeta = (try? c.decodeIfPresent([String: [Int: StepMeta]].self, forKey: .stepMeta)) ?? [:]
        parts = (try? c.decodeIfPresent([InstrumentPart].self, forKey: .parts)) ?? []
    }
}

struct Clip: Identifiable, Codable {
    var id = UUID()
    var s: Int          // start bar
    var l: Int          // length bars
    var color: Color
    var muted = false   // per-clip mute (skipped in Song Mode playback/export)
    /// Which pattern THIS clip plays, independent of the section under it. `nil` (the default, and what
    /// every pre-existing project decodes to) means "follow the section", i.e. the old global behaviour.
    /// Set, it lets one track run pattern B while another stays on A over the same bars — the thing the
    /// section-only model could not express (SEQUENCE_TRACKS_AUDIT finding 1).
    var seq: Int? = nil
    enum CodingKeys: String, CodingKey { case id, s, l, color, muted, seq }   // legacy files may omit id; color persists as hex
    init(s: Int, l: Int, color: Color, muted: Bool = false, seq: Int? = nil) {
        self.s = s; self.l = l; self.color = color; self.muted = muted; self.seq = seq
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        s = try c.decode(Int.self, forKey: .s)
        l = try c.decode(Int.self, forKey: .l)
        color = Color(hex: try c.decode(String.self, forKey: .color))
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? false
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)   // absent in v1–v3 saves → follow the section
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(s, forKey: .s)
        try c.encode(l, forKey: .l)
        try c.encode(color.toHex(), forKey: .color)
        try c.encode(muted, forKey: .muted)
        try c.encodeIfPresent(seq, forKey: .seq)
    }
}

struct Slice: Codable { var offset: Double; var dur: Double }   // seconds

struct MelodyNote: Identifiable, Codable {
    let id = UUID()
    var step: Int       // 0..15
    var pitch: Int      // MIDI note
    var dur: Int        // length in steps
    var vel: Double
    enum CodingKeys: String, CodingKey { case step, pitch, dur, vel }
}

struct SynthBankSlot: Codable { var midi: Int; var patch: SynthPatch }

// Per-pad inspector edits. A pad with no entry behaves exactly like its base voice.
struct PadLayer: Identifiable, Equatable, Codable {
    let id = UUID()
    var sound: String
    var vol: Double = 0.7
    var pitch: Double = 0
    var pan: Double = 0
    enum CodingKeys: String, CodingKey { case sound, vol, pitch, pan }
}
struct PadParam: Equatable, Codable {
    var vol = 0.85
    var pan = 0.0
    var pitch = 0.0          // semitones
    var attack = 0.001
    var decay = 0.0
    var sustain = 1.0
    var release = 1.5
    var cutoff = 18000.0
    var reso = 1.0
    var mode = "oneshot"     // oneshot | gate | loop (hold)
    var choke = 0            // 0 = off, 1..4 choke groups
    var layers: [PadLayer] = []
    var colorHex: String? = nil
    var label: String? = nil
    var sound: String? = nil        // base-sound override (a Kit.drumSounds id); nil = the pad's default
    var sampleFile: String? = nil   // imported one-shot WAV in FD808Samples/<file>; takes precedence over `sound`
    var sampleName: String? = nil   // display name of the imported sample
    var sampleBank: String? = nil   // bank ("A"–"D") the sample applies in; nil = every bank (legacy saves, F0)
    // MPC "Play" params (optional → old saves decode; Swift synthesized Codable throws on missing non-optionals)
    var poly: Bool? = nil           // nil/true = Poly · false = Mono (the pad cuts its own previous hit)
    var offset: Double? = nil       // 0..1 trigger offset (lay-back micro-timing)
    var velSens: Double? = nil      // 0..1 velocity sensitivity (nil/1 = fully responsive · 0 = always full)

    var color: Color? { colorHex.map { Color(hex: $0) } }
    var polyV: Bool { poly ?? true }
    var offsetV: Double { offset ?? 0 }
    var velSensV: Double { velSens ?? 1 }
}

struct PreparedPadSample: Sendable {
    let id: String
    let data: [Float]
    let name: String
    let file: String
}

/// Captures the document identity and CONTENT revision before an asynchronous editing operation. The
/// revision moves when the sampler buffer, the whole project or the pad bank is replaced — not on every
/// step tap or fader nudge, which used to discard a 20 s stretch because the user touched a fader while it
/// ran (SYSTEMS_GAP_AUDIT round 2, cross-1).
struct ProjectOperationDestination: Equatable {
    let projectID: String
    let bank: String
    let revision: UInt64
    @MainActor func matches(_ project: Project) -> Bool {
        project.projectID == projectID && project.bank == bank && project.contentRevision == revision
    }
}

struct SampleState: Codable {
    var name: String
    var kind: String
    var dur: Double
    var trim: [Double] = [0, 1]
    var slices: [Double] = []          // normalized positions 0..1
    var count: Int = 0
    var tools: [String: Bool] = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]
    var pitch: Int = 0                 // semitones for audition / slice playback (the user-facing slider)
    var tuneOffset: Int = 0            // Tune-to-Key correction, applied ON TOP of pitch so a later
                                       // slider touch can't silently destroy the tuning (UX #63)
    var gain: Double = 1               // 0..2
    var loop: Bool = false             // loop the audition region continuously
    var reverseSlices: Bool = false    // map slices in reverse order onto pads
    var wave: [Double] = []            // downsampled peak buckets, 0..1
    var transients: [Double] = []      // normalized transient positions
    var audioFile: String? = nil       // FD808Samples/<file> holding the pristine buffer (persistence)
    var harmonize: Bool = false        // D6 — add diatonic 3rd+5th voices on playback

    // Tolerant decode so older saves (which lacked most of these) still load.
    enum CodingKeys: String, CodingKey { case name, kind, dur, trim, slices, count, tools, pitch, tuneOffset, gain, loop, reverseSlices, wave, transients, audioFile, harmonize }
    init(name: String, kind: String, dur: Double, trim: [Double] = [0, 1], slices: [Double] = [], count: Int = 0,
         tools: [String: Bool] = ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false],
         pitch: Int = 0, tuneOffset: Int = 0, gain: Double = 1, loop: Bool = false, reverseSlices: Bool = false,
         wave: [Double] = [], transients: [Double] = [], audioFile: String? = nil, harmonize: Bool = false) {
        self.name = name; self.kind = kind; self.dur = dur; self.trim = trim; self.slices = slices; self.count = count
        self.tools = tools; self.pitch = pitch; self.tuneOffset = tuneOffset; self.gain = gain; self.loop = loop; self.reverseSlices = reverseSlices
        self.wave = wave; self.transients = transients; self.audioFile = audioFile; self.harmonize = harmonize
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        dur = try c.decode(Double.self, forKey: .dur)
        trim = (try? c.decode([Double].self, forKey: .trim)) ?? [0, 1]
        slices = (try? c.decode([Double].self, forKey: .slices)) ?? []
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
        tools = (try? c.decode([String: Bool].self, forKey: .tools)) ?? ["normalize": false, "reverse": false, "fadeIn": false, "fadeOut": false]
        pitch = (try? c.decode(Int.self, forKey: .pitch)) ?? 0
        tuneOffset = (try? c.decode(Int.self, forKey: .tuneOffset)) ?? 0
        gain = (try? c.decode(Double.self, forKey: .gain)) ?? 1
        loop = (try? c.decode(Bool.self, forKey: .loop)) ?? false
        reverseSlices = (try? c.decode(Bool.self, forKey: .reverseSlices)) ?? false
        wave = (try? c.decode([Double].self, forKey: .wave)) ?? []
        transients = (try? c.decode([Double].self, forKey: .transients)) ?? []
        audioFile = try? c.decodeIfPresent(String.self, forKey: .audioFile)
        harmonize = (try? c.decode(Bool.self, forKey: .harmonize)) ?? false
    }
}

// An imported/recorded audio clip on the arrangement's Audio track (A5 multitrack).
// Buffers live in memory only for now — persistence is a later phase.
struct AudioClip: Identifiable {
    var id = UUID()
    var track: String
    var startBar: Int
    var data: [Float]      // left / mono @ engine SR
    var dataR: [Float]? = nil   // right channel for a stereo take (nil = mono); plays as a 2nd hard-panned voice
    var wave: [Float]      // downsampled peaks for display
    var name: String
    var gain: Double = 1
    var durSec: Double
    var muted: Bool = false   // mute alternate takes for manual comping (A5 Phase 3)
    var isStereo: Bool { dataR != nil }
}

// Lightweight, Codable clip metadata persisted in the snapshot; the audio itself
// is a WAV in FD808Audio/<id>.wav (A5 Phase 4).
struct AudioClipMeta: Codable {
    var id: String
    var track: String
    var startBar: Int
    var name: String
    var gain: Double
    var muted: Bool
    var durSec: Double
    /// True when the take was recorded/imported with a paired `<id>.R.wav`. Optional so old saves (which
    /// predate the flag) decode as mono rather than being reported as broken stereo (#PERSIST-STEREO).
    var isStereo: Bool? = nil
}

@MainActor
final class Project: ObservableObject {
    let engine: AudioEngine

    // transport / global
    @Published var name = "Untitled Beat"
    /// Stable identity, decoupled from the display name/filename, so last-project reload
    /// survives renames and same-name collisions (#219). A fresh project gets a fresh id;
    /// old name-keyed saves mint one at load and persist it on the next save.
    @Published var projectID = UUID().uuidString
    @Published var bpm = 90
    @Published var swing = 0.0          // 0 .. 0.6
    @Published var humanize = 0.0       // 0 .. 1 — Time Correct: random timing + velocity drift for a human feel
    @Published var grooveID = "straight"  // named timing feel (E4); "straight" defers to the Swing slider
    @Published var quantize = "1/16"
    @Published var barSteps = 16        // steps per bar: 16=4/4, 12=3/4, 8=2/4 (A13)
    @Published var playing = false
    @Published var isBouncing = false   // an offline render (auto-master / resample / freeze) is running — drives busy UI (#ARCH-01)
    @Published var recording = false
    /// True while the count-in clicks are playing (Transport owns it). Record paths skip these bars.
    @Published var countingIn = false
    /// A non-forked follower mirrors the teacher: local undo/redo is refused (RootView keeps it in sync).
    @Published var editingLocked = false
    @Published var micRecordFailed = false   // mic permission denied / tap failed → surface "enable mic access" (transient)
    @Published var audioWriteFailed = false  // a take / pad sample could not be written to disk → surfaced, not silent (#PERSIST-CLIP)
    @Published private(set) var metronome = false
    @Published private(set) var countIn = 0          // bars: 0,1,2,4
    @Published var step = -1            // live playhead step (0..15); -1 stopped
    @Published var bar = 0             // live arrangement bar

    // pad mode
    @Published var bank = "A"
    @Published private(set) var fullLevel = false
    @Published var noteRepeat = false
    @Published var repeatDiv = "1/16"
    @Published var sixteenLevels = false
    @Published var levelsParam = "velocity"
    @Published var muteMode = false        // pad-performance Mute mode: tap pads to mute/unmute live
    @Published var focusMode = false       // compose Focus: live playback plays ONLY the active part (monitor one sound while writing it)
    @Published var midiArmed = false       // compose MIDI record-arm: live key/pad hits capture into the active part, snapped to the grid

    // sequencer
    @Published var lanes: [String: [Double]]
    @Published var stepMeta: [String: [Int: StepMeta]] = [:]   // per-step prob/condition/p-locks, mirrors active sequence
    @Published var selectedRow = "kick"
    @Published var rowMute: [String: Bool] = [:]
    @Published var rowSolo: [String: Bool] = [:]

    // sequences (pattern banks) — `lanes`/`melody` mirror the active one
    @Published var sequences: [SeqSlot]
    @Published var activeSeq = 0

    // mixer
    @Published var mixer: [String: MixChannel]

    // arrangement
    @Published var arrangement: [ArrItem]
    @Published var clips: [String: [Clip]]
    @Published var trackMute: [String: Bool] = [:]
    @Published var trackSolo: [String: Bool] = [:]
    @Published var songMode = false       // when on, playback follows the arrangement clips
    @Published var songBars = 16          // arrangement length in bars (16/32/64) — persisted; old saves decode 16

    // dynamic track list (the 99-layered-tracks foundation). Seeded with the 6 legacy lanes;
    // "Add Track" / send-to-track append frozen-content tracks. See Track.swift.
    @Published var tracks: [Track] = []

    // sampling
    @Published var sample: SampleState?
    @Published var sliceBank: [String: Slice]?

    // audio clips on the arrangement's Audio track (A5) — in-memory only for now
    @Published var audioClips: [AudioClip] = []
    @Published var audioArmedTrack: String? = nil    // track armed for mic recording
    /// Manual record-alignment nudge. Device-specific, so it lives in UserDefaults rather than the project —
    /// it used to reset to 0 on every launch and the next take landed misaligned (SYSTEMS_GAP_AUDIT #persist-7).
    @Published var audioRecOffsetMs: Int = UserDefaults.standard.integer(forKey: "fd.audioRecOffsetMs") {
        didSet { UserDefaults.standard.set(audioRecOffsetMs, forKey: "fd.audioRecOffsetMs") }
    }
    /// Bar where a recorded take begins (A5 Phase 3). Persisted in the snapshot; mutate via `setPunchInBar`.
    @Published private(set) var punchInBar: Int = 0

    // melody (piano-roll notes for the synth track)
    @Published var melody: [MelodyNote] = []
    @Published var melodyKey = 0           // 0 = C
    @Published var melodyScale = "major"
    @Published var melodyOctave = 0        // -1, 0, +1
    @Published var melodyDensity = "balanced"
    @Published var melodyMuted = false
    // FX automation lane (A11) — 16 steps, 0..1; target picks which FX param it sweeps
    @Published var autoTarget = ""         // "" | "filter" | "reverb" | "delay"
    @Published var autoLane: [Double] = Array(repeating: 1, count: 16)
    // Song-wide automation (Tracks Tier 3) — one breakpoint per song bar, applied in Song Mode
    @Published var songAutoTarget = ""     // "" | "filter" | "reverb" | "delay"
    @Published var songAuto: [Double] = Array(repeating: 1, count: 16)

    @Published private(set) var scaleLock = true        // keep the keyboard (and everything) in the song key
    @Published private(set) var rollLen = 2             // note length placed by a tap, in 16th steps (1=1/16, 2=1/8, 4=1/4, 8=1/2, 16=1/1)

    // master FX (reverb + delay on the output bus) — pushed to the engine on change
    @Published var fxSettings = MasterFX() { didSet { engine.setMasterFX(fxSettings) } }

    // per-channel insert FX (EQ / comp / drive), keyed by mixer bus id — pushed to the engine
    @Published var channelFX: [String: ChannelFX] = [:] { didSet { pushChannelFX() } }

    // master-bus chain (EQ + limiter) — pushed to the engine on change
    @Published var masterBus = MasterBus() { didSet { engine.setMasterBus(masterBus) } }

    // synth maker (the knob-driven patch that plays the roll + the keyboard)
    @Published var synthPatch = SynthPresets.default {
        didSet { SharedPatchStore.save(synthPatch) }   // share the current sound with the FD808AU plugin (App Group)
    }
    @Published var parts: [InstrumentPart] = []   // Tier 2: extra instrument parts beyond Lead (=melody/synthPatch)
    @Published var activePart = "lead"            // which part the Synth UI edits: "lead" or a parts[].id
    @Published var savedSynths: [SynthPatch] = []
    @Published var synthBank: [String: SynthBankSlot]?

    // pad inspector
    @Published var padParams: [String: PadParam] = [:]
    @Published var activeKit = "classic"   // which DrumKitPreset is applied (for the picker highlight)
    // Imported one-shot sample buffers, keyed by pad id (mono @ engine SR). Not Codable —
    // rehydrated from FD808Samples/<file> on project load. Kept here so offline export can embed them.
    var padSampleData: [String: [Float]] = [:]

    // undo / redo — snapshot-based restore points
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasUnsavedChanges = false   // dirty flag: any edit since the last save/load
    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []
    private var lastCheckpointKey: String?
    private var lastCheckpointAt = Date.distantPast
    private let undoLimit = 80
    /// True while applyState() runs (undo/redo/load). Engine-push didSets still fire (needed to
    /// re-sync), but checkpoint() must early-out — restoring a snapshot is not itself an edit (#23).
    private var isApplyingState = false
    // Op layer (Step 4): the sync bus (no-op until a live room attaches one), the remote-apply guard
    // (suppresses undo pollution + op echo while applying a received op), and the last applied seq.
    var syncBus: SyncBus = NoSyncBus()
    private(set) var isApplyingRemote = false
    var lastOpSeq: UInt64 = 0
    // #19 sampler-buffer undo: a bounded ring of pre-edit engine `sampleOriginal` copies, keyed by a
    // token stamped into the snapshot a checkpoint captures, so undo/redo can restore the AUDIO too.
    private var sampleBufferRing: [(key: String, buffer: [Float])] = []
    private let sampleBufferRingCap = 12
    private let sampleBufferRingMaxFrames = 8_000_000   // ~32 MB of Float PCM; avoids runaway undo memory
    private var nextBufferToken = 0
    private var pendingBufferToken: Int? = nil   // read by snapshot() at the next checkpoint

    init(engine: AudioEngine) {
        self.engine = engine
        let l0 = Kit.lanesFromSteps(Kit.pattern("boombap")?.steps ?? [])
        self.lanes = l0
        self.sequences = [
            SeqSlot(name: "A", lanes: l0, melody: []),
            SeqSlot(name: "B", lanes: Kit.lanesFromSteps(Kit.pattern("house")?.steps ?? []), melody: []),
            SeqSlot(name: "C", lanes: Kit.lanesFromSteps(Kit.pattern("trap")?.steps ?? []), melody: []),
            SeqSlot(name: "D", lanes: [:], melody: []),
        ]
        var m: [String: MixChannel] = [:]
        for c in Kit.channels { m[c.id] = MixChannel() }
        m["melody"] = MixChannel(vol: 0.85)
        m["master"] = MixChannel(vol: 0.9)
        self.mixer = m
        // demo song: intro/verse use A, the hook switches to the trap beat (C)
        self.arrangement = [
            ArrItem(id: "a1", section: "intro", start: 0, len: 2, seq: 0),
            ArrItem(id: "a2", section: "verse", start: 2, len: 4, seq: 0),
            ArrItem(id: "a3", section: "hook", start: 6, len: 4, seq: 2),
            ArrItem(id: "a4", section: "verse", start: 10, len: 4, seq: 0),
            ArrItem(id: "a5", section: "outro", start: 14, len: 2, seq: 0),
        ]
        self.clips = [
            "drums": [Clip(s: 0, l: 16, color: Kit.channelColor("drums"))],
            "hats":  [Clip(s: 2, l: 12, color: Kit.channelColor("hats"))],
            "bass":  [Clip(s: 2, l: 12, color: Kit.channelColor("bass"))],
            "perc":  [Clip(s: 6, l: 4, color: Kit.channelColor("perc")), Clip(s: 10, l: 4, color: Kit.channelColor("perc"))],
            "vox":   [Clip(s: 6, l: 4, color: Color(hex: "#E879F9"))],   // vox has no mixer channel
        ]
        self.tracks = Project.seedTracks()
    }

    // MARK: lane helpers

    func toggleStep(_ padID: String, _ i: Int, vel: Double = 0.85) {
        checkpoint("toggle:\(padID)", coalesce: false)
        var lane = lanes[padID] ?? Kit.emptyLane()
        lane[i] = lane[i] != 0 ? 0 : vel
        lanes[padID] = lane
        emit(.setStep(pad: padID, step: i, vel: lane[i]))
    }
    func setStepVel(_ padID: String, _ i: Int, _ vel: Double) {
        var lane = lanes[padID] ?? Kit.emptyLane()
        guard lane.indices.contains(i) else { return }   // ignore out-of-range steps (e.g. a malformed remote op)
        let v = max(0, min(1, vel))
        // Idempotent: the velocity bar's `minimumDistance: 0` drag delivers a zero-translation frame on
        // touch-down whose value equals the one already there. Checkpointing that marked the project dirty
        // and wiped the redo stack for no edit (#MIX-UNDO).
        guard lane[i] != v else { return }
        checkpoint("paint:\(padID)")
        lane[i] = v
        lanes[padID] = lane
        emit(.setStep(pad: padID, step: i, vel: lane[i]))
    }
    func clearRow(_ padID: String) { checkpoint("clearRow", coalesce: false); lanes[padID] = Kit.emptyLane(); stepMeta[padID] = nil; emit(.clearRow(pad: padID)) }
    func clearAll() { checkpoint("clearAll", coalesce: false); lanes = [:]; stepMeta = [:]; contentRevision &+= 1 }
    func setRowLane(_ padID: String, _ lane: [Double]) { checkpoint("row:\(padID)", coalesce: false); lanes[padID] = lane; stepMeta[padID] = nil }

    // MARK: row mute (checkpointed so it is undoable + dirty like every other mute control)

    /// Toggle one row's mute. Every mute control must go through here (or checkpoint itself): a bare
    /// `rowMute[x] = !rowMute[x]` leaves the edit out of undo, never sets `hasUnsavedChanges`, and is then
    /// silently dropped by autosave / project switch / New Beat (#MUTE-01).
    func toggleRowMute(_ padID: String) {
        checkpoint("rowmute", coalesce: false)   // one tap = one undo step (mirrors Sequence/Track mutes)
        rowMute[padID] = !(rowMute[padID] ?? false)
    }
    /// Clear every row mute as ONE undoable edit. No-ops when nothing is muted so it never dirties an
    /// otherwise-clean project or pushes an empty undo entry (#MUTE-01).
    func unmuteAllRows() {
        guard rowMute.values.contains(true) else { return }
        checkpoint("rowmute.all", coalesce: false)
        for k in Array(rowMute.keys) { rowMute[k] = false }
    }

    // MARK: persisted performance/setup preferences (#PERSIST-PREFS)

    /// Every one of these is a `ProjectSnapshot` field, so every write must checkpoint: a bare
    /// `project.chordMode = x` in the view layer left the edit out of undo, never set
    /// `hasUnsavedChanges`, and was then silently dropped by autosave / project switch / New Beat.
    /// The backing properties are `private(set)` so the compiler keeps future call sites honest.
    /// Each is idempotent: re-selecting the current value is not an edit (no dirty flag, no redo loss).
    func setChordMode(_ v: String) {
        guard v != chordMode else { return }
        checkpoint("chord", coalesce: false)
        chordMode = v
    }
    func setArpMode(_ v: String) {
        guard v != arpMode else { return }
        checkpoint("arp", coalesce: false)
        arpMode = v
    }
    func setArpRate(_ v: String) {
        guard v != arpRate else { return }
        checkpoint("arprate", coalesce: false)
        arpRate = v
    }
    func setArpOct(_ v: Int) {
        guard v != arpOct else { return }
        checkpoint("arpoct", coalesce: false)
        arpOct = v
    }
    func setScaleLock(_ on: Bool) {
        guard on != scaleLock else { return }
        checkpoint("scalelock", coalesce: false)
        scaleLock = on
    }
    func setRollLen(_ v: Int) {
        guard v != rollLen else { return }
        checkpoint("rolllen", coalesce: false)
        rollLen = v
    }
    func setMetronome(_ on: Bool) {
        guard on != metronome else { return }
        checkpoint("metronome", coalesce: false)
        metronome = on
    }
    func setCountIn(_ v: Int) {
        guard v != countIn else { return }
        checkpoint("countin", coalesce: false)
        countIn = v
    }
    func setFullLevel(_ on: Bool) {
        guard on != fullLevel else { return }
        checkpoint("fulllevel", coalesce: false)
        fullLevel = on
    }

    // MARK: - Op layer (Step 4) — emit local edits, apply remote ops through the same mutators

    /// Emit an op for a LOCAL edit. No-op unless a real SyncBus is attached (live room as teacher).
    /// Suppressed while applying a remote op or restoring state, so there's no echo and undo/load
    /// don't broadcast. Called at the end of the named mutators (the single choke point per verb).
    func emit(_ kind: OpKind) {
        guard !isApplyingRemote, !isApplyingState else { return }
        syncBus.emit(SyncOp(kind: kind))
    }

    /// Apply an op to the live state by calling the SAME mutator the teacher's UI called. `remote`
    /// = received from the network → sets the guard so it doesn't pollute the student's undo stack
    /// or re-emit. Drives toward the op's intended state (idempotent where the mutator is a toggle).
    func applyOp(_ kind: OpKind, remote: Bool) {
        // remote ops apply like a state restore: checkpoint() early-outs (no undo pollution) and
        // emit() early-outs (no echo back to the network), both via the isApplyingState/Remote guards.
        if remote { isApplyingRemote = true; isApplyingState = true }
        defer { if remote { isApplyingRemote = false; isApplyingState = false } }
        switch kind {
        case .setStep(let pad, let step, let vel):
            guard Kit.padByID[pad] != nil, (0..<max(1, barSteps)).contains(step) else { return }   // no ghost steps past the bar
            setStepVel(pad, step, vel)
        case .clearRow(let pad):
            clearRow(pad)
        case .setMelodyNote(let step, let pitch, let len, let on):
            // placeMelodyNote toggles: adds when absent, removes when present. Only act when the
            // current state differs from the op's intended `on`, so apply converges to the teacher's.
            let exists = melody.contains { $0.pitch == pitch && step >= $0.step && step < $0.step + $0.dur }
            if on != exists { placeMelodyNote(step: step, pitch: pitch, len: len) }
        case .setStepMeta(let pad, let step, let meta):
            // Validate like setStepVel does: an unknown pad or out-of-bar step from the wire must not be
            // persisted as garbage keys in the student's project (SYSTEMS_GAP_AUDIT #sync-8).
            guard Kit.padByID[pad] != nil, (0..<max(1, barSteps)).contains(step) else { return }
            setStepMeta(pad, step) { $0 = meta }
        case .setTempo(let bpm):
            setBpm(bpm)
        case .switchSequence(let i):
            switchSequence(i)
        case .setBank(let b):
            guard Kit.banks[b] != nil else { return }
            bank = b
        case .setMix(let ch, let vol, let pan, let mute, let solo):
            guard ch == "master" || ch == "melody" || Kit.channels.contains(where: { $0.id == ch })
                    || tracks.contains(where: { $0.id == ch }) else { return }   // unknown channel strings must not persist
            setMix(ch) { m in
                if let vol { m.vol = vol }; if let pan { m.pan = pan }
                if let mute { m.mute = mute }; if let solo { m.solo = solo }
            }
        case .transport, .roomClosed:
            break   // transport: Step 7 clock-synced follow; roomClosed: handled by the session store
        case .fullSync(let snap):
            // keepHistory: a follower's own beat stays one Undo away (the join checkpoint below), and the
            // dirty flag is not cleared, so the recovery autosave keeps protecting whatever was there.
            restore(snap, keepHistory: remote)
        }
    }

    /// True once this remote session has delivered its first snapshot (reset by `beginRemoteSession`).
    private var receivedFirstFullSync = false
    /// The student's own beat, captured when a follow starts, so Leave can put it back (undo is locked while
    /// following, and the recovery slot is a crash net, not a way back).
    private var preJoinSnapshot: ProjectSnapshot?
    /// Called by the session store when a follow starts, so the first snapshot of EVERY class gets its own
    /// join checkpoint and the current beat is kept for `restorePreJoin`.
    func beginRemoteSession() {
        receivedFirstFullSync = false
        var snap = snapshot()
        // Keep the student's sampler AUDIO too: a live snapshot describes the buffer but does not carry it,
        // and the class may replace it (round 3, persist-4 / undo-4).
        let buf = engine.currentSampleOriginal()
        if !buf.isEmpty {
            let token = nextBufferToken; nextBufferToken += 1
            sampleBufferRing.append((key: "\(token)", buffer: buf)); trimSampleRing()
            snap.sampleBufferToken = token
        }
        preJoinSnapshot = snap
    }
    /// Put the beat from before the class back (after Leave). Undoable — the teacher's version stays one
    /// Undo away. Returns false when there is nothing to restore.
    @discardableResult
    func restorePreJoin() -> Bool {
        guard let s = preJoinSnapshot else { return false }
        preJoinSnapshot = nil
        checkpoint("leave class", coalesce: false)
        restore(s, keepHistory: true)
        restoreSampleBufferToken(s.sampleBufferToken)   // the audio stashed at join time
        rebuildSynthSampleSource()
        return true
    }

    /// Student path: apply a received op (records seq for gap detection; no undo pollution, no echo).
    func applyRemote(_ op: SyncOp) {
        lastOpSeq = op.seq
        if case .fullSync = op.kind, !receivedFirstFullSync {
            // The teacher's snapshot is about to replace this beat. Checkpoint it BEFORE the applying-state
            // guard engages so the student can Undo straight back to their own work (SYSTEMS_GAP_AUDIT #sync-1).
            receivedFirstFullSync = true
            checkpoint("class join", coalesce: false)
        }
        applyOp(op.kind, remote: true)
        // Remote ops bypass checkpoint (no undo pollution), which also skipped the dirty flag — a follower
        // who mirrored a whole lesson had a clean flag, so neither autosave path kept it (SYSTEMS_GAP_AUDIT #undo-8).
        hasUnsavedChanges = true
    }

    // MARK: per-step meta (probability / conditions / p-locks)

    func setStepMeta(_ pad: String, _ step: Int, _ mutate: (inout StepMeta) -> Void) {
        checkpoint("stepmeta:\(pad)")
        var sm = stepMeta[pad]?[step] ?? StepMeta()
        mutate(&sm)
        if sm.isDefault {
            stepMeta[pad]?[step] = nil
            if stepMeta[pad]?.isEmpty == true { stepMeta[pad] = nil }
        } else {
            stepMeta[pad, default: [:]][step] = sm
        }
        emit(.setStepMeta(pad: pad, step: step, meta: sm))
    }
    func clearStepMeta(_ pad: String, _ step: Int) {
        checkpoint("stepmeta:\(pad)", coalesce: false)
        stepMeta[pad]?[step] = nil
        if stepMeta[pad]?.isEmpty == true { stepMeta[pad] = nil }
    }
    func stepMetaForBar(_ bar: Int) -> [String: [Int: StepMeta]] { stepMetaOfSeq(sequenceIndexForBar(bar)) }
    /// Evaluate an Elektron-style trig condition against the loop/bar counter.
    static func condPass(_ cond: String, bar: Int) -> Bool {
        switch cond {
        case "1:2": return bar % 2 == 0
        case "2:2": return bar % 2 == 1
        case "1:3": return bar % 3 == 0
        case "1:4": return bar % 4 == 0
        case "fill": return bar % 4 == 3
        case "!fill": return bar % 4 != 3
        default: return true
        }
    }

    /// Wrap a finite bar position before converting to Int; malformed MIDI timing cannot trap.
    static func quantizedStep(_ position: Double, barSteps: Int, quantize: String) -> Int? {
        guard position.isFinite else { return nil }
        let n = min(16, max(1, barSteps))
        let cells = quantize == "1/8" ? max(1, n / 2) : n
        let wrapped = position.truncatingRemainder(dividingBy: 1)
        let cell = ((Int((wrapped * Double(cells)).rounded()) % cells) + cells) % cells
        return min(n - 1, cell * (n / cells))
    }

    /// Record a live pad hit into the active sequence lane. `when0to1` is the fractional position
    /// within the bar (0..1); it quantizes to the nearest step of the ACTIVE bar length (barSteps),
    /// not a hardcoded 16. `vel` stores the played velocity (pre-velSens; Transport applies velSens
    /// on playback) — defaults to the live-tap base so a recorded hit matches a hand-placed step.
    func recordHit(_ padID: String, _ when0to1: Double, vel: Double? = nil) {
        // Warm-up hits during the count-in used to be stamped onto step 0 as phantom downbeats
        // (SYSTEMS_GAP_AUDIT #transport-2). Gate on the count-in itself, not on `step >= 0`: a hit struck
        // just before the first real step publishes must still quantize to the downbeat.
        guard !countingIn else { return }
        guard let i = Self.quantizedStep(when0to1, barSteps: barSteps, quantize: quantize) else { return }
        let v = vel ?? (fullLevel ? 1 : 0.85)
        // A hit in the last half-step of a bar quantizes to step 0 of the NEXT bar: target that bar's sequence.
        let wrapped = i == 0 && when0to1 > 0.5
        // Song Mode plays `lanesForBar(bar)`; a hit must land in the sequence that is SOUNDING at this bar,
        // not in the active edit buffer (SYSTEMS_GAP_AUDIT #transport-1).
        if let target = recordTargetSequence(wrapToNextBar: wrapped) {
            var lane = sequences[target].lanes[padID] ?? Kit.emptyLane()
            guard lane.indices.contains(i) else { return }
            checkpoint("record")
            lane[i] = v
            sequences[target].lanes[padID] = lane
            return
        }
        var lane = lanes[padID] ?? Kit.emptyLane()
        guard lane.indices.contains(i) else { return }   // guard against a short custom lane vs barSteps
        checkpoint("record")   // after the bounds guard: a rejected hit must not dirty the project (#cross-8)
        lane[i] = v
        lanes[padID] = lane
    }
    /// In Song Mode, the index of a NON-active sequence that owns the current arrangement bar (nil when the
    /// active edit buffer is the one playing, or in Loop Mode). `wrapToNextBar` targets the following bar
    /// for a hit that quantized past the bar line.
    func recordTargetSequence(wrapToNextBar: Bool = false) -> Int? {
        guard songMode else { return nil }
        let b = wrapToNextBar ? (bar + 1) % max(1, songBars) : bar
        let i = sequenceIndexForBar(b)
        return (i != activeSeq && sequences.indices.contains(i)) ? i : nil
    }

    /// Record a Bank-D synth pad as a MELODY note at the pad's mapped pitch — so it sequences and
    /// exports as synth (the melody/synth path), not as a drum, and WITHOUT clobbering the shared
    /// drum lanes (which `synthBank` maps for all 16 pads). Falls back to a drum hit if unmapped. (#26 Bank D)
    func recordSynthPad(_ padID: String, _ when0to1: Double) {
        guard let slot = synthBank?[padID] else {
            recordHit(padID, when0to1, vel: fullLevel ? 1.0 : 0.85); return
        }
        guard !countingIn else { return }   // count-in (see recordHit)
        guard let step = Self.quantizedStep(when0to1, barSteps: barSteps, quantize: quantize) else { return }
        // Song Mode: the sequence sounding at this bar (see recordHit). Converges to followers through the
        // heartbeat fullSync (the per-note op carries no sequence index).
        if let target = recordTargetSequence(wrapToNextBar: step == 0 && when0to1 > 0.5) {
            checkpoint("melody", coalesce: false)
            let (st, dur) = Self.boundedNote(step: step, len: rollLen, barSteps: barSteps)
            sequences[target].melody.removeAll { $0.step < st + dur && $0.step + $0.dur > st && $0.pitch == slot.midi }
            sequences[target].melody.append(MelodyNote(step: st, pitch: slot.midi, dur: dur, vel: st % 4 == 0 ? 0.95 : 0.8))
            return
        }
        placeMelodyNote(step: step, pitch: slot.midi, len: rollLen)   // checkpoints; plays via the synth in seq + export
    }

    /// A pad's stacked layers that may sound right now. Each layer is gated by the mixer bus its OWN
    /// sound routes to (finding 72): a "Deep Kick" layer stacked on the kick pad plays on the 808/bass
    /// strip, so muting that strip (or soloing Drums) must silence it. Live taps, the sequencer and the
    /// bounce all resolve layers through this one function.
    func audiblePadLayers(_ padID: String) -> [PadLayer] {
        (padParams[padID]?.layers ?? []).filter { channelAudible(Kit.channelOf($0.sound)) }
    }

    /// Trigger a pad's extra stacked layers (Pad Inspector → Layers) at a scheduled time. Used by the
    /// sequencer + frozen tracks so layered pads sound layered everywhere, not only on live taps.
    func triggerPadLayers(_ padID: String, vel: Double, when: Double?) {
        for ly in audiblePadLayers(padID) {
            engine.trigger(ly.sound, vel: vel * ly.vol, when: when, opts: TriggerOpts(pitch: ly.pitch, pan: ly.pan))
        }
    }

    // MARK: mixer

    /// `emit: false` is for the fader/pan drags: they write a value every frame and would otherwise put
    /// ~60 ops/s per fader on the sync bus; the strip emits ONCE from `.onEnded` via `emitMix` instead.
    func setMix(_ ch: String, emit: Bool = true, _ patch: (inout MixChannel) -> Void) {
        var c = mixer[ch] ?? MixChannel()
        patch(&c)
        c = c.sanitized()   // the 1.1/1.4 ceilings and finite values hold for EVERY writer, incl. remote ops
        // Idempotent: the pan knob and fader use `minimumDistance: 0`, so touch-down writes a value equal
        // to the current one. That must not checkpoint (dirty + redo loss) and must not echo to the room (#MIX-UNDO).
        guard c != (mixer[ch] ?? MixChannel()) else { return }
        checkpoint("mix:\(ch)")
        mixer[ch] = c
        if ch == "master" { pushMasterVolume() }   // master fader/mute is LIVE — affects sounding voices immediately
        if emit { emitMix(ch) }
    }
    /// Publish a channel's current mix state to the room (the end-of-drag op for `setMix(emit: false)`).
    func emitMix(_ ch: String) {
        let c = mixer[ch] ?? MixChannel()
        emit(.setMix(ch: ch, vol: c.vol, pan: c.pan, mute: c.mute, solo: c.solo))
    }

    /// Drive the engine's (live) master gain from the master-channel fader, so moving the master fader or
    /// muting it changes sounding voices in real time instead of only the next triggered hit. Level-neutral:
    /// `0.9` is the engine's existing base trim; `master.vol` was previously baked into every trigger's
    /// velocity (now removed there), so total master gain is unchanged at any fader position.
    func pushMasterVolume() {
        let mst = mixer["master"] ?? MixChannel(vol: 0.9)
        engine.setVolume(mst.mute ? 0 : 0.9 * mst.vol)
    }
    func anySolo() -> Bool { mixer.values.contains { $0.solo } }
    /// True when any solo or mute would shape a bounce — the export paths confirm before rendering
    /// (a kick soloed "just to check" used to become a kick-only share with no warning) (#export-1).
    var mixGateActive: Bool {
        anySolo() || mixer.values.contains { $0.mute }
            || rowSolo.values.contains(true) || rowMute.values.contains(true)
            || trackSolo.values.contains(true) || trackMute.values.contains(true)
    }

    /// Ordered DSP-bus owner ids; index == engine strip slot. The 6 legacy buses first (so old
    /// projects are numerically identical), then one slot per track that owns its own insert FX (G3).
    var busOrder: [String] { FX_CHANNELS + tracks.filter { $0.ownsBus || $0.type == .bus }.map(\.id) }
    var busIndex: [String: Int] {
        var m: [String: Int] = [:]
        for (i, id) in busOrder.enumerated() { m[id] = i }
        return m
    }
    /// Push every bus's insert-FX params to the engine, resizing the engine's bus pool to match
    /// busOrder (G2/G3). For a project with no owned-bus tracks this is the original 6-bus push.
    func pushChannelFX() {
        engine.setChannelCount(busOrder.count)
        for (i, id) in busOrder.enumerated() { engine.setChannelFX(i, channelFX[id] ?? ChannelFX()) }
    }
    func setChannelFX(_ ch: String, _ mutate: (inout ChannelFX) -> Void) {
        checkpoint("fx:\(ch)")
        var c = channelFX[ch] ?? ChannelFX()
        mutate(&c)
        channelFX[ch] = c
    }

    /// Master reverb/delay edit as one coalesced undo step per knob (#23 — was a direct, non-undoable write).
    func setMasterFX(_ key: String, _ mutate: (inout MasterFX) -> Void) {
        checkpoint("mfx:\(key)")
        var f = fxSettings; mutate(&f); fxSettings = f   // didSet pushes to engine
    }
    /// Master-bus chain (EQ / limiter / multiband) edit as one coalesced undo step per knob (#23).
    func setMasterBus(_ key: String, _ mutate: (inout MasterBus) -> Void) {
        checkpoint("mbus:\(key)")
        var b = masterBus; mutate(&b); masterBus = b
    }

    func padGain(_ padID: String) -> Double {
        let ch = Kit.channelOf(padID)
        guard channelAudible(ch) else { return 0 }
        return (mixer[ch] ?? MixChannel()).vol * Project.padDrive
    }

    /// Whether a mixer channel is audible under the current mute/solo state (master mute included).
    /// One rule for the pad's own bus and for every stacked layer's bus (finding 72).
    func channelAudible(_ ch: String) -> Bool {
        let c = mixer[ch] ?? MixChannel()
        if c.mute { return false }
        if anySolo() && !c.solo { return false }
        let master = mixer["master"] ?? MixChannel(vol: 0.9)
        return !master.mute
    }

    /// The pad's inspector Volume trim, normalised so the shipped 0.85 knob is unity.
    func padVolMul(_ id: String) -> Double { padParams[id].map { $0.vol / 0.85 } ?? 1 }

    /// One pad's COMPLETE per-hit gain: its mixer fader (mute/solo applied) times its inspector Volume
    /// trim. The live tap, the sequencer and the offline bounce all resolve a hit through this single
    /// value, so the Volume knob cannot move a pad in the inspector while the pattern and the exported
    /// WAV stay put, and the live trim cannot diverge from the playback trim (finding 42).
    func padHitGain(_ padID: String) -> Double { padGain(padID) * padVolMul(padID) }

    // MARK: triggering

    // MARK: pad inspector

    func getPadParam(_ id: String) -> PadParam { padParams[id] ?? PadParam() }
    func setPadParam(_ id: String, _ mutate: (inout PadParam) -> Void) {
        checkpoint("pad:\(id)")
        var p = padParams[id] ?? PadParam()
        mutate(&p)
        padParams[id] = p
    }
    func clearPadParam(_ id: String) { checkpoint("padClear:\(id)", coalesce: false); padParams[id] = nil }

    /// The per-hit shaping opts for a pad, or nil if it has no inspector edits.
    func padOpts(_ id: String) -> TriggerOpts? {
        let defChoke = Kit.padByID[id]?.defaultChoke ?? 0   // e.g. open/closed hats share one out of the box (#PADS-02)
        // Finding 70: the sidechain duck key is the KICK PAD, not the "kick" voice string, so a kit or
        // sound remap of that pad keeps the pump. Carried on TriggerOpts so live and export agree.
        let scKey = (id == "kick")
        guard let pp = padParams[id] else {
            // No inspector edits, but a family default choke must still cut (open hat ↔ closed hat).
            guard defChoke != 0 || scKey else { return nil }
            var o = TriggerOpts(); o.chokeGroup = defChoke; o.sidechainKey = scKey; return o
        }
        // Priority: explicit user choke → family default → per-pad mono self-cut (reserved 100+index).
        let choke: Int
        if pp.choke != 0 { choke = pp.choke }
        else if defChoke != 0 { choke = defChoke }
        else if !pp.polyV { choke = 100 + (Kit.padByID[id]?.index ?? 0) }
        else { choke = 0 }
        return TriggerOpts(
            pitch: pp.pitch, pan: pp.pan,
            cutoff: pp.cutoff < 18000 ? pp.cutoff : nil, reso: pp.reso,
            attack: pp.attack, decay: pp.decay, sustain: pp.sustain,
            release: pp.mode == "gate" ? min(pp.release, 0.12) : pp.release,
            chokeGroup: choke,
            sidechainKey: scKey)
    }
    /// Scale a base velocity by the pad's Vel Sens (1 = responsive, 0 = always full). Default 1 → unchanged.
    func padVel(_ id: String, _ base: Double) -> Double {
        let vs = padParams[id]?.velSensV ?? 1
        return 1 - vs + base * vs
    }
    /// A pad's lay-back trigger offset in seconds (0–50 ms).
    func padOffsetSec(_ id: String) -> Double { (padParams[id]?.offsetV ?? 0) * 0.05 }
    /// Live Time-Correct humanize: random timing drift (±12 ms) and velocity drift (±18%), scaled by `humanize`.
    func humTime() -> Double { humanize > 0 ? Double.random(in: -1...1) * humanize * 0.012 : 0 }
    func humVel() -> Double { humanize > 0 ? max(0.2, 1 + Double.random(in: -1...1) * humanize * 0.18) : 1 }
    /// `padOpts` overlaid with a step's parameter locks (A8). nil only when neither exists.
    func padOpts(_ id: String, meta: StepMeta?) -> TriggerOpts? {
        let hasPL = meta.map { $0.pitch != nil || $0.cutoff != nil || $0.decay != nil || $0.pan != nil } ?? false
        // The kick pad always needs opts so its sidechainKey flag survives (finding 70).
        if padParams[id] == nil && !hasPL && id != "kick" { return nil }
        var o = padOpts(id) ?? TriggerOpts()
        if let m = meta {
            if let v = m.pitch { o.pitch = v }
            if let v = m.pan { o.pan = v }
            if let v = m.cutoff { o.cutoff = v < 18000 ? v : nil }
            if let v = m.decay { o.decay = v }
        }
        return o
    }

    /// True when the pad's imported sample applies in the CURRENT bank (F0). Sample assignments are
    /// bank-scoped — chops land on Bank C without silently replacing the Bank A/B drum kit. A nil
    /// `sampleBank` is a legacy (pre-scoping) save and keeps its old behavior: the sample plays in
    /// every bank. Live triggering, the sequencer, and export all resolve through this same check.
    func padSampleActive(_ padID: String) -> Bool {
        guard let pp = padParams[padID], pp.sampleFile != nil else { return false }
        return pp.sampleBank == nil || pp.sampleBank == bank
    }

    /// The voice id a pad should make sound with: an imported sample (active in this bank) wins, then
    /// a sound override, else the pad's own default sound. Sample ids use the "smp:" namespace.
    func soundFor(_ padID: String) -> String {
        if padSampleActive(padID) { return "smp:" + padID }
        if let s = padParams[padID]?.sound, !s.isEmpty { return s }
        return padID
    }

    /// `vel` is a 0…1 strike velocity (finger pressure). nil keeps the old fixed 0.85/accent behavior;
    /// Fixed-Velocity mode (fullLevel) always plays at 1.0 regardless (#PADS-01).
    func triggerPad(_ padID: String, accent: Bool = false, when: Double? = nil, vel: Double? = nil) {
        let g = padHitGain(padID)   // mixer fader (mute/solo) × inspector Volume — the same gain the sequencer and bounce use
        if g <= 0 { return }
        let level = fullLevel ? 1.0 : (vel ?? (accent ? 1.0 : 0.85))
        let base = padVel(padID, level)
        let off = padOffsetSec(padID)
        let when = off > 0 ? (when ?? engine.now()) + off : when    // lay-back offset
        let pp = padParams[padID]
        if bank == "D", let slot = synthBank?[padID] {
            engine.triggerSynth(slot.patch, midi: slot.midi, dur: 0.5, vel: base * g, when: when)
            return
        }
        if bank == "C", let slice = sliceBank?[padID], sample != nil {
            engine.playBuffer(offset: slice.offset, dur: slice.dur, vel: base * g, when: when,
                              pitch: pp?.pitch ?? 0, pan: pp?.pan ?? 0)
            return
        }
        engine.trigger(soundFor(padID), vel: base * g, when: when, opts: padOpts(padID))
        triggerPadLayers(padID, vel: base * g, when: when)   // stacked layers, each gated by its own bus
    }

    /// Song-Mode playback gate. A track that has NO clips authored at all plays everywhere (so a
    /// beat you made but never drew clips for isn't silently dropped — fixes the 808/bass-drop bug);
    /// once any clip exists, the track plays only where a clip covers the bar.
    func trackPlaysInSong(_ track: String, atBar bar: Int) -> Bool {
        guard let cs = clips[track], !cs.isEmpty else { return true }
        return cs.contains { bar >= $0.s && bar < $0.s + $0.l && !$0.muted }
    }

    /// The last authored bar across sections, program clips and audio clips — the minimum song length.
    var usedSongBars: Int {
        var b = arrangement.reduce(0) { max($0, $1.start + $1.len) }
        for cs in clips.values { for c in cs { b = max(b, c.s + c.l) } }
        for c in audioClips { b = max(b, c.startBar + 1) }
        return b
    }

    /// Change the arrangement length (16/32/64 bars). Never shrinks below the last authored bar,
    /// so extending is always safe and shrinking can't orphan content. Grows the song automation lane.
    func setSongBars(_ n: Int) {
        let v = min(64, max(4, max(n, usedSongBars)))
        guard v != songBars else { return }
        checkpoint("songbars", coalesce: false)
        songBars = v
        if songAuto.count < v {
            songAuto.append(contentsOf: Array(repeating: songAuto.last ?? 1, count: v - songAuto.count))
        }
    }

    // MARK: arrangement clip editing (FL-Mobile-style)

    /// Duplicate a clip to the right, landing in the next free bars (clamped to the song length).
    func duplicateClip(track: String, id: UUID) {
        guard var cs = clips[track], let c = cs.first(where: { $0.id == id }) else { return }
        checkpoint("clipdup", coalesce: false)
        let start = min(songBars - c.l, c.s + c.l)
        cs.append(Clip(s: max(0, start), l: c.l, color: c.color, muted: c.muted))
        clips[track] = cs
    }
    func deleteClip(track: String, id: UUID) {
        checkpoint("clipdel", coalesce: false)
        clips[track]?.removeAll { $0.id == id }
    }
    func toggleClipMute(track: String, id: UUID) {
        guard let i = clips[track]?.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("clipmute", coalesce: false)
        clips[track]?[i].muted.toggle()
    }
    /// Pin this clip to a pattern, or pass nil to follow the section again. Out-of-range indices are
    /// dropped rather than stored, so a clip can never reference a slot that does not exist.
    func setClipSeq(track: String, id: UUID, _ seq: Int?) {
        guard let i = clips[track]?.firstIndex(where: { $0.id == id }) else { return }
        let v = seq.flatMap { sequences.indices.contains($0) ? $0 : nil }
        guard clips[track]?[i].seq != v else { return }   // no-op → no checkpoint, no redo loss (#MIX-UNDO)
        checkpoint("clipseq", coalesce: false)
        clips[track]?[i].seq = v
    }
    func setClipLength(track: String, id: UUID, _ l: Int) {
        guard var arr = clips[track], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("cliplen", coalesce: false)
        arr[i].l = max(1, min(songBars - arr[i].s, l))
        clips[track] = arr
    }

    // MARK: time-range arrangement ops (FL-Mobile Playlist style)

    /// Remap a bar range [s, s+l) through a position map; nil if it collapses or leaves the song.
    private func remapBars(_ s: Int, _ l: Int, _ f: (Int) -> Int) -> (Int, Int)? {
        let ns = max(0, min(songBars, f(s))), ne = max(0, min(songBars, f(s + l)))
        return ne > ns ? (ns, ne - ns) : nil
    }
    /// Apply a bar-position map to every arrangement layer (program clips, sections, audio clips).
    private func applyArrangeMap(_ f: (Int) -> Int) {
        for tk in Array(clips.keys) {   // snapshot keys — don't mutate the dict while enumerating it
            clips[tk] = (clips[tk] ?? []).compactMap { c in
                remapBars(c.s, c.l, f).map { Clip(s: $0.0, l: $0.1, color: c.color, muted: c.muted) }
            }
        }
        arrangement = arrangement.compactMap { a in
            remapBars(a.start, a.len, f).map { ArrItem(id: a.id, section: a.section, start: $0.0, len: $0.1, seq: a.seq) }
        }
        audioClips = audioClips.compactMap { var c = $0; let n = f(c.startBar); guard n >= 0 && n < songBars else { return nil }; c.startBar = n; return c }
    }
    /// Insert `len` empty bars at bar `at`, pushing later content right.
    func arrangeInsertSpace(at b0: Int, len L: Int) {
        guard L > 0 else { return }
        checkpoint("arrInsert", coalesce: false)
        applyArrangeMap { $0 < b0 ? $0 : $0 + L }
    }
    /// Remove bars [at, at+len), sliding later content left to close the gap.
    func arrangeDeleteSpace(at b0: Int, len L: Int) {
        guard L > 0 else { return }
        checkpoint("arrDelete", coalesce: false)
        applyArrangeMap { $0 <= b0 ? $0 : ($0 >= b0 + L ? $0 - L : b0) }
    }
    /// Duplicate everything in [from, from+len) into the bars right after, shifting later content right.
    func arrangeDuplicate(from b0: Int, len L: Int) {
        guard L > 0 else { return }
        checkpoint("arrDup", coalesce: false)
        var clipCopies: [String: [Clip]] = [:]
        for (tk, cs) in clips {
            for c in cs {
                let s = max(c.s, b0), e = min(c.s + c.l, b0 + L)
                if e > s { clipCopies[tk, default: []].append(Clip(s: s + L, l: e - s, color: c.color, muted: c.muted)) }
            }
        }
        var arrCopies: [ArrItem] = []
        for (i, a) in arrangement.enumerated() {
            let s = max(a.start, b0), e = min(a.start + a.len, b0 + L)
            if e > s { arrCopies.append(ArrItem(id: "dup\(i)-\(a.id)", section: a.section, start: s + L, len: e - s, seq: a.seq)) }
        }
        applyArrangeMap { $0 < b0 + L ? $0 : $0 + L }   // open the gap, then drop the copies in
        for (tk, cs) in clipCopies {
            clips[tk, default: []].append(contentsOf: cs.compactMap { c in c.s >= songBars ? nil : Clip(s: c.s, l: min(c.l, songBars - c.s), color: c.color, muted: c.muted) })
        }
        arrangement.append(contentsOf: arrCopies.compactMap { $0.start >= songBars ? nil : ArrItem(id: $0.id, section: $0.section, start: $0.start, len: min($0.len, songBars - $0.start), seq: $0.seq) })
    }

    // MARK: sequences (pattern banks)

    @Published var queuedSeq: Int? = nil   // Performance mode: launch this sequence at the next bar

    /// Switch the sequence being edited — stash the live buffers, load the new one.
    /// `record` adds an undo checkpoint (skip it for live performance switches).
    func switchSequence(_ i: Int, record: Bool = true) {
        guard i != activeSeq, sequences.indices.contains(i) else { return }
        if record { checkpoint("seqswitch", coalesce: false) }
        sequences[activeSeq].lanes = lanes
        sequences[activeSeq].melody = melody
        sequences[activeSeq].stepMeta = stepMeta
        sequences[activeSeq].parts = parts
        activeSeq = i
        lanes = sequences[i].lanes
        melody = sequences[i].melody
        stepMeta = sequences[i].stepMeta
        parts = sequences[i].parts
        if !(activePart == "lead" || parts.contains { $0.id == activePart }) { activePart = "lead" }
        emit(.switchSequence(index: i))
    }
    /// The stock content a sequence slot ships with, so "has the user written this one?" is answerable.
    /// Slots A–C are seeded from named Kit patterns and D starts empty (see `init`).
    nonisolated static func seededLanes(forSeq i: Int) -> [String: [Double]] {
        switch i {
        case 0: return Kit.lanesFromSteps(Kit.pattern("boombap")?.steps ?? [])
        case 1: return Kit.lanesFromSteps(Kit.pattern("house")?.steps ?? [])
        case 2: return Kit.lanesFromSteps(Kit.pattern("trap")?.steps ?? [])
        default: return [:]
        }
    }
    /// True when a slot holds something other than the pattern it shipped with — i.e. the user put it
    /// there. Used so auto-arranging never introduces stock content the user has not heard.
    func isUserAuthored(seq i: Int) -> Bool {
        guard sequences.indices.contains(i) else { return false }
        let cur = lanesOfSeq(i).filter { $0.value.contains { $0 != 0 } }       // ignore all-zero lanes
        let seed = Project.seededLanes(forSeq: i).filter { $0.value.contains { $0 != 0 } }
        if cur != seed { return true }
        return !melodyOfSeq(i).isEmpty || !partsOfSeq(i).isEmpty              // melody/parts count as authored
    }

    /// Bars a section covers. Bars outside every section have no arranged pattern — see `sequenceIndexForBar`.
    func sectionCovers(_ bar: Int) -> Bool {
        arrangement.contains { bar >= $0.start && bar < $0.start + $0.len }
    }
    func sequenceIndexForBar(_ bar: Int) -> Int {
        if let s = arrangement.first(where: { bar >= $0.start && bar < $0.start + $0.len })?.seq { return s }
        // No section covers this bar. Falling back to `activeSeq` here made playback depend on which
        // pattern TAB was last opened on the Sequence screen — peeking at B silently changed the song
        // (SEQUENCE_TRACKS_AUDIT finding 3). In Song Mode an uncovered bar resolves to a stable slot;
        // Loop Mode has no arrangement at all and must keep following the buffer being edited.
        return songMode ? 0 : activeSeq
    }

    // MARK: pattern lookup by slot

    /// Content of a sequence slot. The ACTIVE slot reads the live edit buffer (`lanes`/`melody`/…),
    /// because that is where in-progress edits live until `switchSequence` flushes them back.
    func lanesOfSeq(_ i: Int) -> [String: [Double]] {
        (i == activeSeq || !sequences.indices.contains(i)) ? lanes : sequences[i].lanes
    }
    func melodyOfSeq(_ i: Int) -> [MelodyNote] {
        (i == activeSeq || !sequences.indices.contains(i)) ? melody : sequences[i].melody
    }
    func partsOfSeq(_ i: Int) -> [InstrumentPart] {
        (i == activeSeq || !sequences.indices.contains(i)) ? parts : sequences[i].parts
    }
    func stepMetaOfSeq(_ i: Int) -> [String: [Int: StepMeta]] {
        (i == activeSeq || !sequences.indices.contains(i)) ? stepMeta : sequences[i].stepMeta
    }

    /// The pattern a CLIP pins for its track at this bar, or nil when it follows the section.
    /// Only unmuted clips count — a muted clip is not playing, so it cannot pin anything.
    func clipSeq(track: String, atBar bar: Int) -> Int? {
        guard let cs = clips[track] else { return nil }
        guard let c = cs.first(where: { bar >= $0.s && bar < $0.s + $0.l && !$0.muted }) else { return nil }
        guard let s = c.seq, sequences.indices.contains(s) else { return nil }
        return s
    }

    /// The pattern a given TRACK plays at a bar: its clip's own pattern when it pins one, else the
    /// section's. This is the one lookup playback, bounce and MIDI export all go through, so the three
    /// can never disagree. Loop Mode ignores clips entirely (there is no arrangement to pin against).
    func sequenceIndex(track: String, atBar bar: Int) -> Int {
        if songMode, let pinned = clipSeq(track: track, atBar: bar) { return pinned }
        return sequenceIndexForBar(bar)
    }

    /// The drum lanes to play for a given bar (the active edit buffer for the active sequence).
    func lanesForBar(_ bar: Int) -> [String: [Double]] { lanesOfSeq(sequenceIndexForBar(bar)) }
    func melodyForBar(_ bar: Int) -> [MelodyNote] { melodyOfSeq(sequenceIndexForBar(bar)) }
    /// The extra instrument parts to play for a given bar (per-sequence in Song Mode).
    func partsForBar(_ bar: Int) -> [InstrumentPart] { partsOfSeq(sequenceIndexForBar(bar)) }

    /// Per-track variants — identical to the `…ForBar` lookups unless a clip pins a pattern.
    func lanesForTrack(_ track: String, atBar bar: Int) -> [String: [Double]] {
        lanesOfSeq(sequenceIndex(track: track, atBar: bar))
    }
    func melodyForTrack(_ track: String, atBar bar: Int) -> [MelodyNote] {
        melodyOfSeq(sequenceIndex(track: track, atBar: bar))
    }
    func partsForTrack(_ track: String, atBar bar: Int) -> [InstrumentPart] {
        partsOfSeq(sequenceIndex(track: track, atBar: bar))
    }
    func stepMetaForTrack(_ track: String, atBar bar: Int) -> [String: [Int: StepMeta]] {
        stepMetaOfSeq(sequenceIndex(track: track, atBar: bar))
    }

    /// Legacy tracks whose clip pins a pattern different from the section's, at this bar. Empty in the
    /// common case, which is what lets the scheduler keep its single hoisted lanes dictionary.
    func clipSeqOverrides(atBar bar: Int) -> [String: Int] {
        guard songMode, !clips.isEmpty else { return [:] }
        let base = sequenceIndexForBar(bar)
        var out: [String: Int] = [:]
        for tk in clips.keys {
            if let s = clipSeq(track: tk, atBar: bar), s != base { out[tk] = s }
        }
        return out
    }

    /// Bank is a VIEW choice (it's still persisted with the project): switching to look at Bank C must not
    /// mark the beat dirty or push an undo step (MAIN_SCREEN_AUDIT_2026-09-16 #6).
    func setBank(_ b: String) { bank = b; emit(.setBank(bank: b)) }   // emit → students' bank
    func setBpm(_ v: Int) { _ = checkpoint("bpm"); bpm = max(40, min(220, v)); emit(.setTempo(bpm: bpm)) }   // coalesced: a tap/drag is one undo step
    func setBpm(_ v: Double) { setBpm(Int(v.rounded())) }
    /// Adopt an externally-driven tempo (Ableton Link) WITHOUT a checkpoint or sync op — a moving-tempo
    /// peer would otherwise flood undo history with phantom bpm steps and spam followers each tick (#TIMING-02).
    func setBpmFromLink(_ v: Int) { bpm = max(40, min(220, v)) }

    // MARK: synth / melody

    var synthGain: Double {
        let mel = mixer["melody"] ?? MixChannel(vol: 0.85)
        return mel.vol * 1.25   // master gain is applied live by the engine (pushMasterVolume), not baked here
    }

    // MARK: Play Assist (E2 chords / E3 arpeggiator / E5 strum) — see PlayAssist.swift
    @Published private(set) var chordMode = "off"   // off | triad | 7th | power | octave
    @Published private(set) var arpMode = "off"     // off | up | down | updown | random
    @Published private(set) var arpRate = "1/16"    // 1/8 | 1/16 | 1/16T | 1/32
    @Published private(set) var arpOct = 1          // 1..3 octaves
    var assistHeld: [String: [Int]] = [:]   // keyboard key → currently-sounding midis (chord-expanded)
    var arpTimer: Timer?
    deinit { arpTimer?.invalidate() }   // a repeating arp timer would otherwise fire forever (no-op via [weak self])
    var arpIdx = 0
    var arpNextTime = 0.0   // absolute engine time of the next arp note (sample-anchored, jitter-immune)

    /// Live keyboard note-on (sustains until noteOff). Plays the current patch — or, with
    /// Play Assist on, expands to a chord and/or feeds the arpeggiator.
    /// `vel` is a 0…1 dynamics scalar (on-screen keyboard passes 1.0 → unchanged; MIDI passes the
    /// controller's velocity so soft/hard strikes differ instead of all playing at one level) (#MIDI-02).
    func synthNoteOn(_ key: String, midi: Int, vel: Double = 1.0) {
        if chordMode == "off" && arpMode == "off" {
            engine.synthOn(key, midi: midi, patch: editPatch, vel: synthGain * max(0.05, min(1, vel)))   // play the active part you're editing, not always Lead
        } else {
            assistNoteOn(key, midi, vel: vel)
        }
    }
    func synthNoteOff(_ key: String) {
        if assistHeld[key] != nil { assistNoteOff(key) } else { engine.synthOff(key) }
    }
    /// One-shot preview (roll cell tap / preset audition).
    func previewNote(midi: Int, dur: Double = 0.5) { engine.triggerSynth(editPatch, midi: midi, dur: dur, vel: synthGain) }

    func mapSynthToPads() {
        checkpoint("mapPads", coalesce: false)
        let midis = synthPadMidis()
        var bank: [String: SynthBankSlot] = [:]
        for (i, p) in Kit.pads.enumerated() { bank[p.id] = SynthBankSlot(midi: midis[i], patch: editPatch) }
        synthBank = bank
        self.bank = "D"
    }

    /// MIDI note for each Bank-D synth pad. With Scale Lock on, the pads climb the
    /// song key's scale so finger-drumming Bank D always stays in key; otherwise
    /// they map chromatically from C3.
    private func synthPadMidis() -> [Int] {
        let count = Kit.pads.count
        guard scaleLock else { return (0..<count).map { 48 + $0 } }
        return Music.scaleLadder(root: 48 + melodyKey, scaleID: melodyScale, count: count)
    }
    func loadSampleSource(_ kind: String) {
        checkpoint("synthSrc", coalesce: false)
        engine.makeSynthSample(kind)
        synthPatch.source = "sample"
        synthPatch.bufferKind = kind
        synthPatch.baseMidi = 60
        synthPatch.name = kind == "vocal" ? "Recorded Sound" : "Sampled Inst"
    }

    /// Place a note of `len` 16th-steps (1/16…1/1) at step/pitch, or toggle it off.
    /// Monophonic: a new note clears any time-overlapping notes so the melody stays a single line.
    func placeMelodyNote(step: Int, pitch: Int, len: Int) {
        checkpoint("melody", coalesce: false)
        // tapping anywhere on an existing same-pitch note removes it
        if let i = melody.firstIndex(where: { $0.pitch == pitch && step >= $0.step && step < $0.step + $0.dur }) {
            melody.remove(at: i)
            emit(.setMelodyNote(step: step, pitch: pitch, len: len, on: false))
            return
        }
        let (step, dur) = Self.boundedNote(step: step, len: len, barSteps: barSteps)   // honor the bar, not a literal 16
        let lo = step, hi = step + dur
        melody.removeAll { $0.step < hi && $0.step + $0.dur > lo }
        melody.append(MelodyNote(step: step, pitch: pitch, dur: dur, vel: step % 4 == 0 ? 0.95 : 0.8))
        emit(.setMelodyNote(step: step, pitch: pitch, len: dur, on: true))
    }

    func clearMelody() { checkpoint("clearMelody", coalesce: false); melody = [] }

    // MARK: audio clips (A5)

    /// Keep a recorded/imported performance as an arrangement clip. Returns false when its WAV could not
    /// be written — in that case NO clip is added, because a clip naming a missing take is exactly the
    /// unrecoverable-on-relaunch state this must never publish (#PERSIST-CLIP).
    @discardableResult
    func addAudioClip(track: String, startBar: Int, data: [Float], dataR: [Float]? = nil, name: String) -> Bool {
        guard !data.isEmpty else { return false }
        let sr = engine.sampleRate
        let dur = Double(data.count) / sr
        let r = (dataR?.isEmpty == false) ? dataR : nil   // treat empty right as mono
        let clip = AudioClip(track: track, startBar: max(0, min(songBars - 1, startBar)),
                             data: data, dataR: r, wave: Project.downsamplePeaks(data), name: name, durSec: dur)
        // The WAV is the take. Append the clip only once its audio is really on disk: appending regardless
        // let Save publish a snapshot naming a file that was never written, so the take was unrecoverable
        // after relaunch while the app reported success (#PERSIST-CLIP).
        guard writeClipWAV(data, id: clip.id, sr: sr) else {
            audioWriteFailed = true
            return false
        }
        if let right = r, !writeClipWAVRight(right, id: clip.id, sr: sr) {
            // A half-written stereo take is a corrupt take, not a mono one — drop the orphan left channel
            // and keep nothing rather than load it back as a silent mono edit.
            deleteClipWAV(id: clip.id)
            audioWriteFailed = true
            return false
        }
        checkpoint("addClip", coalesce: false)
        audioClips.append(clip)
        return true
    }
    func removeAudioClip(_ id: UUID) {
        checkpoint("removeClip", coalesce: false)
        audioClips.removeAll { $0.id == id }
        // WAV intentionally NOT deleted here — undo must be able to restore the recorded take.
        // The launch-time orphan sweep reclaims WAVs that no saved project references (#PERSIST-01).
    }
    /// Clip ids a restore must decode from disk: exactly those the live session does not already hold in
    /// memory. Re-using the decoded takes is what keeps a follower's 6 s fullSync restore off the WAV
    /// reader (finding 47).
    nonisolated static func clipIDsNeedingDecode(_ metas: [AudioClipMeta], cached: Set<UUID>) -> [UUID] {
        metas.compactMap { UUID(uuidString: $0.id) }.filter { !cached.contains($0) }
    }

    /// True when a restore must re-read the pad one-shots: only a changed/added/removed file reference
    /// needs I/O — equal refs mean the buffers already decoded in memory are still the right ones.
    nonisolated static func padSamplesNeedReload(decoded: [String: String], live: [String: String]) -> Bool {
        decoded != live
    }

    /// True when a restore must re-import the sampler buffer. The take is named by a UUID file, so an
    /// unchanged reference means the engine already holds exactly this audio.
    nonisolated static func samplerNeedsReload(file: String?, decoded: String?) -> Bool {
        file != decoded
    }

    func moveAudioClip(_ id: UUID, toBar bar: Int, checkpoint doCheckpoint: Bool = true) {
        if let i = audioClips.firstIndex(where: { $0.id == id }) {
            // A drag checkpoints ONCE at its start (see TrackModeView) and passes false here; per-frame
            // coalesced checkpoints only merged within 0.6s, so a slow drag left undo partway (#FUNCNAV-02).
            if doCheckpoint { checkpoint("audioMove", coalesce: false) }
            audioClips[i].startBar = max(0, min(songBars - 1, bar))
        }
    }
    /// Reconcile in-memory `audioClips` to restored (undo/redo/load/fullSync) metadata. Move/gain/mute
    /// undos reuse the in-memory audio; a re-added clip re-reads its still-on-disk WAV (deletion is
    /// deferred to the orphan sweep, so the take is always recoverable within a session). A clip whose id
    /// the session already holds is reused as-is, which is what keeps a follower's 6 s fullSync restore
    /// from re-decoding every take on the main actor. (#PERSIST-01, finding 47)
    private func restoreAudioClips(from metas: [AudioClipMeta]) {
        let byID = Dictionary(audioClips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let needDecode = Set(Self.clipIDsNeedingDecode(metas, cached: Set(byID.keys)))
        var rebuilt: [AudioClip] = []
        for m in metas {
            guard let uuid = UUID(uuidString: m.id) else { continue }
            if var existing = byID[uuid] {
                existing.startBar = m.startBar; existing.gain = m.gain; existing.muted = m.muted
                rebuilt.append(existing)
            } else if needDecode.contains(uuid), let data = readClipWAV(id: uuid, targetSR: engine.sampleRate), !data.isEmpty {
                var clip = AudioClip(track: m.track, startBar: m.startBar, data: data,
                                     dataR: readClipWAVRight(id: uuid, targetSR: engine.sampleRate),
                                     wave: Project.downsamplePeaks(data), name: m.name, durSec: Double(data.count) / engine.sampleRate)
                clip.id = uuid; clip.gain = m.gain; clip.muted = m.muted
                rebuilt.append(clip)
            }   // else: WAV genuinely gone (shouldn't happen mid-session) → drop, matching repaired()
        }
        audioClips = rebuilt
    }

    // MARK: pad sample import (Pad Inspector → Sound → Import)

    /// Assign a decoded one-shot to a pad: persist a WAV, register it with the engine,
    /// keep a copy in memory for offline export, and point the PadParam at it.
    /// `bank` scopes where the sample plays (F0); nil = every bank (legacy behavior).
    func setPadSample(_ padID: String, data: [Float], name: String, bank: String?) {
        guard !data.isEmpty else { return }
        checkpoint("padSample:\(padID)", coalesce: false)
        applyPadSample(padID, data: data, name: name, bank: bank)
    }
    /// The pad-sample assignment work WITHOUT an undo checkpoint, so batch ops (chop-to-pads)
    /// can collapse to a single undo step. Returns false (and assigns nothing) when the WAV could not be
    /// written — pointing a pad at a file that does not exist silently loses the sound and would make the
    /// next Save refuse the project (#PERSIST-CLIP).
    @discardableResult
    private func applyPadSample(_ padID: String, data: [Float], name: String, bank: String?) -> Bool {
        // Old pad WAV intentionally kept — an undo snapshot may still reference it. The orphan sweep
        // reclaims WAVs no saved project references; deleting here destroyed the take on undo (#PERSIST-02).
        let file = UUID().uuidString + ".wav"
        guard writePadSampleWAV(data, file: file, sr: engine.sampleRate) else {
            audioWriteFailed = true
            return false
        }
        padSampleData[padID] = data
        engine.registerPadSample(padID, data)
        var p = padParams[padID] ?? PadParam()
        p.sampleFile = file; p.sampleName = String(name.prefix(24)); p.sound = nil; p.sampleBank = bank
        padParams[padID] = p
        decodedPadSampleRefs[padID] = file   // now decoded — a restore of this state re-reads nothing
        return true
    }

    /// Assign several pads' one-shots as ONE undo step (stem split / multi-pad ops) — was N separate
    /// checkpoints, one per pad. Empty buffers are skipped.
    func setPadSamples(_ items: [(id: String, data: [Float], name: String)], bank: String?) {
        let real = items.filter { !$0.data.isEmpty }
        guard !real.isEmpty else { return }
        checkpoint("padSamples", coalesce: false)
        for it in real { applyPadSample(it.id, data: it.data, name: it.name, bank: bank) }
    }

    func operationDestination() -> ProjectOperationDestination {
        ProjectOperationDestination(projectID: projectID, bank: bank, revision: contentRevision)
    }
    /// Bumped by `mutateSample`, `applyState` and `clearAll` — the events that invalidate an in-flight
    /// sample operation. Plain edits do not move it.
    private(set) var contentRevision: UInt64 = 0
    nonisolated static func discardPreparedPadSamples(_ items: [PreparedPadSample]) {
        for item in items { deletePadSampleWAV(file: item.file) }
    }

    nonisolated static func preparePadSamples(_ items: [(id: String, data: [Float], name: String)], sampleRate: Double) async -> [PreparedPadSample] {
        await Task.detached(priority: .utility) {
            items.compactMap { item in
                guard !item.data.isEmpty else { return nil }
                let file = UUID().uuidString + ".wav"
                guard writePadSampleWAV(item.data, file: file, sr: sampleRate) else { return nil }
                return PreparedPadSample(id: item.id, data: item.data, name: item.name, file: file)
            }
        }.value
    }

    @discardableResult
    func commitPreparedPadSamples(_ prepared: [PreparedPadSample], bank: String?, destination: ProjectOperationDestination? = nil) -> Int {
        if let destination, !destination.matches(self) {
            Self.discardPreparedPadSamples(prepared)
            return 0
        }
        guard !prepared.isEmpty else { return 0 }
        checkpoint("padSamples", coalesce: false)
        for item in prepared {
            padSampleData[item.id] = item.data
            engine.registerPadSample(item.id, item.data)
            var p = padParams[item.id] ?? PadParam()
            p.sampleFile = item.file; p.sampleName = String(item.name.prefix(24)); p.sound = nil; p.sampleBank = bank
            padParams[item.id] = p
            decodedPadSampleRefs[item.id] = item.file
        }
        return prepared.count
    }

    /// Nearest sign change in `buf` within ±`maxOff` samples of `idx` (zero-cross snap, SAMPLING-04) —
    /// cutting on a crossing keeps chop/trim edges click-free. Returns the clamped `idx` when no
    /// crossing is found. nonisolated: pure math, callable from detached render work.
    nonisolated static func nearestZeroCross(_ buf: [Float], near idx: Int, within maxOff: Int) -> Int {
        let i0 = max(0, min(buf.count - 1, idx))
        guard buf.count > 1, maxOff > 0 else { return i0 }
        for off in 0...maxOff {
            for cand in (off == 0 ? [i0] : [i0 - off, i0 + off]) where cand > 0 && cand < buf.count {
                if (buf[cand - 1] < 0) != (buf[cand] < 0) { return cand }
            }
        }
        return i0
    }

    /// Chop the current sample buffer into per-pad one-shots, so the chops are playable in the
    /// step sequencer AND included in export — fixing the bank-C-only `sliceBank` dead-end where
    /// recorded/sequenced chops silently played the pad's drum voice (#26/#28/#118). One undo step.
    @discardableResult
    func assignSlicesToPads(buffer: [Float], slices: [Double], reverse: Bool, mirror: Bool = false) -> Int {
        guard !buffer.isEmpty, !slices.isEmpty else { return 0 }
        checkpoint("assignChops", coalesce: false)
        sliceBank = nil   // supersede the legacy live-only slice bank — chops are real pad samples now
        let count = slices.count
        var assigned = 0
        let zc = Int(0.005 * engine.sampleRate)   // ±5 ms zero-cross snap window (SAMPLING-04)
        for (i, p) in Kit.pads.enumerated() {
            if i >= count { break }
            let si = reverse ? (count - 1 - i) : i
            let a0 = slices[si]
            let b0 = si + 1 < count ? slices[si + 1] : 1
            // A baked Reverse tool flips the audio but slices were detected on the forward buffer —
            // mirror each window so the cut lands where the transient actually is (F3).
            let (a, b) = mirror ? (1 - b0, 1 - a0) : (a0, b0)
            var lo = max(0, min(buffer.count, Int(a * Double(buffer.count))))
            var hi = max(lo, min(buffer.count, Int(b * Double(buffer.count))))
            if lo > 0 { lo = Self.nearestZeroCross(buffer, near: lo, within: zc) }             // interior edges only —
            if hi < buffer.count { hi = Self.nearestZeroCross(buffer, near: hi, within: zc) }  // 0 and end ARE boundaries
            guard hi > lo else { continue }
            // Count only chops whose WAV actually landed on disk (chops live on Bank C only, F0).
            if applyPadSample(p.id, data: Array(buffer[lo..<hi]), name: "Chop \(si + 1)", bank: "C") { assigned += 1 }
        }
        return assigned
    }

    /// Resample (MPC-style): bounce the current pattern — drums + melody + parts + FX —
    /// to a new one-shot sample on `padID`, exactly `bars` long so it loops seamlessly.
    /// You can then chop it, retune it, or play it like any pad sample: the core MPC loop.
    func resampleToPad(_ padID: String, bars: Int = 1, name: String = "Resample") async {
        let targetBank = bank   // scope the bounce to the bank it was resampled in (F0); bank may change mid-render
        let plan = buildExportPlan(loopBarsOverride: bars)
        isBouncing = true; defer { isBouncing = false }
        let (l, r) = await Task.detached { renderOffline(plan) }.value   // off the main actor so the UI stays live (#ARCH-01)
        guard !l.isEmpty else { return }
        let barSec = Double(max(1, barSteps)) * (60.0 / Double(bpm)) / 4.0
        let frames = max(1, Int((Double(bars) * barSec * engine.sampleRate).rounded()))   // exact bar length → seamless loop
        var mono = [Float](repeating: 0, count: frames)   // pads with silence to the bar line; truncates any tail past it
        var peak: Float = 0
        for i in 0..<min(frames, l.count) { let v = (l[i] + r[i]) * 0.5; mono[i] = v; peak = max(peak, abs(v)) }
        if peak > 1 { for i in mono.indices { mono[i] /= peak } }   // guard inter-sum clipping
        setPadSample(padID, data: mono, name: name, bank: targetBank)
    }

    /// One-knob auto-master (D2, heuristic — no ML): bounce the current beat, measure its loudness +
    /// spectral tilt, then set the master gain toward a target, add a gentle multiband "glue" + a small
    /// corrective high-shelf, and arm the limiter so the louder result can't clip. Returns a summary for
    /// the UI, or nil if there's nothing to analyze. Undoable (master fader + master-bus checkpoints).
    @discardableResult
    func autoMaster() async -> String? {
        let plan = buildExportPlan()
        isBouncing = true; defer { isBouncing = false }
        let (l, r) = await Task.detached { renderOffline(plan) }.value   // off the main actor (#ARCH-01)
        let n = min(l.count, r.count)
        guard n > 1000 else { return nil }
        let coef = exp(-2.0 * .pi * 2000.0 / engine.sampleRate)   // ~2 kHz split for a coarse low/high balance
        var sumSq = 0.0, lowSq = 0.0, highSq = 0.0, lp = 0.0
        for i in 0..<n {
            let s = Double((l[i] + r[i]) * 0.5)
            sumSq += s * s
            lp = coef * lp + (1 - coef) * s
            let hi = s - lp
            lowSq += lp * lp; highSq += hi * hi
        }
        let rms = (sumSq / Double(n)).squareRoot()
        let rmsDb = 20 * log10(max(1e-6, rms))
        let gainDb = max(-9.0, min(9.0, -12.0 - rmsDb))                 // aim ≈ −12 dBFS RMS, clamped
        let bright = highSq / max(1e-9, lowSq)
        let highShelf = max(-3.0, min(3.0, (0.45 - bright) * 8))        // dark → boost highs, bright → tame
        setMix("master") { $0.vol = max(0.1, min(1.5, $0.vol * pow(10, gainDb / 20))) }   // setMix checkpoints (undoable)
        setMasterBus("auto") { mb in
            mb.limiterOn = true; mb.ceiling = -1.0
            mb.mbOn = true                                             // gentle multiband glue
            mb.eqOn = true; mb.high = highShelf
        }
        return String(format: "Auto-mastered · %+.1f dB · limiter on%@", gainDb,
                      abs(highShelf) > 0.3 ? String(format: " · high %+.1f dB", highShelf) : "")
    }

    /// Remove an imported sample from a pad (reverts to its synth / override sound).
    func clearPadSampleFor(_ padID: String) {
        // WAV kept for undo; orphan sweep reclaims it later (#PERSIST-02).
        padSampleData[padID] = nil
        decodedPadSampleRefs[padID] = nil
        engine.clearPadSample(padID)
        setPadParam(padID) { $0.sampleFile = nil; $0.sampleName = nil; $0.sampleBank = nil }
    }

    /// Choose a built-in synth sound for a pad (clears an imported sample only when that sample is
    /// audible in the current bank — picking a Bank A sound must not destroy a Bank C chop, F0).
    func setPadSound(_ padID: String, _ sound: String?) {
        if padSampleActive(padID) { clearPadSampleFor(padID) }
        setPadParam(padID) { $0.sound = sound }
        activeKit = ""   // a manual swap means the loaded kit no longer matches → "Custom"
    }

    /// Remap every pad's sound from a `padID → sound` map (imported samples are kept untouched).
    private func applySoundMap(_ sounds: [String: String]) {
        for pad in Kit.pads {
            if padSampleActive(pad.id) { continue }   // don't stomp a sample that's audible in this bank
            let snd = sounds[pad.id]
            let override = (snd != nil && snd != pad.sound) ? snd : nil
            if var p = padParams[pad.id] {
                p.sound = override
                padParams[pad.id] = (p == PadParam()) ? nil : p   // drop now-default params
            } else if override != nil {
                var p = PadParam(); p.sound = override; padParams[pad.id] = p
            }
        }
    }

    /// Apply a built-in drum-kit preset. One checkpoint → single undo step.
    func applyDrumKit(_ id: String) {
        guard let kit = Kit.drumKits.first(where: { $0.id == id }) else { return }
        checkpoint("kit:\(id)", coalesce: false)
        applySoundMap(kit.sounds)
        activeKit = id
    }

    /// Apply a user-saved kit (its sound map). Highlighted as "user:<id>".
    func applyUserKit(_ id: String, _ sounds: [String: String]) {
        checkpoint("userkit:\(id)", coalesce: false)
        applySoundMap(sounds)
        activeKit = "user:\(id)"
    }

    /// Capture the current per-pad sound overrides (skipping defaults & samples) for saving as a kit.
    func currentPadSounds() -> [String: String] {
        var m: [String: String] = [:]
        for pad in Kit.pads {
            guard let pp = padParams[pad.id], !padSampleActive(pad.id), let s = pp.sound, s != pad.sound else { continue }
            m[pad.id] = s
        }
        return m
    }

    /// Re-register imported pad samples with the engine after a project load — and only the ones whose
    /// assignment actually moved. Pads whose `sampleFile` is unchanged and still decoded are left alone: a
    /// follower's 6 s fullSync used to re-read every one-shot WAV on the main actor (and lose a sample whose
    /// file was not on that device) (finding 47), and an undo that changed ONE pad still cleared every
    /// registration and re-decoded the whole bank, so the cost grew with the total size of every assigned
    /// sample instead of the one that changed (finding 71).
    func loadPadSamples() {
        let live = Self.padSampleFileRefs(padParams)
        guard Self.padSamplesNeedReload(decoded: decodedPadSampleRefs, live: live) else { return }
        let plan = Self.padSampleReloadPlan(decoded: decodedPadSampleRefs, live: live)
        for padID in plan.drop {
            engine.clearPadSample(padID)
            padSampleData[padID] = nil
        }
        for padID in plan.load {
            guard let file = live[padID],
                  let data = readPadSampleWAV(file: file, targetSR: engine.sampleRate), !data.isEmpty else { continue }
            padSampleData[padID] = data
            engine.registerPadSample(padID, data)
        }
        // Only what actually decoded counts as decoded: a pad whose WAV read back empty stays pending so
        // the next load retries it instead of being a silent, never-reported pad forever (#persist-8).
        decodedPadSampleRefs = live.filter { padSampleData[$0.key] != nil }
    }

    /// pad id → the one-shot WAV it currently decodes. Kept in lock-step with `padSampleData` /
    /// `engine.registerPadSample` so a restore can tell an unchanged assignment (reuse the buffer) from a
    /// real edit (re-read the file). (finding 47)
    nonisolated static func padSampleFileRefs(_ params: [String: PadParam]) -> [String: String] {
        var m: [String: String] = [:]
        for (id, pp) in params { if let f = pp.sampleFile { m[id] = f } }
        return m
    }
    private var decodedPadSampleRefs: [String: String] = [:]
    /// The sampler take the engine currently holds, so `loadSampleAudio` can skip an unchanged reference.
    private var decodedSamplerFile: String?

    /// Which pad registrations a reload must touch, given what the engine already decoded and what the
    /// project now points at. Only pads whose assignment moved (or went away) appear — every other pad
    /// keeps the PCM the engine already holds, so one changed assignment costs one WAV read (finding 71).
    nonisolated static func padSampleReloadPlan(decoded: [String: String],
                                                live: [String: String]) -> (drop: [String], load: [String]) {
        var drop: [String] = [], load: [String] = []
        for (padID, file) in decoded where live[padID] != file { drop.append(padID) }
        for (padID, file) in live where decoded[padID] != file { load.append(padID) }
        return (drop.sorted(), load.sorted())
    }

    /// Write the sampler's pristine buffer to disk and stamp the SampleState with its filename.
    /// Call right before an explicit disk save (NOT on every undo checkpoint).
    func savePayload() -> ProjectSavePayload {
        var snap = snapshot()
        let data = sample == nil ? [] : engine.currentSampleOriginal()
        if !data.isEmpty { snap.sample?.audioFile = UUID().uuidString + ".wav" }
        return ProjectSavePayload(snapshot: snap, samplerAudio: data, sampleRate: engine.sampleRate)
    }
    /// On disk-load, push the saved sample buffer back into the engine and re-apply its tools. The take is
    /// a UUID-named file, so an unchanged reference means the engine already holds exactly this audio and
    /// the 6 s fullSync must not re-decode the whole buffer. (finding 47)
    func loadSampleAudio() {
        guard let s = sample else { decodedSamplerFile = nil; return }
        guard Self.samplerNeedsReload(file: s.audioFile, decoded: decodedSamplerFile) else { return }
        guard let file = s.audioFile, let data = readPadSampleWAV(file: file, targetSR: engine.sampleRate), !data.isEmpty else { return }
        _ = engine.importBuffer(data)   // sets engine original + data, recomputes wave
        let edits = (s.tools["normalize"] ?? false) || (s.tools["reverse"] ?? false)
            || (s.tools["fadeIn"] ?? false) || (s.tools["fadeOut"] ?? false) || abs(s.gain - 1) > 0.001
        if edits {
            _ = engine.applySampleEdits(reverse: s.tools["reverse"] ?? false, normalize: s.tools["normalize"] ?? false,
                                        fadeIn: s.tools["fadeIn"] ?? false, fadeOut: s.tools["fadeOut"] ?? false, gain: s.gain)
        }
        decodedSamplerFile = file
    }
    func updateAudioClip(_ id: UUID, _ mutate: (inout AudioClip) -> Void) {
        if let i = audioClips.firstIndex(where: { $0.id == id }) {
            checkpoint("audioEdit:\(id)", coalesce: true)   // coalesce gain-slider drags into one step
            mutate(&audioClips[i])
        }
    }
    static func downsamplePeaks(_ data: [Float], buckets: Int = 200) -> [Float] {
        guard !data.isEmpty else { return [] }
        let per = max(1, data.count / buckets)
        var out: [Float] = []; out.reserveCapacity(buckets + 1)
        var i = 0
        while i < data.count {
            var mx: Float = 0, j = 0
            while j < per && i + j < data.count { mx = max(mx, abs(data[i + j])); j += 1 }
            out.append(mx); i += per
        }
        return out
    }

    func generateMelody(checkpoint doCheckpoint: Bool = true) {
        if doCheckpoint { checkpoint("genMelody", coalesce: false) }   // undoable except the first-view auto-fill
        let base = 60 + melodyKey + 12 * melodyOctave
        let ladder = Music.scaleLadder(root: base, scaleID: melodyScale)

        let density = melodyDensity == "sparse" ? 0.42 : (melodyDensity == "busy" ? 0.85 : 0.62)
        var onsets = [Bool](repeating: false, count: 16)
        onsets[0] = true
        for s in 1..<16 {
            let beat = s % 4 == 0
            let pr = beat ? min(1, density + 0.2) : (s % 2 == 0 ? density : density * 0.55)
            onsets[s] = Double.random(in: 0..<1) < pr
        }
        let onsetSteps = (0..<16).filter { onsets[$0] }

        var idx = 0
        var notes: [MelodyNote] = []
        for (k, s) in onsetSteps.enumerated() {
            if k == 0 {
                idx = 0
            } else {
                let r = Double.random(in: 0..<1)
                let move: Int
                if r < 0.55 { move = Bool.random() ? 1 : -1 }
                else if r < 0.8 { move = Bool.random() ? 2 : -2 }
                else if r < 0.92 { move = 0 }
                else { move = [3, -3, 4, -4].randomElement() ?? 3 }
                idx = max(0, min(ladder.count - 1, idx + move))
            }
            let nextS = k + 1 < onsetSteps.count ? onsetSteps[k + 1] : 16
            let dur = max(1, min(4, nextS - s))
            notes.append(MelodyNote(step: s, pitch: ladder[idx], dur: dur, vel: s % 4 == 0 ? 0.95 : 0.78))
        }
        melody = notes
    }

    // MARK: FX automation (A11)

    func setAutoTarget(_ t: String) {
        guard t != autoTarget else { return }   // re-tapping the same target must not re-seed (wipe) the drawn curve
        checkpoint("autoTarget", coalesce: false)   // switching re-seeds autoLane — make that undoable (was silent loss)
        engine.resetAutomation()   // clear any stale overrides when switching or turning off
        autoTarget = t
        // seed a sensible starting curve: filter open (no effect), reverb/delay dry
        if t == "filter" { autoLane = Array(repeating: 1, count: 16) }
        else if t == "reverb" || t == "delay" { autoLane = Array(repeating: 0, count: 16) }
    }
    func setAutoStep(_ i: Int, _ v: Double) {
        guard autoLane.indices.contains(i) else { return }
        checkpoint("autoLane", coalesce: true)   // coalesce a draw stroke into one undo step
        autoLane[i] = max(0, min(1, v))
    }
    func clearAuto() { checkpoint("clearAuto", coalesce: false); autoLane = Array(repeating: 1, count: 16) }

    /// True when there's anything to render — guards Export against bouncing silence (#275). Shared by the
    /// Tracks export button and the level-independent rail Share action so Export is reachable at every level.
    var hasExportableContent: Bool {
        lanes.values.contains { $0.contains { $0 != 0 } }
            || !audioClips.isEmpty || !melody.isEmpty || !parts.isEmpty
            || tracks.contains { $0.playsAdditively }
    }

    // Song-wide automation (Tracks Tier 3)
    func setSongAutoTarget(_ t: String) {
        guard t != songAutoTarget else { return }        // idempotent, like setAutoTarget
        checkpoint("songAutoTarget", coalesce: false)   // re-seeding songAuto is undoable
        engine.resetAutomation()                         // switching filter→reverb must not leave cutoff pinned
        songAutoTarget = t
        if t == "filter" { songAuto = Array(repeating: 1, count: songBars) }
        else if t == "reverb" || t == "delay" { songAuto = Array(repeating: 0, count: songBars) }
    }
    func setSongAutoBar(_ i: Int, _ v: Double) {
        guard songAuto.indices.contains(i) else { return }
        checkpoint("songAutoLane", coalesce: true)
        songAuto[i] = max(0, min(1, v))
    }
    /// Interpolated automation value at `bar` + fraction through it (smooth bar-to-bar ramp).
    func songAutoValue(bar: Int, frac: Double) -> Double {
        guard !songAuto.isEmpty else { return 1 }
        let a = songAuto[min(songAuto.count - 1, max(0, bar))]
        let b = songAuto[min(songAuto.count - 1, max(0, bar + 1))]
        return a + (b - a) * max(0, min(1, frac))
    }

    // MARK: persistence (snapshot / restore)

    /// Capture the full editable state into a Codable snapshot.
    /// (The live sample buffer isn't serialized — only the musical arrangement.)
    func snapshot() -> ProjectSnapshot {
        if sequences.indices.contains(activeSeq) {   // fold live edits into the active sequence first
            sequences[activeSeq].lanes = lanes
            sequences[activeSeq].melody = melody
            sequences[activeSeq].stepMeta = stepMeta
            sequences[activeSeq].parts = parts
        }
        var snap = ProjectSnapshot(
            name: name, bpm: bpm, swing: swing, quantize: quantize, barSteps: barSteps, bank: bank, fullLevel: fullLevel,
            lanes: lanes, selectedRow: selectedRow, rowMute: rowMute, rowSolo: rowSolo,
            sequences: sequences, activeSeq: activeSeq, mixer: mixer,
            arrangement: arrangement, clips: clips, trackMute: trackMute, trackSolo: trackSolo, songMode: songMode,
            melody: melody, melodyKey: melodyKey, melodyScale: melodyScale, melodyOctave: melodyOctave,
            melodyDensity: melodyDensity, scaleLock: scaleLock, rollLen: rollLen,
            synthPatch: synthPatch, savedSynths: savedSynths, padParams: padParams, synthBank: synthBank,
            fxSettings: fxSettings, channelFX: channelFX, masterBus: masterBus, stepMeta: stepMeta,
            autoTarget: autoTarget, autoLane: autoLane, songAutoTarget: songAutoTarget, songAuto: songAuto,
            audioClips: audioClips.map {
                AudioClipMeta(id: $0.id.uuidString, track: $0.track, startBar: $0.startBar,
                              name: $0.name, gain: $0.gain, muted: $0.muted, durSec: $0.durSec,
                              isStereo: $0.isStereo)
            }, activeKit: activeKit, sample: sample, sliceBank: sliceBank, parts: parts, activePart: activePart,
            chordMode: chordMode, arpMode: arpMode, arpRate: arpRate, arpOct: arpOct, humanize: humanize, grooveID: grooveID,
            tracks: tracks, melodyMuted: melodyMuted, countIn: countIn, metronome: metronome)
        snap.sampleBufferToken = pendingBufferToken
        snap.punchInBar = punchInBar
        snap.id = projectID
        snap.songBars = songBars
        return snap
    }

    /// Every audio asset filename the live session can still reach: the current arrangement plus every
    /// undo/redo restore point. The store's launch sweep keeps a 24h grace for exactly these (undo restores
    /// a removed clip by re-reading its WAV — #PERSIST-01/02), so an immediate reclaim after a delete must
    /// be told about them explicitly or it would delete the audio out from under Undo.
    var liveAssetFilenames: Set<String> {
        var out = Set<String>()
        func collect(_ s: ProjectSnapshot) {
            for c in s.audioClips ?? [] { out.insert("\(c.id).wav"); out.insert("\(c.id).R.wav") }
            for (_, pp) in s.padParams { if let f = pp.sampleFile { out.insert(f) } }
            if let f = s.sample?.audioFile { out.insert(f) }
        }
        collect(snapshot())
        for s in undoStack { collect(s) }
        for s in redoStack { collect(s) }
        return out
    }

    /// Load a project snapshot (e.g. from disk). Resets the sample buffer and
    /// clears undo history — this is a fresh project, not an edit.
    func restore(_ s: ProjectSnapshot, keepHistory: Bool = false) {
        applyState(s, resetSample: true)
        // Everything is reconciled against what the live session already holds, so a restore of UNCHANGED
        // state (the follower's 6 s fullSync) re-reads no WAVs: re-decoding every take and pad one-shot on
        // the main actor stalled the scheduler, and a take whose file was not on this device was dropped
        // even though its audio was in memory. (finding 47)
        restoreAudioClips(from: s.audioClips ?? [])   // load is a full project switch (not undo)
        loadPadSamples()                              // re-register imported pad one-shots with the engine
        loadSampleAudio()                             // restore the sampler buffer + Bank C slices
        rebuildSynthSampleSource()   // (#undo-1) the PCM behind a "sample" synth source lives only in the engine
        if !keepHistory {
            clearUndoHistory()
            hasUnsavedChanges = false              // a freshly-loaded project is clean
        }
    }

    /// A "sample" synth source persists only its descriptor. Copy the sampler buffer into the synth when one
    /// is actually loaded in the engine (not merely described by the snapshot — a swept WAV or a peer's
    /// fullSync has none), else synthesize the named demo buffer. Silent reloads were the original bug.
    func rebuildSynthSampleSource() {
        guard synthPatch.source == "sample" else { return }
        // "sampler" = the buffer came from the Sample tab ("To Synth Keys"); anything else names a synthesized
        // kind (chop/vocal…) that must be regenerated, never overwritten by the sampler's contents (round 3, undo-1).
        if synthPatch.bufferKind == "sampler" {
            if !engine.currentSampleData().isEmpty { engine.sampleToSynth() }
        } else {
            engine.makeSynthSample(synthPatch.bufferKind)
        }
    }

    /// Record-start bar for the next take (checkpointed + persisted; the old direct writes were neither).
    func setPunchInBar(_ b: Int) {
        let nb = max(0, min(max(0, songBars - 1), b))
        guard nb != punchInBar else { return }
        checkpoint("punchIn", coalesce: true)
        punchInBar = nb
    }

    /// Mark the project clean (called after a successful disk save).
    /// Published so views that hold a *copy* of project state (the Free piano-roll editor's note model)
    /// can resync when the notes change from any source — undo/redo, Clear, project load (#FREEROLL-STALE).
    @Published private(set) var editRevision: UInt64 = 0
    func markSaved() { hasUnsavedChanges = false }

    // MARK: sampler-buffer undo (#19)

    private func trimSampleRing() {
        // Evict from the MIDDLE (index 1), preserving the OLDEST entry — the pre-edit baseline, i.e. the
        // original imported buffer — and the most-recent ones. So "undo all the way back to the import"
        // always restores real audio even after many edits; only intermediate states degrade (and that
        // degrades gracefully — restoreSampleBufferToken no-ops on a missing token). Was removeFirst(),
        // which dropped the oldest and silently lost the original.
        while sampleBufferRing.count > sampleBufferRingCap && sampleBufferRing.count > 1 {
            sampleBufferRing.remove(at: 1)
        }
        var frames = sampleBufferRing.reduce(0) { $0 + $1.buffer.count }
        while frames > sampleBufferRingMaxFrames && sampleBufferRing.count > 1 {
            frames -= sampleBufferRing[1].buffer.count
            sampleBufferRing.remove(at: 1)
        }
    }
    /// Run a destructive/tool sampler edit as ONE undo step, capturing the engine's pre-edit
    /// `sampleOriginal` so undo/redo can restore the AUDIO, not just SampleState.
    func mutateSample(_ key: String, coalesce: Bool = false, _ body: () -> Void) {
        contentRevision &+= 1   // the sampler buffer is about to change → in-flight sample ops must not commit
        guard sample != nil else {
            // First sample into a blank project: there's no pre-edit buffer to capture, but this MUST
            // still checkpoint so the project is marked dirty (autosave gates on it) and the take is
            // undoable — otherwise the very first recording/import was lost on background/crash (#SAMPLING-01).
            checkpoint("smp:\(key)", coalesce: false)
            body()
            return
        }
        let token = nextBufferToken; nextBufferToken += 1
        pendingBufferToken = token
        let pushed = checkpoint("smp:\(key)", coalesce: coalesce)   // snapshot() stamps pendingBufferToken
        pendingBufferToken = nil
        if pushed {   // only capture a buffer for a real new undo step (coalesced drags reuse the first)
            let pre = engine.currentSampleOriginal()
            if !pre.isEmpty { sampleBufferRing.append((key: "\(token)", buffer: pre)); trimSampleRing() }
        }
        body()
    }
    /// After applyState restores a snapshot, re-sync the engine sample buffer to match the restored
    /// SampleState — mirrors the proven loadSampleAudio() path (importBuffer + tools). No-ops if the
    /// buffer was evicted from the ring (degrades to prior behavior; never crashes).
    private func restoreSampleBufferToken(_ token: Int?) {
        guard let token, let entry = sampleBufferRing.first(where: { $0.key == "\(token)" }), let s = sample else { return }
        _ = engine.importBuffer(entry.buffer)
        let edits = (s.tools["normalize"] ?? false) || (s.tools["reverse"] ?? false)
            || (s.tools["fadeIn"] ?? false) || (s.tools["fadeOut"] ?? false) || abs(s.gain - 1) > 0.001
        if edits {
            _ = engine.applySampleEdits(reverse: s.tools["reverse"] ?? false, normalize: s.tools["normalize"] ?? false,
                                        fadeIn: s.tools["fadeIn"] ?? false, fadeOut: s.tools["fadeOut"] ?? false, gain: s.gain)
        }
    }

    /// Apply a snapshot to the live state. Shared by load and by undo/redo;
    /// `resetSample` is true only on load (undo keeps the loaded sample around).
    private func applyState(_ s: ProjectSnapshot, resetSample: Bool) {
        editRevision &+= 1
        isApplyingState = true
        defer { isApplyingState = false }
        // Clamp numeric fields from the snapshot (corrupt save / malformed fullSync): an unclamped bpm: 0 →
        // div-by-zero transport, and barSteps > 16 → the 16-element lanes crash on record. (activeSeq below
        // is already clamped this way.)
        name = s.name; bpm = max(40, min(220, s.bpm)); swing = max(0, min(0.6, s.swing)); quantize = s.quantize
        barSteps = max(1, min(16, s.barSteps ?? 16)); bank = s.bank; fullLevel = s.fullLevel
        projectID = s.id ?? UUID().uuidString   // un-migrated (nil-id) saves become id-stable for this session (#219)
        selectedRow = s.selectedRow; rowMute = s.rowMute; rowSolo = s.rowSolo
        sequences = s.sequences
        activeSeq = s.sequences.isEmpty ? 0 : max(0, min(s.activeSeq, s.sequences.count - 1))
        mixer = s.mixer.mapValues { $0.sanitized() }   // never trust a file/peer with the master gain (#cross-2)
        pushMasterVolume()   // restore the live engine master from the loaded master fader (was launch-only 0.9)
        contentRevision &+= 1   // a whole-project swap invalidates in-flight sample operations
        engine.resetAutomation()   // undo/redo across an automation edit must not leave the swept FX applied (#undo-4)
        songBars = max(4, min(64, s.songBars ?? 16))
        punchInBar = max(0, min(max(0, songBars - 1), s.punchInBar ?? 0))   // after songBars: clamp against the INCOMING length
        arrangement = s.arrangement; clips = s.clips; trackMute = s.trackMute; trackSolo = s.trackSolo; songMode = s.songMode
        melodyKey = s.melodyKey; melodyScale = s.melodyScale; melodyOctave = s.melodyOctave; melodyDensity = s.melodyDensity
        scaleLock = s.scaleLock; rollLen = s.rollLen
        autoTarget = s.autoTarget ?? ""; autoLane = s.autoLane ?? Array(repeating: 1, count: 16)
        songAutoTarget = s.songAutoTarget ?? ""; songAuto = s.songAuto ?? Array(repeating: 1, count: songBars)
        synthPatch = s.synthPatch.validated(); savedSynths = s.savedSynths.map { $0.validated() }; padParams = s.padParams; synthBank = s.synthBank
        activePart = s.activePart ?? "lead"
        chordMode = s.chordMode ?? "off"; arpMode = s.arpMode ?? "off"; arpRate = s.arpRate ?? "1/16"; arpOct = s.arpOct ?? 1
        humanize = s.humanize ?? 0
        grooveID = s.grooveID ?? "straight"
        activeKit = s.activeKit ?? "classic"
        fxSettings = s.fxSettings ?? MasterFX()
        channelFX = s.channelFX ?? [:]
        masterBus = s.masterBus ?? MasterBus()
        // migration: v1 saves (and fresh) have no tracks → seed the 6 legacy lanes so nothing changes
        if let t = s.tracks, !t.isEmpty { tracks = t } else { tracks = Project.seedTracks() }
        melodyMuted = s.melodyMuted ?? false
        countIn = s.countIn ?? 0
        metronome = s.metronome ?? false
        // make the live buffers match the active sequence
        if sequences.indices.contains(activeSeq) {
            lanes = sequences[activeSeq].lanes
            melody = sequences[activeSeq].melody
            stepMeta = sequences[activeSeq].stepMeta
            // old saves: per-sequence parts are empty → fall back to the global parts list
            parts = sequences[activeSeq].parts.isEmpty ? (s.parts ?? []) : sequences[activeSeq].parts
        } else {
            lanes = s.lanes; melody = s.melody; stepMeta = s.stepMeta ?? [:]; parts = s.parts ?? []
        }
        sample = s.sample; sliceBank = s.sliceBank   // always restore SampleState (undo of sampler edits); engine buffer re-synced in undo/redo for destructive ops (#19)
        // undo/redo must also restore the arrangement's audio clips (restore() does the same for load,
        // reusing any take the session already decoded). Without this, undoing an add/remove/move left
        // audioClips untouched (#PERSIST-01).
        if !resetSample { restoreAudioClips(from: s.audioClips ?? []) }
        pushChannelFX()   // re-sync the engine bus pool to busOrder now that `tracks` is set (G3 owned buses)
    }

    // MARK: undo / redo

    /// Record a restore point capturing the state *before* an edit. Call at the
    /// top of a mutation. Rapid repeats of the same `key` (a drag, a paint
    /// stroke) coalesce into a single undo step.
    @discardableResult
    func checkpoint(_ key: String, coalesce: Bool = true) -> Bool {
        if isApplyingState { return false }   // restoring a snapshot (undo/redo/load) is not itself an edit
        if !hasUnsavedChanges { hasUnsavedChanges = true }   // don't re-publish an unchanged flag on every drag frame
        editRevision &+= 1   // per edit, deliberately: Transport's step cache + ProjectsSheet's "unchanged" check key off it
        let t = Date()
        if coalesce, key == lastCheckpointKey, t.timeIntervalSince(lastCheckpointAt) < 0.6 {
            lastCheckpointAt = t
            return false   // coalesced into the prior step
        }
        lastCheckpointKey = key
        lastCheckpointAt = t
        undoStack.append(snapshot())
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
        return true
    }

    /// Snapshot of which pad currently points at which imported one-shot file. Undo/redo compares
    /// before vs after so it only re-reads pad WAVs when the assignment actually changed (#PERSIST-02).
    private func padSampleRefs() -> [String: String] {
        var m: [String: String] = [:]
        for (id, pp) in padParams { if let f = pp.sampleFile { m[id] = f } }
        return m
    }

    func undo() {
        guard !editingLocked, let prev = undoStack.popLast() else { return }
        redoStack.append(captureForRedo(crossingSampleEdit: prev.sampleBufferToken != nil))
        let padRefsBefore = padSampleRefs()
        applyState(prev, resetSample: false)          // restores SampleState too
        restoreSampleBufferToken(prev.sampleBufferToken)   // re-sync engine audio for destructive sampler edits (#19)
        rebuildSynthSampleSource()                         // an undo across "To Synth Keys" must not leave a stale copy
        if padSampleRefs() != padRefsBefore { loadPadSamples() }   // re-register imported pad one-shots (#PERSIST-02)
        lastCheckpointKey = nil
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard !editingLocked, let next = redoStack.popLast() else { return }
        undoStack.append(captureForRedo(crossingSampleEdit: next.sampleBufferToken != nil))
        let padRefsBefore = padSampleRefs()
        applyState(next, resetSample: false)
        restoreSampleBufferToken(next.sampleBufferToken)
        rebuildSynthSampleSource()
        if padSampleRefs() != padRefsBefore { loadPadSamples() }   // re-register imported pad one-shots (#PERSIST-02)
        lastCheckpointKey = nil
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    /// Snapshot the current state for the opposite stack; when crossing a sampler-edit boundary,
    /// also stash the CURRENT engine buffer under a fresh token so the round-trip can restore audio (#19).
    private func captureForRedo(crossingSampleEdit: Bool) -> ProjectSnapshot {
        var cur = snapshot()
        if crossingSampleEdit {
            let token = nextBufferToken; nextBufferToken += 1
            cur.sampleBufferToken = token
            let buf = engine.currentSampleOriginal()
            if !buf.isEmpty { sampleBufferRing.append((key: "\(token)", buffer: buf)); trimSampleRing() }
        }
        return cur
    }

    private func clearUndoHistory() {
        undoStack.removeAll(); redoStack.removeAll()
        sampleBufferRing.removeAll(); pendingBufferToken = nil   // #19
        lastCheckpointKey = nil
        canUndo = false; canRedo = false
    }

    /// Reset to a fresh default project (same seed state as a clean launch).
    func resetToDefault() {
        restore(Project(engine: engine).snapshot())
        name = "Untitled Beat"
    }

    /// Start a fresh project from a template (F5). "blank" = the default empty project; any BeatGenerator
    /// style id seeds a genre starter beat (lanes + tempo + swing) so the user isn't staring at a blank grid.
    func startFromTemplate(_ id: String) {
        resetToDefault()
        guard id != "blank", let style = Project.beatStyles.first(where: { $0.id == id }) else { return }
        generateBeat(style: id, density: 0.5)   // fills lanes + sets the genre's bpm/swing
        // Also load a genre-matching drum kit so the starter beat SOUNDS like its vibe, not the default kit.
        let kitForGenre = ["boombap": "classic", "trap": "trap", "house": "house",
                           "lofi": "lofi", "drill": "trap", "afrobeat": "acoustic"]
        if let kitID = kitForGenre[id] { applyDrumKit(kitID) }
        name = style.name
    }
}

// MARK: - Codable snapshot

nonisolated struct ProjectSnapshot: Codable, Sendable {   // Sendable + nonisolated → encode/decode can run off the main actor (no save/load hitch)
    var version = 3   // v3: tracks may carry source.link (live-linked); v1/v2 decode as frozen (tolerant)
    var name: String
    var bpm: Int
    var swing: Double
    var quantize: String
    var barSteps: Int?     // optional → older saves decode fine (A13)
    var bank: String
    var fullLevel: Bool
    var lanes: [String: [Double]]
    var selectedRow: String
    var rowMute: [String: Bool]
    var rowSolo: [String: Bool]
    var sequences: [SeqSlot]
    var activeSeq: Int
    var mixer: [String: MixChannel]
    var arrangement: [ArrItem]
    var clips: [String: [Clip]]
    var trackMute: [String: Bool]
    var trackSolo: [String: Bool]
    var songMode: Bool
    var melody: [MelodyNote]
    var melodyKey: Int
    var melodyScale: String
    var melodyOctave: Int
    var melodyDensity: String
    var scaleLock: Bool
    var rollLen: Int
    var synthPatch: SynthPatch
    var savedSynths: [SynthPatch]
    var padParams: [String: PadParam]
    var synthBank: [String: SynthBankSlot]?
    var fxSettings: MasterFX?      // optional → older saves decode fine
    var channelFX: [String: ChannelFX]?   // optional → older saves decode fine
    var masterBus: MasterBus?      // optional → older saves decode fine
    var stepMeta: [String: [Int: StepMeta]]?   // optional → older saves decode fine
    var autoTarget: String?                    // optional → older saves decode fine (A11)
    var autoLane: [Double]?
    var songAutoTarget: String?                // optional → Tracks Tier 3 song automation
    var songAuto: [Double]?
    var audioClips: [AudioClipMeta]?           // optional → older saves decode fine (A5 Phase 4)
    var activeKit: String?                     // optional → older saves decode fine (drum-kit preset highlight)
    var sample: SampleState?                   // optional → older saves decode fine (sampler persistence)
    var sliceBank: [String: Slice]?            // optional → Bank C slice assignments
    var parts: [InstrumentPart]?               // optional → Tier 2 multi-part instruments
    var activePart: String?
    var chordMode: String?                     // optional → Play Assist persistence (Domain E)
    var arpMode: String?
    var arpRate: String?
    var arpOct: Int?
    var humanize: Double?                       // optional → Time Correct humanize
    var grooveID: String?                       // optional → named groove feel (E4)
    var tracks: [Track]?                        // optional → v1 saves decode to nil, then get seeded (99-track foundation)
    var melodyMuted: Bool?                      // optional → was dropped on save before (data-loss fix #22)
    var countIn: Int?                           // optional → transport prefs now persist
    var metronome: Bool?
    var songBars: Int? = nil                    // optional → older saves decode to nil and load as 16 bars
    var sampleBufferToken: Int? = nil           // #19: in-memory only — links an undo snapshot to a stored engine buffer
    var id: String? = nil                        // optional → v1/name-keyed saves decode to nil; minted on first load, stamped on save (#219)
    var punchInBar: Int? = nil                   // optional → record-start bar persists (was reset to 0 on every load)
}
