import Foundation

// Notification registration, Task activity and Router unread DTOs.

/// The server selects the current two eligible Tasks, independently of where they started.
public struct TaskActivitySnapshot: Codable, Equatable, Sendable {
    public let data: [Conversation]
    public init(data: [Conversation]) { self.data = data }
}

public struct RouterNotificationSnapshot: Codable, Equatable, Sendable {
    public let conversationID: String?
    public let unreadCount: Int
    public let latestMessageID: String?
    public let latestSequence: Int
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", unreadCount = "unread_count"
        case latestMessageID = "latest_message_id", latestSequence = "latest_seq"
    }
    public init(conversationID: String?, unreadCount: Int, latestMessageID: String?, latestSequence: Int) {
        self.conversationID = conversationID; self.unreadCount = unreadCount
        self.latestMessageID = latestMessageID; self.latestSequence = latestSequence
    }
}

public enum ActivityRetirementReason: String, Sendable {
    case dismissed, stopped, expired, finished, disabled
    case authorityChanged = "authority_changed"
}

public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }
public struct NotificationRegistration: Decodable, Sendable {
    public let id: String
    public let status: String
}

/// One generalized Live Status Activity item (`live_status_v1`).
public struct LiveStatusItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let workspaceID: String
    public let groupID: String
    public let conversationID: String?
    public let category: String
    public let status: String
    public let accent: String
    public let title: String
    public let subtitle: String?
    public let compactLabel: String?
    public let etaEpochSeconds: Int?
    public let progress: Double?
    public let stepCurrent: Int?
    public let stepTotal: Int?
    public let stepLabel: String?
    public let detailLeft: String?
    public let detailRight: String?
    public let staleEpochSeconds: Int?
    public let expiresEpochSeconds: Int?
    public let startedAtEpochSeconds: Int?
    public let dismissAtEpochSeconds: Int?
    public let updatedAtEpochSeconds: Int

    enum CodingKeys: String, CodingKey {
        case key
        case workspaceID = "workspace_id"
        case groupID = "group_id"
        case conversationID = "conversation_id"
        case category, status, accent, title, subtitle
        case compactLabel = "compact_label"
        case etaEpochSeconds = "eta_epoch_seconds"
        case progress
        case stepCurrent = "step_current"
        case stepTotal = "step_total"
        case stepLabel = "step_label"
        case detailLeft = "detail_left"
        case detailRight = "detail_right"
        case staleEpochSeconds = "stale_epoch_seconds"
        case expiresEpochSeconds = "expires_epoch_seconds"
        case startedAtEpochSeconds = "started_at_epoch_seconds"
        case dismissAtEpochSeconds = "dismiss_at_epoch_seconds"
        case updatedAtEpochSeconds = "updated_at_epoch_seconds"
    }

    public init(key: String, workspaceID: String, groupID: String, conversationID: String? = nil,
                category: String, status: String, accent: String = "auto", title: String,
                subtitle: String? = nil, compactLabel: String? = nil, etaEpochSeconds: Int? = nil,
                progress: Double? = nil, stepCurrent: Int? = nil, stepTotal: Int? = nil,
                stepLabel: String? = nil, detailLeft: String? = nil, detailRight: String? = nil,
                staleEpochSeconds: Int? = nil, expiresEpochSeconds: Int? = nil,
                startedAtEpochSeconds: Int? = nil, dismissAtEpochSeconds: Int? = nil,
                updatedAtEpochSeconds: Int) {
        self.key = key
        self.workspaceID = workspaceID
        self.groupID = groupID
        self.conversationID = conversationID
        self.category = category
        self.status = status
        self.accent = accent
        self.title = title
        self.subtitle = subtitle
        self.compactLabel = compactLabel
        self.etaEpochSeconds = etaEpochSeconds
        self.progress = progress
        self.stepCurrent = stepCurrent
        self.stepTotal = stepTotal
        self.stepLabel = stepLabel
        self.detailLeft = detailLeft
        self.detailRight = detailRight
        self.staleEpochSeconds = staleEpochSeconds
        self.expiresEpochSeconds = expiresEpochSeconds
        self.startedAtEpochSeconds = startedAtEpochSeconds
        self.dismissAtEpochSeconds = dismissAtEpochSeconds
        self.updatedAtEpochSeconds = updatedAtEpochSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        workspaceID = try c.decode(String.self, forKey: .workspaceID)
        groupID = try c.decode(String.self, forKey: .groupID)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        category = try c.decode(String.self, forKey: .category)
        status = try c.decode(String.self, forKey: .status)
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "auto"
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        compactLabel = try c.decodeIfPresent(String.self, forKey: .compactLabel)
        etaEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .etaEpochSeconds)
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        stepCurrent = try c.decodeIfPresent(Int.self, forKey: .stepCurrent)
        stepTotal = try c.decodeIfPresent(Int.self, forKey: .stepTotal)
        stepLabel = try c.decodeIfPresent(String.self, forKey: .stepLabel)
        detailLeft = try c.decodeIfPresent(String.self, forKey: .detailLeft)
        detailRight = try c.decodeIfPresent(String.self, forKey: .detailRight)
        staleEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .staleEpochSeconds)
        expiresEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .expiresEpochSeconds)
        startedAtEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .startedAtEpochSeconds)
        dismissAtEpochSeconds = try c.decodeIfPresent(Int.self, forKey: .dismissAtEpochSeconds)
        updatedAtEpochSeconds = try c.decode(Int.self, forKey: .updatedAtEpochSeconds)
    }
}

public struct LiveStatusSnapshot: Codable, Equatable, Sendable {
    public let data: [LiveStatusItem]
    public init(data: [LiveStatusItem]) { self.data = data }
}
