import Foundation
import Testing
@testable import CommaCore

@MainActor private final class NotificationMemoryPreferences: TaskNotificationPreferences {
    var records: [String: TaskNotificationRecord] = [:]
    var fail = false
    func load(key: String) throws -> TaskNotificationRecord? {
        if fail { throw CommaError.transport }; return records[key]
    }
    func save(_ record: TaskNotificationRecord, key: String) throws {
        if fail { throw CommaError.transport }; records[key] = record
    }
    func remove(key: String) throws { records.removeValue(forKey: key) }
}
@MainActor private final class NotificationSystemProbe: TaskNotificationSystem {
    var current = TaskNotificationPermission(authorization: .allowed)
    var answer = TaskNotificationPermission(authorization: .allowed)
    var authorizationRequests = 0
    var tokenRequests = 0
    var tokenFails = false
    func settings() async -> TaskNotificationPermission { current }
    func requestAuthorization() async throws -> TaskNotificationPermission {
        authorizationRequests += 1; current = answer; return current
    }
    func deviceToken() async throws -> String {
        tokenRequests += 1
        if tokenFails { throw CommaError.transport }
        return "test-only-device-routing-value"
    }
}
private actor NotificationMutationProbe {
    var events: [String] = []
    var failure: String?
    var failureError: CommaError = .transport
    var pause: String?
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: CheckedContinuation<Void, Never>?
    var active = 0
    var maximumActive = 0
    func fail(_ event: String?, error: CommaError = .transport) { failure = event; failureError = error }
    func pause(_ event: String) { pause = event }
    func waitForPause() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { continuation?.resume(); continuation = nil; pause = nil }
    func perform(_ event: String) async throws {
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        events.append(event)
        if pause == event {
            await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil }
        }
        if failure == event { throw failureError }
    }
}
private struct NotificationChannelProbe: DeviceNotificationTransport {
    let sessionID: String
    let accountID: String
    let mutations: NotificationMutationProbe
    func retire() async throws { try await mutations.perform("delete:" + sessionID) }
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration {
        try await mutations.perform("post:" + sessionID + ":" + workspace.id)
        return try JSONDecoder().decode(NotificationRegistration.self, from: Data("{\"id\":\"registration-\(workspace.id)\",\"status\":\"active\"}".utf8))
    }
}
@MainActor private struct NotificationHarness {
    let preferences = NotificationMemoryPreferences()
    let system = NotificationSystemProbe()
    let mutations = NotificationMutationProbe()
    let workspace = Workspace(id: "w1", groupID: "g1", name: "Test workspace")
    let controller: TaskNotificationController
    init() {
        controller = TaskNotificationController(origin: "https://notifications.test", bundleID: "test.main.phone",
            environment: .sandbox, locale: "en-US", preferences: preferences, system: system)
    }
    func context(session: String = "s1", account: String = "a1", workspace: Workspace? = nil) {
        controller.setContext(sessionID: session, accountID: account, workspace: workspace ?? self.workspace)
        controller.attach(NotificationChannelProbe(sessionID: session, accountID: account, mutations: mutations))
    }
    func start() async { context(); await controller.settle() }
    func enable() async { controller.intent = true; await controller.settle() }
}

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

extension TaskNotificationControllerTests {
    @Test func failedPreferenceWriteRetainsDisableOperationForRetry() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        h.preferences.fail = true
        h.controller.intent = false
        #expect(h.controller.status == .disableFailed)
        #expect(h.controller.record?.retirementRequested == true)
        #expect(h.controller.intent)
        h.preferences.fail = false
        h.controller.retry(); await h.controller.settle()
        #expect(h.controller.status == .off)
        #expect(await h.mutations.events.filter { $0.hasPrefix("post:") }.count == 1)
    }

    @Test func foregroundAlertRequiresMatchingAcknowledgedSessionAndSupportedScope() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        #expect(h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: nil, workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s2", workspaceID: "w1", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w2", groupID: "g1"))
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "other-group"))
        h.system.current = .init(authorization: .denied)
        h.controller.refresh(); await h.controller.settle()
        #expect(!h.controller.allowsForegroundAlert(sessionID: "s1", workspaceID: "w1", groupID: "g1"))
    }

    @Test func dedicatedPreferenceFileSeparatesAccountsAndRestoresAcknowledgedSessionScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notifications.json")
        let first = FileTaskNotificationPreferences(url: url)
        let on = TaskNotificationRecord(intent: true, retirementRequested: true, registrationID: "r1", workspaceID: "w1", groupID: "g1", registrationSessionID: "s1")
        try first.save(on, key: "origin|phone|a1")
        try first.save(TaskNotificationRecord(intent: false), key: "origin|phone|a2")
        let restored = FileTaskNotificationPreferences(url: url)
        #expect(try restored.load(key: "origin|phone|a1") == on)
        #expect(try restored.load(key: "origin|phone|a2")?.intent == false)
        #expect(try restored.load(key: "another-origin|phone|a1") == nil)
        try restored.remove(key: "origin|phone|a1")
        #expect(try restored.load(key: "origin|phone|a2")?.intent == false)
    }
}

extension TaskNotificationControllerTests {
    @Test func pendingDisableKeepsConfirmedOnUntilDeletionAcknowledges() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.pause("delete:s1")
        h.controller.intent = false
        await h.mutations.waitForPause()
        #expect(h.controller.status == .disabling)
        #expect(h.controller.intent, "A pending DELETE must not expose confirmed OFF")
        #expect(!h.controller.canToggle)
        #expect(!h.controller.canPresent)
        await h.mutations.release(); await h.controller.settle()
        #expect(!h.controller.intent)
        #expect(h.controller.status == .off)
    }

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

    @Test func foregroundMissingOrUnauthorizedTaskNeverPresents() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        let missing = await h.controller.authorizeForegroundAlert(taskID: nil, sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
            Issue.record("Missing task IDs must not start a private read"); return true
        })
        #expect(!missing)
        let denied = await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
            throw CommaError.http(status: 403, code: "forbidden", retryAfter: nil)
        })
        #expect(!denied)
        let accessible = await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { target in
            target.groupID == "g1" && target.workspaceID == "w1" && target.conversationID == "task"
        })
        #expect(accessible)
    }

    @Test func foregroundRechecksAuthAndScopeAfterAwaitedTaskAccess() async {
        let h = NotificationHarness(); await h.start(); await h.enable()
        await h.mutations.pause("read:task")
        let mutations = h.mutations
        let checking = Task {
            await h.controller.authorizeForegroundAlert(taskID: "task", sessionID: "s1", workspaceID: "w1", groupID: "g1", check: { _ in
                try await mutations.perform("read:task"); return true
            })
        }
        await h.mutations.waitForPause()
        h.controller.suspendIdentity()
        await h.mutations.release()
        #expect(await checking.value == false)
        await h.controller.settle()
    }
}
