import Foundation
import Testing
@testable import CommaCore

extension TaskNotificationControllerTests {
    @Test func currentSession401NeverSubstitutesForMigrationOrDisable204() async {
        let h = NotificationHarness()
        await h.mutations.fail("delete:s1", error: .http(status: 401, code: "session_revoked", retryAfter: nil))
        h.context(); await h.controller.settle()
        #expect(h.controller.record == nil)
        #expect(h.controller.status == .legacyFailed)
        #expect(h.preferences.records.isEmpty)
        await h.mutations.fail(nil)
        h.controller.retry(); await h.controller.settle(); await h.enable()
        await h.mutations.fail("delete:s1", error: .http(status: 401, code: "session_revoked", retryAfter: nil))
        h.controller.intent = false; await h.controller.settle()
        #expect(h.controller.intent)
        #expect(h.controller.status == .disableFailed)
        #expect(h.controller.record?.registrationID == "registration-w1")
    }

    @Test func revokedOldSession401CanRetireCompensationWithoutChangingNewSession() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.fail("delete:s1", error: .http(status: 401, code: "session_revoked", retryAfter: nil))
        h.context(session: "s2", account: "a2"); await h.controller.settle()
        #expect(h.controller.sessionID == "s2")
        #expect(h.controller.status == .off)
        #expect(h.preferences.records.values.filter(\.intent).count == 1, "The old account's choice is retained independently of revoked authority")
    }

    @Test func sameAccountReplacementSessionKeepsChoiceButReplacesRegistrationAuthority() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.context(session: "s2", account: "a1")
        #expect(h.controller.intent)
        #expect(h.controller.record?.registrationID == nil)
        #expect(!h.controller.canPresent)
        await h.controller.settle()
        #expect(h.controller.intent)
        #expect(h.controller.status == .active)
        #expect(h.controller.record?.registrationSessionID == "s2")
        #expect(await h.mutations.events == ["delete:s1", "post:s1:w1", "delete:s1", "post:s2:w1"])
        #expect(h.preferences.records.count == 1)
        #expect(h.system.authorizationRequests == 0)
    }

    @Test func returningToSameAccountAfterLogoutKeepsExplicitChoice() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.controller.setContext(sessionID: nil, accountID: nil, workspace: nil)
        await h.controller.settle()
        h.context(session: "s2", account: "a1"); await h.controller.settle()
        #expect(h.controller.intent)
        #expect(h.controller.status == .active)
        #expect(h.controller.record?.registrationSessionID == "s2")
        #expect(h.preferences.records.count == 1)
    }

    @Test func authBoundarySuspendsPresentationBeforeRemoteRevocationSettles() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.controller.suspendIdentity()
        #expect(!h.controller.canPresent)
        #expect(!h.controller.canToggle)
        #expect(h.controller.intent, "Pending logout does not erase durable consent")
        h.controller.tokenChanged(); h.controller.refresh(); await h.controller.settle()
        #expect(await h.mutations.events == ["delete:s1", "post:s1:w1"])
        h.controller.resumeIdentity(); await h.controller.settle()
        #expect(h.controller.canPresent)
    }
}
