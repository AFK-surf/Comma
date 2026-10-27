import XCTest

/// The tab shell over the fixture: the app opens on the router chat and keeps its page across the background, tabs
/// keep their state without reloading, the router chat opens over them and keeps its draft, Home's platform cards
/// settle on a card and carry a throw, Home leads into the Task dock, the archive and the router composer, search
/// opens from the tab bar ready to type, and another Task takes over a minimized dock.
@MainActor final class TabShellUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTabsKeepTheirStateWithoutReloading() throws {
        let app = XCUIApplication.fixture()
        XCTAssertTrue(app.element("task-review0").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Needs review"].isSelected, "Home opens on Needs review")
        app.buttons["In progress"].tap()
        XCTAssertTrue(app.element("task-task0").waitForExistence(timeout: 5))
        let loads = app.staticTexts["listLoads"].label
        let inbox = app.buttons["tab-inbox"]
        XCTAssertEqual(inbox.value as? String, "Unread", "Tasks waiting for review mark the Inbox")
        inbox.tap()
        XCTAssertTrue(app.element("inbox-review0").waitForExistence(timeout: 5))
        XCTAssertTrue(inbox.isSelected)
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["tab-home"].tap()
        XCTAssertTrue(app.element("task-task0").waitUntilHittable())
        XCTAssertTrue(app.buttons["In progress"].isSelected, "Home keeps its status across tabs")
        XCTAssertEqual(app.staticTexts["listLoads"].label, loads, "Switching tabs must not reload the list")
    }

    func testRouterChatOpensOverTheTabsAndKeepsItsDraft() throws {
        let app = XCUIApplication.fixture()
        let composer = app.openRouterChat()
        XCTAssertFalse(app.buttons["tab-home"].isHittable, "The router chat covers the tabs")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.typeText("Router draft")
        app.buttons["closeRouterChat"].tap()
        XCTAssertTrue(composer.waitUntilGone(), "Closing folds the chat back into its button")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.openRouterChat().value as? String, "Router draft")
        // A downward drag on the header closes it too.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(composer.waitUntilGone(), "A header drag closes the router chat")
        XCTAssertTrue(app.buttons["tab-home"].waitUntilHittable())
        // So does a drag toward the trailing edge from the chat's leading third, like going back; on a message the
        // same drag replies to it instead (ReplyThreadUITests). One let go short and slow springs back open, and one
        // from further in (here across the header, where there is no message) leaves the chat open.
        XCTAssertEqual(app.openRouterChat().value as? String, "Router draft")
        app.at(0.03, 0.5).press(forDuration: 0.05, thenDragTo: app.at(0.18, 0.5), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(composer.waitUntilHittable(), "A short sideways drag springs the chat back open")
        XCTAssertFalse(app.buttons["tab-home"].isHittable)
        app.at(0.5, 0.08).press(forDuration: 0.05, thenDragTo: app.at(0.95, 0.09))
        XCTAssertFalse(composer.waitUntilGone(timeout: 1.5), "A sideways drag from mid-screen leaves the chat open")
        XCTAssertFalse(app.buttons["tab-home"].isHittable)
        app.at(0.03, 0.5).press(forDuration: 0.05, thenDragTo: app.at(0.9, 0.55))
        XCTAssertTrue(composer.waitUntilGone(), "A sideways drag closes the router chat")
        XCTAssertTrue(app.buttons["tab-home"].waitUntilHittable())
    }

    func testOpensOnTheChatAndKeepsThePageInTheBackground() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat"])
        // A fresh launch opens on the chat, already in place.
        let composer = app.routerComposer
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.waitUntilHittable(), "The app opens on the chat")
        XCTAssertFalse(app.buttons["tab-home"].isHittable, "The chat covers the tabs")
        // Back from the background, the chat is still open.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(composer.waitUntilHittable(), "Coming back keeps the chat open")
        // And a tab the member moved to stays selected, with the chat still closed.
        app.buttons["closeRouterChat"].tap()
        XCTAssertTrue(composer.waitUntilGone())
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitUntilHittable())
        inbox.tap()
        XCTAssertTrue(inbox.isSelected)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(inbox.waitUntilHittable(), "Coming back keeps the page")
        XCTAssertTrue(inbox.isSelected, "Coming back keeps the selected tab")
        XCTAssertFalse(composer.exists, "Coming back does not reopen the chat")
    }

    func testSearchOpensFromTheTabBarAndKeepsTheTab() throws {
        let app = XCUIApplication.fixture()
        let inbox = app.buttons["tab-inbox"]
        XCTAssertTrue(inbox.waitUntilHittable(timeout: 10))
        inbox.tap()
        // Search's button beside Inbox opens the system's search field, focused with the keyboard up.
        app.buttons["openTaskSearch"].tap()
        let field = app.searchFields["Search tasks"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search opens with the keyboard up")
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
        XCTAssertFalse(inbox.isHittable, "Search covers the tabs")
        field.typeText("launch")
        // The field's close button (the search bar's Cancel before iOS 26) closes search on the tab it opened over.
        let closeSearch = if #available(iOS 26.0, *) { app.buttons["close"] } else { app.buttons["Cancel"] }
        closeSearch.tap()
        XCTAssertTrue(field.waitUntilGone(), "Closing search puts the field away")
        XCTAssertTrue(inbox.waitUntilHittable(), "Closing search returns to the tabs")
        XCTAssertTrue(inbox.isSelected, "Search leaves the selected tab as it was")
    }

    func testPlatformCardsSettleOnACardAndCarryAThrow() throws {
        let app = XCUIApplication.fixture()
        let slack = app.buttons["platform-conn-slack"], linear = app.buttons["platform-conn-linear"]
        let last = app.buttons["platform-conn-github"]
        XCTAssertTrue(linear.waitForExistence(timeout: 10))
        let margin = slack.frame.minX - app.frame.minX
        let row = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 0, dy: linear.frame.midY))
        func settled(_ card: XCUIElement, leading: Bool, _ message: String) {
            Thread.sleep(forTimeInterval: 1.2)
            let edge = leading ? card.frame.minX - app.frame.minX : app.frame.maxX - card.frame.maxX
            XCTAssertEqual(edge, margin, accuracy: 2, message)
        }
        // Let go still past half a card, and the row settles on the next card rather than between two.
        row.withOffset(CGVector(dx: 300, dy: 0)).press(forDuration: 0.05, thenDragTo: row.withOffset(CGVector(dx: 200, dy: 0)),
                                                       withVelocity: .slow, thenHoldForDuration: 0.3)
        settled(linear, leading: true, "A drag let go still settles on the nearest card")
        row.withOffset(CGVector(dx: 40, dy: 0)).press(forDuration: 0.02, thenDragTo: row.withOffset(CGVector(dx: 360, dy: 0)),
                                                      withVelocity: XCUIGestureVelocity(3000), thenHoldForDuration: 0)
        settled(slack, leading: true, "A throw back returns to the first card")
        // A hard throw carries the row as far as its speed takes it, here to the end, not one card at a time.
        row.withOffset(CGVector(dx: 320, dy: 0)).press(forDuration: 0.02, thenDragTo: row.withOffset(CGVector(dx: 200, dy: 0)),
                                                       withVelocity: XCUIGestureVelocity(3000), thenHoldForDuration: 0)
        settled(last, leading: false, "A hard throw carries the row to its end")
    }

    func testHomeOpensTasksTheArchiveAndPreTasks() throws {
        let app = XCUIApplication.fixture()
        let review = app.element("task-review0")
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(close.waitUntilGone())
        // The archive reads past an empty first page.
        app.element("openArchivedTasks").tap()
        XCTAssertTrue(app.element("task-arch0").waitForExistence(timeout: 5))
        app.element("closeArchivedTasks").tap()
        XCTAssertTrue(app.element("task-arch0").waitUntilGone())
        // A pre-task goes into the router composer and waits there for the member to send it.
        let slack = app.element("platform-conn-slack")
        XCTAssertTrue(slack.waitForExistence(timeout: 5))
        XCTAssertEqual(slack.label, "Slack, 3 suggested tasks")
        XCTAssertEqual(app.element("platform-conn-github").label, "GitHub, acme, nothing new")
        slack.tap()
        // A member task's card shows the source words it quotes, and its minus stops suggesting the source item.
        let task = app.element("pretask-item-0")
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        XCTAssertTrue(task.label.contains("the rerun is green"), "The card shows its quote: \(task.label)")
        XCTAssertTrue(app.element("pretask-dismiss-item-0").exists)
        let item = app.element("pretask-item-1")
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let composer = app.routerComposer
        let filled = NSPredicate(format: "value CONTAINS %@", "Summarize the #launch thread")
        wait(for: [expectation(for: filled, evaluatedWith: composer)], timeout: 5)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The composer takes focus")
    }

    /// A minimized Task keeps the status switcher over its bar, and another Task opened then takes over the dock,
    /// raised, with its own title.
    func testAnotherTaskTakesOverAMinimizedDock() throws {
        let app = XCUIApplication.fixture()
        let first = app.element("task-review0")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let close = app.buttons["Close task"]
        XCTAssertTrue(close.waitUntilHittable())
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)))
        XCTAssertTrue(app.buttons["Done"].waitUntilHittable(), "The status switcher shows over the minimized Task")
        let second = app.element("task-review1")
        XCTAssertTrue(second.waitUntilHittable())
        second.tap()
        let title = app.buttons.matching(NSPredicate(format: "label == %@", "Draft the Q4 planning notes")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The dock shows the Task opened last")
        XCTAssertTrue(app.buttons["Done"].waitUntilUnhittable(), "The raised sheet covers the switcher")
        close.tap()
        XCTAssertTrue(close.waitUntilGone())
    }
}
