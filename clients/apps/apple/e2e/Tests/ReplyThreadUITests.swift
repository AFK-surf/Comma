import XCTest

/// Replying to a message as Messages does: a swipe to the right opens the message's thread over the transcript, a
/// send in it carries the message as its reply target, and a tap on the space around it closes it. The long-press menu opens the
/// same thread; its menu window is not in the fixture's accessibility tree, so it is checked by hand.
@MainActor final class ReplyThreadUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func bubble(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "History message \(index).")).firstMatch
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
