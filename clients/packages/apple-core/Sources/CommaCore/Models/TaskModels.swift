import Foundation

// Task status buckets, the Group label catalog, share links and pins.

public enum TaskBucket: String, Codable, Sendable, CaseIterable {
    case inProgress, needsReview, done, cancelled, archived
    public init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "in_progress", "running", "working": self = .inProgress
        case "escalated", "needs_review", "ready_for_review", "review", "waiting_for_review": self = .needsReview
        case "closed", "completed", "done", "success", "succeeded", "terminal": self = .done
        case "cancelled", "canceled", "failed", "error": self = .cancelled
        case "archived": self = .archived
        default: self = .inProgress
        }
    }
}

/// The statuses a member can end an in-progress or in-review Task with by hand.
public enum ManualTaskStatus: String, Sendable, CaseIterable {
    case completed, cancelled
    public var bucket: TaskBucket { self == .completed ? .done : .cancelled }
}

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
