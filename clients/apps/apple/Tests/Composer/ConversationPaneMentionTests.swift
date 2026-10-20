import Foundation
import XCTest
import CommaCore
@testable import Comma

/// The composer's @ and / picks as the pane sends and keeps them. A picked Task travels and is saved as the
/// desktop's `[Title](comma:task/<id>)` and reads as `@Title` again; the catalog skills a message names are tagged
/// in the send's `skills` field, and a retry sends the same request again.
@MainActor
final class ConversationPaneMentionTests: XCTestCase {
    nonisolated private static func skills(_ ids: [String]) -> [String: Any] {
        ["status": "ready", "skills": ids.map { ["skill_id": $0, "name": $0, "location": "/.runtime/skills/\($0)/SKILL.md"] }]
    }

    func testSendTurnsPickedTasksIntoDesktopLinksAndTagsSkills() async throws {
        let harness = try StoreHarness()
        harness.core.serve("skills") { _ in Self.skills(["pdf", "frontend-design"]) }
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }
        await store.skills.loadIfStale(store: store)
        let task = try XCTUnwrap(TaskMention(title: "Fix [login]  bug", conversationID: "cnv1_abc"))
        router.draftText = "Ask \(task.displayText) about /PDF and /pdf, not a/frontend-design \n"
        router.draftMentions = [task]

        let attempt = try XCTUnwrap(router.enqueueSend())
        await router.deliver(attempt)

        let sent = try XCTUnwrap(harness.core.calls("chatView.send").last)
        XCTAssertEqual(sent["conversation"] as? String, "router")
        XCTAssertEqual(sent["text"] as? String, "Ask [Fix (login) bug](comma:task/cnv1_abc) about /PDF and /pdf, not a/frontend-design")
        XCTAssertEqual(sent["skills"] as? [[String: String]], [["location": "/.runtime/skills/pdf/SKILL.md"]],
                       "Named once in any case; a slash inside a word names nothing")
        XCTAssertEqual(sent["clientRequestId"] as? String, attempt.id)
        XCTAssertEqual(router.draftText, "")
        XCTAssertTrue(router.draftMentions.isEmpty)
    }

    /// A Routine item waits as a tile and goes as an attached text with its app's name, alone or beside the words;
    /// one moved into the field goes as words, and a refused send gives the tiles back.
    func testStagedRoutineItemsGoAsAttachedTexts() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }
        router.attachText(ChatAttachedText(source: "Linear", text: "Help me review COMMA-1"))
        router.attachText(ChatAttachedText(source: "Linear", text: "Help me review COMMA-1"))
        router.attachText(ChatAttachedText(source: nil, text: "Reply to Dana"))
        XCTAssertEqual(router.draftTexts.map(\.attached.text), ["Help me review COMMA-1", "Reply to Dana"], "Staged once")

        let alone = try XCTUnwrap(router.enqueueSend(), "Tiles alone can be sent")
        XCTAssertEqual(alone.text, "")
        XCTAssertTrue(router.draftTexts.isEmpty)
        await router.deliver(alone)
        let sent = try XCTUnwrap(harness.core.calls("chatView.send").last)
        XCTAssertEqual(sent["text"] as? String, "")
        XCTAssertEqual(sent["attachedTexts"] as? [[String: String]],
                       [["source": "Linear", "text": "Help me review COMMA-1"], ["text": "Reply to Dana"]])

        router.attachText(ChatAttachedText(source: "Slack", text: "Summarize #launch"))
        router.attachText(ChatAttachedText(source: "GitHub", text: "Fix the checks"))
        router.showDraftTextInField(try XCTUnwrap(router.draftTexts.last).id)
        XCTAssertEqual(router.draftText, "Fix the checks")
        harness.core.on("chatView.send") { _ in throw CancellationError() }
        let refused = try XCTUnwrap(router.enqueueSend())
        await router.deliver(refused)
        XCTAssertEqual(harness.core.calls("chatView.send").last?["text"] as? String, "Fix the checks")
        XCTAssertEqual(router.draftTexts.map(\.attached.text), ["Summarize #launch"], "A refused send's tiles come back")
    }

    /// A failed send is retried by its request id: the core sends what it kept, tags included.
    func testRetrySendsTheSameRequestAgain() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        let router = try XCTUnwrap(store.router.pane)
        await until { router.state.loaded }
        router.draftText = "summarize the report"
        let attempt = try XCTUnwrap(router.enqueueSend())
        await router.deliver(attempt)
        await router.retry(attempt.id)

        XCTAssertEqual(harness.core.calls("chatView.retry").map { $0["clientRequestId"] as? String }, [attempt.id])
        XCTAssertEqual(harness.core.calls("chatView.retry").first?["conversation"] as? String, "router")
    }

    func testClosingSavesLinksAndReopeningShowsMentions() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        await store.openTask(id: "task")
        let first = try XCTUnwrap(store.task)
        await until { first.state.loaded }
        let notes = try XCTUnwrap(TaskMention(title: "Release notes", conversationID: "cnv1_notes"))
        let release = try XCTUnwrap(TaskMention(title: "Release", conversationID: "cnv1_release"))
        // The second mention was edited by hand, so it stays the text it now is.
        first.draftText = "Draft \(notes.displayText) and @Releas"
        first.draftMentions = [notes, release]
        store.closeTask()
        let saved = "Draft [Release notes](comma:task/cnv1_notes) and @Releas"
        _ = await harness.core.first("chatView.setDraft") { $0["conversation"] as? String == "task" && $0["draft"] as? String == saved }

        await store.openTask(id: "task")
        let reopened = try XCTUnwrap(store.task)
        await until { reopened.state.loaded }
        XCTAssertFalse(reopened === first)
        XCTAssertEqual(reopened.draftText, "Draft @Release notes and @Releas")
        XCTAssertEqual(reopened.draftMentions, [notes])
        XCTAssertEqual(reopened.outgoingDraft, saved)
    }

    /// A Task picked while the conversation loads joins the saved draft with its own mention kept.
    func testMentionPickedWhileLoadingJoinsTheSavedDraft() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        harness.core.serve("chatView") { _ in nil }
        await store.openTask(id: "task")
        let pane = try XCTUnwrap(store.task)
        let login = try XCTUnwrap(TaskMention(title: "Fix login", conversationID: "cnv1_login"))
        pane.draftText = login.displayText + " "
        pane.draftMentions = [login]
        harness.core.publish("chatView", matching: ["conversation": "task"], [
            "revision": 1,
            "state": ["status": "ready", "draft": "See [Release notes](comma:task/cnv1_notes)", "conversation": ["id": "task"]],
        ])
        await until { pane.state.loaded }

        XCTAssertEqual(pane.draftText, "See @Release notes\n\n@Fix login ")
        XCTAssertEqual(pane.draftMentions.map(\.conversationID), ["cnv1_notes", "cnv1_login"])
        XCTAssertEqual(pane.outgoingDraft, "See [Release notes](comma:task/cnv1_notes)\n\n[Fix login](comma:task/cnv1_login) ")
    }

    func testRestoringASlashDraftReadsSkills() async throws {
        let harness = try StoreHarness()
        harness.core.serve("skills") { _ in Self.skills(["pdf"]) }
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        harness.core.publish("chatView", matching: ["conversation": "router"], [
            "revision": 2, "state": ["status": "ready", "draft": "/pdf the attached report", "conversation": ["id": "router"]],
        ])
        harness.core.serve("chatView") { _ in nil }
        await store.openTask(id: "task")
        let pane = try XCTUnwrap(store.task)
        harness.core.publish("chatView", matching: ["conversation": "task"], [
            "revision": 1, "state": ["status": "ready", "draft": "/pdf the attached report", "conversation": ["id": "task"]],
        ])

        await until { store.skills.catalog.map(\.skillID) == ["pdf"] }
        XCTAssertEqual(pane.enqueueSend()?.skills, ["/.runtime/skills/pdf/SKILL.md"],
                       "A restored draft naming a skill reads the catalog, so a send without focus can tag it")
    }

    /// Only a token the desktop skill pattern could read starts that read.
    func testOnlyASlashTokenPrefetchesSkills() {
        for text in ["/pdf", "Use /pdf", "line\n/PDF", "tab\t/9x"] { XCTAssertTrue(ConversationPane.namesSkill(text), text) }
        for text in ["", "/", "a/b", "https://comma.surf/x", "/ pdf", "／pdf", "/_x", "/é"] {
            XCTAssertFalse(ConversationPane.namesSkill(text), text)
        }
    }
}
