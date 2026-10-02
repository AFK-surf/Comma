import SwiftUI
import Markdown

/// Agent Markdown in bubbles, following the desktop `MarkdownStream` "bubbles" presentation:
/// consecutive prose (paragraphs, headings, lists, quotes) shares one bubble, code blocks and tables
/// get their own, and a thematic break starts a new bubble. Parsing is Apple's CommonMark + GFM parser.
struct MarkdownBubbles: View {
    let slots: [MarkdownSlot]
    let tail: Bool
    var compact = false

    init(text: String, tail: Bool, compact: Bool = false) {
        slots = MarkdownSlot.slots(for: text)
        self.tail = tail
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                let last = index == slots.count - 1
                switch slot {
                case .prose(let blocks):
                    ChatBubbleSurface(fill: CommaTheme.bubbleAssistant, tail: tail && last ? .leading : .none, radius: radius) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { position, block in
                                MarkdownBlockView(markup: block, style: style)
                                    .padding(.top, position == 0 ? 0 : style.spacing(before: block, after: blocks[position - 1]))
                            }
                        }
                        .padding(padding)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let block):
                    ChatBubbleSurface(fill: CommaTheme.markdownTable, tail: tail && last ? .leading : .none, radius: radius) {
                        MarkdownCodeView(block: block, style: style).padding(padding)
                    }
                case .table(let table):
                    ChatBubbleSurface(fill: CommaTheme.markdownTable, tail: tail && last ? .leading : .none, radius: radius) {
                        MarkdownTableView(table: table, style: style).padding(4)
                    }
                }
            }
        }
        .selectableMessageText()
    }

    private var style: MarkdownStyle { MarkdownStyle(compact: compact) }
    private var radius: CGFloat { compact ? 16 : CommaTheme.bubbleRadius }
    private var padding: EdgeInsets {
        compact ? EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10) : CommaTheme.bubblePadding
    }
}

// MARK: - Slots

enum MarkdownSlot {
    case prose([Markup])
    case code(CodeBlock)
    case table(Markdown.Table)

    /// Port of `markdownPresentationSlots` in `blockPresentation.ts`.
    static func slots(for text: String) -> [MarkdownSlot] {
        let document = Document(parsing: text)
        var slots: [MarkdownSlot] = []
        var startsGroup = true
        for child in document.children {
            if child is ThematicBreak { startsGroup = true; continue }
            if let code = child as? CodeBlock {
                slots.append(.code(code))
            } else if let table = child as? Markdown.Table {
                slots.append(.table(table))
            } else if !startsGroup, case .prose(var blocks) = slots.last {
                blocks.append(child)
                slots[slots.count - 1] = .prose(blocks)
            } else {
                slots.append(.prose([child]))
            }
            startsGroup = child is CodeBlock || child is Markdown.Table
        }
        return slots
    }
}

// MARK: - Style

struct MarkdownStyle {
    var compact = false
    var bodySize: CGFloat { compact ? 15 : 16 }
    var body: Font { .system(size: bodySize) }
    var codeSize: CGFloat { compact ? 12 : 14 }

    func heading(_ level: Int) -> Font {
        let size: CGFloat = switch level {
        case 1: bodySize + 6
        case 2: bodySize + 4
        case 3: bodySize + 2
        default: bodySize
        }
        return .system(size: size, weight: .semibold)
    }

    /// Desktop rhythm: 12pt between blocks, 20pt before a heading, 12pt after one.
    func spacing(before block: Markup, after previous: Markup) -> CGFloat {
        if block is Heading { return compact ? 14 : 20 }
        return compact ? 8 : 12
    }
}

// MARK: - Blocks

struct MarkdownBlockView: View {
    let markup: Markup
    let style: MarkdownStyle
    var listDepth = 0

    var body: some View {
        switch markup {
        case let paragraph as Paragraph:
            Text(MarkdownInline.attributed(paragraph, style: style))
                .font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case let heading as Heading:
            Text(MarkdownInline.attributed(heading, style: style))
                .font(style.heading(heading.level)).foregroundStyle(CommaTheme.textPrimary)
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
        case let table as Markdown.Table:
            MarkdownTableView(table: table, style: style)
        case is ThematicBreak:
            Rectangle().fill(CommaTheme.markdownBorder).frame(height: 0.5)
        case let html as HTMLBlock:
            Text(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(style.body).foregroundStyle(CommaTheme.textPrimary)
        default:
            Text(markup.format().trimmingCharacters(in: .whitespacesAndNewlines))
                .font(style.body).foregroundStyle(CommaTheme.textPrimary)
        }
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
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .font(.system(size: style.bodySize - 1))
                .foregroundStyle(checkbox == .checked ? CommaTheme.markdownLink : CommaTheme.textQuaternary)
        } else if ordered {
            Text("\(start + index).").font(style.body.monospacedDigit()).foregroundStyle(CommaTheme.textPrimary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪"][min(depth, 2)]).font(style.body).foregroundStyle(CommaTheme.textPrimary)
                .frame(minWidth: 12)
        }
    }
}

struct MarkdownCodeView: View {
    let block: CodeBlock
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language = block.language, !language.isEmpty {
                Text(language.lowercased()).font(.system(size: style.codeSize - 2, weight: .medium))
                    .foregroundStyle(CommaTheme.textQuaternary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.code.hasSuffix("\n") ? String(block.code.dropLast()) : block.code)
                    .font(.system(size: style.codeSize, design: .monospaced))
                    .foregroundStyle(CommaTheme.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
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
            .font(.system(size: style.bodySize - 2, weight: bold ? .semibold : .regular))
            .foregroundStyle(CommaTheme.textPrimary)
            .multilineTextAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 60, maxWidth: 220, alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Inline

enum MarkdownInline {
    /// Inline Markdown to one attributed string: emphasis, strikethrough, code, links and breaks.
    static func attributed(_ markup: Markup, style: MarkdownStyle) -> AttributedString {
        var result = AttributedString()
        for child in markup.children { result += inline(child, style: style) }
        return result
    }

    private static func inline(_ markup: Markup, style: MarkdownStyle) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return AttributedString(text.string)
        case is SoftBreak:
            return AttributedString(" ")
        case is LineBreak:
            return AttributedString("\n")
        case let code as InlineCode:
            var value = AttributedString(code.code)
            value.font = .system(size: style.bodySize * 0.92, design: .monospaced)
            value.foregroundColor = CommaTheme.markdownInlineCode
            value.backgroundColor = CommaTheme.markdownInlineCodeBackground
            return value
        case let strong as Strong:
            var value = attributed(strong, style: style)
            value.inlinePresentationIntent = (value.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            return value
        case let emphasis as Emphasis:
            var value = attributed(emphasis, style: style)
            value.inlinePresentationIntent = (value.inlinePresentationIntent ?? []).union(.emphasized)
            return value
        case let strike as Strikethrough:
            var value = attributed(strike, style: style)
            value.strikethroughStyle = .single
            return value
        case let link as Markdown.Link:
            var value = attributed(link, style: style)
            if value.characters.isEmpty { value = AttributedString(link.destination ?? "") }
            if let destination = link.destination, let url = URL(string: destination) { value.link = url }
            value.foregroundColor = CommaTheme.markdownLink
            value.underlineStyle = .single
            return value
        case let image as Markdown.Image:
            var value = AttributedString(image.plainText.isEmpty ? (image.source ?? "") : image.plainText)
            if let source = image.source, let url = URL(string: source) { value.link = url }
            value.foregroundColor = CommaTheme.markdownLink
            return value
        case let html as InlineHTML:
            return AttributedString(html.rawHTML)
        default:
            return attributed(markup, style: style)
        }
    }
}
