//  RealtimeSync.swift — live teacher↔student sync over Supabase Realtime Broadcast (SYSTEM_AUDIT Step 6).
//
//  A dependency-free client (raw URLSessionWebSocketTask speaking the Phoenix-channels protocol that
//  Supabase Realtime uses) so the app keeps its single-local-package style. The TEACHER hosts a room
//  and every musical edit emits a SyncOp that is broadcast on the room channel; each FOLLOWING student
//  receives the op and replays it through Project.applyRemote — driving the SAME @Published state, so
//  every student screen re-renders exactly like the teacher's. Students render audio LOCALLY from the
//  synced state (no audio crosses the network). Recorded audio is OUT of v1 sync (the critic's note).

import Foundation
import Combine
import CryptoKit

@MainActor
final class SessionStore: ObservableObject, SyncBus {
    enum Role: String { case solo, host, follow }

    @Published private(set) var role: Role = .solo
    @Published private(set) var connected = false
    @Published private(set) var roomCode = ""
    @Published private(set) var status = "Offline"
    @Published private(set) var opsSent = 0
    @Published private(set) var opsReceived = 0
    @Published private(set) var lastError: String?
    /// "Try it" fork: a follower temporarily stops applying teacher ops to experiment locally; Rejoin
    /// resyncs to the teacher's state on the next heartbeat fullSync.
    @Published private(set) var forked = false

    /// The live project to apply received ops into. Weak — the project owns the bus (no retain cycle).
    weak var project: Project?
    /// Follower hook: drive the local Transport when a teacher play/stop op arrives (Step 7). Set by RootView.
    var onRemoteTransport: ((Bool) -> Void)?

    /// Per-launch token used for op origin + echo filtering — distinct even for two app instances on
    /// the SAME device (a persisted deviceID would make them reject each other's ops as self-echo).
    let instanceToken = UUID().uuidString
    var deviceID = SessionStore.loadDeviceID()   // stable per device; presence id (overridable for tests)
    /// Per-session signing key (host signs every op; followers verify) — closes "any code-holder can
    /// emit as teacher". The host's public key rides each op (TOFU pin, re-asserted via heartbeat).
    let signingKey = Curve25519.Signing.PrivateKey()
    private var pinnedHostKey: Curve25519.Signing.PublicKey?
    @Published private(set) var rejectedOps = 0   // unsigned/forged ops a follower refused to apply
    private var pubKeyB64: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }
    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var topic = ""
    private var ref = 0
    private var seq: UInt64 = 0
    private var lastAppliedSeq: UInt64 = 0   // per follow-session monotonic guard (drop stale/dup ops)
    private var joined = false
    private var hbTask: Task<Void, Never>?
    private var syncHbTask: Task<Void, Never>?   // host: periodic fullSync (late-joiner + divergence backstop)
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0

    static func loadDeviceID() -> String {
        let k = "fd.deviceID"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: k); return s
    }
    /// A fresh, non-guessable room code per live class (vs a shared hardcoded one) — mitigates code
    /// enumeration and cross-class collisions.
    static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no ambiguous 0/O/1/I
        return "FD-" + String((0..<5).map { _ in alphabet[Int(arc4random_uniform(UInt32(alphabet.count)))] })
    }

    // MARK: - Session lifecycle

    func host(code: String) { start(code: code, as: .host) }
    func follow(code: String) { start(code: code, as: .follow) }

    private func start(code: String, as newRole: Role) {
        leave()
        roomCode = code.uppercased()
        role = newRole
        topic = SyncConfig.channelTopic(roomCode)
        lastAppliedSeq = 0
        reconnectAttempt = 0
        pinnedHostKey = nil   // re-pin the host key for the new room
        openConnection()
    }

    /// Open (or re-open) the WebSocket for the current role/room. Reused by reconnect.
    private func openConnection() {
        status = "Connecting…"
        lastError = nil
        let s = URLSession(configuration: .default)
        session = s
        let task = s.webSocketTask(with: SyncConfig.realtimeURL)
        ws = task
        task.resume()
        receiveLoop()
        sendJoin()
        startHeartbeat()
        if role == .host {
            project?.syncBus = self   // teacher edits now emit ops to this bus
            syncHbTask?.cancel()
            syncHbTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.broadcastFullSync()   // late joiners + Rejoin converge within ~6s
                }
            }
        }
    }

    /// Re-establish the socket after a drop, keeping the same room/role (capped exponential backoff).
    private func scheduleReconnect() {
        guard role != .solo, reconnectTask == nil else { return }
        let delay = min(20.0, pow(2.0, Double(reconnectAttempt)))   // 1,2,4,8,16,20…s
        reconnectAttempt += 1
        status = "Reconnecting…"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.role != .solo else { return }
            self.reconnectTask = nil
            self.teardownSocket()
            self.openConnection()
        }
    }

    private func teardownSocket() {
        hbTask?.cancel(); hbTask = nil
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        session?.invalidateAndCancel(); session = nil
        joined = false; connected = false; ref = 0; seq = 0
    }

    func leave() {
        reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempt = 0
        syncHbTask?.cancel(); syncHbTask = nil
        forked = false
        if role != .solo { project?.syncBus = NoSyncBus() }
        teardownSocket()
        role = .solo; status = "Offline"; roomCode = ""
    }

    /// True while following a teacher — local editing is suppressed (read-only mirror) unless forked.
    var isFollowing: Bool { role == .follow }
    /// "Try it": stop applying teacher ops and edit locally. Rejoin: resume mirroring (resyncs on next fullSync).
    func tryIt() { guard role == .follow else { return }; forked = true; status = "Trying it · \(roomCode)" }
    func rejoin() { guard role == .follow else { return }; forked = false; status = "Following · \(roomCode)" }

    // MARK: - SyncBus (teacher edit → broadcast)

    nonisolated func emit(_ op: SyncOp) {
        Task { @MainActor in self.sendOp(op) }
    }

    private func sendOp(_ op: SyncOp) {
        guard role == .host, joined else { return }
        seq += 1
        var o = op; o.room = roomCode; o.origin = instanceToken; o.seq = seq
        // Sign the EXACT op-JSON string we transmit (re-serializing an object could change bytes and
        // break verification). The frame carries {op: <json string>, sig, pub}.
        guard let data = try? JSONEncoder().encode(o), let opStr = String(data: data, encoding: .utf8) else { return }
        let sig = ((try? signingKey.signature(for: data)) ?? Data()).base64EncodedString()
        let wrapper: [String: Any] = ["op": opStr, "sig": sig, "pub": pubKeyB64]
        sendFrame(["topic": topic, "event": "broadcast",
                   "payload": ["type": "broadcast", "event": "op", "payload": wrapper],
                   "ref": nextRef()])
        opsSent += 1
    }

    /// Send the full project to the room (join / reconnect / resync). Teacher-only.
    func broadcastFullSync() {
        guard role == .host, joined, let snap = project?.snapshot() else { return }
        sendOp(SyncOp(kind: .fullSync(snapshot: snap)))
    }

    // MARK: - WebSocket plumbing (Phoenix channels, vsn=1.0.0)

    private func nextRef() -> String { ref += 1; return String(ref) }

    private func sendJoin() {
        sendFrame(["topic": topic, "event": "phx_join",
                   "payload": ["config": ["broadcast": ["self": true, "ack": false],
                                          "presence": ["key": deviceID]]],
                   "ref": nextRef()])
    }

    private func startHeartbeat() {
        hbTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sendFrame(["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": self.nextRef()])
            }
        }
    }

    private func sendFrame(_ obj: [String: Any]) {
        guard let ws, let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(str)) { [weak self] err in
            if let err { Task { @MainActor in self?.lastError = err.localizedDescription } }
        }
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    self.connected = false; self.status = "Disconnected"; self.lastError = err.localizedDescription
                    self.scheduleReconnect()   // auto-recover from a dropped socket during a live lesson
                }
            case .success(let msg):
                if case .string(let text) = msg { Task { @MainActor in self.handle(text) } }
                Task { @MainActor in self.receiveLoop() }   // keep listening
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "phx_reply":
            if let payload = obj["payload"] as? [String: Any], (payload["status"] as? String) == "ok" {
                joined = true; connected = true; reconnectAttempt = 0   // healthy connection resets backoff
                status = role == .host ? "Hosting · \(roomCode)" : (forked ? "Trying it · \(roomCode)" : "Following · \(roomCode)")
                if role == .host { broadcastFullSync() }   // give any already-listening followers current state
            }
        case "broadcast":
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["event"] as? String) == "op",
                  let wrapper = payload["payload"] as? [String: Any],
                  let opStr = wrapper["op"] as? String,
                  let opData = opStr.data(using: .utf8),
                  let op = try? JSONDecoder().decode(SyncOp.self, from: opData) else { return }
            opsReceived += 1
            // Ignore our own echo (broadcast self:true, matched by per-launch instanceToken). A non-forked
            // follower applies the teacher's ops; a forked follower experiments locally until Rejoin.
            guard op.origin != instanceToken, role == .follow, !forked else { return }
            // VERIFY the host signature — reject unsigned/forged ops so a mere code-holder can't inject
            // edits as the teacher. The host's public key is pinned on first sight (re-asserted each op).
            guard let sigB64 = wrapper["sig"] as? String, let sig = Data(base64Encoded: sigB64),
                  let pubB64 = wrapper["pub"] as? String, let pubRaw = Data(base64Encoded: pubB64),
                  let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { rejectedOps += 1; return }
            if pinnedHostKey == nil { pinnedHostKey = pub }
            guard let pinned = pinnedHostKey,
                  pinned.rawRepresentation == pub.rawRepresentation,           // same signer as pinned host
                  pinned.isValidSignature(sig, for: opData) else { rejectedOps += 1; return }
            // Monotonic guard: drop stale/duplicate ops from reordering. fullSync always applies (it's a resync).
            var isFull = false; if case .fullSync = op.kind { isFull = true }
            if !isFull, op.seq > 0, op.seq <= lastAppliedSeq { return }
            lastAppliedSeq = max(lastAppliedSeq, op.seq)
            // Transport ops drive the local Transport (not a Project mutator); everything else applies to state.
            if case .transport(let playing, _, _, _) = op.kind { onRemoteTransport?(playing) }
            else { project?.applyRemote(op) }
        case "phx_error", "phx_close":
            connected = false; status = "Disconnected"
            scheduleReconnect()
        default:
            break
        }
    }
}
