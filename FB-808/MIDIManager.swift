//  MIDIManager.swift — CoreMIDI input (Phase 6 of AUDIO_ENGINE_PLAN). Greenfield + isolated: it owns a
//  CoreMIDI client/input port, connects to every source, and parses the MIDI 1.0 byte stream on CoreMIDI's
//  high-priority callback thread into a lock-guarded, allocation-free ring buffer. A ~10 ms main-queue
//  poll drains that ring and maps events onto the EXISTING trigger APIs (triggerPad / synthNoteOn-Off /
//  panic) via closures — so it feeds the engine without touching the render graph or the audio thread.
//
//  Routing (conventional, predictable): channel 10 (GM drums) → pads, notes 36…51 → pads 0…15 (MPC/Ableton
//  layout, so note 36 = kick = pad 0). Every other channel → melodic synth (plays the active edit patch,
//  exactly like the on-screen keyboard). CC 123 (all-notes-off) → panic. Disabled cleanly when no device.

import CoreMIDI
import Foundation
import Combine

// MARK: - Real-time input FIFO (NOT main-actor isolated; touched only by the CoreMIDI thread + drain)

/// A fixed-capacity ring of raw 3-byte MIDI messages, guarded by an os_unfair_lock. The CoreMIDI read
/// callback parses bytes (with running-status support) straight into this ring with no allocation; the
/// main-queue drain copies them out. When the ring is full, the oldest events are dropped (never blocks
/// the callback thread). Marked @unchecked Sendable: the lock makes all access safe across threads.
final class MIDIInputFIFO: @unchecked Sendable {
    struct Raw { var status: UInt8 = 0; var d1: UInt8 = 0; var d2: UInt8 = 0 }

    private let cap = 1024
    private var ring: [Raw]
    private var head = 0          // next write
    private var tail = 0          // next read
    private var count = 0
    private var lock = os_unfair_lock_s()

    // running-status parser state (only mutated on the single CoreMIDI callback thread, but read under lock)
    private var runningStatus: UInt8 = 0
    private var dataIdx = 0
    private var dataBuf: (UInt8, UInt8) = (0, 0)
    private var inSysex = false

    init() { ring = [Raw](repeating: Raw(), count: cap) }

    /// Parse one CoreMIDI packet's bytes. Called on the CoreMIDI thread. No allocation, no logging.
    func ingest(_ packet: UnsafePointer<MIDIPacket>) {
        let len = Int(packet.pointee.length)
        guard len > 0 else { return }
        os_unfair_lock_lock(&lock)
        withUnsafePointer(to: packet.pointee.data) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: 256) { b in
                for i in 0..<min(len, 256) { parse(b[i]) }
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Byte-stream parser with MIDI running status. Must be called with the lock held.
    private func parse(_ byte: UInt8) {
        if byte >= 0xF8 { return }                       // realtime (clock/start/stop) — single byte, ignore here
        if byte == 0xF0 { inSysex = true; return }       // sysex begin
        if byte == 0xF7 { inSysex = false; runningStatus = 0; return }  // sysex end
        if inSysex { return }
        if byte & 0x80 != 0 {                            // status byte
            if byte >= 0xF0 { runningStatus = 0; dataIdx = 0; return }   // system-common: drop, clear running status
            runningStatus = byte
            dataIdx = 0
            return
        }
        // data byte
        guard runningStatus != 0 else { return }
        let needs = dataLength(runningStatus)
        if needs == 1 {
            push(runningStatus, byte, 0)                 // program change / channel pressure
            dataIdx = 0
        } else {
            if dataIdx == 0 { dataBuf.0 = byte; dataIdx = 1 }
            else { dataBuf.1 = byte; dataIdx = 0; push(runningStatus, dataBuf.0, dataBuf.1) }
        }
    }

    private func dataLength(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1                         // program change, channel pressure
        default: return 2                                 // note on/off, poly-AT, CC, pitch-bend
        }
    }

    private func push(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) {
        if count == cap { tail = (tail + 1) % cap; count -= 1 }   // drop oldest
        ring[head] = Raw(status: s, d1: d1, d2: d2)
        head = (head + 1) % cap
        count += 1
    }

    /// Copy out everything queued since the last drain (main-queue side).
    func drain() -> [Raw] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return [] }
        var out = [Raw](); out.reserveCapacity(count)
        var i = tail
        for _ in 0..<count { out.append(ring[i]); i = (i + 1) % cap }
        tail = head; count = 0
        return out
    }

    func resetParser() { os_unfair_lock_lock(&lock); runningStatus = 0; dataIdx = 0; inSysex = false; os_unfair_lock_unlock(&lock) }
}

// MARK: - MIDIManager (main-actor: lifecycle, source wiring, event dispatch to the app)

@MainActor
final class MIDIManager: ObservableObject {
    /// Pad zone — note 36 (GM kick) maps to pad 0; 16 contiguous notes cover the 4×4 grid.
    static let padBaseNote = 36
    /// GM drum channel (10 in 1-based MIDI ⇒ 9 zero-based) routes to pads; other channels play melodically.
    static let drumChannel: UInt8 = 9

    @Published private(set) var enabled = false
    @Published private(set) var sourceCount = 0
    @Published private(set) var lastEvent = "—"          // diagnostics: most recent recognized event

    /// Routing hooks — set by the app to feed the existing trigger APIs. All invoked on the main actor.
    var onPad: ((Int, Double) -> Void)?                  // (padIndex 0…15, velocity 0…1)
    var onNoteOn: ((Int, Double) -> Void)?               // (midi note, velocity 0…1) — melodic
    var onNoteOff: ((Int) -> Void)?                      // (midi note) — melodic
    var onCC: ((Int, Int, Int) -> Void)?                 // (cc, value, channel)
    var onPanic: (() -> Void)?                           // all-notes-off (CC123)

    private let fifo = MIDIInputFIFO()
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var drainTimer: Timer?
    private var started = false

    deinit {
        drainTimer?.invalidate()
        if inPort != 0 { MIDIPortDispose(inPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Create the CoreMIDI client + input port, connect to all current sources, and start the drain poll.
    /// Safe to call when no MIDI hardware is present (the common case / simulator) — it simply connects to
    /// zero sources and waits for a setup-changed notification. Never throws into the caller.
    func start() {
        guard !started else { return }
        started = true

        // Setup-changed notification re-scans sources when a controller is plugged in / removed.
        let notifyBlock: MIDINotifyBlock = { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                Task { @MainActor in self?.connectAllSources() }
            }
        }
        var status = MIDIClientCreateWithBlock("FD808.MIDIClient" as CFString, &client, notifyBlock)
        guard status == noErr else { started = false; return }

        // Block-based read callback. Runs on a high-priority CoreMIDI thread → only the lock-guarded FIFO
        // is touched (the `fifo` reference is Sendable; no main-actor state is read here).
        let fifo = self.fifo
        let readBlock: MIDIReadBlock = { pktList, _ in
            // Walk the packet list in place — advance the pointer MIDIPacketNext returns; never copy a
            // packet to a stack local (a copy makes MIDIPacketNext compute the next address off stack
            // memory, corrupting multi-packet lists like chords or fast CC sweeps).
            let count = Int(pktList.pointee.numPackets)
            withUnsafePointer(to: pktList.pointee.packet) { first in
                var p = first
                for _ in 0..<count {
                    fifo.ingest(p)
                    p = UnsafePointer(MIDIPacketNext(p))
                }
            }
        }
        status = MIDIInputPortCreateWithBlock(client, "FD808.Input" as CFString, &inPort, readBlock)
        guard status == noErr else {
            MIDIClientDispose(client); client = MIDIClientRef(); started = false; return
        }

        connectAllSources()
        enabled = true

        // ~10 ms main-queue drain. Same Timer + assumeIsolated pattern the engine uses for its reclaim/diag.
        drainTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainAndDispatch() }
        }
    }

    func stop() {
        drainTimer?.invalidate(); drainTimer = nil
        if inPort != 0 { MIDIPortDispose(inPort); inPort = MIDIPortRef() }
        if client != 0 { MIDIClientDispose(client); client = MIDIClientRef() }
        fifo.resetParser()
        enabled = false; started = false; sourceCount = 0
    }

    private func connectAllSources() {
        guard inPort != 0 else { return }
        let prev = sourceCount
        let n = MIDIGetNumberOfSources()
        var connected = 0
        for i in 0..<n {
            let src = MIDIGetSource(i)
            if src != 0, MIDIPortConnectSource(inPort, src, nil) == noErr { connected += 1 }
        }
        sourceCount = connected
        // A controller was unplugged mid-play → its held note-offs will never arrive. Release everything
        // so we don't strand a droning voice (there's no per-source note tracking to be surgical) (#MIDI-03).
        if connected < prev { onPanic?() }
    }

    private func drainAndDispatch() {
        let events = fifo.drain()
        guard !events.isEmpty else { return }
        for e in events {
            let cmd = e.status & 0xF0
            let chan = e.status & 0x0F
            switch cmd {
            case 0x90 where e.d2 > 0:                    // note on (velocity > 0)
                let vel = Double(e.d2) / 127.0
                if chan == Self.drumChannel { dispatchPad(note: Int(e.d1), vel: vel) }
                else { onNoteOn?(Int(e.d1), vel); lastEvent = "Note \(e.d1) v\(e.d2)" }
            case 0x80, 0x90:                             // note off (0x80, or note-on velocity 0)
                if chan != Self.drumChannel { onNoteOff?(Int(e.d1)) }   // pads are one-shots → ignore note-off
            case 0xB0:                                   // control change
                if e.d1 == 123 || e.d1 == 120 { onPanic?(); lastEvent = "All notes off" }   // 123 all-off / 120 all-sound-off
                else { onCC?(Int(e.d1), Int(e.d2), Int(chan)); lastEvent = "CC \(e.d1)=\(e.d2)" }
            default:
                break
            }
        }
    }

    private func dispatchPad(note: Int, vel: Double) {
        let idx = note - Self.padBaseNote
        guard idx >= 0 && idx < 16 else { return }       // outside the 16-pad zone → ignore
        onPad?(idx, vel)
        lastEvent = "Pad \(idx + 1) v\(Int(vel * 127))"
    }

    /// Diagnostics line for the Settings panel.
    var summary: String {
        guard enabled else { return "off" }
        return sourceCount == 0 ? "ready · no device" : "\(sourceCount) source\(sourceCount == 1 ? "" : "s") · \(lastEvent)"
    }
}
