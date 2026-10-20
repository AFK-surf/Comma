import XCTest

/// What of the router chat counts as seen: the reply the member is looking at, which the app badge acknowledges.
@MainActor final class RouterReadUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A reply streamed in while the member watches the end of the chat counts as seen once it is committed,
    /// although its bubble keeps the draft's row and never leaves the screen.
    func testStreamedReplyWatchedToTheEndCountsAsSeen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "--perf-long-chat", "--perf-hold-stream", "--perf-stream"]
        app.launch()
        app.openRouterChat()
        let seen = app.staticTexts["displayedReply"]
        XCTAssertTrue(seen.waitForExistence(timeout: 5))
        XCTAssertTrue(seen.wait(for: \.label, toEqual: "message149", timeout: 5), "The newest reply on screen counts as seen")
        PerfSignal.stream.post()
        // The deltas end 7.2 s after the signal; the commit, refresh and reconnect follow.
        XCTAssertTrue(seen.wait(for: \.label, toEqual: "message150", timeout: 20),
                      "The committed reply counts as seen, not only the one before it (\(seen.label))")
    }
}
