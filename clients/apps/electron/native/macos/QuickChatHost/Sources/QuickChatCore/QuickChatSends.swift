import Foundation

/// The Messages Main is still sending, and the words waiting for the
/// next Quick Chat: those of Quick Chats closed without sending. Each send
/// waits for its own answer, so sends that overlap never replace one another.
/// A failed send's words are Main's: they wait in the Notch to be sent again,
/// not here. Kept words wait, in the order they were said, until a Quick Chat
/// takes them to continue; Quick Chats that send or are closed in the
/// meantime leave them alone.
public struct QuickChatSends: Sendable {
    private var pending: Set<String> = []
    /// The kept words, in the order they were said.
    private var kept: [String] = []

    public init() {}

    public mutating func send(requestId: String) {
        pending.insert(requestId)
    }

    /// Main's answer for one send. True when the send failed; an answer for
    /// no pending send changes nothing.
    public mutating func result(requestId: String, ok: Bool) -> Bool {
        pending.remove(requestId) != nil && !ok
    }

    /// The words of a Quick Chat that closed without sending them.
    public mutating func keep(_ text: String) {
        guard !text.isEmpty else { return }
        kept.append(text)
    }

    /// The kept words, for a Quick Chat that starts now; they are no longer kept here.
    /// Latin sentences keep a space between them; CJK text has none.
    public mutating func takeDraft() -> String {
        defer { kept = [] }
        return SpeechText.normalized(kept.joined(separator: " "))
    }
}
