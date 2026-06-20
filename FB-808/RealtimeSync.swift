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

    var deviceID = SessionStore.loadDeviceID()   // stable per device; overridable for tests
    private var ws: URLSessionWebSocketTask?
    private var session: URLSession?
    private var topic = ""
    private var ref = 0
    private var seq: UInt64 = 0
    private var joined = false
    private var hbTask: Task<Void, Never>?
    private var syncHbTask: Task<Void, Never>?   // host: periodic fullSync (late-joiner + divergence backstop)

    static func loadDeviceID() -> String {
        let k = "fd.deviceID"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: k); return s
    }

    // MARK: - Session lifecycle

    func host(code: String) { start(code: code, as: .host) }
    func follow(code: String) { start(code: code, as: .follow) }

    private func start(code: String, as newRole: Role) {
        leave()
        roomCode = code.uppercased()
        role = newRole
        topic = SyncConfig.channelTopic(roomCode)
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
        if newRole == .host {
            project?.syncBus = self   // teacher edits now emit ops to this bus
            syncHbTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.broadcastFullSync()   // late joiners + Rejoin converge within ~6s
                }
            }
        }
    }

    func leave() {
        hbTask?.cancel(); hbTask = nil
        syncHbTask?.cancel(); syncHbTask = nil
        joined = false; forked = false
        if role != .solo { project?.syncBus = NoSyncBus() }
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        session?.invalidateAndCancel(); session = nil
        role = .solo; connected = false; status = "Offline"; roomCode = ""; ref = 0; seq = 0
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
        var o = op; o.room = roomCode; o.origin = deviceID; o.seq = seq
        guard let data = try? JSONEncoder().encode(o),
              let opJSON = try? JSONSerialization.jsonObject(with: data) else { return }
        sendFrame(["topic": topic, "event": "broadcast",
                   "payload": ["type": "broadcast", "event": "op", "payload": opJSON],
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
                Task { @MainActor in self.connected = false; self.status = "Disconnected"; self.lastError = err.localizedDescription }
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
                joined = true; connected = true
                status = role == .host ? "Hosting · \(roomCode)" : "Following · \(roomCode)"
                if role == .host { broadcastFullSync() }   // late joiners get state on the next op anyway
            }
        case "broadcast":
            guard let payload = obj["payload"] as? [String: Any],
                  (payload["event"] as? String) == "op",
                  let opObj = payload["payload"],
                  let opData = try? JSONSerialization.data(withJSONObject: opObj),
                  let op = try? JSONDecoder().decode(SyncOp.self, from: opData) else { return }
            opsReceived += 1
            // Ignore our own echo (broadcast self:true). A non-forked follower applies the teacher's ops;
            // a forked follower is experimenting locally and resyncs only after Rejoin (next fullSync).
            guard op.origin != deviceID, role == .follow, !forked else { return }
            // Transport ops drive the local Transport (not a Project mutator); everything else applies to state.
            if case .transport(let playing, _, _, _) = op.kind { onRemoteTransport?(playing) }
            else { project?.applyRemote(op) }
        case "phx_error", "phx_close":
            connected = false; status = "Disconnected"
        default:
            break
        }
    }
}
