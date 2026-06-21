//  Transport.swift — a lookahead audio-clock scheduler that plays the shared
//  project pattern through the real synth engine. Ported from transport.js.
//
//  The 25ms lookahead timer runs on the main queue, but musical timing is
//  sample-accurate because every event is scheduled at an absolute engine time.

import SwiftUI
import Combine
import AVFoundation
import FD808Engine

@MainActor
final class Transport: ObservableObject {
    private let project: Project
    private let engine: AudioEngine
    private let fx: PadFX
    var link: LinkClock?               // Ableton Link (A17); nil = no Link
    private var lastSyncedBpm = 0

    private let lookahead = 0.025      // s between scheduler ticks
    private let ahead = 0.12           // s scheduled in advance
    private var timer: DispatchSourceTimer?
    private var playing = false
    private var nextStepTime = 0.0
    private var step16 = 0
    private var barCount = 0          // bar being SCHEDULED (leads real-time by the lookahead); project.bar is the VISUAL bar
    private var countSteps = 0
    private var lastStepAudioTime = 0.0   // engine time at which project.step last became current (for record quantize)

    // audio-record alignment anchors (A5 Phase 2)
    private var audioRecStartNow = 0.0
    private var audioRecBar0 = 0.0
    private var audioRecStartBar = 0

    init(project: Project, engine: AudioEngine, fx: PadFX) {
        self.project = project
        self.engine = engine
        self.fx = fx
    }

    func isPlaying() -> Bool { playing }
    private func secPerStep() -> Double { (60.0 / Double(project.bpm)) / 4 }

    func toggle() { playing ? stop() : start() }

    func start(countInBars: Int? = nil) {
        if playing { return }
        engine.start()
        engine.stopClips()      // clear any clip voices lingering from a prior run
        playing = true
        step16 = 0
        let bars = countInBars ?? project.countIn
        countSteps = bars * max(1, project.barSteps)
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
        project.emit(.transport(playing: true, hostTime: Date().timeIntervalSince1970, bar: 0, step: 0))   // host → followers play (Step 7)
    }

    /// Follower-driven start at a specific arrangement position (clock-synced follow). Like start() but
    /// seeds the playhead to (bar, step). Does NOT emit a transport op (avoids echo on followers).
    func startAt(bar: Int, step: Int) {
        if playing { stop() }
        engine.start(); engine.stopClips()
        playing = true
        let n = max(1, project.barSteps)
        step16 = ((step % n) + n) % n
        countSteps = 0
        nextStepTime = engine.now() + 0.05
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
        if engine.isMicRecording { finishAudioRecord() }
        playing = false
        timer?.cancel()
        timer = nil
        countSteps = 0
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
            finishAudioRecord()
            return
        }
        if project.audioArmedTrack != nil {
            // bring up the play-and-record session BEFORE starting the transport so the
            // engine doesn't restart mid-playback
            engine.startMicRecording { [weak self] ok in
                guard let self else { return }
                self.project.recording = true
                let punch = self.project.punchInBar      // bars before it are count-in
                self.audioRecStartBar = punch
                if !self.playing { self.start() }
                if ok {
                    self.audioRecStartNow = self.engine.micStartTime
                    self.audioRecBar0 = self.nextStepTime + Double(punch) * self.secPerStep() * Double(max(1, self.project.barSteps))
                }
            }
        } else {
            project.recording = true
            if !playing { start() }
        }
    }

    /// Finalize an audio take: trim the front by (pre-roll + round-trip latency + user
    /// offset) so it lines up with the beat, then drop it on the armed track.
    private func finishAudioRecord() {
        guard let track = project.audioArmedTrack, engine.isMicRecording,
              let (raw, lat) = engine.stopMicRecordingRaw() else { return }
        let preRoll = max(0, audioRecBar0 - audioRecStartNow)
        let offset = Double(project.audioRecOffsetMs) / 1000.0
        let trim = Int((preRoll + lat + offset) * 48_000.0)
        var data = raw
        if trim > 0 { data = trim < data.count ? Array(data.dropFirst(trim)) : [] }
        else if trim < 0 { data = Array(repeating: 0, count: -trim) + data }   // push later
        guard !data.isEmpty else { return }
        project.addAudioClip(track: track, startBar: audioRecStartBar, data: data, name: "Take")
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
        if countSteps > 0 { return }

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

        let solo = p.mixer.values.contains { $0.solo }
        let rowSolo = p.rowSolo.values.contains(true)
        let trackSolo = p.trackSolo.values.contains(true)
        let song = p.songMode
        let bar = barCount            // schedule against the lookahead bar (the bar these hits will play in)
        let curLanes = song ? p.lanesForBar(bar) : p.lanes
        let curMelody = song ? p.melodyForBar(bar) : p.melody
        let curMeta = song ? p.stepMetaForBar(bar) : p.stepMeta
        let master = p.mixer["master"] ?? MixChannel(vol: 0.9)
        if master.mute { return }

        // audio clips that start on this bar (A5 multitrack)
        if s == 0 && !p.audioClips.isEmpty {
            for clip in p.audioClips where clip.startBar == bar && !clip.muted {
                let tk = clip.track
                if p.trackMute[tk] == true { continue }
                if trackSolo && !(p.trackSolo[tk] ?? false) { continue }
                engine.playClip(clip.data, when: time, gain: clip.gain, channel: AudioEngine.melodyChannel)
            }
        }

        // Sources a live-linked track now OWNS — suppress them in the classic paths below so a promoted /
        // sent pattern plays exactly ONCE (via its track), not doubled. Seeded tracks have no link so they
        // own nothing; frozen copies carry their own data and don't reference the source. (#review)
        var ownedRows = Set<String>()
        var ownedLeadMelody = false
        var ownedPartIDs = Set<String>()
        for track in p.tracks where track.isLinked {
            guard let link = track.source.link else { continue }
            switch link.kind {
            case .lanes:  if let rows = link.rows { ownedRows.formUnion(rows) } else { ownedRows.formUnion(curLanes.keys) }
            case .melody: ownedLeadMelody = true
            case .part:   if link.partID == nil || link.partID == "lead" { ownedLeadMelody = true } else if let pid = link.partID { ownedPartIDs.insert(pid) }
            case .sequenceLanes, .sequenceMelody: break   // point at a stored sequence bank, not the live scratch buffers
            }
        }

        for (padID, lane) in curLanes {
            guard s < lane.count else { continue }
            let vel = lane[s]
            if vel == 0 { continue }
            if ownedRows.contains(padID) { continue }   // owned by a linked track → played in the additive pass
            if p.rowMute[padID] == true { continue }
            if rowSolo && !(p.rowSolo[padID] ?? false) { continue }
            // Tracks tab mute/solo
            let tk = Kit.trackOf(padID)
            if p.trackMute[tk] == true { continue }
            if trackSolo && !(p.trackSolo[tk] ?? false) { continue }
            // Song Mode: only play tracks that have a clip in this bar
            if song && !p.trackPlaysInSong(tk, atBar: bar) { continue }
            let m = p.mixer[Kit.channelOf(padID)] ?? MixChannel()
            if m.mute { continue }
            if solo && !m.solo { continue }
            // Per-step probability + conditional trigs (A9)
            let sm = curMeta[padID]?[s]
            if let sm {
                if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { continue }
                if sm.prob < 0.999 && Double.random(in: 0..<1) > sm.prob { continue }
            }
            let v = p.padVel(padID, p.fullLevel ? 1 : vel) * m.vol * master.vol * 1.3 * p.humVel()
            let when = time + p.padOffsetSec(padID) + p.humTime()
            engine.trigger(p.soundFor(padID), vel: v, when: when, opts: p.padOpts(padID, meta: sm))
            p.triggerPadLayers(padID, vel: v, when: when)
            flash(padID, at: time)
        }

        // synth / melody track (played by the knob-driven patch) — gated by the "vox" arrangement track
        if !p.melodyMuted, !ownedLeadMelody, !curMelody.isEmpty, p.trackMute["vox"] != true,
           !(trackSolo && !(p.trackSolo["vox"] ?? false)),
           !(song && !p.trackPlaysInSong("vox", atBar: bar)) {
            let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
            if !mmel.mute && !(solo && !mmel.solo) {
                let patch = p.synthPatch
                for note in curMelody where note.step == s {
                    let durSec = Double(note.dur) * secPerStep()
                    let v = note.vel * mmel.vol * master.vol * 1.25 * p.humVel()
                    engine.triggerSynth(patch, midi: note.pitch, dur: durSec, vel: v, when: time + p.humTime())
                }
            }
        }

        // extra instrument parts (Tier 2) — own gate: per-sequence in Song Mode, NOT tied to the
        // vox clip or melody mute, but still honoring the vox track mute/solo and the melody channel.
        let curParts = song ? p.partsForBar(bar) : p.parts
        if !curParts.isEmpty, p.trackMute["vox"] != true,
           !(trackSolo && !(p.trackSolo["vox"] ?? false)) {
            let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
            if !mmel.mute && !(solo && !mmel.solo) {
                for part in curParts where !part.muted && !ownedPartIDs.contains(part.id) {
                    for note in part.notes where note.step == s {
                        let durSec = Double(note.dur) * secPerStep()
                        let v = note.vel * mmel.vol * master.vol * 1.25
                        engine.triggerSynth(part.patch, midi: note.pitch, dur: durSec, vel: v, when: time)
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
        let busIdx = p.busIndex
        let trackVol = Dictionary(p.tracks.map { ($0.id, $0.vol) }, uniquingKeysWith: { a, _ in a })
        for track in p.tracks where track.playsAdditively {   // linked OR frozen, not frozen-to-audio (plays via clip)
            if p.trackMute[track.id] == true { continue }
            if trackSolo && !(p.trackSolo[track.id] ?? false) { continue }
            if song && !p.trackPlaysInSong(track.id, atBar: bar) { continue }
            // route to a group bus if assigned, else this track's own bus; group bus applies its fader as group gain (G3.4)
            let busCh = track.busParent.flatMap { busIdx[$0] } ?? (track.ownsBus ? busIdx[track.id] : nil)
            let gVol = track.busParent.flatMap { trackVol[$0] } ?? 1
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
                        if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { continue }
                        if sm.prob < 0.999 && Double.random(in: 0..<1) > sm.prob { continue }
                    }
                    let v = p.padVel(pad, p.fullLevel ? 1 : lane[s]) * m.vol * master.vol * 1.3 * track.vol * gVol * p.humVel()
                    let when = time + p.padOffsetSec(pad) + p.humTime()
                    var opts = p.padOpts(pad, meta: sm) ?? TriggerOpts()
                    opts.pan = max(-1, min(1, opts.pan + track.pan))   // per-track pan offsets the pad's pan
                    engine.trigger(p.soundFor(pad), vel: v, when: when, opts: opts, channel: busCh)
                    p.triggerPadLayers(pad, vel: v, when: when)
                    flash(pad, at: time)
                }
            case .synthPart:
                guard let (notes, patch) = p.trackNotes(track, atBar: bar) else { continue }   // live-resolved if linked
                let mmel = p.mixer["melody"] ?? MixChannel(vol: 0.85)
                if mmel.mute || (solo && !mmel.solo) { break }
                for note in notes where note.step == s {
                    let durSec = Double(note.dur) * secPerStep()
                    let v = note.vel * mmel.vol * master.vol * 1.25 * track.vol * gVol * p.humVel()
                    engine.triggerSynth(patch, midi: note.pitch, dur: durSec, vel: v, when: time + p.humTime(), pan: track.pan, channel: busCh)
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
        let prev = step16
        step16 += 1; if step16 >= n { step16 = 0 }
        if countSteps > 0 { countSteps -= 1 }
        if step16 == 0 && prev == n - 1 {
            barCount = (barCount + 1) % max(1, project.songBars)
            nudgeToLinkPhase()   // align the downbeat to the Link session (no-op when Link is off)
            // Performance mode: apply a queued pattern launch on the bar line
            if let q = project.queuedSeq { project.switchSequence(q, record: false); project.queuedSeq = nil }
        }
    }

    // MARK: Ableton Link sync (A17) — no-ops unless Link is enabled

    /// Adopt the shared session tempo each tick; if the user changed BPM here, push it to the session.
    private func linkSync() {
        guard let link, link.isOn else { return }
        if lastSyncedBpm != 0 && project.bpm != lastSyncedBpm {
            link.proposeTempo(Double(project.bpm), atHostTime: HostClock.now())
        } else if let t = link.sessionTempo() {
            let r = max(40, min(220, Int(t.rounded())))
            if r != project.bpm { project.setBpm(r) }
        }
        lastSyncedBpm = project.bpm
    }

    /// Ease FD-808's downbeat toward Link's bar phase (called on each bar line). Tune `outputLatency` on device.
    private func nudgeToLinkPhase() {
        guard let link, link.isOn else { return }
        let dt = max(0, nextStepTime - engine.now()) + AVAudioSession.sharedInstance().outputLatency
        let ht = HostClock.now() &+ HostClock.ticks(forSeconds: dt)
        guard let phase = link.phase(atHostTime: ht) else { return }   // 0 ..< quantum (bar)
        let q = link.quantum
        let corrBeats = phase > q / 2 ? (q - phase) : -phase            // shortest shift to phase 0
        nextStepTime += corrBeats * (60.0 / Double(project.bpm)) * 0.5  // ease 50% toward lock per bar
    }

    private func scheduler() {
        guard playing else { return }
        let p = project
        linkSync()
        while nextStepTime < engine.now() + ahead {
            var t = nextStepTime
            if p.swing > 0 && step16 % 2 == 1 { t += secPerStep() * p.swing * 0.66 }
            scheduleStep(step16, t)
            let showStep = step16
            let showBar = barCount            // the bar of THIS step — published at its real time, in lock-step with the step
            let counting = countSteps > 0
            let dt = t - engine.now()
            let stepT = t                     // capture as a let for the closure (record-quantize anchor)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dt)) { [weak self] in
                guard let self, self.playing else { return }
                self.project.step = counting ? -1 : showStep
                self.project.bar = showBar
                self.lastStepAudioTime = stepT
            }
            advance()
        }
    }

    /// Live fractional position within the current bar [0,1), reconstructed from the audio clock
    /// so a recorded pad hit quantizes to the step the user actually HEARD — not the lookahead
    /// playhead. Honors the active bar length (barSteps). Returns 0 when stopped.
    func recordFraction() -> Double {
        let n = Double(max(1, project.barSteps))
        guard playing, project.step >= 0 else { return 0 }
        let sps = secPerStep()
        let prog = sps > 0 ? min(1, max(0, (engine.now() - lastStepAudioTime) / sps)) : 0
        return ((Double(project.step) + prog) / n).truncatingRemainder(dividingBy: 1)
    }
}
