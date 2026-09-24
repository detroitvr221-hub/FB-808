import Foundation

extension ProjectSnapshot {
    /// v4 gives a pad one permanent bank identity. v3 selected the audible sample bank globally.
    /// Move the notes and every reference to them together, preserving the saved playback choice.
    @MainActor func migratedPadSlots() -> ProjectSnapshot {
        guard version < 4 else { return self }
        var result = self
        result.version = 4
        var keys = Set(padParams.keys)
        keys.formUnion(lanes.keys)
        for sequence in sequences { keys.formUnion(sequence.lanes.keys) }
        keys.formUnion((synthBank ?? [:]).keys)
        for track in tracks ?? [] {
            keys.formUnion(track.source.padRows)
            keys.formUnion((track.source.lanes ?? [:]).keys)
            keys.formUnion(track.source.link?.rows ?? [])
        }
        // Some development v3 saves already contain the new identities. Never remap their Bank A
        // content a second time just because another bank happened to be on screen when saved.
        guard !keys.contains(where: { Kit.bankOf($0) != "A" }) else { return result }

        let savedBank = Kit.bankOrder.contains(bank) ? bank : "A"
        // Legacy D synth taps recorded into melody; its drum lanes still played the drum program.
        let laneBank = savedBank == "D" && synthBank != nil ? "A" : savedBank
        func key(_ id: String) -> String {
            guard Kit.padByID[id] != nil else { return id }
            return Kit.slotKey(bank: laneBank, pad: id)
        }
        func remap<Value>(_ values: [String: Value]) -> [String: Value] {
            Dictionary(values.map { (key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        (result.padParams, result.synthBank) = Project.migratedToBankSlots(padParams: padParams, synthBank: synthBank)
        // Legacy hats shared their family choke even when playing a chop. New blank C/D slots have
        // no family defaults, so retain that old relationship explicitly in migrated parameters.
        for pad in Kit.pads where pad.defaultChoke != 0 {
            for bank in Kit.bankOrder {
                let slot = Kit.slotKey(bank: bank, pad: pad.id)
                guard Kit.padByID[slot]?.defaultChoke != pad.defaultChoke else { continue }
                var parameter = result.padParams[slot] ?? PadParam()
                if parameter.choke == 0 { parameter.choke = pad.defaultChoke }
                result.padParams[slot] = parameter
            }
        }
        // Preserve a legacy D-tagged sample in the drum lane too when a synth mapping owns D.
        if laneBank != savedBank {
            for (id, param) in padParams where param.sampleFile != nil && (param.sampleBank == nil || param.sampleBank == savedBank) {
                var copy = param; copy.sampleBank = laneBank
                result.padParams[key(id)] = copy
            }
        }
        result.lanes = remap(lanes)
        result.stepMeta = stepMeta.map(remap)
        result.rowMute = remap(rowMute)
        result.rowSolo = remap(rowSolo)
        result.selectedRow = Kit.slotKey(bank: savedBank, pad: selectedRow)
        for i in result.sequences.indices {
            result.sequences[i].lanes = remap(result.sequences[i].lanes)
            result.sequences[i].stepMeta = remap(result.sequences[i].stepMeta)
        }
        result.tracks = tracks?.map { track in
            var t = track
            t.source.padRows = t.source.padRows.map(key)
            t.source.lanes = t.source.lanes.map(remap)
            if var link = t.source.link {
                link.rows = link.rows?.map(key)
                t.source.link = link
            }
            t.source.samplePad = t.source.samplePad.map(key)
            return t
        }
        return result
    }
}
