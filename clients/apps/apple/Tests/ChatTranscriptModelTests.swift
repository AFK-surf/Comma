import XCTest
import CommaCore
@testable import Comma

/// Transcript relationships must match the desktop thread: they decide bubble tails,
/// reply connectors, and whether a sent bubble keeps its identity when committed.
final class ChatTranscriptModelTests: XCTestCase {
    private func message(_ id: String, user: Bool, root: String? = nil, request: String? = nil) -> Message {
        Message(id: id, kind: "message", actorType: user ? "user" : "agent",
                content: [ContentBlock(type: "text", fields: ["text": .string(id)])],
                clientRequestID: request, threadRootMessageID: root, userID: user ? "u1" : nil)
    }

    func testRepliesConnectToTheirThreadAndInterruptedThreadsUseAPreview() {
        let rows = ChatTranscriptModel.rows(messages: [
            message("q1", user: true), message("q2", user: true),
            message("a2", user: false, root: "q2"),
            message("a1", user: false, root: "q1"),
        ], pending: [], draft: nil, isTask: false)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["a2"]?.reply, ChatReply(sourceAnchorID: "a2", targetID: "q2", presentation: .line))
        // a2's connector occupies the interval above a1, so a1 quotes its target instead of crossing it.
        XCTAssertEqual(byID["a1"]?.reply, ChatReply(sourceAnchorID: "a1", targetID: "q1", presentation: .preview))
        XCTAssertEqual(rows.map(\.bubbleTail), [false, true, false, true])
    }

    func testCommittedSendKeepsThePendingRowIdentity() {
        let target = ConversationTarget(workspaceID: "w", groupID: "g", conversationID: "c")
        let attempt = PendingSend(target: target, text: "hello", attachments: [])
        let pending = ChatTranscriptModel.rows(messages: [], pending: [attempt], draft: nil, isTask: false)
        let committed = ChatTranscriptModel.rows(messages: [message("m1", user: true, request: attempt.id)],
                                                 pending: [attempt], draft: nil, isTask: false)
        XCTAssertEqual(pending.map(\.id), [attempt.id])
        XCTAssertEqual(committed.map(\.id), [attempt.id])
    }

    /// Desktop bubble grouping: consecutive prose shares a bubble, code and tables stand alone,
    /// and a thematic break starts a new bubble.
    func testMarkdownSlotsFollowDesktopBubbleGrouping() {
        let text = "# Title\n\nIntro\n\n- one\n- two\n\n> quote\n\n```\ncode\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter\n\n---\n\nNew group"
        let kinds = MarkdownSlot.slots(for: text).map { slot -> String in
            switch slot {
            case .prose(let blocks): "prose(\(blocks.count))"
            case .code: "code"
            case .table: "table"
            }
        }
        XCTAssertEqual(kinds, ["prose(4)", "code", "table", "prose(1)", "prose(1)"])
    }
}
