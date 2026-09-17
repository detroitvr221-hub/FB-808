//  Export.swift — render the song to a 16-bit WAV (offline, faster than realtime)
//  reusing the same DrumVoice / SynthVoice DSP, then share it.

import SwiftUI
import FD808Engine
import os
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Export plan (Sendable — built on the main actor, rendered off it)

struct ExportDrum: Sendable { var sound: String; var vel: Double; var opts: TriggerOpts; var atSample: Double; var sampleData: [Float]? = nil; var busKey: String? = nil }
struct ExportSynth: Sendable { var patch: SynthPatch; var midi: Int; var dur: Double; var vel: Double; var atSample: Double; var pan: Double = 0; var busKey: String? = nil }
struct ExportClip: Sendable { var data: [Float]; var dataR: [Float]? = nil; var atSample: Double; var gain: Double; var channel: Int }
struct ExportPlan: Sendable {
    var drums: [ExportDrum]
    var synths: [ExportSynth]
    var audioClips: [ExportClip]
    var totalFrames: Int
    var master: Double
    var sr: Double
    var name: String
    var bars: Int
    var fx: MasterFX
    var channelFX: [ChannelFX]    // per-bus inserts, in busOrder order
    var masterBus: MasterBus      // master EQ + limiter
    var busCount: Int = FX_CHANNELS.count           // dynamic insert-FX bus count (G2/G3)
    var busIndex: [String: Int] = [:]               // bus-owner id → strip slot (G3 per-track buses)
    var busOrder: [String] = FX_CHANNELS            // strip slot → owner id (for stem names)
    var safetyEnabled = true                         // always-on master limiter (mirror SynthCore live)
    var safetyCeilingDb = -1.0
    var instrumentSources = InstrumentSourceSnapshot()
    var quality = AudioQuality()
    var automation: [AutoPoint] = []                 // sorted FX-automation schedule (filter/reverb/delay sweeps)
}

/// One FX-automation breakpoint for the offline bounce — mirrors a live per-step applyAuto() call.
struct AutoPoint: Sendable { var atSample: Double; var target: String; var value: Double }

struct ExportFile: Identifiable { let id = UUID(); let urls: [URL] }

nonisolated enum ExportFormat: Sendable {
    case wav, m4a
    nonisolated var ext: String { switch self { case .wav: "wav"; case .m4a: "m4a" } }
    nonisolated var icon: String { switch self { case .wav: "waveform.path"; case .m4a: "waveform" } }
}

// MARK: - Build the plan from the project (mirrors the transport's per-step logic)

extension Project {
    /// Deterministic humanize for one bounced note/hit: a velocity scale and a time offset in seconds.
    /// Seeded from `seed` + (bar, step) so a bounce is reproducible. The drums already used this arithmetic;
    /// the synth/part paths ran dead on the grid, so a Humanized project exported with a rigid synth while
    /// the drums drifted — playback and the shared file did not match (finding 73).
    nonisolated static func humanized(seed: String, bar: Int, step: Int,
                                      amount: Double) -> (velScale: Double, timeOffset: Double) {
        guard amount > 0 else { return (1, 0) }
        var hs = UInt64(bar &* 919 &+ step &* 17 &+ 7)
        for ch in seed.unicodeScalars { hs = hs &* 2654435761 &+ UInt64(ch.value) }
        let velScale = max(0.2, 1 + (Double((hs >> 11) % 2000) / 1000.0 - 1) * amount * 0.18)
        let timeOffset = (Double(hs % 2000) / 1000.0 - 1) * amount * 0.012
        return (velScale, timeOffset)
    }

    func buildExportPlan(loopBarsOverride: Int? = nil, songModeOverride: Bool? = nil, safetyEnabled: Bool = true, safetyCeilingDb: Double = -1.0) -> ExportPlan {
        let sr = engine.sampleRate   // render at the engine rate (Phase 5/8) so recorded audio clips stay in sync; 48 k by default
        let bpmD = Double(bpm)
        let stepDur = (60 / bpmD) / 4
        let n = max(1, barSteps)        // steps per bar (A13 time signature)
        // Resample (loopBarsOverride set) always bounces the current PATTERN, never the arrangement.
        let songMode = loopBarsOverride == nil ? (songModeOverride ?? self.songMode) : false
        let totalBars = loopBarsOverride ?? (songMode ? songBars : 4)
        let masterCh = mixer["master"] ?? MixChannel(vol: 0.9)
        // Live applies the fader (baked into velocities) AND a fixed 0.9 render trim (RootView
        // engine.setVolume(0.9)); fold that same trim in here so the bounce level matches monitoring.
        let master = masterCh.vol * 0.9
        let masterMuted = masterCh.mute
        var automation: [AutoPoint] = []   // FX-automation schedule, mirrors Transport.scheduleStep
        let solo = mixer.values.contains { $0.solo }
        let rowSoloOn = rowSolo.values.contains(true)
        let trackSoloOn = trackSolo.values.contains(true)

        var drums: [ExportDrum] = []
        var synths: [ExportSynth] = []

        for bar in 0..<totalBars where !masterMuted {
            // Clip pattern pins are folded in exactly as Transport.refreshStepCache does, and the lead /
            // parts resolve per-track, so a pinned clip bounces the pattern it plays (SEQUENCE_TRACKS_AUDIT
            // finding 1 — live-vs-bounce parity is non-negotiable here).
            let pins = songMode ? clipSeqOverrides(atBar: bar) : [:]
            let curLanes = Transport.foldClipPins(base: songMode ? lanesForBar(bar) : lanes, overrides: pins,
                                                  lanesOfSeq: { self.lanesOfSeq($0) }, trackOf: { Kit.trackOf($0) })
            let curMelody = songMode ? melodyForTrack("vox", atBar: bar) : melody
            let curParts = songMode ? partsForTrack("vox", atBar: bar) : parts
            var curMeta = songMode ? stepMetaForBar(bar) : stepMeta
            for (tk, si) in pins {
                let src = stepMetaOfSeq(si)
                for pad in Set(curMeta.keys).union(src.keys) where Kit.trackOf(pad) == tk { curMeta[pad] = src[pad] }
            }
            // Sources a track owns — suppressed in the classic paths so a sent/promoted pattern bounces ONCE
            // (via its track), matching live playback. A frozen copy owns the source it captured and a
            // baked-to-audio track owns the source its clip replaced, so neither doubles. (#15)
            var ownedRows = Set<String>()
            var ownedLeadMelody = false
            var ownedPartIDs = Set<String>()
            for track in tracks where track.playsAdditively || track.frozenToAudio {
                let owned = trackOwnership(track)
                if owned.allLanes { ownedRows.formUnion(curLanes.keys) } else { ownedRows.formUnion(owned.rows) }
                ownedLeadMelody = ownedLeadMelody || owned.leadMelody
                ownedPartIDs.formUnion(owned.partIDs)
            }
            for step in 0..<n {
                var t = Double(bar * n + step) * stepDur
                if grooveID == "straight" {                 // match live: Swing slider, else the named groove feel (E4)
                    if swing > 0 && step % 2 == 1 { t += stepDur * swing * 0.66 }
                } else {
                    t += stepDur * Groove.byID(grooveID).push[step % 16]
                }
                let atSample = t * sr

                // FX-automation schedule (mirror Transport.scheduleStep so a filter/reverb/delay sweep
                // bounces exactly as it plays). Song-wide breakpoint takes priority in Song Mode.
                if songMode, songAutoTarget != "" {
                    automation.append(AutoPoint(atSample: atSample, target: songAutoTarget,
                                                value: songAutoValue(bar: bar, frac: Double(step) / Double(n))))
                } else if autoTarget != "", step < autoLane.count {
                    automation.append(AutoPoint(atSample: atSample, target: autoTarget, value: autoLane[step]))
                }

                for (padID, lane) in curLanes {
                    guard step < lane.count, lane[step] > 0 else { continue }
                    if ownedRows.contains(padID) { continue }   // owned by a linked track → bounced in the additive pass
                    if rowMute[padID] == true { continue }
                    if rowSoloOn && !(rowSolo[padID] ?? false) { continue }
                    let tk = Kit.trackOf(padID)
                    if trackMute[tk] == true { continue }
                    if trackSoloOn && !(trackSolo[tk] ?? false) { continue }
                    if songMode && !trackPlaysInSong(tk, atBar: bar) { continue }
                    let m = mixer[Kit.channelOf(padID)] ?? MixChannel()
                    if m.mute { continue }
                    if solo && !m.solo { continue }
                    // per-step probability + conditions (A9) — deterministic so bounces are reproducible
                    let sm = curMeta[padID]?[step]
                    if let sm {
                        if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { continue }
                        if sm.prob < 0.999 {
                            var seed = UInt64(bar &* 16 &+ step) &+ 1
                            for ch in padID.unicodeScalars { seed = seed &* 31 &+ UInt64(ch.value) }
                            if Double(seed % 997) / 997.0 > sm.prob { continue }
                        }
                    }
                    var vel = padVel(padID, fullLevel ? 1 : lane[step]) * padHitGain(padID)
                    var atS = atSample + padOffsetSec(padID) * sr
                    if humanize > 0 {   // deterministic humanize so bounces are reproducible
                        let h = Project.humanized(seed: padID, bar: bar, step: step, amount: humanize)
                        vel *= h.velScale
                        atS += h.timeOffset * sr
                    }
                    drums.append(ExportDrum(sound: soundFor(padID), vel: vel, opts: padOpts(padID, meta: sm) ?? TriggerOpts(),
                                            atSample: atS, sampleData: padSampleActive(padID) ? padSampleData[padID] : nil))
                    // stacked layers — were dropped from bounces (#20); each is gated by its OWN bus (finding 72)
                    for ly in audiblePadLayers(padID) {
                        drums.append(ExportDrum(sound: ly.sound, vel: vel * ly.vol, opts: TriggerOpts(pitch: ly.pitch, pan: ly.pan), atSample: atS))
                    }
                }

                if !melodyMuted, !ownedLeadMelody, !curMelody.isEmpty, trackMute["vox"] != true,
                   !(trackSoloOn && !(trackSolo["vox"] ?? false)),
                   !(songMode && !trackPlaysInSong("vox", atBar: bar)) {
                    let mmel = mixer["melody"] ?? MixChannel(vol: 0.85)
                    if !mmel.mute && !(solo && !mmel.solo) {
                        for note in curMelody where note.step == step {
                            let dur = Double(note.dur) * stepDur
                            // Humanize the synth like live does (Transport applies humVel()/humTime() to
                            // every melody note): a Humanized beat used to bounce with drifting drums and a
                            // rigid, slightly louder lead. (finding 73)
                            let h = Project.humanized(seed: "melody:\(note.pitch)", bar: bar, step: step, amount: humanize)
                            let vel = note.vel * mmel.vol * 1.25 * h.velScale
                            synths.append(ExportSynth(patch: synthPatch, midi: note.pitch, dur: dur, vel: vel,
                                                      atSample: atSample + h.timeOffset * sr))
                        }
                    }
                }

                // extra instrument parts (Tier 2) — own gate, per-sequence, decoupled from the vox clip / melody mute
                if !curParts.isEmpty, trackMute["vox"] != true,
                   !(trackSoloOn && !(trackSolo["vox"] ?? false)) {
                    let mmel = mixer["melody"] ?? MixChannel(vol: 0.85)
                    if !mmel.mute && !(solo && !mmel.solo) {
                        for part in curParts where !part.muted && !ownedPartIDs.contains(part.id) {
                            for note in part.notes where note.step == step {
                                let dur = Double(note.dur) * stepDur
                                let h = Project.humanized(seed: "part:\(part.id):\(note.pitch)", bar: bar, step: step, amount: humanize)
                                let vel = note.vel * mmel.vol * 1.25 * h.velScale
                                synths.append(ExportSynth(patch: part.patch, midi: note.pitch, dur: dur, vel: vel,
                                                          atSample: atSample + h.timeOffset * sr))
                            }
                        }
                    }
                }

                // layered tracks (Add Track / send-to-track) — LIVE-LINKED tracks resolve their source
                // live (so bounces match the edited source), FROZEN tracks bounce their captured copy.
                for track in tracks where track.playsAdditively {   // frozen-to-audio bounces via its clip
                    if trackMute[track.id] == true { continue }
                    if trackSoloOn && !(trackSolo[track.id] ?? false) { continue }
                    if songMode && !trackPlaysInSong(track.id, atBar: bar) { continue }
                    // route to a group bus if assigned, else this track's own bus; apply the group fader as gain (G3.4)
                    let busKey = track.busParent ?? (track.ownsBus ? track.id : nil)
                    let gVol = track.busParent.flatMap { pid in tracks.first { $0.id == pid }?.vol } ?? 1
                    switch track.type {
                    case .drumPattern:
                        guard let tlanes = trackLanes(track, atBar: bar) else { continue }   // live-resolved if linked
                        for (padID, lane) in tlanes {
                            guard step < lane.count, lane[step] > 0 else { continue }
                            let m = mixer[Kit.channelOf(padID)] ?? MixChannel()
                            if m.mute || (solo && !m.solo) { continue }
                            // Honor the linked track's live step prob/conditions/p-locks so the bounce matches
                            // playback (deterministic seed = reproducible, matching the classic export above). (#review)
                            let sm = trackStepMeta(track, padID, step, atBar: bar)
                            if let sm {
                                if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { continue }
                                if sm.prob < 0.999 {
                                    var seed = UInt64(bar &* 16 &+ step) &+ 1
                                    for ch in padID.unicodeScalars { seed = seed &* 31 &+ UInt64(ch.value) }
                                    if Double(seed % 997) / 997.0 > sm.prob { continue }
                                }
                            }
                            let h = Project.humanized(seed: padID, bar: bar, step: step, amount: humanize)
                            let vel = padVel(padID, fullLevel ? 1 : lane[step]) * padHitGain(padID) * track.vol * gVol * h.velScale
                            var opts = padOpts(padID, meta: sm) ?? TriggerOpts()
                            opts.pan = max(-1, min(1, opts.pan + track.pan))
                            drums.append(ExportDrum(sound: soundFor(padID), vel: vel, opts: opts,
                                                    atSample: atSample + padOffsetSec(padID) * sr + h.timeOffset * sr,
                                                    sampleData: padSampleActive(padID) ? padSampleData[padID] : nil, busKey: busKey))
                        }
                    case .synthPart:
                        guard let (notes, patch) = trackNotes(track, atBar: bar) else { continue }   // live-resolved if linked
                        let mmel = mixer["melody"] ?? MixChannel(vol: 0.85)
                        if mmel.mute || (solo && !mmel.solo) { break }
                        for note in notes where note.step == step {
                            let dur = Double(note.dur) * stepDur
                            let h = Project.humanized(seed: "track:\(track.id):\(note.pitch)", bar: bar, step: step, amount: humanize)
                            let vel = note.vel * mmel.vol * 1.25 * track.vol * gVol * h.velScale
                            synths.append(ExportSynth(patch: patch, midi: note.pitch, dur: dur, vel: vel,
                                                      atSample: atSample + h.timeOffset * sr, pan: track.pan, busKey: busKey))
                        }
                    default: break
                    }
                }
            }
        }

        // audio-track clips (A5 Phase 4)
        var clips: [ExportClip] = []
        var audioEnd = 0.0
        for clip in audioClips where !clip.muted {
            if trackMute[clip.track] == true { continue }
            if trackSoloOn && !(trackSolo[clip.track] ?? false) { continue }
            // Placement must match live playback — Transport.audioClipsToFire. In Song Mode a clip sits at
            // its arrangement bar and is dropped past the end. In a loop / resample bounce
            // (songMode == false) live replays EVERY non-muted clip from the loop top on each pass, so the
            // bounce has to wrap it to the top as well; otherwise a take punched at bar > 0 is audible at
            // the loop top live but exported at bar N — or dropped entirely when N >= the loop length —
            // which is exactly the "approved in Loop Mode, wrong in the share" failure. (#16)
            if songMode && clip.startBar >= totalBars { continue }
            // Live Loop Mode restarts every clip at EVERY bar line (Transport.audioClipsToFire at s == 0), so a
            // multi-bar loop bounce must place it once per bar, not once at bar 0 (#transport-4).
            let bars = songMode ? [clip.startBar] : Array(0..<totalBars)
            for b in bars {
                let atSample = Double(b) * stepDur * Double(n) * sr
                clips.append(ExportClip(data: clip.data, dataR: clip.dataR, atSample: atSample, gain: clip.gain, channel: AudioEngine.melodyChannel))
                audioEnd = max(audioEnd, atSample + Double(clip.data.count))
            }
        }

        // longer tail when reverb/delay is on, so the wash isn't cut off — check AUTOMATION too, not just the
        // static mix, or a beat that sweeps reverb/delay up toward the end exports with the tail chopped (#IMPEXP-03).
        let autoWash = ((autoTarget == "reverb" || autoTarget == "delay") && autoLane.contains { $0 > 0.02 })
            || ((songAutoTarget == "reverb" || songAutoTarget == "delay") && songAuto.contains { $0 > 0.02 })
        let tail = (fxSettings.reverbMix > 0.001 || fxSettings.delayMix > 0.001 || autoWash) ? 4.0 : 2.0
        let songFrames = Int(Double(totalBars * n) * stepDur * sr) + Int(tail * sr)
        let totalFrames = max(songFrames, Int(audioEnd) + Int(0.1 * sr))   // don't clip an audio take short
        let order = busOrder
        let cfx = order.map { channelFX[$0] ?? ChannelFX() }
        var idx: [String: Int] = [:]; for (i, id) in order.enumerated() { idx[id] = i }
        return ExportPlan(drums: drums, synths: synths, audioClips: clips, totalFrames: totalFrames, master: master, sr: sr, name: name, bars: totalBars, fx: fxSettings, channelFX: cfx, masterBus: masterBus, busCount: order.count, busIndex: idx, busOrder: order, safetyEnabled: safetyEnabled, safetyCeilingDb: safetyCeilingDb, instrumentSources: engine.core.instrumentSources(), quality: engine.audioQuality, automation: automation)
    }

    /// A DRY, unity-gain plan containing ONLY one frozen track's voices — for bus-freeze (render the
    /// track to an AudioClip so it costs one voice). No master FX/bus (re-applied on playback).
    func buildSoloTrackPlan(_ track: Track) -> ExportPlan {
        // Freeze renders at the engine rate: the resulting clip is played back LIVE at core.sr, so a 48 k
        // bounce of a 96 k engine would play 2× fast. Match the rate (Phase 5/8). 48 k by default.
        let sr = engine.sampleRate, stepDur = (60 / Double(bpm)) / 4, n = max(1, barSteps)
        let totalBars = songMode ? songBars : 4
        var drums: [ExportDrum] = []; var synths: [ExportSynth] = []
        for bar in 0..<totalBars {
            if songMode && !trackPlaysInSong(track.id, atBar: bar) { continue }
            for step in 0..<n {
                var t = Double(bar * n + step) * stepDur
                if grooveID == "straight" {                 // match live: Swing slider, else the named groove feel (E4)
                    if swing > 0 && step % 2 == 1 { t += stepDur * swing * 0.66 }
                } else {
                    t += stepDur * Groove.byID(grooveID).push[step % 16]
                }
                let atSample = t * sr
                switch track.type {
                case .drumPattern:
                    guard let tlanes = trackLanes(track, atBar: bar) else { continue }   // live-resolved if linked
                    for (padID, lane) in tlanes where step < lane.count && lane[step] > 0 {
                        let m = mixer[Kit.channelOf(padID)] ?? MixChannel()
                        // Same gate as live playback and the full bounce: a "fill" trig or a 50 % hat must
                        // freeze the way it plays, not at full density with its p-locks dropped (#transport-5).
                        let sm = trackStepMeta(track, padID, step, atBar: bar)
                        if let sm {
                            if !sm.cond.isEmpty && !Project.condPass(sm.cond, bar: bar) { continue }
                            if sm.prob < 0.999 {
                                var seed = UInt64(bar &* 16 &+ step) &+ 1
                                for ch in padID.unicodeScalars { seed = seed &* 31 &+ UInt64(ch.value) }
                                if Double(seed % 997) / 997.0 > sm.prob { continue }
                            }
                        }
                        var opts = padOpts(padID, meta: sm) ?? TriggerOpts(); opts.pan = max(-1, min(1, opts.pan + track.pan))
                        drums.append(ExportDrum(sound: soundFor(padID), vel: padVel(padID, fullLevel ? 1 : lane[step]) * (m.vol * Project.padDrive * padVolMul(padID)) * track.vol,
                                                opts: opts, atSample: atSample + padOffsetSec(padID) * sr,
                                                sampleData: padSampleActive(padID) ? padSampleData[padID] : nil))
                    }
                case .synthPart:
                    guard let (notes, patch) = trackNotes(track, atBar: bar) else { continue }   // live-resolved if linked
                    for note in notes where note.step == step {
                        synths.append(ExportSynth(patch: patch, midi: note.pitch, dur: Double(note.dur) * stepDur, vel: note.vel * 1.25 * track.vol, atSample: atSample, pan: track.pan))
                    }
                default: break
                }
            }
        }
        let frames = Int(Double(totalBars * n) * stepDur * sr) + Int(sr / 2)
        return ExportPlan(drums: drums, synths: synths, audioClips: [], totalFrames: frames, master: 1.0, sr: sr,
                          name: track.name, bars: totalBars, fx: MasterFX(), channelFX: [], masterBus: MasterBus(),
                          safetyEnabled: false, instrumentSources: engine.core.instrumentSources(), quality: engine.audioQuality)   // DRY freeze — limiter is re-applied on live playback
    }
}

// MARK: - Offline render (active-set, reuses the voice DSP)

/// Build the voice list for a plan (shared by the full-mix render and stem render
/// so they stay in lock-step).
nonisolated func buildVoices(_ plan: ExportPlan) -> [Voice] {
    var voices: [Voice] = []
    var seed: UInt32 = 1
    for d in plan.drums.sorted(by: { $0.atSample < $1.atSample }) {
        seed &+= 0x9e3779b9
        let pr = pow(2, d.opts.pitch / 12.0)
        // Imported one-shot: play the whole buffer (repitched) instead of synthesizing.
        if let data = d.sampleData {
            let sv = SampleVoice(data: data, offset: 0, dur: data.count, vel: d.vel, rate: pr)
            sv.startSample = d.atSample
            sv.pan = d.opts.pan
            let chKey = d.sound.hasPrefix("smp:") ? String(d.sound.dropFirst(4)) : d.sound
            sv.channel = d.busKey.flatMap { plan.busIndex[$0] } ?? (FX_CHANNELS.firstIndex(of: Kit.channelOf(chKey)) ?? 0)
            voices.append(sv)
            continue
        }
        let v = DrumVoice(kind: d.sound, vel: d.vel, seed: seed, pitch: pr, sr: plan.sr)
        v.startSample = d.atSample
        v.pan = d.opts.pan
        v.channel = d.busKey.flatMap { plan.busIndex[$0] } ?? (FX_CHANNELS.firstIndex(of: Kit.channelOf(d.sound)) ?? 0)
        if let c = d.opts.cutoff, c < 17000 { v.extCutoff = max(80, c); v.extReso = d.opts.reso }
        let needEnv = (d.opts.attack ?? 0.001) > 0.004 || d.opts.decay > 0 || (d.opts.sustain ?? 1) < 0.999 || (d.opts.release ?? 1.5) < 1.4
        if needEnv {
            v.hasAmp = true
            v.aA = d.opts.attack ?? 0.001; v.aD = d.opts.decay; v.aS = d.opts.sustain ?? 1; v.aR = d.opts.release ?? 1.5
            v.aLen = v.aA + v.aD + v.aR
        }
        v.chokeGroup = d.opts.chokeGroup
        voices.append(v)
    }
    for syn in plan.synths {
        let v = plan.instrumentSources.makeVoice(patch: syn.patch, midi: syn.midi, sampleRate: plan.sr,
                                                 velocity: syn.vel, gate: syn.dur)
        v.startSample = syn.atSample
        v.channel = syn.busKey.flatMap { plan.busIndex[$0] } ?? (FX_CHANNELS.firstIndex(of: "melody") ?? 5)
        v.pan = syn.pan
        voices.append(v)
    }
    for c in plan.audioClips {
        let v = AudioClipVoice(data: c.data, gain: c.gain)
        v.startSample = c.atSample
        v.channel = c.channel
        if let r = c.dataR {                     // stereo take → two hard-panned voices (matches live playback)
            v.pan = -1
            let vr = AudioClipVoice(data: r, gain: c.gain)
            vr.startSample = c.atSample; vr.channel = c.channel; vr.pan = 1
            voices.append(vr)
        }
        voices.append(v)
    }
    for voice in voices { voice.quality = plan.quality }
    return voices
}

/// Bounce each mixer bus to its own stereo stem. CONVENTION (#215): stems are FX-dry and
/// PRE-MASTER — they include per-channel insert FX, sidechain ducking, and the single master
/// GAIN (`* m`, applied once, matching renderOffline post-#27), but NOT the master-bus EQ/limiter,
/// NOT the shared reverb/delay returns, and each stem is soft-clipped independently. So summing the
/// stems will NOT bit-reconstruct the master WAV (the master bus + reverb tail live only in the full
/// mix, and the per-stem soft-clip is nonlinear) — by design, stems are clean source material for
/// re-mixing in another DAW, not a master decomposition. Silent buses are skipped.
/// Stereo pan gains for a voice — linear (default) or equal-power (opt-in), mirroring SynthCore so the
/// bounce matches live playback. p in -1..1.
@inline(__always) nonisolated func exportPanGains(_ p: Double, quality: AudioQuality) -> (Float, Float) {
    if quality.equalPowerPan { let a = (p + 1) * 0.25 * Double.pi; return (Float(cos(a)), Float(sin(a))) }
    return (Float(p <= 0 ? 1 : 1 - p), Float(p >= 0 ? 1 : 1 + p))
}

/// Array form (tests / small projects). Prefer the streaming overload for real exports: this one holds every
/// bus in memory at once.
nonisolated func renderStems(_ plan: ExportPlan) -> [(name: String, left: [Float], right: [Float])] {
    var out: [(name: String, left: [Float], right: [Float])] = []
    renderStems(plan, isCancelled: nil) { name, l, r in out.append((name: name, left: l, right: r)) }
    return out
}

/// Render one bus at a time and hand it to `each` (the caller writes it and lets it go). Voices are built
/// ONCE for all buses — the old loop rebuilt every voice per bus and returned all stems together, which
/// for a 64-bar song with 20 buses was ~1.7 GB of PCM before the first file landed (#export-2).
nonisolated func renderStems(_ plan: ExportPlan, isCancelled: (@Sendable () -> Bool)? = nil,
                             progress: ((Double) -> Void)? = nil,
                             each: (_ name: String, _ left: [Float], _ right: [Float]) -> Void) {
    let sr = plan.sr
    let nch = plan.busCount
    let cfx = plan.channelFX.count == nch ? plan.channelFX : Array(repeating: ChannelFX(), count: nch)
    // Finding 70: key the sidechain on the kick PAD (opts.sidechainKey), not the voice-name string, so
    // a kit/sound remap of the kick pad keeps the pump. Legacy "kick" hits still key.
    let kickSamples = plan.drums.filter { $0.opts.sidechainKey || $0.sound == "kick" }.map { $0.atSample }.sorted()
    let m = Float(plan.master)
    let allVoices = buildVoices(plan)

    for chIdx in 0..<nch {
        if isCancelled?() == true { return }   // stop rendering the remaining buses, not just writing them
        var voices = allVoices.filter { $0.channel == chIdx }
        guard !voices.isEmpty else { continue }
        voices.sort { $0.startSample < $1.startSample }

        let n = plan.totalFrames
        var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
        let strip = ChannelStrip(sr: sr); strip.configure(cfx[chIdx])
        let pf = cfx[chIdx]
        var nextIdx = 0, lastFrame = 0
        var anyAudio = false   // a genuinely all-zero bus is skipped; a quiet one is kept (round 3, export-3)
        var active: [Voice] = []
        var chokeActive: [Int: DrumVoice] = [:]
        var kIdx = 0, lastKick = -1e18

        for i in 0..<n {
            if i & 8191 == 0, isCancelled?() == true { return }   // cancel inside a long bus, not only between buses
            let g = Double(i)
            while nextIdx < voices.count && voices[nextIdx].startSample <= g {
                let v = voices[nextIdx]
                if let dv = v as? DrumVoice, dv.chokeGroup != 0 {
                    if let prev = chokeActive[dv.chokeGroup], !prev.finished {
                        prev.chokeFade = true; prev.chokeT0 = (g - prev.startSample) / sr
                    }
                    chokeActive[dv.chokeGroup] = dv
                }
                active.append(v); nextIdx += 1
            }
            while kIdx < kickSamples.count && kickSamples[kIdx] <= g { lastKick = kickSamples[kIdx]; kIdx += 1 }
            let scDt = (g - lastKick) / sr
            let scEnv: Float = (scDt >= 0 && scDt < 1) ? Float(exp(-scDt / 0.12)) : 0
            var aL: Float = 0, aR: Float = 0
            var k = 0
            while k < active.count {
                let v = active[k]
                if v.finished { active.remove(at: k); continue }
                let s = v.next(sr)
                let (gl, gr) = exportPanGains(v.pan, quality: plan.quality); aL += s * gl; aR += s * gr
                if v.finished { active.remove(at: k); continue }
                k += 1
            }
            var l: Float, r: Float
            if pf.enabled { (l, r) = strip.process(aL, aR, pf) } else { l = aL; r = aR }
            if pf.scAmount > 0 && scEnv > 0 { let gg = 1 - Float(pf.scAmount) * scEnv; l *= gg; r *= gg }
            l *= m; r *= m
            L[i] = tanhf(l * 0.8) * 1.05
            R[i] = tanhf(r * 0.8) * 1.05
            if max(abs(l), abs(r)) > 2e-4 { lastFrame = i }
            if !anyAudio && max(abs(l), abs(r)) > 1e-7 { anyAudio = true }
            if active.isEmpty && nextIdx >= voices.count && i >= lastFrame { break }
        }
        progress?(Double(chIdx + 1) / Double(max(1, nch)))
        guard anyAudio else { continue }   // truly silent bus → no stem file
        let end = min(n, lastFrame + 1)
        each(chIdx < plan.busOrder.count ? plan.busOrder[chIdx] : "bus\(chIdx)", Array(L[0..<end]), Array(R[0..<end]))
    }
}

nonisolated func renderOffline(_ plan: ExportPlan,
                               progress: (@Sendable (Double) -> Void)? = nil,
                               isCancelled: (@Sendable () -> Bool)? = nil) -> (left: [Float], right: [Float]) {
    let sr = plan.sr
    var voices = buildVoices(plan)
    voices.sort { $0.startSample < $1.startSample }
    let n = plan.totalFrames
    var L = [Float](repeating: 0, count: n)
    var R = [Float](repeating: 0, count: n)
    let m = Float(plan.master)
    var nextIdx = 0
    var active: [Voice] = []
    var chokeActive: [Int: DrumVoice] = [:]   // last hit per choke group (mirrors SynthCore)
    var lastFrame = 0
    let fx = FXChain(sr: sr)
    fx.configure(plan.fx, sr: sr)
    let hasFxAuto = plan.automation.contains { $0.target == "reverb" || $0.target == "delay" }
    let fxActive = plan.fx.reverbMix > 0.0001 || plan.fx.delayMix > 0.0001 || hasFxAuto
    // Mirror the live master chain: automated lowpass sweep + always-on safety limiter (pre soft-clip).
    // mCut glides toward its automation target (~12 ms one-pole, per sample) so the bounce matches the
    // live engine's smoothed sweep instead of stepping at each breakpoint (parity with SynthCore.render).
    var msvfL = SVF(), msvfR = SVF(), mCutTarget = 20_000.0, mCutSmooth = 20_000.0
    let mCutCoef = 1 - exp(-1.0 / (0.012 * sr))
    var exPolyGain: Float = 1                                  // polyphony-aware synth gain (mirrors live SynthCore)
    let exPolyCoef = Float(1 - exp(-1.0 / (0.015 * sr)))
    var safety = SafetyLimiter(sr: sr, ceiling: Float(pow(10, plan.safetyCeilingDb / 20)), enabled: plan.safetyEnabled)
    var aIdx = 0
    // per-channel insert FX (mirrors SynthCore so the export matches live playback)
    let nch = plan.busCount
    let cfx = plan.channelFX.count == nch ? plan.channelFX : Array(repeating: ChannelFX(), count: nch)
    let strips = (0..<nch).map { _ in ChannelStrip(sr: sr) }
    for c in 0..<nch { strips[c].configure(cfx[c]) }
    var accL = [Float](repeating: 0, count: nch)
    var accR = [Float](repeating: 0, count: nch)
    let mbus = MasterBusFX(sr: sr); mbus.configure(plan.masterBus)
    let masterActive = plan.masterBus.active
    let kickSamples = plan.drums.filter { $0.opts.sidechainKey || $0.sound == "kick" }.map { $0.atSample }.sorted()
    var kIdx = 0, lastKick = -1e18

    for i in 0..<n {
        if i & 8191 == 0 {                                 // ~every 8 k frames: report progress, honor cancel
            if isCancelled?() == true { return ([], []) }   // empty ⇒ caller writes no file
            progress?(Double(i) / Double(n))
        }
        let g = Double(i)
        // advance the FX-automation schedule (mirrors live applyAuto mapping)
        while aIdx < plan.automation.count && plan.automation[aIdx].atSample <= g {
            let ap = plan.automation[aIdx]; aIdx += 1
            switch ap.target {
            case "filter": mCutTarget = 20 * pow(900, ap.value)
            case "reverb": fx.reverbMix = Float(ap.value)
            case "delay":  fx.delayMix = Float(ap.value)
            default: break
            }
        }
        // activate voices that start now — apply choke at the moment of activation
        while nextIdx < voices.count && voices[nextIdx].startSample <= g {
            let v = voices[nextIdx]
            if let dv = v as? DrumVoice, dv.chokeGroup != 0 {
                if let prev = chokeActive[dv.chokeGroup], !prev.finished {
                    prev.chokeFade = true
                    prev.chokeT0 = (g - prev.startSample) / sr   // prev's elapsed time → dt starts at 0
                }
                chokeActive[dv.chokeGroup] = dv
            }
            active.append(v); nextIdx += 1
        }
        while kIdx < kickSamples.count && kickSamples[kIdx] <= g { lastKick = kickSamples[kIdx]; kIdx += 1 }
        let scDt = (g - lastKick) / sr
        let scEnv: Float = (scDt >= 0 && scDt < 1) ? Float(exp(-scDt / 0.12)) : 0
        for c in 0..<nch { accL[c] = 0; accR[c] = 0 }
        var nPoly = 0                                          // polyphony-aware synth gain (mirrors live)
        for v in active where !v.finished && v.polyScaled { nPoly += 1 }
        exPolyGain += (Float(1.0 / Double(max(1, nPoly)).squareRoot()) - exPolyGain) * exPolyCoef
        var k = 0
        while k < active.count {
            let v = active[k]
            if v.finished { active.remove(at: k); continue }
            var s = v.next(sr)
            if v.polyScaled { s *= exPolyGain }
            let ch = (v.channel >= 0 && v.channel < nch) ? v.channel : 0
            let (gl, gr) = exportPanGains(v.pan, quality: plan.quality); accL[ch] += s * gl; accR[ch] += s * gr
            if v.finished { active.remove(at: k); continue }
            k += 1
        }
        var mixL: Float = 0, mixR: Float = 0
        var sendL: Float = 0, sendR: Float = 0
        for c in 0..<nch {
            let pf = cfx[c]
            let (l, r) = processChannelStrip(strips[c], accL[c], accR[c], pf, scEnv: scEnv)   // shared with live render
            mixL += l; mixR += r
            if pf.send > 0 { sendL += l * Float(pf.send); sendR += r * Float(pf.send) }
        }
        mCutSmooth += (mCutTarget - mCutSmooth) * mCutCoef   // per-sample glide of the automated master filter
        let mFilter = mCutTarget < 18000 || mCutSmooth < 18000
        // Same master chain the live engine runs (FD808Engine.applyMasterBus) — one source of truth so the
        // bounce can't drift from playback.
        let (gL, gR) = applyMasterBus(mixL: mixL, mixR: mixR, sendL: sendL, sendR: sendR, master: m,
            fx: fx, fxActive: fxActive, msvfL: &msvfL, msvfR: &msvfR, mFilter: mFilter, mCut: mCutSmooth,
            mbus: mbus, masterActive: masterActive, masterBusParams: plan.masterBus, sr: sr)
        let (fl, fr) = masterFinalize(gL, gR, safety: &safety)
        L[i] = fl; R[i] = fr
        if max(abs(gL), abs(gR)) > 2e-4 { lastFrame = i }          // last audible frame
        if active.isEmpty && nextIdx >= voices.count {             // every voice has finished
            let guardFrames = fxActive ? Int(0.1 * sr) : 0         // let the reverb/delay tail ring out
            if i >= lastFrame + guardFrames { break }
        }
    }
    progress?(1.0)
    let end = min(n, lastFrame + 1)
    return (Array(L[0..<end]), Array(R[0..<end]))
}

// MARK: - File writers

// MARK: - Export temp directory (#227)

/// A fresh, unique temp subdirectory for one export batch. Each batch lands in its own
/// UUID folder so re-exporting the same beat name never overwrites a previous file (and so
/// stems of one batch stay grouped). The human-readable filename is preserved inside.
nonisolated func fd808ExportDir() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("FD808Exports", isDirectory: true)
    let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Reclaim old export batches, keeping only the newest N (the just-shared batch is always newest → kept).
nonisolated func sweepExportDirs(keepNewest: Int = 3) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("FD808Exports", isDirectory: true)
    let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let sorted = dirs.sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a > b
    }
    for d in sorted.dropFirst(max(0, keepNewest)) { try? FileManager.default.removeItem(at: d) }
}

// MARK: - Export write failures (#65)

/// Why a rendered beat could not be written to disk. `writeAudio` used to return a bare `URL?`, so every
/// export alert mapped EVERY failure — an out-of-space disk, a failed AAC encode, an unwritable container
/// — onto "add some sounds first", which is the one cause the call sites already exclude via
/// `Project.hasExportableContent`. The empty render is now distinguished from a real I/O failure so the
/// alert can name the plausible cause instead of misdiagnosing a project that already has sounds.
nonisolated enum ExportWriteFailure: Error, Equatable, Sendable {
    case empty
    case outOfSpace
    case other(String)

    /// Copy for the export-failure alert. The "add some sounds" advice belongs ONLY on the genuinely
    /// empty path; a real write failure names the plausible cause.
    var message: String {
        switch self {
        case .empty:
            return "There's nothing to export yet. Add some sounds first, then try again."
        case .outOfSpace:
            return "There isn't enough free space to save the export. Free up some space and try again."
        case .other(let reason):
            return reason.isEmpty ? "Couldn't save the export file. Please try again."
                                   : "Couldn't save the export file: \(reason)"
        }
    }

    /// Classify a thrown write/encode error so the alert can tell a full disk from an encode failure.
    /// AVFoundation wraps the Cocoa/POSIX error it actually hit, so follow `NSUnderlyingErrorKey`.
    nonisolated static func classify(_ error: Error) -> ExportWriteFailure {
        var ns: NSError? = error as NSError
        var depth = 0
        while let e = ns, depth < 8 {
            if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return .outOfSpace }
            if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return .outOfSpace }
            ns = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return .other(error.localizedDescription)
    }
}

/// Write the rendered stereo signal to disk in the requested format.
/// WAV = 16-bit PCM (lossless). M4A = AAC at 192 kbps (native AVFoundation encoder; iOS has no MP3 encoder).
/// `dir` defaults to a fresh per-call batch dir; batch callers (stems) pass one shared dir. (#227)
nonisolated func writeAudio(_ format: ExportFormat, left: [Float], right: [Float], sr: Double, name: String, dir: URL = fd808ExportDir(), dither: Bool = false) -> Result<URL, ExportWriteFailure> {
    let frames = min(left.count, right.count)
    guard frames > 0 else { return .failure(.empty) }
    // 16-bit PCM only: TPDF dither (±1 LSB triangular) decorrelates quantization error so quiet
    // fades/tails dissolve into a faint noise floor instead of gritty truncation distortion. Off by
    // default ⇒ byte-identical to before. AAC is lossy so dither is pointless there. Seeded → reproducible.
    let applyDither = dither && format == .wav
    let lsb: Float = 1.0 / 32768.0
    var rng: UInt32 = 0x2545_F491
    func rnd() -> Float { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return Float(rng) / Float(UInt32.max) }
    let settings: [String: Any]
    switch format {
    case .wav:
        settings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    case .m4a:
        settings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }
    let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
    let url = dir.appendingPathComponent("\(safe.isEmpty ? "FD808 Beat" : safe).\(format.ext)")
    // Atomic write: render into a hidden temp in the SAME dir, close it, then move into place. An
    // interrupted/failed encode never leaves a partial file at the final path (Phase 8 hardening).
    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).\(format.ext)")
    try? FileManager.default.removeItem(at: tmp)
    do {
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: settings)
            let pf = file.processingFormat   // always deinterleaved float PCM; the file converts on write
            let chunk = 16_384               // feed the encoder manageable blocks
            var i = 0
            while i < frames {
                let count = min(chunk, frames - i)
                guard let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(count)),
                      let ch = buf.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
                buf.frameLength = AVAudioFrameCount(count)
                if pf.channelCount >= 2 {
                    if applyDither {
                        for j in 0..<count {
                            ch[0][j] = left[i + j] + (rnd() - rnd()) * lsb
                            ch[1][j] = right[i + j] + (rnd() - rnd()) * lsb
                        }
                    } else {
                        for j in 0..<count { ch[0][j] = left[i + j]; ch[1][j] = right[i + j] }
                    }
                } else {
                    for j in 0..<count { ch[0][j] = (left[i + j] + right[i + j]) * 0.5 }
                }
                try file.write(from: buf)
                i += count
            }
        }   // AVAudioFile is flushed + closed here (released), before the move
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        return .success(url)
    } catch {
        fdLog.error("\(format.ext.uppercased(), privacy: .public) export error: \(error.localizedDescription, privacy: .public)")
        try? FileManager.default.removeItem(at: tmp)
        return .failure(ExportWriteFailure.classify(error))
    }
}

// MARK: - Share sheet

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
