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
    public var bucket: TaskBucket { TaskBucket(status: status, loopState: loop?.object?["state"]?.string) }
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
/// or a reason this client does not know yet.
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

/// Structured provider/account detail accompanying a participant `issue`.
public struct ParticipantIssueDetail: Codable, Equatable, Sendable {
    public let source: String?
    public let profileID: String?
    public let profileName: String?
    public let resetAt: Double?
    public let credits: Bool?
    public let trigger: String?
    enum CodingKeys: String, CodingKey {
        case source, profileID = "profile_id", profileName = "profile_name", resetAt = "reset_at", credits, trigger
    }
    public init(source: String? = nil, profileID: String? = nil, profileName: String? = nil,
                resetAt: Double? = nil, credits: Bool? = nil, trigger: String? = nil) {
        self.source = source; self.profileID = profileID; self.profileName = profileName
        self.resetAt = resetAt; self.credits = credits; self.trigger = trigger
    }
}

/// One active worker session in a multi-session Task roster (`worker_sessions`, up to 6 entries).
public struct WorkerSession: Codable, Equatable, Identifiable, Sendable {
    public let participantID: String
    public let actorID: String?
    public let slot: String
    public let label: String
    public let model: String?
    public let runtime: String?
    public let isPrimary: Bool
    public let subscribed: Bool?
    public let state: String
    public let status: String
    public let updatedAt: Double?
    public let issue: String?
    public let issueDetail: ParticipantIssueDetail?
    public var id: String { participantID }
    enum CodingKeys: String, CodingKey {
        case participantID = "participant_id", actorID = "actor_id", slot, label, model, runtime
        case isPrimary = "is_primary", subscribed, state, status, updatedAt = "updated_at", issue
        case issueDetail = "issue_detail"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantID = try c.decode(String.self, forKey: .participantID)
        actorID = try c.decodeIfPresent(String.self, forKey: .actorID)
        slot = try c.decode(String.self, forKey: .slot)
        label = try c.decode(String.self, forKey: .label)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        subscribed = try c.decodeIfPresent(Bool.self, forKey: .subscribed)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "stopped"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        issueDetail = try? c.decodeIfPresent(ParticipantIssueDetail.self, forKey: .issueDetail)
    }
    public init(participantID: String, actorID: String? = nil, slot: String, label: String,
                model: String? = nil, runtime: String? = nil, isPrimary: Bool, subscribed: Bool? = nil,
                state: String = "stopped", status: String = "", updatedAt: Double? = nil,
                issue: String? = nil, issueDetail: ParticipantIssueDetail? = nil) {
        self.participantID = participantID; self.actorID = actorID; self.slot = slot; self.label = label
        self.model = model; self.runtime = runtime; self.isPrimary = isPrimary; self.subscribed = subscribed
        self.state = state; self.status = status; self.updatedAt = updatedAt
        self.issue = issue; self.issueDetail = issueDetail
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
    public let issueDetail: ParticipantIssueDetail?
    public var id: String { participantID }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", participantID = "participant_id", state, status
        case updatedAt = "updated_at", issue, issueDetail = "issue_detail"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        participantID = try c.decode(String.self, forKey: .participantID)
        state = try c.decode(String.self, forKey: .state)
        status = try c.decode(String.self, forKey: .status)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        issue = try c.decodeIfPresent(String.self, forKey: .issue)
        issueDetail = try? c.decodeIfPresent(ParticipantIssueDetail.self, forKey: .issueDetail)
    }
    public init(conversationID: String, participantID: String, state: String, status: String,
                updatedAt: Double, issue: String? = nil, issueDetail: ParticipantIssueDetail? = nil) {
        self.conversationID = conversationID; self.participantID = participantID; self.state = state
        self.status = status; self.updatedAt = updatedAt; self.issue = issue; self.issueDetail = issueDetail
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
    public let workerSessions: [WorkerSession]?
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
        case workerSessions = "worker_sessions"
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
        workerSessions = try? c.decodeIfPresent([WorkerSession].self, forKey: .workerSessions)
        boundWorker = try? c.decodeIfPresent(BoundWorker.self, forKey: .boundWorker)
        draftID = try c.decodeIfPresent(String.self, forKey: .draftID); responseKey = try c.decodeIfPresent(String.self, forKey: .responseKey)
        sourceMessageIDs = try c.decodeIfPresent([String].self, forKey: .sourceMessageIDs)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision); text = try c.decodeIfPresent(String.self, forKey: .text)
        delta = try c.decodeIfPresent(String.self, forKey: .delta); participantID = try c.decodeIfPresent(String.self, forKey: .participantID)
        state = try c.decodeIfPresent(String.self, forKey: .state); updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}
