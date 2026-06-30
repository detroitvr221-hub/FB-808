//  TeacherModeView.swift — Teacher / Classroom mode: roster, live class, beat
//  review. Classroom-safe (teacher-managed accounts, no public messaging/feeds).
//  Ported from mode-teacher.jsx.

import SwiftUI
import UIKit

private let TE_CLASS = "Beat Lab · 4th Period"
private let TE_TOTAL = 6   // roster-card lesson scale (Student/Submission models live in ClassroomStore.swift)

private func starsFor(_ acc: Double) -> Int { acc >= 0.93 ? 3 : (acc >= 0.78 ? 2 : (acc >= 0.55 ? 1 : 0)) }

struct TeacherModeView: View {
    @EnvironmentObject var project: Project
    @EnvironmentObject var engine: AudioEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var progress: ProgressStore     // live local-user values (#152)
    @EnvironmentObject var classroom: ClassroomStore   // persisted roster/live/sel/feedback (#159)
    @EnvironmentObject var session: SessionStore       // live teacher↔student sync (SYSTEM_AUDIT Step 6)
    @State private var joinCode = ""
    var openTab: (String) -> Void = { _ in }

    @State private var tab = "roster"                  // navigation only — fine to reset on return
    @State private var toast: String?                  // transient
    @State private var confirmEndLive = false          // guard the destructive "End Live Class" (kicks everyone)

    // Live submissions (Submissions tab while HOSTING — real backend data, not the mock roster).
    @State private var remoteSubs: [RemoteSub] = []
    @State private var selectedRemoteID: String?
    @State private var remoteFeedback = ""             // teacher's in-progress feedback for the selected sub
    @State private var subsRefreshing = false
    @State private var reviewEndTask: Task<Void, Never>?   // clears the "playing" cue when the engine clip ends
    @State private var reviewGen = 0                        // invalidates an in-flight load when the user taps again / stops
    @State private var playingSubID: String?

    /// A submission as returned by the `submissions` edge action (token-authorized; teacher-only).
    /// PII-free: only a moderated display name, never an email or account id.
    struct RemoteSub: Identifiable, Equatable {
        let id: String, name: String, beat: String
        let acc: Double?, reviewed: Bool, feedback: String, audioPath: String?
        init?(_ d: [String: Any]) {
            guard let id = d["id"] as? String else { return nil }
            self.id = id
            name = (d["display_name"] as? String) ?? "Student"
            beat = (d["beat_name"] as? String) ?? "Beat"
            acc = (d["accuracy"] as? NSNumber)?.doubleValue
            reviewed = (d["reviewed"] as? Bool) ?? ((d["reviewed"] as? NSNumber)?.boolValue ?? false)
            feedback = (d["feedback"] as? String) ?? ""
            let path = d["audio_url"] as? String
            audioPath = (path?.isEmpty ?? true) ? nil : path
        }
    }

    /// What the roster/monitor display: the live local "You" row first, then — when actually hosting a
    /// live class — the REAL enrolled students from the backend; otherwise the example peers (preview).
    private var displayRoster: [Student] {
        let me = classroom.localRow(progress: progress, outOf: TE_TOTAL)
        if session.role == .host {
            let live = session.remoteRoster.enumerated().map { (i, e) -> Student in
                Student(id: "remote-\(i)", name: e.name, colorHex: Student.palette[i % Student.palette.count],
                        on: e.online, status: e.online ? "on-task" : "offline",
                        doing: e.online ? "In class" : "Away", done: 0, acc: 0, sub: nil)
            }
            return [me] + live
        }
        return [me] + classroom.students
    }
    private var onCount: Int { displayRoster.filter { $0.on }.count }
    private var subs: [Student] { displayRoster.filter { $0.sub != nil } }   // local row has sub:nil → excluded
    private var newSubs: Int { subs.filter { !($0.sub?.reviewed ?? true) }.count }
    /// Unreviewed count for the Submissions tab badge — real remote subs when hosting, mock otherwise.
    private var pendingReview: Int { session.role == .host ? remoteSubs.filter { !$0.reviewed }.count : newSubs }
    /// The lesson chosen in the "Assign to Class" picker, and the pattern the push buttons should send for it
    /// (so Push Pattern / Send Practice follow the assigned lesson instead of a hardcoded Boom Bap).
    private var assignedLesson: Kit.Lesson? { Kit.lessons.first { $0.id == classroom.assignLesson } }
    private var assignedPatternID: String { assignedLesson?.patternID ?? "boombap" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModeHead(title: "Teacher", eyebrow: TE_CLASS) {
                Text("\(onCount) of \(displayRoster.count) online\(classroom.live ? " · LIVE" : "")")
                    .font(FDFont.ui(12.5)).foregroundStyle(classroom.live ? settings.accent : settings.inkFaint)
            }
            CoachNote("Classroom-safe by design — **teacher-managed accounts**, no public messaging, profiles or feeds. Push kits, beats and tempo straight to every student.")
                .padding(.top, 10)
            tabs.padding(.vertical, 14)
            Group {
                switch tab {
                case "roster": roster
                case "live": liveClass
                default: review
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) {
            if let toast { toastView(toast) }
        }
        .alert("End live class?", isPresented: $confirmEndLive) {
            Button("End Class", role: .destructive) { toggleLive() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This disconnects every joined student and ends the session.") }
        // Poll real submissions while hosting (keeps the badge + list live regardless of which tab is open).
        .task(id: session.role) {
            guard session.role == .host else { remoteSubs = []; stopPlayback(); return }
            while !Task.isCancelled {
                await refreshSubs()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    @MainActor private func refreshSubs() async {
        guard session.role == .host else { return }
        subsRefreshing = true
        let raw = await session.fetchSubmissions()
        subsRefreshing = false
        guard session.role == .host else { return }       // role may have changed during the await
        guard let raw else { return }                     // transport failure — keep the current list AND the
        // teacher's in-progress feedback; a network blip must never wipe submissions or unsent text.
        let parsed = raw.compactMap { RemoteSub($0) }
        remoteSubs = parsed
        if let sel = selectedRemoteID, !parsed.contains(where: { $0.id == sel }) { selectedRemoteID = nil }
        if selectedRemoteID == nil { selectedRemoteID = parsed.first?.id; remoteFeedback = parsed.first?.feedback ?? "" }
    }

    private func playRemote(_ sub: RemoteSub) {
        guard let path = sub.audioPath else { return }
        stopPlayback()   // stop any current submission before starting another (no overlapping audio)
        let gen = reviewGen
        Task {
            guard let url = await session.submissionAudioURL(path: path) else { if gen == reviewGen { toast = "Couldn't load audio" }; return }
            // Download + decode OFF the main thread, then play THROUGH THE ENGINE (not a side AVPlayer),
            // so all audio shares the one session/route and the master limiter/volume.
            guard let local = await downloadTemp(url) else { if gen == reviewGen { toast = "Couldn't load audio" }; return }
            let pcm = await SampleEngine.decodeAsync(url: local, targetSR: engine.sampleRate)
            try? FileManager.default.removeItem(at: local)
            guard gen == reviewGen else { return }                 // superseded by another tap / stop during the await
            guard let pcm, !pcm.isEmpty else { toast = "Couldn't load audio"; return }
            engine.start()
            engine.playReviewClip(pcm)
            playingSubID = sub.id
            let dur = Double(pcm.count) / engine.sampleRate
            reviewEndTask?.cancel()
            reviewEndTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000) + 120_000_000)
                if !Task.isCancelled, playingSubID == sub.id { playingSubID = nil }
            }
        }
    }

    /// Download a remote submission WAV to a temp file (AVAudioFile decode needs a local URL).
    private func downloadTemp(_ url: URL) async -> URL? {
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch { return nil }
    }

    private func stopPlayback() {
        reviewGen &+= 1                 // invalidate any in-flight load so it can't start playing after we stop
        reviewEndTask?.cancel(); reviewEndTask = nil
        engine.stopReviewClip()
        playingSubID = nil
    }

    private func sendRemoteFeedback(_ sub: RemoteSub) {
        let text = remoteFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            await session.sendFeedbackRemote(submissionId: sub.id, text: text)
            toast = "Feedback sent to \(sub.name)"
            await refreshSubs()
        }
    }

    /// Deterministic per-name avatar color (stable across launches, unlike String.hashValue).
    private func colorFor(_ s: String) -> Color {
        var h = 5381; for b in s.utf8 { h = ((h << 5) &+ h) &+ Int(b) }
        return Color(hex: Student.palette[abs(h) % Student.palette.count])
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            tabBtn("Roster", "roster")
            tabBtn("Live Class", "live")
            tabBtn("Submissions", "review", badge: pendingReview)
        }
    }
    private func tabBtn(_ label: String, _ id: String, badge: Int = 0) -> some View {
        SegTab(label: label, selected: tab == id, badge: badge) { tab = id }
    }

    // MARK: roster

    private var roster: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("ASSIGN A LESSON").font(FDFont.mono(10, .bold)).tracking(1).foregroundStyle(settings.inkFaint)
                Picker("", selection: $classroom.assignLesson) {
                    ForEach(Kit.lessons) { l in Text("\(l.n). \(l.title)").tag(l.id) }
                }.pickerStyle(.menu).tint(settings.ink)
                    .accessibilityLabel("Lesson to assign")
                Spacer()
                Button { assign() } label: {
                    Text("Assign to Class").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.line, lineWidth: 1))

            if session.role != .host {   // showing the example peers, not a real enrolled class
                HStack(spacing: 8) {
                    Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(settings.inkFaint)
                    Text("Preview — example students. Start a live class to see your real roster.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2))
                .accessibilityElement(children: .combine)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(displayRoster) { st in studentCard(st) }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func studentCard(_ st: Student) -> some View {
        // The local "You" row has no submission to review — tapping it is a no-op — and is shown distinctly
        // (accent border + "YOU" badge) so it doesn't read as just another student.
        let isMe = st.id == ClassroomStore.localRowID
        return Button { if !isMe { classroom.selectedID = st.id; tab = "review" } } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    avatar(st, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(st.name).font(FDFont.display(14, .semibold)).foregroundStyle(settings.ink)
                            if isMe {
                                Text("YOU").font(FDFont.mono(8, .bold)).tracking(0.5).foregroundStyle(settings.accent)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(settings.accent.opacity(0.18)))
                            }
                        }
                        statusPill(st.status)
                    }
                    Spacer()
                    if let sub = st.sub, !sub.reviewed { newTag }
                }
                Text(st.doing).font(FDFont.ui(12)).foregroundStyle(settings.inkDim).lineLimit(1)
                let shownDone = min(st.done, TE_TOTAL)   // keep bar + label on the same "N/total" scale (#152)
                progressBar(Double(shownDone) / Double(TE_TOTAL))
                HStack {
                    Text("\(shownDone)/\(TE_TOTAL) lessons").font(FDFont.mono(10)).foregroundStyle(settings.inkFaint)
                    Spacer()
                    Text("\(Int(st.acc * 100))% timing").font(FDFont.mono(10)).foregroundStyle(settings.inkDim)
                    stars(starsFor(st.acc))
                }
            }
            .padding(13)
            .fdCard(14, fill: settings.panel)
            .overlay(isMe ? RoundedRectangle(cornerRadius: 14).stroke(settings.accent.opacity(0.55), lineWidth: 1.5) : nil)
        }.buttonStyle(.plain)
    }

    // MARK: live

    private var liveClass: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    Text("CLASS CODE").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
                    Text(liveCode).font(FDFont.display(34, .bold)).foregroundStyle(settings.ink).tracking(2)
                        .accessibilityLabel("Class code \(liveCode)")
                    Text("Students join from the home screen").font(FDFont.ui(12)).foregroundStyle(settings.inkDim)
                    Button { if classroom.live { confirmEndLive = true } else { toggleLive() } } label: {
                        HStack(spacing: 8) {
                            Circle().fill(classroom.live ? settings.theme.miss : settings.theme.good).frame(width: 9, height: 9)
                            Text(classroom.live ? "End Live Class" : "Start Live Class").font(FDFont.ui(14, .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 13).fill(classroom.live ? settings.theme.miss : settings.accent))
                    }.buttonStyle(.plain).padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))

                teCard("Class Tempo") {
                    HStack(spacing: 12) {
                        tempoBtn("–") { project.setBpm(project.bpm - 2) }
                            .accessibilityLabel("Decrease class tempo")
                        VStack(spacing: 0) {
                            Text("\(project.bpm)").font(FDFont.mono(24, .bold)).foregroundStyle(settings.ink)
                            Text("BPM").font(FDFont.mono(9, .bold)).foregroundStyle(settings.inkFaint)
                        }.frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Class tempo")
                            .accessibilityValue("\(project.bpm) BPM")
                        tempoBtn("+") { project.setBpm(project.bpm + 2) }
                            .accessibilityLabel("Increase class tempo")
                    }
                    Text("Sets the tempo for the whole studio — every student follows.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                }

                teCard("Live Connection") {   // Step 6: real Supabase Realtime status + student join
                    HStack(spacing: 8) {
                        Circle().fill(session.connected ? settings.theme.good : settings.inkFaint).frame(width: 9, height: 9)
                        Text(session.status).font(FDFont.ui(12.5, .semibold)).foregroundStyle(settings.ink)
                        Spacer()
                        if session.role == .host { Text("↑\(session.opsSent)").font(FDFont.mono(10)).foregroundStyle(settings.inkFaint) }
                        if session.role == .follow { Text("↓\(session.opsReceived)").font(FDFont.mono(10)).foregroundStyle(settings.inkFaint) }
                    }
                    // Joining as a follower starts with leave(), which for a host POSTs "close" and ends the
                    // live class for every student — so never show the join field while THIS device is hosting.
                    if session.role != .host {
                        HStack(spacing: 8) {
                            TextField("Class code", text: $joinCode)
                                .font(FDFont.mono(13, .bold)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .padding(.horizontal, 10).frame(height: 36)
                                .fdCard(9, fill: settings.panel2)
                            Button {
                                let c = joinCode.trimmingCharacters(in: .whitespaces).uppercased()
                                if !c.isEmpty && session.role != .host { session.follow(code: c, name: "Student") }
                            } label: {
                                Text("Join").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 16).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(settings.accent))
                            }.buttonStyle(.plain).disabled(joinCode.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("Students enter the code to follow this class live — they see every edit in real time.")
                            .font(FDFont.ui(11)).foregroundStyle(settings.inkFaint)
                    }
                }
            }
            .frame(width: 280)

            teCard("Push to Class", flex: true) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    pushBtn("🎛 Push Kit") { project.setBank("A"); pushToClass("Studio Kit") }
                    pushBtn("♫ Push Pattern") { loadPattern(assignedPatternID); pushToClass("\(Kit.pattern(assignedPatternID)?.name ?? "Pattern")") }
                    pushBtn("⏱ Push Tempo") { pushToClass("Tempo \(project.bpm) BPM") }
                    pushBtn("✦ Send Practice") { previewPattern(assignedPatternID); pushToClass("Practice: \(assignedLesson?.title ?? "drill")"); openTab("learn") }
                }
                Text("LIVE MONITOR").font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint).padding(.top, 8)
                if !classroom.live {
                    Text("Start the live class to watch students join and follow along in real time.")
                        .font(FDFont.ui(11.5)).foregroundStyle(settings.inkFaint)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(displayRoster) { st in monitorRow(st) }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
        }
    }

    private func monitorRow(_ st: Student) -> some View {
        HStack(spacing: 9) {
            avatar(st, size: 24)
            Text(st.name).font(FDFont.ui(13, .medium)).foregroundStyle(st.on ? settings.ink : settings.inkFaint)
            Spacer()
            let txt = st.on ? (st.status == "on-task" ? "Following" : "Joined") : "Not joined"
            let col: Color = st.on ? (st.status == "on-task" ? settings.theme.good : settings.accent) : settings.inkFaint
            Text(txt).font(FDFont.mono(10, .bold)).foregroundStyle(col)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(col.opacity(0.14)))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(settings.panel2)).opacity(st.on ? 1 : 0.6)
    }

    // MARK: review

    /// Submissions tab: real remote submissions when a live class is hosting, the example roster otherwise.
    @ViewBuilder private var review: some View {
        if session.role == .host { liveReview } else { mockReview }
    }

    // MARK: Live submissions (real backend, teacher-authorized)

    private var liveReview: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("SUBMITTED BEATS · \(remoteSubs.count)").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
                    Spacer()
                    if subsRefreshing { ProgressView().controlSize(.mini) }
                    Button { Task { await refreshSubs() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(settings.inkDim)
                    }.buttonStyle(.plain).accessibilityLabel("Refresh submissions")
                }
                if remoteSubs.isEmpty {
                    Text("No submissions yet — students' beats appear here the moment they hit Submit.")
                        .font(FDFont.ui(12)).foregroundStyle(settings.inkFaint).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(remoteSubs) { sub in remoteSubRow(sub) }
                    }
                }.scrollIndicators(.hidden)
            }
            .frame(width: 280)

            Group {
                if let sub = remoteSubs.first(where: { $0.id == selectedRemoteID }) {
                    remoteReviewDetail(sub)
                } else {
                    VStack {
                        Text("Select a submission to listen and leave feedback.")
                            .font(FDFont.ui(14)).foregroundStyle(settings.inkDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
                }
            }
        }
        .onAppear { Task { await refreshSubs() } }   // snappy first load when the tab opens
        .onDisappear { stopPlayback() }              // don't keep streaming a submission after leaving the tab
    }

    private func remoteSubRow(_ sub: RemoteSub) -> some View {
        Button { selectedRemoteID = sub.id; remoteFeedback = sub.feedback } label: {
            HStack(spacing: 9) {
                Circle().fill(colorFor(sub.name)).frame(width: 24, height: 24)
                    .overlay(Text(String(sub.name.prefix(1))).font(FDFont.ui(11, .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(sub.beat).font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink).lineLimit(1)
                    Text(sub.name).font(FDFont.ui(11)).foregroundStyle(settings.inkDim)
                }
                Spacer()
                if !sub.reviewed { newTag }
                else { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(settings.theme.good) }
            }
            .padding(.horizontal, 10).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(selectedRemoteID == sub.id ? settings.accent.opacity(0.16) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selectedRemoteID == sub.id ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func remoteReviewDetail(_ sub: RemoteSub) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(colorFor(sub.name)).frame(width: 38, height: 38)
                    .overlay(Text(String(sub.name.prefix(1))).font(FDFont.ui(16, .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(sub.beat).font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
                    Text(sub.name).font(FDFont.ui(12)).foregroundStyle(settings.inkDim)
                }
                Spacer()
                if let a = sub.acc {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(a * 100))%").font(FDFont.mono(18, .bold)).foregroundStyle(settings.ink)
                        stars(starsFor(a))
                    }
                }
            }
            HStack(spacing: 10) {
                Button { playRemote(sub) } label: {
                    HStack(spacing: 8) {
                        if playingSubID == sub.id { Image(systemName: "speaker.wave.2.fill").font(.system(size: 12, weight: .bold)) }
                        else { Triangle().fill(.white).frame(width: 11, height: 13) }
                        Text(sub.audioPath == nil ? "No Audio" : "Play Submission")
                    }
                    .font(FDFont.ui(14, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain).disabled(sub.audioPath == nil).opacity(sub.audioPath == nil ? 0.5 : 1)
                Text(sub.audioPath == nil ? "Student submitted without a recording" : "Plays the student's recorded bounce")
                    .font(FDFont.ui(12)).foregroundStyle(settings.inkFaint)
                Spacer()
            }
            Text("WRITTEN FEEDBACK").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
            TextEditor(text: $remoteFeedback)
                .font(FDFont.ui(14)).foregroundStyle(settings.ink).scrollContentBackground(.hidden)
                .padding(10).frame(height: 100)
                .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
            HStack {
                if sub.reviewed { Label("Reviewed", systemImage: "checkmark.seal.fill").font(FDFont.ui(12, .semibold)).foregroundStyle(settings.theme.good) }
                Spacer()
                let empty = remoteFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { sendRemoteFeedback(sub) } label: {
                    Text("Send Feedback").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 11).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain).disabled(empty).opacity(empty ? 0.5 : 1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }

    // MARK: Example submissions (preview when not hosting a live class)

    private var mockReview: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SUBMITTED BEATS · \(subs.count)").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
                if subs.isEmpty { Text("No submissions yet.").font(FDFont.ui(12)).foregroundStyle(settings.inkFaint) }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(subs) { st in subRow(st) }
                    }
                }.scrollIndicators(.hidden)
            }
            .frame(width: 280)

            Group {
                if let st = classroom.selectedID.flatMap({ id in displayRoster.first { $0.id == id } }), let sub = st.sub {
                    reviewDetail(st, sub)
                } else {
                    VStack {
                        Text("Select a submission to listen and leave feedback.")
                            .font(FDFont.ui(14)).foregroundStyle(settings.inkDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
                }
            }
        }
    }

    private func subRow(_ st: Student) -> some View {
        Button { classroom.selectedID = st.id } label: {
            HStack(spacing: 9) {
                avatar(st, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(st.sub?.beat ?? "").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    Text(st.name).font(FDFont.ui(11)).foregroundStyle(settings.inkDim)
                }
                Spacer()
                if !(st.sub?.reviewed ?? true) { newTag }
                else { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(settings.theme.good) }
            }
            .padding(.horizontal, 10).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(classroom.selectedID == st.id ? settings.accent.opacity(0.16) : settings.panel2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(classroom.selectedID == st.id ? settings.accent.opacity(0.5) : settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func reviewDetail(_ st: Student, _ sub: Submission) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                avatar(st, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sub.beat).font(FDFont.display(16, .bold)).foregroundStyle(settings.ink)
                    Text("\(st.name) · \(st.doing)").font(FDFont.ui(12)).foregroundStyle(settings.inkDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(sub.acc * 100))%").font(FDFont.mono(18, .bold)).foregroundStyle(settings.ink)
                    stars(starsFor(sub.acc))
                }
            }
            HStack(spacing: 10) {
                Button { previewPattern(sub.pid) } label: {
                    HStack(spacing: 8) { Triangle().fill(.white).frame(width: 11, height: 13); Text("Play Beat") }
                        .font(FDFont.ui(14, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.ctaGradient()))
                }.buttonStyle(.plain)
                Text("2-bar preview of the submission").font(FDFont.ui(12)).foregroundStyle(settings.inkFaint)
                Spacer()
            }
            Text("WRITTEN FEEDBACK").font(FDFont.mono(10, .bold)).tracking(1.2).foregroundStyle(settings.inkFaint)
            feedbackEditor(st)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }

    @ViewBuilder private func feedbackEditor(_ st: Student) -> some View {
        let binding = Binding<String>(
            get: { classroom.students.first { $0.id == st.id }?.sub?.fb ?? "" },
            set: { v in classroom.setFeedbackText(st.id, v) })
        TextEditor(text: binding)
            .font(FDFont.ui(14)).foregroundStyle(settings.ink).scrollContentBackground(.hidden)
            .padding(10).frame(height: 100)
            .background(RoundedRectangle(cornerRadius: 12).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 12).stroke(settings.line, lineWidth: 1))
        HStack(spacing: 10) {
            Button { sendFeedback(st.id, "") } label: {
                Text("★ Unlock Next Lesson").font(FDFont.ui(13, .semibold)).foregroundStyle(settings.ink)
                    .padding(.horizontal, 16).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 11).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.line, lineWidth: 1))
            }.buttonStyle(.plain)
            Spacer()
            let txt = binding.wrappedValue
            Button { sendFeedback(st.id, txt) } label: {
                Text("Send Feedback").font(FDFont.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 11).fill(settings.accent.ctaGradient()))
            }.buttonStyle(.plain).disabled(txt.trimmingCharacters(in: .whitespaces).isEmpty).opacity(txt.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
    }

    // MARK: small components

    private func avatar(_ st: Student, size: CGFloat) -> some View {
        Text(st.initial).font(FDFont.display(size * 0.45, .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3).fill(st.color))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(st.name), avatar")
    }
    private func statusPill(_ s: String) -> some View {
        let (txt, col): (String, Color) = s == "on-task" ? ("On task", settings.theme.good) : (s == "idle" ? ("Idle", settings.theme.perfect) : ("Offline", settings.inkFaint))
        return HStack(spacing: 4) {
            Circle().fill(col).frame(width: 6, height: 6)
            Text(txt).font(FDFont.mono(9, .bold)).foregroundStyle(col)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(txt)")
    }
    private func progressBar(_ frac: Double) -> some View {
        let f = min(1, max(0, frac))   // clamp so a power-user local row never overdraws its track (#152)
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(settings.line)
                Capsule().fill(settings.accent).frame(width: g.size.width * f)
            }
        }.frame(height: 6)
    }
    private func stars(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(i < n ? settings.theme.perfect : settings.line)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) of 3 stars")
    }
    private var newTag: some View {
        Text("NEW").font(FDFont.mono(8, .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(settings.theme.miss))
    }
    private func teCard<C: View>(_ title: String, flex: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(FDFont.mono(10, .bold)).tracking(1.4).foregroundStyle(settings.inkFaint)
            content()
            if flex { Spacer(minLength: 0) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: flex ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(settings.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(settings.line, lineWidth: 1))
    }
    private func tempoBtn(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: 19, weight: .bold)).foregroundStyle(settings.ink)
                .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 10).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func pushBtn(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(FDFont.ui(13, .semibold)).foregroundStyle(classroom.live ? settings.ink : settings.inkFaint).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(settings.panel2)).overlay(RoundedRectangle(cornerRadius: 11).stroke(settings.line, lineWidth: 1))
        }.buttonStyle(.plain).disabled(!classroom.live).opacity(classroom.live ? 1 : 0.5)
    }
    private func toastView(_ msg: String) -> some View {
        Text(msg).font(FDFont.ui(14, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Capsule().fill(settings.ink.opacity(0.92)))
            .foregroundStyle(settings.theme.bg)
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: actions

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        UIAccessibility.post(notification: .announcement, argument: msg)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            withAnimation { toast = nil }
        }
    }
    private func pushToClass(_ label: String) { flash("\(label) sent to \(onCount) students") }
    private func toggleLive() {
        classroom.live.toggle()
        if classroom.live { session.host(title: TE_CLASS); flash("Starting live class…") }
        else { session.leave(); flash("Live class ended") }
    }
    private var liveCode: String { session.roomCode.isEmpty ? "—" : session.roomCode }
    private func assign() {
        let title = assignedLesson?.title ?? "lesson"
        // Honest feedback: only claim it reached the class when actually hosting; otherwise it's just selected.
        if classroom.live {
            if let pid = assignedLesson?.patternID { previewPattern(pid) }
            pushToClass("Assigned \u{201C}\(title)\u{201D}")
        } else {
            flash("Lesson set: \u{201C}\(title)\u{201D} — start a Live Class to send it")
        }
    }
    private func sendFeedback(_ id: String, _ text: String) {
        classroom.sendFeedback(id, text)   // persists via the store's didSet (#159)
        flash("Feedback sent")
    }
    private func loadPattern(_ pid: String) {
        guard let pat = Kit.pattern(pid) else { return }
        project.checkpoint("pushPattern", coalesce: false)   // overwrites the current beat → keep it undoable
        project.lanes = Kit.lanesFromSteps(pat.steps)
        project.setBpm(pat.bpm)
        project.name = pat.name
    }
    private func previewPattern(_ pid: String) {
        engine.start()
        let pat = Kit.pattern(pid) ?? Kit.patterns[0]
        let stepDur = (60.0 / Double(pat.bpm)) / 4
        let start = engine.now() + 0.1
        for bar in 0..<2 {
            for st in 0..<16 {
                let t = start + Double(bar * 16 + st) * stepDur
                for padID in pat.steps[st] {
                    engine.trigger(padID, vel: (padID == "kick" || padID == "snare") ? 1 : 0.8, when: t)
                }
            }
        }
    }
}
