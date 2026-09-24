//  SampleEngine.swift — off-thread audio-file decoding for the sampler (Phase 2 of AUDIO_ENGINE_PLAN).
//  Pure file → mono-Float PCM at a target rate, with NO engine/UI state, so it runs on a background
//  executor and never hitches the main thread on import or project load. The engine just receives the
//  already-decoded [Float] and stores it in its PCM caches.

@preconcurrency import AVFoundation   // suppress AVFAudio Sendable noise (AVAudioPCMBuffer in the converter block)

enum SampleEngine {
    struct DecodedAudio: Sendable {
        let left: [Float]
        let right: [Float]?
        let sourceSeconds: Double
        let sourceChannels: Int
    }

    nonisolated static func decode(url: URL, targetSR: Double, maxSeconds: Double = 60) -> [Float]? {
        decodeChannels(url: url, targetSR: targetSR, maxSeconds: maxSeconds, stereo: false)?.left
    }

    /// Preserve stereo for arrangement takes, or deliberately downmix for a mono pad/sampler.
    nonisolated static func decodeChannels(url: URL, targetSR: Double, maxSeconds: Double = 60,
                                           stereo: Bool) -> DecodedAudio? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard targetSR.isFinite, targetSR > 0, maxSeconds.isFinite, maxSeconds > 0,
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        guard src.sampleRate > 0, src.channelCount > 0 else { return nil }
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(ceil(src.sampleRate * maxSeconds)), AVAudioFramePosition(AVAudioFrameCount.max)))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else { return nil }
        do { try file.read(into: input) } catch { return nil }
        // Keep the channels through sample-rate conversion. AVAudioConverter's default channel map
        // selects the left channel when converting stereo to mono; explicitly average below instead.
        let channels = src.channelCount
        let output: AVAudioPCMBuffer
        if src.sampleRate == targetSR && src.channelCount == channels && input.floatChannelData != nil {
            output = input
        } else {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: channels, interleaved: false),
                  let converter = AVAudioConverter(from: src, to: format),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(frames) * targetSR / src.sampleRate) + 2048) else { return nil }
            var fed = false
            var error: NSError?
            converter.convert(to: buffer, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return input
            }
            guard error == nil else { return nil }
            output = buffer
        }
        let count = min(Int(output.frameLength), Int(targetSR * maxSeconds))
        guard count > 0, let data = output.floatChannelData else { return nil }
        let left = stereo ? Array(UnsafeBufferPointer(start: data[0], count: count))
            : floats(from: output, sr: targetSR, maxSeconds: maxSeconds)
        return DecodedAudio(left: left,
                            right: stereo && channels > 1 ? Array(UnsafeBufferPointer(start: data[1], count: count)) : nil,
                            sourceSeconds: Double(file.length) / src.sampleRate, sourceChannels: Int(src.channelCount))
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
