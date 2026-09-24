import Foundation

enum ArrangementEdit {
    case insert, delete, duplicate
}

extension Project {
    /// Prepare audio edits before changing the document. Crops/splits get new immutable WAVs, leaving
    /// the original files available to Undo and other saved projects. An I/O failure aborts the edit.
    func prepareAudioRangeEdit(_ edit: ArrangementEdit, at bar: Int, length: Int) -> [AudioClip]? {
        let framesPerBar = Double(barSteps) * 60 / Double(bpm) / 4 * engine.sampleRate
        let lower = Int((Double(bar) * framesPerBar).rounded())
        let upper = Int((Double(bar + length) * framesPerBar).rounded())
        var output: [AudioClip] = []
        var created: [UUID] = []
        var failed = false

        func segment(_ clip: AudioClip, from lo: Int, to hi: Int, startBar: Int, copy: Bool = false) {
            guard !failed, startBar >= 0, startBar < songBars else { return }
            let start = Int((Double(clip.startBar) * framesPerBar).rounded())
            let offset = max(0, lo - start)
            let end = min(clip.data.count, hi - start)
            guard end > offset else { return }
            var result = clip
            result.startBar = startBar
            if offset != 0 || end != clip.data.count || copy {
                result.id = UUID()
                result.data = Array(clip.data[offset..<end])
                result.dataR = clip.dataR.map { Array($0[min(offset, $0.count)..<min(end, $0.count)]) }
                result.durSec = Double(result.data.count) / engine.sampleRate
                result.wave = Self.downsamplePeaks(result.data)
                created.append(result.id)
                guard writeClipWAV(result.data, id: result.id, sr: engine.sampleRate),
                      result.dataR.map({ writeClipWAVRight($0, id: result.id, sr: engine.sampleRate) }) ?? true else {
                    failed = true; return
                }
            }
            output.append(result)
        }

        for clip in audioClips {
            let start = Int((Double(clip.startBar) * framesPerBar).rounded())
            let end = start + clip.data.count
            let cut = edit == .duplicate ? upper : lower
            switch edit {
            case .insert, .duplicate:
                if end <= cut { segment(clip, from: start, to: end, startBar: clip.startBar) }
                else if start >= cut { segment(clip, from: start, to: end, startBar: clip.startBar + length) }
                else {
                    segment(clip, from: start, to: cut, startBar: clip.startBar)
                    segment(clip, from: cut, to: end, startBar: (edit == .duplicate ? bar + length : bar) + length)
                }
                if edit == .duplicate {
                    segment(clip, from: max(start, lower), to: min(end, upper),
                            startBar: max(clip.startBar, bar) + length, copy: true)
                }
            case .delete:
                if end <= lower { segment(clip, from: start, to: end, startBar: clip.startBar) }
                else if start >= upper { segment(clip, from: start, to: end, startBar: clip.startBar - length) }
                else {
                    segment(clip, from: start, to: min(end, lower), startBar: clip.startBar)
                    segment(clip, from: max(start, upper), to: end, startBar: bar)
                }
            }
        }
        if failed {
            created.forEach { deleteClipWAV(id: $0) }
            audioWriteFailed = true
            return nil
        }
        return output
    }

    func remapSongAutomation(_ edit: ArrangementEdit, at bar: Int, length: Int) {
        let neutral = songAutoTarget == "filter" ? 1.0 : 0.0
        var values = Array(songAuto.prefix(songBars))
        values += Array(repeating: neutral, count: max(0, songBars - values.count))
        let start = min(values.count, max(0, bar)), end = min(values.count, start + length)
        switch edit {
        case .insert: values.insert(contentsOf: Array(repeating: neutral, count: length), at: start)
        case .delete: values.removeSubrange(start..<end)
        case .duplicate: values.insert(contentsOf: Array(values[start..<end]), at: end)
        }
        songAuto = Array((values + Array(repeating: neutral, count: songBars)).prefix(songBars))
    }
}
