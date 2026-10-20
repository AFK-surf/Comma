import Foundation
import Testing
@testable import CommaCore

@MainActor private final class BadgeChoicePreferences: TaskNotificationPreferences {
    var records: [String: TaskNotificationRecord] = [:]
    func load(key: String) throws -> TaskNotificationRecord? { records[key] }
    func save(_ record: TaskNotificationRecord, key: String) throws { records[key] = record }
    func remove(key: String) throws { records.removeValue(forKey: key) }
}

@MainActor private final class BadgeAuthorizationSystem: TaskNotificationSystem {
    var permission: TaskNotificationPermission
    var requests = 0
    var failRequest = false
    var tokenFailure: CommaError?
    init(_ permission: TaskNotificationPermission) { self.permission = permission }
    func settings() async -> TaskNotificationPermission { permission }
    func requestAuthorization() async throws -> TaskNotificationPermission {
        requests += 1
        if failRequest { throw CommaError.transport }
        return permission
    }
    func deviceToken() async throws -> String {
        if let tokenFailure { throw tokenFailure }
        return "test-device-token"
    }
}

private struct BadgeDeviceChannel: DeviceNotificationTransport {
    let sessionID = "session"
    let accountID = "account"
    let failure: CommaError?
    init(failure: CommaError? = nil) { self.failure = failure }
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration {
        if let failure { throw failure }
        return try JSONDecoder().decode(NotificationRegistration.self, from: Data("{\"id\":\"device-registration\",\"status\":\"active\"}".utf8))
    }
    func retire() async throws {}
}

@Suite("Notification authorization and setup failures") @MainActor
struct TaskNotificationBadgeAuthorizationTests {
    private let key = "https://badge.test|surf.comma.ios|account"
    private let workspace = Workspace(id: "workspace", groupID: "group", name: "Workspace")

    private func controller(_ preferences: BadgeChoicePreferences, _ system: BadgeAuthorizationSystem) -> TaskNotificationController {
        TaskNotificationController(origin: "https://badge.test", bundleID: "surf.comma.ios", environment: .sandbox,
                                   locale: "en-US", preferences: preferences, system: system)
    }
    private func attach(_ controller: TaskNotificationController, channel: BadgeDeviceChannel = BadgeDeviceChannel()) {
        controller.setContext(sessionID: "session", accountID: "account", workspace: workspace)
        controller.attach(channel)
    }

    @Test func legacyOptInRequestsCompleteOptionsOnceAndPreservesDisabledBadgeAcrossRestart() async throws {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = try JSONDecoder().decode(TaskNotificationRecord.self,
            from: Data("{\"intent\":true,\"retirementRequested\":false}".utf8))
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, quiet: true,
                                                     badgeAllowed: false, explicitlyAuthorized: true))
        let first = controller(preferences, system)
        attach(first); await first.settle()
        #expect(system.requests == 1)
        #expect(first.status == .quiet)
        #expect(!first.permission.badgeAllowed)
        #expect(first.record?.intent == true)
        #expect(preferences.records[key]?.fullAuthorizationRequested == true)
        first.refresh(); await first.settle()
        #expect(system.requests == 1)

        first.setContext(sessionID: "session", accountID: "account", workspace: nil)
        await first.settle()
        #expect(first.status == .noWorkspace)
        #expect(preferences.records[key]?.fullAuthorizationRequested == true)
        let persisted = try JSONEncoder().encode(preferences.records[key])
        preferences.records[key] = try JSONDecoder().decode(TaskNotificationRecord.self, from: persisted)
        let restarted = controller(preferences, system)
        attach(restarted); await restarted.settle()
        #expect(system.requests == 1)
        #expect(restarted.status == .quiet)
        #expect(!restarted.permission.badgeAllowed)
    }

    @Test func unknownOffDeniedAndProvisionalChoicesCannotTriggerAnAuthorizationUpgrade() async {
        let cases: [(Bool?, TaskNotificationPermission, TaskNotificationController.Status)] = [
            (nil, .init(authorization: .notDetermined), .off),
            (false, .init(authorization: .allowed, explicitlyAuthorized: true), .off),
            (true, .init(authorization: .denied), .denied),
            (true, .init(authorization: .allowed, quiet: true), .quiet)
        ]
        for (intent, permission, status) in cases {
            let preferences = BadgeChoicePreferences()
            if let intent { preferences.records[key] = TaskNotificationRecord(intent: intent) }
            let system = BadgeAuthorizationSystem(permission)
            let current = controller(preferences, system)
            attach(current); await current.settle()
            current.refresh(); await current.settle()
            #expect(system.requests == 0)
            #expect(current.status == status)
        }
    }

    @Test func anAlreadyGrantedBadgeDoesNotRequestAgainAfterTheUserDisablesIt() async {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = TaskNotificationRecord(intent: true)
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, badgeAllowed: true,
                                                     explicitlyAuthorized: true))
        let current = controller(preferences, system)
        attach(current); await current.settle()
        #expect(system.requests == 0)
        system.permission = .init(authorization: .allowed, badgeAllowed: false, explicitlyAuthorized: true)
        current.refresh(); await current.settle()
        #expect(system.requests == 0)
        #expect(!current.permission.badgeAllowed)
        #expect(current.record?.intent == true)
    }

    @Test func aFailedUpgradeCanBeRetriedExplicitlyWithoutAutomaticRequestLoops() async {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = TaskNotificationRecord(intent: true)
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, explicitlyAuthorized: true))
        system.failRequest = true
        let current = controller(preferences, system)
        attach(current); await current.settle()
        #expect(current.status == .enableFailed)
        #expect(system.requests == 1)
        current.refresh(); await current.settle()
        #expect(system.requests == 1)
        system.failRequest = false
        current.retry(); await current.settle()
        #expect(system.requests == 2)
        #expect(current.status == .active)
        #expect(!current.permission.badgeAllowed)
    }

    @Test func phoneTokenFailureAndServerPushConfigurationFailureShowDifferentActions() async throws {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = TaskNotificationRecord(intent: true)
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, badgeAllowed: true))
        system.tokenFailure = .transport
        let current = controller(preferences, system)
        attach(current); await current.settle()
        #expect(current.status == .enableFailed)
        #expect(current.failure == .transport)
        let phoneMessage = try #require(current.failureMessage)

        system.tokenFailure = nil
        let serverFailure = CommaError.http(status: 503, code: "push_unavailable", retryAfter: nil)
        attach(current, channel: BadgeDeviceChannel(failure: serverFailure))
        await current.settle()
        #expect(current.failure == serverFailure)
        let serverMessage = try #require(current.failureMessage)
        #expect(phoneMessage != serverMessage)
        #expect(current.intent)
        #expect(!current.canPresent)
    }

    @Test func failedRegistrationKeepsItsRetryInformationAndClearsAfterAnExplicitRetry() async {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = TaskNotificationRecord(intent: true)
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, badgeAllowed: true))
        let current = controller(preferences, system)
        let unavailable = CommaError.http(status: 503, code: "push_unavailable", retryAfter: 1)
        attach(current, channel: BadgeDeviceChannel(failure: unavailable))
        await current.settle()
        #expect(current.status == .enableFailed)
        #expect(current.failure == unavailable)
        #expect(current.failureMessage != nil)
        #expect(current.record?.registrationID == nil)

        attach(current)
        current.retry()
        #expect(current.failure == nil)
        #expect(current.failureMessage == nil)
        await current.settle()
        #expect(current.status == .active)
        #expect(current.canPresent)
        #expect(current.failure == nil)
        #expect(current.failureMessage == nil)
    }

    @Test func authenticationFailuresHaveSafeMessagesAndUnknownDetailsUseTheExistingFallback() async {
        let preferences = BadgeChoicePreferences()
        preferences.records[key] = TaskNotificationRecord(intent: true)
        let system = BadgeAuthorizationSystem(.init(authorization: .allowed, badgeAllowed: true))
        let current = controller(preferences, system)
        let privateDetail = "private workspace path and message content"
        attach(current, channel: BadgeDeviceChannel(failure: .http(status: 403, code: privateDetail, retryAfter: nil)))
        await current.settle()
        #expect(current.failureMessage != nil)
        #expect(current.failureMessage?.contains(privateDetail) == false)
        attach(current, channel: BadgeDeviceChannel(failure: .invalidInput(privateDetail)))
        await current.settle()
        #expect(current.status == .enableFailed)
        #expect(current.failureMessage == nil)
        attach(current, channel: BadgeDeviceChannel(failure: .http(status: 409, code: privateDetail, retryAfter: nil)))
        await current.settle()
        #expect(current.status == .enableFailed)
        #expect(current.failureMessage == nil)
    }
}
