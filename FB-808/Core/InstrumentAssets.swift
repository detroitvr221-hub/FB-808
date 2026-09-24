import Foundation
import FD808Engine

/// M6: bumped per async preset request so a slow SoundFont load can't overwrite a newer choice.
private var presetLoadGeneration: [ObjectIdentifier: UInt64] = [:]

enum PresetApplyResult { case applied, missing, superseded }

extension Project {
    nonisolated private static func presetInstrumentURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return fd808DocsSubdir("FD808Instruments").appendingPathComponent(id + ".sf2")
    }
    private func presetInstrumentURL(_ id: String) -> URL? { Self.presetInstrumentURL(id) }

    func persistPresetInstrument(_ patch: SynthPatch) -> Bool {
        guard let id = patch.instrumentID else { return true }
        guard let data = soundFontAssets[id], let url = presetInstrumentURL(id) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    /// Synchronous variant (reads + parses on the caller). UI call sites use `applyInstrumentPresetAsync`.
    @discardableResult
    func applyInstrumentPreset(_ patch: SynthPatch) -> Bool {
        var font: (String, Data, [MultiSampleRegion])?
        if let id = patch.instrumentID, decodedSoundFonts[id] == nil {
            guard let loaded = Self.readPresetInstrument(id) else { return false }
            font = (id, loaded.data, loaded.regions)
        }
        commitInstrumentPreset(patch, font: font)
        return true
    }

    /// M6: the .sf2 read + parse (tens of MB for a GM bank) runs off the main actor; the result is committed
    /// back on main only if nothing changed meanwhile — same part being edited, same patch, and no newer
    /// preset request — so a slow load can't clobber a later pick or land on a different part.
    func applyInstrumentPresetAsync(_ patch: SynthPatch) async -> PresetApplyResult {
        let key = ObjectIdentifier(self)
        let generation = (presetLoadGeneration[key] ?? 0) &+ 1
        presetLoadGeneration[key] = generation
        guard let id = patch.instrumentID, decodedSoundFonts[id] == nil else {
            commitInstrumentPreset(patch, font: nil)
            return .applied
        }
        let part = activePart, before = editPatch
        let loaded = await Task.detached(priority: .userInitiated) { Self.readPresetInstrument(id) }.value
        guard presetLoadGeneration[key] == generation, activePart == part, editPatch == before else { return .superseded }
        guard let loaded else { return .missing }
        commitInstrumentPreset(patch, font: decodedSoundFonts[id] == nil ? (id, loaded.data, loaded.regions) : nil)
        return .applied
    }

    nonisolated private static func readPresetInstrument(_ id: String) -> (data: Data, regions: [MultiSampleRegion])? {
        guard let url = presetInstrumentURL(id), let data = try? Data(contentsOf: url),
              let parsed = SoundFont.load(data) else { return nil }
        return (data, soundFontRegions(parsed))
    }

    private func commitInstrumentPreset(_ patch: SynthPatch, font: (String, Data, [MultiSampleRegion])?) {
        checkpoint("synth", coalesce: false)
        if let (id, data, regions) = font {
            soundFontAssets[id] = data; decodedSoundFonts[id] = regions
            engine.core.setInstrumentBanks(decodedSoundFonts)
        }
        editPatch = patch
    }

    nonisolated static func soundFontRegions(_ instrument: SFInstrument) -> [MultiSampleRegion] {
        instrument.regions.map {
            MultiSampleRegion(loKey: $0.loKey, hiKey: $0.hiKey, rootKey: $0.rootKey,
                              sampleRate: $0.sampleRate, loopOn: $0.loopOn, pcm: $0.pcm,
                              loopStart: $0.loopStart, loopEnd: $0.loopEnd, tuneCents: Double($0.tuneCents))
        }
    }

    /// Embed each referenced font once. Data's copy-on-write storage is shared by undo snapshots;
    /// unreferenced assets disappear from the next save while old undo points retain their own copy.
    func referencedSoundFonts() -> [String: Data] {
        var patches: [SynthPatch] = [synthPatch]
        patches.append(contentsOf: savedSynths)
        patches.append(contentsOf: parts.map(\.patch))
        patches.append(contentsOf: sequences.flatMap { $0.parts.map(\.patch) })
        patches.append(contentsOf: tracks.compactMap { $0.source.patch })
        patches.append(contentsOf: synthBank?.values.map(\.patch) ?? [])
        let ids = Set(patches.compactMap(\.instrumentID))
        return soundFontAssets.filter { ids.contains($0.key) }
    }

    func restoreSoundFonts(_ assets: [String: Data]) {
        var decoded: [String: [MultiSampleRegion]] = [:]
        for (id, data) in assets {
            if soundFontAssets[id] == data, let cached = decodedSoundFonts[id] { decoded[id] = cached }
            else if let instrument = SoundFont.load(data) { decoded[id] = Self.soundFontRegions(instrument) }
        }
        soundFontAssets = assets
        decodedSoundFonts = decoded
        engine.core.setInstrumentBanks(decoded)
    }
}
