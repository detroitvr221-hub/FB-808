import Foundation

extension Project {
    func startSamplerRecording(completion: @escaping (Bool) -> Void) {
        let id = projectID
        engine.startMicRecording(owner: .sampler(id), finish: { [weak self] in
            guard let self, self.projectID == id else { return }
            self.mutateSample("mic") {
                if let r = self.engine.stopMicRecording() {
                    self.sample = SampleState(name: "Mic Recording", kind: "mic", dur: r.dur,
                                              wave: r.wave, transients: r.transients)
                    self.sliceBank = nil
                }
            }
        }) { [weak self] ok in
            guard let self, self.projectID == id else { return }
            if ok { self.checkpoint("startCapture", coalesce: false) }
            completion(ok)
        }
    }

    /// Shared on-screen/controller path. Note identity includes the MIDI channel at the call site;
    /// quantization, velocity and count-in handling are identical for both input devices.
    func playAndRecordNote(_ key: String, midi: Int, velocity: Double = 1, fraction: Double) {
        synthNoteOn(key, midi: midi, vel: velocity)
        guard midiArmed, playing, !countingIn,
              let step = Self.quantizedStep(fraction, barSteps: barSteps, quantize: quantize) else { return }
        captureNote(pitch: midi, step: step, wrapped: step == 0 && fraction > 0.5, velocity: velocity)
    }
}
