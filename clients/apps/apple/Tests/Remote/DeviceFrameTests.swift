import XCTest
@testable import Comma

/// A flat device's case stands as its picture does (screenCase.ts `screenCaseOf`): the panel of the picture's shape,
/// turned a quarter when the picture lies across it, and none for a picture no panel has the shape of.
@MainActor
final class DeviceFrameTests: XCTestCase {
    private let phone = DeviceLook.Case(
        key: "phone", width: 400, height: 800, frame: CGSize(width: 440, height: 880),
        screen: CGRect(x: 20, y: 40, width: 400, height: 800), corners: [0.1, 0.1, 0.1, 0.1], reach: nil, shapes: nil,
        buttons: [DeviceLook.Button(name: "power", rect: CGRect(x: 436, y: 200, width: 6, height: 80), dx: -1, dy: 0, front: false)])

    func testAnUprightPictureStandsInItsPanelsCase() throws {
        let layout = try XCTUnwrap(DeviceCaseLayout.of([phone], ratio: 0.5, orientation: 0))
        XCTAssertEqual(layout.turn, 0)
        XCTAssertEqual(layout.frame, CGSize(width: 440, height: 880))
        XCTAssertEqual(layout.screen, CGRect(x: 20, y: 40, width: 400, height: 800))
        // (a corner's share of the screen's short side, a little inside the panel's own)
        XCTAssertEqual(layout.corners[0], 0.1 * 400 * 0.8, accuracy: 0.001)
    }

    func testALyingPictureTurnsTheCaseAQuarterAsTheDeviceSays() throws {
        let layout = try XCTUnwrap(DeviceCaseLayout.of([phone], ratio: 2, orientation: 270))
        XCTAssertEqual(layout.turn, 3)
        XCTAssertEqual(layout.frame, CGSize(width: 880, height: 440))
        XCTAssertEqual(layout.screen, CGRect(x: 40, y: 20, width: 800, height: 400))
        // The side button goes round with it, and the way it goes in too.
        XCTAssertEqual(layout.buttons[0].rect, CGRect(x: 200, y: -2, width: 80, height: 6))
        XCTAssertEqual(layout.buttons[0].dy, 1)
    }

    func testAPictureOfAnotherShapeHasNoCase() {
        XCTAssertNil(DeviceCaseLayout.of([phone], ratio: 0.75, orientation: 0))
    }
}
