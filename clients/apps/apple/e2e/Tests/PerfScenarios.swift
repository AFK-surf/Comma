import XCTest

/// The perf plan's scenarios over the fixture's long router chat, one probe window each (`measureScenario`).
/// perf/measure.sh runs them N times per build and perf/compare.py prints the medians side by side, so every step
/// here is fixed: the same touches, the same waits, whatever the build.
@MainActor final class PerfScenarios: XCTestCase {
    /// When the current window began, and the steps `mark(_:)` noted in it.
    var windowStart: Date?
    var marks: [String: Double] = [:]

    /// S1: 30 characters typed one at a time into the router composer, with its keyboard already up.
    func testS1Typing() throws {
        let app = try launchPerfFixture()
        let composer = app.openRouterChat()
        composer.tap()
        composer.raiseKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let text = "The quick brown fox jumps over"
        try measureScenario("S1-typing", in: app) {
            for character in text { app.typeText(String(character)) }
        }
        XCTAssertEqual(composer.value as? String, text)
    }

    /// S2: the router chat while a 4 KB Markdown reply streams in 200 deltas at 30 Hz, until it completes and is
    /// committed. The reply starts 0.5 s after the signal (`PerfStream.lead`): XCUITest waits for an idle app
    /// before each touch, so the finger lands in that lead, drags the transcript slowly toward older messages and
    /// holds, scrolling through the first part of the stream; the rest streams untouched.
    func testS2Streaming() throws {
        let app = try launchPerfFixture(["--perf-stream"])
        app.openRouterChat()
        Thread.sleep(forTimeInterval: 1)
        try measureScenario("S2-streaming", in: app) {
            PerfSignal.stream.post()
            app.at(0.5, 0.35).press(forDuration: 0.05, thenDragTo: app.at(0.5, 0.65), withVelocity: .slow, thenHoldForDuration: 2)
            mark("released")
            // The deltas end 7.2 s after the signal; the commit, refresh and reconnect follow.
            Thread.sleep(forTimeInterval: max(1, 9.5 - Date().timeIntervalSince(windowStart ?? Date())))
        }
        // The drag left the reader above the reply, which the transcript does not pull back down, and rows that far
        // below the viewport are not built. Back to the end, then the committed reply must be there.
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        let ending = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "The streamed reply ends here")).firstMatch
        XCTAssertTrue(ending.waitForExistence(timeout: 5), "The streamed reply must be committed")
    }

    /// S3: five flings up the router transcript, then a pull past its top that loads 100 earlier messages.
    func testS3Scrolling() throws {
        let app = try launchPerfFixture()
        app.openRouterChat()
        Thread.sleep(forTimeInterval: 1)
        let pullIndicator = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Load earlier messages")).firstMatch
        try measureScenario("S3-scrolling", in: app) {
            for _ in 0..<5 { app.swipeDown(velocity: .fast) }
            // On to the top, wherever the flings ended, then a slow pull that is released past the threshold.
            var extra = 0
            while extra < 10, !pullIndicator.isHittable {
                app.swipeDown(velocity: .fast)
                extra += 1
            }
            // How many flings the top took, which changes with the transcript's height; compare runs with care.
            marks["extraFlings"] = Double(extra)
            mark("pull")
            app.at(0.5, 0.3).press(forDuration: 0.1, thenDragTo: app.at(0.5, 0.75), withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 2)
        }
        // The page lands with its oldest row at the top, as the pull leaves it. The transcript builds only the
        // rows near the viewport, so the page's newest row (Note 125) need not exist.
        let earlier = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Note 26.")).firstMatch
        XCTAssertTrue(earlier.waitForExistence(timeout: 5), "The pull must load the earlier page")
    }

    /// S4: the + menu opened by a tap, Photos chosen from it, Back to the menu, then closed by a tap outside.
    func testS4AttachmentMenu() throws {
        let app = try launchPerfFixture()
        app.openRouterChat()
        let plus = app.buttons["Add attachment"]
        XCTAssertTrue(plus.waitUntilHittable())
        // One untimed pass answers the photo access alert, which would otherwise land in the window.
        plus.tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitUntilHittable())
        photos.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitUntilHittable())
        back.tap()
        XCTAssertTrue(photos.waitUntilHittable())
        app.at(0.5, 0.35).tap()
        XCTAssertTrue(photos.waitUntilUnhittable())
        Thread.sleep(forTimeInterval: 1)
        try measureScenario("S4-attachment-menu", in: app) {
            plus.tap()
            Thread.sleep(forTimeInterval: 0.5)
            photos.tap()
            Thread.sleep(forTimeInterval: 1.5)
            back.tap()
            Thread.sleep(forTimeInterval: 1)
            app.at(0.5, 0.35).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(photos.waitUntilUnhittable(), "The menu must close")
    }

    /// S5: ten idle seconds on the router chat's tail, where the running Tasks' cards are on screen.
    func testS5IdleRunningTasks() throws {
        let app = try launchPerfFixture()
        app.openRouterChat()
        XCTAssertTrue(app.element("task-ref-task1").waitUntilHittable())
        Thread.sleep(forTimeInterval: 1)
        try measureScenario("S5-idle-running-tasks", in: app) { Thread.sleep(forTimeInterval: 10) }
    }

    /// S6: Task 0 opened from its card in the router chat, its sheet dragged down into the bar and back up five
    /// times, then its composer focused and dismissed.
    func testS6TaskDock() throws {
        let app = try launchPerfFixture()
        app.openRouterChat()
        Thread.sleep(forTimeInterval: 1)
        try measureScenario("S6-task-dock", in: app) {
            app.openTaskFromRouter()
            XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
            let title = app.taskTitle
            for _ in 0..<5 {
                app.minimizeTask()
                XCTAssertTrue(title.waitUntilHittable())
                title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.at(0.5, 0.2))
                Thread.sleep(forTimeInterval: 0.5)
            }
            let composer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
                .allElementsBoundByIndex.first(where: \.isHittable))
            composer.tap()
            composer.raiseKeyboard()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.staticTexts["No updates yet"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone(timeout: 3))
        }
    }

    /// S7: Inbox, Settings and Home in turn six times, then three flings down Home's list and three back.
    func testS7Tabs() throws {
        let app = try launchPerfFixture()
        let tabs = ["tab-inbox", "tab-settings", "tab-home"].map { app.buttons[$0] }
        try measureScenario("S7-tabs", in: app) {
            for _ in 0..<6 {
                for tab in tabs { tab.tap() }
            }
            for _ in 0..<3 { app.swipeUp(velocity: .fast) }
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(app.buttons["tab-home"].isSelected)
    }

    /// S8: the router chat opened from its button and closed by its close button, five times.
    func testS8RouterOpenClose() throws {
        let app = try launchPerfFixture()
        let open = app.buttons["openRouterChat"]
        let close = app.buttons["closeRouterChat"]
        try measureScenario("S8-router-open-close", in: app) {
            for _ in 0..<5 {
                XCTAssertTrue(open.waitUntilHittable())
                open.tap()
                XCTAssertTrue(close.waitUntilHittable())
                close.tap()
                XCTAssertTrue(app.routerComposer.waitUntilGone())
            }
        }
    }

    /// S9: the composer's menus with the keyboard up: @ from its button, "29" typed a character at a time and Task 29
    /// picked, then / from its button, "pdf" typed and the skill picked.
    func testS9TriggerMenu() throws {
        let app = try launchPerfFixture()
        let composer = app.openRouterChat()
        composer.tap()
        composer.raiseKeyboard()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let mention = app.element("composerMention"), skill = app.element("composerSkill")
        XCTAssertTrue(mention.waitUntilHittable())
        Thread.sleep(forTimeInterval: 1)
        try measureScenario("S9-trigger-menu", in: app) {
            mention.tap()
            for character in "29" { app.typeText(String(character)) }
            app.element("menu-task:task29").tap()
            skill.tap()
            for character in "pdf" { app.typeText(String(character)) }
            app.element("menu-pdf").tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(composer.value as? String, "@Task 29 /pdf ")
    }
}
