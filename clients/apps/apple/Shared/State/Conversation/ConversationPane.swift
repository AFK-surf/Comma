import Foundation
import Observation
import CommaCore

/// One open conversation: its transcript, event stream, sends and history.
/// The router chat and an open Task each own a pane, so opening or closing a Task never reloads the router.
@MainActor @Observable
final class ConversationPane {
    enum Kind: Equatable { case router, task(String) }

    let kind: Kind
    let workspace: Workspace
    private(set) var conversation: Conversation?
    /// The authoritative transcript state. Views never read it: `publish` copies out each value that changed,
    /// so a stream event that changes nothing (a reconnect, a stale or ignored frame) reaches no view.
    @ObservationIgnored private(set) var channel: ConversationState?
    private(set) var messages: [Message] = []
    /// Streamed reply text reaches views at most every `draftInterval`; see `publishDraft`.
    private(set) var assistantDraft: AssistantDraft?
    /// Whether a draft is shown. Unlike `assistantDraft`, it changes once per reply, not once per token.
    private(set) var streamingReply = false
    private(set) var participantStatuses: [ParticipantStatus] = []
    private(set) var boundWorker: BoundWorker?
    /// Keeps a reply in one transcript row from thinking bubble to committed message.
    private(set) var replyRows = ReplyRowIdentity()
    private(set) var loading = false
    var sending = false
    private(set) var loadingMore = false
    private(set) var hasOlderMessages = false
    var connected = false
    private(set) var error: String?
    /// What `error` reports, which decides what retrying it means.
    private(set) var errorOrigin: ErrorOrigin?
    /// Advances with every failure reported, so the same failure again still reaches the toast.
    private(set) var errorRevision = 0
    /// The Group's label catalog, read when the Task details first open.
    var labelCatalog: [TaskLabel]?
    var labelsBusy = false
    /// This client's latest send awaiting its reply (desktop `locallyAwaitingReply`).
    var awaitingReply: String?
    var draftText = ""
    /// Text a pre-task just placed at the end of the draft, until the composer reveals it (`fillDraft`).
    var draftFill: DraftFill?
    /// Tasks picked from the @ menu, shown as @Title; sent and saved as `[Title](comma:task/<id>)`.
    @ObservationIgnored var draftMentions: [TaskMention] = []
    /// Agent commands picked from the / menu, shown as /status; sent and saved as `<salix-command>status</salix-command>`.
    @ObservationIgnored var draftCommands: [AgentCommand] = []
    var pendingSends: [PendingSend] = []
    /// The thread gathered above the composer for a reply, iMessage style; nil when no thread is open.
    var replyThread: ReplyThreadSelection?
    var drafts: [DraftAttachment] = []

    @ObservationIgnored weak var store: CommaStore?
    /// Advances when the pane closes, so late responses and streams cannot write into it.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private(set) var closed = false
    @ObservationIgnored var sendOperation = 0
    @ObservationIgnored var stream: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var oldestSequence: Int?
    /// The load read the conversation's history and started its stream, not only the conversation.
    @ObservationIgnored private var loadFinished = false
    @ObservationIgnored private var draftPublishedAt: ContinuousClock.Instant?
    @ObservationIgnored private var draftFlush: Task<Void, Never>?

    static let awaitingReplyTimeout: Duration = .seconds(150)
    /// About 15 updates a second while tokens stream: smooth to read, and a fraction of the server's frame rate.
    static let draftInterval: Duration = .milliseconds(66)

    init(kind: Kind, workspace: Workspace, store: CommaStore) {
        self.kind = kind
        self.workspace = workspace
        self.store = store
    }

    /// One operation's authority: this pane still open, and the store's session boundary unchanged.
    struct Fence { let epoch: Int; let boundary: Int }
    var fence: Fence { Fence(epoch: epoch, boundary: store?.boundaryToken ?? -1) }

    var isTask: Bool { if case .task = kind { true } else { false } }
    var taskID: String? { if case .task(let id) = kind { id } else { nil } }
    var target: ConversationTarget? {
        guard let conversation else { return nil }
        return ConversationTarget(workspaceID: workspace.id, groupID: conversation.groupID, conversationID: conversation.id)
    }
    var currentPendingSends: [PendingSend] { pendingSends.filter { $0.target == target } }
    var canSend: Bool { target != nil && store?.session != nil && !sending && !loading && !closed }

    // MARK: Lifecycle

    func load() async {
        guard let store, !closed else { return }
        let token = fence
        loading = true
        defer { if isLive(token) { loading = false } }
        do {
            let detail: Conversation
            switch kind {
            case .router:
                detail = try await store.client.openRouter(workspace: workspace)
            case .task(let id):
                let target = ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: id)
                detail = try await store.client.conversation(target: target)
            }
            guard isLive(token) else { return }
            try install(detail)
            try await finishLoad(token)
        } catch { present(error, token) }
    }

    /// The part of a load after the conversation is installed: its history, then its stream.
    private func finishLoad(_ token: Fence) async throws {
        try await prepareHistory(token)
        guard isLive(token) else { return }
        loadFinished = true
        startStream()
    }

    /// Retires the pane: its stream stops and late work cannot write into it.
    func close() {
        persistDraft()
        closed = true
        epoch += 1
        stopStream()
        draftFlush?.cancel(); draftFlush = nil
        replyRows = ReplyRowIdentity()
    }

    /// `updatingTaskList` is false when the caller has already scheduled the task-list refresh.
    func refresh(updatingTaskList: Bool = true) async {
        guard let store, let target, !closed else { return }
        let token = fence
        do {
            let detail = try await store.client.conversation(target: target)
            guard isLive(token) else { return }
            try reconcile(detail, updatingTaskList: updatingTaskList)
            // A read that works answers a read that failed, not a change the server refused or a file on this device.
            if errorOrigin?.answeredByRead == true { dismissError() }
        } catch { present(error, token) }
    }

    /// Reads again after a failed read: the whole conversation if it never loaded, the rest of a load that stopped
    /// after the conversation (its history and stream), else its latest state.
    func retryRead() async {
        // Cleared first, so a read that fails the same way reports again.
        dismissError()
        if conversation == nil { return await load() }
        guard loadFinished else {
            guard !closed else { return }
            let token = fence
            loading = true
            defer { if isLive(token) { loading = false } }
            do { try await finishLoad(token) } catch { present(error, token) }
            return
        }
        await refresh()
    }

    func dismissError() { error = nil; errorOrigin = nil }
    func showError(_ value: String) { error = value; errorOrigin = .local; errorRevision += 1 }

    // MARK: History

    func loadEarlierMessages() async {
        guard let store, let target, let before = oldestSequence, hasOlderMessages, !loadingMore else { return }
        let token = fence
        loadingMore = true
        defer { if isLive(token) { loadingMore = false } }
        do {
            let page = try await store.client.messageHistory(target: target, before: before)
            guard isLive(token) else { return }
            let shown = messages.count
            try updateChannel { try $0.prependHistory(page) }
            oldestSequence = page.covered?.first ?? oldestSequence
            hasOlderMessages = page.hasOlder
            // A page of only hidden system rows would leave the pull doing nothing; keep going a bounded way.
            try await fillHistory(token, until: shown + 1)
        } catch { present(error, token) }
    }

    /// Hidden rows (agent inputs, provider output and status events) count against a page's size but are never shown:
    /// a voice call, for one, writes many of them into the router chat. Reads older pages until `count` rows are
    /// visible, there is no older history, or `historyFillPages` more reads have been spent.
    private func fillHistory(_ token: Fence, until count: Int) async throws {
        guard let store, let target else { return }
        var pages = 0
        while messages.count < count, hasOlderMessages, let before = oldestSequence, pages < Self.historyFillPages {
            pages += 1
            let page = try await store.client.messageHistory(target: target, before: before)
            guard isLive(token) else { return }
            try updateChannel { try $0.prependHistory(page) }
            guard let first = page.covered?.first, first < before else { hasOlderMessages = false; return }
            oldestSequence = first
            hasOlderMessages = page.hasOlder
        }
    }

    /// Enough rows to fill the first screen; four 100-message reads at most, on top of the first page.
    private static let historyFillRows = 12
    private static let historyFillPages = 4

    private func prepareHistory(_ token: Fence) async throws {
        guard let store, let target else { return }
        let page = try await store.client.messageHistory(target: target, limit: 24)
        guard isLive(token) else { return }
        try updateChannel { try $0.prependHistory(page) }
        oldestSequence = page.covered?.first
        hasOlderMessages = page.hasOlder
        try await fillHistory(token, until: Self.historyFillRows)
    }

    // MARK: State

    private func install(_ detail: Conversation) throws {
        conversation = detail
        defer { publish() }
        guard let target else { return }
        var state = ConversationState(target: target)
        try state.reconcile(conversation: detail)
        channel = state
        restoreDraft(for: target)
        dismissError()
        reconcilePending(detail)
    }

    func reconcile(_ detail: Conversation, updatingTaskList: Bool = true) throws {
        conversation = detail
        try updateChannel { try $0.reconcile(conversation: detail) }
        reconcilePending(detail)
        if detail.isTask, updatingTaskList { store?.taskUpdated(detail) }
    }

    private func reconcilePending(_ detail: Conversation) {
        let accepted = Set(detail.messages.compactMap(\.clientRequestID))
        pendingSends.removeAll { $0.target.conversationID == detail.id && accepted.contains($0.id) }
    }

    /// Takes a Task the store changed on the server (a rename, a restore) without another read.
    func adopt(_ detail: Conversation) {
        guard !closed, detail.id == conversation?.id else { return }
        do { try reconcile(detail) } catch { showError(error.localizedDescription) }
    }

    func isLive(_ token: Fence) -> Bool {
        !closed && epoch == token.epoch && (store?.isCurrent(token.boundary) ?? false)
    }

    /// `send` is the pending send that failed, when it was a delivery.
    func present(_ failure: any Error, _ token: Fence, as origin: ErrorOrigin = .server) {
        guard isLive(token), !(failure is CancellationError) else { return }
        error = failure.localizedDescription
        errorOrigin = origin
        errorRevision += 1
        store?.checkSessionAfter(failure)
    }

    // MARK: Publishing

    /// Every change to `channel` goes through here, then `publish` runs. `coalescingDraft` marks a change that
    /// can only have grown the draft's text, which may wait for the next draft slot.
    @discardableResult
    func updateChannel<Result>(coalescingDraft: Bool = false,
                               _ change: (inout ConversationState) throws -> Result) rethrows -> Result? {
        defer { publish(coalescingDraft: coalescingDraft) }
        guard channel != nil else { return nil }
        return try change(&channel!)
    }

    /// Copies the state out to the observed properties, each written only when its value differs.
    private func publish(coalescingDraft: Bool = false) {
        let next = channel?.messages ?? conversation?.messages.filter(\.isVisible) ?? []
        if let shown = assistantDraft, channel?.draft?.id != shown.id {
            var rows = replyRows
            rows.handOff(shown, from: messages, to: next)
            if rows != replyRows { replyRows = rows }
        }
        if messages != next { messages = next }
        let statuses = channel?.participantStatuses ?? [], worker = channel?.boundWorker
        if participantStatuses != statuses { participantStatuses = statuses }
        if boundWorker != worker { boundWorker = worker }
        publishDraft(coalescing: coalescingDraft)
    }

    /// A token arriving within `draftInterval` of the last shown one waits; one trailing update then shows the
    /// newest text. Started, completed, cancelled and snapshots publish at once, so no final text is held back.
    private func publishDraft(coalescing: Bool) {
        let next = channel?.draft
        guard next != assistantDraft else { draftFlush?.cancel(); draftFlush = nil; return }
        let now = ContinuousClock.now
        if coalescing, assistantDraft != nil, next != nil, let last = draftPublishedAt, now - last < Self.draftInterval {
            guard draftFlush == nil else { return }
            let token = fence
            draftFlush = Task { [weak self] in
                try? await Task.sleep(until: last + Self.draftInterval, clock: .continuous)
                guard let self, !Task.isCancelled, self.isLive(token) else { return }
                self.draftFlush = nil
                self.publishDraft(coalescing: false)
            }
            return
        }
        draftFlush?.cancel(); draftFlush = nil
        draftPublishedAt = now
        assistantDraft = next
        if streamingReply != (next != nil) { streamingReply = next != nil }
    }
}
