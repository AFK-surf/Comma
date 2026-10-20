import XCTest

@MainActor final class CallBubbleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDraggingAndExpandingAboveAppPresentations() {
        let app = XCUIApplication()
        app.launchArguments = ["--call-bubble-probe", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let bubble = app.buttons["callBubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertTrue(bubble.isHittable)
        app.buttons["underlyingAction"].tap()
        XCTAssertEqual(app.staticTexts["underlyingTaps"].label, "1", "Touches outside the bubble reach the app")

        let before = bubble.frame
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -170, dy: 230)))
        XCTAssertLessThan(bubble.frame.midX, before.midX - 100)
        XCTAssertGreaterThan(bubble.frame.midY, before.midY + 150)
        XCTAssertFalse(app.buttons["minimizeCall"].exists, "Dragging must not expand the call")
        let moved = bubble.frame
        bubble.tap()
        XCTAssertTrue(app.buttons["minimizeCall"].waitForExistence(timeout: 3))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(bubble.waitForExistence(timeout: 3), "A right swipe from the left edge minimizes the call")
        XCTAssertEqual(bubble.frame.midX, moved.midX, accuracy: 2)
        XCTAssertEqual(bubble.frame.midY, moved.midY, accuracy: 2)

        // Dragging to a screen corner leaves the entire bubble visible and tappable.
        bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero))
        XCTAssertGreaterThanOrEqual(bubble.frame.minX, 0)
        XCTAssertTrue(app.frame.contains(bubble.frame))
        XCTAssertTrue(bubble.isHittable)
        XCTAssertFalse(app.buttons["minimizeCall"].exists)

        app.buttons["openCallProbeSheet"].tap()
        XCTAssertTrue(app.buttons["closeCallProbeSheet"].waitForExistence(timeout: 3))
        bubble.tap()
        XCTAssertTrue(app.buttons["minimizeCall"].waitForExistence(timeout: 3), "Call expands over the sheet")
        app.buttons["minimizeCall"].tap()
        app.buttons["closeCallProbeSheet"].tap()
        app.buttons["openCallProbeCover"].tap()
        XCTAssertTrue(app.buttons["closeCallProbeCover"].waitForExistence(timeout: 3))
        bubble.tap()
        XCTAssertTrue(app.buttons["minimizeCall"].waitForExistence(timeout: 3), "Call expands over a full-screen cover")
        app.buttons["minimizeCall"].tap()
        app.buttons["closeCallProbeCover"].tap()
    }
}
