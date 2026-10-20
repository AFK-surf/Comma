import XCTest

/// Loop Tasks over the fixture (`loop0` paused, `loop1` running and `done0` ended on a schedule, `watch0` on updates,
/// `hook0` on a trigger the app cannot read): their rows name their trigger kind, also at large text, the Loops filter
/// offers each kind and narrows Home to Loop Tasks, and the details card shows what desktop Properties shows: the
/// kind, then the trigger rule and a pending, paused or ended state, never the runs. It lets the member end the Loop.
@MainActor final class ScheduleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// The fixture's crons run on Shanghai's wall clock. Their zone follows the rule, as one more text, when the
    /// simulator's offset differs.
    private static var zoneShows: Bool {
        TimeZone.current.secondsFromGMT() != TimeZone(identifier: "Asia/Shanghai")!.secondsFromGMT()
    }

    func testLoopTasksShowTheirTrigger() throws {
        let app = XCUIApplication.fixture()
        let loop = app.element("task-loop0")
        XCTAssertTrue(loop.waitForExistence(timeout: 10))
        XCTAssertTrue(loop.label.contains("Scheduled"), "A Loop's row names its trigger kind: \(loop.label)")
        XCTAssertFalse(app.element("task-review0").label.contains("Scheduled"))
        showOnlyLoopTasks(app, hiding: "task-review0")
        XCTAssertTrue(loop.waitUntilHittable())

        let facts = openLoopDetails(app, id: "loop0", title: "Check competitor prices", kind: "Scheduled")
        XCTAssertEqual(facts.first, "Every day at 9:00\u{202F}AM", "\(facts)")
        XCTAssertEqual(facts.last, "Paused until you reply", "A paused Loop says why: \(facts)")
        XCTAssertEqual(facts.count, Self.zoneShows ? 3 : 2, "Only the rule, its zone and the pause show: \(facts)")
        XCTAssertFalse(app.staticTexts["4/14 runs"].exists, "The run count does not show")
        // A paused Loop can be ended by hand: its status pill opens the Done and Cancelled menu.
        XCTAssertTrue(app.element("taskStatusMenu").isHittable)
    }

    /// An active Loop, in progress, shows only its trigger rule under its kind: no next run, last run or run count.
    /// One whose rule the app cannot read says Running.
    func testActiveLoopsShowOnlyTheirRule() throws {
        let loops: [(id: String, title: String, kind: String, rule: String, zone: Bool)] = [
            ("loop1", "Post the metrics digest", "Scheduled", "Every Mon, Wed at 6:30\u{202F}PM", Self.zoneShows),
            ("watch0", "Watch PR #12", "On updates", "new comments on PR #12", false),
            ("hook0", "Tidy the release notes", "Other trigger", "Running", false),
        ]
        for loop in loops {
            let app = XCUIApplication.fixture()
            XCTAssertTrue(app.element("task-loop0").waitForExistence(timeout: 10))
            app.buttons["In progress"].tap()
            XCTAssertTrue(app.element("task-task0").waitForExistence(timeout: 5))
            showOnlyLoopTasks(app, hiding: "task-task0")
            let facts = openLoopDetails(app, id: loop.id, title: loop.title, kind: loop.kind)
            XCTAssertEqual(facts.first, loop.rule, "\(loop.id): \(facts)")
            XCTAssertEqual(facts.count, loop.zone ? 2 : 1, "\(loop.id) shows only its rule: \(facts)")
        }
    }

    /// Narrows Home to Loop Tasks with the Loops filter, which offers each trigger kind; `hiding` is a Task of the
    /// shown status that is no Loop Task.
    private func showOnlyLoopTasks(_ app: XCUIApplication, hiding other: String) {
        app.element("openTaskFilters").tap()
        app.element("filterField-schedule").tap()
        let others = app.element("filterOption-comma:not-scheduled")
        XCTAssertTrue(others.waitUntilHittable())
        for kind in ["scheduled", "on-updates", "other-trigger"] {
            XCTAssertTrue(app.element("filterOption-comma:" + kind).exists, "Loops offers \(kind)")
        }
        others.tap()
        // Pulls the options page, then the filter sheet, down by their tops.
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
        }
        XCTAssertTrue(app.element("filterField-schedule").waitUntilGone())
        XCTAssertTrue(app.element(other).waitUntilGone(), "Loops narrows the list to Loop Tasks")
    }

    /// Opens a Loop Task's details card and returns the texts under its Loop heading, which names the trigger kind.
    private func openLoopDetails(_ app: XCUIApplication, id: String, title: String, kind: String) -> [String] {
        let row = app.element("task-" + id)
        XCTAssertTrue(row.waitUntilHittable(), id)
        row.tap()
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(header.waitUntilHittable(), title)
        header.tap()
        let section = app.element("taskLoopSection")
        XCTAssertTrue(section.waitForExistence(timeout: 5))
        XCTAssertEqual(section.staticTexts.firstMatch.label, kind, "The section is named by the trigger kind")
        return app.element("taskLoopFacts").staticTexts.allElementsBoundByIndex.map(\.label)
    }

    /// An ended Loop keeps its kind as the heading and shows only Ended.
    func testEndedLoopShowsOnlyEnded() throws {
        let app = XCUIApplication.fixture()
        app.buttons["Done"].tap()
        let task = app.element("task-done0")
        XCTAssertTrue(task.waitUntilHittable())
        XCTAssertTrue(task.label.contains("Scheduled"), "An ended Loop's row keeps its kind: \(task.label)")
        task.tap()
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Summarize this week’s support tickets")).firstMatch
        XCTAssertTrue(title.waitUntilHittable())
        title.tap()
        let facts = app.element("taskLoopFacts")
        XCTAssertTrue(facts.waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("taskLoopSection").staticTexts.firstMatch.label, "Scheduled")
        XCTAssertEqual(facts.staticTexts.allElementsBoundByIndex.map(\.label), ["Ended"])
    }

    /// At a large text size the chip beside a Loop's title keeps only its trigger kind's glyph, so the title keeps the
    /// row's room; the row still names the kind. Before, the worded chip took half the row and cut the title to two
    /// words.
    func testLargeTextLeavesTheTitleItsRoom() throws {
        let app = XCUIApplication.fixture(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        let loop = app.element("task-loop0")
        XCTAssertTrue(loop.waitForExistence(timeout: 10))
        XCTAssertTrue(loop.label.contains("Scheduled"), "The row still names the trigger kind: \(loop.label)")
        let chip = loop.staticTexts["Scheduled"], title = loop.staticTexts["Check competitor prices every morning"]
        XCTAssertTrue(chip.exists && title.exists)
        XCTAssertLessThan(chip.frame.width, chip.frame.height * 1.5, "The chip is the trigger glyph alone: \(chip.frame)")
        XCTAssertGreaterThan(title.frame.width, loop.frame.width / 2, "The title keeps most of the row: \(title.frame)")
    }
}
