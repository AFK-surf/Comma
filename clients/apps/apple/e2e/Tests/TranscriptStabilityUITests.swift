import XCTest

/// A long Home conversation whose rows range from one line to several screens (`--perf-varied-chat`, the 500
/// messages a device keeps). The transcript must show its rows, keep the reader's place and keep the reader inside
/// the content while it opens, is read upward, takes a send and has a Task's sheet open and minimized over it;
/// `--transcript-probe` counts each frame of the transcript's scroll view. Only iOS 26 shows the failures: its lazy
/// stack changed its estimated height as the reader scrolled and could leave the transcript at an estimated end with
/// no row drawn, and its scroll position was not applied once the reader had scrolled.
@MainActor final class TranscriptStabilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        XCUIApplication.fixture(arguments: ["--perf-varied-chat", "--perf-hold-stream", "--transcript-probe"])
    }

    private func note(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Note \(index).")).firstMatch
    }

    /// The probe's counts since launch, by name.
    private func geometry(_ app: XCUIApplication) -> [String: Int] {
        let label = app.staticTexts["transcriptGeometry"].label
        return Dictionary(uniqueKeysWithValues: label.split(separator: "|").compactMap { pair in
            let parts = pair.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), Int(parts[1]) ?? -1) : nil
        })
    }

    func testLongVariedChatShowsItsRowsThroughOpenReadSendAndTaskDock() throws {
        let app = launch()
        let composer = app.openRouterChat()
        // On screen, not only built: a transcript left past the end of its rows shows nothing until a touch.
        XCTAssertTrue(note(app, 599).waitUntilHittable(timeout: 10), "The chat opens on its newest reply")
        Thread.sleep(forTimeInterval: 2)
        // Up through the long reports, which a lazy stack had not measured.
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 2)

        composer.tap()
        composer.typeText("Where does the launch stand?")
        app.element("sendMessage").tap()
        let sent = app.staticTexts.matching(NSPredicate(format: "label == %@", "Where does the launch stand?")).firstMatch
        XCTAssertTrue(sent.waitUntilHittable(), "The send shows at the end of the transcript")
        Thread.sleep(forTimeInterval: 2)

        app.openTaskFromRouter()
        XCTAssertTrue(app.taskTitle.waitUntilHittable(timeout: 10), "Task 0's sheet opens over the chat")
        Thread.sleep(forTimeInterval: 1.5)
        app.minimizeTask()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(sent.waitUntilHittable(), "The send stays in view after the sheet minimizes")

        let counts = geometry(app)
        XCTAssertGreaterThan(counts["frames"] ?? 0, 0, "The probe must find the transcript (\(counts))")
        XCTAssertEqual(counts["drift"], 0, "The content height must not change under the reader's finger (\(counts))")
        XCTAssertEqual(counts["unheld"], 0, "Rows that join above the reader keep the reader's place (\(counts))")
        XCTAssertEqual(counts["blank"], 0, "The reader must never be left past the end of the content (\(counts))")
    }

    /// The newest reply answers a message far above the rows the transcript first shows; its quote takes the reader
    /// there.
    func testReplyPreviewRevealsATargetAboveTheShownRows() throws {
        let app = launch()
        app.openRouterChat()
        XCTAssertTrue(note(app, 599).waitUntilHittable(timeout: 10))
        let preview = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "View replied message: Note 248.")).firstMatch
        XCTAssertTrue(preview.waitUntilHittable(), "The newest reply quotes the message it answers")
        preview.tap()
        XCTAssertTrue(note(app, 248).waitUntilHittable(timeout: 5), "The quote reveals the message it answers")
    }

    /// Reading upward goes on past the rows the transcript first shows, without a pull.
    func testScrollingUpShowsEarlierRows() throws {
        let app = launch()
        app.openRouterChat()
        XCTAssertTrue(note(app, 599).waitUntilHittable(timeout: 10))
        let earlier = note(app, 570)
        var flings = 0
        while flings < 40, !earlier.exists {
            app.swipeDown(velocity: .fast)
            flings += 1
        }
        let counts = geometry(app)
        XCTAssertTrue(earlier.exists, "Scrolling up reaches rows above those first shown (\(flings) flings, \(counts))")
        XCTAssertGreaterThan(counts["growths"] ?? 0, 0, "Rows joined above the reader (\(counts))")
        XCTAssertEqual(counts["unheld"], 0, "The reader's place holds as rows join above them (\(counts))")
    }

    /// The earlier page the reader pulled for takes a while to come. Meanwhile a reply streaming in below leaves the
    /// reader where they pulled; when the page lands, its newest rows join above them and they stay where they are.
    func testAnEarlierPageThatTakesAWhileJoinsAboveTheReader() throws {
        let app = XCUIApplication.fixture(arguments: ["--perf-long-chat", "--perf-hold-stream", "--perf-stream", "--hold-earlier"])
        app.openRouterChat()
        let pull = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Load earlier messages")).firstMatch
        let held = app.staticTexts["earlierHeld"]
        // The rows above the window join it first; a pull past them asks the server.
        var pulls = 0
        while pulls < 10, held.label == "0" {
            // Up to the top of the rows shown, where the indicator comes on screen.
            var flings = 0
            while flings < 30, pull.frame.minY < 0 {
                app.swipeDown(velocity: .fast)
                flings += 1
            }
            app.at(0.5, 0.3).press(forDuration: 0.1, thenDragTo: app.at(0.5, 0.75), withVelocity: .slow, thenHoldForDuration: 0.3)
            pulls += 1
        }
        XCTAssertEqual(held.label, "1", "A pull asks the server for the earlier page")
        let top = pull.frame.minY

        PerfSignal.stream.post()
        // The reply is below the screen, where the test cannot see it; the server says when it has streamed to its end.
        let committed = app.staticTexts["replyCommitted"]
        XCTAssertTrue(committed.wait(for: \.label, toEqual: "committed", timeout: 20), "The reply streams in to its end")
        XCTAssertEqual(pull.frame.minY, top, accuracy: 1, "The reply growing below leaves the reader where they pulled")

        let first = note(app, 126)
        let place = first.frame.minY
        PerfSignal.releaseEarlier.post()
        let joined = note(app, 125)
        XCTAssertTrue(joined.waitForExistence(timeout: 5), "The page's newest rows join the transcript")
        XCTAssertLessThan(joined.frame.maxY, first.frame.minY, "above the rows that were first")
        XCTAssertEqual(first.frame.minY, place, accuracy: 1, "The reader stays where they were as the page joins above")
    }

    /// A Task's rows stretch with their avatar column. A transcript that shared its height out among them squeezed the
    /// Worker's question card: each choice fell to the 44 pt of one line and its description ran over the next choice.
    func testTaskQuestionCardChoicesHoldTheirDescriptions() throws {
        let app = XCUIApplication.fixture(arguments: ["--task-question"])
        let task = app.element("task-review0")
        XCTAssertTrue(task.waitForExistence(timeout: 10))
        task.tap()
        let labels = ["9C8953 不含托运", "CZ3677 含 20kg 托运", "9C8953 含 20kg 托运"]
        let choices = labels.map { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", $0)).firstMatch }
        XCTAssertTrue(choices[0].waitUntilHittable(timeout: 10), "The Task opens on the Worker's question")
        for (label, choice) in zip(labels, choices) {
            // A label line and a description line under it, inside the row's padding.
            XCTAssertGreaterThan(choice.frame.height, 60, "\(label) holds its description (\(choice.frame))")
        }
    }
}
