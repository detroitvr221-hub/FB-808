//  FourStemSeparator.swift — 4-stem separation (vocals / drums / bass / other) via a bundled Core ML
//  model (D1, full path). This is WIRED but DORMANT until a model is added: it uses the generic Core ML
//  API (load by URL, dictionary feature providers) so it compiles with no model present and needs no
//  Xcode-generated class. When no model is bundled, callers fall back to the model-free HPSS 2-way split.
//
//  ── To enable 4-stem separation ──────────────────────────────────────────────────────────────────
//  1. Convert a Demucs-class model (e.g. htdemucs / hybrid Demucs, or Open-Unmix) to Core ML with
//     coremltools, producing `StemSeparator.mlpackage` (or a compiled `.mlmodelc`).
//  2. Drag it into the FB-808 app target (check "Copy items", add to target).
//  3. If your conversion's feature names / shapes differ from the contract below, either rename them in
//     the conversion or edit `StemModelContract`. Call `FourStemSeparator.describe()` (logs the model's
//     actual I/O) to see what your export exposes, then reconcile.
//
//  Assumed I/O contract (the common Demucs Core ML export):
//    input  : MLMultiArray, shape [1, channels, L]  (stereo channels=2), float32, model sample rate.
//    output : MLMultiArray, shape [1, sources, channels, L]  (sources=4), float32.
//  Feature NAMES and the segment length L are auto-discovered from the model description, so usually
//  only the sample rate / stem order below need attention.

import Foundation
import CoreML
import os

enum StemModelContract {
    static let modelName = "StemSeparator"     // <modelName>.mlpackage / .mlmodelc in the app bundle
    static let sampleRate = 44_100.0           // Demucs operates at 44.1 kHz; we resample to/from engine SR
    static let stemOrder = ["Drums", "Bass", "Other", "Vocals"]   // Demucs default source order
    static let segmentSeconds = 7.8            // fallback chunk length if the model's input length is flexible
    static let overlapSeconds = 0.25           // cross-fade overlap between chunks
}

final class FourStemSeparator {
    struct Stem { let name: String; let audio: [Float] }   // mono (L/R averaged) at the engine sample rate

    private static let log = Logger(subsystem: "com.FB-808", category: "stems")

    /// Is a 4-stem Core ML model bundled with the app?
    static var modelAvailable: Bool { modelURL != nil }

    private static var modelURL: URL? {
        Bundle.main.url(forResource: StemModelContract.modelName, withExtension: "mlmodelc")
        ?? Bundle.main.url(forResource: StemModelContract.modelName, withExtension: "mlpackage")
    }

    /// Log the bundled model's input/output descriptions — run once after adding a model to reconcile the contract.
    static func describe() {
        guard let url = modelURL, let model = try? MLModel(contentsOf: url) else { log.info("stems: no model bundled"); return }
        let d = model.modelDescription
        for (name, desc) in d.inputDescriptionsByName {
            log.info("stems IN  \(name, privacy: .public): \(String(describing: desc.multiArrayConstraint?.shape), privacy: .public)")
        }
        for (name, desc) in d.outputDescriptionsByName {
            log.info("stems OUT \(name, privacy: .public): \(String(describing: desc.multiArrayConstraint?.shape), privacy: .public)")
        }
    }

    /// Separate `mono` (engine-rate) into named stems via the bundled model. Returns nil if no model is
    /// bundled or inference fails — callers should fall back to HPSS or prompt the user.
    static func separate(_ mono: [Float], engineSR: Double) -> [Stem]? {
        guard let url = modelURL else { return nil }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: cfg) else { log.error("stems: model load failed"); return nil }
        let desc = model.modelDescription

        // Discover the audio input feature + its shape.
        guard let (inName, inDesc) = desc.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let inShape = inDesc.multiArrayConstraint?.shape.map({ $0.intValue }), inShape.count >= 2 else {
            log.error("stems: no multiArray input"); return nil
        }
        guard let outName = desc.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key else {
            log.error("stems: no multiArray output"); return nil
        }
        let inChannels = inShape.count >= 3 ? max(1, inShape[inShape.count - 2]) : 1
        let fixedLen = inShape.last ?? -1                        // <=0 means flexible length
        let msr = StemModelContract.sampleRate

        // Resample engine→model rate.
        let x = resample(mono, from: engineSR, to: msr)
        let n = x.count
        guard n > 0 else { return nil }

        let seg = fixedLen > 0 ? fixedLen : Int(StemModelContract.segmentSeconds * msr)
        let overlap = min(seg / 2, Int(StemModelContract.overlapSeconds * msr))
        let stride = max(1, seg - overlap)

        var sources = 0
        var acc: [[Float]] = []                                 // per-source mono accumulator (model rate)
        var norm = [Float](repeating: 0, count: n)

        var pos = 0
        while pos < n {
            let len = min(seg, n - pos)
            guard let input = try? MLMultiArray(shape: inShape.map { NSNumber(value: $0 > 0 ? $0 : seg) }, dataType: .float32) else { return nil }
            fill(input, from: x, at: pos, count: len, channels: inChannels, segLen: seg)

            guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: input)]),
                  let out = try? model.prediction(from: provider),
                  let stems = out.featureValue(for: outName)?.multiArrayValue else {
                log.error("stems: prediction failed"); return nil
            }
            if sources == 0 {                                   // first chunk fixes the source count
                sources = sourceCount(of: stems)
                guard sources > 0 else { return nil }
                acc = Array(repeating: [Float](repeating: 0, count: n), count: sources)
            }
            accumulate(stems, into: &acc, norm: &norm, at: pos, count: len, sources: sources, segLen: seg)
            pos += stride
        }
        guard sources > 0 else { return nil }

        // Normalize the overlap-add, resample each source back to engine rate, name + return.
        return (0..<sources).map { s in
            var m = [Float](repeating: 0, count: n)
            for i in 0..<n { m[i] = acc[s][i] / (norm[i] > 1e-6 ? norm[i] : 1) }
            let back = resample(m, from: msr, to: engineSR)
            let name = s < StemModelContract.stemOrder.count ? StemModelContract.stemOrder[s] : "Stem \(s + 1)"
            return Stem(name: name, audio: back)
        }
    }

    // MARK: - Tensor plumbing

    /// Write a stereo (or mono) segment of `x` into the model input, mono duplicated across channels, zero-padded.
    private static func fill(_ arr: MLMultiArray, from x: [Float], at pos: Int, count: Int, channels: Int, segLen: Int) {
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        let st = arr.strides.map { $0.intValue }
        let cStride = st.count >= 3 ? st[st.count - 2] : 0
        let lStride = st.last ?? 1
        for i in 0..<arr.count { p[i] = 0 }
        for c in 0..<channels {
            for i in 0..<count { p[c * cStride + i * lStride] = x[pos + i] }
        }
    }

    /// Source count from the output shape: prefer the small "sources" dim (commonly [1, S, C, L]).
    private static func sourceCount(of out: MLMultiArray) -> Int {
        let shape = out.shape.map { $0.intValue }
        // [1, S, C, L] → S ; [1, S, L] → S ; [S, C, L] → S
        if shape.count == 4 { return shape[1] }
        if shape.count == 3 { return shape[0] == 1 ? shape[1] : shape[0] }
        return 0
    }

    /// Overlap-add one chunk's stems into the accumulators, averaging stereo→mono, with a Hann cross-fade window.
    private static func accumulate(_ out: MLMultiArray, into acc: inout [[Float]], norm: inout [Float],
                                   at pos: Int, count: Int, sources: Int, segLen: Int) {
        let p = out.dataPointer.bindMemory(to: Float.self, capacity: out.count)
        let st = out.strides.map { $0.intValue }
        let shape = out.shape.map { $0.intValue }
        let rank = shape.count
        // strides: [.., S, C, L] or [.., S, L]
        let sStride = rank == 4 ? st[1] : (shape[0] == 1 ? st[1] : st[0])
        let hasChannels = rank == 4
        let cStride = hasChannels ? st[2] : 0
        let channels = hasChannels ? shape[2] : 1
        let lStride = st.last ?? 1
        for s in 0..<sources {
            for i in 0..<count {
                let w = hann(i, count)                          // cross-fade so overlapping chunks blend
                var v: Float = 0
                for c in 0..<channels { v += p[s * sStride + c * cStride + i * lStride] }
                acc[s][pos + i] += (v / Float(channels)) * w
                if s == 0 { norm[pos + i] += w }
            }
        }
    }

    private static func hann(_ i: Int, _ n: Int) -> Float {
        guard n > 1 else { return 1 }
        return 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(n - 1))
    }

    /// Linear-interpolation resampler (adequate for stem audio; the model dominates quality).
    private static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty, abs(from - to) > 0.5 else { return x }
        let ratio = to / from
        let n = max(1, Int((Double(x.count) * ratio).rounded()))
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let src = Double(i) / ratio
            let i0 = Int(src), f = Float(src - Double(i0))
            let a = i0 < x.count ? x[i0] : 0
            let b = i0 + 1 < x.count ? x[i0 + 1] : a
            y[i] = a + (b - a) * f
        }
        return y
    }
}
