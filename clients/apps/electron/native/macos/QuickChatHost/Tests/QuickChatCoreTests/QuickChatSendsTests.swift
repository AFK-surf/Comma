import Testing
@testable import QuickChatCore

struct QuickChatSendsTests {
    @Test func overlappingSendsEachWaitForTheirOwnAnswer() {
        var sends = QuickChatSends()
        sends.send(requestId: "a")
        sends.send(requestId: "b")
        let first = sends.result(requestId: "a", ok: false)
        let second = sends.result(requestId: "b", ok: true)
        // The failed send's words wait in the Notch, not for the next Quick Chat.
        let draft = sends.takeDraft()
        #expect(first && !second)
        #expect(draft == "")
    }

    @Test func aSuccessKeepsNothing() {
        var sends = QuickChatSends()
        sends.send(requestId: "a")
        let succeeded = sends.result(requestId: "a", ok: true)
        // Answered once; a repeated or unknown answer changes nothing.
        let repeated = sends.result(requestId: "a", ok: false)
        let unknown = sends.result(requestId: "c", ok: false)
        let draft = sends.takeDraft()
        #expect(!succeeded && !repeated && !unknown)
        #expect(draft == "")
    }

    @Test func wordsOfAQuickChatClosedWithoutSendingWaitForTheNextOne() {
        var sends = QuickChatSends()
        sends.send(requestId: "a")
        // Closed by accident while the first send is still being created.
        sends.keep("Remind me at three")
        sends.keep("")
        _ = sends.result(requestId: "a", ok: false)
        let draft = sends.takeDraft()
        let after = sends.takeDraft()
        #expect(draft == "Remind me at three")
        #expect(after == "")
    }

    @Test func keptTextReadsInTheOrderItWasSaid() {
        var sends = QuickChatSends()
        for words in ["Book the room.", "Remind me at three", "帮我订会议室。", "提醒我开会"] {
            sends.keep(words)
        }
        let draft = sends.takeDraft()
        #expect(draft == "Book the room. Remind me at three 帮我订会议室。提醒我开会")
    }
}
