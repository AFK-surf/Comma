import Foundation
import Testing
@testable import CommaCore

@Suite("Ordinary task notification consent and lifecycle") @MainActor
struct TaskNotificationControllerTests {
    // Old clients enrolled from authorization/token callbacks with no explicit choice.
    // New clients retire the authenticated unknown device slot before recording OFF.
    @Test func legacyRetirementMustSettleBeforeOffAndRetryDeletesNotRegisters() async {
        let h = NotificationHarness()
        await h.mutations.pause("delete:s1")
        await h.mutations.fail("delete:s1")
        h.context()
        await h.mutations.waitForPause()
        #expect(h.controller.status == .loading)
        #expect(h.controller.record == nil)
        #expect(!h.controller.canToggle)
        #expect(h.preferences.records.isEmpty)
        await h.mutations.release()
        await h.controller.settle()
        #expect(h.controller.status == .legacyFailed)
        #expect(h.controller.record == nil)
        await h.mutations.fail(nil)
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.status == .off)
        #expect(h.preferences.records.values.first?.intent == false)
        #expect(await h.mutations.events == ["delete:s1", "delete:s1"])
        #expect(h.system.authorizationRequests == 0)
    }

    @Test func offNeverAutoEnablesOnTokenScopeOrForegroundCallbacks() async {
        let h = NotificationHarness(); await h.start()
        h.controller.tokenChanged(); h.controller.refresh(); h.controller.retry()
        h.controller.setContext(sessionID: "s1", accountID: "a1", workspace: Workspace(id: "w2", groupID: "g2", name: "Other"))
        await h.controller.settle()
        #expect(h.controller.status == .off)
        #expect(await h.mutations.events == ["delete:s1"])
        #expect(h.system.authorizationRequests == 0)
        #expect(h.system.tokenRequests == 0)
    }

    @Test func deniedKeepsOnIntentAndRefreshDoesNotAskAgain() async {
        let h = NotificationHarness(); await h.start()
        h.system.current = .init(authorization: .notDetermined)
        h.system.answer = .init(authorization: .denied)
        await h.enable()
        #expect(h.controller.intent)
        #expect(h.controller.status == .denied)
        #expect(h.system.authorizationRequests == 1)
        #expect(!h.controller.canPresent)
        h.controller.refresh(); await h.controller.settle()
        #expect(h.system.authorizationRequests == 1)
        h.system.current = .init(authorization: .allowed)
        h.controller.refresh(); await h.controller.settle()
        #expect(h.controller.status == .active)
        #expect(h.controller.canPresent)
        #expect(h.system.authorizationRequests == 1)
    }

    @Test func disableFailureRestoresOnAndAllAutomaticPathsRetryRetirement() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.fail("delete:s1")
        h.controller.intent = false; await h.controller.settle()
        #expect(h.controller.intent)
        #expect(h.controller.status == .disableFailed)
        #expect(h.controller.record?.retirementRequested == true)
        #expect(!h.controller.canPresent)
        h.controller.tokenChanged(); h.controller.refresh(); await h.controller.settle()
        #expect(h.controller.status == .disableFailed)
        #expect(await h.mutations.events.filter { $0.hasPrefix("post:") }.count == 1)
        await h.mutations.fail(nil)
        h.controller.retry(); await h.controller.settle()
        #expect(!h.controller.intent)
        #expect(h.controller.status == .off)
        #expect(h.controller.record?.registrationID == nil)
        h.controller.tokenChanged(); await h.controller.settle()
        #expect(await h.mutations.events.filter { $0.hasPrefix("post:") }.count == 1)
    }

    @Test func workspaceReplacementWaitsForPriorServerCallAndFailureKeepsOldRemoteScope() async {
        let h = NotificationHarness(); await h.start()
        await h.mutations.pause("post:s1:w1")
        h.controller.intent = true
        await h.mutations.waitForPause()
        let next = Workspace(id: "w2", groupID: "g2", name: "Other")
        await h.mutations.fail("post:s1:w2")
        h.controller.setContext(sessionID: "s1", accountID: "a1", workspace: next)
        #expect(!h.controller.canPresent)
        await h.mutations.release(); await h.controller.settle()
        #expect(h.controller.status == .scopeFailed)
        #expect(h.controller.record?.workspaceID == "w1")
        #expect(h.controller.record?.registrationID == "registration-w1")
        #expect(await h.mutations.maximumActive == 1)
        await h.mutations.fail(nil)
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.record?.workspaceID == "w2")
        #expect(h.controller.canPresent)
    }

    @Test func accountSwitchCompensatesUsingOldSessionBeforeNewAccountOff() async {
        let h = NotificationHarness(); await h.start()
        await h.mutations.pause("post:s1:w1")
        h.controller.intent = true
        await h.mutations.waitForPause()
        h.context(session: "s2", account: "a2")
        #expect(h.controller.record == nil)
        #expect(!h.controller.canPresent)
        await h.mutations.release(); await h.controller.settle()
        #expect(await h.mutations.events == ["delete:s1", "post:s1:w1", "delete:s1", "delete:s2"])
        #expect(await h.mutations.maximumActive == 1)
        #expect(h.controller.sessionID == "s2")
        #expect(h.controller.status == .off)
        #expect(!h.controller.intent)
    }

    @Test func logoutRetiresCapturedSlotAndClearsLocalRecord() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.controller.setContext(sessionID: nil, accountID: nil, workspace: nil)
        await h.controller.settle()
        #expect(!h.controller.canPresent)
        #expect(h.controller.record == nil)
        #expect(h.preferences.records.values.first?.intent == true, "Logout retires authority, not this installation’s explicit account choice")
        #expect(h.preferences.records.values.first?.registrationID == nil)
        #expect(await h.mutations.events.last == "delete:s1")
    }

    @Test func unavailableWorkspaceRetiresOldScopeWithoutChangingOnIntent() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.controller.setContext(sessionID: "s1", accountID: "a1", workspace: nil)
        await h.controller.settle()
        #expect(h.controller.intent)
        #expect(h.controller.status == .noWorkspace)
        #expect(h.controller.record?.registrationID == nil)
        #expect(!h.controller.canPresent)
    }

    @Test func tokenFailureExitsPendingAndRetryEnables() async {
        let h = NotificationHarness(); await h.start()
        h.system.tokenFails = true
        await h.enable()
        #expect(h.controller.status == .enableFailed)
        #expect(h.controller.intent)
        #expect(!h.controller.busy)
        h.system.tokenFails = false
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.status == .active)
    }

    @Test func preferenceReadFailureCannotMasqueradeAsOff() async {
        let h = NotificationHarness(); h.preferences.fail = true
        h.context(); await h.controller.settle()
        #expect(h.controller.status == .legacyFailed)
        #expect(h.controller.record == nil)
        #expect(await h.mutations.events.isEmpty)
        h.preferences.fail = false
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.status == .off)
    }

    @Test func restartPreservesFailedDisableOperationInsteadOfAutoEnabling() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.fail("delete:s1")
        h.controller.intent = false; await h.controller.settle()
        let restarted = TaskNotificationController(origin: "https://notifications.test", bundleID: "test.main.phone",
            environment: .sandbox, locale: "en-US", preferences: h.preferences, system: h.system)
        restarted.setContext(sessionID: "s1", accountID: "a1", workspace: h.workspace)
        restarted.attach(NotificationChannelProbe(sessionID: "s1", accountID: "a1", mutations: h.mutations))
        await restarted.settle()
        #expect(restarted.status == .disableFailed)
        #expect(restarted.intent)
        #expect(await h.mutations.events.filter { $0.hasPrefix("post:") }.count == 1)
    }
}
