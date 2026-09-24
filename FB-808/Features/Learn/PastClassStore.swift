//  Classes this iPad hosted, with their teacher tokens, in the Keychain (device-only). Lets a teacher
//  review and delete a finished class's submissions after "End Live Class" or an app kill — the token
//  used to exist only in memory, orphaning that class's data (PRODUCTION_READINESS M5 / B5).

import Foundation
import Security
import os

enum PastClassStore {
    private static let service = "com.blkmkt.fd808.classes"
    private static let account = "hosted"
    /// Server data expires 30 days after last activity, so older entries only point at nothing.
    static let retention: TimeInterval = 30 * 24 * 3600
    private static let cap = 20

    static func all(now: Date = Date()) -> [PastClass] {
        load().filter { now.timeIntervalSince($0.started) < retention }.sorted { $0.started > $1.started }
    }

    static func remember(_ c: PastClass) {
        var list = load().filter { $0.code != c.code }
        list.insert(c, at: 0)
        save(Array(list.prefix(cap)))
    }

    static func forget(code: String) { save(load().filter { $0.code != code }) }

    private static func load() -> [PastClass] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([PastClass].self, from: data)) ?? []
    }

    private static func save(_ list: [PastClass]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { $1 }
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess { fdLog.error("Couldn't store hosted class token (\(status))") }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
