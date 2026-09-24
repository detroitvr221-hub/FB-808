import Foundation
import Testing
@testable import FB_808

// Classroom hardening and privacy (PRODUCTION_READINESS_AUDIT_2026-09-24 B4/B5/M1/M5).
@Suite(.serialized)
struct ClassroomPrivacyTests {
    @Test @MainActor func roomCodesAreEightUnambiguousSymbols() {
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        for _ in 0..<200 {
            let code = SessionStore.randomCode()
            #expect(code.hasPrefix("FD-"))
            let body = code.dropFirst(3)
            #expect(body.count == 8)
            #expect(body.allSatisfy { allowed.contains($0) })
        }
    }

    /// The host token must outlive the session so a finished class can still be reviewed and deleted.
    @Test func hostedClassesPersistUntilForgotten() {
        let code = "FD-TEST" + String(UUID().uuidString.prefix(4))
        PastClassStore.remember(PastClass(code: code, token: "tok", title: "Test", started: Date()))
        #expect(PastClassStore.all().contains { $0.code == code && $0.token == "tok" })
        PastClassStore.forget(code: code)
        #expect(!PastClassStore.all().contains { $0.code == code })
    }

    /// Past the server's 30-day retention there is nothing left to review, so the list hides it.
    @Test func expiredClassesAreNotListed() {
        let code = "FD-OLD" + String(UUID().uuidString.prefix(4))
        PastClassStore.remember(PastClass(code: code, token: "t", title: "Old", started: Date(timeIntervalSinceNow: -31 * 24 * 3600)))
        #expect(!PastClassStore.all().contains { $0.code == code })
        PastClassStore.forget(code: code)
    }

    @Test @MainActor func rosterKeepsTheServerEnrollmentID() {
        let entry = RosterEntry(name: "Ana", online: true, enrollmentID: "e-1")
        #expect(entry.enrollmentID == "e-1")
    }

    @Test func privacyPolicyLinkIsPublic() {
        #expect(AppLinks.privacyPolicy.scheme == "https")
        #expect(AppLinks.privacyPolicy.absoluteString.hasSuffix("PRIVACY.md"))
    }
}
