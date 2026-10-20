import SwiftUI
import XCTest
@testable import Comma

/// The client core's Markdown tree read as bubbles. The fixtures are what the core's `messageMarkdown` makes of the
/// text in each test's comment.
final class MarkdownTreeTests: XCTestCase {
    private func tree(_ json: String) -> NSArray { try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSArray }

    /// Desktop bubble grouping: consecutive prose shares a bubble, code and tables stand alone, and a thematic break
    /// starts a new bubble.
    func testSlotsFollowDesktopBubbleGrouping() {
        // # Title / Intro with **bold** / - one - two / > quote / ```swift code``` / | a | b | table / After / --- / New group
        let tree = tree("""
            [["h",["Title"],{"level":1}],["p",["Intro with ",["b",["bold"]]]],["list",[["li",[["p",["one"]]]],["li",[["p",["two"]]]]]],\
            ["quote",[["p",["quote"]]]],["pre",{"language":"swift","code":"code\\n"}],\
            ["table",[["tr",[["td",["a"],{"header":true,"align":"left"}],["td",["b"],{"header":true,"align":"center"}]]],\
            ["tr",[["td",["1"],{"align":"left"}],["td",["2"],{"align":"center"}]]]]],["p",["After"]],["hr"],["p",["New group"]]]
            """)
        let slots = MarkdownTree.slots(tree, style: MarkdownStyle()) { _ in nil }
        let kinds = slots.map { slot -> String in
            switch slot {
            case .prose(let blocks): "prose(\(blocks.count))"
            case .code(let language, let text): "code(\(language ?? "-"),\(text))"
            case .table(let table): "table(\(table.head.map { String($0.characters) }),\(table.alignments == [.leading, .center]))"
            }
        }
        XCTAssertEqual(kinds, ["prose(4)", "code(swift,code)", "table([\"a\", \"b\"],true)", "prose(1)", "prose(1)"])
    }

    /// A Task chip sits in the text where the agent wrote it, as a link to the Task with the section it is in.
    func testATaskChipStaysInTheTextAsALink() throws {
        // I started <inline task t1 "Fix [login]", done> for you.
        let tree = tree(#"[["p",["I started ",["comma-inline",{"key":"element-1"}]," for you."]]]"#)
        XCTAssertEqual(MarkdownTree.partIndex("element-1"), 1)
        let slots = MarkdownTree.slots(tree, style: MarkdownStyle()) { key in
            key == "element-1" ? .task(id: "t1", title: "Fix [login]", bucket: .done) : nil
        }
        guard case .prose(let blocks) = try XCTUnwrap(slots.first), case .paragraph(let text) = try XCTUnwrap(blocks.first) else {
            return XCTFail("One paragraph")
        }
        XCTAssertEqual(String(text.characters), "I started Fix [login] for you.")
        let links = text.runs[\.link].compactMap { link, range in link.map { ($0.absoluteString, String(text[range].characters)) } }
        XCTAssertEqual(links.map(\.0), ["comma:task/t1#done"])
        XCTAssertEqual(links.map(\.1), ["Fix [login]"])
        XCTAssertEqual(MarkdownTree.plainText(tree) { _ in .words("Fix [login]") }, "I started Fix [login] for you.")
    }
}
