import Foundation

/// A model picked from the router chat's @ menu, to start a Task with it and the rest of the message (desktop
/// `modelMentionPlainText`; the server's `SalixIM.ModelMentionTask`). The field shows it as `@GPT 5.5`, or with the
/// thinking effort picked for it as `@GPT 5.5 · high`; the message and the saved draft carry the desktop wire text
/// `[GPT 5.5](comma:model/gpt-5.5)` or `[GPT 5.5 · high](comma:model/gpt-5.5?effort=high)`. The pane's ledger
/// `draftModels` turns each `@label` still intact back into its link on send and save, as it does a Task's, and a sent
/// one reads `@label` in its bubble, never as a link (desktop `modelMentionsAsWords`).
struct ModelMention: Hashable, Sendable {
    /// The name as the desktop writes it into the link: brackets become parentheses and whitespace runs one space,
    /// trimmed, falling back to the id.
    let label: String
    let modelID: String
    /// The thinking effort picked for it; nil for the model's default.
    let effort: String?

    /// Nil unless the link pattern reads `modelID`, `effort` and the label back.
    init?(name: String, modelID: String, effort: String? = nil) {
        guard Self.matches(modelID, Self.idPattern), effort.map({ Self.matches($0, Self.effortPattern) }) ?? true else {
            return nil
        }
        let words = name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .split(whereSeparator: \.isWhitespace)
        let label = words.isEmpty ? modelID : words.joined(separator: " ")
        guard label.unicodeScalars.count <= 200 else { return nil }
        self.label = label
        self.modelID = modelID
        self.effort = effort
    }

    /// What the menu inserts for `name` at `effort`: the name alone at the default effort, else `name · effort`, as
    /// the desktop's pill reads.
    static func shownName(_ name: String, effort: String?) -> String {
        effort.map { "\(name) · \($0)" } ?? name
    }

    var displayText: String { "@" + label }
    var wireText: String { "[\(label)](\(Self.linkPrefix)\(modelID)\(effort.map { "?effort=" + $0 } ?? ""))" }

    /// `text` with each `@label` a ledger entry still matches replaced by its link, by `TaskMention.serialize`'s
    /// rules: the `@` starts the text or follows whitespace, no letter or digit follows the label, longer labels are
    /// tried first, and each entry is used once.
    static func serialize(_ text: String, models: [ModelMention]) -> String {
        var result = "", cursor = text.startIndex
        for link in links(in: text, models: models) {
            result += text[cursor..<link.range.lowerBound]
            result += link.model.wireText
            cursor = link.range.upperBound
        }
        return result + text[cursor...]
    }

    /// Where `serialize` links, in text order: each `@label` from its `@`, with the ledger entry it sends.
    static func links(in text: String, models: [ModelMention]) -> [(range: Range<String.Index>, model: ModelMention)] {
        MentionLabels.links(in: text, labels: models.map(\.label)).map { ($0.range, models[$0.slot]) }
    }

    /// Each `[label](comma:model/<id>)` in `text` read as `@label` again, with the mentions in order as the ledger
    /// (desktop `projectMentionTokens`). `project(serialize(text, ledger))` returns `text` and the entries that matched.
    static func project(_ text: String) -> (text: String, models: [ModelMention]) {
        guard text.contains(linkPrefix) else { return (text, []) }
        var result = "", models: [ModelMention] = [], cursor = text.startIndex
        for match in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text),
                  let id = Range(match.range(at: 2), in: text),
                  let model = ModelMention(name: String(text[name]), modelID: String(text[id]),
                                           effort: Range(match.range(at: 3), in: text).map { String(text[$0]) })
            else { continue }
            result += text[cursor..<whole.lowerBound]
            result += model.displayText
            models.append(model); cursor = whole.upperBound
        }
        return (result + text[cursor...], models)
    }

    /// Whether `url` is a sent mention's `comma:model/<id>` link, which names a model and opens nothing.
    static func isLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "comma" && url.absoluteString.dropFirst("comma:".count).hasPrefix("model/")
    }

    static let linkPrefix = "comma:model/"
    /// The desktop `MODEL_MENTION_PATTERN`.
    private static let link = try! NSRegularExpression(
        pattern: "\\[([^\\]\\n]{1,200})\\]\\(comma:model/([A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}?)(?:\\?effort=([a-z_]{1,32}))?\\)")
    private static let idPattern = try! NSRegularExpression(pattern: "\\A[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}\\z")
    private static let effortPattern = try! NSRegularExpression(pattern: "\\A[a-z_]{1,32}\\z")

    private static func matches(_ value: String, _ pattern: NSRegularExpression) -> Bool {
        pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

/// Where picked `@label`s sit in a draft, by `TaskMention.links`' rules, for labels of any kind: the `@` starts the
/// text or follows whitespace, and the label ends the text or is followed by neither a letter nor a digit. Longer
/// labels are tried first, so "@GPT 5.5 review" is not read as "@GPT 5.5"; equal labels go in the order given. Each is
/// used once. The pane matches its Tasks and models in one pass with it, so neither kind takes the other's place.
enum MentionLabels {
    /// Each label found, in text order: its range from the `@`, and its index in `labels`.
    static func links(in text: String, labels: [String]) -> [(range: Range<String.Index>, slot: Int)] {
        guard !labels.isEmpty, text.utf8.contains(UInt8(ascii: "@")) else { return [] }
        var unused = labels.indices.sorted { a, b in
            labels[a].count != labels[b].count ? labels[a].count > labels[b].count : a < b
        }
        var links: [(range: Range<String.Index>, slot: Int)] = []
        var index = text.startIndex, afterWhitespace = true
        while index < text.endIndex, !unused.isEmpty {
            let character = text[index], next = text.index(after: index)
            if character == "@", afterWhitespace,
               let position = unused.firstIndex(where: { end(of: labels[$0], at: next, in: text) != nil }),
               let stop = end(of: labels[unused[position]], at: next, in: text) {
                links.append((index..<stop, unused.remove(at: position)))
                index = stop; afterWhitespace = false
                continue
            }
            index = next; afterWhitespace = character.isWhitespace
        }
        return links
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
