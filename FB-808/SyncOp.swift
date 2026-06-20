//  SyncOp.swift — the operation log (SYSTEM_AUDIT.md Step 4).
//
//  Every musical edit is a small, serializable verb. ONE op model powers three things:
//   (a) local editing — the existing mutators stay the entry point and now self-emit an op;
//   (b) remote teacher→student broadcast — the op is sent over the wire and re-applied;
//   (c) (future) live-link propagation — the same op re-derives dependent tracks deterministically.
//
//  Each `OpKind` is the serialized form of an existing `Project` mutator. `applyOp(op)` calls that
//  SAME mutator, so the student's shared @Published `Project` updates and every open screen
//  re-renders — no per-screen networking code, ever. The `isApplyingRemote` guard suppresses undo
//  pollution and op echo when applying a received op.

import Foundation

/// A single serializable edit. Synthesized Codable (Swift↔Swift; both ends are this same app).
enum OpKind: Codable {
    case setStep(pad: String, step: Int, vel: Double)               // → setStepVel / toggleStep
    case clearRow(pad: String)                                      // → clearRow
    case setMelodyNote(step: Int, pitch: Int, len: Int, on: Bool)   // → placeMelodyNote (toggle)
    case setStepMeta(pad: String, step: Int, meta: StepMeta)        // → setStepMeta
    case setTempo(bpm: Int)                                         // → setBpm
    case switchSequence(index: Int)                                // → switchSequence
    case setBank(bank: String)                                     // → bank
    case setMix(ch: String, vol: Double?, pan: Double?, mute: Bool?, solo: Bool?)  // → setMix
    case transport(playing: Bool, hostTime: Double, bar: Int, step: Int)           // → Transport (Step 7 clock-synced)
    case fullSync(snapshot: ProjectSnapshot)                       // join / reconnect / seq-gap resync only
}

/// The op envelope broadcast over the room channel.
struct SyncOp: Codable {
    var v: Int = 1                 // schema version
    var room: String = ""          // room id (class code)
    var origin: String = ""        // emitting device id (the authoritative teacher)
    var seq: UInt64 = 0            // monotonic per-room sequence (gap detection)
    var hostTime: Double = 0       // teacher host-clock timestamp (transport ops)
    var kind: OpKind
}

/// Sink for ops emitted by local edits. `NoSyncBus` drops them (solo / offline / student-follow).
/// A real bus (Step 6) serializes to Supabase Realtime Broadcast when hosting a live room.
protocol SyncBus: AnyObject {
    func emit(_ op: SyncOp)
}
final class NoSyncBus: SyncBus { func emit(_ op: SyncOp) {} }
