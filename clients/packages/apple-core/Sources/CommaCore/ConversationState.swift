import Foundation

/// UI-shaped state for one exact owner. Canonical rows, transient drafts and participant activity have separate authority.
public struct ConversationState: Sendable {
    public let target: ConversationTarget
    public private(set) var conversation: Conversation?
    public private(set) var messages: [Message] = []
    public private(set) var draft: AssistantDraft?
    public private(set) var participantStatuses: [ParticipantStatus] = []
    /// The Task's Worker, carried by each Task participant-status snapshot.
    public private(set) var boundWorker: BoundWorker?
    public private(set) var syncWarning: String?
    private var incarnation = 0
    private var snapshotReady = false
    private var completedDraft = false
    private var cancellationFence: (responseKey: String, sources: [String], through: Int)?

    public init(target: ConversationTarget) { self.target = target }

    /// Keep visible content during a reconnect; accept transient data only after this connection's snapshot.
    @discardableResult
    public mutating func beginStream() -> Int {
        incarnation += 1; snapshotReady = false
        if let fence = cancellationFence, incarnation > fence.through { cancellationFence = nil }
        return incarnation
    }

    public mutating func reconcile(conversation next: Conversation) throws {
        guard next.groupID == target.groupID && next.id == target.conversationID else { throw CommaError.invalidResponse }
        conversation = next
        if next.messages.isEmpty && !messages.isEmpty { syncWarning = "suspect-empty"; return }
        messages = merge(messages, next.messages); syncWarning = nil
    }

    public mutating func prependHistory(_ page: MessagePage) throws {
        guard page.data.count <= 100 else { throw CommaError.responseTooLarge }
        messages = merge(page.data, messages)
    }

    /// Returns true when the owner should reconnect/refetch. Group task events never rewrite the Task's business status.
    @discardableResult
    public mutating func apply(event: ConversationEvent, incarnation expected: Int) throws -> Bool {
        guard expected == incarnation else { return false }
        guard event.groupID == nil || event.groupID == target.groupID,
              event.conversationID == nil || event.conversationID == target.conversationID else { throw CommaError.invalidResponse }
        switch event.type {
        case "snapshot":
            let old = conversation
            let snapshot = Conversation(id: target.conversationID, groupID: target.groupID,
                title: event.title ?? old?.title ?? "", status: event.status ?? old?.status ?? "open",
                kind: old?.kind ?? "user_chat", activityStatus: old?.activityStatus,
                reviewVersion: old?.reviewVersion, updatedAt: old?.updatedAt, createdAt: old?.createdAt,
                messages: event.messages ?? [], labels: old?.labels, origin: old?.origin,
                clientPlatform: old?.clientPlatform, schedule: old?.schedule, freshness: old?.freshness)
            try reconcile(conversation: snapshot)
            snapshotReady = true
            participantStatuses = event.participantStatus.map { validParticipant($0) ? [$0] : [] } ?? []
            let previous = draft
            draft = nil; completedDraft = false
            if let owner = event.participantDraft, validDraft(owner), !cancelled(owner) {
                if let previous, sameIdentity(previous, owner) {
                    draft = cumulative(previous, owner)
                } else { draft = owner }
            }
            return false
        case "conversation_invalidated", "conversation_list_invalidated", "conversation_list_resync_required", "message_created":
            return true
        case "task_participant_statuses":
            guard let statuses = event.participants, statuses.count <= 2,
                  statuses.allSatisfy(validParticipant), Set(statuses.map(\.participantID)).count == statuses.count else { return false }
            participantStatuses = statuses
            boundWorker = event.boundWorker
            return false
        case "participant_status":
            guard snapshotReady, let id = event.participantID, let state = event.state,
                  let status = event.status, let updatedAt = event.updatedAt else { return false }
            let next = ParticipantStatus(conversationID: target.conversationID, participantID: id, state: state, status: status, updatedAt: updatedAt)
            guard validParticipant(next) else { return false }
            if let old = participantStatuses.first(where: { $0.id == id }), old.updatedAt > updatedAt { return false }
            participantStatuses = participantStatuses.filter { $0.id != id } + [next]
            return false
        case "participant_status_cleared":
            guard snapshotReady, event.reason == "owner_unavailable", let id = event.participantID else { return false }
            participantStatuses.removeAll { $0.id == id }; return false
        default:
            guard event.type.hasPrefix("message_draft_"), snapshotReady,
                  let conversationID = event.conversationID, let draftID = event.draftID,
                  let responseKey = event.responseKey, let sources = event.sourceMessageIDs,
                  let revision = event.revision, let text = event.text else { return false }
            let next = AssistantDraft(conversationID: conversationID, draftID: draftID, responseKey: responseKey,
                                      sourceMessageIDs: sources, revision: revision, text: text)
            guard validDraft(next), !cancelled(next) else { return false }
            let kind = String(event.type.dropFirst("message_draft_".count))
            if let current = draft {
                if current.responseKey == next.responseKey {
                    guard current.sourceMessageIDs == next.sourceMessageIDs else { return false }
                    if kind == "cancelled" {
                        // Hold cumulative pixels until the next authoritative snapshot installs committed rows.
                        cancellationFence = (next.responseKey, next.sourceMessageIDs, incarnation + 1)
                        return true
                    }
                    guard !completedDraft else { return false }
                    draft = cumulative(current, next)
                    completedDraft = kind == "completed"
                    return false
                }
                guard !completedDraft && kind == "started" else { return false }
            } else { guard kind == "started" else { return false } }
            guard kind == "started" else { return false }
            draft = next; completedDraft = false; return false
        }
    }

    private func validParticipant(_ value: ParticipantStatus) -> Bool {
        value.conversationID == target.conversationID && !value.participantID.isEmpty && ["active", "error", "stopped"].contains(value.state)
    }
    private func validDraft(_ value: AssistantDraft) -> Bool {
        value.conversationID == target.conversationID && !value.draftID.isEmpty && !value.responseKey.isEmpty && value.revision >= 0 &&
        !value.sourceMessageIDs.isEmpty && value.sourceMessageIDs.allSatisfy({ !$0.isEmpty }) &&
        Set(value.sourceMessageIDs).count == value.sourceMessageIDs.count
    }
    private func sameIdentity(_ left: AssistantDraft, _ right: AssistantDraft) -> Bool {
        left.responseKey == right.responseKey && left.sourceMessageIDs == right.sourceMessageIDs
    }
    private func cancelled(_ value: AssistantDraft) -> Bool {
        cancellationFence.map { $0.responseKey == value.responseKey && $0.sources == value.sourceMessageIDs && incarnation <= $0.through } ?? false
    }
    private func cumulative(_ previous: AssistantDraft, _ next: AssistantDraft) -> AssistantDraft {
        // Full cumulative text is recovery authority. Delta is never blindly appended after a missed/replayed frame.
        guard next.text.hasPrefix(previous.text) else { return previous }
        return next
    }
    private func merge(_ older: [Message], _ newer: [Message]) -> [Message] {
        let visible = older.filter(\.isVisible)
        var order = visible.map(\.id), values = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in newer where message.isVisible {
            if values[message.id] == nil { order.append(message.id) }
            values[message.id] = message
        }
        var seen: Set<String> = []
        return order.compactMap { id in seen.insert(id).inserted ? values[id] : nil }
    }
}
