import Foundation
import CommaCore

// MARK: - Row model

enum ChatActorRole: Equatable { case router, worker }

/// One transcript row. The id stays stable when a pending send becomes its committed message, and when a
/// streamed draft becomes its committed reply, so the bubble keeps its identity instead of replaying an entrance.
struct ChatRow: Identifiable, Equatable {
    enum Content: Equatable {
        case message(ChatItem)
        case pending(ChatPending)
        case draft(ChatDraft?)
    }
    let id: String
    let relationshipID: String
    let content: Content
    /// The words the bubble shows: a person's own (a command as `/command`, quoted passages ahead), an agent's as
    /// plain words (its bubbles draw its Markdown tree).
    let text: String
    /// Text a member's message attaches as a block, such as a Routine item, which shows as a chip rather than as its text.
    let attachedTexts: [ChatAttachedText]
    /// The names of the workspace files a member's message carries, which show as chips rather than as its text.
    let files: [String]
    let isUser: Bool
    let actorRole: ChatActorRole?
    let actorID: String?
    let createdBy: String?
    let threadRoot: String
    let createdAt: Double?
    var groupFirst = true
    var groupLast = true
    var bubbleTail = false
    var reply: ChatReply?
    /// Status shown while the draft row has no text yet.
    var activityLabel: String?

    init(id: String, relationshipID: String, content: Content, isUser: Bool, actorRole: ChatActorRole?,
         actorID: String? = nil, createdBy: String? = nil, threadRoot: String, createdAt: Double? = nil) {
        self.id = id; self.relationshipID = relationshipID; self.content = content
        switch content {
        case .message(let message) where isUser:
            text = Self.quoted(message.quotes, message.command.map { "/" + $0 } ?? message.text)
            attachedTexts = message.attachedTexts
            files = message.files.map(\.name)
        case .message(let message): text = message.text; attachedTexts = []; files = []
        case .pending(let pending): text = pending.text; attachedTexts = pending.attachedTexts; files = pending.files.map(\.name)
        case .draft(let draft): text = draft?.text ?? ""; attachedTexts = []; files = []
        }
        self.isUser = isUser; self.actorRole = actorRole; self.actorID = actorID; self.createdBy = createdBy
        self.threadRoot = threadRoot; self.createdAt = createdAt
    }

    var message: ChatItem? { if case .message(let value) = content { value } else { nil } }
    var isDraft: Bool { if case .draft = content { true } else { false } }
    /// The Markdown tree an agent's bubbles draw; nil for a person's message.
    var markdown: CoreJSON? {
        switch content {
        case .message(let message): message.markdown
        case .draft(let draft): draft?.markdown
        case .pending: nil
        }
    }

    func sameSender(_ other: ChatRow) -> Bool {
        isUser == other.isUser && actorRole == other.actorRole && actorID == other.actorID && createdBy == other.createdBy
    }

    /// A person's words with the passages they quote ahead, as Markdown quotes.
    private static func quoted(_ quotes: [String], _ words: String) -> String {
        let lines = quotes.map { quote in
            quote.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        }
        return (lines + [words]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

struct ChatReply: Equatable {
    enum Presentation: Equatable { case line, preview }
    /// Row whose avatar or first bubble starts the connector.
    let sourceAnchorID: String
    /// Row the connector reaches, or the thread root for a preview.
    let targetID: String
    let presentation: Presentation
    /// A preview's quote: the target's text on one line, at most 180 characters, a Task mention as `@Title` as its
    /// bubble shows it. Nil while the target is not loaded.
    var targetText: String?
}

/// Row ids that outlive one row's content. A reply's thinking bubble, its streamed draft and its committed
/// message share one row, so the bubble updates in place: no teardown and no second entrance.
struct ReplyRowIdentity: Equatable {
    /// The row of the reply in progress: its thinking bubble, then its draft.
    private(set) var live = "reply:0"
    /// Committed replies that took over a draft's row, by message id.
    private(set) var aliases: [String: String] = [:]
    private var handOffs = 0

    func rowID(for message: ChatItem) -> String { aliases[message.id] ?? message.clientRequestID ?? message.id }

    /// A draft left the transcript in the update from `earlier` to `next`. The new reply that answers the draft's
    /// sources takes over its row (or the only new reply, when none names them), and the next reply gets a new row.
    mutating func handOff(_ draft: ChatDraft, from earlier: [ChatItem], to next: [ChatItem]) {
        let known = Set(earlier.map(\.id)), sources = Set(draft.sourceMessageIDs)
        let fresh = next.filter { !$0.isUser && !known.contains($0.id) }
        let answer = fresh.first { message in
            [message.replyToMessageID, message.threadRootMessageID].contains { $0.map(sources.contains) == true }
        }
        guard let reply = answer ?? (fresh.count == 1 ? fresh.first : nil) else { return }
        aliases[reply.id] = live
        handOffs += 1
        live = "reply:\(handOffs)"
    }
}

enum ChatTranscriptModel {
    /// The rows of an open conversation, with its reply identity. Build them once per view update.
    @MainActor static func rows(for pane: ConversationPane) -> [ChatRow] {
        rows(timeline: pane.state.timeline, isTask: pane.isTask, activity: pane.replyActivity, identity: pane.replyRows)
    }

    /// Port of the desktop `messageRelationships`: one pass groups consecutive rows by sender and thread,
    /// then connects each non-user group to the last group of the same thread.
    static func rows(timeline: [ChatEntry], isTask: Bool, activity: String? = nil,
                     identity: ReplyRowIdentity = ReplyRowIdentity()) -> [ChatRow] {
        var rows: [ChatRow] = []
        var messages: [String: ChatItem] = [:]
        var lastUser: String?
        var hasDraft = false
        for entry in timeline {
            switch entry {
            case .message(_, let message):
                messages[message.id] = message
                let isUser = message.isUser
                if isUser { lastUser = message.createdBy }
                let role: ChatActorRole? = isUser ? nil
                    : message.actorRole == "router" ? .router : message.actorRole == "worker" ? .worker : (isTask ? .worker : .router)
                rows.append(ChatRow(id: identity.rowID(for: message), relationshipID: message.id, content: .message(message),
                                    isUser: isUser, actorRole: role, actorID: message.actorType == "agent" ? message.actorID : nil,
                                    createdBy: isUser ? message.createdBy : nil,
                                    threadRoot: message.threadRootMessageID ?? message.id, createdAt: message.createdAt))
            case .pending(_, let pending):
                // A reply joins its parent's thread before the server names the root.
                let root = pending.replyToMessageID.map { parent in
                    messages[parent].map { $0.threadRootMessageID ?? $0.id } ?? parent
                } ?? pending.clientRequestID
                rows.append(ChatRow(id: pending.clientRequestID, relationshipID: pending.clientRequestID, content: .pending(pending),
                                    isUser: true, actorRole: nil, createdBy: lastUser, threadRoot: root))
            case .draft(_, let draft):
                hasDraft = true
                let parent = draft.sourceMessageIDs.last
                let root = parent.flatMap { messages[$0] }.map { $0.threadRootMessageID ?? $0.id } ?? parent ?? draft.draftID
                rows.append(ChatRow(id: identity.live, relationshipID: "draft:" + draft.draftID, content: .draft(draft),
                                    isUser: false, actorRole: isTask ? .worker : .router, threadRoot: root))
            case .gap:
                continue
            }
        }
        var related = relate(rows)
        if hasDraft, let last = related.indices.last {
            related[last].activityLabel = String(localized: "Typing…")
        } else if let activity {
            // Status feedback is not a message: it joins no reply chain. It shares the draft row's
            // identity so the thinking bubble becomes the streamed reply in place.
            var row = ChatRow(id: identity.live, relationshipID: "activity", content: .draft(nil), isUser: false,
                              actorRole: isTask ? .worker : .router, threadRoot: "activity")
            row.bubbleTail = true
            row.activityLabel = activity
            related.append(row)
        }
        return related
    }

    /// One thread's rows, grouped among themselves as the open reply thread shows them. Gathered together they
    /// are visibly one thread, so they carry no connectors or previews.
    static func thread(_ rows: [ChatRow], root: String) -> [ChatRow] {
        relate(rows.filter { $0.threadRoot == root }).map { row in
            var row = row
            row.reply = nil
            return row
        }
    }

    private static func relate(_ input: [ChatRow]) -> [ChatRow] {
        var rows = input
        var groups: [[Int]] = []
        for index in rows.indices {
            if let group = groups.last, let previous = group.last,
               rows[previous].sameSender(rows[index]), rows[previous].threadRoot == rows[index].threadRoot {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        for group in groups {
            for (offset, index) in group.enumerated() {
                rows[index].groupFirst = offset == 0
                rows[index].groupLast = offset == group.count - 1
            }
        }
        for index in rows.indices {
            let next = index + 1 < rows.count ? rows[index + 1] : nil
            rows[index].bubbleTail = next == nil || next!.isUser != rows[index].isUser ||
                (rows[index].isUser && next!.createdBy != rows[index].createdBy)
        }
        let position = Dictionary(rows.enumerated().map { ($1.relationshipID, $0) }, uniquingKeysWith: { first, _ in first })
        var lastThreadAnchor: [String: Int] = [:]
        var occupiedThrough = -1
        /// Each member reply's hook, by the reply's last row: its group, what it answers, and the interval
        /// occupied before it, so an Agent answering it can take its place.
        var memberReplies: [Int: (group: Int, target: Int, occupied: Int)] = [:]
        for group in groups {
            let first = group[0], last = group[group.count - 1]
            let root = rows[first].threadRoot
            let previousAnchor = lastThreadAnchor[root]
            lastThreadAnchor[root] = last
            // A member's own message starts its thread unless it replies into one.
            if root == rows[first].relationshipID || (rows[first].isUser && previousAnchor == nil) { continue }
            var anchor = previousAnchor, occupied = occupiedThrough
            // An Agent answering a member's reply continues the line from the message that reply answered, and the
            // reply's own hook gives way to it.
            if !rows[first].isUser, let previousAnchor, let member = memberReplies[previousAnchor] {
                rows[member.group].reply = nil
                anchor = member.target
                occupied = member.occupied
            }
            // Extend a thread from its last group. Another thread's connector in the interval forces a preview.
            let lined = anchor.map { $0 >= occupied } ?? false
            // A member's reply has no preview slot: it connects only when the line is clear.
            if rows[first].isUser && !lined { continue }
            if rows[first].isUser, let anchor { memberReplies[last] = (first, anchor, occupiedThrough) }
            occupiedThrough = last
            if lined, let anchor {
                rows[first].reply = ChatReply(sourceAnchorID: rows[last].id, targetID: rows[anchor].id, presentation: .line)
            } else {
                let target = position[root].map { rows[$0] }
                rows[first].reply = ChatReply(sourceAnchorID: rows[last].id, targetID: target?.id ?? root, presentation: .preview,
                                              // A model mention quotes as the name its bubble reads.
                                              targetText: target.map { quote(ModelMention.project($0.text).text) })
            }
        }
        return rows
    }

    /// `text` on one line, each run of whitespace a single space, cut at `limit` characters. The rows are built
    /// on every update while a reply streams, so it reads only as far as the quote needs, however long the text.
    static func quote(_ text: String, limit: Int = 180) -> String {
        var quote = "", length = 0, gap = false
        for character in text {
            if character.isWhitespace { gap = length > 0; continue }
            if gap, length < limit { quote.append(" "); length += 1 }
            gap = false
            guard length < limit else { break }
            quote.append(character); length += 1
        }
        return quote
    }
}
