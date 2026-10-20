import XCTest

/// The app's toast: a failure of what the member did, or of work in the background, over whichever page shows, and
/// the pages that have nothing to show for a failure saying so in place.
@MainActor final class ToastUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A Task action that fails reports once, as the toast under the status bar rather than a banner in the list, and
    /// a swipe up takes it away.
    func testFailedTaskActionIsOneToastThatSwipesAway() throws {
        let app = XCUIApplication.fixture(arguments: ["--fail-task-actions"])
        let task = app.element("task-review0")
        XCTAssertTrue(task.waitUntilHittable(timeout: 10))
        task.swipeLeft()
        app.buttons["Archive"].firstMatch.tap()
        let toast = app.element("toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "The failure shows as the toast")
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "This item changed"))
        XCTAssertTrue(message.allElementsBoundByIndex.allSatisfy { toast.frame.contains($0.frame) },
                      "Only the toast reports it, with no banner in the list")
        XCTAssertLessThan(toast.frame.minY, app.frame.height / 4, "It sits under the status bar")
        toast.swipeUp()
        // Well inside its five seconds on screen, so only the swipe can have taken it.
        XCTAssertTrue(toast.waitUntilGone(timeout: 1.5), "A swipe up takes it away")
    }

    /// A Task that could not be read at all says so in its sheet, with the toast saying why, and Try Again reads the
    /// whole Task rather than refreshing one that never loaded.
    func testTaskThatNeverLoadedSaysSoInPlaceAndReadsAgain() throws {
        let app = XCUIApplication.fixture(arguments: ["--fail-task-open"])
        let task = app.element("task-review0")
        XCTAssertTrue(task.waitUntilHittable(timeout: 10))
        task.tap()
        let failed = app.element("conversationFailed")
        XCTAssertTrue(failed.waitForExistence(timeout: 5), "The Task says it could not load")
        let toast = app.element("toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "The toast says why")
        XCTAssertFalse(app.element("toastAction").exists, "Only the page offers to read again")
        toast.swipeUp()
        XCTAssertTrue(toast.waitUntilGone(timeout: 1.5))
        XCTAssertTrue(failed.exists, "The page still says so once its toast has gone")
        app.recoverServer()
        app.buttons["Try Again"].firstMatch.tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Worker update")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Reading again shows the Task's messages")
        XCTAssertTrue(failed.waitUntilGone(), "The failure leaves with them")
    }

    /// With no Workspace read at launch, the chat the app opens on says it could not load rather than loading for ever,
    /// and Try Again reads the Workspace and opens the chat.
    func testLaunchWithoutAWorkspaceSaysSoInTheChatAndReadsAgain() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--fail-workspaces-once"])
        let failed = app.element("conversationFailed")
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "The chat says it could not load")
        XCTAssertTrue(app.element("toast").waitForExistence(timeout: 3), "The toast says why")
        failed.buttons["Try Again"].tap()
        XCTAssertTrue(app.element("chatComposer").waitForExistence(timeout: 5), "Reading again opens the chat")
        XCTAssertTrue(failed.waitUntilGone(), "The failure leaves")
    }

    /// A task list that could not be read says so where the Tasks would be, instead of "No tasks", and reads again.
    func testUnreadableTaskListSaysSoInPlaceAndReadsAgain() throws {
        let app = XCUIApplication.fixture(arguments: ["--fail-task-list"])
        let failed = app.element("taskListFailed")
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "Home says the list could not load")
        XCTAssertTrue(app.element("toast").waitForExistence(timeout: 3), "The toast says why")
        app.recoverServer()
        app.buttons["Try Again"].firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-"))
        XCTAssertTrue(row.firstMatch.waitForExistence(timeout: 5), "Reading again shows the Tasks")
        XCTAssertTrue(failed.waitUntilGone(), "The failure leaves with them")
    }
}
