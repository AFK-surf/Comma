import Foundation
import Observation
import CommaCore

/// One open conversation: its transcript, event stream, sends and history.
/// Home and an open Task each own a pane, so opening or closing a Task never reloads Home.
@MainActor @Observable
final class ConversationPane {
    enum Kind: Equatable { case home, task(String) }

    let kind: Kind
    let workspace: Workspace
    private(set) var conversation: Conversation?
    private(set) var channel: ConversationState?
    private(set) var loading = false
    private(set) var sending = false
    private(set) var loadingMore = false
    private(set) var hasOlderMessages = false
    private(set) var connected = false
    private(set) var error: String?
    /// The Group's label catalog, read when the Task details first open.
    private(set) var labelCatalog: [TaskLabel]?
    private(set) var labelsBusy = false
    /// This client's latest send awaiting its reply (desktop `locallyAwaitingReply`).
    private(set) var awaitingReply: String?
    var draftText = ""
    var pendingSends: [PendingSend] = []
    var attachments: [ContentBlock] = []

    @ObservationIgnored private weak var store: CommaStore?
    /// Advances when the pane closes, so late responses and streams cannot write into it.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private(set) var closed = false
    @ObservationIgnored private var sendOperation = 0
    @ObservationIgnored private var stream: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var oldestSequence: Int?

    static let awaitingReplyTimeout: Duration = .seconds(150)

    init(kind: Kind, workspace: Workspace, store: CommaStore) {
        self.kind = kind
        self.workspace = workspace
        self.store = store
    }

    /// One operation's authority: this pane still open, and the store's session boundary unchanged.
    private struct Fence { let epoch: Int; let boundary: Int }
    private var fence: Fence { Fence(epoch: epoch, boundary: store?.boundaryToken ?? -1) }

    var isTask: Bool { if case .task = kind { true } else { false } }
    var taskID: String? { if case .task(let id) = kind { id } else { nil } }
    var target: ConversationTarget? {
        guard let conversation else { return nil }
        return ConversationTarget(workspaceID: workspace.id, groupID: conversation.groupID, conversationID: conversation.id)
    }
    var messages: [Message] { (channel?.messages ?? conversation?.messages ?? []).filter(\.isVisible) }
    var assistantDraft: AssistantDraft? { channel?.draft }
    var boundWorker: BoundWorker? { channel?.boundWorker }
    var currentPendingSends: [PendingSend] { pendingSends.filter { $0.target == target } }
    var canSend: Bool { target != nil && store?.session != nil && !sending && !loading && !closed }

    /// Reply feedback from the desktop `ParticipantStatusSlot`: local "Thinking…" after this client's
    /// send until a reply or draft appears, then the participant's own activity.
    var replyActivity: String? {
        guard target != nil, assistantDraft == nil else { return nil }
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
        guard channel?.participantStatuses.contains(where: { $0.state == "active" }) == true else { return nil }
        return hasResponse ? String(localized: "Working…") : String(localized: "Thinking…")
    }

    // MARK: Lifecycle

    func load() async {
        guard let store, !closed else { return }
        let token = fence
        loading = true
        defer { if isLive(token) { loading = false } }
        do {
            let detail: Conversation
            switch kind {
            case .home:
                detail = try await store.client.openHome(workspace: workspace)
            case .task(let id):
                let target = ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: id)
                detail = try await store.client.conversation(target: target)
            }
            guard isLive(token) else { return }
            try install(detail)
            try await prepareHistory(token)
            guard isLive(token) else { return }
            startStream()
        } catch { present(error, token) }
    }

    /// Retires the pane: its stream stops and late work cannot write into it.
    func close() {
        if let target { store?.saveDraft(draftText, for: target) }
        closed = true
        epoch += 1
        stopStream()
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

    func refresh() async {
        guard let store, let target, !closed else { return }
        let token = fence
        do {
            let detail = try await store.client.conversation(target: target)
            guard isLive(token) else { return }
            try reconcile(detail)
            error = nil
        } catch { present(error, token) }
    }

    func dismissError() { error = nil }
    func showError(_ value: String) { error = value }

    // MARK: Sending

    func send() async {
        guard let attempt = enqueueSend() else { return }
        await deliver(attempt)
    }

    /// Queues the draft as a pending send without waiting for delivery, so the view can start
    /// the send motion for this exact attempt before calling `deliver(_:)`.
    func enqueueSend() -> PendingSend? {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, canSend, !text.isEmpty || !attachments.isEmpty else { return nil }
        let attempt = PendingSend(target: target, text: text, attachments: attachments)
        pendingSends.append(attempt)
        awaitingReply = attempt.id
        draftText = ""
        store?.saveDraft("", for: target)
        attachments = []
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
            let result = try await store.client.send(target: attempt.target, text: attempt.text,
                                                     requestID: attempt.id, attachments: attempt.attachments)
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
            present(error, token)
        }
    }

    func retry(_ attempt: PendingSend) async {
        guard store?.session != nil, !loading, !closed,
              pendingSends.contains(where: { $0.id == attempt.id && $0.status == .failed }) else { return }
        awaitingReply = attempt.id
        await deliver(attempt)
    }

    func attachFile(filename: String, contentType: String, data: Data) async throws {
        guard let store, let target, attachments.count < 8 else {
            throw CommaError.invalidInput("You can attach up to eight files to a message.")
        }
        let token = fence
        let file = try await store.client.uploadFile(workspace: workspace, filename: filename, contentType: contentType, data: data)
        guard isLive(token), self.target == target else { throw CancellationError() }
        attachments.append(file)
    }

    // MARK: Task actions

    func acceptReview() async {
        guard let store, let target, let detail = conversation, detail.canAcceptReview,
              let version = detail.reviewVersion else { return }
        let token = fence
        do {
            let updated = try await store.client.acceptTask(target: target, reviewVersion: version)
            guard isLive(token) else { return }
            try reconcile(updated)
            await store.refreshTaskList()
        } catch {
            present(error, token)
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
        } catch { present(error, token) }
    }

    /// Reads the catalog once per pane; a failed read leaves it empty so the next open retries.
    func loadLabelCatalog() async {
        guard let store, labelCatalog == nil, isTask else { return }
        let token = fence
        do {
            let catalog = try await store.client.taskLabels(groupID: workspace.groupID)
            guard isLive(token) else { return }
            labelCatalog = catalog.labels
        } catch { present(error, token) }
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
        } catch { present(error, token) }
    }

    /// Takes a Task the store changed on the server (a rename, a restore) without another read.
    func adopt(_ detail: Conversation) {
        guard !closed, detail.id == conversation?.id else { return }
        do { try reconcile(detail) } catch { self.error = error.localizedDescription }
    }

    /// The catalog after a label change elsewhere (Settings or a proposal decision).
    func installLabelCatalog(_ labels: [TaskLabel]) {
        guard !closed else { return }
        labelCatalog = labels
    }

    // MARK: History

    func loadEarlierMessages() async {
        guard let store, let target, let before = oldestSequence, hasOlderMessages, !loadingMore else { return }
        let token = fence
        loadingMore = true
        defer { if isLive(token) { loadingMore = false } }
        do {
            let page = try await store.client.messageHistory(target: target, before: before)
            guard isLive(token) else { return }
            try channel?.prependHistory(page)
            oldestSequence = page.covered?.first ?? oldestSequence
            hasOlderMessages = page.hasOlder
        } catch { present(error, token) }
    }

    private func prepareHistory(_ token: Fence) async throws {
        guard let store, let target else { return }
        let page = try await store.client.messageHistory(target: target, limit: 24)
        guard isLive(token) else { return }
        try channel?.prependHistory(page)
        oldestSequence = page.covered?.first
        hasOlderMessages = page.hasOlder
    }

    // MARK: State

    private func install(_ detail: Conversation) throws {
        conversation = detail
        guard let target else { return }
        var state = ConversationState(target: target)
        try state.reconcile(conversation: detail)
        channel = state
        draftText = store?.draft(for: target) ?? ""
        error = nil
        reconcilePending(detail)
    }

    private func reconcile(_ detail: Conversation) throws {
        conversation = detail
        try channel?.reconcile(conversation: detail)
        reconcilePending(detail)
        if detail.isTask { store?.taskUpdated(detail) }
    }

    private func reconcilePending(_ detail: Conversation) {
        let accepted = Set(detail.messages.compactMap(\.clientRequestID))
        pendingSends.removeAll { $0.target.conversationID == detail.id && accepted.contains($0.id) }
    }

    // MARK: Streams

    /// Home listens to its conversation events. A Task listens to the group feed filtered to it, which
    /// also carries task-list invalidations while the Task is open.
    func startStream() {
        stopStream()
        guard let store, let target, let conversation, store.session != nil, !closed else { return }
        let token = fence
        let isTask = conversation.isTask
        stream = Task { [weak self] in
            var retry = 0
            while !Task.isCancelled {
                guard let self, self.isLive(token), store.session != nil else { return }
                let incarnation = self.channel?.beginStream() ?? 0
                do {
                    let events = isTask
                        ? await store.client.taskEvents(workspace: self.workspace, conversationID: target.conversationID)
                        : await store.client.conversationEvents(target: target)
                    defer { events.cancel() }
                    for try await event in events {
                        guard self.isLive(token), !Task.isCancelled else { return }
                        self.connected = true
                        retry = 0
                        if isTask {
                            if event.type == "task_participant_statuses" {
                                try self.channel?.apply(event: event, incarnation: incarnation)
                            }
                            if ["conversation_list_invalidated", "conversation_list_resync_required"].contains(event.type) {
                                self.scheduleRefresh()
                                store.scheduleTaskListRefresh()
                            }
                        } else if try self.channel?.apply(event: event, incarnation: incarnation) == true {
                            self.scheduleRefresh()
                            break
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    guard self.isLive(token), !Task.isCancelled else { return }
                    self.connected = false
                    self.present(error, token)
                    retry = min(retry + 1, 4)
                    try? await Task.sleep(for: .seconds(min(15, 1 << retry)))
                }
            }
        }
    }

    func stopStream() {
        stream?.cancel(); stream = nil
        refreshTask?.cancel(); refreshTask = nil
        connected = false
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        let token = fence
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.isLive(token) else { return }
            await self.refresh()
            if self.isLive(token) { self.refreshTask = nil }
        }
    }

    private func isLive(_ token: Fence) -> Bool {
        !closed && epoch == token.epoch && (store?.isCurrent(token.boundary) ?? false)
    }

    private func present(_ failure: any Error, _ token: Fence) {
        guard isLive(token), !(failure is CancellationError) else { return }
        error = failure.localizedDescription
        store?.checkSessionAfter(failure)
    }
}
