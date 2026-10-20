import SwiftUI
import Markdown

/// Agent Markdown in bubbles, following the desktop `MarkdownStream` "bubbles" presentation:
/// consecutive prose (paragraphs, headings, lists, quotes) shares one bubble, code blocks and tables
/// get their own, and a thematic break starts a new bubble. Parsing is Apple's CommonMark + GFM parser.
struct MarkdownBubbles: View {
    let slots: [MarkdownSlot]
    let tail: Bool
    var compact = false
    @Environment(\.assistantBubbleFill) private var fill

    init(text: String, tail: Bool, compact: Bool = false) {
        slots = MarkdownSlot.cached(for: text)
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
                                MarkdownBlockView(markup: block, style: style)
                                    .padding(.top, position == 0 ? 0 : style.spacing(before: block, after: blocks[position - 1]))
                            }
                        }
                        .padding(padding)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let block):
                    ChatBubbleSurface(fill: CommaTheme.markdownTable, tail: tail && last ? .leading : .none, radius: radius) {
                        // A long line scrolls to the bubble's edge, which clips it, rather than stopping inside the padding.
                        MarkdownCodeView(block: block, style: style, inset: padding)
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

// MARK: - Slots

enum MarkdownSlot {
    case prose([Markup])
    case code(CodeBlock)
    case table(Markdown.Table)

    /// The slots for `text`, parsed once while it stays in the cache: a conversation opened again (a Task's
    /// dock, a transcript rebuilt for a new pane) reuses them. Bubbles are built on the main actor, which owns
    /// the cache.
    @MainActor static func cached(for text: String) -> [MarkdownSlot] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.slots }
        let slots = slots(for: text)
        cache.setObject(CachedSlots(slots), forKey: key, cost: text.utf8.count)
        return slots
    }

    /// About a megabyte of message text, so a streamed reply's many drafts push out older ones first.
    @MainActor private static let cache: NSCache<NSString, CachedSlots> = {
        let cache = NSCache<NSString, CachedSlots>()
        cache.totalCostLimit = 1_000_000
        return cache
    }()

    private final class CachedSlots {
        let slots: [MarkdownSlot]
        init(_ slots: [MarkdownSlot]) { self.slots = slots }
    }

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

/// Markdown on the app type ladder (see `CommaTheme.messageFont`), so bubbles follow Dynamic Type: prose at
/// the body size, a first-level heading at the 20pt title size, other headings at the body size in semibold.
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

    /// Desktop rhythm: 12pt between blocks, 20pt before a heading, 12pt after one.
    func spacing(before block: Markup, after previous: Markup) -> CGFloat {
        if block is Heading { return compact ? 14 : 20 }
        return compact ? 8 : 12
    }
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
            value.font = style.inlineCode
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

extension EnvironmentValues {
    /// The assistant bubble's fill; an open reply thread deepens it over its blurred backdrop.
    @Entry var assistantBubbleFill: Color = CommaTheme.bubbleAssistant
}
