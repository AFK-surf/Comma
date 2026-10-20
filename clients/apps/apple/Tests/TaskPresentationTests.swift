import XCTest
import CommaCore
@testable import Comma

/// How a Task's facts read in every list: its status name, when it changed, and why it cannot be archived.
final class TaskPresentationTests: XCTestCase {
    private func task(updated: Double = 0, archive: ArchiveAvailability? = nil) -> TaskSummary {
        .listed("t", status: "completed", section: "done", updatedAt: updated, extra: archive.map { availability in
            ["archiveAvailability": ["allowed": availability.allowed, "reason": availability.reason as Any].compactMapValues { $0 }]
        } ?? [:])
    }

    /// Every status list, Home's switcher included, reads In progress, Needs review, Done, Cancelled.
    func testStatusesShowInOneOrder() {
        XCTAssertEqual(TaskListFilter.statusBuckets, [.inProgress, .needsReview, .done, .cancelled])
        XCTAssertEqual(TaskBucket.homeStatuses, [.inProgress, .needsReview, .done, .cancelled])
    }

    /// A section or status the app does not know, such as the retired `backlog`, reads as In progress.
    func testUnknownSectionsReadAsInProgress() {
        XCTAssertEqual(TaskSummary.listed("t", status: "", section: "backlog").bucket, .inProgress)
        XCTAssertEqual(TaskBucket(status: "backlog"), .inProgress)
    }

    /// Home opens on Needs review before any Task is read and whatever the list holds, and a new workspace opens on it
    /// again after the member chose another status.
    @MainActor func testHomeOpensOnNeedsReview() {
        let query = HomeTaskQuery()
        XCTAssertEqual(query.selectedBucket, .needsReview)
        XCTAssertEqual(query.title, "Needs review")
        query.select(.done)
        query.reset()
        XCTAssertEqual(query.selectedBucket, .needsReview)
    }

    /// A short or empty filtered list reads at most five pages on its own, then waits for the member to read on;
    /// a new filter starts a new budget, and a full list always reads on.
    @MainActor func testAShortOrEmptyListReadsABoundedNumberOfPages() {
        let query = HomeTaskQuery()
        for _ in 0..<5 { XCTAssertTrue(query.claimPage(visible: 0, hasMore: true)) }
        XCTAssertFalse(query.claimPage(visible: 0, hasMore: true), "An empty list stops at its budget")
        XCTAssertFalse(query.needsMore(visible: 3, hasMore: true), "So does a short one")
        XCTAssertTrue(query.needsMore(visible: 20, hasMore: true), "A full list reads on as it scrolls")
        query.select(.done)
        XCTAssertTrue(query.needsMore(visible: 0, hasMore: true), "Another status has a budget of its own")
    }

    /// Home lists a status's Tasks pinned first, then in the order the core gives every client (the board's), and
    /// those the core does not name yet last, in the server's order.
    @MainActor func testHomeListsTasksInTheCoresOrder() {
        let query = HomeTaskQuery()
        query.select(.inProgress)
        let tasks = ["a", "b", "c", "d", "e"].map { TaskSummary.listed($0) } + [.listed("done", section: "done")]
        let rows = query.rows(tasks: tasks, pinned: ["d"], order: ["done", "c", "a", "b"], knownLabelIDs: [])
        XCTAssertEqual(rows.map(\.id), ["d", "c", "a", "b", "e"])
    }

    func testEveryStatusHasOneName() {
        let names = TaskBucket.allCases.map { String(localized: $0.label) }
        XCTAssertEqual(names, ["In progress", "Needs review", "Done", "Cancelled", "Archived"])
    }

    /// Seconds and milliseconds name the same day, as the Inbox and the router's Task card read them.
    func testUpdatedLabelReadsSecondsAndMillisecondsAlike() {
        let day = Date(timeIntervalSince1970: 1_788_177_000).formatted(.dateTime.month(.abbreviated).day())
        XCTAssertEqual(task(updated: 1_788_177_000).updatedLabel, "Updated \(day)")
        XCTAssertEqual(task(updated: 1_788_177_000_000).updatedLabel, "Updated \(day)")
        XCTAssertEqual(task().updatedLabel, "Updated recently")
        XCTAssertEqual(task(updated: 0).updatedLabel, "Updated recently")
    }

    /// Home and the Inbox give a refused Archive the desktop's reason; a Task the server is silent on keeps Archive.
    func testArchiveRefusalNamesTheServersReason() {
        func reason(_ availability: ArchiveAvailability?) -> String? {
            task(archive: availability).archiveRefusal.map { String(localized: $0) }
        }
        XCTAssertNil(reason(nil))
        XCTAssertNil(reason(ArchiveAvailability(allowed: true)))
        XCTAssertEqual(reason(ArchiveAvailability(allowed: false, reason: "not_finished")), "Finish the task before archiving")
        XCTAssertEqual(reason(ArchiveAvailability(allowed: false, reason: "schedule_bound")),
                       "Remove the recurring schedule before archiving")
        XCTAssertEqual(reason(ArchiveAvailability(allowed: false, reason: "quota")),
                       "Task status is unavailable; refresh to try again")
        XCTAssertEqual(reason(ArchiveAvailability(allowed: false)), "Task status is unavailable; refresh to try again")
    }
}
