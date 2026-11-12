import XCTest
import UIKit

/// Native rendering and gesture boundaries: image identity, horizontal paging, interactive dismissal and return.
@MainActor final class ChatImageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFailedCoverKeepsItsRowAndVideoStillOpens() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--chat-images", "--chat-video", "--chat-cover-fails", "--hide-metrics"])
        let image = app.buttons["chat-image-mixed:0"]
        let video = app.buttons["chat-image-mixed:1"]
        XCTAssertTrue(video.waitUntilHittable(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Image unavailable"), object: video)], timeout: 15), .completed)
        keepScreenshot(app, "Failed video cover")
        XCTAssertEqual(image.frame.minY, video.frame.minY, accuracy: 1, "A failed cover keeps the attachment row aligned")
        XCTAssertEqual(image.frame.height, video.frame.height, accuracy: 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "V5-材质相机灯光验证.mp4")).count, 1,
                       "One attachment keeps one tile when its cover fails")
        video.tap()
        XCTAssertTrue(app.element("chatVideoPlayer").waitForExistence(timeout: 15), "A cover failure must not block playback")
        XCTAssertTrue(app.buttons["Retry"].waitUntilGone(timeout: 15), "A playing video keeps its controls clear of Retry")
        keepScreenshot(app, "Playback after cover failure")
    }

    func testVideoAndImagesShareTheGalleryAndReleasePlaybackWhenPagedAway() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--chat-images", "--chat-video", "--hide-metrics"])
        let video = app.buttons["chat-image-mixed:1"]
        XCTAssertTrue(video.waitUntilHittable(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Image loaded"), object: video)], timeout: 15), .completed)
        XCTAssertEqual(video.frame.minY, app.buttons["chat-image-mixed:0"].frame.minY, accuracy: 1)
        keepScreenshot(app, "Mixed image and video attachments")
        video.tap()
        let player = app.element("chatVideoPlayer")
        XCTAssertTrue(player.waitForExistence(timeout: 15), "Native playback displays the video")
        keepScreenshot(app, "Native video playback")
        let viewer = app.element("chatImageViewer")
        viewer.swipeLeft()
        XCTAssertTrue(app.staticTexts["chatImagePosition"].wait(for: \.label, toEqual: "4 / 4", timeout: 5))
        XCTAssertTrue(player.waitUntilGone(), "Paging away releases the video player")
        viewer.swipeRight()
        XCTAssertTrue(player.waitForExistence(timeout: 15))
        app.at(0.5, 0.35).press(forDuration: 0.05, thenDragTo: app.at(0.55, 0.85),
                               withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(viewer.waitUntilGone())
        XCTAssertTrue(player.waitUntilGone(), "Closing releases native playback")
    }

    func testImagesInOneReplyShareRowsAndWrapWithinTheChat() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--chat-images", "--chat-image-group", "--hide-metrics"])
        let first = app.buttons["chat-image-photo-group:0"]
        let second = app.buttons["chat-image-photo-group:1"]
        let last = app.buttons["chat-image-photo-group:7"]
        XCTAssertTrue(first.waitUntilHittable(timeout: 15))
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        keepScreenshot(app, "Images from one reply")
        XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 1, "Two images fit on one row")
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX, "Images retain their message order")
        XCTAssertGreaterThan(last.frame.minY, first.frame.maxY, "Extra images wrap to another row")
        XCTAssertLessThanOrEqual(last.frame.maxX, app.frame.maxX, "Wrapped images stay within the viewport")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Image loaded"), object: second)], timeout: 10), .completed)
        second.tap()
        let viewer = app.element("chatImageViewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["chatPreviewImage-photo-group:1"].exists)
        viewer.swipeLeft()
        XCTAssertTrue(app.staticTexts["chatImagePosition"].wait(for: \.label, toEqual: "4 / 9", timeout: 5))
        XCTAssertTrue(app.images["chatPreviewImage-photo-group:2"].exists)
        app.buttons["closeChatImageViewer"].tap()
        XCTAssertTrue(viewer.waitUntilGone())
    }

    func testCloseUsesNativeChromeInBothOrientations() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let sideBar = UIDevice.current.name.contains("Duo")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--chat-images", "--hide-metrics"])
            let thumbnail = app.buttons["chat-image-photo2:0"]
            XCTAssertTrue(thumbnail.waitUntilHittable(timeout: 15))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Image loaded"), object: thumbnail)], timeout: 10), .completed)
            thumbnail.tap()
            let close = app.buttons["closeChatImageViewer"]
            XCTAssertTrue(close.waitUntilHittable())
            let image = app.images["chatPreviewImage-photo2:0"]
            XCTAssertTrue(image.waitForExistence(timeout: 5))
            if sideBar {
                XCTAssertGreaterThan(close.frame.midX, app.frame.maxX - 90, "Close belongs to Duo's system column")
                XCTAssertLessThanOrEqual(image.frame.maxX, close.frame.minX + 1, "The image clears the system column")
            } else {
                XCTAssertLessThan(close.frame.midY, app.frame.midY, "Close uses the native top navigation bar")
            }
            keepScreenshot(app, "Native image controls \(orientation.rawValue)")
            close.tap()
            XCTAssertTrue(app.element("chatImageViewer").waitUntilGone())
            app.terminate()
        }
    }

    func testInlineImageOpensPagesAndDragsBackToCurrentThumbnail() throws {
        let app = XCUIApplication.fixture(arguments: ["--launch-in-chat", "--chat-images", "--hide-metrics"])
        let thumbnail = app.buttons["chat-image-photo2:0"]
        XCTAssertTrue(thumbnail.waitUntilHittable(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Image loaded"),
                                                                    object: thumbnail)], timeout: 10), .completed)
        keepScreenshot(app, "Inline images")
        thumbnail.tap()
        let viewer = app.element("chatImageViewer")
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["chatPreviewImage-photo2:0"].waitForExistence(timeout: 5))
        keepScreenshot(app, "Image zoomed in")
        let original = app.images["chatPreviewImage-photo2:0"].frame
        app.at(0.5, 0.4).press(forDuration: 0.05, thenDragTo: app.at(0.5, 0.42),
                              withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(viewer.exists, "A short downward drag returns to the full image")
        XCTAssertEqual(app.images["chatPreviewImage-photo2:0"].frame.width, original.width, accuracy: 1)
        viewer.swipeRight()
        XCTAssertTrue(app.staticTexts["chatImagePosition"].wait(for: \.label, toEqual: "2 / 3", timeout: 5))
        XCTAssertTrue(app.images["chatPreviewImage-photo1:0"].exists)
        viewer.swipeRight()
        XCTAssertTrue(app.staticTexts["chatImagePosition"].wait(for: \.label, toEqual: "1 / 3", timeout: 5))
        viewer.swipeLeft()
        XCTAssertTrue(app.staticTexts["chatImagePosition"].wait(for: \.label, toEqual: "2 / 3", timeout: 5))
        keepScreenshot(app, "Adjacent image")
        app.at(0.5, 0.4).press(forDuration: 0.05, thenDragTo: app.at(0.55, 0.85),
                              withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(viewer.waitUntilGone())
        XCTAssertTrue(app.buttons["chat-image-photo1:0"].waitUntilHittable())
        app.buttons["chat-image-photo1:0"].tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        app.buttons["closeChatImageViewer"].tap()
        XCTAssertTrue(viewer.waitUntilGone())
    }
}
