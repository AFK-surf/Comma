import SwiftUI
import CommaCore

// MARK: - Extras

/// Task references and attachments under a message's bubbles. A Task referenced inline sits in the text instead.
struct MessageExtras: View {
    let message: ChatItem
    /// Current Task summary for a referenced id, when the task list has it.
    var taskSummary: ((String) -> TaskSummary?)?
    var openTask: ((String) -> Void)?
    var openAttachment: ((ChatAttachment) -> Void)?

    /// Whether anything renders under the text bubbles, a question card included; the last bubble then gives up its tail.
    static func hasContent(_ message: ChatItem) -> Bool { hasChips(message) || message.question != nil }

    /// Whether the message has Task references or attachments, which this view draws.
    static func hasChips(_ message: ChatItem) -> Bool { !message.refs.isEmpty || !message.attachments.isEmpty }

    var body: some View {
        if Self.hasChips(message) {
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                ForEach(Array(message.refs.enumerated()), id: \.offset) { _, ref in
                    Button { openTask?(ref.conversationID) } label: {
                        TaskReferenceLabel(title: ref.title, task: taskSummary?(ref.conversationID))
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(openTask == nil)
                    .accessibilityIdentifier("task-ref-" + ref.conversationID)
                }
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    Button { openAttachment?(attachment) } label: {
                        // The desktop's file and image glyphs.
                        FileChip(name: attachment.name, icon: attachment.blockType == "image" ? "central-images-1" : "central-file-bend")
                    }
                    .buttonStyle(TactileButtonStyle())
                    .disabled(openAttachment == nil || attachment.index == nil)
                }
            }
        }
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
