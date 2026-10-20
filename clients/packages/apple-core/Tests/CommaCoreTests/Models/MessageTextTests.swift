import Foundation
import Testing
@testable import CommaCore

/// `publicText` skips its split and regex when neither marker's bytes are present. The result must be what the
/// original implementation returned, character for character, for every input.
@Suite("Message public text")
struct MessageTextTests {
    /// The implementation before the fast path, kept verbatim as the reference.
    private func referencePublicText(_ text: String) -> String {
        let prefix = text.components(separatedBy: "[[comma-protocol]]").first ?? ""
        return prefix.replacingOccurrences(of: "```comma:[\\s\\S]*?(?:```|$)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain prose, Markdown, CJK, emoji, CRLF, combining marks and near-miss markers, with and without the real ones.
    private static let pieces = [
        "", " ", "\n", "\r\n", "\t", "\u{00A0}", "\u{2028}", "Hello", "你好，有什么可以帮你？", "👩‍👩‍👧", "e\u{301}",
        "Comma", "comma", "a comma, then", "[[comma", "-protocol]]", "``comma:", "```", "```swift\nlet x = 1\n```",
        "```comma:private\ninternal\n```", "```comma:", "\u{1FEF}``comma:x", "``\u{301}`comma:", "```comma:\u{301}x```",
        "[[comma-protocol]]", "[[comma-protocol]]\u{301}", "[\u{301}[comma-protocol]]", "［［comma-protocol］］",
        "[[comma-context]]", " [[comma-context]] rest", "\u{FEFF}[[comma-context]]", "## Heading\n\n- one\n- two",
    ]

    @Test func publicTextMatchesTheReferenceForCraftedInputs() {
        for first in Self.pieces {
            for second in Self.pieces {
                for joiner in ["", " ", "\n"] {
                    let text = first + joiner + second
                    #expect(Message.publicText(text) == referencePublicText(text), "\(text.debugDescription)")
                }
            }
        }
    }

    @Test func publicTextMatchesTheReferenceForGeneratedInputs() {
        var random = SeededRandom(seed: 0xC0FFEE)
        for _ in 0..<4_000 {
            let text = (0..<Int.random(in: 1...6, using: &random)).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
            #expect(Message.publicText(text) == referencePublicText(text), "\(text.debugDescription)")
        }
    }

    @Test func publicTextStillRemovesPrivateFencesAndTheProtocolTail() {
        #expect(Message.publicText("  Public\n```comma:private\ninternal\n```\nReply[[comma-protocol]]hidden \n") == "Public\n\nReply")
        #expect(Message.publicText("Visible ```comma:open fence to the end") == "Visible")
        #expect(Message.publicText("\n  Plain reply.  \n") == "Plain reply.")
    }

    /// The text of a row and of a reply in progress both go through `publicText`.
    @Test func messageAndDraftTextUseThePublicText() {
        let raw = "Answer\n```comma:ref\n{}\n```\n[[comma-protocol]]{\"x\":1}"
        let message = Message(id: "m", kind: "message", actorType: "agent", content: [
            ContentBlock(type: "text", fields: ["text": .string(raw)]), ContentBlock(type: "text", fields: ["text": .string("more")]),
        ])
        #expect(message.text == referencePublicText(raw + "\nmore"))
        let draft = AssistantDraft(conversationID: "c", draftID: "d", responseKey: "r", sourceMessageIDs: ["m"], revision: 1, text: raw)
        #expect(draft.displayText == referencePublicText(raw))
    }
}

/// SplitMix64, so the generated corpus is the same on every run.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
