import XCTest
@testable import Comma

/// What the Inbox reads from the marks the core keeps: unread and cleared, each against the Task's revision.
final class InboxMarksTests: XCTestCase {
    private func task(_ id: String, status: String = "ready_for_review", at updatedAt: Double = 100) -> TaskSummary {
        .withStatus(id, status, updatedAt: updatedAt)
    }

    func testNeedsReviewIsUnreadUntilSeenAndAgainOnceItUpdates() {
        var marks = InboxMarks()
        XCTAssertTrue(marks.isUnread(task("a")))
        XCTAssertFalse(marks.isUnread(task("b", status: "completed")), "Only Needs review asks for attention by itself")
        marks.seen["a"] = 100
        XCTAssertFalse(marks.isUnread(task("a")))
        XCTAssertTrue(marks.isUnread(task("a", at: 101)), "A newer revision re-arms the dot")
    }

    func testManualUnreadStaysWhileTheMarkIsKept() {
        var marks = InboxMarks()
        marks.unread["a"] = 100
        marks.seen["a"] = 500
        XCTAssertTrue(marks.isUnread(task("a", status: "completed", at: 500)), "Viewing alone keeps a manual unread mark")
    }

    func testClearedRowsReturnWhenTheTaskUpdates() {
        var marks = InboxMarks()
        marks.cleared["a"] = 100
        XCTAssertTrue(marks.isCleared(task("a")))
        XCTAssertFalse(marks.isCleared(task("a", at: 101)), "New activity resurfaces a cleared row")
        XCTAssertFalse(marks.isCleared(task("c")))
    }
}
