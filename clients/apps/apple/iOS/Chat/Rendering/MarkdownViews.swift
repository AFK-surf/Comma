import SwiftUI
import CommaCore

/// Agent Markdown in bubbles, from the tree the client core parsed (`MarkdownTree`), following the desktop
/// `MarkdownStream` "bubbles" presentation: consecutive prose shares one bubble, code blocks and tables get their own,
/// and a thematic break starts a new bubble.
struct MarkdownBubbles: View {
    let slots: [MarkdownSlot]
    let tail: Bool
    var compact = false
    @Environment(\.assistantBubbleFill) private var fill

    /// The bubbles of a message's tree; `parts` are the message's, which the tree's Task chips name.
    init(tree: NSArray, parts: [ChatPart], tail: Bool, compact: Bool = false) {
        let style = MarkdownStyle(compact: compact)
        slots = MarkdownTree.slots(tree, style: style) { key in
            guard let index = MarkdownTree.partIndex(key), parts.indices.contains(index) else { return nil }
            switch parts[index] {
            case .task(let id, let title, let section, let unavailable):
                return unavailable ? .words(String(localized: "Task unavailable"))
                    : .task(id: id, title: title ?? String(localized: "Task"), bucket: section.map { TaskBucket(section: $0) })
            case .interactive(let summary): return summary.map { .words($0) }
            case .markdown(let text): return .words(text)
            // The card follows the message's bubbles (`QuestionCard`).
            case .question, .other: return nil
            }
        }
        self.tail = tail
        self.compact = compact
    }

    /// Plain words in one bubble, for a message the core gave no tree.
    init(text: String, tail: Bool, compact: Bool = false) {
        slots = text.isEmpty ? [] : [.prose([.paragraph(AttributedString(text))])]
        self.tail = tail
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                let last = index == slots.count - 1
                switch slot {
                case .prose(let blocks):
                    ChatBubbleSurface(fill: fill, tail: tail && last ? .leading : .none, radius: radius) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { position, block in
                                MarkdownBlockView(block: block, style: style)
                                    .padding(.top, position == 0 ? 0 : style.spacing(before: block))
                            }
                        }
                        .padding(padding)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let text):
                    ChatBubbleSurface(fill: CommaTheme.markdownTable, tail: tail && last ? .leading : .none, radius: radius) {
                        // A long line scrolls to the bubble's edge, which clips it, rather than stopping inside the padding.
                        MarkdownCodeView(language: language, code: text, style: style, inset: padding)
                            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                            .selectableMessageText()
                    }
                case .table(let table):
                    ChatBubbleSurface(fill: CommaTheme.markdownTable, tail: tail && last ? .leading : .none, radius: radius) {
                        MarkdownTableView(table: table, style: style).padding(4)
                            .selectableMessageText()
                    }
                }
            }
        }
    }

    private var style: MarkdownStyle { MarkdownStyle(compact: compact) }
    private var radius: CGFloat { compact ? 16 : CommaTheme.bubbleRadius }
    private var padding: EdgeInsets {
        compact ? EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10) : CommaTheme.bubblePadding
    }
}

/// Markdown on the app type ladder (see `CommaTheme.messageFont`), so bubbles follow Dynamic Type: prose at the body
/// size, a first-level heading at the 20pt title size, other headings at the body size in semibold.
struct MarkdownStyle {
    var compact = false
    var body: Font { .body }
    /// SF Mono reads larger than SF Pro at one size, so code, inline or in a block, sits a step below the prose.
    var code: Font { .subheadline.monospaced() }
    var inlineCode: Font { code }
    var table: Font { .subheadline }

    func heading(_ level: Int) -> Font {
        level == 1 ? .title3.weight(.semibold) : .headline
    }

    /// Desktop rhythm: 12pt between blocks, 20pt before a heading.
    func spacing(before block: MarkdownBlock) -> CGFloat {
        if case .heading = block { return compact ? 14 : 20 }
        return compact ? 8 : 12
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle
    var listDepth = 0
    @Environment(\.inlineTaskStore) private var taskStore
    /// An inline Task's status icon, the desktop's 20pt at the body size.
    @ScaledMetric(relativeTo: .body) private var taskIconSide: CGFloat = 20

    var body: some View {
        switch block {
        case .paragraph(let value):
            let text = inlineText(value)
            // Selection is set on the text, not the bubble, so the pills beneath it keep their renderer.
            text.font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .lineSpacing(3)
                .selectableMessageText()
                .inlineTaskPills(text.font(style.body), has: MarkdownInline.namesTask(value), iconSide: taskIconSide, lineSpacing: 3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            let text = inlineText(value)
            text.font(style.heading(level)).foregroundStyle(CommaTheme.textPrimary)
                .selectableMessageText()
                .inlineTaskPills(text.font(style.heading(level)), has: MarkdownInline.namesTask(value), iconSide: taskIconSide)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            MarkdownListView(items: items, ordered: ordered, start: start, depth: listDepth, style: style)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(CommaTheme.markdownBorder).frame(width: 4)
                VStack(alignment: .leading, spacing: style.compact ? 6 : 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(block: child, style: style)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
            MarkdownCodeView(language: language, code: code, style: style)
                .padding(10)
                .background(CommaTheme.markdownTable, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .selectableMessageText()
        case .table(let table):
            MarkdownTableView(table: table, style: style).selectableMessageText()
        case .divider:
            Rectangle().fill(CommaTheme.markdownBorder).frame(height: 0.5)
        }
    }

    private func inlineText(_ value: AttributedString) -> SwiftUI.Text {
        MarkdownInline.text(value, iconSide: taskIconSide, summary: taskStore.map { store in { store.taskSummary(id: $0) } })
    }
}

/// Bullets cycle disc → circle → square with depth; ordered markers use tabular digits.
struct MarkdownListView: View {
    let items: [MarkdownListItem]
    let ordered: Bool
    let start: Int
    let depth: Int
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.compact ? 5 : 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index, item)
                    VStack(alignment: .leading, spacing: style.compact ? 5 : 8) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                            MarkdownBlockView(block: child, style: style, listDepth: depth + 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 2 : 0)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func marker(_ index: Int, _ item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            // A hidden digit carries the item's first baseline; the box is drawn on its line.
            Text(verbatim: "0").font(style.body).hidden()
                .frame(minWidth: 18)
                .overlay { MarkdownCheckbox(checked: checked) }
        } else if ordered {
            Text("\(start + index).").font(style.body.monospacedDigit()).foregroundStyle(CommaTheme.textPrimary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪"][min(depth, 2)]).font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .frame(minWidth: 12)
        }
    }
}

/// A GFM task-list box: a hairline rounded square, filled with a check when done, as on the desktop.
private struct MarkdownCheckbox: View {
    let checked: Bool
    /// The box grows with the text it sits in.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            if checked {
                shape.fill(CommaTheme.markdownLink)
                CentralIcon("icon-check", size: 14, relativeTo: .body).foregroundStyle(.white)
            } else {
                shape.strokeBorder(CommaTheme.textQuaternary, lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(checked ? Text("Checked") : Text("Unchecked"))
    }
}

struct MarkdownCodeView: View {
    let language: String?
    let code: String
    let style: MarkdownStyle
    /// Padding inside a bubble of its own. The code scrolls under it, so a line too long to show runs on to the
    /// bubble's edge and reads as cut off there, as text under a scroll edge does.
    var inset = EdgeInsets()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.lowercased()).font(.footnote.weight(.medium))
                    .foregroundStyle(CommaTheme.textQuaternary)
                    .padding(.leading, inset.leading).padding(.trailing, inset.trailing)
            }
            // As wide as its longest line; a scroll view only for a line wider than the bubble.
            ViewThatFits(in: .horizontal) {
                text.padding(.leading, inset.leading).padding(.trailing, inset.trailing)
                ScrollView(.horizontal, showsIndicators: false) { text }
                    .contentMargins(.leading, inset.leading, for: .scrollContent)
                    .contentMargins(.trailing, inset.trailing, for: .scrollContent)
            }
        }
        .padding(.top, inset.top).padding(.bottom, inset.bottom)
    }

    private var text: some View {
        Text(code)
            .font(style.code)
            .foregroundStyle(CommaTheme.textPrimary)
            .fixedSize(horizontal: true, vertical: true)
    }
}

/// GFM table on the desktop surface: header row on the table background, hairline row dividers, horizontal scrolling
/// when the columns are wider than the bubble.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle

    /// As wide as its columns: a scroll view of its own only when they are wider than the bubble, so the bubble
    /// around it ends where the table does.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
    }

    private var grid: some View {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.head.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, bold: true, alignment: alignment(column))
                    }
                }
                .background(CommaTheme.markdownTable)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(CommaTheme.markdownBorder)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, bold: false, alignment: alignment(column))
                        }
                    }
                }
            }
            .background(CommaTheme.markdownSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CommaTheme.markdownBorder, lineWidth: 0.5))
    }

    private func alignment(_ column: Int) -> MarkdownTable.Alignment {
        table.alignments.indices.contains(column) ? table.alignments[column] : .leading
    }

    private func cellView(_ cell: AttributedString, bold: Bool, alignment: MarkdownTable.Alignment) -> some View {
        Text(cell)
            .font(style.table.weight(bold ? .semibold : .regular))
            .foregroundStyle(CommaTheme.textPrimary)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 60, maxWidth: 220, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// The inline parts of the app's own Markdown-like text (a member's message, a routine's prose): emphasis, code and
/// links, read by Foundation, and a Task mention's `[Title](comma:task/<id>)` as the link `MarkdownInline.text` draws.
enum MarkdownInline {}

extension EnvironmentValues {
    /// The assistant bubble's fill; an open reply thread deepens it over its blurred backdrop.
    @Entry var assistantBubbleFill: Color = CommaTheme.bubbleAssistant
}
