import SwiftUI
import XCTest
import CommaCore
@testable import Comma

/// The composer's caret and menus: which menu the caret opens, what the @ and / buttons and the rows write, the
/// desktop's Escape signature, a caret left behind by text from outside the field, Backspace on a mention or a
/// command, a caret the field reports in its own UTF-16 copy of a non-ASCII draft, and when the menu has room.
@MainActor
final class TriggerMenuModelTests: XCTestCase {
    private func pane() throws -> ConversationPane {
        ConversationPane(kind: .router, workspace: Workspace(id: "w1", groupID: "g1", name: "W"), conversationID: "router",
                         store: try StoreHarness().store)
    }

    /// The field typing `text` with the caret after `caretOffset` characters (the end when nil).
    private func type(_ text: String, caret caretOffset: Int? = nil, into pane: ConversationPane, model: TriggerMenuModel) {
        let old = pane.draftText
        model.textBinding(for: pane).wrappedValue = text
        let caret = caretOffset.map { text.index(text.startIndex, offsetBy: $0) } ?? text.endIndex
        model.selectionBinding(for: pane).wrappedValue = TextSelection(insertionPoint: caret)
        model.textDidChange(from: old, to: text, pane: pane)
    }

    private func caretOffset(_ model: TriggerMenuModel, in pane: ConversationPane) throws -> Int {
        let range = try selected(model, in: pane)
        XCTAssertTrue(range.isEmpty, "A caret, not a range")
        return pane.draftText.distance(from: pane.draftText.startIndex, to: range.lowerBound)
    }

    private func selected(_ model: TriggerMenuModel, in pane: ConversationPane) throws -> Range<String.Index> {
        let selection = try XCTUnwrap(model.selectionBinding(for: pane).wrappedValue)
        guard case .selection(let range) = selection.indices else { throw XCTSkip("several ranges") }
        return range
    }

    func testButtonsInsertAtTheCaretAndToggle() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("hello world", caret: 6, into: pane, model: model)
        model.tap(.mention, pane: pane)
        XCTAssertEqual(pane.draftText, "hello @world")
        XCTAssertEqual(try caretOffset(model, in: pane), 7)
        XCTAssertEqual(model.match(in: pane.draftText)?.trigger, .mention)
        model.tap(.skill, pane: pane)
        XCTAssertEqual(pane.draftText, "hello /world", "The other button swaps a bare trigger")
        model.tap(.skill, pane: pane)
        XCTAssertEqual(pane.draftText, "hello world", "The same button removes it")
        XCTAssertNil(model.match(in: pane.draftText))
    }

    func testEscapeKeepsTheMenuClosedUntilTheTextChangesAndATapReopensIt() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("hi /pd", into: pane, model: model)
        model.dismiss(in: pane.draftText)
        XCTAssertNil(model.match(in: pane.draftText))
        model.tap(.skill, pane: pane)
        XCTAssertEqual(pane.draftText, "hi /pd", "A tap on a dismissed menu reopens it without editing")
        XCTAssertEqual(model.match(in: pane.draftText)?.query, "pd")
        model.dismiss(in: pane.draftText)
        type("hi /pdf", into: pane, model: model)
        XCTAssertEqual(model.match(in: pane.draftText)?.query, "pdf", "Typing opens it again")
    }

    func testRowsInsertTheDesktopText() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("ask @2", into: pane, model: model)
        model.choose(task29, pane: pane)
        XCTAssertEqual(pane.draftText, "ask @Task 29 ")
        XCTAssertEqual(pane.draftMentions.map(\.conversationID), ["task29"])
        XCTAssertNil(model.match(in: pane.draftText))
        model.choose(task29, pane: pane)
        XCTAssertEqual(pane.draftText, "ask @Task 29 ", "A stale tap does nothing")
        type("ask @Task 29 /", into: pane, model: model)
        model.choose(command("ls", body: "ls /"), pane: pane)
        XCTAssertEqual(pane.draftText, "ask @Task 29 /ls /\n", "A command reads as its bubble will, not as its markup")
        XCTAssertEqual(pane.outgoingDraft, "ask [Task 29](comma:task/task29) <salix-command>ls /</salix-command>\n")
        XCTAssertEqual(try caretOffset(model, in: pane), pane.draftText.count, "A path command keeps its line to itself")
        XCTAssertNil(model.match(in: pane.draftText))
    }

    private let task29 = TriggerMenuItem(kind: .task(conversationID: "task29", title: "Task 29", bucket: .inProgress),
                                         id: "task:task29", label: "Task 29", detail: nil,
                                         candidate: ComposerMenuCandidate(id: "task:task29", label: "Task 29"))

    private func command(_ name: String, body: String) -> TriggerMenuItem {
        TriggerMenuItem(kind: .command(name: name, body: body), id: "salix-" + name, label: "/" + name, detail: nil,
                        candidate: ComposerMenuCandidate(id: "salix-" + name, label: "/" + name))
    }

    /// A picked command goes as its control text while its name is intact; its path is plain text to edit in place,
    /// on a line of its own, so the message typed next goes below the block, as after the desktop's closing tag.
    /// One Backspace at the end of its name takes the name whole, as on a mention; an edit inside it leaves text.
    func testCommandsReadAsSlashAndBackspaceTakesTheirName() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("/", into: pane, model: model)
        model.choose(command("status", body: "status"), pane: pane)
        XCTAssertEqual(pane.draftText, "/status ")
        XCTAssertEqual(pane.outgoingDraft, "<salix-command>status</salix-command> ")
        type("/status", into: pane, model: model)
        XCTAssertEqual(pane.draftText, "/status", "Deleting the space after it is an ordinary edit")
        type("/statu", into: pane, model: model)
        XCTAssertEqual(pane.draftText, "")
        XCTAssertTrue(pane.draftCommands.isEmpty)

        type("/", into: pane, model: model)
        model.choose(command("cat", body: "cat /path/to/file"), pane: pane)
        XCTAssertEqual(pane.draftText, "/cat /path/to/file\n")
        XCTAssertEqual(String(pane.draftText[try selected(model, in: pane)]), "/path/to/file",
                       "The placeholder comes selected, for typing to replace it")
        type("/cat /notes.md\n", caret: 14, into: pane, model: model)
        XCTAssertEqual(pane.outgoingDraft, "<salix-command>cat /notes.md</salix-command>\n")
        type("/cat /notes.md\nplease", into: pane, model: model)
        XCTAssertEqual(pane.outgoingDraft, "<salix-command>cat /notes.md</salix-command>\nplease",
                       "The message below the command goes outside its block")
        type("/ca /notes.md\nplease", caret: 3, into: pane, model: model)
        XCTAssertEqual(pane.draftText, " /notes.md\nplease")
        XCTAssertEqual(try caretOffset(model, in: pane), 0)
        XCTAssertEqual(pane.outgoingDraft, " /notes.md\nplease")

        type("/\nthen", caret: 1, into: pane, model: model)
        model.choose(command("ls", body: "ls /"), pane: pane)
        XCTAssertEqual(pane.draftText, "/ls /\nthen", "A line break that follows already is kept, not doubled")
        XCTAssertEqual(try caretOffset(model, in: pane), 6)

        type("/", into: pane, model: model)
        model.choose(command("help", body: "help"), pane: pane)
        type("/hlp ", caret: 2, into: pane, model: model)
        XCTAssertEqual(pane.draftText, "/hlp ", "A Backspace inside the name is an ordinary edit")
        XCTAssertEqual(pane.outgoingDraft, "/hlp ", "and the edited name goes as the text it is")
    }

    /// A command beside a mention in a non-ASCII draft: both read as the field shows them and go as the desktop's
    /// markup, and one Backspace at the end of the command's name, reported by the field in its own UTF-16 copy of
    /// the draft, takes the name whole and leaves the mention linked.
    func testCommandsBesideMentionsInANonASCIIDraft() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("日本語 /", into: pane, model: model)
        model.choose(command("status", body: "status"), pane: pane)
        type("日本語 /status @", into: pane, model: model)
        model.choose(task29, pane: pane)
        XCTAssertEqual(pane.draftText, "日本語 /status @Task 29 ")
        XCTAssertEqual(pane.outgoingDraft, "日本語 <salix-command>status</salix-command> [Task 29](comma:task/task29) ")

        let old = pane.draftText, field = NSString(string: "日本語 /statu @Task 29 ") as String
        model.textBinding(for: pane).wrappedValue = field
        model.selectionBinding(for: pane).wrappedValue =
            TextSelection(insertionPoint: field.utf16.index(field.startIndex, offsetBy: 10))
        model.textDidChange(from: old, to: field, pane: pane)
        XCTAssertEqual(pane.draftText, "日本語  @Task 29 ")
        XCTAssertEqual(try caretOffset(model, in: pane), 4)
        XCTAssertTrue(pane.draftCommands.isEmpty)
        XCTAssertEqual(pane.outgoingDraft, "日本語  [Task 29](comma:task/task29) ")
    }

    func testBackspaceAtTheEndOfAMentionTakesItWhole() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("see @", into: pane, model: model)
        let item = TriggerMenuItem(kind: .task(conversationID: "t1", title: "Plan Q4", bucket: .inProgress), id: "task:t1",
                                   label: "Plan Q4", detail: nil, candidate: ComposerMenuCandidate(id: "task:t1", label: "Plan Q4"))
        model.choose(item, pane: pane)
        model.textDidChange(from: "see @", to: pane.draftText, pane: pane)
        type("see @Plan Q4", into: pane, model: model)
        XCTAssertEqual(pane.draftText, "see @Plan Q4", "Deleting the space after it is an ordinary edit")
        type("see @Plan Q", into: pane, model: model)
        XCTAssertEqual(pane.draftText, "see ")
        XCTAssertEqual(try caretOffset(model, in: pane), 4)
        XCTAssertTrue(pane.draftMentions.isEmpty)
    }

    /// Two picked Tasks with one title: Backspace on either takes its own ledger entry, and a pick goes into the
    /// ledger at its place in the text, so each mention left is still sent as its own Task.
    func testSameTitledMentionsKeepTheirOwnTasks() throws {
        let pane = try pane(), model = TriggerMenuModel()
        func fixBug(_ id: String) -> TriggerMenuItem {
            TriggerMenuItem(kind: .task(conversationID: id, title: "Fix bug", bucket: .inProgress), id: "task:" + id,
                            label: "Fix bug", detail: nil, candidate: ComposerMenuCandidate(id: "task:" + id, label: "Fix bug"))
        }
        type("@", into: pane, model: model)
        model.choose(fixBug("A"), pane: pane)
        type("@Fix bug and @", into: pane, model: model)
        model.choose(fixBug("B"), pane: pane)
        XCTAssertEqual(pane.outgoingDraft, "[Fix bug](comma:task/A) and [Fix bug](comma:task/B) ")
        type("@Fix bu and @Fix bug ", caret: 7, into: pane, model: model)
        XCTAssertEqual(pane.draftText, " and @Fix bug ")
        XCTAssertEqual(pane.outgoingDraft, " and [Fix bug](comma:task/B) ", "The mention left is B's")
        type("@ and @Fix bug ", caret: 1, into: pane, model: model)
        model.choose(fixBug("C"), pane: pane)
        XCTAssertEqual(pane.outgoingDraft, "[Fix bug](comma:task/C) and [Fix bug](comma:task/B) ", "Picked last, C comes first")
    }

    /// The field reports its caret in its own UIKit copy of the draft, counted in UTF-16, so every draft written
    /// outside it (a button, a row, a Routine) is that kind of string too: the caret then lands where it was put.
    func testTheFieldsCaretReadsTrueInNonASCIIDraftsWrittenOutsideIt() throws {
        let pane = try pane(), model = TriggerMenuModel()
        func fieldCaret(_ utf16Offset: Int) {
            let field = NSString(string: pane.draftText) as String
            model.selectionBinding(for: pane).wrappedValue =
                TextSelection(insertionPoint: field.utf16.index(field.startIndex, offsetBy: utf16Offset))
        }
        type("日本語の文 abc", caret: 6, into: pane, model: model)
        model.tap(.skill, pane: pane)
        XCTAssertEqual(pane.draftText, "日本語の文 /abc")
        fieldCaret(9)
        XCTAssertEqual(model.match(in: pane.draftText)?.query, "ab")
        fieldCaret(3)
        model.tap(.mention, pane: pane)
        XCTAssertEqual(pane.draftText, "日本語 @の文 /abc")

        let routine = try self.pane()
        routine.appendDraft("你好 世界")
        model.reset()
        model.textDidChange(from: "", to: routine.draftText, pane: routine)
        let field = NSString(string: routine.draftText) as String
        model.selectionBinding(for: routine).wrappedValue =
            TextSelection(insertionPoint: field.utf16.index(field.startIndex, offsetBy: 3))
        model.tap(.mention, pane: routine)
        XCTAssertEqual(routine.draftText, "你好 @世界")
    }

    /// Only a draft replaced from outside the field (a send) closes the menu at once; the person's own edits, even one
    /// that empties the draft, close it with its exit. The buttons and the menu share one test of the room.
    func testTheMenuClosesAtOnceOnlyForTextFromOutsideAndNeedsRoom() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("@", into: pane, model: model)
        model.tap(.mention, pane: pane)
        XCTAssertEqual(pane.draftText, "")
        XCTAssertFalse(model.isFromOutside(pane.draftText), "Taking a bare trigger away is the person's own close")
        type("hi @", into: pane, model: model)
        pane.draftText = ""
        XCTAssertTrue(model.isFromOutside(pane.draftText), "A send empties the draft from outside the field")
        let metrics = TriggerMenuMetrics(), room = TriggerMenuModel()
        room.spaceAbove = 0
        XCTAssertFalse(room.fits(metrics) || room.shown(in: "@", metrics: metrics) != nil, "No room: no menu, no buttons")
        room.spaceAbove = 1_000
        XCTAssertTrue(room.fits(metrics) && room.shown(in: "@", metrics: metrics) != nil)
    }

    func testTextFromOutsideTheFieldDropsTheCaret() throws {
        let pane = try pane(), model = TriggerMenuModel()
        type("hello world", caret: 6, into: pane, model: model)
        let old = pane.draftText
        pane.appendDraft("A routine prompt")
        XCTAssertNil(model.selectionBinding(for: pane).wrappedValue, "The field keeps its own caret")
        model.textDidChange(from: old, to: pane.draftText, pane: pane)
        XCTAssertNil(model.selectionBinding(for: pane).wrappedValue)
        XCTAssertNil(model.match(in: pane.draftText), "No caret reads as the end, where there is no trigger")
        model.tap(.mention, pane: pane)
        XCTAssertEqual(pane.draftText, "hello world\n\nA routine prompt @", "A tap goes where the field left the caret")
    }
}
