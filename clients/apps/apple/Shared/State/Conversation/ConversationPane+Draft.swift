import Foundation
import CommaCore

/// The draft as the member sees it and as it travels. The field shows a Task picked from the @ menu as `@Title` and
/// an agent command picked from the / menu as `/status`; the ledgers (`ConversationPane+Picks`) turn them back into
/// the desktop's markup on send and save, and saved markup reads as the field showed it when the conversation opens
/// (desktop `projectMentionTokens`). On the Watch the ledgers fill only from a saved draft.
extension ConversationPane {
    /// Keeps the draft, picks included, for the next pane of this conversation.
    func persistDraft() {
        if let target { store?.saveDraft(outgoingDraft, for: target) }
    }

    /// Adds text to the draft after a blank line, like the desktop's appendRecommendationPrompt.
    func appendDraft(_ text: String) {
        draftText = Self.fieldText(draftText.isEmpty ? text : draftText + "\n\n" + text)
    }

    /// Appends a pre-task's prompt as `appendDraft` does and notes it, so the composer reveals it with the fill
    /// motion (desktop `animateDraftFill`). Typing, a restored draft and other inserts never note one.
    func fillDraft(_ text: String) {
        appendDraft(text)
        draftFill = text.isEmpty ? nil : DraftFill(inserted: text)
    }

    /// `text` as UIKit hands the composer's field its text: NSString-backed, its indices counted in UTF-16. The
    /// field reports its caret in such a copy of the draft, while a string built in Swift counts UTF-8, and the
    /// same offset is a different place in non-ASCII text. So a draft written anywhere but the field is this kind.
    static func fieldText(_ text: String) -> String { NSString(string: text) as String }

    /// Installs the saved draft once the conversation loads. Text typed or inserted while the transcript loaded
    /// joins the saved draft instead of replacing it. Send works while the composer is collapsed, so a restored
    /// `/skill` can go before any focus has read the skills catalog: a draft naming one reads it now.
    func restoreDraft(for target: ConversationTarget) {
        let typed = draftText, typedMentions = draftMentions, typedCommands = draftCommands
        let saved = Self.project(store?.draft(for: target) ?? "")
        draftText = Self.fieldText(saved.text)
        draftMentions = saved.mentions
        draftCommands = saved.commands
        if !typed.isEmpty, typed != draftText {
            appendDraft(typed)
            draftMentions += typedMentions
            draftCommands += typedCommands
        }
        if let store, Self.namesSkill(draftText) { Task { await store.skills.loadIfStale(store: store) } }
    }

    /// Whether `text` holds a token the desktop skill pattern could read: `/` at the start or after whitespace,
    /// then an ASCII letter or digit.
    static func namesSkill(_ text: String) -> Bool {
        var afterWhitespace = true, slash = false
        for character in text {
            if slash, character.isASCII, character.isLetter || character.isNumber { return true }
            slash = character == "/" && afterWhitespace
            afterWhitespace = character.isWhitespace
        }
        return false
    }
}

/// Text another surface placed at the end of the draft, which the composer reveals once.
struct DraftFill: Equatable {
    let id = UUID()
    let inserted: String
    let at = ContinuousClock.now

    /// Whether `draft` still ends with the filled text, and the fill is recent enough to reveal. A fill the
    /// composer could not show at once (the router never opened, the keyboard never rose) goes stale.
    func applies(to draft: String, now: ContinuousClock.Instant = .now) -> Bool {
        draft.hasSuffix(inserted) && now - at < .seconds(4)
    }
}
