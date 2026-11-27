import SwiftUI
import XCTest
@testable import Comma

/// A bubble's words as the one text a selection runs in.
@MainActor final class MessageTextSelectionTests: XCTestCase {
    private func slots(_ json: String) throws -> [MarkdownSlot] {
        let tree = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSArray)
        return MarkdownBubbles.slots(tree: tree, parts: [], style: MarkdownStyle())
    }

    /// A prose bubble's blocks are in its text in reading order, one line each, a list item after its marker, so a
    /// selection can run from any word to any other and copies what it covers.
    func testAProseBubbleIsOneTextInReadingOrder() throws {
        // # Title / Intro with **bold** / - one - two / > quote
        let slots = try slots("""
            [["h",["Title"],{"level":1}],["p",["Intro with ",["b",["bold"]]]],["list",[["li",[["p",["one"]]]],["li",[["p",["two"]]]]]],\
            ["quote",[["p",["quote"]]]]]
            """)
        guard case .prose(let blocks) = try XCTUnwrap(slots.first) else { return XCTFail("One prose bubble") }
        let text = SelectableMessageText.prose(blocks)
        XCTAssertEqual(text.string, "Title\nIntro with bold\n•\tone\n•\ttwo\nquote")
        let bold = (text.string as NSString).range(of: "bold")
        let font = try XCTUnwrap(text.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    /// A table's rows are lines and its cells are apart by tabs, as a spreadsheet takes them.
    func testATableBubbleCopiesAsTabSeparatedRows() throws {
        // | a | b | / | 1 | 2 |
        let slots = try slots("""
            [["table",[["tr",[["td",["a"],{"header":true,"align":"left"}],["td",["b"],{"header":true,"align":"center"}]]],\
            ["tr",[["td",["1"],{"align":"left"}],["td",["2"],{"align":"center"}]]]]]]
            """)
        guard case .table(let table) = try XCTUnwrap(slots.first) else { return XCTFail("One table bubble") }
        XCTAssertEqual(SelectableMessageText.table(table).text.string, "a\tb\n1\t2")
    }

    /// A person's message reads as its bubble does: a Task mention is `@Title`, not its link's source.
    func testAPersonsMentionReadsAsItsBubbleShowsIt() {
        let text = SelectableMessageText.person(MessageBubbles.inline("See [Fix login](comma:task/t1) now"), color: .white)
        XCTAssertEqual(text.string, "See @Fix login now")
    }
}
