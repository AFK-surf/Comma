import Foundation
import Testing
@testable import CommaCore

/// The desktop trigger rules (`findAiInputMenuMatch`), the trigger buttons and row completion. Drafts are
/// written with "|" as the caret; a draft without "|" has no selection, which means the caret is at the end.
@Suite("Composer trigger rules")
struct ComposerTriggerTests {
    private func draft(_ marked: String) -> (text: String, selection: Range<String.Index>?) {
        guard let bar = marked.firstIndex(of: "|") else { return (marked, nil) }
        var text = marked
        text.remove(at: bar)
        let caret = text.index(text.startIndex, offsetBy: marked.distance(from: marked.startIndex, to: bar))
        return (text, caret..<caret)
    }

    private func match(_ marked: String) -> ComposerTriggerMatch? {
        let (text, selection) = draft(marked)
        return ComposerTrigger.match(in: text, selection: selection)
    }

    private func isBoundary(_ index: String.Index, of text: String) -> Bool {
        index == text.endIndex || text.indices.contains(index)
    }

    private func marked(_ edit: ComposerEdit) -> String {
        #expect(isBoundary(edit.caret, of: edit.text), "The caret is a character boundary of the new text")
        var text = edit.text
        text.insert("|", at: edit.caret)
        return text
    }

    private func tap(_ trigger: ComposerTrigger, _ marked: String) -> String? {
        let (text, selection) = draft(marked)
        guard case .edit(let edit) = ComposerTrigger.toggling(trigger, in: text, selection: selection) else { return nil }
        return self.marked(edit)
    }

    private func complete(_ marked: String, with insertion: String, trailingSpace: Bool = true) throws -> String {
        let (text, selection) = draft(marked)
        let open = try #require(ComposerTrigger.match(in: text, selection: selection))
        return self.marked(ComposerTrigger.completing(open, in: text, with: insertion, trailingSpace: trailingSpace))
    }

    @Test func matchesAtStartAndAfterWhitespace() throws {
        let bare = try #require(match("@"))
        #expect(bare.trigger == .mention && bare.query.isEmpty)
        #expect(match("hi @ta")?.query == "ta")
        let skill = try #require(match("hi\n/sk"))
        #expect(skill.trigger == .skill && skill.query == "sk")
        let text = "hi @ta"
        #expect(String(text[try #require(ComposerTrigger.match(in: text, selection: nil)).range]) == "@ta")
    }

    @Test func ideographicSpaceCountsAsWhitespace() {
        #expect(match("你好\u{3000}@任")?.query == "任")
        #expect(match("你好@任") == nil)
    }

    @Test func ignoresTriggerInsideAWord() {
        #expect(match("a/b") == nil)
        #expect(match("x@y") == nil)
        #expect(match("mail me at x@y.com") == nil)
    }

    @Test func spaceClosesTheMenu() {
        #expect(match("@ta ") == nil)
        #expect(match("@ta\n") == nil)
    }

    @Test func repeatedTriggerFailsLikeDesktop() {
        #expect(match("/a/b") == nil)
        #expect(match("@a@b") == nil)
        #expect(match("@@") == nil)
        #expect(match("@x/y").map { [$0.trigger.rawValue, $0.query] } == ["@", "x/y"])
        #expect(match("/@x").map { [$0.trigger.rawValue, $0.query] } == ["/", "@x"])
    }

    /// Each alias is looked up on its own on the desktop, so only a repeat of the same character fails.
    @Test func fullwidthTriggersFromCJKInput() throws {
        let mention = try #require(match("请看 ＠任务"))
        #expect(mention.trigger == .mention && mention.query == "任务")
        #expect(match("你好 ／pdf").map { [$0.trigger.rawValue, $0.query] } == ["/", "pdf"])
        #expect(match("／a/b")?.query == "a/b")
        #expect(match("＠a＠b") == nil)
        #expect(ComposerTrigger("＠") == .mention && ComposerTrigger("／") == .skill && ComposerTrigger("#") == nil)
    }

    @Test func caretMidTextUsesTextBeforeCaret() {
        #expect(match("hi @ta|sk rest")?.query == "ta")
        #expect(match("hi @|task")?.query == "")
        #expect(match("@ta rest|") == nil)
        #expect(match("hi| @ta") == nil)
    }

    @Test func rangeSelectionNeverMatches() {
        let text = "hi @task"
        let start = text.index(text.startIndex, offsetBy: 4)
        #expect(ComposerTrigger.match(in: text, selection: start..<text.endIndex) == nil)
    }

    @Test func nilSelectionMeansEnd() {
        let text = "hi @task"
        #expect(ComposerTrigger.match(in: text, selection: nil) == ComposerTrigger.match(in: text, selection: text.endIndex..<text.endIndex))
    }

    @Test func staleSelectionReturnsNilWithoutTrapping() {
        let longer = "a much longer draft that was sent @ta"
        let stale = longer.index(longer.startIndex, offsetBy: 30)
        #expect(ComposerTrigger.match(in: "@ta", selection: stale..<stale) == nil)
        #expect(!ComposerTrigger.valid(stale..<stale, in: "@ta"))
        let accented = "e\u{301} @x"
        let inside = accented.unicodeScalars.index(after: accented.startIndex)
        #expect(!ComposerTrigger.valid(inside..<inside, in: accented), "Inside a character")
        #expect(ComposerTrigger.validated(inside..<accented.endIndex, in: accented) == nil, "A range with one bad bound")
        let old = "abcdefgh", family = "👩‍👩‍👧 @x"
        let aligned = old.index(old.startIndex, offsetBy: 4)
        #expect(ComposerTrigger.match(in: family, selection: aligned..<aligned) == nil,
                "A boundary of the old text that falls inside a character of the new one")
    }

    /// UIKit hands the field UTF-16 strings and Swift edits build UTF-8 ones. A selection of the same string lands
    /// exactly. One left from another string never traps and gives a boundary of the current text or nothing,
    /// where the standard library would trap on the first and accept the second inside a flag.
    @Test func selectionsAcrossStringEncodings() throws {
        let bridged = NSString(string: "你好 @ta") as String
        #expect(!bridged.isContiguousUTF8)
        let caret = bridged.index(bridged.startIndex, offsetBy: 2)
        let same = try #require(ComposerTrigger.validated(caret..<caret, in: bridged))
        #expect(bridged[..<same.lowerBound] == "你好")
        #expect(ComposerTrigger.match(in: bridged, selection: bridged.endIndex..<bridged.endIndex)?.query == "ta")

        let typed = NSString(string: "draft typed in UIKit é") as String
        let staleUTF16 = typed.index(typed.startIndex, offsetBy: 4)
        let shorter = "你好"  // UTF-16 length 2, UTF-8 length 6: the index lies between the two ends.
        let result = ComposerTrigger.validated(staleUTF16..<staleUTF16, in: shorter)
        #expect(result.map { isBoundary($0.lowerBound, of: shorter) } ?? true)
        #expect(ComposerTrigger.match(in: shorter, selection: staleUTF16..<staleUTF16) == nil)
        let farUTF16 = typed.index(typed.startIndex, offsetBy: 14)
        #expect(ComposerTrigger.validated(farUTF16..<farUTF16, in: shorter) == nil)

        let flags = NSString(string: "🇨🇳🇨🇳 @a") as String
        let other = "abcdefgh"
        let insideFlag = other.index(other.startIndex, offsetBy: 5)
        #expect(ComposerTrigger.validated(insideFlag..<insideFlag, in: flags) == nil)
        guard case .edit(let edit) = ComposerTrigger.toggling(.skill, in: flags, selection: insideFlag..<insideFlag) else {
            Issue.record("A stale selection taps at the end"); return
        }
        #expect(marked(edit) == "🇨🇳🇨🇳 @a /|")
    }

    @Test func tapInsertsWithSpaceWhenNeeded() {
        #expect(tap(.mention, "") == "@|")
        #expect(tap(.mention, "hello") == "hello @|")
        #expect(tap(.mention, "hello ") == "hello @|")
        #expect(tap(.mention, "ab|cd") == "ab @|cd")
        #expect(tap(.skill, "line\n|") == "line\n/|")
    }

    @Test func tapReplacesASelection() throws {
        let text = "fix this now"
        let start = text.index(text.startIndex, offsetBy: 4), end = text.index(start, offsetBy: 4)
        guard case .edit(let edit) = ComposerTrigger.toggling(.mention, in: text, selection: start..<end) else {
            Issue.record("A selection is replaced"); return
        }
        #expect(marked(edit) == "fix @| now")
        let glued = "abcd"
        let tail = glued.index(glued.startIndex, offsetBy: 2)
        guard case .edit(let spaced) = ComposerTrigger.toggling(.skill, in: glued, selection: tail..<glued.endIndex) else {
            Issue.record("A selection is replaced"); return
        }
        #expect(marked(spaced) == "ab /|")
    }

    @Test func staleSelectionTapsAtTheEnd() {
        let longer = "a longer draft that was sent"
        let stale = longer.index(longer.startIndex, offsetBy: 20)
        guard case .edit(let edit) = ComposerTrigger.toggling(.mention, in: "hi", selection: stale..<stale) else {
            Issue.record("A stale selection taps at the end"); return
        }
        #expect(marked(edit) == "hi @|")
    }

    @Test func secondTapRemovesABareTrigger() {
        #expect(tap(.mention, "hello @") == "hello |")
        #expect(tap(.mention, "＠") == "|")
        #expect(tap(.skill, "ab /|cd") == "ab |cd")
    }

    @Test func secondTapWithQueryDismisses() {
        let (text, selection) = draft("hello @ta")
        #expect(ComposerTrigger.toggling(.mention, in: text, selection: selection) == .dismiss)
    }

    @Test func otherTriggerSwapsABareTrigger() {
        #expect(tap(.skill, "hello @") == "hello /|")
        #expect(tap(.mention, "／") == "@|")
        #expect(tap(.skill, "@ta") == "@ta /|", "A query is kept and the other trigger starts after it")
    }

    @Test func completingAddsOneSpace() throws {
        #expect(try complete("hi @ta", with: "@Task 1") == "hi @Task 1 |")
        #expect(try complete("@ta|x", with: "@Task") == "@Task |x")
    }

    @Test func completingReusesFollowingSpace() throws {
        #expect(try complete("hi @ta| rest", with: "@Task") == "hi @Task |rest")
        #expect(try complete("/pd|\nnext", with: "/pdf") == "/pdf\n|next")
    }

    @Test func completingReplacesFullwidthTrigger() throws {
        #expect(try complete("看 ＠任", with: "@任务") == "看 @任务 |")
        #expect(try complete("／pd", with: "/pdf") == "/pdf |")
    }

    @Test func commandsInsertWithoutSpace() throws {
        let command = ControlCommand.wireText("status")
        #expect(try complete("/st", with: command, trailingSpace: false) == command + "|")
        #expect(try complete("/st| more", with: command, trailingSpace: false) == command + "| more")
    }

    /// A control character ends a character, so an accent may follow it on its own; after the completion's space
    /// it joins that space, and the caret steps back onto the boundary before it. ("|" would join the accent too.)
    @Test func completingKeepsTheCaretOnACharacterBoundary() throws {
        let text = "@ta\u{1}\u{301}"
        let caret = text.index(text.startIndex, offsetBy: 4)
        let open = try #require(ComposerTrigger.match(in: text, selection: caret..<caret))
        let edit = ComposerTrigger.completing(open, in: text, with: "@Task", trailingSpace: true)
        #expect(edit.text == "@Task \u{301}")
        #expect(edit.text[..<edit.caret] == "@Task")
        #expect(isBoundary(edit.caret, of: edit.text))
    }
}
