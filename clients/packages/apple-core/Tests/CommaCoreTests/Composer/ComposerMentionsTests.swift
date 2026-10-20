import Foundation
import Testing
@testable import CommaCore

/// Task mentions as the desktop writes them (`mentionSerialization.ts`, `projectMentionTokens`) and the agent
/// command text the router's / menu inserts.
@Suite("Composer mentions and commands")
struct ComposerMentionsTests {
    private func mention(_ title: String, _ id: String) throws -> TaskMention {
        try #require(TaskMention(title: title, conversationID: id))
    }

    @Test func wireTextMatchesDesktop() throws {
        let fix = try mention("Fix [login]\n  bug", "cnv1_abc")
        #expect(fix.wireText == "[Fix (login) bug](comma:task/cnv1_abc)")
        #expect(fix.displayText == "@Fix (login) bug")
        #expect(try mention(" 修复\u{3000}登录 ", "cnv1_x.y-z").wireText == "[修复 登录](comma:task/cnv1_x.y-z)")
    }

    @Test func emptyTitleFallsBackToID() throws {
        #expect(try mention("  \n ", "cnv1_abc").label == "cnv1_abc")
        #expect(try mention("", "task29").displayText == "@task29")
    }

    @Test func invalidIDRejected() {
        for id in ["", "_abc", ".abc", "a/b", "a b", "a)b", "任务", "a?b"] {
            #expect(TaskMention(title: "Title", conversationID: id) == nil, "\(id)")
        }
    }

    @Test func serializeReplacesEachMentionOnce() throws {
        let fix = try mention("Fix login", "c1")
        #expect(TaskMention.serialize("@Fix login and @Fix login again", mentions: [fix])
                == "[Fix login](comma:task/c1) and @Fix login again")
        #expect(TaskMention.serialize("no mentions here", mentions: [fix]) == "no mentions here")
        #expect(TaskMention.serialize("@Fix login", mentions: []) == "@Fix login")
    }

    @Test func editedMentionStaysText() throws {
        let fix = try mention("Fix login", "c1")
        #expect(TaskMention.serialize("@Fix logi please", mentions: [fix]) == "@Fix logi please")
        #expect(TaskMention.serialize("Fix login", mentions: [fix]) == "Fix login", "The @ was deleted")
    }

    @Test func needsWordBoundary() throws {
        let fix = try mention("Fix login", "c1")
        #expect(TaskMention.serialize("@Fix loginx", mentions: [fix]) == "@Fix loginx")
        #expect(TaskMention.serialize("@Fix login2", mentions: [fix]) == "@Fix login2")
        #expect(TaskMention.serialize("@Fix login任务", mentions: [fix]) == "@Fix login任务")
        #expect(TaskMention.serialize("see @Fix login.", mentions: [fix]) == "see [Fix login](comma:task/c1).")
        #expect(TaskMention.serialize("a@Fix login", mentions: [fix]) == "a@Fix login", "The @ must follow whitespace")
        #expect(TaskMention.serialize("x\n@Fix login", mentions: [fix]) == "x\n[Fix login](comma:task/c1)")
    }

    @Test func duplicateLabelsInLedgerOrder() throws {
        let first = try mention("Same", "a1"), second = try mention("Same", "b2")
        #expect(TaskMention.serialize("@Same and @Same", mentions: [first, second])
                == "[Same](comma:task/a1) and [Same](comma:task/b2)")
    }

    @Test func longerLabelsAreTriedFirst() throws {
        let short = try mention("Fix", "s1"), long = try mention("Fix login", "l1")
        #expect(TaskMention.serialize("@Fix login then @Fix", mentions: [short, long])
                == "[Fix login](comma:task/l1) then [Fix](comma:task/s1)")
    }

    @Test func projectRoundTrips() throws {
        let ledger = [try mention("Fix (login) bug", "cnv1_abc"), try mention("Ship", "c2"), try mention("Ship", "c3")]
        let text = "Compare @Fix (login) bug with @Ship and @Ship\nthanks"
        let wire = TaskMention.serialize(text, mentions: ledger)
        #expect(wire == "Compare [Fix (login) bug](comma:task/cnv1_abc) with [Ship](comma:task/c2) and [Ship](comma:task/c3)\nthanks")
        let projected = TaskMention.project(wire)
        #expect(projected.text == text)
        #expect(projected.mentions == ledger)
        #expect(TaskMention.serialize(projected.text, mentions: projected.mentions) == wire)
    }

    @Test func projectIgnoresOtherLinks() {
        for text in ["[Docs](https://comma.surf)", "[Daily](comma:routine/r1)", "[bad](comma:task/_x)",
                     "[multi\nline](comma:task/c1)", "plain text"] {
            let projected = TaskMention.project(text)
            #expect(projected.text == text && projected.mentions.isEmpty, "\(text)")
        }
        let projected = TaskMention.project("see [Fix](comma:task/c1) and [Docs](https://comma.surf)")
        #expect(projected.text == "see @Fix and [Docs](https://comma.surf)")
        #expect(projected.mentions.map(\.conversationID) == ["c1"])
    }

    @Test func conversationIDFromURL() throws {
        #expect(TaskMention.conversationID(from: try #require(URL(string: "comma:task/cnv1_abc"))) == "cnv1_abc")
        for link in ["comma://task/cnv1_abc", "https://comma.surf/task/x", "comma:task/a/b", "comma:task/", "comma:routine/r1",
                     "comma:task/x?y=1"] {
            #expect(TaskMention.conversationID(from: try #require(URL(string: link))) == nil, "\(link)")
        }
    }

    @Test func controlCommandDisplay() {
        let status = ControlCommand.wireText("status")
        #expect(status == "<salix-command>status</salix-command>")
        #expect(ControlCommand.displayText(status) == "/status")
        #expect(ControlCommand.displayText("  " + ControlCommand.wireText("ls /") + "\n") == "/ls /")
        #expect(ControlCommand.displayText(ControlCommand.wireText("cat /path/to/file")) == "/cat /path/to/file")
        for text in ["please " + status, status + " now", status + status, "plain text", "",
                     ControlCommand.wireText(String(repeating: "x", count: 257))] {
            #expect(ControlCommand.displayText(text) == text, "\(text)")
        }
    }
}
