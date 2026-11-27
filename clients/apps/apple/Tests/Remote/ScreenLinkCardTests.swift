import XCTest
@testable import Comma

/// A screen card ends once a listing no longer has the boot it meant (ScreenLink.tsx's `gone`).
@MainActor
final class ScreenLinkCardTests: XCTestCase {
    private let screen = "simulator:ABC"

    private func row(_ instance: String) -> ListedDeviceScreen {
        ListedDeviceScreen(["id": screen, "instance": instance] as NSDictionary)!
    }

    func testNoListingYetSaysNothing() {
        XCTAssertFalse(ScreenLinkCard.ended(nil, screen: screen, meant: nil))
    }

    func testAListingWithTheMeantBootIsLive() {
        XCTAssertFalse(ScreenLinkCard.ended([row("a")], screen: screen, meant: "a"))
    }

    func testAnotherBootInItsPlaceHasEnded() {
        XCTAssertTrue(ScreenLinkCard.ended([row("b")], screen: screen, meant: "a"))
    }

    func testAListingWithoutTheDeviceHasEnded() {
        XCTAssertTrue(ScreenLinkCard.ended([], screen: screen, meant: nil))
    }
}
