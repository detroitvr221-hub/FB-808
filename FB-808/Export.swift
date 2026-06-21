//  Export.swift — render the song to a 16-bit WAV (offline, faster than realtime)
//  reusing the same DrumVoice / SynthVoice DSP, then share it.

import SwiftUI
import FD808Engine
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Export plan (Sendable — built on the main actor, rendered off it)

struct ExportDrum: Sendable { var sound: String; var vel: Double; var opts: TriggerOpts; var atSample: Double; var sampleData: [Float]? = nil; var busKey: String? = nil }
struct ExportSynth: Sendable { var patch: SynthPatch; var midi: Int; var dur: Double; var vel: Double; var atSample: Double; var pan: Double = 0; var busKey: String? = nil }
struct ExportClip: Sendable { var data: [Float]; var atSample: Double; var gain: Double; var channel: Int }
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
}

struct ExportFile: Identifiable { let id = UUID(); let urls: [URL] }

enum ExportFormat: Sendable {
    case wav, m4a
    nonisolated var ext: String { switch self { case .wav: "wav"; case .m4a: "m4a" } }
    nonisolated var menuLabel: String { switch self { case .wav: "WAV · lossless"; case .m4a: "M4A · AAC (compressed)" } }
    nonisolated var icon: String { switch self { case .wav: "waveform.path"; case .m4a: "waveform" } }
}

// MARK: - Build the plan from the project (mirrors the transport's per-step logic)

extension Project {
    func buildExportPlan(loopBarsOverride: Int? = nil) -> ExportPlan {
        let sr = 48_000.0
        let bpmD = Double(bpm)
        let stepDur = (60 / bpmD) / 4
        let n = max(1, barSteps)        // steps per bar (A13 time signature)
        // Resample (loopBarsOverride set) always bounces the current PATTERN, never the arrangement.
        let songMode = loopBarsOverride == nil ? self.songMode : false
        let totalBars = loopBarsOverride ?? (songMode ? songBars : 4)
        let masterCh = mixer["master"] ?? MixChannel(vol: 0.9)
        let master = masterCh.vol
        let masterMuted = masterCh.mute
        let solo = mixer.values.contains { $0.solo }
        let rowSoloOn = rowSolo.values.contains(true)
        let trackSoloOn = trackSolo.values.contains(true)

        var drums: [ExportDrum] = []
        var synths: [ExportSynth] = []

        for bar in 0..<totalBars where !masterMuted {
            let curLanes = songMode ? lanesForBar(bar) : lanes
            let curMelody = songMode ? melodyForBar(bar) : melody
            let curParts = songMode ? partsForBar(bar) : parts
            let curMeta = songMode ? stepMetaForBar(bar) : stepMeta
            // Sources a live-linked track owns — suppress in the classic paths so a sent/promoted pattern
            // bounces ONCE (via its track), matching live playback. (#review)
            var ownedRows = Set<String>()
            var ownedLeadMelody = false
            var ownedPartIDs = Set<String>()
            for track in tracks where track.isLinked {
                guard let link = track.source.link else { continue }
                switch link.kind {
                case .lanes:  if let rows = link.rows { ownedRows.formUnion(rows) } else { ownedRows.formUnion(curLanes.keys) }
                case .melody: ownedLeadMelody = true
                case .part:   if link.partID == nil || link.partID == "lead" { ownedLeadMelody = true } else if let pid = link.partID { ownedPartIDs.insert(pid) }
                case .sequenceLanes, .sequenceMelody: break
                }
            }
            for step in 0..<n {
                var t = Double(bar * n + step) * stepDur
                if swing > 0 && step % 2 == 1 { t += stepDur * swing * 0.66 }
                let atSample = t * sr

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
                    var vel = padVel(padID, fullLevel ? 1 : lane[step]) * m.vol * Project.padDrive
                    var atS = atSample + padOffsetSec(padID) * sr
                    if humanize > 0 {   // deterministic humanize so bounces are reproducible
                        var hs = UInt64(bar &* 919 &+ step &* 17 &+ 7)
                        for ch in padID.unicodeScalars { hs = hs &* 2654435761 &+ UInt64(ch.value) }
                        vel *= max(0.2, 1 + (Double((hs >> 11) % 2000) / 1000.0 - 1) * humanize * 0.18)
                        atS += (Double(hs % 2000) / 1000.0 - 1) * humanize * 0.012 * sr
                    }
                    drums.append(ExportDrum(sound: soundFor(padID), vel: vel, opts: padOpts(padID, meta: sm) ?? TriggerOpts(),
                                            atSample: atS, sampleData: padParams[padID]?.sampleFile != nil ? padSampleData[padID] : nil))
                    for ly in padParams[padID]?.layers ?? [] {   // stacked layers — were dropped from bounces (#20)
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
                            let vel = note.vel * mmel.vol * 1.25
                            synths.append(ExportSynth(patch: synthPatch, midi: note.pitch, dur: dur, vel: vel, atSample: atSample))
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
                                let vel = note.vel * mmel.vol * 1.25
                                synths.append(ExportSynth(patch: part.patch, midi: note.pitch, dur: dur, vel: vel, atSample: atSample))
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
                            let vel = padVel(padID, fullLevel ? 1 : lane[step]) * m.vol * Project.padDrive * track.vol * gVol
                            var opts = padOpts(padID, meta: sm) ?? TriggerOpts()
                            opts.pan = max(-1, min(1, opts.pan + track.pan))
                            drums.append(ExportDrum(sound: soundFor(padID), vel: vel, opts: opts,
                                                    atSample: atSample + padOffsetSec(padID) * sr,
                                                    sampleData: padParams[padID]?.sampleFile != nil ? padSampleData[padID] : nil, busKey: busKey))
                        }
                    case .synthPart:
                        guard let (notes, patch) = trackNotes(track, atBar: bar) else { continue }   // live-resolved if linked
                        let mmel = mixer["melody"] ?? MixChannel(vol: 0.85)
                        if mmel.mute || (solo && !mmel.solo) { break }
                        for note in notes where note.step == step {
                            let dur = Double(note.dur) * stepDur
                            let vel = note.vel * mmel.vol * 1.25 * track.vol * gVol
                            synths.append(ExportSynth(patch: patch, midi: note.pitch, dur: dur, vel: vel, atSample: atSample, pan: track.pan, busKey: busKey))
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
            if clip.startBar >= totalBars { continue }
            let atSample = Double(clip.startBar) * stepDur * Double(n) * sr
            clips.append(ExportClip(data: clip.data, atSample: atSample, gain: clip.gain, channel: AudioEngine.melodyChannel))
            audioEnd = max(audioEnd, atSample + Double(clip.data.count))
        }

        // longer tail when reverb/delay is on, so the wash isn't cut off
        let tail = (fxSettings.reverbMix > 0.001 || fxSettings.delayMix > 0.001) ? 4.0 : 2.0
        let songFrames = Int(Double(totalBars * n) * stepDur * sr) + Int(tail * sr)
        let totalFrames = max(songFrames, Int(audioEnd) + Int(0.1 * sr))   // don't clip an audio take short
        let order = busOrder
        let cfx = order.map { channelFX[$0] ?? ChannelFX() }
        var idx: [String: Int] = [:]; for (i, id) in order.enumerated() { idx[id] = i }
        return ExportPlan(drums: drums, synths: synths, audioClips: clips, totalFrames: totalFrames, master: master, sr: sr, name: name, bars: totalBars, fx: fxSettings, channelFX: cfx, masterBus: masterBus, busCount: order.count, busIndex: idx, busOrder: order)
    }

    /// A DRY, unity-gain plan containing ONLY one frozen track's voices — for bus-freeze (render the
    /// track to an AudioClip so it costs one voice). No master FX/bus (re-applied on playback).
    func buildSoloTrackPlan(_ track: Track) -> ExportPlan {
        let sr = 48_000.0, stepDur = (60 / Double(bpm)) / 4, n = max(1, barSteps)
        let totalBars = songMode ? songBars : 4
        var drums: [ExportDrum] = []; var synths: [ExportSynth] = []
        for bar in 0..<totalBars {
            if songMode && !trackPlaysInSong(track.id, atBar: bar) { continue }
            for step in 0..<n {
                var t = Double(bar * n + step) * stepDur
                if swing > 0 && step % 2 == 1 { t += stepDur * swing * 0.66 }
                let atSample = t * sr
                switch track.type {
                case .drumPattern:
                    guard let tlanes = trackLanes(track, atBar: bar) else { continue }   // live-resolved if linked
                    for (padID, lane) in tlanes where step < lane.count && lane[step] > 0 {
                        let m = mixer[Kit.channelOf(padID)] ?? MixChannel()
                        var opts = padOpts(padID) ?? TriggerOpts(); opts.pan = max(-1, min(1, opts.pan + track.pan))
                        drums.append(ExportDrum(sound: soundFor(padID), vel: padVel(padID, fullLevel ? 1 : lane[step]) * m.vol * Project.padDrive * track.vol,
                                                opts: opts, atSample: atSample + padOffsetSec(padID) * sr,
                                                sampleData: padParams[padID]?.sampleFile != nil ? padSampleData[padID] : nil))
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
                          name: track.name, bars: totalBars, fx: MasterFX(), channelFX: [], masterBus: MasterBus())
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
        let v = DrumVoice(kind: d.sound, vel: d.vel, seed: seed, pitch: pr)
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
        let freq = 440 * pow(2, Double(syn.midi + syn.patch.octave * 12 - 69) / 12.0)
        // Karplus string parts render with their own voice so the bounce matches playback.
        let v: Voice = syn.patch.source == "string"
            ? KarplusVoice(patch: syn.patch, freq: freq, vel: syn.vel, gate: syn.dur, sr: plan.sr)
            : SynthVoice(patch: syn.patch, freq: freq, fromFreq: 0, vel: syn.vel, gate: syn.dur)
        v.startSample = syn.atSample
        v.channel = syn.busKey.flatMap { plan.busIndex[$0] } ?? (FX_CHANNELS.firstIndex(of: "melody") ?? 5)
        v.pan = syn.pan
        voices.append(v)
    }
    for c in plan.audioClips {
        let v = AudioClipVoice(data: c.data, gain: c.gain)
        v.startSample = c.atSample
        v.channel = c.channel
        voices.append(v)
    }
    return voices
}

/// Bounce each mixer bus to its own stereo stem. CONVENTION (#215): stems are FX-dry and
/// PRE-MASTER — they include per-channel insert FX, sidechain ducking, and the single master
/// GAIN (`* m`, applied once, matching renderOffline post-#27), but NOT the master-bus EQ/limiter,
/// NOT the shared reverb/delay returns, and each stem is soft-clipped independently. So summing the
/// stems will NOT bit-reconstruct the master WAV (the master bus + reverb tail live only in the full
/// mix, and the per-stem soft-clip is nonlinear) — by design, stems are clean source material for
/// re-mixing in another DAW, not a master decomposition. Silent buses are skipped.
nonisolated func renderStems(_ plan: ExportPlan) -> [(name: String, left: [Float], right: [Float])] {
    let sr = plan.sr
    let nch = plan.busCount
    let cfx = plan.channelFX.count == nch ? plan.channelFX : Array(repeating: ChannelFX(), count: nch)
    let kickSamples = plan.drums.filter { $0.sound == "kick" }.map { $0.atSample }.sorted()
    let m = Float(plan.master)
    var stems: [(name: String, left: [Float], right: [Float])] = []

    for chIdx in 0..<nch {
        var voices = buildVoices(plan).filter { $0.channel == chIdx }
        guard !voices.isEmpty else { continue }
        voices.sort { $0.startSample < $1.startSample }

        let n = plan.totalFrames
        var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
        let strip = ChannelStrip(sr: sr); strip.configure(cfx[chIdx])
        let pf = cfx[chIdx]
        var nextIdx = 0, lastFrame = 0
        var active: [Voice] = []
        var chokeActive: [Int: DrumVoice] = [:]
        var kIdx = 0, lastKick = -1e18

        for i in 0..<n {
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
                let p = v.pan
                if p == 0 { aL += s; aR += s }
                else { aL += s * Float(p <= 0 ? 1 : 1 - p); aR += s * Float(p >= 0 ? 1 : 1 + p) }
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
            if active.isEmpty && nextIdx >= voices.count && i >= lastFrame { break }
        }
        let end = min(n, lastFrame + 1)
        stems.append((name: chIdx < plan.busOrder.count ? plan.busOrder[chIdx] : "bus\(chIdx)", left: Array(L[0..<end]), right: Array(R[0..<end])))
    }
    return stems
}

nonisolated func renderOffline(_ plan: ExportPlan) -> (left: [Float], right: [Float]) {
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
    let fxActive = plan.fx.reverbMix > 0.0001 || plan.fx.delayMix > 0.0001
    // per-channel insert FX (mirrors SynthCore so the export matches live playback)
    let nch = plan.busCount
    let cfx = plan.channelFX.count == nch ? plan.channelFX : Array(repeating: ChannelFX(), count: nch)
    let strips = (0..<nch).map { _ in ChannelStrip(sr: sr) }
    for c in 0..<nch { strips[c].configure(cfx[c]) }
    var accL = [Float](repeating: 0, count: nch)
    var accR = [Float](repeating: 0, count: nch)
    let mbus = MasterBusFX(sr: sr); mbus.configure(plan.masterBus)
    let masterActive = plan.masterBus.active
    let kickSamples = plan.drums.filter { $0.sound == "kick" }.map { $0.atSample }.sorted()
    var kIdx = 0, lastKick = -1e18

    for i in 0..<n {
        let g = Double(i)
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
        var k = 0
        while k < active.count {
            let v = active[k]
            if v.finished { active.remove(at: k); continue }
            let s = v.next(sr)
            let p = v.pan
            let ch = (v.channel >= 0 && v.channel < nch) ? v.channel : 0
            if p == 0 { accL[ch] += s; accR[ch] += s }
            else { accL[ch] += s * Float(p <= 0 ? 1 : 1 - p); accR[ch] += s * Float(p >= 0 ? 1 : 1 + p) }
            if v.finished { active.remove(at: k); continue }
            k += 1
        }
        var mixL: Float = 0, mixR: Float = 0
        var sendL: Float = 0, sendR: Float = 0
        for c in 0..<nch {
            let pf = cfx[c]
            var l: Float, r: Float
            if pf.enabled { (l, r) = strips[c].process(accL[c], accR[c], pf) }
            else { l = accL[c]; r = accR[c] }
            if pf.scAmount > 0 && scEnv > 0 { let gg = 1 - Float(pf.scAmount) * scEnv; l *= gg; r *= gg }
            mixL += l; mixR += r
            if pf.send > 0 { sendL += l * Float(pf.send); sendR += r * Float(pf.send) }
        }
        var gL = mixL * m, gR = mixR * m
        if fxActive {
            let sL = sendL * m, sR = sendR * m
            let (oL, oR) = fx.process(gL + sL, gR + sR)
            gL = oL - sL; gR = oR - sR
        }
        if masterActive { (gL, gR) = mbus.process(gL, gR, plan.masterBus) }
        L[i] = tanhf(gL * 0.8) * 1.05
        R[i] = tanhf(gR * 0.8) * 1.05
        if max(abs(gL), abs(gR)) > 2e-4 { lastFrame = i }          // last audible frame
        if active.isEmpty && nextIdx >= voices.count {             // every voice has finished
            let guardFrames = fxActive ? Int(0.1 * sr) : 0         // let the reverb/delay tail ring out
            if i >= lastFrame + guardFrames { break }
        }
    }
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

/// Write the rendered stereo signal to disk in the requested format.
/// WAV = 16-bit PCM (lossless). M4A = AAC at 192 kbps (native AVFoundation encoder; iOS has no MP3 encoder).
/// `dir` defaults to a fresh per-call batch dir; batch callers (stems) pass one shared dir. (#227)
nonisolated func writeAudio(_ format: ExportFormat, left: [Float], right: [Float], sr: Double, name: String, dir: URL = fd808ExportDir()) -> URL? {
    let frames = min(left.count, right.count)
    guard frames > 0 else { return nil }
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
    try? FileManager.default.removeItem(at: url)
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let pf = file.processingFormat   // always deinterleaved float PCM; the file converts on write
        let chunk = 16_384               // feed the encoder manageable blocks
        var i = 0
        while i < frames {
            let count = min(chunk, frames - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: AVAudioFrameCount(count)),
                  let ch = buf.floatChannelData else { return nil }
            buf.frameLength = AVAudioFrameCount(count)
            if pf.channelCount >= 2 {
                for j in 0..<count { ch[0][j] = left[i + j]; ch[1][j] = right[i + j] }
            } else {
                for j in 0..<count { ch[0][j] = (left[i + j] + right[i + j]) * 0.5 }
            }
            try file.write(from: buf)
            i += count
        }
        return url
    } catch {
        print("\(format.ext.uppercased()) export error: \(error)")
        return nil
    }
}

// Back-compat shim.
nonisolated func writeWAV(left: [Float], right: [Float], sr: Double, name: String) -> URL? {
    writeAudio(.wav, left: left, right: right, sr: sr, name: name)
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
