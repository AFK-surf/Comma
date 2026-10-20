import Foundation
import XCTest
import CommaCore
@testable import Comma

/// Agent commands picked from the router's / menu: the field reads `/status`, the server reads the desktop's
/// `<salix-command>status</salix-command>` (wire format unchanged), and a saved draft reads as the field showed it.
@MainActor
final class AgentCommandTests: XCTestCase {
    private let status = AgentCommand(body: "status")!
    private let cat = AgentCommand(body: "cat /path/to/file")!

    func testAPickedCommandGoesAsTheDesktopsControlText() {
        XCTAssertEqual(AgentCommand.serialize("/status", commands: [status]), ControlCommand.wireText("status"))
        XCTAssertEqual(AgentCommand.serialize("Hi /status please", commands: [status]),
                       "Hi <salix-command>status</salix-command> please")
        XCTAssertEqual(AgentCommand.serialize("/status", commands: []), "/status", "Typed by hand, it is text")
        for text in ["a/status", "/status.", "/statusx", "/stat"] {
            XCTAssertEqual(AgentCommand.serialize(text, commands: [status]), text, "\(text) is not the picked command")
        }
        XCTAssertEqual(AgentCommand.serialize("/status and /status", commands: [status]),
                       "<salix-command>status</salix-command> and /status", "Each pick is used once")
    }

    /// A command with a path holds the rest of its line, trailing whitespace left out; the next line is text.
    func testAPathRunsToTheEndOfItsLine() {
        XCTAssertEqual(AgentCommand.serialize("/cat /notes/a b.md  \nthanks", commands: [cat]),
                       "<salix-command>cat /notes/a b.md</salix-command>  \nthanks")
        XCTAssertEqual(AgentCommand.serialize("/cat", commands: [cat]), "<salix-command>cat</salix-command>")
        let ls = AgentCommand(body: "ls /")!
        XCTAssertTrue(ls.takesPath)
        XCTAssertFalse(status.takesPath)
        XCTAssertEqual(ls.token, "/ls")
        XCTAssertNil(AgentCommand(body: "  "))
        XCTAssertNil(AgentCommand(body: "cat\n/x"))
    }

    /// A saved block reads as `/body` with its ledger, and goes back as it was; a block that could not read back as
    /// itself from the field stays markup.
    func testSavedBlocksReadAsSlashAndRoundTrip() {
        for saved in ["<salix-command>status</salix-command>", "Hi <salix-command>status</salix-command> there",
                      "<salix-command>ls /</salix-command>\nmore", "x\n<salix-command>cat /a.md</salix-command> ",
                      "你好 <salix-command>cat /文件.md</salix-command>\n<salix-command>help</salix-command> 世界"] {
            let projected = AgentCommand.project(saved)
            XCTAssertFalse(projected.text.contains("salix-command"), saved)
            XCTAssertEqual(AgentCommand.serialize(projected.text, commands: projected.commands), saved)
        }
        XCTAssertEqual(AgentCommand.project("Hi <salix-command> status </salix-command>").text, "Hi /status")
        XCTAssertEqual(AgentCommand.project("Hi <salix-command>ls /</salix-command>").commands, [AgentCommand(body: "ls /")!])
        for kept in ["x<salix-command>status</salix-command>", "<salix-command>status</salix-command>x",
                     "<salix-command>ls /</salix-command> then", "<salix-command></salix-command>", "plain /status"] {
            XCTAssertEqual(AgentCommand.project(kept).text, kept, kept)
            XCTAssertTrue(AgentCommand.project(kept).commands.isEmpty, kept)
        }
    }

    /// A sent message reads in its bubble as the field showed it: the desktop's `/command` for a whole message, and
    /// each block in longer text that the field would read back as a pick; any other block stays as written.
    func testBubblesReadAsTheFieldShowedIt() {
        XCTAssertEqual(AgentCommand.bubbleText(" <salix-command>status</salix-command> "), "/status")
        XCTAssertEqual(AgentCommand.bubbleText("日本語 <salix-command>help</salix-command> [T](comma:task/t) please"),
                       "日本語 /help [T](comma:task/t) please")
        XCTAssertEqual(AgentCommand.bubbleText("Run <salix-command>ls /</salix-command> now"),
                       "Run <salix-command>ls /</salix-command> now", "A path with text after it is not a pick")
        XCTAssertEqual(AgentCommand.bubbleText("plain text"), "plain text")
    }

    /// The pane sends and saves a picked command as its control text, and a reopened conversation shows `/status`
    /// with the ledger that sends it the same way; mentions beside it keep their links.
    func testThePaneSendsAndRestoresCommands() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        defer { store.suspend() }
        await store.openTask(id: "task")
        let first = try XCTUnwrap(store.task)
        await until { first.state.loaded }
        let notes = try XCTUnwrap(TaskMention(title: "Release notes", conversationID: "cnv1_notes"))
        first.draftText = "/status for \(notes.displayText) "
        first.draftMentions = [notes]
        first.draftCommands = [status]
        store.closeTask()
        let saved = "<salix-command>status</salix-command> for [Release notes](comma:task/cnv1_notes) "
        _ = await harness.core.first("chatView.setDraft") { $0["conversation"] as? String == "task" && $0["draft"] as? String == saved }

        await store.openTask(id: "task")
        let reopened = try XCTUnwrap(store.task)
        await until { reopened.state.loaded }
        XCTAssertEqual(reopened.draftText, "/status for @Release notes ")
        XCTAssertEqual(reopened.draftCommands, [status])
        XCTAssertEqual(reopened.draftMentions, [notes])

        reopened.draftText = "/status"
        reopened.draftMentions = []
        let attempt = try XCTUnwrap(reopened.enqueueSend())
        XCTAssertEqual(attempt.text, ControlCommand.wireText("status"), "The wire format is the desktop's")
        XCTAssertTrue(reopened.draftCommands.isEmpty)
        XCTAssertEqual(ControlCommand.displayText(attempt.text), "/status", "and its bubble reads as the field did")
    }
}
