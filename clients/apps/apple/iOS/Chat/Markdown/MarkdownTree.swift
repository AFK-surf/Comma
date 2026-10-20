import CommaCore
import Foundation
import SwiftUI

/**
 * The Markdown a message carries (`ChatItem.markdown`, the client core's tree) read as blocks to draw, as Android's
 * `MarkdownTree` reads it. The core parses every message once for every client; this only reads its tree: text is a
 * string, any other node `[kind, children?, attributes?]`, a Task chip `["comma-inline", { key }]` naming the message
 * part it stands for.
 */
indirect enum MarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String?, text: String)
    case table(MarkdownTable)
    case divider
}

struct MarkdownListItem {
    /// nil for an item without a box, else whether it is checked.
    let checked: Bool?
    let blocks: [MarkdownBlock]
}

struct MarkdownTable {
    enum Alignment { case leading, center, trailing }
    let head: [AttributedString]
    let alignments: [Alignment]
    let rows: [[AttributedString]]
}

/// Agent Markdown in bubbles, following the desktop `MarkdownStream` "bubbles" presentation: consecutive prose
/// (paragraphs, headings, lists, quotes) shares one bubble, code blocks and tables get their own, and a thematic break
/// starts a new bubble.
enum MarkdownSlot {
    case prose([MarkdownBlock])
    case code(language: String?, text: String)
    case table(MarkdownTable)
}

enum MarkdownTree {
    private static let element = "comma-inline"

    /// What an inline element shows: a Task chip's link (`comma:task/<id>#<bucket>`) and title, or plain words.
    enum Inline {
        case task(id: String?, title: String, bucket: TaskBucket?)
        case words(String)
    }

    /// The part index an element key names (`element-<index in base 36>`); nil for another key.
    static func partIndex(_ key: String) -> Int? {
        guard key.hasPrefix("element-") else { return nil }
        return Int(key.dropFirst("element-".count), radix: 36)
    }

    /// The slots of `tree`, an element drawn as `inline` says (left out when it says nil).
    static func slots(_ tree: NSArray, style: MarkdownStyle, inline: (String) -> Inline?) -> [MarkdownSlot] {
        var slots: [MarkdownSlot] = []
        var startsGroup = true
        for node in tree {
            if kind(node) == "hr" { startsGroup = true; continue }
            let blocks = block(node, style: style, inline: inline)
            for block in blocks {
                switch block {
                case .code(let language, let text): slots.append(.code(language: language, text: text))
                case .table(let table): slots.append(.table(table))
                default:
                    if !startsGroup, case .prose(var prose) = slots.last {
                        prose.append(block)
                        slots[slots.count - 1] = .prose(prose)
                    } else {
                        slots.append(.prose([block]))
                    }
                }
                startsGroup = { if case .code = block { true } else if case .table = block { true } else { false } }()
            }
        }
        return slots
    }

    /// The tree's words, without their styles: what Copy copies.
    static func plainText(_ tree: NSArray, inline: (String) -> Inline?) -> String {
        var out: [String] = []
        for node in tree {
            let words = String(text(children(node).isEmpty && node is String ? [node] : children(node), style: MarkdownStyle(),
                                    inline: inline).characters)
            if kind(node) == "pre" { out.append(attributes(node)?.text("code") ?? "") } else if !words.isEmpty { out.append(words) }
        }
        return out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func block(_ node: Any, style: MarkdownStyle, inline: (String) -> Inline?) -> [MarkdownBlock] {
        if let words = node as? String {
            return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(AttributedString(words))]
        }
        let attributes = attributes(node)
        switch kind(node) {
        case "p":
            let value = trimmed(text(children(node), style: style, inline: inline))
            return value.characters.isEmpty ? [] : [.paragraph(value)]
        case "h":
            return [.heading(level: attributes?.int("level") ?? 1, trimmed(text(children(node), style: style, inline: inline)))]
        case "list":
            let ordered = attributes?.bool("ordered") == true
            let items = children(node).map { item in
                MarkdownListItem(checked: (self.attributes(item)?["checked"] as? NSNumber)?.boolValue,
                                 blocks: children(item).flatMap { block($0, style: style, inline: inline) })
            }
            return [.list(ordered: ordered, start: attributes?.int("start") ?? 1, items: items)]
        case "quote":
            return [.quote(children(node).flatMap { block($0, style: style, inline: inline) })]
        case "pre":
            let code = attributes?.text("code") ?? ""
            return [.code(language: attributes?.string("language"), text: code.hasSuffix("\n") ? String(code.dropLast()) : code)]
        case "mathblock":
            let latex = attributes?.text("content") ?? ""
            let open = attributes?.string("markup") ?? "$$"
            return [.code(language: nil, text: "\(open)\n\(latex)\n\(closing(open))")]
        case "table":
            let rows = children(node).map { children($0) }
            let head = rows.first ?? []
            return [.table(MarkdownTable(
                head: head.map { trimmed(text(children($0), style: style, inline: inline)) },
                alignments: head.map { cell in
                    switch self.attributes(cell)?.string("align") {
                    case "center": .center
                    case "right": .trailing
                    default: .leading
                    }
                },
                rows: rows.dropFirst().map { row in row.map { trimmed(text(children($0), style: style, inline: inline)) } }))]
        case "hr":
            return [.divider]
        case "html_block":
            let raw = (attributes?.text("raw") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? [] : [.paragraph(AttributedString(raw))]
        case element:
            guard let key = attributes?.string("key"), let shown = inline(key) else { return [] }
            return [.paragraph(run(shown))]
        default:
            let nested = children(node)
            if nested.contains(where: { !($0 is String) && blockKinds.contains(kind($0) ?? "") }) {
                return nested.flatMap { block($0, style: style, inline: inline) }
            }
            let value = trimmed(text(nested, style: style, inline: inline))
            return value.characters.isEmpty ? [] : [.paragraph(value)]
        }
    }

    /// Inline nodes as one run of styled text.
    static func text(_ nodes: [Any], style: MarkdownStyle, inline: (String) -> Inline?) -> AttributedString {
        var out = AttributedString()
        for node in nodes {
            if let words = node as? String {
                out += AttributedString(words)
                continue
            }
            let attributes = attributes(node)
            switch kind(node) {
            case "b":
                var value = text(children(node), style: style, inline: inline)
                value.inlinePresentationIntent = (value.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                out += value
            case "i":
                var value = text(children(node), style: style, inline: inline)
                value.inlinePresentationIntent = (value.inlinePresentationIntent ?? []).union(.emphasized)
                out += value
            case "s":
                var value = text(children(node), style: style, inline: inline)
                value.strikethroughStyle = .single
                out += value
            case "a":
                var value = text(children(node), style: style, inline: inline)
                let href = attributes?.text("href") ?? ""
                if value.characters.isEmpty { value = AttributedString(href) }
                if let url = URL(string: href) { value.link = url }
                value.foregroundColor = CommaTheme.markdownLink
                value.underlineStyle = .single
                out += value
            case "code":
                var value = AttributedString(attributes?.text("code") ?? "")
                value.font = style.inlineCode
                value.foregroundColor = CommaTheme.markdownInlineCode
                value.backgroundColor = CommaTheme.markdownInlineCodeBackground
                out += value
            case "math":
                // A formula's text is its source: what a selection copies.
                let open = attributes?.string("markup") ?? "$"
                var value = AttributedString(open + (attributes?.text("content") ?? "") + closing(open))
                value.font = style.inlineCode
                out += value
            case "br":
                out += AttributedString("\n")
            case "img":
                let source = attributes?.text("src") ?? ""
                var value = AttributedString(attributes?.string("alt") ?? source)
                if let url = URL(string: source) { value.link = url }
                value.foregroundColor = CommaTheme.markdownLink
                out += value
            case element:
                if let key = attributes?.string("key"), let shown = inline(key) { out += run(shown) }
            case "html_inline":
                out += AttributedString(attributes?.text("raw") ?? "")
            default:
                let nested = children(node)
                out += nested.isEmpty ? AttributedString(attributes?.text("content") ?? "") : text(nested, style: style, inline: inline)
            }
        }
        return out
    }

    /// An inline element as text: a Task chip as the link `MarkdownInline.text` draws as the desktop's inline Task.
    private static func run(_ shown: Inline) -> AttributedString {
        switch shown {
        case .words(let words):
            var value = AttributedString(words)
            value.inlinePresentationIntent = .stronglyEmphasized
            return value
        case .task(let id, let title, let bucket):
            guard let id, let url = URL(string: "comma:task/\(id)" + (bucket.map { "#" + $0.rawValue } ?? "")) else {
                return AttributedString(title)
            }
            var value = AttributedString(title)
            value.link = url
            return value
        }
    }

    private static func trimmed(_ value: AttributedString) -> AttributedString {
        let characters = value.characters
        guard let first = characters.firstIndex(where: { !$0.isWhitespace }),
              let last = characters.lastIndex(where: { !$0.isWhitespace }) else { return AttributedString() }
        return AttributedString(value[first...last])
    }

    private static func closing(_ open: String) -> String {
        switch open {
        case "\\(": "\\)"
        case "\\[": "\\]"
        default: open
        }
    }

    static func kind(_ node: Any) -> String? { (node as? NSArray)?.firstObject as? String }

    static func children(_ node: Any) -> [Any] {
        guard let array = node as? NSArray, array.count > 1, let nested = array[1] as? NSArray else { return [] }
        return nested as? [Any] ?? []
    }

    static func attributes(_ node: Any) -> NSDictionary? {
        guard let array = node as? NSArray, array.count > 1 else { return nil }
        return (array[1] as? NSDictionary) ?? (array.count > 2 ? array[2] as? NSDictionary : nil)
    }

    private static let blockKinds: Set<String> = ["p", "h", "list", "quote", "pre", "mathblock", "table", "hr", "html_block"]
}
