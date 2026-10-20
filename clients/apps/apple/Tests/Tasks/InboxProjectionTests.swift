import XCTest
import CommaCore
@testable import Comma

final class InboxProjectionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-04 12:00 UTC, in seconds.
    private let noon: Double = 1_791_115_200

    private func task(_ id: String, status: String = "ready_for_review", at updatedAt: Double,
                      origin: String? = nil) -> TaskSummary {
        .withStatus(id, status, updatedAt: updatedAt, extra: origin.map { ["origin": $0] } ?? [:])
    }

    func testDefaultRowsAreAttentionTasksNewestFirstWithoutArchivedOrCleared() {
        let tasks = [task("review", at: noon - 60),
                     task("done", status: "completed", at: (noon - 30) * 1000),
                     task("failed", status: "failed", at: noon - 90),
                     task("running", status: "in_progress", at: noon),
                     task("archived", status: "archived", at: noon),
                     task("cleared", status: "completed", at: noon - 10)]
        var marks = InboxMarks()
        marks.cleared["cleared"] = noon - 10
        let rows = InboxProjection.rows(tasks, marks: marks, filter: InboxProjection.defaultFilter)
        XCTAssertEqual(rows.map(\.id), ["done", "review", "failed"], "Milliseconds and seconds sort together")
        let wider = InboxProjection.defaultFilter.setting(.status, values: ["needsReview", "done", "cancelled", "inProgress"],
                                                          all: Set(TaskBucket.allCases.map(\.rawValue)))
        XCTAssertEqual(InboxProjection.rows(tasks, marks: marks, filter: wider).map(\.id), ["running", "done", "review", "failed"])
        XCTAssertEqual(InboxProjection.listed(tasks, marks: marks).count, 4)
    }

    func testUnreadOnlyAndPlatformNarrowTheRows() {
        let tasks = [task("a", at: noon, origin: "slack"), task("b", at: noon - 1),
                     task("c", status: "completed", at: noon - 2, origin: "slack")]
        var marks = InboxMarks()
        marks.seen["b"] = noon - 1
        XCTAssertEqual(InboxProjection.rows(tasks, marks: marks, filter: InboxProjection.defaultFilter, unreadOnly: true)
            .map(\.id), ["a"])
        var slack = InboxProjection.defaultFilter
        slack.origins = ["slack"]
        XCTAssertEqual(InboxProjection.rows(tasks, marks: marks, filter: slack).map(\.id), ["a", "c"])
    }

    func testDaysGroupConsecutiveRowsByCalendarDay() {
        let rows = [task("today", at: noon), task("morning", at: noon - 11 * 3600),
                    task("yesterday", at: noon - 86_400), task("older", at: noon - 5 * 86_400)]
        let days = InboxProjection.days(rows, calendar: calendar)
        XCTAssertEqual(days.map { $0.tasks.map(\.id) }, [["today", "morning"], ["yesterday"], ["older"]])
        XCTAssertEqual(days.first?.id, calendar.startOfDay(for: Date(timeIntervalSince1970: noon)))
    }

    func testHasUnreadIgnoresArchivedAndClearedRowsButNotTheFilter() {
        let review = task("a", at: noon)
        var marks = InboxMarks()
        XCTAssertTrue(InboxProjection.hasUnread([review], marks: marks))
        XCTAssertFalse(InboxProjection.hasUnread([task("b", status: "archived", at: noon)], marks: marks))
        marks.cleared["a"] = noon
        XCTAssertFalse(InboxProjection.hasUnread([review], marks: marks))
        let running = task("c", status: "in_progress", at: noon)
        marks.unread["c"] = noon
        XCTAssertTrue(InboxProjection.hasUnread([review, running], marks: marks))
    }

    func testEmptyStatesSayWhetherNothingArrivedEverythingWasHandledOrTheFilterHidesRows() {
        let review = task("a", at: noon, origin: "slack")
        var marks = InboxMarks()
        let unfiltered = InboxProjection.defaultFilter
        XCTAssertEqual(InboxProjection.emptyState([task("b", status: "in_progress", at: noon)], marks: marks, filter: unfiltered),
                       .nothingYet)
        var telegram = unfiltered
        telegram.origins = ["telegram"]
        XCTAssertEqual(InboxProjection.emptyState([review], marks: marks, filter: telegram), .filtered(hidden: 1))
        marks.cleared["a"] = noon
        XCTAssertEqual(InboxProjection.emptyState([review], marks: marks, filter: telegram), .caughtUp,
                       "Nothing to bring back once every row is cleared")
        XCTAssertEqual(InboxProjection.emptyState([review], marks: marks, filter: unfiltered), .caughtUp)
    }
}
