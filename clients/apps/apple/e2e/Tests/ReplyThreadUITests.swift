import XCTest

/// Replying to a message as Messages does: a swipe to the right opens the message's thread over the transcript, a
/// send in it carries the message as its reply target, and a tap on the space around it closes it. The long-press menu opens the
/// same thread; its menu window is not in the fixture's accessibility tree, so it is checked by hand.
@MainActor final class ReplyThreadUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func bubble(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History message \(index).")).firstMatch
    }

    func testClosingReplyKeepsHeaderBelowStatusBar() throws {
        try checkReplyHeader(longChat: false)
    }

    func testReplyToEarlierMessageWithKeyboardOpen() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--call-controls", "--hide-metrics"])
        let composer = app.routerComposer
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let headerY = app.buttons["closeRouterChat"].frame.minY
        for index in [28, 29, 28] {
            let message = bubble(app, index)
            XCTAssertTrue(message.waitUntilHittable())
            let original = message.frame
            keepScreenshot(app, "Keyboard before replying to message \(index)")
            message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: message.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
            XCTAssertTrue(app.element("replyThread").waitForExistence(timeout: 3))
            keepScreenshot(app, "Message \(index) gathered above keyboard")
            app.at(0.5, 0.3).tap()
            XCTAssertTrue(app.element("replyThread").waitUntilGone())
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertEqual(message.frame.minY, original.minY, accuracy: 1,
                           "Closing a reply restores the original transcript position")
            XCTAssertEqual(app.buttons["closeRouterChat"].frame.minY, headerY, accuracy: 1)
        }
    }

    func testClosingLongReplyKeepsHeaderBelowStatusBar() throws {
        try checkReplyHeader(longChat: true)
    }

    func testClosingReplyAfterOpeningChatKeepsHeaderBelowStatusBar() throws {
        try checkReplyHeader(longChat: false, launchInChat: false)
    }

    func testClosingReplyFromEarlierHistoryKeepsHeaderBelowStatusBar() throws {
        try checkReplyHeader(longChat: false, earlierHistory: true)
    }

    private func checkReplyHeader(longChat: Bool, launchInChat: Bool = true, earlierHistory: Bool = false) throws {
        let app = XCUIApplication.fixture(arguments: ["--call-controls", "--hide-metrics"]
                                          + (launchInChat ? ["--launch-in-chat"] : [])
                                          + (longChat ? ["--perf-long-chat"] : []))
        let composer = launchInChat ? app.routerComposer : app.openRouterChat()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let close = app.buttons["closeRouterChat"]
        let call = app.buttons["startCall"]
        XCTAssertTrue(close.waitUntilHittable())
        XCTAssertTrue(call.waitUntilHittable())
        let headerY = close.frame.minY
        let callY = call.frame.minY
        XCTAssertGreaterThan(headerY, 40)
        keepScreenshot(app, "Header before replying")
        if earlierHistory { app.readEarlierMessages() }

        let message = longChat
            ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Note 149.")).firstMatch
            : bubble(app, earlierHistory ? 0 : 28)
        XCTAssertTrue(message.waitUntilHittable())
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: message.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.element("replyThread").waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(close.frame.minY, headerY, accuracy: 1, "Opening a reply preserves the header")
        app.at(longChat ? 0.01 : 0.5, 0.3).tap()
        XCTAssertTrue(app.element("replyThread").waitUntilGone())
        keepScreenshot(app, "Header after closing reply")
        XCTAssertEqual(close.frame.minY, headerY, accuracy: 1, "Closing a reply preserves the header")
        XCTAssertEqual(call.frame.minY, callY, accuracy: 1, "Closing a reply preserves the call button")
        // Scrolling the transcript dismisses the keyboard after the reply layer leaves.
        app.at(0.5, 0.4).press(forDuration: 0.05, thenDragTo: app.at(0.5, 0.6))
        XCTAssertTrue(app.keyboards.firstMatch.waitUntilGone())
        keepScreenshot(app, "Header after dismissing keyboard")
        XCTAssertEqual(close.frame.minY, headerY, accuracy: 1,
                       "Closing a reply must preserve the navigation bar's top safe area")
        XCTAssertEqual(call.frame.minY, callY, accuracy: 1, "Dismissing the keyboard preserves the call button")
    }

    func testSwipeRightRepliesInTheMessagesThread() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        let message = bubble(app, 28)
        XCTAssertTrue(message.waitUntilHittable())

        message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: message.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.element("replyThread").waitForExistence(timeout: 3), "A swipe past the threshold opens the thread")
        XCTAssertEqual(composer.placeholderValue, "Reply in thread", "The composer says where the send goes")

        composer.typeText("Shorter please")
        app.element("sendMessage").tap()
        let sent = app.staticTexts["lastSend"]
        XCTAssertTrue(sent.wait(for: \.label, toEqual: "text=Shorter please|skills=|reply=message28", timeout: 5),
                      "The send answers the swiped message (\(sent.label))")
        XCTAssertTrue(app.element("replyThread").exists, "The thread stays open for the conversation that follows")

        // A tap on the blurred space above the thread closes it.
        app.at(0.5, 0.3).tap()
        XCTAssertTrue(app.element("replyThread").waitUntilGone(), "Closing the thread returns to the transcript")
        composer.typeText("Unrelated")
        app.element("sendMessage").tap()
        XCTAssertTrue(sent.wait(for: \.label, toEqual: "text=Unrelated|skills=", timeout: 5),
                      "After closing, a send replies to nothing (\(sent.label))")
    }
}
