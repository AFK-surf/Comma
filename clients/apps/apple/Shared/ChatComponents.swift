import SwiftUI
import CommaCore

// MARK: - Row model

enum ChatActorRole: Equatable { case router, worker }

/// One transcript row. The id stays stable when a pending send becomes its committed message,
/// so the bubble keeps its identity instead of replaying an entrance.
struct ChatRow: Identifiable, Equatable {
    enum Content: Equatable {
        case message(Message)
        case pending(text: String, attachments: [ContentBlock], failed: Bool, attemptID: String)
        case draft(text: String)
    }
    let id: String
    let relationshipID: String
    let content: Content
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

    var message: Message? { if case .message(let value) = content { value } else { nil } }
    var isDraft: Bool { if case .draft = content { true } else { false } }
    var text: String {
        switch content {
        case .message(let message): message.text
        case .pending(let text, _, _, _): text
        case .draft(let text): text
        }
    }

    func sameSender(_ other: ChatRow) -> Bool {
        isUser == other.isUser && actorRole == other.actorRole && actorID == other.actorID && createdBy == other.createdBy
    }
}

struct ChatReply: Equatable {
    enum Presentation: Equatable { case line, preview }
    /// Row whose avatar or first bubble starts the connector.
    let sourceAnchorID: String
    /// Row the connector reaches, or the thread root for a preview.
    let targetID: String
    let presentation: Presentation
}

enum ChatTranscriptModel {
    /// Port of the desktop `messageRelationships`: one pass groups consecutive rows by sender and thread,
    /// then connects each non-user group to the last group of the same thread.
    static func rows(messages: [Message], pending: [PendingSend], draft: AssistantDraft?, isTask: Bool,
                     activity: String? = nil) -> [ChatRow] {
        var rows: [ChatRow] = messages.map { message in
            let isUser = message.isUser
            let role: ChatActorRole? = isUser ? nil : (!isTask || message.roleLabel == "delegator" ? .router : .worker)
            return ChatRow(id: message.clientRequestID ?? message.id, relationshipID: message.id,
                           content: .message(message), isUser: isUser, actorRole: role,
                           actorID: message.actorType == "agent" ? message.agentID : nil,
                           createdBy: isUser ? message.userID : nil,
                           threadRoot: message.threadRootMessageID ?? message.id, createdAt: message.createdAt)
        }
        let committed = Set(messages.compactMap(\.clientRequestID))
        let lastUserID = messages.last(where: \.isUser)?.userID
        for attempt in pending where !committed.contains(attempt.id) {
            rows.append(ChatRow(id: attempt.id, relationshipID: attempt.id,
                                content: .pending(text: attempt.text, attachments: attempt.attachments,
                                                  failed: attempt.status == .failed, attemptID: attempt.id),
                                isUser: true, actorRole: nil, actorID: nil, createdBy: lastUserID,
                                threadRoot: attempt.id, createdAt: nil))
        }
        if let draft {
            let parent = draft.sourceMessageIDs.last
            let root = messages.first { $0.id == parent }.map { $0.threadRootMessageID ?? $0.id } ?? parent ?? draft.id
            rows.append(ChatRow(id: "draft", relationshipID: "draft:" + draft.id, content: .draft(text: draft.displayText),
                                isUser: false, actorRole: isTask ? .worker : .router, actorID: nil, createdBy: nil,
                                threadRoot: root, createdAt: nil))
        }
        var related = relate(rows)
        if draft != nil, let last = related.indices.last {
            related[last].activityLabel = String(localized: "Typing…")
        } else if let activity {
            // Status feedback is not a message: it joins no reply chain. It shares the draft row's
            // identity so the thinking bubble becomes the streamed reply in place.
            var row = ChatRow(id: "draft", relationshipID: "activity", content: .draft(text: ""), isUser: false,
                              actorRole: isTask ? .worker : .router, actorID: nil, createdBy: nil,
                              threadRoot: "activity", createdAt: nil)
            row.bubbleTail = true
            row.activityLabel = activity
            related.append(row)
        }
        return related
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
        for group in groups {
            let first = group[0], last = group[group.count - 1]
            let root = rows[first].threadRoot
            let previousAnchor = lastThreadAnchor[root]
            lastThreadAnchor[root] = last
            if rows[first].isUser || (previousAnchor == nil && root == rows[first].relationshipID) { continue }
            // Extend a thread from its last group. Another thread's connector in the interval forces a preview.
            let lined = previousAnchor.map { $0 >= occupiedThrough } ?? false
            occupiedThrough = last
            if lined, let previousAnchor {
                rows[first].reply = ChatReply(sourceAnchorID: rows[last].id, targetID: rows[previousAnchor].id, presentation: .line)
            } else {
                rows[first].reply = ChatReply(sourceAnchorID: rows[last].id,
                                              targetID: position[root].map { rows[$0].id } ?? root, presentation: .preview)
            }
        }
        return rows
    }
}

// MARK: - Bubble

enum BubbleTail { case none, leading, trailing }

/// A chat bubble with the desktop's 20pt radius and optional message tail.
/// The tail uses the same vector as `message-tail.svg`: 16×10, 8pt in from the edge, hanging 7pt below.
struct ChatBubbleSurface<Label: View>: View {
    var fill: Color
    var tail: BubbleTail = .none
    var radius: CGFloat = CommaTheme.bubbleRadius
    @ViewBuilder var label: Label

    var body: some View {
        label
            .background(alignment: tail == .leading ? .bottomLeading : .bottomTrailing) {
                ZStack(alignment: tail == .leading ? .bottomLeading : .bottomTrailing) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    if tail != .none {
                        Image("MessageTail").renderingMode(.template).resizable()
                            .foregroundStyle(fill)
                            .frame(width: 16, height: 10)
                            .scaleEffect(x: tail == .leading ? -1 : 1, y: 1)
                            .offset(x: tail == .leading ? 8 : -8, y: 7)
                    }
                }
            }
    }
}

/// Text bubbles for one message: one bubble per Markdown block for assistants, one bubble for users.
struct MessageBubbles: View {
    let text: String
    let isUser: Bool
    let tail: Bool
    var compact = false

    var body: some View {
        if isUser {
            ChatBubbleSurface(fill: CommaTheme.brandSolid, tail: tail ? .trailing : .none, radius: radius) {
                Text(inline(text)).font(font).foregroundStyle(.white)
                    .tint(.white)
                    .padding(padding)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .selectableMessageText()
        } else {
            MarkdownBubbles(text: text, tail: tail, compact: compact)
        }
    }

    private var font: Font { compact ? .system(size: 15) : CommaTheme.messageFont }
    private var radius: CGFloat { compact ? 16 : CommaTheme.bubbleRadius }
    private var padding: EdgeInsets {
        compact ? EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10) : CommaTheme.bubblePadding
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(value)
    }
}

/// Desktop `.comma-chat-thinking-bubble`: a 40pt tailed bubble with the animated Comma mark and a
/// shimmering status line. Its surface breathes (1 → 1.025 over 3.6s) while Comma works.
struct ThinkingBubble: View {
    var label: String = String(localized: "Thinking…")
    var compact = false
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            CommaLogoAnimation(ink: CommaTheme.textPrimary, aperture: CommaTheme.bubbleAssistant)
                .frame(width: 16, height: 16)
            ShimmerText(text: label, font: .system(size: compact ? 13 : 15))
                .contentTransition(.opacity)
                .animation(CommaMotion.stateChange, value: label)
        }
        .padding(.horizontal, 13)
        .frame(height: compact ? 34 : 40)
        .background(alignment: .bottomLeading) {
            ChatBubbleSurface(fill: CommaTheme.bubbleAssistant, tail: .leading, radius: compact ? 16 : CommaTheme.bubbleRadius) {
                Color.clear
            }
            .scaleEffect(breathing ? 1.025 : 1, anchor: .center)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 1.8).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Running-status text with the desktop `comma-shiny-text` sweep.
struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 13)
    @State private var phase: CGFloat = -1
    var body: some View {
        Text(text).font(font).foregroundStyle(CommaTheme.textQuaternary).lineLimit(1)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, CommaTheme.textPrimary.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.5)
                        .offset(x: phase * geometry.size.width * 1.5)
                }
                .mask(Text(text).font(font).lineLimit(1))
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Agent avatar: the Comma mark for the Router and a sparkle on the worker colour for Workers.
struct AgentAvatar: View {
    let role: ChatActorRole
    var size: CGFloat = 16
    var body: some View {
        Group {
            switch role {
            case .router:
                CommaMark(size: size).foregroundStyle(CommaTheme.textPrimary)
            case .worker:
                Image(systemName: "sparkles").font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(CommaTheme.agentAvatar, in: Circle())
                    .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Extras

/// Task references, attachments and widget summaries under a message's bubbles.
struct MessageExtras: View {
    let message: Message
    /// Current Task summary for a referenced id, when the task list has it.
    var taskSummary: ((String) -> Conversation?)?
    var openTask: ((String) -> Void)?
    var openAttachment: ((Int, String) -> Void)?

    static let blockTypes: Set<String> = ["conversation_ref", "file", "image", "widget"]

    /// Whether anything renders under the text bubbles; the last bubble then gives up its tail.
    static func hasContent(_ message: Message) -> Bool {
        message.content.contains { block in
            switch block.type {
            case "conversation_ref": block.conversationID != nil
            case "file", "image": true
            case "widget": block.summary != nil
            default: false
            }
        }
    }

    var body: some View {
        let items = Array(message.content.enumerated()).filter { Self.blockTypes.contains($0.element.type) }
        if !items.isEmpty {
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                ForEach(items, id: \.offset) { index, block in item(index, block) }
            }
        }
    }

    @ViewBuilder private func item(_ index: Int, _ block: ContentBlock) -> some View {
        switch block.type {
        case "conversation_ref":
            if let id = block.conversationID {
                Button { openTask?(id) } label: {
                    TaskReferenceCard(title: block.title, task: taskSummary?(id))
                }
                .buttonStyle(TactileButtonStyle(scale: 0.98))
                .disabled(openTask == nil)
                .accessibilityIdentifier("task-ref-" + id)
            }
        case "file", "image":
            let name = block.displayName ?? String(localized: "Attachment")
            Button { openAttachment?(index, name) } label: {
                HStack(spacing: 6) {
                    Image(systemName: block.type == "image" ? "photo" : "doc").font(.system(size: 13))
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(CommaTheme.textSecondary)
                .padding(.horizontal, 10).frame(height: 30)
                .background(CommaTheme.bgSecondary, in: Capsule())
                .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(openAttachment == nil)
        default:
            if let summary = block.summary {
                Text(summary).font(.system(size: 14)).foregroundStyle(CommaTheme.textTertiary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(CommaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// A Task referenced in chat, drawn like the desktop Task card: status icon on the title line,
/// then running progress or the status and updated date.
struct TaskReferenceCard: View {
    let title: String?
    let task: Conversation?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let task { TaskStatusIcon(bucket: task.bucket) }
                else {
                    Image(systemName: "checklist").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(CommaTheme.sidebarIcon).frame(width: 18, height: 18)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(task?.title ?? title ?? String(localized: "Task"))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                if let task, let progress = task.progressLabel {
                    ShimmerText(text: progress)
                } else {
                    Text(detail).font(.system(size: 13)).foregroundStyle(CommaTheme.textQuaternary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CommaTheme.textPlaceholder)
                .padding(.top, 3)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(CommaTheme.cardPrimary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detail: String {
        guard let task else { return String(localized: "Task") }
        return String(localized: "\(String(localized: task.bucket.labelResource)) · \(task.updatedLabel)")
    }
}

extension Conversation {
    /// Only running work reports progress; the status icon already says where other tasks landed.
    var progressLabel: String? {
        guard bucket == .inProgress else { return nil }
        let activity = activityStatus?.replacingOccurrences(of: "_", with: " ").capitalized(with: .current)
        return activity.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "In progress")
    }

    var updatedLabel: String {
        guard let value = updatedAt, value > 0 else { return String(localized: "Updated recently") }
        let date = Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
        return String(localized: "Updated \(date.formatted(.dateTime.month(.abbreviated).day()))")
    }
}

// MARK: - Task status

extension TaskBucket {
    var labelResource: LocalizedStringResource {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In progress"
        case .needsReview: "Needs review"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .archived: "Archived"
        }
    }
    var label: LocalizedStringKey {
        switch self {
        case .backlog: "Backlog"
        case .inProgress: "In progress"
        case .needsReview: "Needs review"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .archived: "Archived"
        }
    }
    var symbol: String {
        switch self {
        case .backlog: "circle.dashed"
        case .inProgress: "circle.dotted.circle"
        case .needsReview: "exclamationmark.bubble"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .archived: "archivebox"
        }
    }
    var tint: Color {
        switch self {
        case .needsReview: CommaTheme.attention
        case .done: CommaTheme.successPrimary
        case .cancelled: CommaTheme.errorPrimary
        default: CommaTheme.sidebarIcon
        }
    }
}

/// Status glyph with the desktop Task board colours. Only running work turns; the turning glyph is its own
/// view, so a status change removes it together with its repeating animation.
struct TaskStatusIcon: View {
    let bucket: TaskBucket
    var size: CGFloat = 18
    var body: some View {
        Group {
            if bucket == .inProgress {
                SpinningStatusGlyph(symbol: bucket.symbol, tint: bucket.tint, size: size)
            } else {
                Image(systemName: bucket.symbol)
                    .font(.system(size: size * 0.9, weight: .medium))
                    .foregroundStyle(bucket.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SpinningStatusGlyph: View {
    let symbol: String
    let tint: Color
    let size: CGFloat
    @State private var turning = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.9, weight: .medium))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}
