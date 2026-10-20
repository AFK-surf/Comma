import Foundation
import CommaCore

/// An agent command picked from the router chat's / menu. The field shows it as its sent bubble reads, `/status` or
/// `/cat /path/to/file`, where the desktop shows the wire text. The pane's ledger `draftCommands` turns each `/name`
/// still intact back into `ControlCommand.wireText` on send and save, so the server reads the same
/// `<salix-command>` block, and a saved block reads as `/body` again when the conversation opens. A command that
/// takes a path (ls, cat) runs to the end of its line, so its path is edited in place as plain text and may hold
/// spaces, as the server reads it; a pick puts such a command on a line of its own, so the message goes below it.
struct AgentCommand: Hashable, Sendable {
    let name: String
    let takesPath: Bool

    /// The path the desktop's `cat` row inserts, for the person to replace with a real one.
    static let placeholderPath = "/path/to/file"

    /// Nil for a body with no name or on several lines, which a field line cannot show as one command.
    init?(body: String) {
        let words = body.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = words.first, !body.contains(where: \.isNewline) else { return nil }
        self.name = String(name)
        self.takesPath = words.count > 1
    }

    /// A command as the field shows it once picked, and as `ControlCommand.displayText` shows it sent.
    static func displayText(_ body: String) -> String { "/" + body }

    /// A user message as its bubble and the send flight show it, so it reads as the field did: a message that is one
    /// command reads `/body` as on the desktop, and so does each block in a longer message that a saved draft would
    /// read back as a pick (`project`). Any other text is unchanged.
    static func bubbleText(_ text: String) -> String {
        let whole = ControlCommand.displayText(text)
        return whole != text ? whole : project(text).text
    }

    /// The part one Backspace at its end takes whole, as a picked mention's `@Title`; a path after it is plain text.
    var token: String { "/" + name }

    /// `text` with each `/name` a ledger entry still matches turned into its control text. The `/` must start the
    /// text or follow whitespace, and whitespace or the end must follow the name. Each entry is used once, and an
    /// entry nothing matches is dropped.
    static func serialize(_ text: String, commands: [AgentCommand]) -> String {
        guard !commands.isEmpty else { return text }
        var result = "", cursor = text.startIndex
        for link in links(in: text, commands: commands) {
            result += text[cursor..<link.lowerBound]
            result += ControlCommand.wireText(String(text[text.index(after: link.lowerBound)..<link.upperBound]))
            cursor = link.upperBound
        }
        return result + text[cursor...]
    }

    /// Where each command the ledger sends sits in `text`, from its `/` to the end of its body: the name, and for a
    /// command that takes a path the rest of its line, trailing whitespace left out.
    static func links(in text: String, commands: [AgentCommand]) -> [Range<String.Index>] {
        // Longer names first, so a name that starts another never takes its place.
        var unused = commands.sorted { $0.name.count > $1.name.count }
        var links: [Range<String.Index>] = [], index = text.startIndex, afterWhitespace = true
        while index < text.endIndex, !unused.isEmpty {
            let character = text[index], next = text.index(after: index)
            if character == "/", afterWhitespace,
               let slot = unused.firstIndex(where: { end(of: $0.name, at: next, in: text) != nil }),
               var stop = end(of: unused[slot].name, at: next, in: text) {
                if unused.remove(at: slot).takesPath { stop = lineEnd(after: stop, in: text) }
                links.append(index..<stop)
                index = stop; afterWhitespace = false
                continue
            }
            index = next; afterWhitespace = character.isWhitespace
        }
        return links
    }

    /// Each `<salix-command>body</salix-command>` in `text` that reads back as itself reads as `/body`, and the
    /// commands come back in order as the ledger: one that starts the text or follows whitespace, is followed by
    /// whitespace or the end, and for a path command ends its line. Any other block stays as it was.
    static func project(_ text: String) -> (text: String, commands: [AgentCommand]) {
        // A byte search first: most texts hold no block, and every user bubble passes through here.
        guard text.utf8.firstRange(of: openTag.utf8) != nil else { return (text, []) }
        var result = "", commands: [AgentCommand] = [], cursor = text.startIndex
        for match in block.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let raw = Range(match.range(at: 1), in: text),
                  let command = AgentCommand(body: String(text[raw])),
                  whole.lowerBound == text.startIndex || text[text.index(before: whole.lowerBound)].isWhitespace,
                  whole.upperBound == text.endIndex || text[whole.upperBound].isWhitespace,
                  !command.takesPath || lineEnd(after: whole.upperBound, in: text) == whole.upperBound else { continue }
            result += text[cursor..<whole.lowerBound]
            result += displayText(text[raw].trimmingCharacters(in: .whitespaces))
            commands.append(command); cursor = whole.upperBound
        }
        return (result + text[cursor...], commands)
    }

    private static let openTag = "<salix-command>"
    /// The server's block (salix_im control_command.ex): a body of at most 256 characters and no `<`.
    private static let block = try! NSRegularExpression(pattern: "<salix-command>([^<]{0,256})</salix-command>")

    /// Where `name` ends when `text` spells it from `start` and whitespace or the end follows; nil otherwise.
    private static func end(of name: String, at start: String.Index, in text: String) -> String.Index? {
        var index = start
        for character in name {
            guard index < text.endIndex, text[index] == character else { return nil }
            index = text.index(after: index)
        }
        return index == text.endIndex || text[index].isWhitespace ? index : nil
    }

    /// The end of the line `start` is on, before its trailing whitespace, and never before `start`.
    private static func lineEnd(after start: String.Index, in text: String) -> String.Index {
        var end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
        while end > start, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return end
    }
}
