import Foundation

/// A Task picked from the composer's @ menu. The field shows it as `@Title`; the message and the saved draft carry
/// the desktop wire text `[Title](comma:task/<id>)` (app chat/model/mentionSerialization.ts), a self-describing
/// reference the agent reads with no new transport field. The composer keeps a ledger of the Tasks picked into
/// its draft, turns `@Title` back into links on send and save, and reads saved links as `@Title` on restore. A
/// plain text field cannot show atomic pills, so a mention edited by hand degrades to plain text.
public struct TaskMention: Equatable, Hashable, Sendable {
    /// The title as the desktop writes it into the link: brackets become parentheses and whitespace runs one
    /// space, trimmed, falling back to the id.
    public let label: String
    public let conversationID: String

    /// Nil unless `conversationID` is an id the link pattern reads back: `[A-Za-z0-9][A-Za-z0-9._-]*`.
    public init?(title: String, conversationID: String) {
        guard Self.isLinkID(conversationID) else { return nil }
        let words = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .split(whereSeparator: \.isWhitespace)
        self.label = words.isEmpty ? conversationID : words.joined(separator: " ")
        self.conversationID = conversationID
    }

    public var displayText: String { "@" + label }
    public var wireText: String { "[\(label)](comma:task/\(conversationID))" }

    /// `text` with each `@label` a ledger entry still matches replaced by its link. The `@` must start the text or
    /// follow whitespace, and the label must end the text or be followed by neither a letter nor a digit. Longer
    /// labels are tried first, so "@Fix login" is not read as "@Fix"; equal labels go in ledger order. Each entry
    /// is used once, and an entry nothing matches is dropped.
    public static func serialize(_ text: String, mentions: [TaskMention]) -> String {
        var result = "", cursor = text.startIndex
        for link in links(in: text, mentions: mentions) {
            result += text[cursor..<link.range.lowerBound]
            result += link.mention.wireText
            cursor = link.range.upperBound
        }
        return result + text[cursor...]
    }

    /// Where `serialize` links, in text order: each `@label` from its `@`, with the ledger entry it sends.
    public static func links(in text: String, mentions: [TaskMention]) -> [(range: Range<String.Index>, mention: TaskMention)] {
        guard !mentions.isEmpty, text.utf8.contains(UInt8(ascii: "@")) else { return [] }
        var unused = mentions.enumerated().sorted { a, b in
            a.element.label.count != b.element.label.count ? a.element.label.count > b.element.label.count : a.offset < b.offset
        }.map(\.element)
        var links: [(range: Range<String.Index>, mention: TaskMention)] = []
        var index = text.startIndex, afterWhitespace = true
        while index < text.endIndex, !unused.isEmpty {
            let character = text[index], next = text.index(after: index)
            if character == "@", afterWhitespace, let found = firstMatch(unused, at: next, in: text) {
                links.append((index..<found.end, unused.remove(at: found.slot)))
                index = found.end; afterWhitespace = false
                continue
            }
            index = next; afterWhitespace = character.isWhitespace
        }
        return links
    }

    /// The desktop `projectMentionTokens`: each `[Title](comma:task/<id>)` in `text` reads as `@Title` again, and
    /// the mentions come back in order as the ledger. `project(serialize(text, ledger))` returns `text` and the
    /// entries that matched.
    public static func project(_ text: String) -> (text: String, mentions: [TaskMention]) {
        guard text.containsMarker(linkPrefix) else { return (text, []) }
        var result = "", mentions: [TaskMention] = [], cursor = text.startIndex
        for match in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let title = Range(match.range(at: 1), in: text),
                  let id = Range(match.range(at: 2), in: text),
                  let mention = TaskMention(title: String(text[title]), conversationID: String(text[id])) else { continue }
            result += text[cursor..<whole.lowerBound]
            result += mention.displayText
            mentions.append(mention); cursor = whole.upperBound
        }
        result += text[cursor...]
        return (result, mentions)
    }

    /// The Task a sent mention's `comma:task/<id>` link opens; nil for any other URL.
    public static func conversationID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "comma" else { return nil }
        let path = url.absoluteString.dropFirst("comma:".count)
        guard path.hasPrefix("task/") else { return nil }
        let id = String(path.dropFirst("task/".count))
        return isLinkID(id) ? id : nil
    }

    private static let linkPrefix = "comma:task/"
    /// The desktop `TASK_MENTION_PATTERN`.
    private static let link = try! NSRegularExpression(pattern: "\\[([^\\]\\n]+)\\]\\(comma:task/([A-Za-z0-9][A-Za-z0-9._-]*)\\)")

    private static func isLinkID(_ id: String) -> Bool {
        func alphanumeric(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) }
        guard let first = id.unicodeScalars.first, alphanumeric(first) else { return false }
        return id.unicodeScalars.allSatisfy { alphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// The first ledger entry whose label `text` spells from `start`, and where it ends.
    private static func firstMatch(_ ledger: [TaskMention], at start: String.Index, in text: String) -> (slot: Int, end: String.Index)? {
        for (slot, mention) in ledger.enumerated() {
            if let end = end(of: mention.label, at: start, in: text) { return (slot, end) }
        }
        return nil
    }

    /// Where `label` ends when `text` spells it character by character from `start` and no letter or digit
    /// follows; nil otherwise.
    private static func end(of label: String, at start: String.Index, in text: String) -> String.Index? {
        var index = start
        for character in label {
            guard index < text.endIndex, text[index] == character else { return nil }
            index = text.index(after: index)
        }
        guard index == text.endIndex || !(text[index].isLetter || text[index].isNumber) else { return nil }
        return index
    }
}

/// An agent command from the router chat's / menu (the desktop "Agent commands" group). It travels as editable
/// text the server reads from the message (salix_im control_command.ex), so the picker inserts the wire text and
/// a bubble that holds only a command shows it as `/body`.
public enum ControlCommand {
    public static func wireText(_ body: String) -> String { "<salix-command>\(body)</salix-command>" }

    /// `/body` for a text that is one command and nothing else; any other text unchanged. Runs for every user row
    /// on every transcript pass, so a text without the opening tag returns before the regex.
    public static func displayText(_ text: String) -> String {
        guard text.containsMarker(openTag), let match = sole.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let body = Range(match.range(at: 1), in: text) else { return text }
        return "/" + text[body].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let openTag = "<salix-command>"
    private static let sole = try! NSRegularExpression(pattern: "^\\s*<salix-command>([^<]{0,256})</salix-command>\\s*$")
}
