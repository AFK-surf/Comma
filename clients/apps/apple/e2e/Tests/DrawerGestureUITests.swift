import XCTest

@MainActor final class DrawerGestureUITests: XCTestCase {
    func testEdgeDismissalPreservesStatusAndNeverRefreshes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let open = app.buttons["openTasks"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let loads = app.staticTexts["listLoads"]
        XCTAssertTrue(app.buttons["openTasks"].exists)
        open.tap()
        XCTAssertTrue(app.buttons["task-task0"].waitForExistence(timeout: 5))
        let initialLoads = loads.label
        let initialStatus = app.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch.label
        for end in [CGVector(dx: 0.05, dy: 0.5), CGVector(dx: 0.1, dy: 0.7)] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: end))
            XCTAssertTrue(open.waitForExistence(timeout: 5), "The edge swipe must close the drawer")
            XCTAssertEqual(loads.label, initialLoads, "Closing must not refresh")
            open.tap()
            XCTAssertTrue(app.buttons["task-task0"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch.label, initialStatus)
        }
        // A vertical edge drag is swallowed; the list must stay at its first row.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)))
        XCTAssertTrue(app.buttons["task-task0"].exists)
        XCTAssertEqual(loads.label, initialLoads)
        // The same vertical drag away from the edge still refreshes.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        let refreshed = expectation(for: NSPredicate(format: "label != %@", initialLoads), evaluatedWith: loads)
        wait(for: [refreshed], timeout: 5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        let changed = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["Needs review"])
        wait(for: [changed], timeout: 5)
    }
}
