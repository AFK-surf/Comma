import Foundation

// The OS notification authorization the controller reads and requests.

public struct TaskNotificationPermission: Equatable, Sendable {
    public enum Authorization: Equatable, Sendable { case notDetermined, denied, allowed }
    public let authorization: Authorization
    public let quiet: Bool
    public let badgeAllowed: Bool
    /// The OS reported explicit authorization, rather than provisional/ephemeral delivery.
    /// Individual alert, sound and badge choices still come from current OS settings.
    public let explicitlyAuthorized: Bool
    public init(authorization: Authorization, quiet: Bool = false, badgeAllowed: Bool = false, explicitlyAuthorized: Bool = false) {
        self.authorization = authorization; self.quiet = quiet; self.badgeAllowed = badgeAllowed
        self.explicitlyAuthorized = explicitlyAuthorized
    }
}

@MainActor public protocol TaskNotificationSystem: AnyObject {
    func settings() async -> TaskNotificationPermission
    /// Requests all interactions used by the app. Initial prompts require explicit opt-in;
    /// an already explicitly authorized choice can update its requested options once.
    func requestAuthorization() async throws -> TaskNotificationPermission
    /// Must settle with a token or an error within a bounded time.
    func deviceToken() async throws -> String
}
