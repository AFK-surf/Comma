import XCTest
import UIKit

@MainActor extension XCUIApplication {
    /// Ends the fixture's `--fail-…` failures and returns once the server answers again.
    func recoverServer() {
        PerfSignal.recover.post()
        let state = staticTexts["serverRecovered"]
        XCTAssertTrue(state.wait(for: \.label, toEqual: "recovered", timeout: 5), "The fixture server recovers")
    }

    /// Launches the fixture in English; `light` pins the light appearance for pixel checks, and `arguments` add
    /// the fixture's own switches.
    static func fixture(light: Bool = false, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            + (light ? ["-AppleInterfaceStyle", "Light"] : []) + arguments
        app.launch()
        return app
    }

    /// Any element by accessibility identifier, whatever its type.
    func element(_ id: String) -> XCUIElement { descendants(matching: .any).matching(identifier: id).firstMatch }

    /// The router chat's composer while no Task is open; an open Task's composer shares the identifier.
    var routerComposer: XCUIElement { element("chatComposer") }

    /// Opens the router chat from the button beside the tab bar and returns its composer.
    @discardableResult
    func openRouterChat() -> XCUIElement {
        let button = buttons["openRouterChat"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.waitUntilHittable(), "The router button must be reachable")
        button.tap()
        XCTAssertTrue(routerComposer.waitForExistence(timeout: 10))
        return routerComposer
    }

    /// Task 0's title in the dock header: a tap opens its details while expanded and raises the sheet
    /// while minimized.
    var taskTitle: XCUIElement { buttons.matching(NSPredicate(format: "label == %@", "Task 0")).firstMatch }

    /// Drags the expanded Task sheet down by its header into the minimized bar.
    func minimizeTask() {
        let title = taskTitle
        XCTAssertTrue(title.waitUntilHittable())
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }

    /// Opens (or re-expands) Task 0 from its reference card in the router chat's newest message.
    func openTaskFromRouter() {
        let reference = element("task-ref-task0")
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap()
    }

    /// Drags the open transcript down a few screens' worth, into earlier messages.
    func readEarlierMessages() {
        for _ in 0..<3 {
            coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        }
    }
}

@MainActor extension XCUIElement {
    /// Types and deletes a space in this focused field. While the simulator has a hardware keyboard connected
    /// a tap only focuses; typing brings the software keyboard up, as a tap does on a device.
    func raiseKeyboard() { typeText(" " + XCUIKeyboardKey.delete.rawValue) }

    func waitUntilHittable(timeout: TimeInterval = 5) -> Bool { wait(for: "isHittable == true", timeout: timeout) }
    func waitUntilGone(timeout: TimeInterval = 5) -> Bool { wait(for: "exists == false", timeout: timeout) }
    func waitUntilOutOfView(timeout: TimeInterval = 5) -> Bool {
        wait(for: "exists == false OR isHittable == false", timeout: timeout)
    }
    func waitUntilUnhittable(timeout: TimeInterval = 5) -> Bool { wait(for: "isHittable == false", timeout: timeout) }
    func waitUntilEnabled(timeout: TimeInterval = 5) -> Bool { wait(for: "isEnabled == true", timeout: timeout) }

    private func wait(for predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

@MainActor extension XCTestCase {
    /// Keeps a screenshot with the test's results and returns it.
    func keepScreenshot(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    /// The RGBA colour of one point of a screenshot of `frame`.
    func pixel(_ screenshot: XCUIScreenshot, at point: CGPoint, in frame: CGRect) throws -> [UInt8] {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let x = (point.x - frame.minX) / frame.width * CGFloat(image.width)
        let y = (point.y - frame.minY) / frame.height * CGFloat(image.height)
        let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
