import XCTest
import CommaCore
@testable import Comma

/// A Loop Task's Loop as the core's topics carry it, what it changes about the Task, its kind, and its details, which
/// match desktop Properties.
final class TaskLoopTests: XCTestCase {
    private let paused: [String: Any] = [
        "state": "paused", "reason": "waiting", "wakeCount": 3, "maxRuns": 10, "startedAt": 1_720_000_000_000,
        "lastWakeAt": 1_720_227_600_000, "nextRunAt": 1_720_314_000_000,
        "cadence": ["pattern": ["kind": "weekly", "days": [1, 3], "hour": 18, "minute": 30],
                    "cron": "30 18 * * 1,3", "timezone": "Asia/Shanghai"],
    ]

    private func loop(_ fields: [String: Any]) throws -> TaskLoop {
        try XCTUnwrap(TaskLoop((["startedAt": 1_720_000_000_000, "wakeCount": 0] as [String: Any])
            .merging(fields) { $1 } as NSDictionary))
    }

    /// Both topics carry the same object: the `tasks` list and the summaries the details card reads.
    func testBothTopicsReadTheSameLoop() throws {
        let listed = TaskSummary.withStatus("t", "escalated", extra: ["loop": paused])
        let summary = try XCTUnwrap(TaskSummary(summary: ["id": "t", "group_id": "g", "title": "T", "status": "escalated",
                                                          "kind": "agent_task", "updated_at": 5, "loop": paused] as NSDictionary))
        XCTAssertEqual(listed.loop, summary.loop)
        let loop = try XCTUnwrap(summary.loop)
        XCTAssertEqual(loop.state, .paused)
        XCTAssertEqual(loop.reason, .waiting)
        XCTAssertEqual(loop.cadence, .timed(pattern: .weekly(days: [1, 3], hour: 18, minute: 30),
                                            cron: "30 18 * * 1,3", timezone: "Asia/Shanghai"))
        XCTAssertTrue(summary.scheduled)
        XCTAssertNil(TaskSummary.withStatus("p", "active").loop, "A Task without `loop` is no Loop Task")
    }

    /// A member can end a running Loop Task by hand (the server deletes its Loop), but it never waits for a review to
    /// accept; once its Loop ended it is a plain Task again. A Loop still being set up already runs the Task.
    func testALoopCanBeEndedByHandButNotAccepted() {
        let loop = TaskSummary.withStatus("t", "escalated", extra: ["loop": paused, "archiveVersion": 5])
        XCTAssertTrue(loop.canSetStatus)
        let review = TaskSummary.withStatus("r", "ready_for_review", extra: [
            "loop": ["state": "pending", "startedAt": 1, "wakeCount": 0], "reviewVersion": 2,
        ])
        XCTAssertTrue(review.scheduled)
        XCTAssertFalse(review.canAcceptReview)
        let ended = TaskSummary.withStatus("e", "ready_for_review", extra: [
            "loop": ["state": "ended", "reason": "max_runs", "startedAt": 1, "wakeCount": 5, "endedAt": 1_720_400_000_000],
            "reviewVersion": 2,
        ])
        XCTAssertFalse(ended.scheduled)
        XCTAssertEqual(ended.loop?.reason, .maxRuns)
        XCTAssertTrue(ended.canAcceptReview)
    }

    /// What wakes it, in words: a timed pattern, or the updates the person named, as they wrote them. A time reads
    /// as the viewer's locale writes it, so its ICU data decides "9:00" or "09:00".
    func testCadenceReadsAsATimeOrTheNamedUpdates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        func label(_ pattern: TaskLoop.Pattern, cron: String? = nil) -> String {
            TaskLoop.label(pattern, cron: cron, calendar: calendar)
        }
        func time(_ hour: Int, _ minute: Int) -> String {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = .gmt
            return utc.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute))!
                .formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale!, timeZone: .gmt))
        }
        XCTAssertEqual(label(.daily(hour: 9, minute: 0)), "Every day at \(time(9, 0))")
        XCTAssertEqual(label(.weekdays(hour: 9, minute: 0)), "Every weekday at \(time(9, 0))")
        XCTAssertEqual(label(.weekly(days: [1, 3], hour: 18, minute: 30)), "Every Mon, Wed at \(time(18, 30))")
        XCTAssertEqual(label(.monthly(day: 1, hour: 8, minute: 0)), "Monthly on day 1 at \(time(8, 0))")
        XCTAssertEqual(label(.hourly(minute: 5)), "Every hour at :05")
        XCTAssertEqual(label(.interval(minutes: 360)), "Every 6 hours")
        XCTAssertEqual(label(.interval(minutes: 30)), "Every 30 minutes")
        XCTAssertEqual(label(.interval(minutes: 1440)), "Every day")
        XCTAssertEqual(label(.custom, cron: "0 9 1-7 * 1"), "0 9 1-7 * 1")

        let interval = try loop(["state": "active", "cadence": ["pattern": ["kind": "interval", "minutes": 60],
                                                                "everyMinutes": 60]])
        XCTAssertEqual(interval.cadenceLabel(calendar: calendar), "Every hour")
        let events = try loop(["state": "active", "cadence": ["events": "new comments on PR #12"]])
        XCTAssertEqual(events.cadence, .events("new comments on PR #12"))
        XCTAssertEqual(events.cadenceLabel(), "new comments on PR #12")
        XCTAssertNil(try loop(["state": "active", "cadence": [:]]).cadenceLabel(),
                     "A cadence this client does not know has no words")
    }

    /// Each Loop is named by the kind of its trigger, with the glyph desktop draws for it. An ended Loop keeps the
    /// kind of the trigger it had.
    func testTheKindNamesTheTrigger() throws {
        let timed = try loop(["state": "active", "cadence": ["pattern": ["kind": "daily", "hour": 9, "minute": 0],
                                                             "cron": "0 9 * * *", "timezone": "Asia/Shanghai"]])
        let events = try loop(["state": "active", "cadence": ["events": "new comments on PR #12"]])
        let unknown = try loop(["state": "active"])
        XCTAssertEqual([timed.kind, events.kind, unknown.kind], [.scheduled, .onUpdates, .other])
        XCTAssertEqual(TaskLoop.Kind.allCases.map(\.label), ["Scheduled", "On updates", "Other trigger"])
        XCTAssertEqual(TaskLoop.Kind.allCases.map(\.iconName),
                       ["central-calendar-days", "central-eye-open", "central-infinity"])
        let ended = try loop(["state": "ended", "reason": "max_runs", "cadence": ["events": "new comments on PR #12"]])
        XCTAssertEqual(ended.kind, .onUpdates)
    }

    /// The details under the kind are the rows desktop Properties shows. An active Loop shows only its trigger rule,
    /// never its next run, last run, run count or end. A pending Loop adds Setting up, a paused one says why it
    /// paused, and an ended one shows only Ended. There is always at least one row.
    func testDetailsShowWhatDesktopPropertiesShows() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let runFacts: [String: Any] = [
            "wakeCount": 4, "maxRuns": 14, "lastWakeAt": 1_720_227_600_000, "nextRunAt": 1_720_314_000_000,
            "until": "PR #12 is merged", "endsAt": 1_720_400_000_000,
        ]
        let hourly: [String: Any] = ["pattern": ["kind": "interval", "minutes": 60], "everyMinutes": 60]
        let updates: [String: Any] = ["events": "new comments on PR #12"]
        func details(_ fields: [String: Any]) throws -> [TaskLoop.Detail] {
            try loop(runFacts.merging(fields) { $1 }).details(viewer: shanghai)
        }
        XCTAssertEqual(try details(["state": "active", "cadence": hourly]), [.rule("Every hour", zone: nil)])
        XCTAssertEqual(try details(["state": "active", "cadence": updates]),
                       [.rule("new comments on PR #12", zone: nil)])
        XCTAssertEqual(try details(["state": "active"]), [.running], "A rule this client cannot read still runs")
        XCTAssertEqual(try details(["state": "pending", "cadence": hourly]),
                       [.rule("Every hour", zone: nil), .settingUp])
        XCTAssertEqual(try details(["state": "pending"]), [.settingUp])
        XCTAssertEqual(try details(["state": "paused", "reason": "waiting", "cadence": updates]),
                       [.rule("new comments on PR #12", zone: nil), .paused("Paused until you reply")])
        XCTAssertEqual(try details(["state": "paused", "reason": "exited", "cadence": hourly]),
                       [.rule("Every hour", zone: nil), .paused("Paused · its program stopped")])
        XCTAssertEqual(try details(["state": "paused"]), [.paused("Paused")], "A reason this client does not know")
        XCTAssertEqual(try details(["state": "ended", "reason": "max_runs", "cadence": hourly]), [.ended])
        XCTAssertEqual(try details(["state": "ended", "reason": "cancelled", "cadence": updates]), [.ended])
    }

    /// A stepped-hour cron keeps its minute past the hour, which its interval pattern drops, as desktop writes it.
    func testASteppedHourKeepsItsMinute() {
        XCTAssertEqual(TaskLoop.label(.interval(minutes: 120), cron: "30 */2 * * *"), "Every 2 hours at :30")
        XCTAssertEqual(TaskLoop.label(.interval(minutes: 120), cron: "5 */2 * * *"), "Every 2 hours at :05")
        XCTAssertEqual(TaskLoop.label(.interval(minutes: 120), cron: "0 */2 * * *"), "Every 2 hours")
        XCTAssertEqual(TaskLoop.label(.interval(minutes: 120), cron: nil), "Every 2 hours", "An interval has no cron")
    }

    /// The cron's zone shows only when its offset now differs from the viewer's: short beside the rule, its long
    /// name for VoiceOver. An interval and a zone this system does not know show none.
    func testTheZoneShowsOnlyWhenItsOffsetDiffers() throws {
        let loop = try XCTUnwrap(TaskLoop(paused as NSDictionary))
        let english = Locale(identifier: "en_US")
        let july = Date(timeIntervalSince1970: 1_720_000_000)
        XCTAssertNil(loop.foreignZone(viewer: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")), at: july))
        XCTAssertNil(loop.foreignZone(viewer: try XCTUnwrap(TimeZone(identifier: "Asia/Taipei")), at: july),
                     "Another zone with the same offset is the viewer's wall clock")
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let foreign = try XCTUnwrap(loop.foreignZone(viewer: berlin, at: july, locale: english))
        XCTAssertEqual(foreign, TaskLoop.Zone(offset: "GMT+8", name: "China Standard Time"))
        XCTAssertEqual(loop.details(viewer: berlin, at: july, locale: english).first,
                       .rule(try XCTUnwrap(loop.cadenceLabel()), zone: foreign), "The rule row carries the zone")
        let interval = try self.loop(["state": "active", "cadence": ["pattern": ["kind": "interval", "minutes": 60],
                                                                     "everyMinutes": 60]])
        XCTAssertNil(interval.foreignZone(), "An interval has no zone")
        let unknownZone = try self.loop(["state": "active",
                                         "cadence": ["pattern": ["kind": "daily", "hour": 9, "minute": 0],
                                                     "cron": "0 9 * * *", "timezone": "Mars/Olympus_Mons"]])
        XCTAssertNil(unknownZone.foreignZone())
        // A zone with daylight saving is named as desktop's hover names it: generic, not the season's name.
        let pacific = try self.loop(["state": "active",
                                     "cadence": ["pattern": ["kind": "daily", "hour": 9, "minute": 0],
                                                 "cron": "0 9 * * *", "timezone": "America/Los_Angeles"]])
        XCTAssertEqual(pacific.foreignZone(viewer: berlin, at: july, locale: english),
                       TaskLoop.Zone(offset: "GMT-7", name: "Pacific Time"))
    }
}
