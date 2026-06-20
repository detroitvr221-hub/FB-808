//  ClassroomStore.swift — persistent Teacher/Classroom state (#152/#159).
//  Roster, live-class flag, selected submission, and written feedback live here as a
//  UserDefaults-backed ObservableObject (the same idiom as AppSettings/ProgressStore), so
//  they survive tab switches and relaunches instead of resetting to a hardcoded mock.
//  The local user is NOT stored here — it's rebuilt live from ProgressStore each render
//  (see `localRow`), so there's one source of truth for the learner's own progress.

import SwiftUI
import Combine

// Roster models (moved out of TeacherModeView, now Codable for persistence).
struct Submission: Codable, Equatable { var beat: String; var pid: String; var acc: Double; var reviewed: Bool; var fb: String }
struct Student: Codable, Identifiable, Equatable {
    let id: String; let name: String; let colorHex: String
    var on: Bool; var status: String; var doing: String
    var done: Int; var acc: Double
    var sub: Submission?
    var color: Color { Color(hex: colorHex) }   // computed → excluded from synthesized Codable
    var initial: String { String(name.prefix(1)) }
}

@MainActor
final class ClassroomStore: ObservableObject {
    @Published var students: [Student]   { didSet { saveStudents() } }
    @Published var live: Bool            { didSet { store.set(live, forKey: "fd.class.live") } }
    @Published var selectedID: String?   { didSet { store.set(selectedID, forKey: "fd.class.sel") } }
    @Published var assignLesson: String  { didSet { store.set(assignLesson, forKey: "fd.class.assign") } }

    private let store = UserDefaults.standard
    static let localRowID = "__local__"   // sentinel id for the synthetic local-user row

    init() {
        let s = UserDefaults.standard
        students = ClassroomStore.loadStudents()   // absent/empty → seedRoster() (didSet does NOT fire in init)
        live = s.bool(forKey: "fd.class.live")
        selectedID = s.string(forKey: "fd.class.sel")
        assignLesson = s.string(forKey: "fd.class.assign")
            ?? (Kit.lessons.first { !$0.done }?.id ?? Kit.lessons.first?.id ?? "l1")
    }

    private func saveStudents() {
        if let data = try? JSONEncoder().encode(students) { store.set(data, forKey: "fd.class.students") }
    }
    private static func loadStudents() -> [Student] {
        guard let data = UserDefaults.standard.data(forKey: "fd.class.students"),
              let arr = try? JSONDecoder().decode([Student].self, from: data), !arr.isEmpty
        else { return seedRoster() }   // first run only; once any edit persists, never re-seeds
        return arr
    }

    /// The 8 example peers (identical to the former TE_SEED). Persisted after the first edit so
    /// teacher changes stick; never overwrites a stored roster.
    static func seedRoster() -> [Student] {
        [ Student(id: "s1", name: "Maya R.", colorHex: "#FF6A2B", on: true,  status: "on-task", doing: "Boom Bap Groove",  done: 5, acc: 0.94, sub: Submission(beat: "First Boom Bap", pid: "boombap", acc: 0.94, reviewed: false, fb: "")),
          Student(id: "s2", name: "Liam K.", colorHex: "#33E0D4", on: true,  status: "on-task", doing: "Four on the Floor", done: 4, acc: 0.88, sub: Submission(beat: "House Party",    pid: "house",   acc: 0.88, reviewed: false, fb: "")),
          Student(id: "s3", name: "Aria P.", colorHex: "#C77DFF", on: true,  status: "idle",    doing: "Idle",             done: 3, acc: 0.72, sub: nil),
          Student(id: "s4", name: "Noah T.", colorHex: "#FFC23C", on: true,  status: "on-task", doing: "808 Trap Bounce",  done: 6, acc: 0.97, sub: Submission(beat: "Trap Star",      pid: "trap",    acc: 0.97, reviewed: true,  fb: "Incredible timing — try adding an open hat next.")),
          Student(id: "s5", name: "Zoe M.", colorHex: "#6C7BFF", on: false, status: "offline", doing: "Last seen 2d ago",  done: 2, acc: 0.61, sub: nil),
          Student(id: "s6", name: "Eli S.", colorHex: "#7AE582", on: true,  status: "on-task", doing: "The Steady Beat",   done: 3, acc: 0.79, sub: Submission(beat: "Steady Groove",  pid: "boombap", acc: 0.79, reviewed: false, fb: "")),
          Student(id: "s7", name: "Iris W.", colorHex: "#FF7AC6", on: true,  status: "idle",    doing: "Idle",             done: 4, acc: 0.83, sub: nil),
          Student(id: "s8", name: "Theo B.", colorHex: "#27C2E8", on: false, status: "offline", doing: "Last seen 1d ago",  done: 1, acc: 0.55, sub: nil) ]
    }

    /// The local user as a live roster row (#152). Read fresh from ProgressStore every render —
    /// never frozen into `students` and never persisted — so it updates the instant a lesson is
    /// completed elsewhere. `done` is clamped to `outOf` to keep the card's "N/total" scale honest.
    /// `acc` is a synthetic timing proxy derived from XP (there's no measured timing metric for the
    /// local user yet), used only for the star/percent glance.
    func localRow(progress: ProgressStore, outOf: Int, name: String = "You", colorHex: String = "#FF6A2B") -> Student {
        let realDone = Kit.lessons.filter { progress.doneLessons.contains($0.id) }.count
        let done = min(realDone, outOf)
        let acc = min(0.99, 0.5 + Double(progress.totalXP) / 1200.0)
        let status = progress.todayXP > 0 ? "on-task" : "idle"
        let doing = "Lv \(progress.level) · \(progress.totalXP) XP"
        return Student(id: ClassroomStore.localRowID, name: name, colorHex: colorHex,
                       on: true, status: status, doing: doing, done: done, acc: acc, sub: nil)
    }

    /// Mark a peer's submission reviewed (+ optional feedback text). No-op on the synthetic local
    /// row (it's never in `students`, so firstIndex returns nil). Persists via the students didSet.
    func sendFeedback(_ id: String, _ text: String) {
        guard let i = students.firstIndex(where: { $0.id == id }) else { return }
        students[i].sub?.reviewed = true
        if !text.isEmpty { students[i].sub?.fb = text }
    }
    func setFeedbackText(_ id: String, _ v: String) {
        if let i = students.firstIndex(where: { $0.id == id }) { students[i].sub?.fb = v }
    }
}
