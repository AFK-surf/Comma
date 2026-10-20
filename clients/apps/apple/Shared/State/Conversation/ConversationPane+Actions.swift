import Foundation
import CommaCore

/// What the member asks of a conversation: sends and attachments, the feedback while a reply comes,
/// and changes to its Task.
extension ConversationPane {
    // MARK: Reply feedback

    /// Reply feedback from the desktop `ParticipantStatusSlot`: local "Thinking…" after this client's
    /// send until a reply or draft appears, then the participant's own activity.
    var replyActivity: String? {
        guard target != nil, !streamingReply else { return nil }
        let visible = messages
        var hasResponse = visible.last.map { !$0.isUser } ?? false
        if let request = awaitingReply {
            if let index = visible.lastIndex(where: { $0.clientRequestID == request }) {
                hasResponse = visible[(index + 1)...].contains { !$0.isUser }
            } else {
                hasResponse = false
            }
            let failed = pendingSends.contains { $0.id == request && $0.status == .failed }
            if !hasResponse && !failed { return String(localized: "Thinking…") }
        }
        guard participantStatuses.contains(where: { $0.state == "active" }) else { return nil }
        return hasResponse ? String(localized: "Working…") : String(localized: "Thinking…")
    }

    /// Thinking about or streaming a reply: the Comma mark plays its animation instead of standing still.
    /// Reads `streamingReply`, not the draft, so the shell's router button does not update per token.
    var isReplying: Bool { replyActivity != nil || streamingReply }

    // MARK: Sending

    func send() async {
        guard let attempt = enqueueSend() else { return }
        await deliver(attempt)
    }

    /// Queues the draft as a pending send without waiting for delivery, so the view can start
    /// the send motion for this exact attempt before calling `deliver(_:)`. Picked Tasks go as their links, picked
    /// agent commands as their control text, and each catalog skill the text names is tagged, as on the desktop; a
    /// retry sends the same skills.
    func enqueueSend() -> PendingSend? {
        let text = outgoingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, canSend, !attachmentsBlockSend, !text.isEmpty || !attachments.isEmpty else { return nil }
        let skills = Skill.mentionedLocations(in: text, catalog: store?.skills.catalog ?? [])
        let attempt = PendingSend(target: target, text: text, attachments: attachments, skills: skills,
                                  replyToMessageID: replyTargetID)
        pendingSends.append(attempt)
        // The first reply answers the chosen message; later ones answer the thread's newest message.
        if replyThread?.targetID != nil { replyThread?.targetID = nil }
        awaitingReply = attempt.id
        draftText = ""
        draftMentions = []
        draftCommands = []
        store?.saveDraft("", for: target)
        drafts = []
        Task { [weak self] in
            try? await Task.sleep(for: Self.awaitingReplyTimeout)
            if self?.awaitingReply == attempt.id { self?.awaitingReply = nil }
        }
        return attempt
    }

    func deliver(_ attempt: PendingSend) async {
        guard let store, !sending, !closed else { return }
        let token = fence
        sendOperation += 1
        let operation = sendOperation
        sending = true
        if let index = pendingSends.firstIndex(where: { $0.id == attempt.id }) { pendingSends[index].status = .sending }
        defer { if isLive(token), sendOperation == operation { sending = false } }
        do {
            let result = try await store.client.send(target: attempt.target, text: attempt.text, requestID: attempt.id,
                                                     attachments: attempt.attachments, skills: attempt.skills,
                                                     replyToMessageID: attempt.replyToMessageID)
            guard isLive(token) else { return }
            if target == attempt.target { try reconcile(result) }
            if let index = pendingSends.firstIndex(where: { $0.id == attempt.id }) {
                pendingSends[index].status = .accepted
            }
        } catch {
            guard isLive(token) else { return }
            if let index = pendingSends.firstIndex(where: { $0.id == attempt.id }) {
                pendingSends[index].status = .failed
            }
            if awaitingReply == attempt.id { awaitingReply = nil }
            present(error, token, as: .send(attempt.id))
        }
    }

    func retry(_ attempt: PendingSend) async {
        guard store?.session != nil, !loading, !closed,
              pendingSends.contains(where: { $0.id == attempt.id && $0.status == .failed }) else { return }
        // The banner explained this failure; the row now shows the send going again.
        if errorOrigin == .send(attempt.id) { dismissError() }
        awaitingReply = attempt.id
        await deliver(attempt)
    }

    /// Sign-out authority change: an in-flight send can no longer succeed from this view.
    func invalidateSends() {
        sendOperation += 1
        sending = false
        pendingSends = pendingSends.map { item in
            var next = item
            if next.status == .sending { next.status = .failed }
            return next
        }
    }

    // MARK: Task actions

    /// Ends the Task by hand as Done or Cancelled, against the version the member saw.
    func setStatus(_ status: ManualTaskStatus) async {
        guard let store, let target, let detail = conversation, detail.canSetStatus,
              let version = detail.archiveVersion else { return }
        let token = fence
        do {
            let updated = try await store.client.setTaskStatus(target: target, status: status, expectedUpdatedAt: version)
            guard isLive(token) else { return }
            try reconcile(updated)
            await store.refreshTaskList()
        } catch {
            present(error, token, as: .request)
            await refresh()
        }
    }

    func cancelTask() async {
        guard let store, let target, isTask else { return }
        let token = fence
        do {
            let updated = try await store.client.cancelTask(target: target)
            guard isLive(token) else { return }
            try reconcile(updated)
            await store.refreshTaskList()
        } catch { present(error, token, as: .request) }
    }

    /// Reads the catalog once per pane; a failed read leaves it empty so the next open retries.
    func loadLabelCatalog() async {
        guard let store, labelCatalog == nil, isTask else { return }
        let token = fence
        do {
            let catalog = try await store.client.taskLabels(groupID: workspace.groupID)
            guard isLive(token) else { return }
            labelCatalog = catalog.labels
        } catch { present(error, token, as: .request) }
    }

    /// Replaces the Task's labels. Ids deleted from the catalog are dropped first: the server refuses
    /// any write that names one.
    func setLabels(_ ids: [String]) async {
        guard let store, let target, isTask, !labelsBusy else { return }
        let known = Set(labelCatalog?.map(\.id) ?? [])
        let token = fence
        labelsBusy = true
        defer { if isLive(token) { labelsBusy = false } }
        do {
            let updated = try await store.client.setTaskLabels(target: target, labelIDs: ids.filter(known.contains))
            guard isLive(token) else { return }
            try reconcile(updated)
        } catch { present(error, token, as: .request) }
    }

    /// The catalog after a label change elsewhere (Settings or a proposal decision).
    func installLabelCatalog(_ labels: [TaskLabel]) {
        guard !closed else { return }
        labelCatalog = labels
    }
}

extension ConversationPane {
    /// Where an error came from. Only a failed read is worth repeating as it was: a failed send is retried from its own
    /// row, a refused change is made again, and a file that could not be attached is chosen again.
    enum ErrorOrigin: Equatable {
        /// A read of the conversation.
        case server
        /// A change the member asked for (status, cancel, labels) that the server refused, or a read the member's
        /// own step needed (the label catalog). Reading the conversation again does not answer it, so a later read
        /// keeps it.
        case request
        /// The pending send, by id, that could not be delivered.
        case send(String)
        /// Work on this device: a file too large, a photo that would not load.
        case local

        /// A later read of the conversation that works clears it: a failed read, and a failed send, whose own row
        /// keeps its Retry.
        var answeredByRead: Bool {
            switch self {
            case .server, .send: true
            case .request, .local: false
            }
        }
    }
}

struct PendingSend: Identifiable {
    enum Status { case sending, accepted, failed }
    let id = UUID().uuidString
    let target: ConversationTarget
    let text: String
    let attachments: [ContentBlock]
    /// Locations of the catalog skills the text names, sent as the desktop `skills` field.
    var skills: [String] = []
    /// The message this send answers, kept for retries.
    var replyToMessageID: String?
    var status: Status = .sending
}
