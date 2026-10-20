import SwiftUI
import CommaCore

/// The composer's caret and its @ and / menus. Which menu is open, and on what query, is derived from the draft
/// and the caret on every read, so whatever moves either (typing, the caret, a send, a restored draft) opens and
/// closes the menu without bookkeeping. Only the trigger views read it; the composer only hands it on.
@MainActor @Observable
final class TriggerMenuModel {
    /// The field's selection as the field last reported or was given it. It can outlive its text: a send clears
    /// the draft, a restore or a Routine replaces it, and the router keeps one composer across conversations. So
    /// every use checks it against the current draft first.
    var selection: TextSelection?
    /// The composer's distance from the top of the conversation as it shows, which the open menu may not grow past.
    var spaceAbove: CGFloat = 0
    /// The menu closed with Escape, as the desktop's signature: it stays closed until the text changes or the
    /// caret's trigger or query does. Offsets are in UTF-8, so they compare across copies of the text.
    private var dismissal: Dismissal?
    /// The model whose efforts the @ menu shows in place of its list, with the menu they were opened from: they show
    /// only while it stays that menu, so typing, a caret move or a pick returns the list without bookkeeping.
    private var efforts: (modelID: String, menu: Dismissal)?
    /// The draft as the field, or a pick, last wrote it. Any other text came from outside the field (a send, a
    /// restored draft, a Routine), which leaves the caret where the field puts it rather than where it was.
    @ObservationIgnored private var written: String?

    private struct Dismissal: Equatable {
        let trigger: ComposerTrigger
        let start: Int
        let caret: Int
    }

    /// The field's text binding, which notes what the field wrote.
    func textBinding(for pane: ConversationPane) -> Binding<String> {
        Binding(get: { pane.draftText }, set: { [self] in
            written = $0
            pane.draftText = $0
        })
    }

    /// The field's selection binding. It hands the field only a caret that belongs to the current draft, as the
    /// draft's own indices: after a write from outside the field, or for a caret that no longer fits, it hands
    /// none, and the field keeps its own.
    func selectionBinding(for pane: ConversationPane) -> Binding<TextSelection?> {
        Binding(get: { [self] in
            if let written, written != pane.draftText { return nil }
            guard let selection, case .selection(let range) = selection.indices else { return selection }
            guard let valid = ComposerTrigger.validated(range, in: pane.draftText) else { return nil }
            return valid == range ? selection : TextSelection(range: valid)
        }, set: { [self] in selection = $0 })
    }

    /// The open menu, or nil while none is: no trigger before the caret, a range or several ranges selected, or
    /// the menu dismissed with Escape.
    func match(in text: String) -> ComposerTriggerMatch? {
        guard let match = caretMatch(in: text), signature(match, in: text) != dismissal else { return nil }
        return match
    }

    /// The open menu as it shows, with its greatest height: nil also where not even a header and a row fit above
    /// the composer (`fits`). The trigger then stays plain text. The panel and the buttons both read it, so they
    /// never disagree.
    func shown(in text: String, metrics: TriggerMenuMetrics) -> (match: ComposerTriggerMatch, cap: CGFloat)? {
        guard let cap = metrics.cap(below: spaceAbove), let match = match(in: text) else { return nil }
        return (match, cap)
    }

    /// Whether a menu would have room above the composer, a header and a row. Where it would not, the @ and /
    /// buttons leave the row rather than offer a menu that cannot open.
    func fits(_ metrics: TriggerMenuMetrics) -> Bool { metrics.cap(below: spaceAbove) != nil }

    /// Whether the draft reads `text` from outside the field (a send, a restored draft, a Routine) rather than as
    /// typing, a button or a pick last wrote it.
    func isFromOutside(_ text: String) -> Bool { written.map { $0 != text } ?? false }

    /// Escape: closes the open menu until the text or the caret's trigger changes.
    func dismiss(in text: String) {
        dismissal = caretMatch(in: text).map { signature($0, in: text) }
        efforts = nil
    }

    /// A field or pane change: the caret starts over.
    func reset() {
        selection = nil
        dismissal = nil
        efforts = nil
        written = nil
    }

    /// The id of the model whose efforts the open menu shows in place of its list (`showEfforts`); nil on the list.
    func effortsShown(in text: String) -> String? {
        guard let efforts, let match = match(in: text), signature(match, in: text) == efforts.menu else { return nil }
        return efforts.modelID
    }

    /// A model row's chevron: the menu shows that model's efforts in place of its list, as the desktop's second level.
    func showEfforts(of item: TriggerMenuItem, in text: String) {
        guard let model = item.effortsBehind, let match = match(in: text), match.trigger == .mention else { return }
        efforts = (model.id, signature(match, in: text))
    }

    /// The way back: the list again, as the query left it.
    func closeEfforts() { efforts = nil }

    /// A tap on the @ or / button. On a menu closed with Escape it reopens that menu as it is; otherwise it
    /// inserts, removes or swaps the trigger at the caret as `ComposerTrigger.toggling` decides, which can also
    /// close a menu with a query by the button that opened it.
    func tap(_ trigger: ComposerTrigger, pane: ConversationPane) {
        let text = pane.draftText
        if let open = caretMatch(in: text), open.trigger == trigger, signature(open, in: text) == dismissal {
            dismissal = nil
            return
        }
        switch ComposerTrigger.toggling(trigger, in: text, selection: caretRange) {
        case .edit(let edit): apply(edit, to: pane)
        case .dismiss: dismiss(in: text)
        }
    }

    /// A row: its text replaces the trigger and query, as the desktop inserts it, except that a pick reads as its
    /// sent bubble does. A Task reads "@Title", a model "@GPT 5.5" or with the effort picked behind its row
    /// "@GPT 5.5 · high", and a command "/status", and each joins the pane's ledger, which sends it as the desktop's
    /// link or control text; a skill is "/id". A command with a path takes a line of its own (`choosePath`). The text
    /// is matched again, so a tap that arrives after the menu changed does nothing.
    func choose(_ item: TriggerMenuItem, pane: ConversationPane) {
        let text = pane.draftText
        guard let match = match(in: text) else { return }
        switch (item.kind, match.trigger) {
        case (.task(let id, let title, _), .mention):
            let mention = TaskMention(title: title, conversationID: id)
            apply(ComposerTrigger.completing(match, in: text, with: mention?.displayText ?? "@" + title,
                                             trailingSpace: true), to: pane)
            if let mention { pane.pick(mention, at: match.range.lowerBound, in: text) }
        case (.model(let model), .mention):
            chooseModel(model, effort: nil, match: match, in: text, pane: pane)
        case (.effort(let model, let effort), .mention):
            chooseModel(model, effort: effort, match: match, in: text, pane: pane)
        case (.skill(let skill), .skill):
            apply(ComposerTrigger.completing(match, in: text, with: "/" + skill.skillID, trailingSpace: true), to: pane)
        case (.command(_, let body), .skill):
            let command = AgentCommand(body: body)
            if command?.takesPath == true {
                choosePath(body, match: match, in: text, pane: pane)
            } else {
                apply(ComposerTrigger.completing(match, in: text, with: AgentCommand.displayText(body), trailingSpace: true),
                      to: pane)
            }
            if let command { pane.pick(command) }
        default:
            return
        }
    }

    /// Text another surface placed in the draft (a pre-task's prompt) continues where it ends: the caret goes to the
    /// end of the draft, as if the text had been typed, as the desktop's fill leaves it.
    func placeCaretAtEnd(of pane: ConversationPane) {
        let draft = pane.draftText
        written = draft
        selection = TextSelection(insertionPoint: draft.endIndex)
    }

    /// The text changed: a dismissed menu may open again, as on the desktop. Text from outside the field drops the
    /// caret, which the field has put at the end. One Backspace at the end of a picked "@Title" or "/status" takes
    /// the whole pick, as deleting a desktop pill does; any other edit leaves a pick as text the ledger no longer
    /// matches.
    func textDidChange(from old: String, to new: String, pane: ConversationPane) {
        if dismissal != nil { dismissal = nil }
        // Typing returns a model's efforts to the list, even typing that comes back to the same query.
        if efforts != nil { efforts = nil }
        guard new == written else {
            selection = nil
            written = new
            return
        }
        guard !pane.draftMentions.isEmpty || !pane.draftModels.isEmpty || !pane.draftCommands.isEmpty, let cut = Self.deletion(from: old, to: new),
              let start = pane.unpick(endingAt: cut.upperBound, in: old) else { return }
        let edit = String(old[..<start]) + old[cut.upperBound...]
        let caret = edit.index(edit.startIndex, offsetBy: old.distance(from: old.startIndex, to: start))
        write(edit, selecting: caret..<caret, to: pane)
    }

    // MARK: Private

    /// The caret as a range of the field's text, or nil when there is none or several ranges are selected.
    private var caretRange: Range<String.Index>? {
        guard case .selection(let range) = selection?.indices else { return nil }
        return range
    }

    /// The trigger before the caret, dismissed or not. A nil selection is the caret at the end (the field has not
    /// reported one yet); several ranges open nothing, as a range does.
    private func caretMatch(in text: String) -> ComposerTriggerMatch? {
        guard selection != nil else { return ComposerTrigger.match(in: text, selection: nil) }
        return caretRange.flatMap { ComposerTrigger.match(in: text, selection: $0) }
    }

    private func signature(_ match: ComposerTriggerMatch, in text: String) -> Dismissal {
        Dismissal(trigger: match.trigger,
                  start: text.utf8.distance(from: text.startIndex, to: match.range.lowerBound),
                  caret: text.utf8.distance(from: text.startIndex, to: match.range.upperBound))
    }

    private func apply(_ edit: ComposerEdit, to pane: ConversationPane) {
        write(edit.text, selecting: edit.caret..<edit.caret, to: pane)
    }

    /// A model picked at its default effort or at `effort`: the field reads it as its pill, `@GPT 5.5 · high`.
    private func chooseModel(_ model: MentionModel, effort: String?, match: ComposerTriggerMatch, in text: String,
                             pane: ConversationPane) {
        let name = ModelMention.shownName(model.name, effort: effort)
        let mention = ModelMention(name: name, modelID: model.id, effort: effort)
        apply(ComposerTrigger.completing(match, in: text, with: mention?.displayText ?? "@" + name, trailingSpace: true),
              to: pane)
        if let mention { pane.pick(mention, at: match.range.lowerBound, in: text) }
        efforts = nil
    }

    /// A command with a path holds the rest of its line (`AgentCommand.links`), so it takes the line to itself, and
    /// what is typed next is the message, as after the desktop's closing tag: a line break follows it unless one
    /// does already. The desktop's placeholder path comes selected, for typing to replace it; a working path
    /// (`ls /`) leaves the caret on the next line.
    private func choosePath(_ body: String, match: ComposerTriggerMatch, in text: String, pane: ConversationPane) {
        let shown = AgentCommand.displayText(body), end = match.range.upperBound
        let breaks = end < text.endIndex && text[end].isNewline
        let edit = ComposerTrigger.completing(match, in: text, with: shown + (breaks ? "" : "\n"), trailingSpace: false)
        let start = text.utf8.distance(from: text.startIndex, to: match.range.lowerBound)
        let pathEnd = edit.text.utf8.index(edit.text.startIndex, offsetBy: start + shown.utf8.count)
        if body.hasSuffix(" " + AgentCommand.placeholderPath) {
            write(edit.text, selecting: edit.text.utf8.index(pathEnd, offsetBy: -AgentCommand.placeholderPath.utf8.count)..<pathEnd,
                  to: pane)
        } else {
            let next = edit.text.index(after: pathEnd)
            write(edit.text, selecting: next..<next, to: pane)
        }
    }

    /// Writes a draft built here as the field's own kind of string (`ConversationPane.fieldText`), its selection
    /// (a caret, or a range) moved onto it by UTF-16 offset, so the carets the field reports next read at the same
    /// offsets in non-ASCII text.
    private func write(_ text: String, selecting range: Range<String.Index>, to pane: ConversationPane) {
        let draft = ConversationPane.fieldText(text)
        func moved(_ index: String.Index) -> String.Index {
            draft.utf16.index(draft.startIndex, offsetBy: text.utf16.distance(from: text.startIndex, to: index))
        }
        written = draft
        pane.draftText = draft
        selection = range.isEmpty ? TextSelection(insertionPoint: moved(range.lowerBound))
            : TextSelection(range: moved(range.lowerBound)..<moved(range.upperBound))
    }

    /// The one character `new` lost from `old`, as its range in `old`; nil for any other edit.
    private static func deletion(from old: String, to new: String) -> Range<String.Index>? {
        guard old.utf8.count > new.utf8.count else { return nil }
        var (o, n) = (old.startIndex, new.startIndex)
        while o < old.endIndex, n < new.endIndex, old[o] == new[n] { o = old.index(after: o); n = new.index(after: n) }
        guard o < old.endIndex else { return nil }
        let cut = o..<old.index(after: o)
        return old[cut.upperBound...] == new[n...] ? cut : nil
    }
}
