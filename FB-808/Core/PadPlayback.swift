import FD808Engine

enum PadPlaybackSource {
    case oneShot(String)
    case synth(SynthBankSlot)
}

struct PadPlaybackHit {
    var source: PadPlaybackSource
    var velocity: Double
    var options: TriggerOpts
}

extension Project {
    /// Resolve the instrument once for taps, sequenced hits, bounces and MIDI.
    func padPlaybackSource(_ id: String) -> PadPlaybackSource {
        if let slot = synthBank?[id] { return .synth(slot) }
        return .oneShot(soundFor(id))
    }

    func padPlaybackHits(_ id: String, velocity: Double, meta: StepMeta? = nil,
                         panOffset: Double = 0) -> [PadPlaybackHit] {
        var options = padOpts(id, meta: meta) ?? TriggerOpts()
        options.pan = max(-1, min(1, options.pan + panOffset))
        let source = padPlaybackSource(id)
        var hits = [PadPlaybackHit(source: source, velocity: velocity, options: options)]
        if case .oneShot = source {
            hits += audiblePadLayers(id).map { layer in
                PadPlaybackHit(source: .oneShot(layer.sound), velocity: velocity * layer.vol,
                               options: TriggerOpts(pitch: layer.pitch, pan: max(-1, min(1, layer.pan + panOffset))))
            }
        }
        return hits
    }

    func triggerPadPlayback(_ id: String, velocity: Double, when: Double?, meta: StepMeta? = nil,
                            panOffset: Double = 0, channel: Int? = nil) {
        for hit in padPlaybackHits(id, velocity: velocity, meta: meta, panOffset: panOffset) {
            switch hit.source {
            case .oneShot(let sound):
                engine.trigger(sound, vel: hit.velocity, when: when, opts: hit.options, channel: channel)
            case .synth(let slot):
                engine.triggerSynth(slot.patch, midi: slot.midi, dur: 0.5, vel: hit.velocity,
                                    when: when, pan: hit.options.pan, channel: channel)
            }
        }
    }

    func appendPadPlayback(_ id: String, velocity: Double, atSample: Double, meta: StepMeta? = nil,
                           panOffset: Double = 0, busKey: String? = nil,
                           drums: inout [ExportDrum], synths: inout [ExportSynth]) {
        for hit in padPlaybackHits(id, velocity: velocity, meta: meta, panOffset: panOffset) {
            switch hit.source {
            case .oneShot(let sound):
                let sample = sound.hasPrefix("smp:") ? padSampleData[String(sound.dropFirst(4))] : nil
                drums.append(ExportDrum(sound: sound, vel: hit.velocity, opts: hit.options,
                                        atSample: atSample, sampleData: sample, busKey: busKey))
            case .synth(let slot):
                synths.append(ExportSynth(patch: slot.patch, midi: slot.midi, dur: 0.5, vel: hit.velocity,
                                          atSample: atSample, pan: hit.options.pan, busKey: busKey))
            }
        }
    }
}
