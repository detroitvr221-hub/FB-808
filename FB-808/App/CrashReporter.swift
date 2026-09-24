//  On-device crash / hang / exit diagnostics via MetricKit. Nothing is uploaded: payloads are kept in
//  Application Support and appended to Settings → "Copy / share diagnostics", which the user sends
//  themselves (PRODUCTION_READINESS H6 — production crashes and watchdog kills were invisible).

import Foundation
import MetricKit
import os

final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    /// Newest-first cap on retained payload files — each can be tens of KB of call stacks.
    private static let keep = 12
    private let queue = DispatchQueue(label: "fd808.crashreporter", qos: .utility)

    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let items = payloads.map { ($0.timeStampEnd, $0.jsonRepresentation()) }
        queue.async { for (date, json) in items { self.store(json, stamp: date, kind: "diagnostic") } }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Only exit reasons matter here (jetsam / watchdog / background-task kills never reach a crash log).
        let items = payloads.compactMap { p -> (Date, Data)? in
            guard p.applicationExitMetrics != nil else { return nil }
            return (p.timeStampEnd, p.jsonRepresentation())
        }
        queue.async { for (date, json) in items { self.store(json, stamp: date, kind: "exits") } }
    }

    private func store(_ json: Data, stamp: Date, kind: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(kind)-\(Int(stamp.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
            try json.write(to: dir.appendingPathComponent(name), options: .atomic)
            let files = storedFiles()
            for old in files.dropFirst(Self.keep) { try? fm.removeItem(at: old) }
        } catch {
            fdLog.error("Couldn't keep diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Newest first.
    private func storedFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    /// Text appended to the diagnostics share: a count line plus the three newest payloads verbatim.
    func report() -> String {
        queue.sync {
            let files = storedFiles()
            guard !files.isEmpty else { return "\n\n— Crash & exit reports: none recorded" }
            var out = "\n\n— Crash & exit reports (\(files.count) kept on this iPad)"
            for file in files.prefix(3) {
                guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
                out += "\n\n[\(file.lastPathComponent)]\n" + text
            }
            return out
        }
    }
}
