import Foundation

/// Captures the Auth Session that owns an ActivityKit registration and its compensating deletion.
public protocol ActivityNotificationTransport: Sendable {
    var sessionID: String { get }
    var accountID: String { get }
    func register(token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration
    func retire(id: String, reason: ActivityRetirementReason) async throws
}

struct SessionActivityNotificationChannel: ActivityNotificationTransport {
    let sessionID: String
    let accountID: String
    let registerOperation: @Sendable (String, String?, String) async throws -> NotificationRegistration
    let retireOperation: @Sendable (String, ActivityRetirementReason) async throws -> Void
    func register(token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration {
        try await registerOperation(token, activityID, registrationID)
    }
    func retire(id: String, reason: ActivityRetirementReason) async throws { try await retireOperation(id, reason) }
}

/// Captures the Auth Session that owns generalized Live Status (`live_status_v1`) registrations.
public protocol LiveStatusNotificationTransport: Sendable {
    var sessionID: String { get }
    var accountID: String { get }
    func register(token: String, activityID: String?, liveKey: String?, registrationID: String) async throws -> NotificationRegistration
    func retire(id: String, reason: ActivityRetirementReason) async throws
}

struct SessionLiveStatusNotificationChannel: LiveStatusNotificationTransport {
    let sessionID: String
    let accountID: String
    let registerOperation: @Sendable (String, String?, String?, String) async throws -> NotificationRegistration
    let retireOperation: @Sendable (String, ActivityRetirementReason) async throws -> Void
    func register(token: String, activityID: String?, liveKey: String?, registrationID: String) async throws -> NotificationRegistration {
        try await registerOperation(token, activityID, liveKey, registrationID)
    }
    func retire(id: String, reason: ActivityRetirementReason) async throws { try await retireOperation(id, reason) }
}
