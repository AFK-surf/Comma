import XCTest
@testable import CommaCore

final class ConversationTests: XCTestCase {
    func testArchiveFieldsDecode() throws {
        let json = Data("""
        {"id":"t","group_id":"g","title":"T","status":"archived","kind":"agent_task","archived_at":5,
         "archived_from_status":"in_progress","archive_availability":{"allowed":false,"reason":"not_finished"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(Conversation.self, from: json)
        XCTAssertEqual(decoded.archivedFromStatus, "in_progress")
        XCTAssertEqual(decoded.archiveAvailability, ArchiveAvailability(allowed: false, reason: "not_finished"))
        XCTAssertTrue(decoded.isArchived)
    }

    /// Only a Loop that still runs (being set up, active or paused) keeps the review out of reach; the member may
    /// end any Loop Task by hand. A Task without `loop` is no Loop Task.
    func testOnlyARunningLoopIsScheduled() throws {
        func task(_ status: String, loop: String?) throws -> Conversation {
            let loop = loop.map { #","loop":\#($0)"# } ?? ""
            let json = #"{"id":"t","group_id":"g","title":"T","status":"\#(status)","kind":"agent_task","updated_at":5,"review_version":2\#(loop)}"#
            return try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        }
        let facts = #""started_at":1759990000000,"wake_count":3"#
        let paused = try task("escalated", loop: #"{"state":"paused","reason":"waiting",\#(facts)}"#)
        XCTAssertTrue(paused.canSetStatus, "A paused Loop can be ended by hand")
        XCTAssertTrue(try task("active", loop: #"{"state":"active",\#(facts)}"#).canSetStatus)
        XCTAssertFalse(try task("ready_for_review", loop: #"{"state":"active",\#(facts)}"#).canAcceptReview)
        XCTAssertFalse(try task("ready_for_review", loop: #"{"state":"pending",\#(facts)}"#).canAcceptReview)
        XCTAssertTrue(try task("ready_for_review", loop: #"{"state":"ended","reason":"max_runs",\#(facts)}"#).canAcceptReview,
                      "A Loop that ended is a plain Task again")
        XCTAssertTrue(try task("ready_for_review", loop: nil).canAcceptReview)
    }

    func testKeepingTheMessageTailKeepsEveryOtherField() {
        let messages = ["m1", "m2", "m3"].map { Message(id: $0, kind: "chat", actorType: "user", content: []) }
        let full = Conversation(id: "t", groupID: "g", title: "T", status: "archived", kind: "agent_task", messages: messages,
                                archivedAt: 5, archivedFromStatus: "completed",
                                archiveAvailability: ArchiveAvailability(allowed: false), shared: true)
        let tail = full.keepingMessageTail(2)
        XCTAssertEqual(tail.messages.map(\.id), ["m2", "m3"])
        XCTAssertEqual(tail, Conversation(id: "t", groupID: "g", title: "T", status: "archived", kind: "agent_task",
                                          messages: Array(messages.suffix(2)), archivedAt: 5, archivedFromStatus: "completed",
                                          archiveAvailability: ArchiveAvailability(allowed: false), shared: true))
    }
}
