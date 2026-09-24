//  Transport.swift — a lookahead audio-clock scheduler that plays the shared
//  project pattern through the real synth engine. Ported from transport.js.
//
//  The 25ms lookahead timer runs on the main queue, but musical timing is
//  sample-accurate because every event is scheduled at an absolute engine time.

import SwiftUI
import Combine
import AVFoundation
import os
import FD808Engine

/// One scheduler tick of bar arithmetic (see `Transport.advanceStep`).
struct StepAdvance: Equatable { var step: Int; var barLine: Bool }
/// Where the grid should resume after a main-thread stall (see `Transport.catchUpSteps`).
struct CatchUp: Equatable { var steps: Int; var step16: Int; var barCount: Int; var countSteps: Int }

@MainActor
final class Transport: ObservableObject {
    private let project: Project
    private let engine: AudioEngine
    private let fx: PadFX
    var link: LinkClock?               // Ableton Link (A17); nil = no Link
    private var lastSyncedBpm = 0
    /// Link's session tempo as a Double (the external session is authoritative while Link is on). Kept out
    /// of `project.bpm` so following a session can never overwrite the user's saved tempo. (#20)
    private var linkTempo: Double?
    /// Sample-accurate step-fire seam (SequencerEngine, Phase 4): invoked as each 16th is SCHEDULED, with
    /// (bar, step, absoluteEngineTime). nil by default (zero behavior change); the hook for MIDI clock-out,
    /// external sync, or a future arranger — deterministic, not asyncAfter-based.
    var onStep: ((Int, Int, Double) -> Void)?

    private let lookahead = 0.025      // s between scheduler ticks
    private let ahead = 0.12           // s scheduled in advance
    private var timer: DispatchSourceTimer?
    private(set) var playing = false
    private var nextStepTime = 0.0
    private var step16 = 0
    private var stepBarSteps = 16     // bar length in force when `step16` was last set/advanced (finding 46)
    private var loopPass = 0          // Loop-Mode passes completed; the bar conditional trigs evaluate against (finding 49)
    private(set) var droppedSteps = 0 // steps skipped by a backlog fast-forward, for diagnostics (finding 48)
    private var audioRecTrackID: String?          // the track armed when the take started (fallback if disarmed mid-take)
    private var songModeSub: AnyCancellable?   // Song/Loop toggle mid-playback → restart the bar counters (#transport-minor)
    private var barCount = 0          // bar being SCHEDULED (leads real-time by the lookahead); project.bar is the VISUAL bar
    private var countSteps = 0
    private var lastStepAudioTime = 0.0   // engine time at which project.step last became current (for record quantize)

    // audio-record alignment anchors (A5 Phase 2)
    private var audioRecStartNow = 0.0
    private var audioRecBar0 = 0.0
    private var audioRecStartBar = 0

    // Per-BAR cache of the track-derived lookups scheduleStep needs — the dict/set rebuilds were
    // per 16th note (known ARCH-03). Refreshed on every bar line (and when the track list or the ownership
    // sets change — freeze/relink used to keep a stale ownership set until the next bar line, doubling the
    // source for up to a bar), so mid-bar link/vol edits settle at the next downbeat instead of costing
    // every step.
    private var stepCacheBar = -1
    private var stepCacheTracks = -1
    private var stepCacheRevision: UInt64 = .max
    private var cachedBusIdx: [String: Int] = [:]
    private var cachedTrackMixes: [String: TrackMix] = [:]
    private var cachedOwnedRows = Set<String>()
    private var cachedOwnedLeadMelody = false
    private var cachedOwnedPartIDs = Set<String>()
    /// Lanes/step-meta for the classic (seeded-track) path once per-clip pattern pins are folded in.
    /// Identical to the bar's arranged pattern unless some clip pins a different one, and rebuilt on the
    /// same per-bar cadence as the rest of this cache — never per step.
    private var cachedLegacyLanes: [String: [Double]] = [:]
    private var cachedLegacyMeta: [String: [Int: StepMeta]] = [:]

    /// Fold per-track clip pattern pins into the bar's lanes. Walks the UNION of the arranged pattern's
    /// pads and the pinned pattern's pads: a pin can both add hits on pads the arranged pattern leaves
    /// empty and silence pads it fills, so replacing key-by-key from the base alone would miss half of it.
    nonisolated static func foldClipPins(base: [String: [Double]],
                                         overrides: [String: Int],
                                         lanesOfSeq: (Int) -> [String: [Double]],
                                         trackOf: (String) -> String) -> [String: [Double]] {
        guard !overrides.isEmpty else { return base }
        var out = base
        for (tk, si) in overrides {
            let src = lanesOfSeq(si)
            for pad in Set(base.keys).union(src.keys) where trackOf(pad) == tk {
                out[pad] = src[pad] ?? Kit.emptyLane()
            }
        }
        return out
    }

    private func refreshStepCache(bar: Int, curLanes: [String: [Double]], curMeta: [String: [Int: StepMeta]], song: Bool) {
        let p = project
        stepCacheBar = bar
        stepCacheTracks = p.tracks.count
        stepCacheRevision = p.editRevision
        cachedBusIdx = p.busIndex
        cachedTrackMixes = Dictionary(p.tracks.map { ($0.id, p.trackMix($0.id)) }, uniquingKeysWith: { a, _ in a })
        cachedOwnedRows = []
        cachedOwnedLeadMelody = false
        cachedOwnedPartIDs = []
        let pins = song ? p.clipSeqOverrides(atBar: bar) : [:]
        cachedLegacyLanes = Self.foldClipPins(base: curLanes, overrides: pins,
                                              lanesOfSeq: { p.lanesOfSeq($0) }, trackOf: { Kit.trackOf($0) })
        if pins.isEmpty { cachedLegacyMeta = curMeta } else {
            var meta = curMeta
            for (tk, si) in pins {
                let src = p.stepMetaOfSeq(si)
                for pad in Set(curMeta.keys).union(src.keys) where Kit.trackOf(pad) == tk { meta[pad] = src[pad] }
            }
            cachedLegacyMeta = meta
        }
        // A track that reproduces live material from its own content owns it: a live link, a frozen copy
        // (link cleared but the copy carried over), or a baked-to-audio track whose clip stands in for the
        // synthesis. Suppressing them here is what keeps a sent/promoted/frozen pattern playing ONCE. (#15)
        for track in p.tracks where track.playsAdditively || track.frozenToAudio {
            let owned = p.trackOwnership(track)
            // Union over the FOLDED lanes: a clip pin can introduce a pad the arranged pattern does not
            // have, and an "owns every lane" track must suppress that one too or it would play twice.
            if owned.allLanes { cachedOwnedRows.formUnion(cachedLegacyLanes.keys) } else { cachedOwnedRows.formUnion(owned.rows) }
            cachedOwnedLeadMelody = cachedOwnedLeadMelody || owned.leadMelody
            cachedOwnedPartIDs.formUnion(owned.partIDs)
        }
    }

    init(project: Project, engine: AudioEngine, fx: PadFX) {
        self.project = project
        self.engine = engine
        self.fx = fx
        project.beforeProjectReplacement = { [weak self] in self?.stop() }
        // Toggling Song Mode while playing used to keep the old barCount/loopPass, so Loop-Mode conditional
        // trigs resumed on a stale pass number and the Tracks playhead sat on a frozen bar until Stop.
        songModeSub = project.$songMode.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.barCount = 0; self.loopPass = 0
            if self.playing { self.project.bar = 0 }
        }
    }

    private func secPerStep() -> Double { Self.stepDuration(bpm: Double(project.bpm), linkTempo: linkTempo) }
    /// The tempo the grid actually runs at (Link session tempo when Link drives it). Note Repeat and other
    /// tempo-derived timers must use this, not `project.bpm`, or they drift against the transport.
    var effectiveBpm: Double { linkTempo ?? Double(project.bpm) }

    // MARK: pure scheduling arithmetic (extracted so the grid/count-in/clip rules are unit-testable)

    /// Length of one 16th. Link's session tempo is a Double and drives the grid when Link is on, so an
    /// external session (e.g. 120.4 BPM) is followed exactly instead of being rounded into the saved
    /// project bpm first. (#20)
    nonisolated static func stepDuration(bpm: Double, linkTempo: Double?) -> Double {
        (60.0 / max(1, linkTempo ?? bpm)) / 4
    }

    /// Engine time of the downbeat of arrangement bar `targetBar`, relative to the scheduler's next step.
    /// Must include the count-in still to elapse (`countSteps`) and the scheduler's own sub-bar position,
    /// so a mic take is trimmed to the real bar line rather than landing countIn bars late (clicks intact)
    /// or a whole bar plus fraction off when punching in over a running beat. In Loop Mode the arrangement
    /// bar never advances, so PUNCH counts bars of count-in from the next loop top. (#17)
    nonisolated static func micAnchor(nextStepTime: Double, step16: Int, barCount: Int, countSteps: Int,
                                      barSteps: Int, songBars: Int, songMode: Bool, secPerStep: Double,
                                      targetBar: Int) -> Double {
        let n = max(1, barSteps)
        let stepsToTarget: Int
        if songMode {
            let songSteps = max(1, songBars * n)
            var d = (targetBar - barCount) * n - step16
            d = ((d % songSteps) + songSteps) % songSteps
            stepsToTarget = d
        } else {
            stepsToTarget = (n - step16) % n + max(0, targetBar) * n
        }
        return nextStepTime + Double(countSteps + stepsToTarget) * secPerStep
    }

    /// Audio clips that fire when the scheduler reaches the top of arrangement bar `bar`, plus whether the
    /// clip voice layer must be restarted first. Loop Mode loops ONE bar, so the arrangement bar never
    /// advances: a clip at bar > 0 would never sound, and a clip longer than the loop would stack on itself
    /// every pass. Both are handled by wrapping every clip to the loop top and restarting the layer. (#16)
    nonisolated static func audioClipsToFire(_ clips: [AudioClip], atBar bar: Int,
                                             songMode: Bool) -> (clips: [AudioClip], restart: Bool) {
        let live = clips.filter { !$0.muted }
        if songMode { return (live.filter { $0.startBar == bar }, false) }
        return (live, !live.isEmpty)
    }

    /// Whether the host may tell followers that playback has begun. Emitting `playing: true` at the top of
    /// the count-in made every follower start the pattern 1-4 bars early, then get yanked back mid-bar by
    /// the heartbeat. (#18)
    nonisolated static func shouldAnnouncePlay(countSteps: Int) -> Bool { countSteps <= 0 }

    /// Lead the follower leaves between receiving a seek and its first scheduled step (see `startAt`).
    nonisolated static let followerStartLead = 0.05

    /// The follower's target step (cyclically within the song) for a received transport op. The step is
    /// advanced by the time since the op PLUS the follower's own start lead, because `startAt` schedules its
    /// first step one lead in the future: without that term every late joiner — and every follower after a
    /// re-seek — sat 50-175 ms behind the teacher. (#19)
    nonisolated static func followerTargetStep(bar: Int, step: Int, elapsed: Double, secPerStep: Double,
                                               barSteps: Int, songBars: Int,
                                               startLead: Double = Transport.followerStartLead) -> Int {
        let n = max(1, barSteps)
        let songSteps = max(1, songBars * n)
        let abs0 = bar * n + step + Int(((elapsed + startLead) / max(1e-6, secPerStep)).rounded())
        return ((abs0 % songSteps) + songSteps) % songSteps
    }

    /// What a follower should do with a received transport op.
    enum FollowerAction: Equatable {
        case ignore
        case stop
        case start(bar: Int, step: Int)    // nothing playing locally → join in at the teacher's position
        case reseek(bar: Int, step: Int)   // already playing but off the grid → re-anchor
    }

    /// Follower policy for a transport op (drives RootView). The local-vs-target comparison is cyclic: a
    /// target wrapped past the end of the song is one step away from a follower sitting on the last step,
    /// not a whole song-length drift, so the heartbeat no longer forces a destructive stop/restart on every
    /// pass of the arrangement. (#19)
    nonisolated static func followerAction(playing: Bool, bar: Int, step: Int, localPlaying: Bool,
                                           localBar: Int, localStep: Int, barSteps: Int, songBars: Int,
                                           reseekThreshold: Double = 2) -> FollowerAction {
        guard playing else { return .stop }
        if !localPlaying { return .start(bar: bar, step: step) }
        let n = max(1, barSteps)
        let songSteps = max(1, songBars * n)
        let local = ((localBar * n + max(0, localStep)) % songSteps + songSteps) % songSteps
        let target = ((bar * n + step) % songSteps + songSteps) % songSteps
        let d = abs(local - target)
        let drift = min(d, songSteps - d)      // cyclic distance: the song is a loop
        return Double(drift) > reseekThreshold ? .reseek(bar: bar, step: step) : .ignore
    }

    /// One tick of the step counter. `prevBarSteps` is the bar length in force when `step16` was set and
    /// `barSteps` the live one, so a time-signature change between two steps is visible. Returns the step
    /// to schedule next and whether that transition is a real bar line.
    nonisolated static func advanceStep(step16: Int, prevBarSteps: Int, barSteps: Int) -> StepAdvance {
        let n = max(1, barSteps)
        // The signature changed between two steps, so `step16` is an index on the OLD grid. A change that
        // lands ON a downbeat needs nothing: the wrap already fired under the old length and the new bar
        // simply continues. Anywhere else the old step index can be past the new bar length (4/4 → 3/4 at
        // step 12..15 wraps without `prev` ever reaching n-1 = 11, so the bar line — and with it barCount,
        // project.bar, the Song-Mode clip gate and condPass — stalled for a bar) or short of it (3/4 → 4/4
        // plays extra steps before the line). Start the new bar here so this wrap IS the bar line.
        // (finding 46)
        if max(1, prevBarSteps) != n, step16 != 0 { return StepAdvance(step: 0, barLine: true) }
        let prev = min(step16, n - 1)
        var next = prev + 1
        if next >= n { next = 0 }
        return StepAdvance(step: next, barLine: next == 0 && prev == n - 1)
    }

    /// Grid position the scheduler should jump to when it has fallen more than `threshold` behind and at
    /// least one whole step is already in the past. nil = nothing to skip (play the late step normally).
    nonisolated static func catchUpSteps(behind: Double, secPerStep: Double, step16: Int, barCount: Int,
                                         countSteps: Int, barSteps: Int, songMode: Bool, songBars: Int,
                                         threshold: Double) -> CatchUp? {
        guard secPerStep > 0, behind > threshold else { return nil }
        let steps = Int((behind / secPerStep).rounded(.down))   // whole steps whose time is already past
        guard steps > 0 else { return nil }
        let n = max(1, barSteps)
        let abs = max(0, step16) + steps
        let bars = max(1, songBars)
        return CatchUp(steps: steps, step16: abs % n,
                       // Loop Mode pins the arrangement bar (matching advance()); Song Mode wraps the song.
                       // Never advance the arrangement while the count-in is still running — the stall path
                       // used to re-open #TIMING-01 (song started N bars in after a hitch during the count).
                       barCount: (songMode && countSteps == 0) ? (max(0, barCount) + abs / n) % bars : max(0, barCount),
                       countSteps: max(0, countSteps - steps))
    }

    /// The bar number a conditional trig is evaluated against: the arrangement bar in Song Mode, the
    /// loop-pass counter in Loop Mode (the arrangement bar never advances there). Evaluated against bar 0
    /// forever, "2:2" and "fill" never fired live while the 4-bar bounce played them, and "1:2"/"1:3"/
    /// "1:4"/"!fill" stayed permanently on. (finding 49)
    nonisolated static func trigBar(songMode: Bool, barCount: Int, loopPass: Int) -> Int {
        songMode ? barCount : loopPass
    }

    /// The Loop-Mode pass counter after one completed loop. Deliberately unbounded: the export numbers its
    /// bars 0,1,2… from the loop top, so a pass counter that keeps counting matches every loop length.
    nonisolated static func nextLoopPass(_ pass: Int) -> Int { pass + 1 }

    func toggle() { playing ? stop() : start() }

    func start(countInBars: Int? = nil) {
        if playing { return }
        engine.start()
        engine.stopClips()      // clear any clip voices lingering from a prior run
        playing = true
        step16 = 0
        stepBarSteps = max(1, project.barSteps)
        loopPass = 0
        droppedSteps = 0
        stepCacheBar = -1
        let bars = countInBars ?? project.countIn
        countSteps = bars * max(1, project.barSteps)
        project.countingIn = countSteps > 0
        nextStepTime = engine.now() + 0.08
        project.playing = true
        project.step = -1
        project.bar = 0          // restart the arrangement from the top
        barCount = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: lookahead)
        t.setEventHandler { [weak self] in self?.scheduler() }
        timer = t
        t.resume()
        if Self.shouldAnnouncePlay(countSteps: countSteps) {
            project.emit(.transport(playing: true, hostTime: Date().timeIntervalSince1970, bar: 0, step: 0))   // host → followers play (Step 7)
        } else {
            // Counting in: hold the class. Announcing "playing" here made every follower start the drum
            // pattern during the teacher's count-in, then get re-seeked mid-bar by the heartbeat. (#18)
            project.emit(.transport(playing: false, hostTime: Date().timeIntervalSince1970, bar: 0, step: 0))
        }
    }

    /// Follower-driven start at a specific arrangement position (clock-synced follow). Like start() but
    /// seeds the playhead to (bar, step). Does NOT emit a transport op (avoids echo on followers).
    func startAt(bar: Int, step: Int) {
        project.countingIn = false
        if playing { stop() }
        engine.start(); engine.stopClips()
        playing = true
        stepCacheBar = -1
        let n = max(1, project.barSteps)
        step16 = ((step % n) + n) % n
        stepBarSteps = n
        loopPass = 0
        droppedSteps = 0
        countSteps = 0
        nextStepTime = engine.now() + Self.followerStartLead
        project.playing = true
        project.step = -1
        let sb = max(0, bar) % max(1, project.songBars)
        project.bar = sb
        barCount = sb
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: lookahead)
        t.setEventHandler { [weak self] in self?.scheduler() }
        timer = t
        t.resume()
    }

    func stop() {
        engine.finishMicCapture()
        playing = false
        timer?.cancel()
        timer = nil
        countSteps = 0
        project.countingIn = false
        engine.stopClips()
        engine.resetAutomation()   // release any swept FX params
        project.playing = false
        project.recording = false
        project.step = -1
        project.emit(.transport(playing: false, hostTime: Date().timeIntervalSince1970, bar: project.bar, step: max(0, project.step)))
    }

    // arm record; start playing if needed. If an audio track is armed, capture the
    // mic into a clip (overdub) instead of / alongside pad recording.
    func record() {
        if project.recording {
            project.recording = false
            if let owner = engine.micOwner, case .track = owner { engine.finishMicCapture(owner: owner) }
            return
        }
        if let trackID = project.audioArmedTrack {
            guard engine.micOwner == nil else { project.backgroundOperationNotice = "Finish the current microphone capture before starting a track take."; return }
            // bring up the play-and-record session BEFORE starting the transport so the
            // engine doesn't restart mid-playback
            let projectID = project.projectID
            let owner = AudioEngine.MicOwner.track(project: projectID, track: trackID)
            engine.startMicRecording(owner: owner, finish: { [weak self] in
                self?.finishAudioRecord()
                self?.project.recording = false
            }) { [weak self] ok in
                guard let self, self.project.projectID == projectID else { return }
                guard ok else { self.project.micRecordFailed = true; return }   // denied/failed → don't fake a recording
                self.project.recording = true
                let punch = self.project.punchInBar      // bars before it are count-in
                self.audioRecTrackID = trackID
                self.project.checkpoint("startCapture", coalesce: false)

                self.audioRecStartBar = punch
                if !self.playing { self.start() }
                self.audioRecStartNow = self.engine.micStartTime
                self.audioRecBar0 = Self.micAnchor(nextStepTime: self.nextStepTime, step16: self.step16,
                                                   barCount: self.barCount, countSteps: self.countSteps,
                                                   barSteps: self.project.barSteps, songBars: self.project.songBars,
                                                   songMode: self.project.songMode, secPerStep: self.secPerStep(),
                                                   targetBar: punch)
            }
        } else {
            project.recording = true
            if !playing { start() }
        }
    }

    /// Finalize an audio take: trim the front by (pre-roll + round-trip latency + user
    /// offset) so it lines up with the beat, then drop it on the armed track.
    private func finishAudioRecord() {
        // Stop the capture FIRST: if the track was disarmed/deleted mid-take, bailing before
        // stopMicRecordingRaw() left the tap installed and the session pinned to play-and-record, and the next
        // record attempt showed a bogus "microphone access" alert (SYSTEMS_GAP_AUDIT #lifecycle-5).
        guard engine.isMicRecording, case .track = engine.micOwner else { return }
        let take = engine.stopMicRecordingRaw()
        // Fall back to the track that was armed when the take STARTED: disarming/deleting it mid-take used
        // to drop the captured audio silently (round 2, cross-4).
        guard let (raw, rawR, lat) = take else { audioRecTrackID = nil; return }
        let armed = audioRecTrackID ?? project.audioArmedTrack   // the track the take STARTED on wins over a mid-take re-arm
        audioRecTrackID = nil
        let track: String
        if let armed, project.tracks.contains(where: { $0.id == armed }) { track = armed }
        else {
            track = project.tracks.first(where: { $0.type == .audio })?.id ?? project.addTrack(.audio)
            project.backgroundOperationNotice = "The recording track was removed. Your take was kept on an audio track."
        }
        let preRoll = max(0, audioRecBar0 - audioRecStartNow)
        let offset = Double(project.audioRecOffsetMs) / 1000.0
        let trim = Int((preRoll + lat + offset) * engine.sampleRate)   // captured at the engine rate, not always 48 k (Phase 5/7)
        func trimmed(_ a: [Float]) -> [Float] {                        // same latency trim applied to both channels
            if trim > 0 { return trim < a.count ? Array(a.dropFirst(trim)) : [] }
            if trim < 0 { return Array(repeating: 0, count: -trim) + a }   // push later
            return a
        }
        let data = trimmed(raw)
        guard !data.isEmpty else { return }
        project.addAudioClip(track: track, startBar: audioRecStartBar, data: data, dataR: rawR.map(trimmed), name: "Take")
    }

    private func flash(_ padID: String, at time: Double) {
        let dt = time - engine.now()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
            self?.fx.bump(padID)
        }
    }

    private func scheduleStep(_ s: Int, _ time: Double) {
        let p = project
        if (p.metronome || countSteps > 0) && s % 4 == 0 {
            engine.trigger("click", vel: s % 16 == 0 ? 0.95 : 0.7, when: time)
        }
        if Haptics.shared.enabled && countSteps == 0 && s % 4 == 0 {   // "feel the beat" — pulse at the step's real time
            let dt = time - engine.now()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { Haptics.shared.beat(strong: s % 16 == 0) }
        }
        if countSteps > 0 { return }
        onStep?(barCount, s, time)   // SequencerEngine step-fire seam (sample-accurate; nil = no-op)

        // FX automation (A11) — apply the lane value at this step's time (song automation overrides in Song Mode)
        if p.autoTarget != "", s < p.autoLane.count, !(p.songMode && p.songAutoTarget != "") {
            let v = p.autoLane[s], target = p.autoTarget
            let dt = time - engine.now()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
                guard let self, self.playing else { return }
                self.applyAuto(target, v)
            }
        }
        // Song-wide FX automation (Tier 3) — interpolated breakpoint per bar, only in Song Mode
        if p.songMode, p.songAutoTarget != "" {
            let v = p.songAutoValue(bar: barCount, frac: Double(s) / Double(max(1, p.barSteps))), target = p.songAutoTarget
            let dt = time - engine.now()
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
                guard let self, self.playing else { return }
                self.applyAuto(target, v)
            }
        }

        // Focus (compose monitor): play ONLY the part being edited so you can hear one sound in isolation
        // while writing it. The metronome above still fires for timing; drums, tracks, clips + other parts
        // are skipped. This is a live-monitor toggle, independent of the mixer's persistent solo/mute.
        if p.focusMode {
            let mvol = (p.mixer["melody"] ?? MixChannel(vol: 0.85)).vol
            if p.activePart == "lead" {
                let mel = p.songMode ? p.melodyForBar(barCount) : p.melody
                for note in mel where note.step == s {
                    engine.triggerSynth(p.synthPatch, midi: note.pitch, dur: Double(note.dur) * secPerStep(),
                                        vel: note.vel * mvol * 1.25 * p.humVel(), when: time + p.humTime())
                }
            } else {
                let parts = p.songMode ? p.partsForBar(barCount) : p.parts
                if let part = parts.first(where: { $0.id == p.activePart }) {
                    for note in part.notes where note.step == s {
                        engine.triggerSynth(part.patch, midi: note.pitch, dur: Double(note.dur) * secPerStep(),
                                            vel: note.vel * mvol * 1.25 * p.humVel(), when: time + p.humTime())
                    }
                }
            }
            return
        }

        let solo = p.mixer.values.contains { $0.solo }
        let rowSolo = p.rowSolo.values.contains(true)
        let song = p.songMode
        let bar = barCount            // schedule against the lookahead bar (the bar these hits will play in)
        // Per-bar conditional trigs: the arrangement bar in Song Mode, the loop pass in Loop Mode (where
        // barCount is pinned at 0). (finding 49)
        let trigBar = Self.trigBar(songMode: song, barCount: bar, loopPass: loopPass)
        let curLanes = song ? p.lanesForBar(bar) : p.lanes
        let curMelody = song ? p.melodyForBar(bar) : p.melody
        let curMeta = song ? p.stepMetaForBar(bar) : p.stepMeta
        let master = p.mixer["master"] ?? MixChannel(vol: 0.9)
        if master.mute { return }

        if s == 0 || stepCacheBar != bar || stepCacheTracks != p.tracks.count || stepCacheRevision != p.editRevision {
            refreshStepCache(bar: bar, curLanes: curLanes, curMeta: curMeta, song: song)
        }
        func mix(_ id: String) -> TrackMix { cachedTrackMixes[id] ?? p.trackMix(id) }

        // audio clips that start on this bar (A5 multitrack)
        if s == 0 && !p.audioClips.isEmpty {
            let fire = Self.audioClipsToFire(p.audioClips, atBar: bar, songMode: song)
            // Loop Mode replays the clip layer from the top every pass; stop the previous pass's voices
            // first so a take longer than the loop can't stack on (and amplify) itself. (#16)
            let limit = fire.restart ? Int((secPerStep() * Double(p.barSteps) * engine.sampleRate).rounded()) : nil
            for clip in fire.clips {
                let tk = clip.track
                let tm = mix(tk)
                if !tm.audible { continue }
                let ch = p.trackBusChannel(tm, fallback: AudioEngine.melodyChannel)
                let gain = clip.gain * tm.gain, balance = Project.stereoBalance(tm.pan)
                if let r = clip.dataR {   // stereo take → two hard-panned (±1) voices reconstruct L/R
                    engine.playClip(clip.data, when: time, gain: gain * balance.left, channel: ch, pan: -1, maxFrames: limit)
                    engine.playClip(r,         when: time, gain: gain * balance.right, channel: ch, pan: 1, maxFrames: limit)
                } else {
                    engine.playClip(clip.data, when: time, gain: gain, channel: ch, pan: tm.pan, maxFrames: limit)
                }
            }
        }

        // Sources a live-linked OR frozen track now OWNS — suppress them in the classic paths below so a
        // promoted / sent pattern plays exactly ONCE (via its track), not doubled. Seeded tracks own
        // nothing; a frozen copy owns the source it captured, and a baked-to-audio track owns the source
        // its clip replaced. (#15)
        let ownedRows = cachedOwnedRows
        let ownedLeadMelody = cachedOwnedLeadMelody
        let ownedPartIDs = cachedOwnedPartIDs
        // Clip pattern pins already folded in (per bar, not per step).
        let playLanes = cachedLegacyLanes
        let playMeta = cachedLegacyMeta

        for (padID, lane) in playLanes {
            guard s < lane.count else { continue }
            let vel = lane[s]
            if vel == 0 { continue }
            if ownedRows.contains(padID) { continue }   // owned by a linked track → played in the additive pass
            if p.rowMute[padID] == true { continue }
            if rowSolo && !(p.rowSolo[padID] ?? false) { continue }
            // Tracks tab mute/solo
            let tk = Kit.trackOf(padID)
            let tm = mix(tk)
            if !tm.audible { continue }
            // Song Mode: only play tracks that have a clip in this bar
            if song && !p.trackPlaysInSong(tk, atBar: bar) { continue }
            let m = p.mixer[Kit.channelOf(padID)] ?? MixChannel()
            if m.mute { continue }
            if solo && !m.solo { continue }
            // Per-step probability + conditional trigs (A9)
            let sm = playMeta[padID]?[s]
            if let sm {
                if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: trigBar) { continue }
                if sm.prob < 0.999 && Double.random(in: 0..<1) > sm.prob { continue }
            }
            let v = p.padVel(padID, p.fullLevel ? 1 : vel) * p.padHitGain(padID) * tm.gain * p.humVel()
            let when = time + p.padOffsetSec(padID) + p.humTime()
            p.triggerPadPlayback(padID, velocity: v, when: when, meta: sm, panOffset: tm.pan, channel: tm.busKey.flatMap { p.busOrder.firstIndex(of: $0) })
            flash(padID, at: time)
        }

        // synth / melody track (played by the knob-driven patch) — gated by the "vox" arrangement track
        // The vox clip can pin its own pattern, so the lead resolves per-track rather than per-bar.
        let voxMelody = song ? p.melodyForTrack("vox", atBar: bar) : curMelody
        if !p.melodyMuted, !ownedLeadMelody, !voxMelody.isEmpty, mix("vox").audible,
           !(song && !p.trackPlaysInSong("vox", atBar: bar)) {
            let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
            if !mmel.mute && !(solo && !mmel.solo) {
                let patch = p.synthPatch
                for note in voxMelody where note.step == s {
                    let durSec = Double(note.dur) * secPerStep()
                    let v = note.vel * mmel.vol * 1.25 * mix("vox").gain * p.humVel()
                    engine.triggerSynth(patch, midi: note.pitch, dur: durSec, vel: v, when: time + p.humTime(), pan: mix("vox").pan, channel: mix("vox").busKey.flatMap { p.busOrder.firstIndex(of: $0) })
                }
            }
        }

        // extra instrument parts (Tier 2) — own gate: per-sequence in Song Mode, NOT tied to the
        // vox clip or melody mute, but still honoring the vox track mute/solo and the melody channel.
        let curParts = song ? p.partsForTrack("vox", atBar: bar) : p.parts
        if !curParts.isEmpty, mix("vox").audible {
            let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
            if !mmel.mute && !(solo && !mmel.solo) {
                for part in curParts where !part.muted && !ownedPartIDs.contains(part.id) {
                    for note in part.notes where note.step == s {
                        let durSec = Double(note.dur) * secPerStep()
                        // Humanize like the lead melody and the tracks: the parts path was the one synth
                        // path live left dead on the grid, so it was the only one that disagreed with the
                        // bounce once the bounce humanized every synth path. (finding 73)
                        let v = note.vel * mmel.vol * 1.25 * mix("vox").gain * p.humVel()
                        engine.triggerSynth(part.patch, midi: note.pitch, dur: durSec, vel: v, when: time + p.humTime(), pan: mix("vox").pan, channel: mix("vox").busKey.flatMap { p.busOrder.firstIndex(of: $0) })
                    }
                }
            }
        }

        // ── Layered tracks (Add Track / send-to-track): LIVE-LINKED tracks resolve their source live
        //    here (editing the source updates them), FROZEN tracks play their captured copy — both gated
        //    by the same track-mute / track-solo / Song-Mode-clip rules as the seeded lanes. The 6 seeded
        //    tracks have neither a link nor a copy, so they're untouched — played by the classic paths
        //    above (no double-trigger). Link resolution is per-step here, matching the existing
        //    curLanes/trackVol per-step cost; a per-bar cache is a future optimization. (SYSTEM_AUDIT Step 1)
        let busIdx = cachedBusIdx
        for track in p.tracks where track.playsAdditively {   // linked OR frozen, not frozen-to-audio (plays via clip)
            let tm = mix(track.id)
            if !tm.audible { continue }
            if song && !p.trackPlaysInSong(track.id, atBar: bar) { continue }
            // route to a group bus if assigned, else this track's own bus; group bus applies its fader as group gain (G3.4)
            let busCh = tm.busKey.flatMap { busIdx[$0] }
            switch track.type {
            case .drumPattern:
                guard let tlanes = p.trackLanes(track, atBar: bar) else { continue }   // live-resolved if linked
                for (pad, lane) in tlanes {
                    guard s < lane.count, lane[s] != 0 else { continue }
                    let m = p.mixer[Kit.channelOf(pad)] ?? MixChannel()
                    if m.mute || (solo && !m.solo) { continue }
                    // linked drum tracks honor the live stepMeta (probability/conditions/p-locks); frozen copies don't (#Step3)
                    let sm = p.trackStepMeta(track, pad, s, atBar: bar)
                    if let sm {
                        if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: trigBar) { continue }
                        if sm.prob < 0.999 && Double.random(in: 0..<1) > sm.prob { continue }
                    }
                    let v = p.padVel(pad, p.fullLevel ? 1 : lane[s]) * p.padHitGain(pad) * tm.gain * p.humVel()
                    let when = time + p.padOffsetSec(pad) + p.humTime()
                    p.triggerPadPlayback(pad, velocity: v, when: when, meta: sm, panOffset: tm.pan, channel: busCh)
                    flash(pad, at: time)
                }
            case .synthPart:
                guard let (notes, patch) = p.trackNotes(track, atBar: bar) else { continue }   // live-resolved if linked
                let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
                if mmel.mute || (solo && !mmel.solo) { break }
                for note in notes where note.step == s {
                    let durSec = Double(note.dur) * secPerStep()
                    let v = note.vel * mmel.vol * 1.25 * tm.gain * p.humVel()
                    engine.triggerSynth(patch, midi: note.pitch, dur: durSec, vel: v, when: time + p.humTime(), pan: tm.pan, channel: busCh)
                }
            default: break
            }
        }
    }

    private func applyAuto(_ target: String, _ v: Double) {
        switch target {
        case "filter": engine.setMasterCutoff(20 * pow(900, v))   // v=0 → 20 Hz, v=1 → 18 kHz
        case "reverb": engine.setReverbAuto(v)
        case "delay":  engine.setDelayAuto(v)
        default: break
        }
    }

    private func advance() {
        nextStepTime += secPerStep()
        let n = max(1, project.barSteps)
        let wasCounting = countSteps > 0   // count-in active at the START of this advance (incl. the count→play transition)
        let r = Self.advanceStep(step16: step16, prevBarSteps: stepBarSteps, barSteps: n)
        step16 = r.step
        stepBarSteps = n
        if countSteps > 0 { countSteps -= 1 }   // `countingIn` clears when the first REAL step publishes (audio time), not one lookahead early
        if r.barLine {
            // Count-in shares step16 with playback but MUST leave the arrangement pinned at bar 0, or
            // Song Mode starts N bars in and skips its intro (#TIMING-01). Only advance on real bar lines.
            if !wasCounting {
                // Loop (non-song) mode loops the single active pattern, so pin the arrangement bar at 0 —
                // otherwise the counter/Tracks playhead swept 0→songBars while one bar looped (#FUNCNAV-01).
                // The LOOP PASS still advances: it is what the per-bar conditional trigs evaluate against,
                // so a programmed fill fires live exactly where the 4-bar bounce plays it. (finding 49)
                if project.songMode { barCount = (barCount + 1) % max(1, project.songBars) }
                else { loopPass = Self.nextLoopPass(loopPass) }
                nudgeToLinkPhase()   // align the downbeat to the Link session (no-op when Link is off)
                // Performance mode: apply a queued pattern launch on the bar line
                if let q = project.queuedSeq { project.switchSequence(q, record: false); project.queuedSeq = nil }
            }
        }
    }

    // MARK: Ableton Link sync (A17) — no-ops unless Link is enabled

    /// Adopt the shared session tempo each tick; if the user changed BPM here, push it to the session.
    /// The session tempo is kept as a Double in `linkTempo` and drives the grid directly: rounding it into
    /// the persisted `project.bpm` would run up to 0.5 BPM off the session and overwrite the user's saved
    /// tempo. (#20)
    private func linkSync() {
        guard let link, link.isOn else { linkTempo = nil; lastSyncedBpm = project.bpm; return }
        if lastSyncedBpm != 0 && project.bpm != lastSyncedBpm {
            link.proposeTempo(Double(project.bpm), atHostTime: HostClock.now())
            linkTempo = nil                     // the user's tempo is authoritative again
        } else if let t = link.sessionTempo() {
            linkTempo = max(40, min(220, t))    // Double — the grid follows the session exactly
        }
        lastSyncedBpm = project.bpm
    }

    /// Ease FD-808's downbeat toward Link's bar phase (called on each bar line). Tune `outputLatency` on device.
    private func nudgeToLinkPhase() {
        guard let link, link.isOn else { return }
        // Read the host clock FIRST, then the audio clock: if a main-thread stall lands between the two,
        // dt comes out slightly smaller, so the projected host time `ht` errs early rather than late.
        let host = HostClock.now()
        let dt = max(0, nextStepTime - engine.now()) + AVAudioSession.sharedInstance().outputLatency
        let ht = host &+ HostClock.ticks(forSeconds: dt)
        let q0 = Double(max(1, project.barSteps)) / 4   // bar length in beats (3/4 = 3), not a hard 4/4
        if link.quantum != q0 { link.quantum = q0; return }   // the phase domain just changed — skip this bar's nudge (no jump)
        guard let phase = link.phase(atHostTime: ht) else { return }   // 0 ..< quantum (bar)
        let q = link.quantum
        let corrBeats = phase > q / 2 ? (q - phase) : -phase            // shortest shift to phase 0
        // Ease 50% toward lock per bar, but never pull the next step into the PAST (a backward nudge could
        // otherwise schedule steps before now() → they'd flam onto the next block boundary).
        nextStepTime = max(nextStepTime + corrBeats * secPerStep() * 4 * 0.5, engine.now() + lookahead)
    }

    private func scheduler() {
        guard playing else { return }
        let p = project
        linkSync()
        // A main-thread stall longer than the lookahead must not release the whole backlog at once: the
        // shipped loop scheduled every missed step at now + 1 ms, so at 120 BPM a 1 s stall fired half a
        // bar (8 sixteenths) on one sample — a loud flam through the limiter. Fast-forward the counters to
        // the current grid position instead; nextStepTime stays absolute, so the grid keeps its phase.
        // (finding 48)
        let sps = secPerStep()
        if let c = Self.catchUpSteps(behind: engine.now() - nextStepTime, secPerStep: sps, step16: step16,
                                     barCount: barCount, countSteps: countSteps, barSteps: p.barSteps,
                                     songMode: p.songMode, songBars: p.songBars, threshold: lookahead) {
            let wasCounting = countSteps > 0
            nextStepTime += Double(c.steps) * sps
            step16 = c.step16
            stepBarSteps = max(1, p.barSteps)
            barCount = c.barCount
            countSteps = c.countSteps
            droppedSteps += c.steps
            fdLog.debug("scheduler backlog: skipped \(c.steps, privacy: .public) step(s) after a main-thread stall")
            // The count-in ended inside the skipped backlog: announce now (its bar line was skipped).
            if wasCounting && countSteps == 0 { announcePlay(from: nextStepTime) }
        }
        while nextStepTime < engine.now() + ahead {
            var t = nextStepTime
            if p.grooveID == "straight" {            // manual Swing slider
                if p.swing > 0 && step16 % 2 == 1 { t += secPerStep() * p.swing * 0.66 }
            } else {                                  // named groove feel (E4) — per-16th micro-timing
                t += secPerStep() * Groove.byID(p.grooveID).push[step16 % 16]
            }
            t = max(t, engine.now() + 0.001)   // negative-push grooves must never schedule into the past → flam (#TIMING-03)
            scheduleStep(step16, t)
            let showStep = step16
            let showBar = barCount            // the bar of THIS step — published at its real time, in lock-step with the step
            let counting = countSteps > 0
            let dt = t - engine.now()
            let stepT = t                     // capture as a let for the closure (record-quantize anchor)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
                guard let self, self.playing else { return }
                if !counting && self.project.countingIn { self.project.countingIn = false }   // at the step's real time (round 3, transport-1/2)
                self.project.step = counting ? -1 : showStep
                self.project.bar = showBar
                self.lastStepAudioTime = stepT
            }
            advance()
            // The count-in just ended: NOW tell followers the pattern is starting. `nextStepTime` is the
            // first real step (bar 0 step 0), so announce at its real time to avoid the lookahead skew. (#18)
            if counting && countSteps == 0 { announcePlay(from: nextStepTime) }
        }
    }

    /// Emit the host's start-of-pattern transport op at the moment the first real step sounds (not at the
    /// top of the count-in), so followers start on the downbeat instead of 1-4 bars early. (#18)
    private func announcePlay(from time: Double) {
        let dt = time - engine.now()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
            guard let self, self.playing, self.project.playing else { return }
            self.project.emit(.transport(playing: true, hostTime: Date().timeIntervalSince1970, bar: 0, step: 0))
        }
    }

    /// Live fractional position within the current bar [0,1), reconstructed from the audio clock
    /// so a recorded pad hit quantizes to the step the user actually HEARD — not the lookahead
    /// playhead. Honors the active bar length (barSteps). Returns 0 when stopped.
    func recordFraction(at time: Double? = nil) -> Double {
        let n = Double(max(1, project.barSteps))
        guard playing, project.step >= 0 else { return 0 }
        let sps = secPerStep()
        // Clamp below one step: after a >1-step stall the wrapped value (e.g. 16.4/16 → 0.025) lost the
        // "this hit belongs to the NEXT bar" information the record paths derive from `> 0.5` (round 3, transport-4).
        let prog = sps > 0 ? min(0.999, max(0, ((time ?? engine.now()) - lastStepAudioTime) / sps)) : 0
        return ((Double(project.step) + prog) / n).truncatingRemainder(dividingBy: 1)
    }
}
