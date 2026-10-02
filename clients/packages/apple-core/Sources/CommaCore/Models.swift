import Foundation

public enum ApplePlatform: String, Codable, Sendable { case ios, watchos }

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

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

public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public let data: [Element]
    public let hasMore: Bool?
    public let nextCursor: String?
    enum CodingKeys: String, CodingKey { case data, hasMore = "has_more", nextCursor = "next_cursor" }
    public init(data: [Element], hasMore: Bool? = nil, nextCursor: String? = nil) {
        self.data = data; self.hasMore = hasMore; self.nextCursor = nextCursor
    }
}

public struct ConversationTarget: Codable, Equatable, Hashable, Sendable {
    public let workspaceID: String
    public let groupID: String
    public let conversationID: String
    public init(workspaceID: String, groupID: String, conversationID: String) {
        self.workspaceID = workspaceID; self.groupID = groupID; self.conversationID = conversationID
    }
}

public enum TaskBucket: String, Codable, Sendable, CaseIterable {
    case backlog, inProgress, needsReview, done, cancelled, archived
    public init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "in_progress", "running", "working": self = .inProgress
        case "escalated", "needs_review", "ready_for_review", "review", "waiting_for_review": self = .needsReview
        case "closed", "completed", "done", "success", "succeeded", "terminal": self = .done
        case "cancelled", "canceled", "failed", "error": self = .cancelled
        case "archived": self = .archived
        default: self = .backlog
        }
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
    public let messages: [Message]
    public let labels: [String]?
    public let origin: String?
    public let clientPlatform: String?
    public let schedule: JSONValue?
    public let freshness: Freshness?
    /// Set while the Task is archived; archived Tasks are listed only on request.
    public let archivedAt: Double?
    /// The Task has an active public share link.
    public let shared: Bool?
    /// The newest `limit` messages. A server that ignores `message_limit` still returns a usable tail.
    public func keepingMessageTail(_ limit: Int) -> Conversation {
        guard messages.count > limit else { return self }
        return Conversation(id: id, groupID: groupID, title: title, status: status, kind: kind, activityStatus: activityStatus,
                            reviewVersion: reviewVersion, updatedAt: updatedAt, createdAt: createdAt,
                            messages: Array(messages.suffix(limit)), labels: labels, origin: origin,
                            clientPlatform: clientPlatform, schedule: schedule, freshness: freshness,
                            archivedAt: archivedAt, shared: shared)
    }
    public var bucket: TaskBucket { TaskBucket(status: status) }
    public var isTask: Bool { kind == "agent_task" }
    public var isArchived: Bool { status == "archived" || archivedAt != nil }
    /// The optimistic-concurrency version archive and unarchive require.
    public var archiveVersion: Int? { updatedAt.map { Int($0) }.flatMap { $0 > 0 ? $0 : nil } }
    public var canAcceptReview: Bool {
        isTask && status == "ready_for_review" && (reviewVersion ?? 0) > 0 &&
        (schedule == nil || schedule == .null || schedule == .object([:]))
    }
    enum CodingKeys: String, CodingKey {
        case id, groupID = "group_id", title, status, kind, activityStatus = "activity_status"
        case reviewVersion = "review_version", updatedAt = "updated_at", createdAt = "created_at"
        case messages, labels, origin, clientPlatform = "client_platform", schedule, freshness
        case archivedAt = "archived_at", shared
    }
    public init(id: String, groupID: String, title: String, status: String, kind: String,
                activityStatus: String? = nil, reviewVersion: Int? = nil, updatedAt: Double? = nil,
                createdAt: Double? = nil, messages: [Message] = [], labels: [String]? = nil,
                origin: String? = nil, clientPlatform: String? = nil, schedule: JSONValue? = nil,
                freshness: Freshness? = nil, archivedAt: Double? = nil, shared: Bool? = nil) {
        self.id = id; self.groupID = groupID; self.title = title; self.status = status; self.kind = kind
        self.activityStatus = activityStatus; self.reviewVersion = reviewVersion; self.updatedAt = updatedAt
        self.createdAt = createdAt; self.messages = messages; self.labels = labels; self.origin = origin
        self.clientPlatform = clientPlatform; self.schedule = schedule; self.freshness = freshness
        self.archivedAt = archivedAt; self.shared = shared
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), groupID: try c.decode(String.self, forKey: .groupID),
                  title: try c.decode(String.self, forKey: .title), status: try c.decode(String.self, forKey: .status),
                  kind: try c.decode(String.self, forKey: .kind), activityStatus: try c.decodeIfPresent(String.self, forKey: .activityStatus),
                  reviewVersion: try c.decodeIfPresent(Int.self, forKey: .reviewVersion), updatedAt: try c.decodeIfPresent(Double.self, forKey: .updatedAt),
                  createdAt: try c.decodeIfPresent(Double.self, forKey: .createdAt), messages: try c.decodeIfPresent([Message].self, forKey: .messages) ?? [],
                  labels: try c.decodeIfPresent([String].self, forKey: .labels), origin: try c.decodeIfPresent(String.self, forKey: .origin),
                  clientPlatform: try c.decodeIfPresent(String.self, forKey: .clientPlatform), schedule: try c.decodeIfPresent(JSONValue.self, forKey: .schedule),
                  freshness: try c.decodeIfPresent(Freshness.self, forKey: .freshness),
                  archivedAt: try c.decodeIfPresent(Double.self, forKey: .archivedAt),
                  shared: try c.decodeIfPresent(Bool.self, forKey: .shared))
    }
}

public struct Freshness: Codable, Equatable, Sendable { public let state: String }

/// One Group catalog label. `color` is a preset name (`blue`, `success`, …) or a `#rrggbb` custom colour.
public struct TaskLabel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let description: String?
    public init(id: String, name: String, color: String, description: String? = nil) {
        self.id = id; self.name = name; self.color = color; self.description = description
    }
}

/// A label change an agent proposed. It applies only after a member approves it.
public struct TaskLabelProposal: Codable, Equatable, Identifiable, Sendable {
    public struct ProposedLabel: Codable, Equatable, Sendable {
        public let id: String?
        public let name: String
        public let color: String
        public let description: String?
    }
    public struct Payload: Codable, Equatable, Sendable {
        public let labels: [ProposedLabel]?
        public let conversationTitle: String?
        enum CodingKeys: String, CodingKey { case labels, conversationTitle = "conversation_title" }
    }
    public let id: String
    /// `create`, `update`, `delete` or `apply`.
    public let op: String
    public let status: String
    public let summary: String?
    public let payload: Payload?
    public var isPending: Bool { status == "pending" }
}

/// The Group's label catalog, the agent proposals awaiting a member, and the approval policy.
public struct TaskLabelCatalog: Codable, Equatable, Sendable {
    public let labels: [TaskLabel]
    public let proposals: [TaskLabelProposal]
    /// Preset colour names the server accepts.
    public let colors: [String]
    /// `ask` keeps agent proposals pending; `auto` applies them.
    public let approvalPolicy: String
    enum CodingKeys: String, CodingKey { case labels, proposals, colors, approvalPolicy = "approval_policy" }
    public init(labels: [TaskLabel], proposals: [TaskLabelProposal] = [], colors: [String] = [], approvalPolicy: String = "ask") {
        self.labels = labels; self.proposals = proposals; self.colors = colors; self.approvalPolicy = approvalPolicy
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = try c.decode([TaskLabel].self, forKey: .labels)
        // A proposal shape this client does not know must not hide the catalog itself.
        proposals = (try? c.decodeIfPresent([TaskLabelProposal].self, forKey: .proposals)) ?? []
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []
        approvalPolicy = try c.decodeIfPresent(String.self, forKey: .approvalPolicy) ?? "ask"
    }
    public var pendingProposals: [TaskLabelProposal] { proposals.filter(\.isPending) }
}

/// The owner's view of a Task's public share link.
public struct TaskShare: Codable, Equatable, Sendable {
    public let url: String
    public let createdAt: Double
    public let sharedAt: Double
    public let messageCount: Int
    public let artifactCount: Int
    /// Messages arrived after the link's cutoff; publishing again moves the cutoff to the latest message.
    public let hasNewerMessages: Bool
    enum CodingKeys: String, CodingKey {
        case url, createdAt = "created_at", sharedAt = "shared_at", messageCount = "message_count"
        case artifactCount = "artifact_count", hasNewerMessages = "has_newer_messages"
    }
}

/// One pinned Task in the Group.
public struct PinnedTask: Codable, Equatable, Sendable {
    public let conversation: Conversation
    public let pinnedAt: Double
    enum CodingKeys: String, CodingKey { case conversation, pinnedAt = "pinned_at" }
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
    /// Active: not revoked and not expired at `now` (seconds).
    public func isActive(now: Double = Date().timeIntervalSince1970) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > now } ?? true)
    }
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

public struct ContentBlock: Codable, Equatable, Sendable {
    public let type: String
    public let fields: [String: JSONValue]
    public var text: String? { fields["text"]?.string }
    public init(type: String, fields: [String: JSONValue] = [:]) { self.type = type; self.fields = fields }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode([String: JSONValue].self)
        guard let type = value["type"]?.string, !type.isEmpty else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Content block requires a type")
        }
        self.type = type; self.fields = value.filter { $0.key != "type" }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields.merging(["type": .string(type)]) { _, expected in expected })
    }
}

public struct Message: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let actorType: String
    public let content: [ContentBlock]
    public let clientRequestID: String?
    public let replyToMessageID: String?
    public let threadRootMessageID: String?
    public let agentID: String?
    public let userID: String?
    public let roleLabel: String?
    public let createdAt: Double?
    public let metadata: [String: JSONValue]?
    public let agentInput: JSONValue?
    public var rawText: String { content.compactMap(\.text).joined(separator: "\n") }
    public var text: String { Self.publicText(rawText) }
    public var isUser: Bool { actorType == "user" }
    public var isVisible: Bool {
        if rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[[comma-context]]") { return false }
        if actorType == "system", agentInput != nil { return false }
        if actorType == "system" && kind == "app_event",
           ["provider.output", "provider.status", "message.redelivery"].contains(metadata?["event_type"]?.string ?? "") { return false }
        return true
    }
    enum CodingKeys: String, CodingKey {
        case id = "message_id", kind, actorType = "actor_type", content, clientRequestID = "client_request_id"
        case replyToMessageID = "reply_to_message_id", threadRootMessageID = "thread_root_message_id"
        case agentID = "agent_id", userID = "user_id", roleLabel = "role_label"
        case createdAt = "created_at", metadata, agentInput = "agent_input"
    }
    public init(id: String, kind: String, actorType: String, content: [ContentBlock], clientRequestID: String? = nil,
                replyToMessageID: String? = nil, threadRootMessageID: String? = nil, agentID: String? = nil,
                userID: String? = nil, roleLabel: String? = nil, createdAt: Double? = nil,
                metadata: [String: JSONValue]? = nil, agentInput: JSONValue? = nil) {
        self.id = id; self.kind = kind; self.actorType = actorType; self.content = content
        self.clientRequestID = clientRequestID; self.replyToMessageID = replyToMessageID
        self.threadRootMessageID = threadRootMessageID; self.agentID = agentID; self.userID = userID; self.roleLabel = roleLabel
        self.createdAt = createdAt; self.metadata = metadata; self.agentInput = agentInput
    }
    public static func publicText(_ text: String) -> String {
        let prefix = text.components(separatedBy: "[[comma-protocol]]").first ?? ""
        return prefix.replacingOccurrences(of: "```comma:[\\s\\S]*?(?:```|$)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct AssistantDraft: Codable, Equatable, Identifiable, Sendable {
    public let conversationID: String
    public let draftID: String
    public let responseKey: String
    public let sourceMessageIDs: [String]
    public let revision: Int
    public let text: String
    public var displayText: String { Message.publicText(text) }
    public var id: String { responseKey + ":" + sourceMessageIDs.joined(separator: ",") }
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id", draftID = "draft_id", responseKey = "response_key"
        case sourceMessageIDs = "source_message_ids", revision, text
    }
    public init(conversationID: String, draftID: String, responseKey: String, sourceMessageIDs: [String], revision: Int, text: String) {
        self.conversationID = conversationID; self.draftID = draftID; self.responseKey = responseKey
        self.sourceMessageIDs = sourceMessageIDs; self.revision = revision; self.text = text
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

public struct SequenceSpan: Codable, Equatable, Sendable { public let first: Int; public let last: Int }
public struct MessagePage: Codable, Sendable {
    public let data: [Message]
    public let covered: SequenceSpan?
    public let bounds: SequenceSpan?
    public let hasOlder: Bool
    public let hasNewer: Bool
    enum CodingKeys: String, CodingKey { case data, covered, bounds, hasOlder = "has_older", hasNewer = "has_newer" }
}
public struct DownloadedAttachment: Sendable {
    public let data: Data
    public let contentType: String
    public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
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
public enum PushEnvironment: String, Codable, Sendable { case sandbox, production }
public struct NotificationRegistration: Decodable, Sendable {
    public let id: String
    public let status: String
}
