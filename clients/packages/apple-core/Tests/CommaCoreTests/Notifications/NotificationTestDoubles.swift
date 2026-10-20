import Foundation
@testable import CommaCore

// In-memory preferences, an OS permission probe and a serialized mutation recorder for notification tests.

@MainActor final class NotificationMemoryPreferences: TaskNotificationPreferences {
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
@MainActor final class NotificationSystemProbe: TaskNotificationSystem {
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
actor NotificationMutationProbe {
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
struct NotificationChannelProbe: DeviceNotificationTransport {
    let sessionID: String
    let accountID: String
    let mutations: NotificationMutationProbe
    func retire() async throws { try await mutations.perform("delete:" + sessionID) }
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration {
        try await mutations.perform("post:" + sessionID + ":" + workspace.id)
        return try JSONDecoder().decode(NotificationRegistration.self, from: Data("{\"id\":\"registration-\(workspace.id)\",\"status\":\"active\"}".utf8))
    }
}
@MainActor struct NotificationHarness {
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
