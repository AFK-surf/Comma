import XCTest

/// The composer's microphone. The fixture server writes every recording out as the same words, so the words reaching
/// the draft show that a recording ended and was sent, whatever the simulator's microphone heard.
@MainActor final class DictationUITests: XCTestCase {
    private let words = "Book the room for Friday"

    override func setUp() { continueAfterFailure = false }

    /// The permission prompt makes the scene inactive and cancels the touch; neither ends the recording it interrupts.
    func testThePermissionPromptLeavesTheRecordingRunning() throws {
        XCUIApplication().resetAuthorizationStatus(for: .microphone)
        let (app, mic) = openComposer()
        mic.tap()
        allowMicrophone()
        let stop = app.buttons["Stop dictation"]
        XCTAssertTrue(stop.waitUntilHittable(), "The recording runs on after the prompt")
        XCTAssertFalse(app.element("toast").exists, "The prompt is no failure")
        stop.tap()
        expectWords(in: app)
    }

    /// A hold that lifts while the recorder starts ends the recording all the same.
    func testAHoldThatLiftsAsTheMicrophoneStartsEndsTheRecording() throws {
        let (app, mic) = openComposerWithTheMicrophoneHeld()
        mic.press(forDuration: 0.5)
        PerfSignal.releaseMicrophone.post()
        expectWords(in: app)
    }

    /// A tap on the capsule while the recorder starts ends the recording once it is up, and nothing has failed.
    func testATapAsTheMicrophoneStartsEndsTheRecording() throws {
        let (app, mic) = openComposerWithTheMicrophoneHeld()
        mic.tap()
        app.buttons["Stop dictation"].tap()
        PerfSignal.releaseMicrophone.post()
        expectWords(in: app)
    }

    /// A recording started right after one cancelled while the recorder starts gets the microphone: the cancelled
    /// one's stop comes first.
    func testARecordingStartedRightAfterACancelGetsTheMicrophone() throws {
        let (app, mic) = openComposerWithTheMicrophoneHeld()
        mic.tap()
        app.buttons["Cancel dictation"].tap()
        XCTAssertTrue(app.buttons["Dictate message"].waitUntilHittable())
        mic.tap()
        PerfSignal.releaseMicrophone.post()
        let stop = app.buttons["Stop dictation"]
        XCTAssertTrue(stop.waitUntilHittable())
        stop.tap()
        expectWords(in: app)
    }

    private func openComposer(arguments: [String] = []) -> (XCUIApplication, XCUICoordinate) {
        let app = XCUIApplication.fixture(arguments: arguments)
        app.openRouterChat()
        // The control lies over the whole row; only the microphone's corner, the 44pt before Send, answers a touch.
        let control = app.element("dictateMessage")
        XCTAssertTrue(control.waitUntilHittable())
        let mic = control.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -66, dy: -22))
        return (app, mic)
    }

    /// The system answers the permission first, so that no prompt comes between the test and the held start.
    private func openComposerWithTheMicrophoneHeld() -> (XCUIApplication, XCUICoordinate) {
        XCUIApplication().resetAuthorizationStatus(for: .microphone)
        let (app, mic) = openComposer()
        mic.tap()
        allowMicrophone()
        XCTAssertTrue(app.buttons["Stop dictation"].waitUntilHittable())
        app.terminate()
        return openComposer(arguments: ["--hold-microphone"])
    }

    private func allowMicrophone() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "The system asks for the microphone")
        allow.tap()
    }

    private func expectWords(in app: XCUIApplication) {
        let arrived = expectation(for: NSPredicate(format: "value CONTAINS %@", words), evaluatedWith: app.routerComposer)
        wait(for: [arrived], timeout: 15)
    }
}
