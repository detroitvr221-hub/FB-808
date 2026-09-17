//  ProgressStore.swift — the engagement layer (B8): XP/levels, a daily practice
//  streak with Duolingo-style streak-freezes, a customizable daily XP goal, and
//  achievements. Persisted across launches via UserDefaults.

import SwiftUI
import Combine

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var totalXP: Int
    @Published private(set) var streak: Int
    @Published private(set) var todayXP: Int
    @Published private(set) var freezes: Int
    @Published var dailyGoal: Int { didSet { store.set(dailyGoal, forKey: "fd.dailyGoal") } }
    @Published private(set) var achievements: Set<String>
    @Published private(set) var doneLessons: Set<String>   // completed Skill-Path lessons (persisted)
    @Published var newlyUnlocked: String?     // drives a one-shot toast

    private let store = UserDefaults.standard
    private var lastDay: String               // "yyyy-MM-dd" of the last day XP was earned

    static let allAchievements: [(id: String, label: String, icon: String)] = [
        ("first", "First Beats", "music.note"),
        ("streak3", "3-Day Streak", "flame.fill"),
        ("streak7", "Week Warrior", "flame.fill"),
        ("xp500", "500 XP", "star.fill"),
        ("lvl5", "Level 5", "rosette"),
    ]

    init() {
        let s = UserDefaults.standard
        totalXP = s.integer(forKey: "fd.xp")
        streak = s.integer(forKey: "fd.streak")
        todayXP = s.integer(forKey: "fd.todayXP")
        freezes = s.object(forKey: "fd.freezes") as? Int ?? 2
        dailyGoal = s.object(forKey: "fd.dailyGoal") as? Int ?? 60
        lastDay = s.string(forKey: "fd.lastDay") ?? ""
        achievements = Set(s.stringArray(forKey: "fd.achievements") ?? [])
        doneLessons = Set(s.stringArray(forKey: "fd.doneLessons") ?? [])
        rollover()
    }

    /// Mark a Skill-Path lesson complete (persists across launches & tab switches).
    func completeLesson(_ id: String) {
        guard !doneLessons.contains(id) else { return }
        doneLessons.insert(id)
        store.set(Array(doneLessons), forKey: "fd.doneLessons")
    }

    private func today() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }
    private func dayDelta(_ a: String, _ b: String) -> Int? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let da = f.date(from: a), let db = f.date(from: b) else { return nil }
        return Calendar.current.dateComponents([.day], from: da, to: db).day
    }

    /// On launch / new day: reset today's XP, and spend freezes for any missed days.
    private func rollover() {
        let t = today()
        if lastDay == t { return }
        todayXP = 0
        if !lastDay.isEmpty, let d = dayDelta(lastDay, t), d > 1 {
            let missed = d - 1
            if freezes >= missed { freezes -= missed }   // streak survives on freezes
            else { streak = 0; freezes = 0 }             // streak broken
        }
        persist()
    }

    private var lastCreative: [String: Date] = [:]
    /// Award XP for a hands-on creative action (making a beat, sending a take to a track, exporting…),
    /// throttled per action key so it can't be button-mashed for XP. (#153 — music-making earns XP, not just Learn.)
    func awardCreative(_ key: String, _ amount: Int = 6, cooldown: TimeInterval = 12) {
        let now = Date()
        if let t = lastCreative[key], now.timeIntervalSince(t) < cooldown { return }
        lastCreative[key] = now
        addXP(amount)
    }

    func addXP(_ amount: Int) {
        guard amount > 0 else { return }
        let t = today()
        let firstToday = lastDay != t
        totalXP += amount
        todayXP += amount
        if firstToday {
            streak += 1                 // first practice of a new day extends the streak
            lastDay = t
            if streak % 5 == 0 { freezes = min(5, freezes + 1) }   // earn a freeze every 5 days
        }
        checkAchievements()
        persist()
    }

    private func checkAchievements() {
        unlock("first", totalXP > 0)
        unlock("streak3", streak >= 3)
        unlock("streak7", streak >= 7)
        unlock("xp500", totalXP >= 500)
        unlock("lvl5", level >= 5)
    }
    private func unlock(_ id: String, _ cond: Bool) {
        guard cond, !achievements.contains(id) else { return }
        achievements.insert(id)
        newlyUnlocked = ProgressStore.allAchievements.first { $0.id == id }?.label ?? "Achievement!"
    }

    var level: Int { totalXP / 120 + 1 }
    var levelProgress: Double { Double(totalXP % 120) / 120.0 }
    var goalProgress: Double { dailyGoal > 0 ? min(1, Double(todayXP) / Double(dailyGoal)) : 1 }
    var goalMet: Bool { todayXP >= dailyGoal }

    private func persist() {
        store.set(totalXP, forKey: "fd.xp")
        store.set(streak, forKey: "fd.streak")
        store.set(todayXP, forKey: "fd.todayXP")
        store.set(freezes, forKey: "fd.freezes")
        store.set(lastDay, forKey: "fd.lastDay")
        store.set(Array(achievements), forKey: "fd.achievements")
    }
}
