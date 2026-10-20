import Foundation

// A conversation as the client core's `chatView` topic says it (the same topic the desktop's windows and the Android
// app read), read into Swift values. Immutable: what a view holds never changes under it.

enum ChatConnection: Sendable { case idle, connecting, live, reconnecting, paused }

enum ChatProblem: Sendable { case network, unauthorized, forbidden, notFound, server }

struct ChatViewState: Sendable {
    /// The server's conversation as the core holds it (its title, status, review version, labels).
    var conversation: CoreJSON?
    /// Canonical messages in seq order, then sends still under way, then at most one streaming reply.
    var timeline: [ChatEntry] = []
    var participant: ChatParticipant?
    /// The Worker bound to a Task, as its participant status says.
    var boundWorker: ChatBoundWorker?
    /// The maker of the model the Task runs (the core's `taskRun.vendor`), whose logo stands for its Worker.
    var workerVendor: String?
    var activity: ChatActivity?
    var connection: ChatConnection = .idle
    var problem: ChatProblem?
    /// What the device kept shows before the server answered; an empty conversation is known once it did.
    var loaded = false
    var hasOlder = false
    var loadingOlder = false
    var reply = ChatReplyState()
    /// The files the composer's draft holds, as the core uploads them.
    var attachments: [ChatDraftAttachment] = []
    /// The images added to each question card's other answer, by the question's message id, apart from the draft.
    var questionAttachments: [String: [ChatDraftAttachment]] = [:]
    /// The composer's draft text as the core keeps it, and the epoch a change of it was made in.
    var draft = ""
    var draftEpoch: Int?
    /// Orders this state against the receipt of a call: a receipt's revision is in every later state.
    var revision = 0
}

/// Where the conversation's next reply stands (the core's `reply`, which every client reads the same way).
struct ChatReplyState: Equatable, Sendable {
    /// A reply is on its way: a send not yet answered, a wait not timed out, or a reply streaming in.
    var coming = false
    /// This device's own send waits for its first answer.
    var thinking = false
    var streaming = false
    /// The agent works on this conversation.
    var working = false
    /// The agent stopped with an error.
    var failed = false
    var timedOut = false

    /// Something is on its way: the thinking bubble shows.
    var pending: Bool { (coming || working) && !failed }
}

/// One row of the timeline. `key` stays when a send becomes its canonical message.
enum ChatEntry: Sendable {
    case message(key: String, ChatItem)
    case pending(key: String, ChatPending)
    case draft(key: String, ChatDraft)
    /// Messages the server has that this device has not read yet, between two ranges of history.
    case gap(key: String)

    var key: String {
        switch self {
        case .message(let key, _), .pending(let key, _), .draft(let key, _), .gap(let key): key
        }
    }
}

/// A canonical message.
struct ChatItem: Sendable, Equatable {
    let id: String
    /// Its place in the conversation; 0 when the server gave none.
    let seq: Int
    let isUser: Bool
    /// `user`, `agent` or `system`.
    let actorType: String
    let actorID: String?
    /// The Router or a Worker, as the core says who wrote it.
    let actorRole: String?
    let createdBy: String?
    let clientRequestID: String?
    let replyToMessageID: String?
    let threadRootMessageID: String?
    let createdAt: Double?
    /// A person's own words (`display.body`), or the agent's text as plain words.
    let text: String
    /// A person's command, shown as `/command`.
    let command: String?
    let quotes: [String]
    /// Text the person attached as a block, such as a Routine item (`display.texts`).
    let attachedTexts: [ChatAttachedText]
    /// Workspace files the person's message names.
    let files: [ChatFile]
    let parts: [ChatPart]
    let attachments: [ChatAttachment]
    let refs: [ChatRef]
    /// The instructions a Task works from (its brief).
    let brief: Bool
    /// An agent's message as the core parsed it (`@comma/core/markdown`'s tree); nil for a person's.
    let markdown: CoreJSON?

    static func == (left: ChatItem, right: ChatItem) -> Bool {
        left.id == right.id && left.text == right.text && left.parts == right.parts && left.attachments == right.attachments &&
            left.attachedTexts == right.attachedTexts &&
            left.refs == right.refs && left.seq == right.seq && left.markdown?.value as AnyObject? === right.markdown?.value as AnyObject?
    }

    /// The question card the message asks, drawn under its bubbles.
    var question: ChatQuestion? {
        for part in parts { if case .question(let question) = part { return question } }
        return nil
    }
}

enum ChatPart: Sendable, Equatable {
    case markdown(String)
    /// An inline Task chip; `conversationID` is nil when it is unavailable.
    /// `section` is the core's `statusBucket`.
    case task(conversationID: String?, title: String?, section: String?, unavailable: Bool)
    /// Interactive content, shown as its summary.
    case interactive(summary: String?)
    /// An Agent's question card. Its Markdown tree leaves it out: the card follows the message's bubbles.
    case question(ChatQuestion)
    /// Shows nothing, as a person's answer to a question card does (their message's words are its bubble).
    case other
}

/// An Agent's question (the core's `question` part): two to six choices, perhaps more than one picked, perhaps an
/// answer in the person's own words, and where the card stands.
struct ChatQuestion: Sendable, Equatable {
    struct Choice: Sendable, Equatable, Identifiable {
        let id: String
        let label: String
        let description: String?
        let recommended: Bool
    }

    enum Status: String, Sendable {
        /// Waiting for an answer.
        case open
        /// This device's answer is on its way.
        case sending
        /// This device's answer was not sent; the card is open again with it.
        case failed
        /// Answered or skipped on the card, answered by a message in the chat, or replaced by a later question.
        case answered, skipped, replied, replaced

        /// The card takes an answer; otherwise it shows how it ended.
        var isOpen: Bool { self == .open || self == .failed }
    }

    struct State: Sendable, Equatable {
        var status: Status
        /// The picks and other text an answer on the card gave (kept when it failed).
        var choiceIDs: [String] = []
        var other: String?
        var error: String?

        init(status: Status, choiceIDs: [String] = [], other: String? = nil, error: String? = nil) {
            self.status = status; self.choiceIDs = choiceIDs; self.other = other; self.error = error
        }

        init(_ json: NSDictionary?) {
            self.init(status: json?.string("status").flatMap(Status.init(rawValue:)) ?? .open,
                      choiceIDs: json?.strings("choiceIds") ?? [], other: json?.text("other"), error: json?.string("error"))
        }
    }

    /// The message that asks; an answer replies to it.
    let messageID: String
    let prompt: String
    let choices: [Choice]
    let multiSelect: Bool
    let allowOther: Bool
    var state: State

    /// Nil for a part that is not a whole question.
    init?(_ part: NSDictionary) {
        guard let id = part.string("messageId"), let prompt = part.string("prompt") else { return nil }
        let choices = part.objects("choices").compactMap { choice -> Choice? in
            guard let id = choice.string("id"), let label = choice.string("label") else { return nil }
            return Choice(id: id, label: label, description: choice.string("description"), recommended: choice.bool("recommended"))
        }
        guard choices.count >= 2 else { return nil }
        messageID = id
        self.prompt = prompt
        self.choices = choices
        multiSelect = part.bool("multiSelect")
        allowOther = part.bool("allowOther")
        state = State(part.object("state"))
    }
}

struct ChatAttachment: Sendable, Equatable {
    /// `image` or `file`.
    let blockType: String
    /// The attachment's place in its message, as the attachment endpoint expects; nil when it cannot be served.
    let index: Int?
    let fileName: String?
    let title: String?
    let mimeType: String?
    let size: Int?
    let workspacePath: String?
    let width: Int?
    let height: Int?
    /// The blob a download reads, when the server can serve it.
    let blob: CoreJSON?
    let agentID: String?

    var name: String { fileName ?? title ?? workspacePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Attachment") }

    static func == (left: ChatAttachment, right: ChatAttachment) -> Bool {
        left.blockType == right.blockType && left.index == right.index && left.fileName == right.fileName &&
            left.title == right.title && left.size == right.size && left.workspacePath == right.workspacePath
    }
}

struct ChatRef: Sendable, Equatable {
    let conversationID: String
    let kind: String?
    let title: String?
    let status: String?
}

struct ChatFile: Sendable, Equatable {
    let name: String
    let path: String
}

/// Text sent with a message as one attachment, such as a Routine item, and the app it came from.
struct ChatAttachedText: Sendable, Equatable {
    /// The app's name, such as Linear.
    let source: String?
    let text: String

    /// The text's first line, as the desktop's pill shows it.
    var title: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .lazy.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
    }
}

struct ChatPending: Sendable, Equatable {
    let clientRequestID: String
    /// What the person wrote: their words, a command as `/command`, the passages they quote ahead.
    let text: String
    let attachedTexts: [ChatAttachedText]
    let files: [ChatFile]
    let replyToMessageID: String?
    let failed: Bool
    /// Why the send failed, in the app's language, when the core said.
    let error: String?
    /// The send failed for lack of funds: the way on is billing, not another try.
    let billing: Bool
}

struct ChatDraftAttachment: Sendable, Equatable, Identifiable {
    enum Status: Sendable { case uploading, uploaded, failed }
    let id: String
    let name: String
    let size: Int
    let status: Status
    /// Its place in the workspace once uploaded.
    let path: String?
    let error: String?
}

struct ChatDraft: Sendable, Equatable {
    let responseKey: String
    let sourceMessageIDs: [String]
    let draftID: String
    let text: String
    /// The text as the core parsed it so far.
    let markdown: CoreJSON?
    /// The server ended the draft; it stays until the canonical message replaces it.
    let ended: Bool

    static func == (left: ChatDraft, right: ChatDraft) -> Bool {
        left.responseKey == right.responseKey && left.sourceMessageIDs == right.sourceMessageIDs &&
            left.text == right.text && left.ended == right.ended
    }
}

struct ChatParticipant: Sendable, Equatable {
    let participantID: String
    /// `active`, `error` or `stopped`.
    let state: String
    /// Server-provided display text; never parsed for meaning.
    let status: String?
    let issue: String?
    let updatedAt: Double?
}

struct ChatBoundWorker: Sendable, Equatable {
    let participantID: String
    let actorID: String?
    let name: String
}

struct ChatActivity: Sendable, Equatable {
    let phase: String
    let status: String
    let summaryClass: String
    let summary: String?
    let toolName: String?
}

/**
 * Reads the core's `chatView` value into the chat's state, as `ChatViewReader` does on Android. It runs on the core
 * client's queue, one value at a time, and keeps what it read: a part of the value the topic did not change is the
 * same object as before, so a message is read again only when it changed. A streaming reply costs nothing but its own
 * text.
 */
final class ChatViewReader: @unchecked Sendable {
    private var read: [ObjectIdentifier: (NSDictionary, ChatItem?)] = [:]
    private var messagesRead: NSArray?
    private var rangesRead: NSArray?
    private var canonical: [ChatEntry] = []

    func read(_ value: Any?) -> ChatViewState {
        guard let view = value as? NSDictionary else { return ChatViewState() }
        let revision = view.int("revision") ?? 0
        guard let json = view.object("state") else { return ChatViewState(revision: revision) }
        let history = json.object("history")
        let rows = visible(json.array("serverMessages") ?? [], history?.array("ranges"))
        var keys = Set(rows.map(\.key))
        var timeline = rows
        let shown = pendingDisplays(json.array("messages"))
        for pending in json.objects("pending") {
            guard let item = self.pending(pending, shown) else { continue }
            let key = Self.requestKey(item.clientRequestID)
            if keys.insert(key).inserted { timeline.append(.pending(key: key, item)) }
        }
        if let draft = json.object("assistantDraft") {
            let reply = ChatDraft(responseKey: draft.text("responseKey") ?? "", sourceMessageIDs: draft.strings("sourceMessageIds"),
                                  draftID: draft.text("draftId") ?? "", text: draft.text("text") ?? "",
                                  markdown: draft.array("markdown").map { CoreJSON(value: $0) },
                                  ended: draft.string("status") == "completed")
            timeline.append(.draft(key: "d:" + reply.responseKey + ":" + reply.sourceMessageIDs.joined(separator: ","), reply))
        }
        let status = json.string("status")
        var state = ChatViewState()
        state.conversation = json.object("conversation").map { CoreJSON(value: $0) }
        state.timeline = timeline
        state.participant = json.object("participantStatus").map { said in
            ChatParticipant(participantID: said.text("participantId") ?? "", state: said.text("state") ?? "",
                            status: said.string("status"), issue: said.string("issue"), updatedAt: said.double("updatedAt"))
        }
        state.boundWorker = json.object("boundWorker").flatMap { worker in
            worker.string("participantId").map { ChatBoundWorker(participantID: $0, actorID: worker.string("actorId"), name: worker.text("name") ?? "") }
        }
        state.workerVendor = json.object("taskRun")?.string("vendor")
        state.activity = json.object("activity").map { activity in
            ChatActivity(phase: activity.text("phase") ?? "", status: activity.text("status") ?? "",
                         summaryClass: activity.text("summaryClass") ?? "none", summary: activity.string("summary"),
                         toolName: activity.string("toolName"))
        }
        state.connection = switch json.string("connection") {
        case "connecting": .connecting
        case "live": .live
        case "reconnecting": .reconnecting
        case "paused": .paused
        default: .idle
        }
        state.problem = switch json.string("errorKind") {
        case "network": .network
        case "unauthorized": .unauthorized
        case "forbidden": .forbidden
        case "not-found": .notFound
        default: status == "error" ? .server : nil
        }
        state.loaded = !rows.isEmpty || status == "ready" || status == "error"
        state.hasOlder = history?.bool("hasOlder") == true
        state.loadingOlder = history?.bool("loadingOlder") == true
        if let said = json.object("reply") {
            state.reply = ChatReplyState(coming: said.bool("coming"), thinking: said.bool("thinking"), streaming: said.bool("streaming"),
                                         working: said.bool("working"), failed: said.bool("failed"), timedOut: said.bool("timedOut"))
        }
        state.attachments = json.objects("draftAttachments").compactMap(Self.draftAttachment)
        for case let (id as String, items as NSArray) in json.object("questionAttachments") ?? [:] {
            let attachments = items.compactMap { ($0 as? NSDictionary).flatMap(Self.draftAttachment) }
            if !attachments.isEmpty { state.questionAttachments[id] = attachments }
        }
        state.draft = json.text("draft") ?? ""
        state.draftEpoch = view.int("draftEpoch")
        state.revision = revision
        return state
    }

    /// The timeline key of the turn a request opens, pending or confirmed.
    static func requestKey(_ clientRequestID: String) -> String { "r:" + clientRequestID }

    private static func draftAttachment(_ item: NSDictionary) -> ChatDraftAttachment? {
        guard let id = item.string("id") else { return nil }
        let status: ChatDraftAttachment.Status = switch item.string("status") {
        case "uploaded": .uploaded
        case "failed": .failed
        default: .uploading
        }
        return ChatDraftAttachment(id: id, name: item.text("name") ?? "", size: item.int("size") ?? 0, status: status,
                                   path: item.string("path"), error: item.string("error"))
    }

    /**
     * The messages in the order the core gives them (by seq). Between two ranges of the history read sits one gap,
     * keyed by the newer range's start, which the core keeps fixed until the ranges meet.
     */
    private func visible(_ messages: NSArray, _ ranges: NSArray?) -> [ChatEntry] {
        if messages === messagesRead && ranges === rangesRead { return canonical }
        messagesRead = messages
        rangesRead = ranges
        var next: [ObjectIdentifier: (NSDictionary, ChatItem?)] = [:]
        var gaps = (ranges ?? []).dropFirst().compactMap { (($0 as? NSArray)?.firstObject as? NSNumber)?.intValue }.sorted()
        var keys = Set<String>()
        var out: [ChatEntry] = []
        for case let json as NSDictionary in messages {
            let identity = ObjectIdentifier(json)
            let message: ChatItem?
            if let kept = read[identity], kept.0 === json { message = kept.1 } else { message = item(json) }
            next[identity] = (json, message)
            guard let message else { continue }
            // A gap sits before the first message of each range but the oldest.
            while message.seq > 0, let gap = gaps.first, message.seq >= gap {
                out.append(.gap(key: "gap:\(gap)"))
                gaps.removeFirst()
            }
            let preferred = message.clientRequestID.map(Self.requestKey)
            let key: String
            if let preferred, keys.insert(preferred).inserted { key = preferred } else {
                key = "m:" + message.id
                keys.insert(key)
            }
            out.append(.message(key: key, message))
        }
        read = next
        canonical = out
        return out
    }

    /// Nil for a message with nothing to show.
    private func item(_ json: NSDictionary) -> ChatItem? {
        guard let id = json.string("messageId") else { return nil }
        let user = json.string("role") == "user"
        let display = json.object("display")
        let parts: [ChatPart] = json.objects("parts").map { part in
            switch part.string("kind") {
            case "markdown": return .markdown(part.text("text") ?? "")
            case "inline-task":
                let task = part.object("task")
                let unavailable = task?.bool("unavailable") == true || task?.string("conversationId") == nil
                return .task(conversationID: unavailable ? nil : task?.string("conversationId"), title: task?.string("title"),
                             section: task?.string("statusBucket"), unavailable: unavailable)
            case "dynamic-ui": return .interactive(summary: part.string("summary"))
            case "question": return ChatQuestion(part).map { .question($0) } ?? .other
            // A person's answer to a question card: their message's words say it.
            default: return .other
            }
        }
        let attachments = json.objects("attachments").map { item in
            ChatAttachment(blockType: item.text("blockType") ?? "file", index: item.int("attachmentIndex"), fileName: item.string("fileName"),
                           title: item.string("title"), mimeType: item.string("mimeType"), size: item.int("size"),
                           workspacePath: item.string("workspacePath"), width: item.int("width"), height: item.int("height"),
                           blob: item.object("blobRef").map { CoreJSON(value: $0) }, agentID: item.string("agentId"))
        }
        let refs = json.objects("refs").compactMap { ref -> ChatRef? in
            ref.string("conversationId").map { ChatRef(conversationID: $0, kind: ref.string("kind"), title: ref.string("title"), status: ref.string("status")) }
        }
        let files = files(display)
        let attachedTexts = attachedTexts(display)
        let text = (display?.text("body") ?? json.text("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = json.array("markdown")
        if text.isEmpty && display?.string("command") == nil && attachments.isEmpty && refs.isEmpty && files.isEmpty &&
            attachedTexts.isEmpty &&
            (markdown?.count ?? 0) == 0 && parts.allSatisfy({ if case .markdown(let words) = $0 { words.isEmpty } else { false } }) {
            return nil
        }
        return ChatItem(id: id, seq: json.int("seq") ?? 0, isUser: user, actorType: json.string("actorType") ?? (user ? "user" : "agent"),
                        actorID: json.string("actorId"), actorRole: json.string("actorRole"), createdBy: json.string("createdBy"),
                        clientRequestID: json.string("clientRequestId"), replyToMessageID: json.string("replyToMessageId"),
                        threadRootMessageID: json.string("threadRootMessageId"), createdAt: json.double("createdAt"),
                        text: text, command: display?.string("command"), quotes: display?.strings("quotes") ?? [], attachedTexts: attachedTexts, files: files,
                        parts: parts, attachments: attachments, refs: refs, brief: json.bool("brief"),
                        markdown: markdown.map { CoreJSON(value: $0) })
    }

    private func files(_ display: NSDictionary?) -> [ChatFile] {
        display?.objects("files").compactMap { file in
            guard let name = file.string("name"), let path = file.string("path") else { return nil }
            return ChatFile(name: name, path: path)
        } ?? []
    }

    private func attachedTexts(_ display: NSDictionary?) -> [ChatAttachedText] {
        display?.objects("texts").compactMap { attached in
            attached.text("text").map { ChatAttachedText(source: attached.string("source"), text: $0) }
        } ?? []
    }

    /// The core's reading of each message still being sent, by its request id: they close the `messages` list.
    private func pendingDisplays(_ messages: NSArray?) -> [String: NSDictionary] {
        var out: [String: NSDictionary] = [:]
        guard let messages else { return out }
        for case let message as NSDictionary in messages.reversed() {
            guard message.string("source") == "pending" else { break }
            if let id = message.string("clientRequestId"), let display = message.object("display") { out[id] = display }
        }
        return out
    }

    private func pending(_ json: NSDictionary, _ shown: [String: NSDictionary]) -> ChatPending? {
        guard let id = json.string("clientRequestId") else { return nil }
        let display = shown[id]
        let words = display.map { $0.string("command").map { "/" + $0 } ?? ($0.text("body") ?? "") } ?? (json.text("text") ?? "")
        let quotes = display?.strings("quotes") ?? []
        let text = (quotes.map { quote in quote.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") }
            + [words.trimmingCharacters(in: .whitespacesAndNewlines)]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ChatPending(clientRequestID: id, text: text, attachedTexts: attachedTexts(display), files: files(display), replyToMessageID: json.string("replyToMessageId"),
                           failed: json.string("status") == "failed", error: json.string("error"),
                           billing: json.string("failureAction") == "billing")
    }
}
