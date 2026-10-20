import CommaCore
import Foundation
import Observation

/**
 * One open conversation as the client core shows it to this app: its `chatView` topic and the `chatView.*` calls, the
 * same ones the desktop's windows and the Android app use. The core keeps the conversation (the event stream, history
 * and its gaps, the streaming reply, what is being sent, the draft and its files); the pane shows the topic while the
 * conversation is on screen and passes on what the member does. The router chat and an open Task each own a pane, so
 * opening or closing a Task never reloads the router.
 */
@MainActor @Observable
final class ConversationPane {
    enum Kind: Equatable { case router, task(String) }

    /// The window this app is to the core: it has one.
    static let surface = "ios"
    static let maxAttachments = 8

    let kind: Kind
    let workspace: Workspace
    let conversationID: String
    /// What the core shows of the conversation, read off its `chatView` topic.
    private(set) var state = ChatViewState()
    /// The server's conversation as the core holds it (title, status, review version, labels).
    private(set) var conversation: Conversation?
    /// A Task's summary as the core keeps it (`taskSummaries`): its facts and the section its status folds into.
    private(set) var summary: TaskSummary?
    private(set) var error: String?
    /// What `error` reports, which decides what retrying it means.
    private(set) var errorOrigin: ErrorOrigin?
    /// Advances with every failure reported, so the same failure again still reaches the toast.
    private(set) var errorRevision = 0
    /// The Group's label catalog, read when the Task details first open.
    var labelCatalog: [TaskLabel]?
    var labelsBusy = false
    var draftText = "" {
        didSet { if draftText != oldValue { scheduleDraftSave() } }
    }
    /// Text a pre-task just placed at the end of the draft, until the composer reveals it (`fillDraft`).
    var draftFill: DraftFill?
    /// Routine items staged for the next message, each a tile above the text, sent as attached texts.
    private(set) var draftTexts: [DraftText] = []
    /// Tasks picked from the @ menu, shown as @Title; sent and saved as `[Title](comma:task/<id>)`.
    @ObservationIgnored var draftMentions: [TaskMention] = []
    /// Models picked from the router chat's @ menu, shown as @GPT 5.5; sent and saved as `[GPT 5.5](comma:model/<id>)`.
    @ObservationIgnored var draftModels: [ModelMention] = []
    /// Agent commands picked from the / menu, shown as /status; sent as `<salix-command>status</salix-command>`.
    @ObservationIgnored var draftCommands: [AgentCommand] = []
    /// The thread gathered above the composer for a reply, iMessage style; nil when no thread is open.
    var replyThread: ReplyThreadSelection?
    /// Sends this pane started that the core has not shown yet, by request id: their text for the send motion.
    private(set) var pendingSends: [PendingSend] = []
    /// Keeps a reply in one transcript row from thinking bubble to committed message.
    private(set) var replyRows = ReplyRowIdentity()
    /// The images each question card's other answer holds, by the question's message id, as the core uploads them.
    /// Kept apart from `state`, so a card redraws when its images change and not on every update of the conversation.
    private(set) var questionAttachments: [String: [ChatDraftAttachment]] = [:]
    /// The pictures of the images picked for question cards on this phone, by the core's attachment id.
    private(set) var questionThumbnails: [String: Data] = [:]

    @ObservationIgnored weak var store: CommaStore?
    @ObservationIgnored private(set) var closed = false
    @ObservationIgnored private var showing: Task<Void, Never>?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var draftRestored = false
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    /// A read problem was reported, and no read has succeeded since.
    @ObservationIgnored private var problemReported = false
    /// The files picked for the draft, by the core's attachment id: what their tiles show.
    @ObservationIgnored private var localFiles: [String: (file: AttachmentPayload, thumbnail: Data?)] = [:]
    @ObservationIgnored private var labelWatch: Task<Void, Never>?
    @ObservationIgnored private var summaryWatch: Task<Void, Never>?
    /// Callers waiting for a value at least as new as a call's receipt.
    @ObservationIgnored private var revisionWaiters: [(revision: Int, resume: CheckedContinuation<Void, Never>)] = []

    init(kind: Kind, workspace: Workspace, conversationID: String, store: CommaStore) {
        self.kind = kind
        self.workspace = workspace
        self.conversationID = conversationID
        self.store = store
        foreground = store.foreground
    }

    var isTask: Bool { if case .task = kind { true } else { false } }
    /// The core shows the conversation now: it follows its stream (only while the app is in the foreground).
    var isShown: Bool { showing != nil }
    var taskID: String? { if case .task(let id) = kind { id } else { nil } }
    var target: ConversationTarget? {
        ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: conversationID)
    }
    private var view: [String: Any] {
        ["workspace": workspace.id, "group": workspace.groupID, "conversation": conversationID, "surface": Self.surface]
    }

    // MARK: What the core shows

    /// The canonical messages, in order.
    var messages: [ChatItem] {
        state.timeline.compactMap { if case .message(_, let item) = $0 { item } else { nil } }
    }
    var assistantDraft: ChatDraft? {
        state.timeline.lazy.compactMap { if case .draft(_, let draft) = $0 { draft } else { nil } }.first
    }
    var streamingReply: Bool { assistantDraft != nil }
    var loading: Bool { !state.loaded && state.problem == nil }
    var hasOlderMessages: Bool { state.hasOlder }
    var loadingMore: Bool { state.loadingOlder }
    var boundWorker: BoundWorker? {
        state.boundWorker.map { BoundWorker(participantID: $0.participantID, actorID: $0.actorID, name: $0.name) }
    }
    /// The maker of the model the Task runs, whose logo stands for its Worker.
    var workerVendor: String? { state.workerVendor }
    var canSend: Bool { store?.session != nil && !closed }

    /// What the reply bubble says while a reply is coming: this device's own send waiting, then the agent working.
    var replyActivity: String? {
        guard !streamingReply, state.reply.pending else { return nil }
        if state.reply.thinking { return String(localized: "Thinking…") }
        if state.reply.working {
            if let summary = state.activity?.summary, state.activity?.summaryClass == "public" { return summary }
            let answered = messages.last.map { !$0.isUser } ?? false
            return answered ? String(localized: "Working…") : String(localized: "Thinking…")
        }
        return state.reply.coming ? String(localized: "Thinking…") : nil
    }

    /// Thinking about or streaming a reply: the Comma mark plays its animation instead of standing still.
    var isReplying: Bool { replyActivity != nil || streamingReply }

    // MARK: Lifecycle

    /// Shows the conversation to the core: it opens its stream and history, and keeps them while the pane is shown.
    func open() {
        closed = false
        show()
        followSummary()
    }

    /// A Task's summary, from the list in focus or the core's summary cache.
    private func followSummary() {
        guard let store, isTask, summaryWatch == nil else { return }
        let id = conversationID
        let updates = store.core.subscribe(["topic": "taskSummaries", "group": workspace.groupID, "ids": id]) { value in
            (value as? NSDictionary)?.objects("summaries").lazy.compactMap(TaskSummary.init(summary:)).first { $0.id == id }
        }
        summaryWatch = Task { [weak self] in
            for await value in updates {
                guard let self, !self.closed else { return }
                if case .value(let next?) = value, next != self.summary { self.summary = next }
            }
        }
    }

    /// Retires the pane: the core lets the conversation go, and late values reach nothing.
    func close() {
        flushDraft()
        closed = true
        let waiting = revisionWaiters
        revisionWaiters = []
        for waiter in waiting { waiter.resume.resume() }
        showing?.cancel(); showing = nil
        labelWatch?.cancel(); labelWatch = nil
        summaryWatch?.cancel(); summaryWatch = nil
        replyRows = ReplyRowIdentity()
    }

    /// The core keeps the event stream only while the conversation is visible; coming back resumes it and fills any gap.
    func setForeground(_ visible: Bool) {
        foreground = visible
        show()
    }

    private func show() {
        guard !closed, foreground, let store else {
            showing?.cancel(); showing = nil
            return
        }
        guard showing == nil else { return }
        let reader = ChatViewReader()
        let boundary = store.boundaryToken
        var topic = view
        topic["topic"] = "chatView"
        let updates = store.core.subscribe(topic, read: reader.read)
        showing = Task { [weak self] in
            for await value in updates {
                guard let self, !self.closed, self.store?.isCurrent(boundary) == true else { return }
                switch value {
                case .value(let next): self.install(next)
                case .failed(let failure): self.present(failure, as: .server)
                }
            }
        }
    }

    private func install(_ next: ChatViewState) {
        if let shown = assistantDraft, !next.timeline.contains(where: { if case .draft(_, let draft) = $0 { draft == shown } else { false } }) {
            var rows = replyRows
            rows.handOff(shown, from: messages, to: next.timeline.compactMap { if case .message(_, let item) = $0 { item } else { nil } })
            if rows != replyRows { replyRows = rows }
        }
        let decoded = next.conversation?.value as AnyObject? === state.conversation?.value as AnyObject?
            ? conversation : next.conversation?.decode(Conversation.self)
        state = next
        if conversation != decoded { conversation = decoded }
        if questionAttachments != next.questionAttachments {
            questionAttachments = next.questionAttachments
            let kept = Set(next.questionAttachments.values.joined().map(\.id))
            if questionThumbnails.keys.contains(where: { !kept.contains($0) }) {
                questionThumbnails = questionThumbnails.filter { kept.contains($0.key) }
            }
        }
        let ready = revisionWaiters.filter { $0.revision <= next.revision }
        revisionWaiters.removeAll { $0.revision <= next.revision }
        for waiter in ready { waiter.resume.resume() }
        let shown = Set(next.timeline.map(\.key))
        pendingSends.removeAll { shown.contains(ChatViewReader.requestKey($0.id)) || shown.contains("m:" + $0.id) }
        if !draftRestored, next.conversation != nil || next.loaded {
            draftRestored = true
            restoreDraft(next.draft)
        }
        if next.problem == nil {
            // A read that succeeded; the core reading again after a failure passes through no problem while it reads.
            if next.loaded { problemReported = false }
            if next.loaded, errorOrigin?.answeredByRead == true { dismissError() }
        } else if let problem = next.problem, !problemReported, errorOrigin == nil {
            // Once until a read succeeds: the core reading again brings the problem back, perhaps named otherwise, and
            // a dismissed toast stays dismissed.
            problemReported = true
            report(problem)
        }
    }

    private func report(_ problem: ChatProblem) {
        let message: String = switch problem {
        // The core names every failure that is not a refusal a network one, a server's 5xx too.
        case .network, .server: String(localized: "Comma could not load this conversation.")
        case .unauthorized: String(localized: "Your session ended. Sign in again.")
        case .forbidden: String(localized: "You can’t open this conversation.")
        case .notFound: String(localized: "This conversation is no longer available.")
        }
        error = message
        errorOrigin = .server
        errorRevision += 1
    }

    /// Reads the conversation again now, as a pull to refresh or Try Again asks.
    func refresh() {
        Task { _ = try? await call("refresh") }
    }

    /// Reads again after a failed read.
    func retryRead() async {
        dismissError()
        _ = try? await call("refresh")
    }

    func dismissError() { error = nil; errorOrigin = nil }
    func showError(_ value: String) { error = value; errorOrigin = .local; errorRevision += 1 }

    func present(_ failure: any Error, as origin: ErrorOrigin = .request) {
        guard !closed, !(failure is CancellationError) else { return }
        if let error = failure as? CoreError, error.code == "cancelled" { return }
        error = failure.localizedDescription
        errorOrigin = origin
        errorRevision += 1
    }

    /// Loads the page before the oldest message shown.
    func loadEarlierMessages() async {
        guard hasOlderMessages, !loadingMore else { return }
        _ = try? await call("older")
    }

    /// One of the core's calls for this conversation.
    @discardableResult
    func call(_ name: String, _ params: [String: Any] = [:]) async throws -> CoreJSON {
        guard let store, !closed else { throw CancellationError() }
        var all = view
        for (key, value) in params { all[key] = value }
        return try await store.core.call("chatView." + name, all)
    }

    // MARK: Draft

    /// Keeps the draft, picks included, in the core (which keeps it on the device) a moment after the last edit.
    private func scheduleDraftSave() {
        guard draftRestored, !closed else { return }
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.flushDraft()
        }
    }

    private func flushDraft() {
        guard draftRestored, let store, !closed else { return }
        draftSave?.cancel(); draftSave = nil
        var params = view
        params["draft"] = outgoingDraft
        Task { _ = try? await store.core.call("chatView.setDraft", params) }
    }

    /// Installs the draft the core kept once the conversation shows. Text typed meanwhile joins it.
    private func restoreDraft(_ saved: String) {
        let typed = draftText, typedMentions = draftMentions, typedModels = draftModels, typedCommands = draftCommands
        let projected = Self.project(saved)
        draftText = Self.fieldText(projected.text)
        draftMentions = projected.mentions
        draftModels = projected.models
        draftCommands = projected.commands
        if !typed.isEmpty, typed != draftText {
            appendDraft(typed)
            draftMentions += typedMentions
            draftModels += typedModels
            draftCommands += typedCommands
        }
        if let store, Self.namesSkill(draftText) { Task { await store.skills.loadIfStale(store: store) } }
    }

    /// Adds text to the draft after a blank line, like the desktop's appendRecommendationPrompt.
    func appendDraft(_ text: String) {
        draftText = Self.fieldText(draftText.isEmpty ? text : draftText + "\n\n" + text)
    }

    /// Appends a pre-task's prompt as `appendDraft` does and notes it, so the composer reveals it with the fill motion.
    func fillDraft(_ text: String) {
        appendDraft(text)
        draftFill = text.isEmpty ? nil : DraftFill(inserted: text)
    }

    /// Stages a Routine item for the next message, as the desktop stages its tile; the same text is staged once.
    func attachText(_ attached: ChatAttachedText) {
        guard !draftTexts.contains(where: { $0.attached.text == attached.text }) else { return }
        draftTexts.append(DraftText(attached: attached))
    }

    func removeDraftText(_ id: String) {
        draftTexts.removeAll { $0.id == id }
    }

    /// Moves a staged item's text into the field after the draft, as the desktop's "Show in text field" does.
    func showDraftTextInField(_ id: String) {
        guard let staged = draftTexts.first(where: { $0.id == id }) else { return }
        removeDraftText(id)
        fillDraft(staged.attached.text)
    }

    /// `text` as UIKit hands the composer's field its text: NSString-backed, its indices counted in UTF-16.
    static func fieldText(_ text: String) -> String { NSString(string: text) as String }

    /// Whether `text` holds a token the desktop skill pattern could read: `/` at the start or after whitespace, then an
    /// ASCII letter or digit.
    static func namesSkill(_ text: String) -> Bool {
        var afterWhitespace = true, slash = false
        for character in text {
            if slash, character.isASCII, character.isLetter || character.isNumber { return true }
            slash = character == "/" && afterWhitespace
            afterWhitespace = character.isWhitespace
        }
        return false
    }

    // MARK: Sending

    /// Takes the draft as a send without waiting for the core, so the view can start the send motion for this exact
    /// send before `deliver(_:)`. Picked Tasks go as their links, picked agent commands as their control text, and each
    /// catalog skill the text names is tagged, as on the desktop.
    func enqueueSend() -> PendingSend? {
        let text = outgoingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !attachmentsBlockSend, !text.isEmpty || !drafts.isEmpty || !draftTexts.isEmpty else { return nil }
        let skills = Skill.mentionedLocations(in: text, catalog: store?.skills.catalog ?? [])
        let attempt = PendingSend(text: text, files: drafts.map(\.file.filename), skills: skills, attachedTexts: draftTexts,
                                  replyToMessageID: replyTargetID)
        pendingSends.append(attempt)
        draftTexts = []
        // The first reply answers the chosen message; later ones answer the thread's newest message.
        if replyThread?.targetID != nil { replyThread?.targetID = nil }
        draftSave?.cancel(); draftSave = nil
        draftRestored = false
        draftText = ""
        draftMentions = []
        draftModels = []
        draftCommands = []
        draftRestored = true
        return attempt
    }

    /// Sends `attempt` with the draft's files: the core shows it as being sent, then sent.
    func deliver(_ attempt: PendingSend) async {
        var params: [String: Any] = ["text": attempt.text, "clientRequestId": attempt.id]
        if let reply = attempt.replyToMessageID { params["replyToMessageId"] = reply }
        if !attempt.skills.isEmpty { params["skills"] = attempt.skills.map { ["location": $0] } }
        if !attempt.attachedTexts.isEmpty {
            params["attachedTexts"] = attempt.attachedTexts.map { staged -> [String: Any] in
                var text: [String: Any] = ["text": staged.attached.text]
                if let source = staged.attached.source { text["source"] = source }
                return text
            }
        }
        do {
            try await call("send", params)
        } catch {
            pendingSends.removeAll { $0.id == attempt.id }
            // A refused send's staged items come back to the composer.
            let staged = Set(draftTexts.map(\.id))
            draftTexts.insert(contentsOf: attempt.attachedTexts.filter { !staged.contains($0.id) }, at: 0)
            present(error, as: .send(attempt.id))
        }
    }

    func retry(_ clientRequestID: String) async {
        if errorOrigin == .send(clientRequestID) { dismissError() }
        do { try await call("retry", ["clientRequestId": clientRequestID]) } catch { present(error, as: .send(clientRequestID)) }
    }

    func discard(_ clientRequestID: String) async {
        _ = try? await call("discard", ["clientRequestId": clientRequestID])
    }

    // MARK: Attachments

    /// The draft's files, as the core uploads them, each with what this phone picked for its tile.
    var drafts: [DraftAttachment] {
        state.attachments.map { item in
            let local = localFiles[item.id]
            let file = local?.file ?? AttachmentPayload(filename: item.name, contentType: "application/octet-stream", data: Data())
            let state: DraftAttachment.State = switch item.status {
            case .uploading: .uploading
            case .uploaded: .ready
            case .failed: .failed(item.error ?? String(localized: "The file could not be uploaded."))
            }
            return DraftAttachment(id: item.id, file: file, thumbnail: local?.thumbnail, state: state)
        }
    }

    /// An upload is still on its way, or failed and waits to be retried or removed; the message waits for it.
    var attachmentsBlockSend: Bool { state.attachments.contains { $0.status != .uploaded } }
    var attachmentRoom: Int { attachmentRoom(nil) }

    /// Adds `file` to the draft at once, or with `questionMessageID` to that question card's other answer (apart from
    /// the draft); the core uploads it. The task ends once the core shows its row.
    @discardableResult
    func attach(_ file: AttachmentPayload, thumbnail: Data?, questionMessageID: String? = nil) -> Task<Void, Never> {
        guard attachmentRoom(questionMessageID) > 0 else {
            showError(String(localized: "You can attach up to eight files to a message."))
            return Task {}
        }
        let before = Set(attachments(questionMessageID).map(\.id))
        return Task {
            do {
                var params: [String: Any] = ["files": [["name": file.filename, "size": file.data.count,
                                                        "bytes": CoreBytes.json(file.data)]]]
                if let questionMessageID { params["questionMessageId"] = questionMessageID }
                let receipt = try await call("attach", params)
                // The value with the receipt's revision has the new row.
                await reach(receipt.object?.int("revision") ?? 0)
                // Its row: a new one of its name and size not yet given its file (photos picked together attach at once).
                let row = attachments(questionMessageID).first { row in
                    !before.contains(row.id) && localFiles[row.id] == nil && questionThumbnails[row.id] == nil
                        && row.name == file.filename && row.size == file.data.count
                }
                guard let id = row?.id else { return }
                if questionMessageID == nil { localFiles[id] = (file, thumbnail) } else if let thumbnail { questionThumbnails[id] = thumbnail }
            } catch {
                present(error, as: .local)
            }
        }
    }

    /// Uploads a failed file of the draft, or of question card `questionMessageID`, again.
    func retryAttachment(_ id: String, questionMessageID: String? = nil) {
        var params: [String: Any] = ["attachmentId": id]
        if let questionMessageID { params["questionMessageId"] = questionMessageID }
        Task { _ = try? await call("retryAttachment", params) }
    }

    /// Removes a file from the draft, or from question card `questionMessageID`.
    func removeAttachment(_ id: String, questionMessageID: String? = nil) {
        localFiles[id] = nil
        questionThumbnails[id] = nil
        var params: [String: Any] = ["attachmentId": id]
        if let questionMessageID { params["questionMessageId"] = questionMessageID }
        Task { _ = try? await call("removeAttachment", params) }
    }

    // MARK: Question cards

    /// Answers the question card `questionMessageID` asks with the choices picked, the other answer (its text and the
    /// card's images) or a skip. The core words the answer and sends it as one message; the card shows it as being
    /// sent at once, and again as open with the answer kept when it fails.
    func answerQuestion(_ questionMessageID: String, choiceIDs: [String], other: String? = nil, skipped: Bool = false) {
        guard canSend else { return }
        var params: [String: Any] = ["questionMessageId": questionMessageID, "choiceIds": choiceIDs]
        if let other { params["other"] = other }
        if skipped { params["skipped"] = true }
        Task {
            do { try await call("answerQuestion", params) } catch { present(error, as: .request) }
        }
    }

    /// How many more files the draft, or question card `questionMessageID`'s other answer, takes.
    func attachmentRoom(_ questionMessageID: String?) -> Int {
        max(0, Self.maxAttachments - attachments(questionMessageID).count)
    }

    /// The draft's files, or question card `questionMessageID`'s, as the core uploads them.
    private func attachments(_ questionMessageID: String?) -> [ChatDraftAttachment] {
        guard let questionMessageID else { return state.attachments }
        return questionAttachments[questionMessageID] ?? []
    }

    /// Returns once the core shows a value at least as new as `revision` (or the pane closed).
    private func reach(_ revision: Int) async {
        guard state.revision < revision, !closed else { return }
        await withCheckedContinuation { revisionWaiters.append((revision, $0)) }
    }

    // MARK: Replying

    /// The committed message the next send answers.
    var replyTargetID: String? {
        guard let replyThread else { return nil }
        if let target = replyThread.targetID { return target }
        return messages.last { ($0.threadRootMessageID ?? $0.id) == replyThread.rootID }?.id ?? replyThread.rootID
    }

    func openReplyThread(on message: ChatItem) {
        guard !closed else { return }
        replyThread = ReplyThreadSelection(rootID: message.threadRootMessageID ?? message.id, targetID: message.id)
    }

    func closeReplyThread() { replyThread = nil }

    // MARK: Task actions

    /// Ends the Task by hand as Done or Cancelled, against the version the member saw.
    func setStatus(_ status: ManualTaskStatus) async {
        guard let detail = conversation, detail.canSetStatus, let version = detail.archiveVersion else { return }
        do { try await call("setTaskStatus", ["status": status.rawValue, "expectedUpdatedAt": version]) }
        catch { present(error) }
    }

    /// Accepts the Task's review: it is done.
    func acceptReview() async {
        guard let detail = conversation, detail.canAcceptReview, let version = detail.reviewVersion else { return }
        do { try await call("acceptTaskReview", ["reviewVersion": version]) } catch { present(error) }
    }

    /// Stops the Task its Worker runs.
    func cancelTask() async {
        guard let store, isTask else { return }
        do { _ = try await store.core.call("tasks.cancel", ["group": workspace.groupID, "conversation": conversationID]) }
        catch { present(error) }
    }

    /// Follows the Group's label catalog (the core's `taskLabels`), once the Task details first open.
    func loadLabelCatalog() async {
        guard let store, labelWatch == nil, isTask else { return }
        let updates = store.core.subscribe(["topic": "taskLabels", "group": workspace.groupID]) { value -> [TaskLabel]? in
            CoreJSON(value: (value as? NSDictionary)?.object("catalog")).decode(TaskLabelCatalog.self)?.labels
        }
        labelWatch = Task { [weak self] in
            for await value in updates {
                guard let self, !self.closed else { return }
                if case .value(let labels?) = value { self.labelCatalog = labels }
            }
        }
    }

    /// Replaces the Task's labels. Ids deleted from the catalog are dropped first: the server refuses any write that
    /// names one.
    func setLabels(_ ids: [String]) async {
        guard let store, isTask, !labelsBusy else { return }
        let known = Set(labelCatalog?.map(\.id) ?? [])
        labelsBusy = true
        defer { labelsBusy = false }
        do {
            _ = try await store.core.call("taskLabels.assign", ["group": workspace.groupID, "conversation": conversationID,
                                                                "labels": ids.filter(known.contains)])
        } catch { present(error) }
    }
}

extension ConversationPane {
    /// Where an error came from. Only a failed read is worth repeating as it was: a failed send is retried from its own
    /// row, a refused change is made again, and a file that could not be attached is chosen again.
    enum ErrorOrigin: Equatable {
        /// A read of the conversation.
        case server
        /// A change the member asked for that the server refused.
        case request
        /// The send, by request id, that could not be delivered.
        case send(String)
        /// Work on this device: a file too large, a photo that would not load.
        case local

        /// A later read of the conversation that works clears it.
        var answeredByRead: Bool {
            switch self {
            case .server, .send: true
            case .request, .local: false
            }
        }
    }
}

/// A send this pane started, until the core shows it (then its row is the core's).
struct PendingSend: Identifiable, Equatable {
    let id = UUID().uuidString.lowercased()
    let text: String
    /// The names of the draft's files it carries.
    let files: [String]
    /// Locations of the catalog skills the text names, sent as the desktop `skills` field.
    let skills: [String]
    /// The Routine items staged with it.
    let attachedTexts: [DraftText]
    /// The message this send answers.
    let replyToMessageID: String?
}

/// The thread a member chose to reply in. `targetID` is the message they picked; once their first reply is sent it
/// clears, and later replies answer the thread's newest message.
struct ReplyThreadSelection: Equatable {
    let rootID: String
    var targetID: String?
}

/// One file of the draft: what was picked, its tile, and how its upload goes.
struct DraftAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case failed(String)
        case ready
    }

    let id: String
    let file: AttachmentPayload
    /// A small JPEG for a photo's tile.
    let thumbnail: Data?
    var state: State = .uploading

    var isImage: Bool { file.contentType.hasPrefix("image/") }
}

/// What is attached: the file's name, type and contents.
struct AttachmentPayload: Equatable, Sendable {
    let filename: String
    let contentType: String
    let data: Data
}

/// Text another surface placed at the end of the draft, which the composer reveals once.
/// A Routine item staged for the next message.
struct DraftText: Identifiable, Equatable {
    let id = UUID().uuidString
    let attached: ChatAttachedText
}

struct DraftFill: Equatable {
    let id = UUID()
    let inserted: String
    let at = ContinuousClock.now

    /// Whether `draft` still ends with the filled text, and the fill is recent enough to reveal.
    func applies(to draft: String, now: ContinuousClock.Instant = .now) -> Bool {
        draft.hasSuffix(inserted) && now - at < .seconds(4)
    }
}
