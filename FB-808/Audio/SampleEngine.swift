//  SampleEngine.swift — off-thread audio-file decoding for the sampler (Phase 2 of AUDIO_ENGINE_PLAN).
//  Pure file → mono-Float PCM at a target rate, with NO engine/UI state, so it runs on a background
//  executor and never hitches the main thread on import or project load. The engine just receives the
//  already-decoded [Float] and stores it in its PCM caches.

@preconcurrency import AVFoundation   // suppress AVFAudio Sendable noise (AVAudioPCMBuffer in the converter block)

enum SampleEngine {
    /// Decode `url` to mono Float32 @ `targetSR`, capped to `maxSeconds`. Background-safe (nonisolated,
    /// touches no shared state). Returns nil on any failure.
    nonisolated static func decode(url: URL, targetSR: Double, maxSeconds: Double = 60) -> [Float]? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let srcFmt = file.processingFormat
        guard srcFmt.sampleRate > 0, maxSeconds > 0 else { return nil }
        let maxSourceFrames = AVAudioFramePosition(ceil(srcFmt.sampleRate * maxSeconds))
        let readableFrames = min(file.length, maxSourceFrames, AVAudioFramePosition(AVAudioFrameCount.max))
        let frames = AVAudioFrameCount(readableFrames)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: inBuf) } catch { return nil }

        // Fast path: already mono @ the engine rate.
        if srcFmt.sampleRate == targetSR && srcFmt.channelCount == 1 {
            let d = floats(from: inBuf, sr: targetSR, maxSeconds: maxSeconds)
            return d.isEmpty ? nil : d
        }
        // Otherwise resample + downmix to mono Float32 @ the target rate.
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: srcFmt, to: outFmt) else { return nil }
        let cap = AVAudioFrameCount(Double(frames) * targetSR / srcFmt.sampleRate) + 2048
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil else { return nil }
        let d = floats(from: outBuf, sr: targetSR, maxSeconds: maxSeconds)
        return d.isEmpty ? nil : d
    }

    /// Decode on a background executor; the result returns to the caller's actor without blocking it.
    static func decodeAsync(url: URL, targetSR: Double, maxSeconds: Double = 60) async -> [Float]? {
        await Task.detached(priority: .userInitiated) { decode(url: url, targetSR: targetSR, maxSeconds: maxSeconds) }.value
    }

    /// Pull a mono `[Float]` out of a PCM buffer (down-mixing if needed), capped to `maxSeconds`.
    nonisolated static func floats(from buf: AVAudioPCMBuffer, sr: Double, maxSeconds: Double) -> [Float] {
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        guard n > 0, ch > 0, let chans = buf.floatChannelData else { return [] }
        let cap = min(n, Int(sr * maxSeconds))
        var out = [Float](repeating: 0, count: cap)
        if ch == 1 {
            let p = chans[0]
            for i in 0..<cap { out[i] = p[i] }
        } else {
            let inv = 1 / Float(ch)
            for i in 0..<cap {
                var s: Float = 0
                for c in 0..<ch { s += chans[c][i] }
                out[i] = s * inv
            }
        }
        return out
    }
}
