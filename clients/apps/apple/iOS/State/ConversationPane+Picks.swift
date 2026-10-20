import Foundation
import CommaCore

/// What the field shows as plain text and the draft sends as the desktop's markup: a Task picked from the @ menu
/// reads `@Title` and goes as `[Title](comma:task/<id>)`; a model picked from the router's @ menu reads `@GPT 5.5` (or
/// `@GPT 5.5 · high`) and goes as `[GPT 5.5](comma:model/<id>)` (or with `?effort=high`); an agent command picked from
/// the / menu reads `/status` and goes as `<salix-command>status</salix-command>`. A ledger keeps each pick still in
/// the draft. A pick edited by hand no longer matches and goes as the text it now is, since a plain text field cannot
/// hold atomic pills.
extension ConversationPane {
    /// The draft with its picks as the desktop's markup, as it is sent and saved.
    var outgoingDraft: String {
        var result = "", cursor = draftText.startIndex
        for link in mentionLinks(in: draftText) {
            result += draftText[cursor..<link.range.lowerBound]
            result += link.wireText
            cursor = link.range.upperBound
        }
        return AgentCommand.serialize(result + draftText[cursor...], commands: draftCommands)
    }

    /// Saved markup as the field shows it, with the ledgers that send it back as it was.
    static func project(_ markup: String)
        -> (text: String, mentions: [TaskMention], models: [ModelMention], commands: [AgentCommand]) {
        let commands = AgentCommand.project(markup)
        let mentions = TaskMention.project(commands.text)
        let models = ModelMention.project(mentions.text)
        return (models.text, mentions.mentions, models.models, commands.commands)
    }

    /// The parts of `text` that go as picks rather than as the words typed: each Task and model the ledgers still
    /// link, each agent command, and each skill name the send tags. The field shows them in the brand colour, so a
    /// pick reads as one until an edit makes it plain text again.
    func pickRanges(in text: String) -> [Range<String.Index>] {
        mentionLinks(in: text).map(\.range)
            + AgentCommand.links(in: text, commands: draftCommands)
            + Skill.mentions(in: text, catalog: store?.skills.catalog ?? []).map(\.range)
    }

    /// Notes a Task picked at `start` in `text`, the draft as it read before the pick. Equal titles link in ledger
    /// order, so the pick takes its place in the ledger by its place in the text.
    func pick(_ mention: TaskMention, at start: String.Index, in text: String) {
        let slot = Self.ledgerIndex(of: mention.label, at: start, in: text, ledger: draftMentions)
        draftMentions.insert(mention, at: slot ?? draftMentions.endIndex)
    }

    /// Notes a model picked at `start` in `text`, as `pick(_:at:in:)` notes a Task.
    func pick(_ model: ModelMention, at start: String.Index, in text: String) {
        let slot = Self.ledgerIndex(of: model.label, at: start, in: text, ledger: draftModels)
        draftModels.insert(model, at: slot ?? draftModels.endIndex)
    }

    /// Notes a picked agent command. Commands with one name are alike, so their order needs no keeping.
    func pick(_ command: AgentCommand) { draftCommands.append(command) }

    /// One Backspace took the character before `end` from `old`. When that ended a pick the draft still sends, a
    /// mention's `@Title`, a model's `@GPT 5.5` or a command's `/name`, the pick leaves its ledger and its start comes
    /// back, for the caller to take the whole of it, as deleting a desktop pill does. Nil for any other edit, which
    /// leaves the text alone.
    func unpick(endingAt end: String.Index, in old: String) -> String.Index? {
        if let link = mentionLinks(in: old).last(where: { $0.range.upperBound == end }) {
            switch link.pick {
            case .task(let mention):
                if let index = Self.ledgerIndex(of: mention.label, at: link.range.lowerBound, in: old, ledger: draftMentions) {
                    draftMentions.remove(at: index)
                    return link.range.lowerBound
                }
            case .model(let model):
                if let index = Self.ledgerIndex(of: model.label, at: link.range.lowerBound, in: old, ledger: draftModels) {
                    draftModels.remove(at: index)
                    return link.range.lowerBound
                }
            }
        }
        let before = old[..<end]
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

    /// A Task or a model a ledger links.
    enum MentionPick {
        case task(TaskMention)
        case model(ModelMention)
    }

    /// Where the Tasks and models the ledgers still link sit in `text`, in text order, matched in one pass so a longer
    /// label of either kind is read first (`MentionLabels`); Tasks come before models of an equal label.
    func mentionLinks(in text: String) -> [(range: Range<String.Index>, pick: MentionPick, wireText: String)] {
        let picks = draftMentions.map(MentionPick.task) + draftModels.map(MentionPick.model)
        let labels = picks.map { pick in
            switch pick {
            case .task(let mention): mention.label
            case .model(let model): model.label
            }
        }
        return MentionLabels.links(in: text, labels: labels).map { link in
            let pick = picks[link.slot]
            switch pick {
            case .task(let mention): return (link.range, pick, mention.wireText)
            case .model(let model): return (link.range, pick, model.wireText)
            }
        }
    }

    /// The ledger entry linked to a pick of `label` at `start`. Entries with equal labels link in ledger order, so it
    /// is the first of them the text before `start` leaves unused; nil when none is.
    private static func ledgerIndex(of label: String, at start: String.Index, in text: String,
                                    ledger: [TaskMention]) -> Int? {
        let linked = TaskMention.project(TaskMention.serialize(String(text[..<start]), mentions: ledger)).mentions
        let used = linked.filter { $0.label == label && ledger.contains($0) }.count
        return ledger.indices.filter { ledger[$0].label == label }.dropFirst(used).first
    }

    private static func ledgerIndex(of label: String, at start: String.Index, in text: String,
                                    ledger: [ModelMention]) -> Int? {
        let used = ModelMention.links(in: String(text[..<start]), models: ledger).filter { $0.model.label == label }.count
        return ledger.indices.filter { ledger[$0].label == label }.dropFirst(used).first
    }
}
