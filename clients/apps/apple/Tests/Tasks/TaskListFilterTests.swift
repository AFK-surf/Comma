import XCTest
import CommaCore
@testable import Comma

final class TaskListFilterTests: XCTestCase {
    private let known: Set<String> = ["bug", "docs"]

    private func task(_ id: String, status: String = "in_progress", labels: [String] = [], origin: String? = nil,
                      client: String? = nil, loop: String? = nil, cadence: [String: Any]? = nil) -> TaskSummary {
        var extra: [String: Any] = [:]
        extra["labels"] = labels
        if let origin { extra["origin"] = origin }
        if let client { extra["clientPlatform"] = client }
        if let loop {
            var value: [String: Any] = ["state": loop, "startedAt": 1, "wakeCount": 1]
            value["cadence"] = cadence
            extra["loop"] = value
        }
        return .withStatus(id, status, extra: extra)
    }

    func testFieldsCombineWithAndWhileValuesWithinAFieldCombineWithOr() {
        let filter = TaskListFilter(statuses: [.inProgress, .needsReview], origins: ["slack"])
        XCTAssertTrue(filter.matches(task("a", origin: "slack"), knownLabelIDs: known))
        XCTAssertTrue(filter.matches(task("b", status: "ready_for_review", origin: "slack"), knownLabelIDs: known))
        XCTAssertFalse(filter.matches(task("c", status: "completed", origin: "slack"), knownLabelIDs: known))
        XCTAssertFalse(filter.matches(task("d", origin: "telegram"), knownLabelIDs: known))
        XCTAssertTrue(TaskListFilter().matches(task("e", status: "cancelled"), knownLabelIDs: known))
    }

    func testLabelsIgnoreIDsTheCatalogNoLongerKnows() {
        let unlabeled = TaskListFilter(labels: [TaskListFilter.noLabel])
        XCTAssertTrue(unlabeled.matches(task("a", labels: []), knownLabelIDs: known))
        XCTAssertTrue(unlabeled.matches(task("b", labels: ["deleted"]), knownLabelIDs: known))
        XCTAssertFalse(unlabeled.matches(task("c", labels: ["bug", "deleted"]), knownLabelIDs: known))
        let bugs = TaskListFilter(labels: ["bug"])
        XCTAssertTrue(bugs.matches(task("e", labels: ["docs", "bug"]), knownLabelIDs: known))
        XCTAssertFalse(bugs.matches(task("f", labels: ["docs"]), knownLabelIDs: known))
    }

    func testOriginAndClientPlatformKeys() {
        XCTAssertEqual(TaskListFilter.originKey("wechat"), "wechat")
        XCTAssertEqual(TaskListFilter.originKey("discord"), TaskListFilter.unspecified)
        XCTAssertEqual(TaskListFilter.originKey(nil), TaskListFilter.unspecified)
        XCTAssertEqual(TaskListFilter.clientPlatformKey("macos"), "macos")
        XCTAssertEqual(TaskListFilter.clientPlatformKey("watchos"), "watchos")
        XCTAssertEqual(TaskListFilter.clientPlatformKey("electron"), "unknown")
        XCTAssertNil(TaskListFilter.clientPlatformKey(nil))
        XCTAssertNil(TaskListFilter.clientPlatformKey(""))
        let unspecified = TaskListFilter(origins: [TaskListFilter.unspecified])
        XCTAssertTrue(unspecified.matches(task("a"), knownLabelIDs: known))
        XCTAssertFalse(unspecified.matches(task("b", origin: "comma"), knownLabelIDs: known))
        let phones = TaskListFilter(clientPlatforms: ["ios"])
        XCTAssertTrue(phones.matches(task("c", client: "ios"), knownLabelIDs: known))
        XCTAssertFalse(phones.matches(task("d"), knownLabelIDs: known), "A Task with no device never matches a device")
    }

    /// Loops splits Loop Tasks by the kind of their trigger, an ended Loop by the kind it had, as on the desktop;
    /// No loop holds the rest.
    func testLoopsSplitsLoopTasksByTheirTriggerKind() {
        let timed: [String: Any] = ["pattern": ["kind": "daily", "hour": 9, "minute": 0], "cron": "0 9 * * *",
                                    "timezone": "Asia/Shanghai"]
        let updates: [String: Any] = ["events": "new comments on PR #12"]
        let tasks = [task("a", loop: "active", cadence: timed), task("b", loop: "ended", cadence: timed),
                     task("c", loop: "paused", cadence: updates), task("d", loop: "active"), task("e")]
        func matching(_ option: String) -> [String] {
            let filter = TaskListFilter(schedules: [option])
            return tasks.filter { filter.matches($0, knownLabelIDs: known) }.map(\.id)
        }
        XCTAssertEqual(matching(TaskListFilter.scheduled), ["a", "b"])
        XCTAssertEqual(matching(TaskListFilter.onUpdates), ["c"])
        XCTAssertEqual(matching(TaskListFilter.otherTrigger), ["d"])
        XCTAssertEqual(matching(TaskListFilter.notScheduled), ["e"])
        XCTAssertEqual(TaskListFilter.counts(field: .schedule, tasks: tasks, knownLabelIDs: known),
                       [TaskListFilter.scheduled: 2, TaskListFilter.onUpdates: 1, TaskListFilter.otherTrigger: 1,
                        TaskListFilter.notScheduled: 1])
    }

    func testSettingEveryOptionStopsNarrowingAndNoneNarrowsToNothing() {
        let all: Set<String> = ["slack", "comma", TaskListFilter.unspecified]
        var filter = TaskListFilter().setting(.platform, values: ["slack"], all: all)
        XCTAssertEqual(filter.origins, ["slack"])
        XCTAssertEqual(filter.narrowedFields, [.platform])
        filter = filter.setting(.platform, values: all, all: all)
        XCTAssertNil(filter.origins)
        XCTAssertEqual(filter.narrowedFields, [])
        let statuses: Set<String> = [TaskBucket.done.rawValue, TaskBucket.cancelled.rawValue]
        filter = filter.setting(.status, values: [], all: statuses)
        XCTAssertEqual(filter.statuses, [])
        XCTAssertFalse(filter.matches(task("a"), knownLabelIDs: known))
        filter = filter.setting(.status, values: [TaskBucket.done.rawValue], all: statuses)
        XCTAssertEqual(filter.statuses, [.done])
        XCTAssertEqual(filter.values(.status), [TaskBucket.done.rawValue])
        filter.labels = [TaskListFilter.noLabel]
        XCTAssertEqual(filter.narrowedFields, [.status, .label])
    }

    func testCountsIgnoreTheCurrentNarrowing() {
        let tasks = [task("a", labels: ["bug"], origin: "slack", client: "macos"),
                     task("b", status: "completed", labels: ["bug", "gone"], origin: "slack", client: "electron"),
                     task("c", status: "completed", labels: [], client: nil),
                     task("d", labels: ["docs"], origin: "comma", client: "ios")]
        XCTAssertEqual(TaskListFilter.counts(field: .status, tasks: tasks, knownLabelIDs: known),
                       [TaskBucket.inProgress.rawValue: 2, TaskBucket.done.rawValue: 2])
        XCTAssertEqual(TaskListFilter.counts(field: .label, tasks: tasks, knownLabelIDs: known),
                       ["bug": 2, "docs": 1, TaskListFilter.noLabel: 1])
        XCTAssertEqual(TaskListFilter.counts(field: .platform, tasks: tasks, knownLabelIDs: known),
                       ["slack": 2, "comma": 1, TaskListFilter.unspecified: 1])
        XCTAssertEqual(TaskListFilter.counts(field: .clientPlatform, tasks: tasks, knownLabelIDs: known),
                       ["macos": 1, "unknown": 1, "ios": 1])
    }
}
