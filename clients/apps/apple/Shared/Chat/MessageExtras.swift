import SwiftUI
import CommaCore

// MARK: - Extras

/// Task references, attachments and widget summaries under a message's bubbles. A Task referenced inline sits in
/// the text instead (`Message.bubbleText`).
struct MessageExtras: View {
    let message: Message
    /// Current Task summary for a referenced id, when the task list has it.
    var taskSummary: ((String) -> Conversation?)?
    var openTask: ((String) -> Void)?
    var openAttachment: ((Int, String) -> Void)?

    static let blockTypes: Set<String> = ["conversation_ref", "file", "image", "widget"]

    /// Whether anything renders under the text bubbles; the last bubble then gives up its tail.
    static func hasContent(_ message: Message) -> Bool {
        message.displayContent.contains { block in
            switch block.type {
            case "conversation_ref": block.conversationID != nil && !block.isInlineTaskReference
            case "file", "image": true
            case "widget": block.summary != nil
            default: false
            }
        }
    }

    var body: some View {
        let items = Array(message.displayContent.enumerated()).filter { Self.blockTypes.contains($0.element.type) && !$0.element.isInlineTaskReference }
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
                    TaskReferenceLabel(title: block.title, task: taskSummary?(id))
                }
                .buttonStyle(TactileButtonStyle())
                .disabled(openTask == nil)
                .accessibilityIdentifier("task-ref-" + id)
            }
        case "file", "image":
            let name = block.displayName ?? String(localized: "Attachment")
            Button { openAttachment?(index, name) } label: {
                // The desktop's file and image glyphs.
                FileChip(name: name, icon: block.type == "image" ? "central-images-1" : "central-file-bend")
            }
            .buttonStyle(TactileButtonStyle())
            .disabled(openAttachment == nil)
        default:
            if let summary = block.summary {
                Text(summary).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(CommaTheme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Sent files

/// The desktop's list of workspace files under a member's message (`parseAttachmentsBlock`): a header after a blank
/// line, then one `- name (workspace file: /path)` line per file. A message of files alone reads "I've attached some
/// files:", which the chips replace.
enum AttachedFiles {
    private static let header = "\n\nAttached files in your workspace:\n"
    private static let onlyText = "I've attached some files:"

    /// The message's own text and the names of the files listed under it; the whole text and no names when the
    /// list is missing or any line of it is not a file, as on the desktop.
    static func split(_ text: String) -> (body: String, names: [String]) {
        guard let start = text.range(of: header, options: .backwards) else { return (text, []) }
        var list = text[start.upperBound...]
        while list.last?.isWhitespace == true { list = list.dropLast() }
        // A regex is not Sendable, so it is no static; the literal is checked when the app compiles.
        let line = #/- (.+?) \(workspace file: (/[A-Za-z0-9._~!$&'()*+,;=:@%/-]+)\)/#
        var names: [String] = []
        for row in list.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = row.wholeMatch(of: line) else { return (text, []) }
            names.append(String(match.1))
        }
        guard !names.isEmpty else { return (text, []) }
        let body = String(text[..<start.lowerBound])
        return (body.trimmingCharacters(in: .whitespacesAndNewlines) == onlyText ? "" : body, names)
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
