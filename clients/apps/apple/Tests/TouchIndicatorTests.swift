import UIKit
import XCTest
@testable import Comma

/// While the screen is captured, each finger has a dot on the app's topmost window; without a capture none shows.
@MainActor
final class TouchIndicatorTests: XCTestCase {
    private final class Finger {}

    func testTheAppFollowsTheTouchesOfAWindowThatShows() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.isHidden = false
        defer { window.isHidden = true }
        XCTAssertTrue(TouchIndicator.shared.watches(window))
    }

    func testACapturedFingerHasADotOnTheTopmostWindowUntilItLifts() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let page = UIWindow(windowScene: scene)
        page.isHidden = false
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 10
        cover.isHidden = false
        defer { page.isHidden = true; cover.isHidden = true }
        let indicator = TouchIndicator()
        let first = Finger(), second = Finger()

        indicator.follow(ObjectIdentifier(first), phase: .began, at: CGPoint(x: 80, y: 120), in: page, captured: true)
        indicator.follow(ObjectIdentifier(second), phase: .began, at: CGPoint(x: 200, y: 300), in: page, captured: true)
        XCTAssertTrue(indicator.window === cover)
        XCTAssertEqual(indicator.points.sorted { $0.x < $1.x }, [CGPoint(x: 80, y: 120), CGPoint(x: 200, y: 300)])
        XCTAssertTrue(cover.hitTest(CGPoint(x: 80, y: 120), with: nil) === cover, "The dots take no touches")

        indicator.follow(ObjectIdentifier(first), phase: .moved, at: CGPoint(x: 90, y: 160), in: page, captured: true)
        indicator.follow(ObjectIdentifier(second), phase: .ended, at: CGPoint(x: 200, y: 300), in: page, captured: true)
        XCTAssertEqual(indicator.points, [CGPoint(x: 90, y: 160)])

        indicator.follow(ObjectIdentifier(first), phase: .cancelled, at: CGPoint(x: 90, y: 160), in: page, captured: true)
        XCTAssertEqual(indicator.points, [])
    }

    func testNoDotShowsWithoutACaptureAndTheDotsGoWhenItEnds() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let page = UIWindow(windowScene: scene)
        page.isHidden = false
        defer { page.isHidden = true }
        let indicator = TouchIndicator()
        let finger = Finger()

        indicator.follow(ObjectIdentifier(finger), phase: .began, at: CGPoint(x: 80, y: 120), in: page, captured: false)
        XCTAssertEqual(indicator.points, [])
        XCTAssertNil(indicator.window)

        indicator.follow(ObjectIdentifier(finger), phase: .moved, at: CGPoint(x: 80, y: 130), in: page, captured: true)
        XCTAssertEqual(indicator.points, [CGPoint(x: 80, y: 130)])
        indicator.follow(ObjectIdentifier(finger), phase: .moved, at: CGPoint(x: 80, y: 140), in: page, captured: false)
        XCTAssertEqual(indicator.points, [])
        XCTAssertNil(indicator.window)
    }
}
