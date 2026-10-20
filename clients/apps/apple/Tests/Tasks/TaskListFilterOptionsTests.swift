import XCTest
import CommaCore
@testable import Comma

final class TaskListFilterOptionsTests: XCTestCase {
    private func task(_ id: String, status: String = "in_progress", origin: String? = nil, client: String? = nil) -> TaskSummary {
        var extra: [String: Any] = [:]
        if let origin { extra["origin"] = origin }
        if let client { extra["clientPlatform"] = client }
        return .withStatus(id, status, extra: extra)
    }

    func testStatusOffersEveryBoardColumnAndLabelNeedsTheCatalog() {
        let filter = TaskListFilter()
        XCTAssertEqual(filter.options(.status, tasks: [], labelIDs: []),
                       ["inProgress", "needsReview", "done", "cancelled"])
        XCTAssertEqual(filter.options(.label, tasks: [task("a")], labelIDs: []), [], "No catalog labels, no Label field")
        XCTAssertEqual(filter.options(.label, tasks: [], labelIDs: ["docs", "bug"]), ["docs", "bug", TaskListFilter.noLabel])
    }

    func testPlatformsListWhatTasksUsePlusTheSelectionInMenuOrder() {
        let tasks = [task("a", origin: "slack", client: "ios"), task("b", origin: "comma", client: "electron"),
                     task("c", origin: "comma")]
        var filter = TaskListFilter()
        XCTAssertEqual(filter.options(.platform, tasks: tasks, labelIDs: []), ["slack", "comma"])
        XCTAssertEqual(filter.options(.platform, tasks: [task("x"), task("y", origin: "discord")], labelIDs: []), [],
                       "Unspecified alone is no choice")
        XCTAssertEqual(TaskListFilter(origins: [TaskListFilter.unspecified]).options(.platform, tasks: [task("x")], labelIDs: []),
                       [TaskListFilter.unspecified], "A selection stays offered so it can be cleared")
        XCTAssertEqual(filter.options(.clientPlatform, tasks: tasks, labelIDs: []), ["ios", TaskListFilter.unknownClientPlatform])
        filter.origins = ["telegram"]
        filter.clientPlatforms = ["macos"]
        XCTAssertEqual(filter.options(.platform, tasks: tasks + [task("d", origin: "discord")], labelIDs: []),
                       ["slack", "telegram", "comma", TaskListFilter.unspecified])
        XCTAssertEqual(filter.options(.clientPlatform, tasks: tasks, labelIDs: []),
                       ["macos", "ios", TaskListFilter.unknownClientPlatform])
    }

    /// Loops offers Scheduled, On updates and No loop, as on the desktop, and Other trigger only while a loaded Task
    /// has a trigger this client cannot read, or while it is selected so it can be cleared. Checking every choice stops
    /// the field narrowing.
    func testLoopsOffersEachTriggerKindAndTheRest() {
        let filter = TaskListFilter()
        let kinds = [TaskListFilter.scheduled, TaskListFilter.onUpdates, TaskListFilter.notScheduled]
        XCTAssertEqual(filter.options(.schedule, tasks: [task("a")], labelIDs: []), kinds)
        let unknown = TaskSummary.withStatus("u", "in_progress", extra: ["loop": ["state": "ended", "startedAt": 1,
                                                                                  "wakeCount": 1]])
        let withOther = [TaskListFilter.scheduled, TaskListFilter.onUpdates, TaskListFilter.otherTrigger,
                         TaskListFilter.notScheduled]
        XCTAssertEqual(filter.options(.schedule, tasks: [task("a"), unknown], labelIDs: []), withOther)
        let other = filter.setting(.schedule, values: [TaskListFilter.otherTrigger], all: Set(kinds))
        XCTAssertEqual(other.options(.schedule, tasks: [task("a")], labelIDs: []), withOther)
        let scheduled = filter.setting(.schedule, values: [TaskListFilter.scheduled], all: Set(kinds))
        XCTAssertEqual(scheduled.narrowedFields, [.schedule])
        XCTAssertNil(scheduled.setting(.schedule, values: Set(kinds), all: Set(kinds)).schedules)
    }

    func testClearingAFieldStopsItNarrowing() {
        let filter = TaskListFilter(statuses: [], labels: ["bug"], origins: ["slack"])
        XCTAssertNil(filter.clearing(.status).statuses)
        XCTAssertEqual(filter.clearing(.status).narrowedFields, [.label, .platform])
        XCTAssertEqual(filter.clearing(.label).clearing(.platform).narrowedFields, [.status])
    }

    /// An archived Task is listed in the section it was archived from, as the core's summaries say.
    func testArchivedTasksListTheStatusTheyWereArchivedFrom() throws {
        func summary(_ from: String?) -> TaskSummary? {
            var item: [String: Any] = ["id": "t", "group_id": "g", "title": "T", "status": "archived", "kind": "agent_task"]
            if let from { item["archived_from_bucket"] = from }
            return TaskSummary(summary: item as NSDictionary)
        }
        XCTAssertEqual(summary("done")?.listBucket, .done)
        XCTAssertEqual(summary("done")?.bucket, .archived)
        XCTAssertEqual(summary("in_progress")?.listBucket, .inProgress)
    }
}
