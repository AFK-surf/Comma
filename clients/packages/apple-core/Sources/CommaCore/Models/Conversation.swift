import Foundation

// Conversation DTOs and the live events a conversation stream carries.

public struct ConversationTarget: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: String
    public let groupID: String
    public let conversationID: String
    public init(workspaceID: String, groupID: String, conversationID: String) {
        self.workspaceID = workspaceID; self.groupID = groupID; self.conversationID = conversationID
    }
}

/// REST Conversation DTO; never an Electron renderer projection.
public struct Conversation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let groupID: String
    public let title: String
    public let status: String
    public let kind: String
    public let activityStatus: String?
    public let reviewVersion: Int?
    public let updatedAt: Double?
    public let createdAt: Double?
    public internal(set) var messages: [Message]
    public let labels: [String]?
    public let origin: String?
    public let clientPlatform: String?
    /// A Loop Task's Loop as the server sends it (`loop`); nil on every other Task.
    public let loop: JSONValue?
    public let freshness: Freshness?
    /// Set while the Task is archived; archived Tasks are listed only on request.
    public let archivedAt: Double?
    /// The status the Task had when it was archived.
    public let archivedFromStatus: String?
    /// Whether the member may archive the Task now; nil when the server did not say.
    public let archiveAvailability: ArchiveAvailability?
    /// The Task has an active public share link.
    public let shared: Bool?
    /// The newest `limit` messages. A server that ignores `message_limit` still returns a usable tail.
    public func keepingMessageTail(_ limit: Int) -> Conversation {
        guard messages.count > limit else { return self }
        var tail = self
        tail.messages = Array(messages.suffix(limit))
        return tail
    }
    public var bucket: TaskBucket { TaskBucket(status: status) }
    public var isTask: Bool { kind == "agent_task" }
    public var isArchived: Bool { status == "archived" || archivedAt != nil }
    /// When the Task last changed: `updatedAt`, else `createdAt`; nil while the server has sent neither.
    public var updatedDate: Date? { (updatedAt ?? createdAt).flatMap { $0 > 0 ? Date(wireTimestamp: $0) : nil } }
    /// The optimistic-concurrency version archive and unarchive require.
    public var archiveVersion: Int? { updatedAt.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil } }
    public var canAcceptReview: Bool {
        isTask && status == "ready_for_review" && (reviewVersion ?? 0) > 0 && !isScheduled
    }
    /// A member can end the Task by hand, a Loop too. The server also refuses Workflow and Triage Tasks.
    public var canSetStatus: Bool {
        isTask && !isArchived && ["active", "ready_for_review", "escalated"].contains(status) && archiveVersion != nil
    }
    /// Its Loop still runs it (being set up, active or paused): it never waits for a review to accept. A Task whose
    /// Loop ended keeps its `loop`.
    private var isScheduled: Bool { ["pending", "active", "paused"].contains(loop?.object?["state"]?.string) }
    enum CodingKeys: String, CodingKey {
        case id, groupID = "group_id", title, status, kind, activityStatus = "activity_status"
        case reviewVersion = "review_version", updatedAt = "updated_at", createdAt = "created_at"
        case messages, labels, origin, clientPlatform = "client_platform", loop, freshness
        case archivedAt = "archived_at", archivedFromStatus = "archived_from_status"
        case archiveAvailability = "archive_availability", shared
    }
    public init(id: String, groupID: String, title: String, status: String, kind: String,
                activityStatus: String? = nil, reviewVersion: Int? = nil, updatedAt: Double? = nil,
                createdAt: Double? = nil, messages: [Message] = [], labels: [String]? = nil,
                origin: String? = nil, clientPlatform: String? = nil, loop: JSONValue? = nil,
                freshness: Freshness? = nil, archivedAt: Double? = nil, archivedFromStatus: String? = nil,
                archiveAvailability: ArchiveAvailability? = nil, shared: Bool? = nil) {
        self.id = id; self.groupID = groupID; self.title = title; self.status = status; self.kind = kind
        self.activityStatus = activityStatus; self.reviewVersion = reviewVersion; self.updatedAt = updatedAt
        self.createdAt = createdAt; self.messages = messages; self.labels = labels; self.origin = origin
        self.clientPlatform = clientPlatform; self.loop = loop; self.freshness = freshness
        self.archivedAt = archivedAt; self.archivedFromStatus = archivedFromStatus
        self.archiveAvailability = archiveAvailability; self.shared = shared
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), groupID: try c.decode(String.self, forKey: .groupID),
                  title: try c.decode(String.self, forKey: .title), status: try c.decode(String.self, forKey: .status),
                  kind: try c.decode(String.self, forKey: .kind), activityStatus: try c.decodeIfPresent(String.self, forKey: .activityStatus),
                  reviewVersion: try c.decodeIfPresent(Int.self, forKey: .reviewVersion), updatedAt: try c.decodeIfPresent(Double.self, forKey: .updatedAt),
                  createdAt: try c.decodeIfPresent(Double.self, forKey: .createdAt), messages: try c.decodeIfPresent([Message].self, forKey: .messages) ?? [],
                  labels: try c.decodeIfPresent([String].self, forKey: .labels), origin: try c.decodeIfPresent(String.self, forKey: .origin),
                  clientPlatform: try c.decodeIfPresent(String.self, forKey: .clientPlatform), loop: try c.decodeIfPresent(JSONValue.self, forKey: .loop),
                  freshness: try c.decodeIfPresent(Freshness.self, forKey: .freshness),
                  archivedAt: try c.decodeIfPresent(Double.self, forKey: .archivedAt),
                  archivedFromStatus: try c.decodeIfPresent(String.self, forKey: .archivedFromStatus),
                  archiveAvailability: try c.decodeIfPresent(ArchiveAvailability.self, forKey: .archiveAvailability),
                  shared: try c.decodeIfPresent(Bool.self, forKey: .shared))
    }
}

public struct Freshness: Codable, Equatable, Sendable { public let state: String }

/// Whether the server lets the member archive a Task now. `reason` says why not: `not_finished`,
/// `schedule_bound`, or a reason this client does not know yet.
public struct ArchiveAvailability: Codable, Equatable, Sendable {
    public let allowed: Bool
    public let reason: String?
    public init(allowed: Bool, reason: String? = nil) { self.allowed = allowed; self.reason = reason }
}

/// The Worker bound to a Task, as reported by the Task's participant-status event.
public struct BoundWorker: Codable, Equatable, Sendable {
    public let participantID: String
    public let actorID: String?
    public let name: String
    enum CodingKeys: String, CodingKey { case participantID = "participant_id", actorID = "actor_id", name }
    public init(participantID: String, actorID: String? = nil, name: String) {
        self.participantID = participantID; self.actorID = actorID; self.name = name
    }
}

/// Runtime owner activity is independent of Task business status.
public struct ParticipantStatus: Codable, Equatable, Identifiable, Sendable {
    public let conversationID: String
    public let participantID: String
    public let state: String
    public let status: String
    public let updatedAt: Double
    public let issue: String?
    public var id: String { participantID }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", participantID = "participant_id", state, status
        case updatedAt = "updated_at", issue
    }
    public init(conversationID: String, participantID: String, state: String, status: String, updatedAt: Double, issue: String? = nil) {
        self.conversationID = conversationID; self.participantID = participantID; self.state = state
        self.status = status; self.updatedAt = updatedAt; self.issue = issue
    }
}

public struct ConversationEvent: Decodable, Equatable, Sendable {
    public let type: String
    public let conversationID: String?
    public let groupID: String?
    public let title: String?
    public let status: String?
    public internal(set) var messages: [Message]?
    public let participantDraft: AssistantDraft?
    public let participantStatus: ParticipantStatus?
    public let participants: [ParticipantStatus]?
    public let boundWorker: BoundWorker?
    public let draftID: String?
    public let responseKey: String?
    public let sourceMessageIDs: [String]?
    public let revision: Int?
    public let text: String?
    public let delta: String?
    public let participantID: String?
    public let state: String?
    public let updatedAt: Double?
    public let reason: String?
    enum CodingKeys: String, CodingKey {
        case type, conversationID = "conversation_id", groupID = "group_id", title, status, messages
        case participantDraft = "participant_draft", participantStatus = "participant_status", participants
        case boundWorker = "bound_worker"
        case draftID = "draft_id", responseKey = "response_key", sourceMessageIDs = "source_message_ids"
        case revision, text, delta, participantID = "participant_id", state, updatedAt = "updated_at", reason
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        title = try c.decodeIfPresent(String.self, forKey: .title); status = try c.decodeIfPresent(String.self, forKey: .status)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages)
        // Invalid transient owner data must not destroy independently readable history.
        participantDraft = try? c.decodeIfPresent(AssistantDraft.self, forKey: .participantDraft)
        participantStatus = try? c.decodeIfPresent(ParticipantStatus.self, forKey: .participantStatus)
        participants = try? c.decodeIfPresent([ParticipantStatus].self, forKey: .participants)
        boundWorker = try? c.decodeIfPresent(BoundWorker.self, forKey: .boundWorker)
        draftID = try c.decodeIfPresent(String.self, forKey: .draftID); responseKey = try c.decodeIfPresent(String.self, forKey: .responseKey)
        sourceMessageIDs = try c.decodeIfPresent([String].self, forKey: .sourceMessageIDs)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision); text = try c.decodeIfPresent(String.self, forKey: .text)
        delta = try c.decodeIfPresent(String.self, forKey: .delta); participantID = try c.decodeIfPresent(String.self, forKey: .participantID)
        state = try c.decodeIfPresent(String.self, forKey: .state); updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}
