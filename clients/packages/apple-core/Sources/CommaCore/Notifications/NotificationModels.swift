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
