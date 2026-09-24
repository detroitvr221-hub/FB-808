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

/// A live enrolled student, surfaced to the Teacher roster (name is teacher-visible by design; no PII).
struct RosterEntry: Identifiable, Equatable { let id = UUID(); let name: String; let online: Bool }

/// A host's answer to a channel (re)joining: the project snapshot, plus the transport position when
/// playback is already past the count-in (see `SessionStore.joinResync`).
struct JoinResync: Equatable {
    var fullSync: Bool
    var announceTransport: Bool
    var bar: Int
    var step: Int
}

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
    /// The host ended the class while we were following (round 3, sync-1). RootView reacts (restores the
    /// student's own beat) and acknowledges.
    @Published private(set) var classEndedByHost = false
    func acknowledgeClassEnded() { classEndedByHost = false }
    private var resyncAttempts = 0
    private var resyncAnswerTimes: [Date] = []   // host: room-wide cap on snapshot answers to `resync`
    private var pongTimes: [Date] = []           // host: room-wide cap on pong broadcasts

    /// The live project to apply received ops into. Weak — the project owns the bus (no retain cycle).
    weak var project: Project?
    /// Runs before a follow replaces the local project (RootView saves the recovery slot when there is
    /// unsaved work) — joining a class used to overwrite the student's beat with no trace (#sync-1).
    var onBeforeJoin: (() -> Void)?
    private var pendingJoinAnswer: Task<Void, Never>?   // host: coalesced (never dropped) resync answer
    private var resyncRetry: Task<Void, Never>?         // follower: re-request if no fullSync arrives
    private var lastControlFrameAt: [String: Date] = [:] // per-sender throttle for resync/ping (unauthenticated frames)
    /// Follower hook: drive the local Transport when a teacher play/stop op arrives. The bar/step are
    /// already clock-offset-adjusted to the teacher's CURRENT position (Step 7 + clock sync).
    var onRemoteTransport: ((_ playing: Bool, _ atBar: Int, _ atStep: Int) -> Void)?
    /// Estimated wall-clock offset (teacherClock − followerClock), from ping/pong (median of low-RTT).
    @Published private(set) var clockOffset: Double = 0
    private var rttSamples: [(rtt: Double, offset: Double)] = []
    private var pingTask: Task<Void, Never>?

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
    /// Fingerprint of the last snapshot broadcast to the room. The 6 s heartbeat skips an unchanged project
    /// so the whole class does not re-decode its audio (and lose undo) for nothing; reset per session.
    private var lastFullSyncFingerprint: UInt64?
    /// Debounce for responding to a follower's `resync` request (see answerJoin).
    private var lastJoinAnswerAt = Date.distantPast
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var joinWatchdog: Task<Void, Never>?   // fail-safe if the socket opens but phx_join never replies
    // Token backend (edge function `room`): teacher's host token + the live roster; student's token + presence.
    @Published private(set) var remoteRoster: [RosterEntry] = []
    @Published private(set) var roomTitle = ""
    // Student submit lifecycle — drives the Submit banner so a child sees their work reach the teacher
    // (was a fully silent network action that degraded to metadata-only without telling them).
    enum SubmitState: Equatable { case idle, submitting, sentWithAudio, sentMetadataOnly, failed }
    @Published private(set) var submitState: SubmitState = .idle
    private(set) var hostToken: String?
    // Ephemeral (in-memory, per-session) — survives reconnects within a session but a stolen value
    // can't be replayed across launches/rooms; the server re-issues on join if blank.
    var studentToken = ""
    private var rosterTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var joinTask: Task<Void, Never>?   // the async create/join handle (cancelled on re-entry/leave)
    var displayName = "Student"

    static func loadDeviceID() -> String {
        let k = "fd.deviceID"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: k); return s
    }
    /// A fresh, hard-to-guess room code per live class (vs a shared hardcoded one) — mitigates code
    /// enumeration and cross-class collisions. 6 symbols over a 32-char alphabet ≈ 1.1B codes (~30 bits).
    static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no ambiguous 0/O/1/I
        return "FD-" + String((0..<6).map { _ in alphabet[Int(arc4random_uniform(UInt32(alphabet.count)))] })
    }

    // MARK: - Resync policy (pure — unit-tested)

    /// What the host owes a channel that just (re)joined. The snapshot alone leaves a mid-song joiner — or
    /// a student who pressed Rejoin — silent until the next 6 s heartbeat carries a transport op, so the
    /// host must re-assert the transport at the same moment. `step < 0` means the teacher is still counting
    /// in: announcing then made followers start the pattern early (#18), so the snapshot goes alone.
    nonisolated static func joinResync(playing: Bool, bar: Int, step: Int) -> JoinResync {
        // step < 0 = the teacher's count-in (project.step is pinned at -1): the snapshot travels alone,
        // because announcing "playing" then made already-playing followers snap to bar 0 mid-count (#18).
        JoinResync(fullSync: true, announceTransport: playing && step >= 0, bar: max(0, bar), step: max(0, step))
    }

    /// Whether the periodic heartbeat must re-broadcast the whole project. Re-sending an unchanged 1–2 MB
    /// snapshot every 6 s made every follower re-decode its WAVs on the main actor; a fingerprint that only
    /// moves on a real change lets the heartbeat skip the no-op case, while join/reconnect/Rejoin force one.
    nonisolated static func shouldSendFullSync<R: Equatable>(force: Bool, revision: R, lastSentRevision: R?) -> Bool {
        if force { return true }                        // join / reconnect / Rejoin always converge
        guard let lastSentRevision else { return true } // nothing sent yet this session
        return revision != lastSentRevision
    }

    /// Content fingerprint of a snapshot — the heartbeat's change detector. It deliberately hashes the
    /// SNAPSHOT rather than using `editRevision`: swing, groove and the time signature are edited through
    /// @Published properties that never bump the revision, and fullSync is the only carrier those edits
    /// have. SHA-256 over every encoded byte (not `Hasher.combine(data)`: Data's Hashable only samples part
    /// of a large buffer, so a small edit deep in the JSON read as "unchanged"). (finding 47)
    nonisolated static func snapshotFingerprint(_ s: ProjectSnapshot) -> UInt64 {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // deterministic key order for equal values
        guard let data = try? enc.encode(s) else { return 0 }
        var out: UInt64 = 0
        for (i, byte) in SHA256.hash(data: data).prefix(8).enumerated() { out |= UInt64(byte) << (8 * i) }
        return out
    }

    // MARK: - Session lifecycle

    /// Teacher: create a room on the backend (registers this session's public key as the room's
    /// authoritative host key), then connect. Generates a fresh non-guessable code.
    func host(title: String? = nil) {
        leave()
        let code = SessionStore.randomCode()
        status = "Creating room…"
        joinTask?.cancel()
        joinTask = Task { @MainActor in
            let res = await callRoom(["action": "create", "code": code, "hostKey": pubKeyB64, "title": title])
            guard !Task.isCancelled else { return }   // a newer host/follow/leave superseded this
            guard res?["ok"] as? Bool == true, let token = res?["hostToken"] as? String else {
                status = "Offline"; lastError = (res?["error"] as? String) ?? "Could not create room"; return
            }
            hostToken = token
            begin(code: code, role: .host, serverHostKey: nil, channelKey: res?["channel"] as? String)
            startRosterPolling()
        }
    }

    /// Student: join a room by code (server-side display-name moderation), receive the AUTHORITATIVE
    /// host public key (removes the TOFU first-pin race) + a student token, then follow.
    func follow(code: String, name: String) {
        leave()
        onBeforeJoin?()                 // protect the beat that is about to be replaced (#sync-1)
        project?.beginRemoteSession()   // the first snapshot of this class gets its own join checkpoint
        displayName = name.isEmpty ? "Student" : name
        let up = code.uppercased()
        status = "Joining…"
        joinTask?.cancel()
        joinTask = Task { @MainActor in
            let res = await callRoom(["action": "join", "code": up, "displayName": displayName,
                                      "studentToken": studentToken.isEmpty ? nil : studentToken])
            guard !Task.isCancelled else { return }
            guard res?["ok"] as? Bool == true else {
                status = "Offline"; lastError = (res?["error"] as? String) ?? "Could not join"; return
            }
            if let st = res?["studentToken"] as? String { studentToken = st }
            if let n = res?["displayName"] as? String { displayName = n }   // moderated name from server
            if let t = res?["title"] as? String { roomTitle = t }
            var serverKey: Curve25519.Signing.PublicKey?
            if let hk = res?["hostKey"] as? String, let raw = Data(base64Encoded: hk) {
                serverKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            }
            begin(code: up, role: .follow, serverHostKey: serverKey, channelKey: res?["channel"] as? String)
            startPresence()
        }
    }

    private func begin(code: String, role newRole: Role, serverHostKey: Curve25519.Signing.PublicKey?, channelKey: String?) {
        // FAIL CLOSED on the read-gate: the realtime topic MUST be the unguessable server-issued channel
        // key, never the shoulder-surfable room code. If the server didn't return one, refuse to connect
        // rather than exposing a class of minors' live stream on a guessable/displayed topic.
        guard let key = channelKey, !key.isEmpty else {
            status = "Offline"; lastError = "Secure channel unavailable — please rejoin"; return
        }
        // Followers MUST have the server-authoritative host key — no silent TOFU fallback (else a mere
        // code-holder could race a forged op and get self-pinned as the teacher).
        if newRole == .follow && serverHostKey == nil {
            status = "Offline"; lastError = "Couldn't verify the teacher — please rejoin"; return
        }
        roomCode = code.uppercased()
        role = newRole
        topic = SyncConfig.channelTopic(key)
        lastAppliedSeq = 0
        lastFullSyncFingerprint = nil     // a new session (re)converges from scratch
        seq = 0                          // op sequence is reset only on a genuinely new session, NOT on reconnect
        reconnectAttempt = 0
        pinnedHostKey = serverHostKey    // server-authoritative; followers are guaranteed non-nil by the guard above
        rttSamples = []; clockOffset = 0
        openConnection()
        if newRole == .follow { startPing() }   // estimate the clock offset for transport alignment
    }

    // MARK: - Token backend (edge function `room`)

    private func callRoom(_ body: [String: Any?]) async -> [String: Any]? { await callFunc("room", body) }

    private func callFunc(_ name: String, _ body: [String: Any?]) async -> [String: Any]? {
        guard let url = URL(string: "https://\(SyncConfig.projectRef).supabase.co/functions/v1/\(name)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SyncConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(SyncConfig.anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // A backend rejection is explicit: a non-empty "error" string, or "ok" == false. Surface it as a
        // failure instead of reporting success on any JSON body.
        if let err = obj["error"] as? String, !err.isEmpty { return nil }
        if (obj["ok"] as? Bool) == false { return nil }
        return obj
    }

    private func startRosterPolling() {
        rosterTask?.cancel()
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let res = await self.callRoom(["action": "roster", "code": self.roomCode, "hostToken": self.hostToken]),
                   let arr = res["roster"] as? [[String: Any]] {
                    self.remoteRoster = arr.map { RosterEntry(name: ($0["name"] as? String) ?? "Student",
                                                              online: ($0["online"] as? Bool) ?? false) }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func startPresence() {
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.callRoom(["action": "presence", "code": self.roomCode, "studentToken": self.studentToken])
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Student: submit the current beat for teacher review (optional audio URL from Storage).
    @discardableResult
    func submitBeat(beatName: String, audioUrl: String?, accuracy: Double?) async -> Bool {
        let res = await callRoom(["action": "submit", "code": roomCode, "studentToken": studentToken,
                                  "displayName": displayName, "beatName": beatName, "audioUrl": audioUrl, "accuracy": accuracy])
        return res != nil
    }
    /// Teacher: list submissions / send feedback.
    /// Returns nil on a transport failure (so callers don't mistake a network blip for "no submissions"
    /// and wipe the UI), [] only when the server genuinely reports none.
    func fetchSubmissions() async -> [[String: Any]]? {
        guard let res = await callRoom(["action": "submissions", "code": roomCode, "hostToken": hostToken]) else { return nil }
        return (res["submissions"] as? [[String: Any]]) ?? []
    }
    /// False when the backend did not accept the feedback (offline, expired token) — the UI used to toast
    /// "sent" regardless (#sync-7).
    @discardableResult
    func sendFeedbackRemote(submissionId: String, text: String) async -> Bool {
        let res = await callRoom(["action": "feedback", "code": roomCode, "hostToken": hostToken, "submissionId": submissionId, "text": text])
        return res != nil
    }

    // MARK: - Audio via Storage (submission bounces)

    /// Teacher: a short-lived signed URL to play back a submission's audio.
    func submissionAudioURL(path: String) async -> URL? {
        guard let res = await callRoom(["action": "downloadUrl", "code": roomCode, "hostToken": hostToken, "path": path]),
              let u = res["url"] as? String else { return nil }
        return URL(string: u.hasPrefix("http") ? u : SyncConfig.url.absoluteString + u)
    }
    /// Render an ExportPlan to a mono WAV in memory — runs OFF the main thread (renderOffline is heavy).
    nonisolated static func renderMonoWAV(_ plan: ExportPlan) -> Data? {
        let (l, r) = renderOffline(plan)
        guard !l.isEmpty else { return nil }
        var mono = [Float](repeating: 0, count: l.count)
        for i in 0..<l.count { mono[i] = (l[i] + r[i]) * 0.5 }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        // Write at the plan's rate, not the 48 kHz default: renderOffline produced this audio at
        // plan.sr, so omitting it stamped a 48 kHz header on e.g. a 96 kHz bounce and played it back
        // at the wrong speed (audit finding 53).
        guard writeWAVData(mono, to: tmp, sr: plan.sr) else { return nil }
        let data = try? Data(contentsOf: tmp)
        try? FileManager.default.removeItem(at: tmp)
        return data
    }
    /// Student: bounce the current beat and submit it (audio uploaded server-side via the edge fn).
    private var submissionGeneration = UUID()
    func submitCurrentBeat() async {
        guard submitState != .submitting else { return }   // ignore double-taps mid-submit
        submissionGeneration = UUID()
        let generation = submissionGeneration, room = roomCode, token = studentToken
        submitState = .submitting
        let name = project?.name ?? "Beat"
        guard let plan = project?.buildExportPlan() else {
            let ok = await submitBeat(beatName: name, audioUrl: nil, accuracy: nil)
            if generation == submissionGeneration { await finishSubmit(ok ? .sentMetadataOnly : .failed) }; return
        }
        let wav = await Task.detached(priority: .userInitiated) { SessionStore.renderMonoWAV(plan) }.value
        guard generation == submissionGeneration, roomCode == room, studentToken == token else { return }
        if let wav, wav.count < 8_000_000 {
            let res = await callFunc("submitAudio", ["code": roomCode, "studentToken": studentToken,
                                                     "displayName": displayName, "beatName": name,
                                                     "wavBase64": wav.base64EncodedString()])
            if generation == submissionGeneration { await finishSubmit(res != nil ? .sentWithAudio : .failed) }
        } else {
            let ok = await submitBeat(beatName: name, audioUrl: nil, accuracy: nil)   // metadata only if no/oversized audio
            if generation == submissionGeneration { await finishSubmit(ok ? .sentMetadataOnly : .failed) }
        }
    }
    /// Publish the terminal submit state, then clear it back to idle after a few seconds so the banner resets.
    private func finishSubmit(_ state: SubmitState) async {
        let generation = submissionGeneration
        submitState = state
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if generation == submissionGeneration && submitState == state { submitState = .idle }
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
        armJoinWatchdog()   // recover if the socket opens but the channel never joins (silent phx_join drop)
        if role == .host {
            project?.syncBus = self   // teacher edits now emit ops to this bus
            syncHbTask?.cancel()
            syncHbTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    // Late joiners + Rejoin converge within ~6 s — but only when the project actually moved:
                    // re-sending an unchanged snapshot made every follower re-import its WAVs on the main
                    // actor every 6 s for nothing (finding 47).
                    self.broadcastFullSync()
                    // Re-assert the transport position so late joiners play in time — but not during the
                    // teacher's count-in: the host pins project.step = -1 there, and `max(0, -1) == 0` told an
                    // already-playing follower to snap to bar 0 step 0 mid-count (an audible dropout). (#18)
                    self.sendTransportNow()
                }
            }
        }
    }

    /// Arm a one-shot deadline: if the channel hasn't joined within 8s of opening the socket, force a
    /// teardown + reconnect. Without this, a socket that connects but never receives a phx_join reply
    /// (channel-level reject delivered as a drop, lost join frame, half-open NAT) leaves a HOST silently
    /// broadcasting nothing — the whole class sees a frozen "Connecting…" with no recovery.
    private func armJoinWatchdog() {
        joinWatchdog?.cancel()
        let mySocket = ws
        joinWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.role != .solo, !self.joined, self.ws === mySocket else { return }
            self.lastError = "Join timed out"
            self.teardownSocket()
            self.scheduleReconnect()
        }
    }

    /// Re-establish the socket after a drop, keeping the same room/role (capped exponential backoff + jitter).
    private func scheduleReconnect() {
        guard role != .solo, reconnectTask == nil else { return }
        // Equal jitter so a shared-cause outage (server restart) doesn't make a whole classroom re-dial
        // in lockstep (thundering herd).
        let base = min(20.0, pow(2.0, Double(reconnectAttempt)))   // 1,2,4,8,16,20…s
        let delay = base * 0.5 + Double.random(in: 0...(base * 0.5))
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
        joinWatchdog?.cancel(); joinWatchdog = nil
        ws?.cancel(with: .goingAway, reason: nil); ws = nil
        session?.invalidateAndCancel(); session = nil
        joined = false; connected = false; ref = 0   // NOTE: `seq` is deliberately NOT reset — it must stay
        // monotonic across reconnects so followers' lastAppliedSeq doesn't reject post-reconnect ops.
    }

    func leave() {
        reconnectTask?.cancel(); reconnectTask = nil; reconnectAttempt = 0
        syncHbTask?.cancel(); syncHbTask = nil
        joinTask?.cancel(); joinTask = nil
        rosterTask?.cancel(); rosterTask = nil
        presenceTask?.cancel(); presenceTask = nil
        pingTask?.cancel(); pingTask = nil
        pendingJoinAnswer?.cancel(); pendingJoinAnswer = nil
        resyncRetry?.cancel(); resyncRetry = nil
        lastControlFrameAt = [:]
        forked = false
        lastFullSyncFingerprint = nil
        // Teacher: tell the room first (signed op) so followers unlock instead of sitting under a green
        // "Following" banner forever (round 3, sync-1), then deactivate the room on the backend.
        if role == .host, joined { sendOp(SyncOp(kind: .roomClosed)) }
        // Teacher: deactivate the room on the backend so its code/key can't be reused/spoofed later.
        if role == .host, let token = hostToken, !roomCode.isEmpty {
            let code = roomCode
            Task { _ = await callRoom(["action": "close", "code": code, "hostToken": token]) }
        }
        if role != .solo { project?.syncBus = NoSyncBus() }
        teardownSocket()
        submissionGeneration = UUID(); submitState = .idle
        role = .solo; status = "Offline"; roomCode = ""; hostToken = nil; remoteRoster = []; roomTitle = ""; lastError = nil
    }

    /// True while following a teacher — local editing is suppressed (read-only mirror) unless forked.
    var isFollowing: Bool { role == .follow }
    /// "Try it": stop applying teacher ops and edit locally. Rejoin: resume mirroring (resyncs on next fullSync).
    func tryIt() {
        guard role == .follow else { return }
        forked = true; status = "Trying it · \(roomCode)"
        resyncRetry?.cancel(); resyncRetry = nil   // no fullSync will ever "arrive" while forked
    }
    func rejoin() {
        guard role == .follow else { return }
        onBeforeJoin?()   // the fork's edits go to the recovery slot before the teacher's state replaces them
        forked = false
        status = "Following · \(roomCode)"
        // Ask for the teacher's state+position NOW: relying on the next heartbeat left a rejoining student
        // silent (and mid-bar) for up to 6 s. (finding 50)
        requestResync()
    }

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
        sendBroadcast(event: "op", payload: ["op": opStr, "sig": sig, "pub": pubKeyB64])
        opsSent += 1
    }

    private func sendBroadcast(event: String, payload: [String: Any]) {
        sendFrame(["topic": topic, "event": "broadcast",
                   "payload": ["type": "broadcast", "event": event, "payload": payload],
                   "ref": nextRef()])
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.joined { self.sendBroadcast(event: "ping", payload: ["from": self.instanceToken, "t0": Date().timeIntervalSince1970]) }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Send the full project to the room (join / reconnect / Rejoin / resync). Teacher-only.
    /// `force` bypasses the unchanged-content skip — a (re)joining follower needs the snapshot even when
    /// the teacher has not touched anything since the last heartbeat (finding 47).
    func broadcastFullSync(force: Bool = false) {
        guard role == .host, joined, let snap = project?.snapshot() else { return }
        let fp = Self.snapshotFingerprint(snap)
        guard Self.shouldSendFullSync(force: force, revision: fp, lastSentRevision: lastFullSyncFingerprint) else { return }
        lastFullSyncFingerprint = fp
        sendOp(SyncOp(kind: .fullSync(snapshot: snap)))
    }

    /// Re-assert the current transport position so a follower that just (re)joined starts in time instead
    /// of waiting up to 6 s for the heartbeat. Never during the count-in (#18). (finding 50)
    private func sendTransportNow() {
        guard role == .host, joined, let p = project, p.playing, p.step >= 0 else { return }
        sendOp(SyncOp(kind: .transport(playing: true, hostTime: Date().timeIntervalSince1970, bar: p.bar, step: p.step)))
    }

    /// Answer a channel that just (re)joined: state plus the transport when playback is already running.
    /// `immediate` skips the debounce for our own channel join; an incoming `resync` request (any room
    /// member can send one) is debounced so a burst cannot become a multi-megabyte broadcast storm.
    private func answerJoin(immediate: Bool = false) {
        guard role == .host, joined else { return }
        let now = Date()
        if !immediate, now.timeIntervalSince(lastJoinAnswerAt) < 1 {
            // Coalesce, don't drop: a class joining in the same second used to get ONE snapshot and the
            // rest sat unsynced until the teacher edited something (#sync-2). One deferred answer serves
            // every requester (the broadcast reaches all of them).
            if pendingJoinAnswer == nil {
                let wait = max(0.05, 1 - now.timeIntervalSince(lastJoinAnswerAt))
                pendingJoinAnswer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.pendingJoinAnswer = nil; self?.answerJoin(immediate: true) }
                }
            }
            return
        }
        lastJoinAnswerAt = now
        let r = Self.joinResync(playing: project?.playing ?? false, bar: project?.bar ?? 0, step: project?.step ?? -1)
        if r.fullSync { broadcastFullSync(force: true) }
        if r.announceTransport { sendTransportNow() }
    }

    /// A follower asks for the teacher's current state+position (initial join, or "Rejoin" after Try-it).
    private func requestResync() {
        guard role == .follow, joined, !forked else { resyncRetry = nil; return }   // clear so a later gap can re-arm (round 3, cross-3)
        resyncAttempts += 1
        if resyncAttempts > 3 {   // a dead host: say so instead of asking forever under a green banner (round 3, sync-4)
            resyncRetry = nil
            lastError = "Lost the teacher — tap Leave, then join again"
            status = "Following · no response"
            return
        }
        sendBroadcast(event: "resync", payload: ["from": instanceToken])
        // Re-ask if nothing arrives: the host's answer is coalesced and a lost frame otherwise left this
        // follower on its own beat under a green "Following" banner forever (#sync-2/4).
        resyncRetry?.cancel()
        resyncRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.requestResync() }
        }
    }
    /// Room-wide rate cap (in addition to the per-sender one, whose key a bad actor can rotate).
    private func withinRoomBudget(_ times: inout [Date], max: Int, window: TimeInterval) -> Bool {
        let now = Date()
        times.removeAll { now.timeIntervalSince($0) > window }
        guard times.count < max else { return false }
        times.append(now)
        return true
    }
    /// Cheap per-sender throttle for the two unauthenticated control frames (`resync`, `ping`) so one
    /// member can't force a 1–2 MB snapshot broadcast every second or an unbounded pong storm (#sync-6).
    private func controlFrameAllowed(from sender: String?, minInterval: TimeInterval) -> Bool {
        let key = sender ?? "?"
        let now = Date()
        if let last = lastControlFrameAt[key], now.timeIntervalSince(last) < minInterval { return false }
        lastControlFrameAt[key] = now
        if lastControlFrameAt.count > 256 {   // evict the oldest half, never wipe (a wipe reset everyone's throttle)
            for k in lastControlFrameAt.sorted(by: { $0.value < $1.value }).prefix(128).map(\.key) { lastControlFrameAt[k] = nil }
        }
        return true
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
        ws.send(.string(str)) { err in   // don't capture self in this @Sendable completion; hop to the actor instead
            guard let err else { return }
            Task { @MainActor [weak self] in self?.lastError = err.localizedDescription }
        }
    }

    private func receiveLoop() {
        let task = ws   // capture identity so a torn-down socket's late callback can't drive a live one
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Task { @MainActor in
                    guard task === self.ws else { return }   // ignore failures from a socket we already replaced
                    self.connected = false; self.status = "Disconnected"; self.lastError = err.localizedDescription
                    self.scheduleReconnect()   // auto-recover from a dropped socket during a live lesson
                }
            case .success(let msg):
                if case .string(let text) = msg { Task { @MainActor in self.handle(text) } }
                Task { @MainActor in guard task === self.ws else { return }; self.receiveLoop() }   // keep listening on the SAME socket
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
                joined = true; connected = true; reconnectAttempt = 0; lastError = nil   // healthy connection resets backoff
                joinWatchdog?.cancel(); joinWatchdog = nil               // channel joined — stand the deadline down
                status = role == .host ? "Hosting · \(roomCode)" : (forked ? "Trying it · \(roomCode)" : "Following · \(roomCode)")
                // (Re)join handshake: the snapshot AND, when a lesson is already playing, the transport —
                // otherwise a student joining mid-song heard nothing until the next 6 s heartbeat. (finding 50)
                if role == .host { answerJoin(immediate: true) } else if !forked { requestResync() }
            }
        case "broadcast":
            guard let payload = obj["payload"] as? [String: Any], let inner = payload["event"] as? String else { return }
            switch inner {
            case "op":     handleOp(payload["payload"] as? [String: Any])
            case "ping":   handlePing(payload["payload"] as? [String: Any])
            case "pong":   handlePong(payload["payload"] as? [String: Any])
            case "resync":
                let from = (payload["payload"] as? [String: Any])?["from"] as? String
                if controlFrameAllowed(from: from, minInterval: 2), withinRoomBudget(&resyncAnswerTimes, max: 10, window: 60) {
                    answerJoin()   // a follower (re)joined — at most 10 snapshot answers a minute room-wide (round 3, sync-3)
                }
            default: break
            }
        case "phx_error", "phx_close":
            connected = false; status = "Disconnected"
            scheduleReconnect()
        default:
            break
        }
    }

    private func handleOp(_ wrapper: [String: Any]?) {
        guard let wrapper, let opStr = wrapper["op"] as? String, let opData = opStr.data(using: .utf8) else { return }
        guard let op = try? JSONDecoder().decode(SyncOp.self, from: opData) else {
            // An op this build can't decode (mixed app versions) would silently diverge the follower;
            // ask for a full snapshot instead (#sync-4).
            if role == .follow, !forked, resyncRetry == nil { requestResync() }
            return
        }
        opsReceived += 1
        // Ignore our own echo (broadcast self:true, matched by per-launch instanceToken). A non-forked
        // follower applies the teacher's ops; a forked follower experiments locally until Rejoin — but a
        // (signed) roomClosed reaches forked followers too.
        guard op.origin != instanceToken, role == .follow else { return }
        var isClosed = false; if case .roomClosed = op.kind { isClosed = true }
        if forked && !isClosed { return }
        // VERIFY the host signature — reject unsigned/forged ops so a mere code-holder can't inject
        // edits as the teacher (pinned key is server-authoritative when set on join, else TOFU).
        guard let sigB64 = wrapper["sig"] as? String, let sig = Data(base64Encoded: sigB64),
              let pubB64 = wrapper["pub"] as? String, let pubRaw = Data(base64Encoded: pubB64),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubRaw) else { rejectedOps += 1; return }
        // No TOFU auto-pin: the follower's pinnedHostKey is the server-authoritative key set in begin().
        // A wire key that doesn't match (or a missing pin) is rejected — a code-holder can't self-pin.
        guard let pinned = pinnedHostKey,
              pinned.rawRepresentation == pub.rawRepresentation,
              pinned.isValidSignature(sig, for: opData) else { rejectedOps += 1; return }
        if isClosed {
            leave()
            lastError = "The teacher ended the class"
            status = "Class ended"
            classEndedByHost = true
            return
        }
        var isFull = false; if case .fullSync = op.kind { isFull = true }
        if !isFull, op.seq > 0, op.seq <= lastAppliedSeq { return }
        if isFull { resyncRetry?.cancel(); resyncRetry = nil; resyncAttempts = 0 }
        else if lastAppliedSeq > 0, op.seq > lastAppliedSeq + 1, resyncRetry == nil {
            requestResync()   // a gap: something was lost on the wire — apply this op, then reconverge (#sync-4)
        }
        // A fullSync is an authoritative resync: re-anchor the dedup watermark to the host's CURRENT seq
        // (handles a host restart whose seq is below our last-applied). Incremental ops advance it as usual.
        lastAppliedSeq = isFull ? op.seq : max(lastAppliedSeq, op.seq)
        // Transport ops drive the local Transport at the teacher's CURRENT position (clock-offset adjusted).
        if case .transport(let playing, let hostTime, let bar, let step) = op.kind {
            guard playing else { onRemoteTransport?(false, 0, 0); return }
            let bpm = Double(max(40, project?.bpm ?? 90)), n = max(1, project?.barSteps ?? 16)   // clamp: no div-by-zero
            let secPerStep = (60.0 / bpm) / 4.0
            let elapsed = min(3600, max(0, Date().timeIntervalSince1970 - (hostTime - clockOffset)))   // clamp wild offsets
            // Target step = the teacher's step advanced by the time since the op, cyclically within the
            // song. Transport.followerTargetStep also folds in the follower's own start lead, so a late
            // joiner (or any post-re-seek follower) is no longer 50-175 ms behind for the whole session. (#19)
            let s = Transport.followerTargetStep(bar: bar, step: step, elapsed: elapsed, secPerStep: secPerStep,
                                                 barSteps: n, songBars: project?.songBars ?? 16)
            onRemoteTransport?(true, s / n, s % n)
        } else {
            project?.applyRemote(op)
        }
    }

    // Clock sync (NTP-style): follower pings, host echoes recv/send times, follower keeps the median
    // offset of the lowest-RTT samples → maps the teacher's transport host-time into the follower's clock.
    private func handlePing(_ p: [String: Any]?) {
        guard role == .host, let from = p?["from"] as? String, let t0 = p?["t0"] as? Double else { return }
        guard controlFrameAllowed(from: "ping:" + from, minInterval: 0.5), withinRoomBudget(&pongTimes, max: 20, window: 1) else { return }
        let now = Date().timeIntervalSince1970
        sendBroadcast(event: "pong", payload: ["to": from, "t0": t0, "t1": now, "t2": Date().timeIntervalSince1970])
    }
    private func handlePong(_ p: [String: Any]?) {
        guard role == .follow, (p?["to"] as? String) == instanceToken,
              let t0 = p?["t0"] as? Double, let t1 = p?["t1"] as? Double, let t2 = p?["t2"] as? Double else { return }
        let now = Date().timeIntervalSince1970
        let rtt = (now - t0) - (t2 - t1)
        let offset = ((t1 - t0) + (t2 - now)) / 2.0            // teacherClock − followerClock
        rttSamples.append((rtt, offset)); if rttSamples.count > 8 { rttSamples.removeFirst() }
        let best = rttSamples.sorted { $0.rtt < $1.rtt }.prefix(max(1, rttSamples.count / 2)).map { $0.offset }.sorted()
        clockOffset = best[best.count / 2]
    }
}
