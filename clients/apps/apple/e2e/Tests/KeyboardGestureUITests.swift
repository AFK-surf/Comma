import XCTest
import UIKit

/// The router chat's and the Task dock's keyboards, drafts and card edges. The router chat is the layer
/// opened from the button beside the tab bar; Task 0 opens from the reference card in its newest message.
@MainActor final class KeyboardGestureUITests: XCTestCase {
    func testRouterCardBackgroundAndBottomCornersWithMinimizedTask() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture(light: true)
        let composer = app.openRouterChat()
        let safeBottom = try XCTUnwrap(Double(app.staticTexts["windowBottomInset"].label))
        guard safeBottom > 0 else { throw XCTSkip("Requires a device with a bottom safe area") }
        func checkBottom(_ name: String) throws {
            let screenshot = keepScreenshot(app, name)
            // Sample the composer's blur band in the bottom safe area, below the input. It holds the light
            // tone the keyboard's corners match (about 245), never the black canvas of a Task gap.
            let rgba = try pixel(screenshot, at: CGPoint(x: app.frame.midX, y: app.frame.maxY - safeBottom / 2), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertGreaterThanOrEqual(component, 235, "The router chat's light band must continue below the input: \(rgba)")
            }
        }
        try checkBottom("Router bottom before opening Task")
        app.openTaskFromRouter()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.minimizeTask()
        let minimized = keepScreenshot(app, "Router card bottom corners above minimized Task")
        let bottom = app.frame.maxY - safeBottom - 66
        for x in [app.frame.minX + 3, app.frame.maxX - 3] {
            let rgba = try pixel(minimized, at: CGPoint(x: x, y: bottom - 3), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertLessThanOrEqual(component, 20, "Both bottom corners must expose the black gap around the rounded app card: \(rgba)")
            }
        }
        let middle = try pixel(minimized, at: CGPoint(x: app.frame.midX, y: bottom - 3), in: app.frame)
        XCTAssertGreaterThan(middle[0], 220, "The card surface must remain visible between its bottom corners")
        close.tap()
        XCTAssertTrue(composer.waitUntilHittable())
        try checkBottom("Router bottom after closing Task")
    }

    func testTaskCardResizesWithoutRepeatedTranscriptLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--card-motion-probe"]
        app.launch()
        let toggle = app.buttons["toggleMotionTask"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let count = { try XCTUnwrap(Int(app.staticTexts["cardViewportLayouts"].label)) }
        let height = { try XCTUnwrap(Double(app.staticTexts["cardViewportHeight"].label)) }
        for _ in 0..<3 {
            let beforeOpen = try count()
            let fullHeight = try height()
            toggle.tap()
            XCTAssertLessThanOrEqual(try count() - beforeOpen, 2, "Opening must not relayout the transcript every animation frame")
            XCTAssertEqual(fullHeight - (try height()), 66, accuracy: 2)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "motionDraft").firstMatch.isHittable)
            let beforeClose = try count()
            toggle.tap()
            XCTAssertLessThanOrEqual(try count() - beforeClose, 2, "Closing must not relayout the transcript every animation frame")
            XCTAssertEqual(try height(), fullHeight, accuracy: 2)
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "motionDraft").firstMatch.value as? String, "Keep this draft")
    }

    func testMinimizedTaskDoesNotAddAGapAboveRouterKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture(light: true)
        let composer = app.openRouterChat()
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Home draft")
        XCTAssertTrue(app.keyboards.firstMatch.isHittable, "Requires the system software keyboard to be visible")
        XCTAssertLessThan(app.keyboards.firstMatch.frame.minY, app.frame.maxY)
        func checkKeyboardBottom(_ name: String) throws {
            let screenshot = keepScreenshot(app, name)
            let rgba = try pixel(screenshot, at: CGPoint(x: app.frame.minX + 3, y: app.frame.maxY - 4), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertGreaterThan(component, 150, "The light keyboard's bottom background must not expose the black Task canvas: \(rgba)")
            }
        }
        try checkKeyboardBottom("Router keyboard without Task")
        let keyboardGap = app.keyboards.firstMatch.frame.minY - composer.frame.maxY
        let homeDraft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "chatComposer", "Home draft")).firstMatch
        app.openTaskFromRouter()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        app.minimizeTask()
        let title = app.taskTitle
        XCTAssertTrue(homeDraft.waitUntilHittable())
        homeDraft.tap()
        homeDraft.raiseKeyboard()
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.keyboards.firstMatch)], timeout: 5)
        try checkKeyboardBottom("Router keyboard with minimized Task")
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY - homeDraft.frame.maxY, keyboardGap, accuracy: 2,
                       "The minimized Task must not reserve space between the router input and keyboard")
        XCTAssertEqual(homeDraft.value as? String, "Home draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        XCTAssertTrue(title.waitUntilHittable())
        XCTAssertLessThanOrEqual(homeDraft.frame.maxY, title.frame.minY,
                                 "The Task bar must regain its space when the keyboard closes")
        XCTAssertEqual(homeDraft.value as? String, "Home draft")
    }

    func testTaskComposerRespectsBottomSafeAreaAndKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let inProgress = app.buttons["In progress"]
        XCTAssertTrue(inProgress.waitForExistence(timeout: 10))
        let safeBottom = try XCTUnwrap(Double(app.staticTexts["windowBottomInset"].label))
        guard safeBottom > 0 else { throw XCTSkip("Requires a device with a bottom safe area") }
        inProgress.tap()
        let task = app.buttons["task-task0"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        let composer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
            .allElementsBoundByIndex.first(where: \.isHittable))
        XCTAssertGreaterThanOrEqual(app.frame.maxY - composer.frame.maxY, safeBottom,
                                    "The Task input must stay above the Home indicator before any keyboard event")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Task draft")
        XCTAssertGreaterThanOrEqual(app.keyboards.firstMatch.frame.minY - composer.frame.maxY, 8,
                                    "The keyboard must leave room for the input")
        app.staticTexts["No updates yet"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        XCTAssertGreaterThanOrEqual(app.frame.maxY - composer.frame.maxY, safeBottom)
        XCTAssertEqual(composer.value as? String, "Task draft")
    }

    func testOpeningAndReexpandingTaskDismissesRouterKeyboardAndKeepsDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let homeComposer = app.openRouterChat()
        homeComposer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        homeComposer.typeText("Home draft")
        let homeDraft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "chatComposer", "Home draft")).firstMatch
        app.openTaskFromRouter()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        let hidden = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)

        let title = app.taskTitle
        for dragToExpand in [false, true] {
            app.minimizeTask()
            XCTAssertTrue(homeDraft.waitUntilHittable())
            XCTAssertEqual(homeDraft.value as? String, "Home draft")
            homeDraft.tap()
            homeDraft.raiseKeyboard()
            XCTAssertTrue(app.keyboards.firstMatch.waitUntilHittable())
            // The minimized bar is covered by the software keyboard; the Task's reference card stays reachable.
            app.openTaskFromRouter()
            wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
            XCTAssertEqual(homeDraft.value as? String, "Home draft")
            app.minimizeTask()
            XCTAssertTrue(homeDraft.waitUntilHittable())
            if dragToExpand {
                title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            } else {
                title.tap()
            }
            wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        }
        let taskComposer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
            .allElementsBoundByIndex.first(where: \.isHittable))
        taskComposer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        taskComposer.typeText("Task draft")
        XCTAssertEqual(taskComposer.value as? String, "Task draft")
        app.buttons["Close task"].tap()
        wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        XCTAssertEqual(homeDraft.value as? String, "Home draft")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Returning to the router chat must not restore its old focus")
    }

    func testScrollingRouterHistoryDismissesKeyboardAndPreservesDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Keep this draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 3)
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText(" again")
        let edited = try XCTUnwrap(composer.value as? String)
        XCTAssertTrue(edited.contains(" again"))
        XCTAssertEqual(edited.replacingOccurrences(of: " again", with: ""), "Keep this draft")
    }

    /// Taking the composer while reading history brings the newest message back above it, as Messages does.
    func testFocusingRouterComposerScrollsToNewestMessage() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        // Task 0's reference card is under the router chat's newest message.
        let newest = app.element("task-ref-task0")
        XCTAssertTrue(newest.waitUntilHittable(), "The router chat opens on its newest message")
        app.readEarlierMessages()
        XCTAssertTrue(newest.waitUntilOutOfView(), "Reading history leaves the newest message out of view")
        composer.tap()
        XCTAssertTrue(newest.waitUntilHittable(), "Taking the composer must bring the newest message into view")
        XCTAssertLessThanOrEqual(newest.frame.maxY, composer.frame.minY, "The newest message must end above the composer")
    }

    /// Taking a Task's composer at its newest message keeps that message above the composer as the keyboard rises, as
    /// Messages does. The Task dock makes room for the keyboard with the transcript's inset, not its size.
    func testFocusingTaskComposerKeepsNewestMessageInView() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let task = app.element("task-review0")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        let newest = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Worker update 19")).firstMatch
        XCTAssertTrue(newest.waitUntilHittable(), "The Task opens on its newest message")
        let composer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
            .allElementsBoundByIndex.first(where: \.isHittable))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let settled = expectation(for: NSPredicate { _, _ in newest.frame.maxY <= composer.frame.minY }, evaluatedWith: nil)
        wait(for: [settled], timeout: 3)
        XCTAssertTrue(newest.isHittable, "The newest message stays in view above the composer")
    }

    /// A reply sent to a Task while reading its Worker's history lands in view, where its bubble's flight ends.
    func testTaskReplySentWhileReadingHistoryLandsInView() throws {
        continueAfterFailure = false
        let app = XCUIApplication.fixture()
        let task = app.element("task-review0")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        let newest = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Worker update 19")).firstMatch
        XCTAssertTrue(newest.waitUntilHittable(), "The Task opens on its newest message")
        let composer = try XCTUnwrap(app.descendants(matching: .any).matching(identifier: "chatComposer")
            .allElementsBoundByIndex.first(where: \.isHittable))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Ship it")
        // The reply is found by what the field holds: typed straight after the Task opens, its first letter can be lost.
        let reply = try XCTUnwrap(composer.value as? String)
        // Reading back puts the keyboard down and keeps the draft, so the send below starts away from the end.
        app.readEarlierMessages()
        XCTAssertTrue(newest.waitUntilOutOfView(), "Reading history leaves the newest message out of view")
        app.buttons["sendMessage"].firstMatch.tap()
        let sent = app.staticTexts[reply]
        XCTAssertTrue(sent.waitUntilHittable(), "The sent reply must land in view")
        XCTAssertLessThanOrEqual(sent.frame.maxY, composer.frame.minY, "The sent reply must land above the composer")
    }
}
