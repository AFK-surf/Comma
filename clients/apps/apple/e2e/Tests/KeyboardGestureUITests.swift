import XCTest
import UIKit

@MainActor final class KeyboardGestureUITests: XCTestCase {
    func testHomeCardBackgroundAndBottomCornersWithMinimizedTask() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Light"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let safeBottom = try XCTUnwrap(Double(app.staticTexts["windowBottomInset"].label))
        guard safeBottom > 0 else { throw XCTSkip("Requires a device with a bottom safe area") }
        func checkBottom(_ name: String) throws {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            // Sample above the Home indicator, inside the container's bottom safe area.
            let rgba = try pixel(screenshot, at: CGPoint(x: app.frame.midX, y: app.frame.maxY - safeBottom + 4), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertGreaterThanOrEqual(component, 253, "Home's white background must continue below the input: \(rgba)")
            }
        }
        try checkBottom("Home bottom before opening Task")
        app.buttons["openTasks"].tap()
        let task = app.buttons["task-task0"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Task 0")).firstMatch
        title.tap()
        let minimized = app.screenshot()
        let attachment = XCTAttachment(screenshot: minimized)
        attachment.name = "Home bottom corners above minimized Task"
        attachment.lifetime = .keepAlways
        add(attachment)
        let bottom = app.frame.maxY - safeBottom - 66
        for x in [app.frame.minX + 3, app.frame.maxX - 3] {
            let rgba = try pixel(minimized, at: CGPoint(x: x, y: bottom - 3), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertLessThanOrEqual(component, 20, "Both bottom corners must expose the black gap around the rounded Home card: \(rgba)")
            }
        }
        let middle = try pixel(minimized, at: CGPoint(x: app.frame.midX, y: bottom - 3), in: app.frame)
        XCTAssertGreaterThan(middle[0], 220, "The card surface must remain visible between its bottom corners")
        close.tap()
        XCTAssertTrue(composer.isHittable)
        try checkBottom("Home bottom after closing Task")
    }

    private func pixel(_ screenshot: XCUIScreenshot, at point: CGPoint, in frame: CGRect) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let x = (point.x - frame.minX) / frame.width * CGFloat(image.width)
        let y = (point.y - frame.minY) / frame.height * CGFloat(image.height)
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
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

    func testMinimizedTaskDoesNotAddAGapAboveHomeKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Light"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Home draft")
        XCTAssertTrue(app.keyboards.firstMatch.isHittable, "Requires the system software keyboard to be visible")
        XCTAssertLessThan(app.keyboards.firstMatch.frame.minY, app.frame.maxY)
        func checkKeyboardBottom(_ name: String) throws {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let rgba = try pixel(screenshot, at: CGPoint(x: app.frame.minX + 3, y: app.frame.maxY - 4), in: app.frame)
            for component in rgba.prefix(3) {
                XCTAssertGreaterThan(component, 150, "The light keyboard's bottom background must not expose the black Task canvas: \(rgba)")
            }
        }
        try checkKeyboardBottom("Home keyboard without Task")
        let keyboardGap = app.keyboards.firstMatch.frame.minY - composer.frame.maxY
        let homeDraft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "chatComposer", "Home draft")).firstMatch
        app.buttons["openTasks"].tap()
        let task = app.buttons["task-task0"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Task 0")).firstMatch
        title.tap()
        XCTAssertTrue(homeDraft.isHittable)
        homeDraft.tap()
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.keyboards.firstMatch)], timeout: 5)
        try checkKeyboardBottom("Home keyboard with minimized Task")
        XCTAssertEqual(app.keyboards.firstMatch.frame.minY - homeDraft.frame.maxY, keyboardGap, accuracy: 2,
                       "The minimized Task must not reserve space between Home's input and keyboard")
        XCTAssertEqual(homeDraft.value as? String, "Home draft")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        XCTAssertTrue(title.isHittable)
        XCTAssertLessThanOrEqual(homeDraft.frame.maxY, title.frame.minY,
                                 "The Task bar must regain its space when the keyboard closes")
        XCTAssertEqual(homeDraft.value as? String, "Home draft")
    }

    func testTaskComposerRespectsBottomSafeAreaAndKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["openTasks"].waitForExistence(timeout: 10))
        let safeBottom = try XCTUnwrap(Double(app.staticTexts["windowBottomInset"].label))
        guard safeBottom > 0 else { throw XCTSkip("Requires a device with a bottom safe area") }
        app.buttons["openTasks"].tap()
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
        app.staticTexts["No messages yet"].tap()
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
        XCTAssertGreaterThanOrEqual(app.frame.maxY - composer.frame.maxY, safeBottom)
        XCTAssertEqual(composer.value as? String, "Task draft")
    }

    func testOpeningAndReexpandingTaskDismissesHomeKeyboardAndKeepsDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let homeComposer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(homeComposer.waitForExistence(timeout: 10))
        homeComposer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        homeComposer.typeText("Home draft")
        let homeDraft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "chatComposer", "Home draft")).firstMatch
        app.buttons["openTasks"].tap()
        let task = app.buttons["task-task0"]
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        XCTAssertTrue(app.buttons["Close task"].waitForExistence(timeout: 5))
        let hidden = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)

        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Task 0")).firstMatch
        for dragToExpand in [false, true] {
            title.tap()
            XCTAssertTrue(homeDraft.isHittable)
            XCTAssertEqual(homeDraft.value as? String, "Home draft")
            homeDraft.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            // The minimized bar is covered by the software keyboard; the sidebar remains reachable.
            app.buttons["openTasks"].tap()
            task.tap()
            wait(for: [expectation(for: hidden, evaluatedWith: app.keyboards.firstMatch)], timeout: 3)
            XCTAssertEqual(homeDraft.value as? String, "Home draft")
            title.tap()
            XCTAssertTrue(homeDraft.isHittable)
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
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Returning Home must not restore its old focus")
    }

    func testScrollingHomeHistoryDismissesKeyboardAndPreservesDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
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
}
