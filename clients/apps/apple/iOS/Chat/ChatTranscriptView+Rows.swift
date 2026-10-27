import SwiftUI
import CommaCore

/// Row layout for the transcript: bubbles, avatars, reply previews, spacing and entrances.
extension ChatTranscriptView {
    // MARK: Rows

    /// Each row reads its text once: a message's text is filtered from its content on every read.
    @ViewBuilder func rowView(_ row: ChatRow, proxy: ScrollViewProxy) -> some View {
        let text = row.text
        if row.isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 42)
                VStack(alignment: .trailing, spacing: 6) {
                    if let message = row.message { extras(message) }
                    // Above the text, as the composer held them over the field; the same chips from send to delivery.
                    ForEach(Array(row.attachedTexts.enumerated()), id: \.offset) { _, attached in AttachedTextChip(attached: attached) }
                    ForEach(Array(row.files.enumerated()), id: \.offset) { _, name in FileChip(name: name) }
                    if !text.isEmpty {
                        Group {
                            if let flight {
                                OutgoingSlot(controller: flight, id: row.id) {
                                    MessageBubbles(text: text, isUser: true, tail: row.bubbleTail)
                                }
                            } else {
                                MessageBubbles(text: text, isUser: true, tail: row.bubbleTail)
                            }
                        }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contextMenu { messageMenu(row) }
                        // The anchor is outside the swipe, so a reply line stays where the bubble rests.
                        .modifier(swipeToReply(row))
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                    }
                    if case .pending(let pending) = row.content {
                        if pending.failed {
                            Button { retry(pending.clientRequestID) } label: {
                                Label { Text("Not delivered · Retry") } icon: { CentralIcon("central-exclamation-triangle", size: 14, relativeTo: .footnote) }
                                    .font(.footnote.weight(.medium)).foregroundStyle(CommaTheme.errorPrimary)
                                    .frame(minHeight: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(TactileButtonStyle())
                            .transition(.opacity)
                        }
                    }
                }
            }
            .background(highlight(row))
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                if showsIdentity(row) {
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                        if row.groupLast, let role = row.actorRole {
                            AgentAvatar(role: role).padding(4)
                                .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .avatar): $0] }
                        }
                    }
                    .frame(width: CommaTheme.avatarGutter)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let reply = row.reply, reply.presentation == .preview {
                        ReplyPreview(quote: reply.targetText) {
                            reveal(reply.targetID, proxy: proxy)
                        }
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .preview): $0] }
                        .padding(.bottom, 6)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if showsIdentity(row), row.groupFirst {
                            Text(row.actorRole == .router ? "Comma" : "Worker")
                                .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                                .padding(.leading, 13)
                        }
                        if row.isDraft && text.isEmpty {
                            ThinkingBubble(label: row.activityLabel ?? String(localized: "Thinking…"))
                        } else if !text.isEmpty {
                            // The tail marks the end of the message, so a following card or attachment takes it over.
                            MessageBubbles(text: text, isUser: false,
                                           tail: row.bubbleTail && !showsIdentity(row) && !(row.message.map(MessageExtras.hasContent) ?? false),
                                           markdown: row.markdown, parts: row.message?.parts ?? [])
                        }
                        if let message = row.message { extras(message) }
                    }
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contextMenu { messageMenu(row) }
                    // The anchor is outside the swipe, so a reply line stays where the bubble rests.
                    .modifier(swipeToReply(row))
                    .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                    if let message = row.message, let question = message.question {
                        // Outside the bubbles' long press and swipe, which would take the field's editing menu and
                        // the card's touches; the reply line reaches the card when the message has nothing else.
                        let alone = text.isEmpty && !MessageExtras.hasChips(message)
                        QuestionCard(question: question, pane: pane)
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.top, 2)
                            .anchorPreference(key: ChatAnchorKey.self, value: .bounds) {
                                alone ? [ChatAnchorID(row: row.id, part: .content): $0] : [:]
                            }
                    }
                    if let message = row.message, let requests = pane.requestPlacement.byMessage[message.id] {
                        // After the reply's text and question, outside its long press and swipe like the question card.
                        ForEach(requests) { request in
                            AgentRequestCard(request: request, pane: pane)
                                .frame(maxWidth: 560, alignment: .leading)
                                .padding(.top, 2)
                        }
                    }
                }
                Spacer(minLength: 42)
            }
            .background(highlight(row))
        }
    }

    private func extras(_ message: ChatItem) -> some View {
        MessageExtras(message: message, taskSummary: store.taskSummary(id:), openTask: openTask) { openAttachment(message, $0) }
    }

    private func highlight(_ row: ChatRow) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(CommaTheme.brandSolid.opacity(highlighted == row.id ? 0.1 : 0))
            .padding(-6)
            .animation(.easeOut(duration: 0.14), value: highlighted)
    }

    /// Router identity is implied in the router chat; Tasks show who wrote each group.
    func showsIdentity(_ row: ChatRow) -> Bool { isTask && !row.isUser }

    /// Same sender 6pt, a reply under its prompt 12pt, a new turn 20pt.
    func spacing(before row: ChatRow, after previous: ChatRow) -> CGFloat {
        if row.isUser == previous.isUser { return row.groupFirst && !row.isUser && isTask ? 12 : 6 }
        return row.isUser ? 20 : 12
    }

    func isNew(_ row: ChatRow) -> Bool {
        if row.isDraft { return true }
        guard let createdAt = row.createdAt else { return !row.isUser }
        return Date(wireTimestamp: createdAt).timeIntervalSince1970 >= openedAt - 1
    }

    func isPending(_ row: ChatRow) -> Bool {
        if case .pending = row.content { true } else { false }
    }

    /// A send with text arrives as the composer's flying surface. A send without one rises from the composer,
    /// and a new reply settles in; with Reduce Motion both only fade in.
    func transition(for row: ChatRow) -> AnyTransition {
        if isPending(row) {
            if flight != nil && !row.text.isEmpty { return .identity }
            return reduceMotion ? .opacity.animation(CommaMotion.stateChange) : .outgoingBubble
        }
        guard !row.isUser && isNew(row) else { return .identity }
        return reduceMotion ? .opacity.animation(CommaMotion.stateChange) : .assistantEntry
    }
}

// MARK: - Reply preview

/// Quoted target shown above a reply whose thread was interrupted by another connector.
private struct ReplyPreview: View {
    let text: String
    let action: () -> Void

    /// `quote` is the target's text on one line, as the transcript model flattened it; nil while the target
    /// is not loaded.
    init(quote: String?, action: @escaping () -> Void) {
        self.action = action
        guard let quote else { text = String(localized: "Load earlier message"); return }
        text = quote.isEmpty ? String(localized: "Attachment") : quote
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
                .opacity(0.7)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.98))
        .accessibilityLabel(Text("View replied message: \(text)"))
    }
}
