import Foundation

/// Ordinary alerts only. ActivityKit and push-to-start do not share this consent.
public protocol DeviceNotificationTransport: Sendable {
    var sessionID: String { get }
    var accountID: String { get }
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration
    func retire() async throws
}

struct SessionDeviceNotificationChannel: DeviceNotificationTransport {
    let sessionID: String
    let accountID: String
    let registerOperation: @Sendable (String, PushEnvironment, Workspace, String, String) async throws -> NotificationRegistration
    let retireOperation: @Sendable () async throws -> Void
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration {
        try await registerOperation(token, environment, workspace, bundleID, locale)
    }
    func retire() async throws { try await retireOperation() }
}
