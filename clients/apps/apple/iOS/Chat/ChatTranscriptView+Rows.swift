import SwiftUI
import CommaCore

/// Row layout for the transcript: bubbles, avatars, reply previews, spacing and entrances.
extension ChatTranscriptView {
    // MARK: Rows

    /// Each row reads its text once: a message's text is filtered from its content on every read.
    @ViewBuilder func rowView(_ row: ChatRow, proxy: ScrollViewProxy) -> some View {
        let text = row.text
        if row.isMine {
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 6) {
                    if let message = row.message {
                        extras(message, availableWidth: contentWidth, includeAttachments: false)
                    }
                    userMediaAndFiles(row)
                    // Attachments stay above the person's message text.
                    ForEach(Array(row.attachedTexts.enumerated()), id: \.offset) { _, attached in AttachedTextChip(attached: attached) }
                    if !text.isEmpty {
                        Group {
                            if let flight {
                                OutgoingSlot(controller: flight, id: row.id) {
                                    MessageBubbles(text: text, isUser: true, tail: row.bubbleTail, platform: row.message?.platformSource)
                                }
                            } else {
                                MessageBubbles(text: text, isUser: true, tail: row.bubbleTail, platform: row.message?.platformSource)
                            }
                        }
                        .padding(.leading, 42)
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .environment(\.messageSelection, selection(in: row))
                        .contextMenu { messageMenu(row) }
                        // The anchor is outside the swipe, so a reply line stays where the bubble rests.
                        .modifier(swipeToReply(row))
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                    }
                }
                // Media-, file- or chip-only user messages have no text bubble; fall back to their content bounds.
                .transformAnchorPreference(key: ChatAnchorKey.self, value: .bounds) { value, anchor in
                    let id = ChatAnchorID(row: row.id, part: .content)
                    if value[id] == nil { value[id] = anchor }
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
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(highlight(row))
        } else {
            let agentAvailableWidth = max(0, contentWidth - (showsIdentity(row) ? CommaTheme.avatarGutter : 0))
            HStack(alignment: .bottom, spacing: 0) {
                if showsIdentity(row) {
                    ZStack(alignment: .bottomLeading) {
                        Color.clear
                        if row.groupLast, let writer = row.otherWriter {
                            PersonAvatar(store: store, name: personName(writer), source: people?.face(writer)?.avatar, size: 24)
                                .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .avatar): $0] }
                        } else if row.groupLast, let role = row.actorRole {
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
                        .padding(.trailing, 42)
                        .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .preview): $0] }
                        .padding(.bottom, 6)
                    }
                    let hasBody = (showsIdentity(row) && row.groupFirst)
                        || (row.otherWriter != nil && (!row.attachedTexts.isEmpty || !row.files.isEmpty))
                        || (row.isDraft && text.isEmpty)
                        || !text.isEmpty
                        || (row.message.map(MessageExtras.hasChips) ?? false)
                    VStack(alignment: .leading, spacing: 6) {
                        if hasBody {
                            VStack(alignment: .leading, spacing: 6) {
                                if showsIdentity(row), row.groupFirst {
                                    let workerLabel: String = {
                                        if pane.workerSessions.count > 1,
                                           let pid = row.participantID,
                                           let session = pane.workerSessions.first(where: { $0.participantID == pid }) {
                                            let trimmed = session.label.trimmingCharacters(in: .whitespacesAndNewlines)
                                            let lower = trimmed.lowercased()
                                            let lowerSlot = session.slot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                            let showSlot = lower != lowerSlot && lower != "@\(lowerSlot)"
                                            return showSlot ? "\(trimmed) @\(session.slot)" : trimmed
                                        }
                                        return String(localized: "Worker")
                                    }()
                                    Text(row.otherWriter.map(personName)
                                         ?? (row.actorRole == .router ? pane.store?.router.name ?? "Comma" : workerLabel))
                                        .font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                                        .padding(.leading, 13)
                                }
                                if row.otherWriter != nil {
                                    ForEach(Array(row.attachedTexts.enumerated()), id: \.offset) { _, attached in AttachedTextChip(attached: attached) }
                                    ForEach(Array(row.files.enumerated()), id: \.offset) { _, name in FileChip(name: name) }
                                }
                                if row.isDraft && text.isEmpty {
                                    ThinkingBubble(label: row.activityLabel ?? String(localized: "Thinking…"))
                                        .padding(.trailing, 42)
                                } else if !text.isEmpty, row.otherWriter != nil {
                                    MessageBubbles(text: text, isUser: true, tail: false, incoming: true)
                                        .padding(.trailing, 42)
                                } else if !text.isEmpty {
                                    // The tail marks the end of the message, so a following card or attachment takes it over.
                                    MessageBubbles(text: text, isUser: false,
                                                   tail: row.bubbleTail && !showsIdentity(row) && !(row.message.map(MessageExtras.hasContent) ?? false),
                                                   markdown: row.markdown, parts: row.message?.parts ?? [])
                                        .padding(.trailing, 42)
                                }
                                if let message = row.message { extras(message, availableWidth: agentAvailableWidth) }
                            }
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .environment(\.messageSelection, selection(in: row))
                            .contextMenu { messageMenu(row) }
                            // The anchor is outside the swipe, so a reply line stays where the bubble rests.
                            .modifier(swipeToReply(row))
                        }
                        if let message = row.message, let question = message.question {
                            // Outside the bubbles' long press and swipe, which would take the field's editing menu and
                            // the card's touches.
                            QuestionCard(question: question, pane: pane)
                                .frame(maxWidth: 560, alignment: .leading)
                                .padding(.trailing, 42)
                                .padding(.top, hasBody ? 2 : 0)
                        }
                        if let message = row.message, let requests = pane.requestPlacement.byMessage[message.id] {
                            // After the reply's text and question, outside its long press and swipe like the question card.
                            ForEach(requests) { request in
                                AgentRequestCard(request: request, pane: pane)
                                    .frame(maxWidth: 560, alignment: .leading)
                                    .padding(.trailing, 42)
                                    .padding(.top, hasBody || message.question != nil ? 2 : 0)
                            }
                        }
                    }
                    .anchorPreference(key: ChatAnchorKey.self, value: .bounds) { [ChatAnchorID(row: row.id, part: .content): $0] }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(highlight(row))
        }
    }

    @ViewBuilder private func userMediaAndFiles(_ row: ChatRow) -> some View {
        let target = pane.target.map { (groupID: $0.groupID, conversationID: $0.conversationID) }
        let context: ChatMediaContext? = target.map {
            ChatMediaContext(gallery: images, store: store, group: $0.groupID, conversation: $0.conversationID)
        }
        let partitioned = Self.partitionUserMedia(row: row, target: target, context: context)
        if let context, let message = row.message, !partitioned.images.isEmpty {
            ChatMediaImageGroupView(
                messageID: message.id,
                items: partitioned.images,
                context: context,
                isUser: true,
                availableWidth: contentWidth,
                openAttachment: { openAttachment(message, $0) }
            )
        }
        if let context, !partitioned.videos.isEmpty {
            FlowLayout(spacing: CommaTheme.imageSpacing) {
                ForEach(partitioned.videos) { item in
                    ChatMediaThumbnail(item: item, context: context) {
                        if let message = row.message { openAttachment(message, item.attachment) }
                    }
                    .id(item.cacheKey)
                }
            }
        }
        if !partitioned.attachments.isEmpty || !partitioned.fileNames.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(partitioned.attachments.enumerated()), id: \.offset) { _, attachment in
                    if let message = row.message {
                        Button { openAttachment(message, attachment) } label: {
                            FileChip(name: attachment.name, icon: attachment.blockType == "image" ? "central-images-1" : "central-file-bend")
                        }
                        .buttonStyle(TactileButtonStyle())
                        .disabled(attachment.index == nil)
                    }
                }
                ForEach(Array(partitioned.fileNames.enumerated()), id: \.offset) { _, name in
                    FileChip(name: name)
                }
            }
        }
    }

    static func partitionUserMedia(
        row: ChatRow,
        target: (groupID: String, conversationID: String)?,
        context: ChatMediaContext?
    ) -> (images: [ChatMediaItem], videos: [ChatMediaItem], attachments: [ChatAttachment], fileNames: [String]) {
        var imageItems: [ChatMediaItem] = []
        var videoItems: [ChatMediaItem] = []
        var nonMediaAttachments: [ChatAttachment] = []
        var nonMediaFiles: [String] = []
        if let message = row.message {
            for (position, attachment) in message.attachments.enumerated() {
                if let context, let item = context.item(message: message, position: position, attachment: attachment) {
                    if item.isVideo {
                        videoItems.append(item)
                    } else {
                        imageItems.append(item)
                    }
                } else {
                    nonMediaAttachments.append(attachment)
                }
            }
        }
        for (position, name) in row.files.enumerated() {
            if let message = row.message, let target, position < message.files.count,
               let item = ChatMediaItem(message: message, file: message.files[position], position: position,
                                        group: target.groupID, conversation: target.conversationID) {
                if item.isVideo {
                    videoItems.append(item)
                } else {
                    imageItems.append(item)
                }
            } else {
                nonMediaFiles.append(name)
            }
        }
        return (imageItems, videoItems, nonMediaAttachments, nonMediaFiles)
    }

    private func extras(_ message: ChatItem, availableWidth: CGFloat, includeAttachments: Bool = true) -> some View {
        MessageExtras(message: message, taskSummary: store.taskSummary(id:), openTask: openTask,
                      openMiniApp: { app in
            let review = pane.conversation
            let publication = pane.isTask && pane.conversationID == app.conversationID && review?.canAcceptReview == true
                ? review?.reviewVersion.map { MiniAppPublication(appID: app.appID, version: app.version,
                                                                 conversationID: app.conversationID, reviewVersion: $0) } : nil
            store.miniAppTarget = MiniAppTarget(workspaceID: pane.workspace.id, appID: app.appID, version: app.version, publication: publication)
        }, openDynamicUI: { dynamicUI = $0 }, openAttachment: { openAttachment(message, $0) },
                      availableWidth: availableWidth, includeAttachments: includeAttachments)
    }

    private func highlight(_ row: ChatRow) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(CommaTheme.brandSolid.opacity(highlighted == row.id ? 0.1 : 0))
            .padding(-6)
            .animation(.easeOut(duration: 0.14), value: highlighted)
    }

    /// Router identity is implied in the router chat; Tasks show who wrote each group, another person included.
    func showsIdentity(_ row: ChatRow) -> Bool { isTask && !row.isMine }

    /// Another person's name as People knows them; until it loads, or for someone it does not know, unnamed.
    func personName(_ id: String) -> String {
        guard let name = people?.face(id)?.name, !name.isEmpty else { return String(localized: "Someone") }
        return name
    }

    /// Same sender 6pt, a reply under its prompt 12pt, a new turn 20pt.
    func spacing(before row: ChatRow, after previous: ChatRow) -> CGFloat {
        if row.isMine == previous.isMine { return row.groupFirst && !row.isMine && isTask ? 12 : 6 }
        return row.isMine ? 20 : 12
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
        guard !row.isMine && isNew(row) else { return .identity }
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
