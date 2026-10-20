import XCTest

/// Settings' Profile over the fixture, whose first name save answers only when the test lets it.
@MainActor final class ProfileUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A name typed and submitted while the last one is still saving is saved after it, and stays in the field.
    func testNameSubmittedWhileAnotherSavesIsSavedAfterIt() throws {
        let app = XCUIApplication.fixture(arguments: ["--hold-first-profile-save"])
        let settings = app.buttons["tab-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let profile = app.element("openProfile")
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        let field = app.textFields["profileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Alex Rivera"), evaluatedWith: field)], timeout: 5)
        // As the member would: select the whole name, type over it and press Done.
        func submit(_ name: String) {
            field.tap()
            field.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
            selectAll.tap()
            field.typeText(name + "\n")
        }
        submit("Alice")
        submit("Alice Smith")
        // Both were asked for while the first saves; only now does it answer.
        PerfSignal.releaseSave.post()
        let saves = app.element("profileSaves")
        let both = NSPredicate(format: "label == %@", "Alice|Alice Smith")
        wait(for: [expectation(for: both, evaluatedWith: saves)], timeout: 20)
        XCTAssertEqual(field.value as? String, "Alice Smith", "The first save's answer must not replace the name typed after it")
    }
}
