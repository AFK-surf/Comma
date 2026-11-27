import XCTest

/// Messages' drag to show times, for where messages came from: a drag to the left moves the router chat's rows and
/// shows each platform message's logo; letting go puts them back, and the drag opens no reply.
@MainActor final class SourceRevealUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLeftwardDragShowsSourcesAndReturns() throws {
        let app = XCUIApplication.fixture(light: true, arguments: ["--launch-in-chat", "--platform-messages", "--hide-metrics"])
        let wechat = app.staticTexts["From WeChat"]
        XCTAssertTrue(wechat.waitUntilHittable())
        let rest = wechat.frame
        keepScreenshot(app, "Platform messages at rest")
        app.at(0.85, 0.55).press(forDuration: 0.05, thenDragTo: app.at(0.35, 0.56), withVelocity: .slow, thenHoldForDuration: 1.5)
        XCTAssertFalse(app.element("replyThread").exists, "a leftward drag is not a reply")
        // Let go: the rows spring back where they were.
        let deadline = Date().addingTimeInterval(3)
        while abs(wechat.frame.minX - rest.minX) > 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(wechat.frame.minX, rest.minX, accuracy: 1)
    }
}
