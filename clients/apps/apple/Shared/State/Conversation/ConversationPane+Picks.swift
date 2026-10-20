import Foundation
import CommaCore

/// What the field shows as plain text and the draft sends as the desktop's markup: a Task picked from the @ menu
/// reads `@Title` and goes as `[Title](comma:task/<id>)`; an agent command picked from the / menu reads `/status` and
/// goes as `<salix-command>status</salix-command>`. A ledger keeps each pick still in the draft. A pick edited by hand
/// no longer matches and goes as the text it now is, since a plain text field cannot hold atomic pills.
extension ConversationPane {
    /// The draft with its picks as the desktop's markup, as it is sent and saved.
    var outgoingDraft: String {
        AgentCommand.serialize(TaskMention.serialize(draftText, mentions: draftMentions), commands: draftCommands)
    }

    /// Saved markup as the field shows it, with the ledgers that send it back as it was.
    static func project(_ markup: String) -> (text: String, mentions: [TaskMention], commands: [AgentCommand]) {
        let commands = AgentCommand.project(markup)
        let mentions = TaskMention.project(commands.text)
        return (mentions.text, mentions.mentions, commands.commands)
    }

    /// The parts of `text` that go as picks rather than as the words typed: each Task the ledger still links, each
    /// agent command, and each skill name the send tags. The field shows them in the brand colour, so a pick reads
    /// as one until an edit makes it plain text again.
    func pickRanges(in text: String) -> [Range<String.Index>] {
        TaskMention.links(in: text, mentions: draftMentions).map(\.range)
            + AgentCommand.links(in: text, commands: draftCommands)
            + Skill.mentions(in: text, catalog: store?.skills.catalog ?? []).map(\.range)
    }

    /// Notes a Task picked at `start` in `text`, the draft as it read before the pick. Equal titles link in ledger
    /// order, so the pick takes its place in the ledger by its place in the text.
    func pick(_ mention: TaskMention, at start: String.Index, in text: String) {
        let slot = Self.ledgerIndex(of: mention.label, at: start, in: text, ledger: draftMentions)
        draftMentions.insert(mention, at: slot ?? draftMentions.endIndex)
    }

    /// Notes a picked agent command. Commands with one name are alike, so their order needs no keeping.
    func pick(_ command: AgentCommand) { draftCommands.append(command) }

    /// One Backspace took the character before `end` from `old`. When that ended a pick the draft still sends, a
    /// mention's `@Title` or a command's `/name`, the pick leaves its ledger and its start comes back, for the caller
    /// to take the whole of it, as deleting a desktop pill does. Nil for any other edit, which leaves the text alone.
    func unpick(endingAt end: String.Index, in old: String) -> String.Index? {
        let before = old[..<end]
        if let mention = draftMentions.last(where: { before.hasSuffix($0.displayText) }) {
            let start = old.index(end, offsetBy: -mention.displayText.count)
            if start == old.startIndex || old[old.index(before: start)].isWhitespace,
               let index = Self.ledgerIndex(of: mention.label, at: start, in: old, ledger: draftMentions) {
                draftMentions.remove(at: index)
                return start
            }
        }
        let named = draftCommands.indices.filter { before.hasSuffix(draftCommands[$0].token) }
        if let index = named.max(by: { draftCommands[$0].name.count < draftCommands[$1].name.count }) {
            let start = old.index(end, offsetBy: -draftCommands[index].token.count)
            if AgentCommand.links(in: old, commands: draftCommands).contains(where: { $0.lowerBound == start }) {
                draftCommands.remove(at: index)
                return start
            }
        }
        return nil
    }

    /// The ledger entry `TaskMention.serialize` links to a mention of `label` at `start`. Entries with equal labels
    /// link in ledger order, so it is the first of them the text before `start` leaves unused; nil when none is.
    private static func ledgerIndex(of label: String, at start: String.Index, in text: String,
                                    ledger: [TaskMention]) -> Int? {
        let linked = TaskMention.project(TaskMention.serialize(String(text[..<start]), mentions: ledger)).mentions
        let used = linked.filter { $0.label == label && ledger.contains($0) }.count
        return ledger.indices.filter { ledger[$0].label == label }.dropFirst(used).first
    }
}
