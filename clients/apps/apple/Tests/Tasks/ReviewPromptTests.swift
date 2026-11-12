import Foundation
import XCTest
@testable import Comma

/// When Comma asks for an App Store rating: at the third accepted result, then no sooner than 120 days later.
@MainActor
final class ReviewPromptTests: XCTestCase {
    /// This iPhone's preferences and clock, and the requests the app made.
    private final class Phone {
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var foreground = true
        var asked = 0

        /// The prompt as a launch makes it: the count and the last request are the preferences'.
        @MainActor func launch() -> ReviewPrompt {
            ReviewPrompt(preferences: preferences, now: { self.now }, settle: .zero) {
                guard self.foreground else { return false }
                self.asked += 1
                return true
            }
        }
    }

    /// The third accepted result asks; the first two do not.
    func testTheThirdAcceptedResultAsks() async {
        let phone = Phone()
        let prompt = phone.launch()
        await prompt.workAccepted()
        await prompt.workAccepted()
        XCTAssertEqual(phone.asked, 0)
        await prompt.workAccepted()
        XCTAssertEqual(phone.asked, 1)
    }

    /// After a request, accepted results ask again only once 120 days passed. Launches in between change nothing.
    func testTheNextRequestWaits120Days() async {
        let phone = Phone()
        for _ in 0..<3 { await phone.launch().workAccepted() }
        XCTAssertEqual(phone.asked, 1)

        phone.now += ReviewPrompt.interval - 1
        for _ in 0..<5 { await phone.launch().workAccepted() }
        XCTAssertEqual(phone.asked, 1)

        phone.now += 1
        await phone.launch().workAccepted()
        XCTAssertEqual(phone.asked, 2)
    }

    /// A request due while the app is out of the foreground is made at the next accepted result.
    func testARequestNoSceneCouldTakeStaysDue() async {
        let phone = Phone()
        let prompt = phone.launch()
        phone.foreground = false
        for _ in 0..<3 { await prompt.workAccepted() }
        XCTAssertEqual(phone.asked, 0)

        phone.foreground = true
        await prompt.workAccepted()
        XCTAssertEqual(phone.asked, 1)
    }
}
