import SwiftUI
import Markdown
import CommaCore

// MARK: - Blocks

struct MarkdownBlockView: View {
    let markup: Markup
    let style: MarkdownStyle
    var listDepth = 0
    @Environment(\.inlineTaskStore) fileprivate var taskStore
    /// An inline Task's status icon, the desktop's 20pt at the body size.
    @ScaledMetric(relativeTo: .body) fileprivate var taskIconSide: CGFloat = 20

    var body: some View {
        switch markup {
        case let paragraph as Paragraph:
            let inline = inlineText(paragraph)
            // Selection is set on the text, not the bubble, so the pills beneath it keep their renderer.
            inline.text.font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .lineSpacing(3)
                .selectableMessageText()
                .inlineTaskPills(inline.text.font(style.body), has: inline.hasTasks, iconSide: taskIconSide, lineSpacing: 3)
                .fixedSize(horizontal: false, vertical: true)
        case let heading as Heading:
            let inline = inlineText(heading)
            inline.text.font(style.heading(heading.level)).foregroundStyle(CommaTheme.textPrimary)
                .selectableMessageText()
                .inlineTaskPills(inline.text.font(style.heading(heading.level)), has: inline.hasTasks, iconSide: taskIconSide)
                .fixedSize(horizontal: false, vertical: true)
        case let list as UnorderedList:
            MarkdownListView(items: Array(list.listItems), ordered: false, start: 1, depth: listDepth, style: style)
        case let list as OrderedList:
            MarkdownListView(items: Array(list.listItems), ordered: true, start: Int(list.startIndex), depth: listDepth, style: style)
        case let quote as BlockQuote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(CommaTheme.markdownBorder).frame(width: 4)
                VStack(alignment: .leading, spacing: style.compact ? 6 : 8) {
                    ForEach(Array(quote.children.enumerated()), id: \.offset) { _, child in
                        MarkdownBlockView(markup: child, style: style)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case let code as CodeBlock:
            MarkdownCodeView(block: code, style: style)
                .padding(10)
                .background(CommaTheme.markdownTable, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .selectableMessageText()
        case let table as Markdown.Table:
            MarkdownTableView(table: table, style: style).selectableMessageText()
        case is ThematicBreak:
            Rectangle().fill(CommaTheme.markdownBorder).frame(height: 0.5)
        case let html as HTMLBlock:
            Text(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .selectableMessageText()
        default:
            Text(markup.format().trimmingCharacters(in: .whitespacesAndNewlines))
                .font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .selectableMessageText()
        }
    }
}

extension MarkdownBlockView {
    /// A paragraph or heading's inline Markdown, and whether it names a Task inline.
    fileprivate func inlineText(_ markup: Markup) -> (text: SwiftUI.Text, hasTasks: Bool) {
        let value = MarkdownInline.attributed(markup, style: style)
        return (MarkdownInline.text(value, iconSide: taskIconSide, summary: taskStore.map { store in { store.taskSummary(id: $0) } }),
                MarkdownInline.namesTask(value))
    }
}

/// Bullets cycle disc → circle → square with depth; ordered markers use tabular digits.
struct MarkdownListView: View {
    let items: [ListItem]
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
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            MarkdownBlockView(markup: child, style: style, listDepth: depth + 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 2 : 0)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func marker(_ index: Int, _ item: ListItem) -> some View {
        if let checkbox = item.checkbox {
            // A hidden digit carries the item's first baseline; the box is drawn on its line.
            Text(verbatim: "0").font(style.body).hidden()
                .frame(minWidth: 18)
                .overlay { MarkdownCheckbox(checked: checkbox == .checked) }
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
    let block: CodeBlock
    let style: MarkdownStyle
    /// Padding inside a bubble of its own. The code scrolls under it, so a line too long to show runs on to the
    /// bubble's edge and reads as cut off there, as text under a scroll edge does.
    var inset = EdgeInsets()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language = block.language, !language.isEmpty {
                Text(language.lowercased()).font(.footnote.weight(.medium))
                    .foregroundStyle(CommaTheme.textQuaternary)
                    .padding(.leading, inset.leading).padding(.trailing, inset.trailing)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.code.hasSuffix("\n") ? String(block.code.dropLast()) : block.code)
                    .font(style.code)
                    .foregroundStyle(CommaTheme.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .contentMargins(.leading, inset.leading, for: .scrollContent)
            .contentMargins(.trailing, inset.trailing, for: .scrollContent)
        }
        .padding(.top, inset.top).padding(.bottom, inset.bottom)
    }
}

/// GFM table on the desktop surface: header row on the table background, hairline row dividers,
/// horizontal scrolling when the columns are wider than the bubble.
struct MarkdownTableView: View {
    let table: Markdown.Table
    let style: MarkdownStyle

    var body: some View {
        let alignments = table.columnAlignments
        let head = Array(table.head.cells)
        let rows = table.body.rows.map { Array($0.cells) }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, bold: true, alignment: alignments[safe: column] ?? nil)
                    }
                }
                .background(CommaTheme.markdownTable)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(CommaTheme.markdownBorder)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, bold: false, alignment: alignments[safe: column] ?? nil)
                        }
                    }
                }
            }
            .background(CommaTheme.markdownSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(CommaTheme.markdownBorder, lineWidth: 0.5))
        }
    }

    private func cellView(_ cell: Markdown.Table.Cell, bold: Bool, alignment: Markdown.Table.ColumnAlignment?) -> some View {
        Text(MarkdownInline.attributed(cell, style: style))
            .font(style.table.weight(bold ? .semibold : .regular))
            .foregroundStyle(CommaTheme.textPrimary)
            .multilineTextAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 60, maxWidth: 220, alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
