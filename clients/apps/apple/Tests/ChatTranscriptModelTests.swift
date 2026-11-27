import SwiftUI
import UIKit
import XCTest
import CommaCore
@testable import Comma

/// Transcript relationships must match the desktop thread: they decide bubble tails, reply connectors, and whether a
/// sent bubble keeps its identity when committed. The rows come from `chatView` values as the core gives them, read by
/// `ChatViewReader`.
final class ChatTranscriptModelTests: XCTestCase {
    private func message(_ id: String, user: Bool, root: String? = nil, request: String? = nil, reply: String? = nil,
                         text: String? = nil, display: [String: Any]? = nil) -> [String: Any] {
        var json: [String: Any] = ["messageId": id, "role": user ? "user" : "assistant", "actorType": user ? "user" : "agent",
                                   "text": text ?? id]
        if user { json["createdBy"] = "u1" }
        if let root { json["threadRootMessageId"] = root }
        if let request { json["clientRequestId"] = request }
        if let reply { json["replyToMessageId"] = reply }
        if let display { json["display"] = display }
        return json
    }

    private func pending(_ id: String, text: String, reply: String? = nil) -> [String: Any] {
        var json: [String: Any] = ["clientRequestId": id, "text": text, "status": "sending"]
        if let reply { json["replyToMessageId"] = reply }
        return json
    }

    private func draft(_ id: String, sources: [String], text: String) -> [String: Any] {
        ["draftId": id, "responseKey": "r-" + id, "sourceMessageIds": sources, "text": text, "status": "streaming"]
    }

    /// The timeline of a `chatView` value with these messages, sends under way and streamed reply.
    private func timeline(_ messages: [[String: Any]], pending: [[String: Any]] = [], shown: [[String: Any]] = [],
                          draft: [String: Any]? = nil, reader: ChatViewReader = ChatViewReader()) -> [ChatEntry] {
        var state: [String: Any] = ["status": "ready", "serverMessages": messages, "pending": pending, "messages": shown]
        if let draft { state["assistantDraft"] = draft }
        let value = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: ["revision": 1, "state": state]))
        return reader.read(value).timeline
    }

    private func rows(_ messages: [[String: Any]], pending: [[String: Any]] = [], shown: [[String: Any]] = [],
                      draft: [String: Any]? = nil, activity: String? = nil, identity: ReplyRowIdentity = ReplyRowIdentity()) -> [ChatRow] {
        ChatTranscriptModel.rows(timeline: timeline(messages, pending: pending, shown: shown, draft: draft), isTask: false,
                                 activity: activity, identity: identity)
    }

    /// In a Task together, another person's message is not the account's own: it sits on the left under their name.
    /// It was drawn as the account's own, on the right, because only user and Agent messages were told apart.
    func testAnotherPersonsMessageInATaskTogetherIsNotTheAccountsOwn() {
        var theirs = message("m2", user: true)
        theirs["createdBy"] = "u2"
        let rows = ChatTranscriptModel.rows(timeline: timeline([message("m1", user: true), theirs, message("m3", user: false)]),
                                            isTask: true, selfID: "u1")
        XCTAssertEqual(rows.map(\.isMine), [true, false, false])
        XCTAssertEqual(rows.map(\.otherWriter), [nil, "u2", nil])
        XCTAssertTrue(rows[0].groupLast && rows[1].groupFirst, "Each writer starts their own group")

        // The Router's chat calls its one user "current"; that is the account.
        var router = message("r1", user: true)
        router["createdBy"] = "current"
        XCTAssertTrue(ChatTranscriptModel.rows(timeline: timeline([router]), isTask: false, selfID: "u1")[0].isMine)
    }

    private func items(_ messages: [[String: Any]]) -> [ChatItem] {
        timeline(messages).compactMap { if case .message(_, let item) = $0 { item } else { nil } }
    }

    /// An Agent message that asks a question card, as the core gives it: the card is a part, not text.
    private func question(_ id: String, state: [String: Any] = ["status": "open"]) -> [String: Any] {
        var json = message(id, user: false, text: "")
        json["parts"] = [["kind": "question", "messageId": id, "prompt": "这两个会怎么处理？",
                          "choices": [["id": "c1", "label": "Merge", "description": "Keep both?", "reply": "Merge them.", "recommended": true],
                                      ["id": "c2", "label": "Drop"]],
                          "multiSelect": false, "allowOther": true, "state": state]]
        return json
    }

    /// `value` as Foundation's objects, as the core client gives them.
    private func foundation(_ value: Any) -> Any {
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value))
    }

    private func chatDraft(_ json: [String: Any]) -> ChatDraft {
        timeline([], draft: json).compactMap { if case .draft(_, let draft) = $0 { draft } else { nil } }[0]
    }

    func testRepliesConnectToTheirThreadAndInterruptedThreadsUseAPreview() {
        let rows = rows([
            message("q1", user: true), message("q2", user: true),
            message("a2", user: false, root: "q2"),
            message("a1", user: false, root: "q1"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(byID["a2"]?.reply, ChatReply(sourceAnchorID: "a2", targetID: "q2", presentation: .line))
        // a2's connector occupies the interval above a1, so a1 quotes its target instead of crossing it.
        XCTAssertEqual(byID["a1"]?.reply, ChatReply(sourceAnchorID: "a1", targetID: "q1", presentation: .preview, targetText: "q1"))
        XCTAssertEqual(rows.map(\.bubbleTail), [false, true, false, true])
    }

    /// A preview quotes its target on one line, at most 180 characters, as splitting and joining the whole text would.
    func testPreviewQuoteCollapsesWhitespaceAndStopsAtTheLimit() {
        let long = String(repeating: "word \n\t ", count: 400)
        for text in ["", "  \n ", " one\n\ntwo  three ", long, String(repeating: "x", count: 179) + " y z", String(repeating: "é", count: 500)] {
            let expected = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(180))
            XCTAssertEqual(ChatTranscriptModel.quote(text), expected)
        }
    }

    /// An open reply thread shows only its own messages, without connectors, and a reply still being sent joins it
    /// through its parent.
    func testReplyThreadGathersItsMessagesAndAPendingReply() {
        let rows = rows([
            message("q1", user: true), message("q2", user: true),
            message("a2", user: false, root: "q2"), message("a1", user: false, root: "q1"),
        ], pending: [pending("s1", text: "shorter please", reply: "a1")])
        let thread = ChatTranscriptModel.thread(rows, root: "q1")
        XCTAssertEqual(thread.map(\.id), ["q1", "a1", "s1"])
        // Gathered together they are visibly one thread: no connectors or previews there.
        XCTAssertTrue(thread.allSatisfy { $0.reply == nil })
        // In the transcript the member's reply connects to the message it answers where nothing interrupts it;
        // a member's own new message still starts a thread of its own.
        XCTAssertEqual(rows.last?.reply, ChatReply(sourceAnchorID: "s1", targetID: "a1", presentation: .line))
        XCTAssertNil(rows.first { $0.id == "q2" }?.reply)
    }

    /// Once an Agent answers a member's reply, the reply's hook gives way to one line between the two Agent messages.
    func testAgentAnsweringAMemberReplyConnectsToTheMessageThatReplyAnswered() {
        let rows = rows([
            message("q1", user: true), message("a1", user: false, root: "q1"),
            message("u2", user: true, root: "q1"), message("a2", user: false, root: "q1"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertNil(byID["u2"]?.reply)
        XCTAssertEqual(byID["a2"]?.reply, ChatReply(sourceAnchorID: "a2", targetID: "a1", presentation: .line))
    }

    func testCommittedSendKeepsThePendingRowIdentity() {
        let sending = rows([], pending: [pending("s1", text: "hello")])
        let committed = rows([message("m1", user: true, request: "s1", text: "hello")], pending: [pending("s1", text: "hello")])
        XCTAssertEqual(sending.map(\.id), ["s1"])
        XCTAssertEqual(committed.map(\.id), ["s1"])
    }

    /// The thinking bubble, the streamed draft and the committed reply are one row: the bubble updates in place
    /// and plays no second entrance. The next reply gets a row of its own.
    func testStreamedReplyKeepsOneRowFromThinkingToCommitted() {
        var identity = ReplyRowIdentity()
        let question = message("q1", user: true)
        let thinking = rows([question], activity: "Thinking…", identity: identity)
        let partial = draft("d1", sources: ["q1"], text: "Partial answer")
        let streaming = rows([question], draft: partial, identity: identity)
        let reply = message("a1", user: false, reply: "q1", text: "Full answer")
        identity.handOff(chatDraft(partial), from: items([question]), to: items([question, reply]))
        let committed = rows([question, reply], identity: identity)
        XCTAssertEqual(thinking.last?.id, streaming.last?.id)
        XCTAssertEqual(streaming.last?.id, committed.last?.id)
        XCTAssertEqual(committed.last?.text, "Full answer")
        let next = rows([question, reply, message("q2", user: true)], activity: "Thinking…", identity: identity)
        XCTAssertEqual(Set(next.map(\.id)).count, next.count, "The next reply's row cannot reuse the committed one")
    }

    /// Without a reply naming the draft's sources, only a single new reply can take the draft's row.
    func testDraftRowIsNotGuessedAmongSeveralNewReplies() {
        var identity = ReplyRowIdentity()
        let partial = chatDraft(draft("d1", sources: ["q1"], text: "Partial"))
        let before = identity
        identity.handOff(partial, from: [], to: items([message("x1", user: false), message("x2", user: false)]))
        XCTAssertEqual(identity, before)
        let only = items([message("x1", user: false)])
        identity.handOff(partial, from: [], to: only)
        XCTAssertEqual(identity.rowID(for: only[0]), before.live)
        XCTAssertNotEqual(identity.live, before.live)
    }

    /// A member's agent command reads as `/command`, as the core shows it; an agent's text stays as written, and a
    /// reply quotes the command as the bubble shows it.
    func testUserCommandShowsAsSlash() {
        let command = ControlCommand.wireText("ls /")
        let rows = rows([
            message("q1", user: true, text: command, display: ["command": "ls /"]), message("q2", user: true),
            message("a2", user: false, root: "q2", text: command), message("a1", user: false, root: "q1"),
        ])
        XCTAssertEqual(rows.map(\.text), ["/ls /", "q2", command, "a1"])
        XCTAssertEqual(rows[3].reply?.targetText, "/ls /")
    }

    /// A send under way reads as the core shows it: a command as `/command`, quoted passages ahead.
    func testPendingSendReadsAsTheCoreShowsIt() {
        let rows = rows([], pending: [pending("s1", text: ControlCommand.wireText("status")), pending("s2", text: "raw")],
                        shown: [["source": "pending", "clientRequestId": "s1", "display": ["command": "status"]],
                                ["source": "pending", "clientRequestId": "s2", "display": ["body": "why?", "quotes": ["a\nb"]]]])
        XCTAssertEqual(rows.map(\.text), ["/status", "> a\n> b\n\nwhy?"])
    }

    /// A Routine item sent as an attached text shows as its chip ahead of the words, sent or still sending, and a
    /// message that is nothing but one still shows.
    func testAttachedTextShowsAsChip() {
        let texts: [[String: Any]] = [["source": "Linear", "text": "\n  Review   COMMA-1\n\nhttps://linear.app"], ["text": "Reply to Dana"]]
        let rows = rows([message("m1", user: true, display: ["body": "", "quotes": [], "texts": texts]),
                         message("m2", user: true, display: ["body": "Start", "quotes": [], "texts": [texts[1]]])],
                        pending: [pending("s1", text: "raw")],
                        shown: [["source": "pending", "clientRequestId": "s1", "display": ["body": "Now", "texts": [texts[1]]]]])
        XCTAssertEqual(rows.map(\.text), ["", "Start", "Now"])
        XCTAssertEqual(rows[0].attachedTexts, [ChatAttachedText(source: "Linear", text: "\n  Review   COMMA-1\n\nhttps://linear.app"),
                                              ChatAttachedText(source: nil, text: "Reply to Dana")])
        XCTAssertEqual(rows[0].attachedTexts.map(\.title), ["Review COMMA-1", "Reply to Dana"])
        XCTAssertEqual(rows[1].attachedTexts.map(\.title), ["Reply to Dana"])
        XCTAssertEqual(rows[2].attachedTexts.map(\.title), ["Reply to Dana"])
    }

    /// An Agent's question reads as a card with its choices and state, even with no text of its own, and takes the
    /// last bubble's tail; a part that is not a whole question shows nothing.
    @MainActor func testQuestionPartReadsAsACard() throws {
        let item = try XCTUnwrap(items([question("q1")]).first)
        let card = try XCTUnwrap(item.question)
        XCTAssertEqual(card.messageID, "q1")
        XCTAssertEqual(card.prompt, "这两个会怎么处理？")
        XCTAssertEqual(card.choices, [ChatQuestion.Choice(id: "c1", label: "Merge", description: "Keep both?", recommended: true),
                                      ChatQuestion.Choice(id: "c2", label: "Drop", description: nil, recommended: false)])
        XCTAssertFalse(card.multiSelect)
        XCTAssertTrue(card.allowOther)
        XCTAssertEqual(card.state, ChatQuestion.State(status: .open))
        XCTAssertTrue(MessageExtras.hasContent(item))
        XCTAssertFalse(MessageExtras.hasChips(item))

        var single = question("q2", state: ["status": "failed", "choiceIds": ["c2"], "other": "", "error": "Offline"])
        XCTAssertEqual(items([single]).first?.question?.state,
                       ChatQuestion.State(status: .failed, choiceIDs: ["c2"], other: "", error: "Offline"))
        XCTAssertFalse(try XCTUnwrap(items([single]).first?.question?.independent))
        XCTAssertNil(items([single]).first?.question?.skipBehavior)

        // Single-choice independent Monoid confirmation card (1..6 choices allowed, skipBehavior: "dismiss").
        var monoid = message("q_monoid", user: false, text: "")
        monoid["parts"] = [["kind": "question", "messageId": "q_monoid", "prompt": "Approve staging deploy?",
                            "choices": [["id": "c1", "label": "Approve", "recommended": true]],
                            "multiSelect": false, "allowOther": false,
                            "skipBehavior": "dismiss", "independent": true,
                            "state": ["status": "open"]]]
        let monoidCard = try XCTUnwrap(items([monoid]).first?.question)
        XCTAssertEqual(monoidCard.choices, [ChatQuestion.Choice(id: "c1", label: "Approve", description: nil, recommended: true)])
        XCTAssertEqual(monoidCard.skipBehavior, "dismiss")
        XCTAssertTrue(monoidCard.independent)

        // Zero choices or more than 6 choices are rejected as incomplete questions.
        single["text"] = "Fallback"
        single["parts"] = [["kind": "question", "messageId": "q2", "prompt": "No choices", "choices": [],
                            "multiSelect": false, "allowOther": true, "state": ["status": "open"]]]
        let emptyFallback = try XCTUnwrap(items([single]).first)
        XCTAssertNil(emptyFallback.question)
        XCTAssertEqual(emptyFallback.parts, [.other])

        single["parts"] = [["kind": "question", "messageId": "q3", "prompt": "Too many",
                            "choices": (1...7).map { ["id": "c\($0)", "label": "Option \($0)"] },
                            "multiSelect": false, "allowOther": false, "state": ["status": "open"]]]
        let overflowFallback = try XCTUnwrap(items([single]).first)
        XCTAssertNil(overflowFallback.question)
        XCTAssertEqual(overflowFallback.parts, [.other])
    }

    /// Independent Monoid cards stay open alongside later ordinary questions without local replacement.
    func testIndependentQuestionCardsRemainOpenAlongsideLaterQuestions() throws {
        var independent = message("q_monoid", user: false, text: "")
        independent["parts"] = [["kind": "question", "messageId": "q_monoid", "prompt": "Confirm Monoid action?",
                                 "choices": [["id": "c1", "label": "Confirm"]],
                                 "multiSelect": false, "allowOther": false,
                                 "skipBehavior": "dismiss", "independent": true,
                                 "state": ["status": "open"]]]
        let later = question("q_router", state: ["status": "open"])
        let parsed = items([independent, later])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].question?.independent, true)
        XCTAssertEqual(parsed[0].question?.skipBehavior, "dismiss")
        XCTAssertEqual(parsed[0].question?.state.status, .open)
        XCTAssertEqual(parsed[1].question?.independent, false)
        XCTAssertEqual(parsed[1].question?.state.status, .open)
    }

    /// A person's answer to a card shows only its own words: its `question-answer` part draws nothing.
    func testQuestionAnswerPartShowsOnlyTheMessageWords() {
        var answer = message("a1", user: true, reply: "q1", display: ["body": "Merge them.", "quotes": [], "files": []])
        answer["parts"] = [["kind": "question-answer", "questionMessageId": "q1", "choiceIds": ["c1"], "skipped": false]]
        let rows = rows([question("q1"), answer])
        XCTAssertEqual(rows.map(\.text), ["", "Merge them."])
        XCTAssertEqual(rows.last?.message?.parts, [.other])
        XCTAssertNil(rows.last?.message?.question)
    }

    /// The card stands where the core says it does in the server's messages, this device's sends counted; each new
    /// state changes the message, and so its row.
    func testQuestionStateChangesTheMessage() throws {
        let reader = ChatViewReader()
        func read(_ state: [String: Any]) throws -> ChatItem {
            let value: NSDictionary = ["revision": 1, "state": ["status": "ready", "serverMessages": foundation([question("q1", state: state)])] as [String: Any]]
            let items = reader.read(value).timeline.compactMap { if case .message(_, let item) = $0 { item } else { nil } }
            return try XCTUnwrap(items.first)
        }
        let open = try read(["status": "open"])
        XCTAssertEqual(open.question?.state, ChatQuestion.State(status: .open))
        let sending = try read(["status": "sending", "choiceIds": ["c1"]])
        XCTAssertEqual(sending.question?.state, ChatQuestion.State(status: .sending, choiceIDs: ["c1"]))
        XCTAssertNotEqual(open, sending)
        let answered = try read(["status": "answered", "choiceIds": ["c1"]])
        XCTAssertEqual(answered.question?.state, ChatQuestion.State(status: .answered, choiceIDs: ["c1"]))
        XCTAssertNotEqual(sending, answered)

        let row = { (item: ChatItem) in ChatTranscriptModel.rows(timeline: [.message(key: "m:q1", item)], isTask: false) }
        XCTAssertNotEqual(row(open), row(answered))
    }

    /// A sent Task mention reads `@Title` in semibold and links to the Task, in the bubble and in the send flight
    /// alike; other links and Markdown draw as before, and an agent command flies as `/command`.
    @MainActor func testSentMentionReadsAsAtTitle() throws {
        let mention = try XCTUnwrap(TaskMention(title: "Fix [login] bug", conversationID: "cnv1_abc"))
        let text = MessageBubbles.inline("Ask \(mention.wireText) and *see* [docs](https://comma.surf)")
        XCTAssertEqual(String(text.characters), "Ask @Fix (login) bug and see docs")
        let links = text.runs[\.link].compactMap { link, range in link.map { ($0.absoluteString, String(text[range].characters)) } }
        XCTAssertEqual(links.map(\.0), ["comma:task/cnv1_abc", "https://comma.surf"])
        XCTAssertEqual(links.map(\.1), ["@Fix (login) bug", "docs"])
        let semibold = text.runs[AttributeScopes.SwiftUIAttributes.FontAttribute.self]
            .filter { $0.0 == CommaTheme.messageFont.weight(.semibold) }
            .map { String(text[$0.1].characters) }
        XCTAssertEqual(semibold, ["@Fix (login) bug"], "Only the mention, the @ included, is semibold")
        let plain = "Plain **bold** and comma:task/cnv1_abc"
        XCTAssertEqual(MessageBubbles.inline(plain),
                       try AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))

        let flight = OutgoingFlightController()
        flight.launch(id: "s1", text: "Ask \(mention.wireText)", radius: 20)
        XCTAssertEqual(flight.flight.map { String($0.text.characters) }, "Ask @Fix (login) bug")
        XCTAssertEqual(flight.flight?.text, MessageBubbles.inline("Ask \(mention.wireText)"), "The flight draws what lands")
        flight.launch(id: "s2", text: ControlCommand.wireText("compact"), radius: 20)
        XCTAssertEqual(flight.flight.map { String($0.text.characters) }, "/compact")
    }

    @MainActor func testDynamicUICardPreviewAndTitleDeduplication() {
        XCTAssertNil(DynamicUIChatCard.previewText(for: "   \n\n  "))
        XCTAssertEqual(
            DynamicUIChatCard.previewText(for: "  附近8家咖啡店  \n\n  瑰機咖啡约60米  \n"),
            "附近8家咖啡店\n瑰機咖啡约60米"
        )
        XCTAssertEqual(
            DynamicUIChatCard.subtitleText(
                for: "附近8家咖啡店，按OpenStreetMap坐标直线距离排序：瑰機咖啡约60米",
                title: "附近 8 家咖啡店"
            ),
            "按OpenStreetMap坐标直线距离排序：瑰機咖啡约60米"
        )
        XCTAssertNil(
            DynamicUIChatCard.subtitleText(for: "附近 8 家咖啡店", title: "附近 8 家咖啡店")
        )
        XCTAssertEqual(
            DynamicUIChatCard.subtitleText(for: "香港本周末天气 · 周六阴", title: "周末天气"),
            "香港本周末天气 · 周六阴"
        )
    }

    @MainActor func testDynamicUISheetTitlePrefersCardTitleAndNestedCardTitle() {
        XCTAssertEqual(
            PhoneDynamicUIModel.sheetTitle(for: nil, preferredTitle: "  附近 8 家咖啡店  "),
            "附近 8 家咖啡店"
        )
        let nested: NSDictionary = [
            "data": [
                "coffee_list": [
                    "title": "附近 8 家咖啡店",
                    "items": []
                ]
            ]
        ]
        XCTAssertEqual(
            PhoneDynamicUIModel.sheetTitle(for: nested, preferredTitle: nil),
            "附近 8 家咖啡店"
        )
        let flat: NSDictionary = ["data": ["title": "周末天气"]]
        XCTAssertEqual(
            PhoneDynamicUIModel.sheetTitle(for: flat, preferredTitle: nil),
            "周末天气"
        )
        XCTAssertEqual(
            PhoneDynamicUIModel.sheetTitle(for: nil, preferredTitle: nil, fallback: "Interactive content"),
            "Interactive content"
        )
    }

    @MainActor func testDynamicUICardClampsLongSummaryHeightForTitledAndLegacyCards() {
        let longSummary = String(repeating: "附近8家咖啡店，按OpenStreetMap坐标直线距离排序：瑰機咖啡约60米；MOBYS约450米；星巴克约520米。", count: 8)
        let titled = PhoneDynamicUI(
            id: "ui-titled",
            conversation: "cnv-1",
            message: "msg-1",
            index: 0,
            title: "附近 8 家咖啡店",
            summary: longSummary
        )
        let legacy = PhoneDynamicUI(
            id: "ui-legacy",
            conversation: "cnv-1",
            message: "msg-2",
            index: 0,
            title: nil,
            summary: longSummary
        )
        for ui in [titled, legacy] {
            let controller = UIHostingController(rootView: DynamicUIChatCard(ui: ui, disabled: false, open: {}))
            let size = controller.sizeThatFits(in: CGSize(width: 318, height: 1000))
            XCTAssertGreaterThan(size.height, 44)
            XCTAssertLessThan(size.height, 140)
        }
    }

    /// A missing or zero-sized target anchor must skip its connector rather than drawing a line from y = 0
    /// across earlier turns; a textless attachment-only user message with a content rect still draws its hook.
    func testReplyConnectorsSkipMissingOrEmptyTargetsAndAnchorToContentBounds() {
        let rows = rows([
            message("u1", user: true, text: "First"),
            message("a1", user: false, root: "u1", reply: "u1", text: "Answer 1"),
            message("u2", user: true, text: "", display: ["body": "", "quotes": [], "files": [["name": "photo.jpg", "path": "/tmp/photo.jpg"]], "texts": []]),
            message("a2", user: false, root: "u2", reply: "u2", text: "Answer 2"),
        ])

        let baseRects: [ChatAnchorID: CGRect] = [
            ChatAnchorID(row: "u1", part: .content): CGRect(x: 260, y: 20, width: 100, height: 40),
            ChatAnchorID(row: "a1", part: .content): CGRect(x: 0, y: 72, width: 280, height: 80),
            ChatAnchorID(row: "a2", part: .content): CGRect(x: 0, y: 224, width: 280, height: 60),
        ]

        let missingTarget = ChatTranscriptView.connectors(rows: rows, showsIdentity: { _ in false }, rects: baseRects)
        XCTAssertEqual(missingTarget.map(\.id), ["line:u1"])

        var emptyTargetRects = baseRects
        emptyTargetRects[ChatAnchorID(row: "u2", part: .content)] = .zero
        let emptyTarget = ChatTranscriptView.connectors(rows: rows, showsIdentity: { _ in false }, rects: emptyTargetRects)
        XCTAssertEqual(emptyTarget.map(\.id), ["line:u1"])

        var anchoredRects = baseRects
        anchoredRects[ChatAnchorID(row: "u2", part: .content)] = CGRect(x: 200, y: 172, width: 160, height: 40)
        let anchored = ChatTranscriptView.connectors(rows: rows, showsIdentity: { _ in false }, rects: anchoredRects)
        XCTAssertEqual(anchored.map(\.id), ["line:u1", "line:u2"])
        let u2Bounds = anchored[1].path.boundingRect
        XCTAssertEqual(u2Bounds.minY, 192, accuracy: 0.5, "Connector starts at the attachment row's vertical midpoint")
        XCTAssertEqual(u2Bounds.maxY, 216, accuracy: 0.5, "Connector ends 8pt above the reply bubble")
    }

    /// A textless user row (files/attachments only) still publishes a non-empty content anchor, and an assistant row
    /// with a QuestionCard includes the card in its content anchor so follow-up connectors start below the card.
    @MainActor func testTextlessUserRowAndQuestionCardPublishContentAnchors() async throws {
        let serverMessages: [[String: Any]] = [
            ["messageId": "u1", "seq": 1, "role": "user", "actorType": "user", "createdBy": "current",
             "text": "", "display": ["body": "", "quotes": [], "files": [["name": "photo.jpg", "path": "/tmp/photo.jpg"]], "texts": []]],
            ["messageId": "a1", "seq": 2, "role": "assistant", "actorType": "agent", "actorRole": "router",
             "replyToMessageId": "u1", "threadRootMessageId": "u1",
             "text": "检测到冲突：",
             "parts": [[
                "kind": "question", "messageId": "a1", "prompt": "怎么处理？",
                "choices": [["id": "c1", "label": "合并", "recommended": true], ["id": "c2", "label": "取消"]],
                "multiSelect": false, "allowOther": false,
                "state": ["status": "answered", "choiceIds": ["c1"]],
             ]]],
            ["messageId": "u2", "seq": 3, "role": "user", "actorType": "user", "createdBy": "current",
             "replyToMessageId": "a1", "threadRootMessageId": "u1", "text": "合并"],
            ["messageId": "a2", "seq": 4, "role": "assistant", "actorType": "agent", "actorRole": "router",
             "replyToMessageId": "u2", "threadRootMessageId": "u1", "text": "已合并。"],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: [
            "revision": 1,
            "state": [
                "status": "ready",
                "conversation": ["conversationId": "router", "kind": "router"],
                "serverMessages": serverMessages,
                "pending": [],
                "messages": [],
            ] as [String: Any],
        ])
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in
            (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
        }
        await harness.start()
        let pane = try XCTUnwrap(harness.store.router.pane)
        pane.open(); defer { pane.close() }
        let deadline = ContinuousClock.now + .seconds(5)
        while pane.messages.count < serverMessages.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = ChatTranscriptModel.rows(for: pane)
        var captured: [ChatAnchorID: CGRect] = [:]
        let probe = ChatTranscriptView(
            rows: rows, pane: pane, store: harness.store, isTask: false,
            hasOlderMessages: false, loadingMore: false, openAttachment: { _, _ in }
        )
        .overlayPreferenceValue(ChatAnchorKey.self) { anchors in
            GeometryReader { geometry in
                Color.clear.onAppear {
                    captured = anchors.mapValues { geometry[$0] }
                }
                .onChange(of: anchors.keys.count) { _, _ in
                    captured = anchors.mapValues { geometry[$0] }
                }
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: probe)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let anchorDeadline = ContinuousClock.now + .seconds(5)
        while captured[ChatAnchorID(row: "u1", part: .content)] == nil, ContinuousClock.now < anchorDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let u1Rect = try XCTUnwrap(captured[ChatAnchorID(row: "u1", part: .content)], "Textless user row must publish a content anchor")
        XCTAssertGreaterThan(u1Rect.width, 0)
        XCTAssertGreaterThan(u1Rect.height, 0)
        let a1Rect = try XCTUnwrap(captured[ChatAnchorID(row: "a1", part: .content)])
        let a2Rect = try XCTUnwrap(captured[ChatAnchorID(row: "a2", part: .content)])
        // Text bubble (~42pt) + QuestionCard (~64pt+) must both lie inside a1's content anchor.
        XCTAssertGreaterThan(a1Rect.height, 90, "Assistant content anchor must include its QuestionCard")
        let lines = ChatTranscriptView.connectors(rows: rows, showsIdentity: { _ in false }, rects: captured)
        let u1Line = try XCTUnwrap(lines.first { $0.id == "line:u1" })
        XCTAssertEqual(u1Line.path.boundingRect.minY, u1Rect.midY, accuracy: 1)
        let a1Line = try XCTUnwrap(lines.first { $0.id == "line:a1" })
        XCTAssertGreaterThanOrEqual(a1Line.path.boundingRect.minY, a1Rect.maxY + 7)
        XCTAssertLessThanOrEqual(a1Line.path.boundingRect.maxY, a2Rect.minY - 7)
    }
}
