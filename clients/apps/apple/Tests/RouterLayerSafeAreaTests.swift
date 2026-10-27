import SwiftUI
import UIKit
import XCTest
@testable import Comma

/// The router chat keeps the status bar's inset while its layer changes size closed, as it does when a Task docks or
/// the phone turns: its navigation bar stays under the status bar, not in it.
@MainActor
final class RouterLayerSafeAreaTests: XCTestCase {
    func testAResizeWhileClosedKeepsTheStatusBarInset() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = scene.screen.bounds
        let navigation = AppNavigation()
        navigation.routerButtonFrame = CGRect(x: screen.maxX - 72, y: screen.maxY - 90, width: 56, height: 56)
        let content = HostedContent(content: RouterLayerContent(store: harness.store, navigation: navigation),
                                    environment: EnvironmentValues())
        let layer = RouterLayerController(content: content)
        let card = UIViewController()
        card.addChild(layer)
        card.view.addSubview(layer.view)
        layer.view.frame = screen
        layer.didMove(toParent: card)
        window.rootViewController = card
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let statusBar = try XCTUnwrap(window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : nil)

        // Place the chat at the closing zoom's destination without waiting for Core Animation.
        // The button is below the status bar, so resizing through this transform used to lose the top inset.
        layer.place(layer.closedFrame)

        let probe = SafeAreaProbe(frame: layer.hosting.view.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layer.hosting.view.addSubview(probe)
        layer.hosting.view.layoutIfNeeded()
        probe.tops.removeAll()

        // A docked Task ends the app card above its bar.
        layer.view.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - 100)
        window.layoutIfNeeded()

        XCTAssertFalse(probe.tops.isEmpty, "The resize gives the chat its safe area again")
        XCTAssertEqual(probe.tops.filter { $0 != statusBar }, [], "Every safe area the chat gets keeps the status bar's inset")
    }
}

/// Records each top safe-area inset its superview passes down.
private final class SafeAreaProbe: UIView {
    var tops: [CGFloat] = []

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        tops.append(safeAreaInsets.top)
    }
}
