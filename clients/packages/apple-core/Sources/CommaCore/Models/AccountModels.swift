import Foundation

// Sign-in, session, workspace and member account DTOs.

public enum ApplePlatform: String, Codable, Sendable { case ios, watchos }

public struct CommaUser: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let name: String?
    public init(id: String, email: String, name: String? = nil) { self.id = id; self.email = email; self.name = name }
}

/// Public session identity. The bearer stays inside CommaClient and its Keychain store.
public struct CommaSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let expiresAt: Double
    public let user: CommaUser
    enum CodingKeys: String, CodingKey { case id = "session_id", expiresAt = "expires_at", user }
    public init(id: String, expiresAt: Double, user: CommaUser) { self.id = id; self.expiresAt = expiresAt; self.user = user }
}

public struct EmailChallenge: Codable, Equatable, Sendable {
    public let challengeID: String
    enum CodingKeys: String, CodingKey { case challengeID = "challenge_id" }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let groupID: String
    public let name: String
    public let status: String?
    enum CodingKeys: String, CodingKey { case id, groupID = "group_id", name, status }
    public init(id: String, groupID: String, name: String, status: String? = nil) {
        self.id = id; self.groupID = groupID; self.name = name; self.status = status
    }
}

public struct WorkspaceBootstrap: Codable, Equatable, Sendable {
    public let status: String
    public let workspace: Workspace
    public let retryAfterSeconds: Int?
    enum CodingKeys: String, CodingKey { case status, workspace, retryAfterSeconds = "retry_after_seconds" }
}

/// The signed-in member's editable profile.
public struct UserProfile: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let name: String?
    public let avatarID: String?
    enum CodingKeys: String, CodingKey { case id, email, name, avatarID = "avatar_id" }
    public init(id: String, email: String, name: String? = nil, avatarID: String? = nil) {
        self.id = id; self.email = email; self.name = name; self.avatarID = avatarID
    }
    public static let maxNameLength = 64
    public static let maxAvatarBytes = 2_097_152
}

/// One Auth Session of the member, as listed for device management.
public struct AuthSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let authMethod: String?
    public let clientKind: String?
    public let clientPlatform: String?
    public let deviceLabel: String?
    public let parentSessionID: String?
    public let authenticatedAt: Double?
    public let lastSeenAt: Double?
    public let expiresAt: Double?
    public let revokedAt: Double?
    public let restricted: Bool?
    enum CodingKeys: String, CodingKey {
        case id, authMethod = "auth_method", clientKind = "client_kind", clientPlatform = "client_platform"
        case deviceLabel = "device_label", parentSessionID = "parent_session_id", authenticatedAt = "authenticated_at"
        case lastSeenAt = "last_seen_at", expiresAt = "expires_at", revokedAt = "revoked_at", restricted
    }
    /// When the device was last seen, else when it signed in; nil while the server has sent neither.
    public var lastActiveDate: Date? { (lastSeenAt ?? authenticatedAt).map(Date.init(wireTimestamp:)) }
    /// Active: not revoked and not expired at `now` (seconds).
    public func isActive(now: Double = Date().timeIntervalSince1970) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > now } ?? true)
    }
}

public struct AppleLoginAttempt: Decodable, Sendable {
    public let attemptID: String
    public let nonce: String
    public let clientID: String
    public let expiresAt: Double
    enum CodingKeys: String, CodingKey { case attemptID = "attempt_id", nonce, clientID = "client_id", expiresAt = "expires_at" }
}
public enum AppleLoginResult: Sendable {
    case signedIn(CommaSession)
    case otpRequired(challengeID: String, email: String)
}
public struct WatchPairing: Codable, Sendable {
    public let pairingID: String
    public let pairingSecret: String
    public let expiresAt: Double
    enum CodingKeys: String, CodingKey { case pairingID = "pairing_id", pairingSecret = "pairing_secret", expiresAt = "expires_at" }
}
