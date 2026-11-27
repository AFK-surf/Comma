import SwiftUI
import CommaCore

// MARK: - Extras

/// Task references and attachments under a message's bubbles. A Task referenced inline sits in the text instead.
struct MessageExtras: View {
    let message: ChatItem
    /// Current Task summary for a referenced id, when the task list has it.
    var taskSummary: ((String) -> TaskSummary?)?
    var openTask: ((String) -> Void)?
    var openMiniApp: ((MiniAppCardValue) -> Void)?
    var openDynamicUI: ((PhoneDynamicUI) -> Void)?
    var openAttachment: ((ChatAttachment) -> Void)?
    var availableWidth: CGFloat = 358
    var includeAttachments: Bool = true
    @Environment(\.chatMedia) private var images

    /// Whether anything renders under the text bubbles, a question card included; the last bubble then gives up its tail.
    static func hasContent(_ message: ChatItem) -> Bool { hasChips(message) || message.question != nil }

    /// Whether the message has Task references or attachments, which this view draws.
    static func hasChips(_ message: ChatItem) -> Bool { !message.refs.isEmpty || !message.attachments.isEmpty || !message.miniApps.isEmpty || !message.dynamicUIs.isEmpty }

    var body: some View {
        let showsExtras = !message.refs.isEmpty || !message.miniApps.isEmpty || !message.dynamicUIs.isEmpty || (includeAttachments && !message.attachments.isEmpty)
        if showsExtras {
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                ForEach(message.dynamicUIs) { ui in
                    DynamicUIChatCard(ui: ui, disabled: openDynamicUI == nil) {
                        openDynamicUI?(ui)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.trailing, message.isUser ? 0 : 42)
                }
                ForEach(message.miniApps) { app in
                    MiniAppChatCard(app: app) { openMiniApp?(app) }.disabled(openMiniApp == nil)
                }
                ForEach(Array(message.refs.enumerated()), id: \.offset) { _, ref in
                    Button { openTask?(ref.conversationID) } label: {
                        TaskReferenceLabel(title: ref.title, task: taskSummary?(ref.conversationID))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(openTask == nil)
                    .accessibilityIdentifier("task-ref-" + ref.conversationID)
                }
                if includeAttachments, !message.attachments.isEmpty {
                    let partitioned = Self.partitionAttachments(message: message, context: images)
                    if let images, !partitioned.images.isEmpty {
                        ChatMediaImageGroupView(
                            messageID: message.id,
                            items: partitioned.images,
                            context: images,
                            isUser: message.isUser,
                            availableWidth: availableWidth,
                            openAttachment: openAttachment
                        )
                    }
                    if let images, !partitioned.videos.isEmpty {
                        FlowLayout(spacing: CommaTheme.imageSpacing) {
                            ForEach(partitioned.videos) { item in
                                ChatMediaThumbnail(item: item, context: images) { openAttachment?(item.attachment) }
                                    .id(item.cacheKey)
                            }
                        }
                    }
                    if !partitioned.files.isEmpty {
                        FlowLayout(spacing: CommaTheme.imageSpacing) {
                            ForEach(Array(partitioned.files.enumerated()), id: \.offset) { _, attachment in
                                Button { openAttachment?(attachment) } label: {
                                    FileChip(name: attachment.name, icon: attachment.blockType == "image" ? "central-images-1" : "central-file-bend")
                                }
                                .buttonStyle(TactileButtonStyle())
                                .disabled(openAttachment == nil || attachment.index == nil)
                            }
                        }
                    }
                }
            }
        }
    }

    static func partitionAttachments(
        message: ChatItem,
        context: ChatMediaContext?
    ) -> (images: [ChatMediaItem], videos: [ChatMediaItem], files: [ChatAttachment]) {
        var imageItems: [ChatMediaItem] = []
        var videoItems: [ChatMediaItem] = []
        var files: [ChatAttachment] = []
        for (position, attachment) in message.attachments.enumerated() {
            if let context, let item = context.item(message: message, position: position, attachment: attachment) {
                if item.isVideo {
                    videoItems.append(item)
                } else {
                    imageItems.append(item)
                }
            } else {
                files.append(attachment)
            }
        }
        return (imageItems, videoItems, files)
    }
}


/// Compact launch card for an Agent-generated `dynamic_ui` attachment in the chat transcript.
/// Follows `QuestionCard` and `AgentRequestCard` surface tokens. When a concise `title` is present,
/// renders it as the bold headline paired with the disclosure chevron and up to two muted lines of
/// deduplicated summary; legacy payloads without a `title` fall back to a three-line summary row.
struct DynamicUIChatCard: View {
    let ui: PhoneDynamicUI
    let disabled: Bool
    let open: () -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let card = RoundedRectangle(cornerRadius: CommaTheme.bubbleRadius, style: .continuous)
        let title = ui.title
        let preview = Self.previewText(for: ui.summary)
        let subtitle = title.flatMap { title in preview.flatMap { Self.subtitleText(for: $0, title: title) } }
        Button(action: open) {
            Group {
                if let title {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: title)
                                .font(.headline)
                                .foregroundStyle(CommaTheme.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !disabled {
                                SettingsChevron()
                                    .frame(height: UIFont.preferredFont(forTextStyle: .headline).lineHeight)
                            }
                        }
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.subheadline)
                                .foregroundStyle(CommaTheme.textSecondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: preview ?? String(localized: "Interactive content"))
                            .font(.subheadline)
                            .foregroundStyle(CommaTheme.textPrimary)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !disabled {
                            SettingsChevron()
                                .frame(height: UIFont.preferredFont(forTextStyle: .subheadline).lineHeight)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CommaTheme.bgSecondary, in: card)
            .overlay(card.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1 / displayScale))
            .contentShape(card)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier("message.dynamic-ui.\(ui.id)")
    }

    static func previewText(for summary: String) -> String? {
        let lines = summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: "\n")
        return normalized.isEmpty ? nil : normalized
    }

    static func subtitleText(for preview: String, title: String) -> String? {
        let trimmedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreview.isEmpty else { return nil }
        let stripped = stripLeadingTitlePrefix(trimmedPreview, title: title)
        return stripped.isEmpty ? nil : stripped
    }

    private static let titleSeparators = CharacterSet(charactersIn: "：:，,—–-·|。.;；")
        .union(.whitespacesAndNewlines)

    private static func stripLeadingTitlePrefix(_ text: String, title: String) -> String {
        let titleScalars = title.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !titleScalars.isEmpty else { return text }

        let textView = text.unicodeScalars
        var textIdx = textView.startIndex
        var titleIdx = titleScalars.startIndex

        while titleIdx < titleScalars.endIndex {
            while textIdx < textView.endIndex,
                  CharacterSet.whitespacesAndNewlines.contains(textView[textIdx]) {
                textIdx = textView.index(after: textIdx)
            }
            guard textIdx < textView.endIndex else { return text }
            if String(textView[textIdx]).lowercased() != String(titleScalars[titleIdx]).lowercased() {
                return text
            }
            textIdx = textView.index(after: textIdx)
            titleIdx = titleScalars.index(after: titleIdx)
        }

        if textIdx == textView.endIndex {
            return ""
        }

        guard titleSeparators.contains(textView[textIdx]) else {
            return text
        }

        while textIdx < textView.endIndex, titleSeparators.contains(textView[textIdx]) {
            textIdx = textView.index(after: textIdx)
        }
        return String(textView[textIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A file under a message: one the member sent, as the composer's chip showed it, or an attachment to open.
struct FileChip: View {
    let name: String
    var icon = "central-file-bend"

    var body: some View {
        HStack(spacing: 6) {
            CentralIcon(icon, size: 16, relativeTo: .subheadline)
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(CommaTheme.textSecondary)
        .padding(.horizontal, 12).frame(minHeight: 32)
        .background(CommaTheme.bgSecondary, in: Capsule())
        .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Text a member attached as a block, such as a Routine item: the app's mark and the text's first line, as the
/// desktop's pill shows it. A tap shows the whole text, as hovering the pill does on the desktop.
struct AttachedTextChip: View {
    let attached: ChatAttachedText
    @State private var showsText = false

    var body: some View {
        Button { showsText = true } label: {
            HStack(spacing: 6) {
                if let image = ProviderArtwork.image(attached.source) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                        .foregroundStyle(CommaTheme.textPrimary)
                } else {
                    CentralIcon("central-file-bend", size: 16, relativeTo: .subheadline)
                }
                Text(attached.title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(CommaTheme.textSecondary)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(CommaTheme.bgSecondary, in: Capsule())
            .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityIdentifier("attached-text")
        .popover(isPresented: $showsText) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let source = attached.source {
                        Text(verbatim: source).font(.footnote.weight(.semibold)).foregroundStyle(CommaTheme.textSecondary)
                    }
                    Text(verbatim: attached.text).font(.subheadline).foregroundStyle(CommaTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .frame(idealWidth: 300, maxHeight: 360)
            .presentationCompactAdaptation(.popover)
        }
    }
}
