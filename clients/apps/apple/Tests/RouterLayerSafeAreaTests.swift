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
        let content = HostedContent(content: RouterLayerContent(store: harness.store, navigation: navigation),
                                    environment: EnvironmentValues())
        let layer = RouterLayerController(content: content, open: false)
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

        let surface = try XCTUnwrap(layer.hosting.view.superview)
        let probe = SafeAreaProbe(frame: surface.bounds)
        probe.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.addSubview(probe)
        layer.hosting.view.layoutIfNeeded()
        probe.tops.removeAll()

        // A docked Task ends the app card above its bar.
        layer.view.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - 100)
        window.layoutIfNeeded()

        XCTAssertEqual(layer.hosting.view.bounds.height, layer.view.bounds.height, accuracy: 1)
        XCTAssertEqual(layer.hosting.view.safeAreaInsets.top, statusBar)
        XCTAssertEqual(probe.tops.filter { $0 != statusBar }, [], "Every safe area the chat gets keeps the status bar's inset")
    }

    func testRouterMarkTracksTheNativeButtonAcrossTabAndBadgeChanges() async throws {
        let fixture = try await RouterLayerFixture(open: false)
        defer { fixture.tearDown() }
        let bar = fixture.bar
        let tab = try XCTUnwrap(bar.tabs.first { $0.accessibilityIdentifier == "openRouterChat" })
        let source = bar.routerFace
        let badge = bar.routerBadge
        XCTAssertFalse(badge.isDescendant(of: source), "The overhanging badge lives outside the zoom's clipped source view")
        for state in [ShellTabBar(routerUnread: 3), ShellTabBar(selection: .inbox, routerReplying: true)] {
            bar.apply(state)
            fixture.window.layoutIfNeeded()
            let slot = try XCTUnwrap(tab.frame(in: bar.view))
            XCTAssertIdentical(source.superview, bar.view)
            XCTAssertEqual(source.frame, slot)
            XCTAssertIdentical(badge.superview, bar.view)
            XCTAssertEqual(badge.frame, slot)
            XCTAssertFalse(badge.clipsToBounds)
            let hit = try XCTUnwrap(bar.view.hitTest(CGPoint(x: slot.midX, y: slot.midY), with: nil))
            XCTAssertFalse(hit.isDescendant(of: source), "The native button still takes the tap")
            XCTAssertFalse(hit.isDescendant(of: badge), "The badge overlay never intercepts taps")
            XCTAssertEqual(tab.accessibilityValue, state.routerReplying ? String(localized: "Thinking") : String(localized: "\(3) new replies"))
        }
    }

    func testWholeChatIsVisibleInsideTheCardDuringOpeningAndClosing() async throws {
        let fixture = try await RouterLayerFixture(open: false)
        defer { fixture.tearDown() }
        let host = try XCTUnwrap(fixture.layer.hosting.view)
        let source = fixture.bar.routerFace
        let badge = fixture.bar.routerBadge
        fixture.bar.apply(ShellTabBar(routerUnread: 2))
        fixture.window.layoutIfNeeded()
        XCTAssertFalse(fixture.bar.routerBadgeHidden)
        let tab = try XCTUnwrap(fixture.bar.tabs.first { $0.accessibilityIdentifier == "openRouterChat" })
        let tabBar = fixture.bar.tabBar
        let slot = try XCTUnwrap(tab.frame(in: tabBar))
        let centre = CGPoint(x: slot.midX, y: slot.midY)
        let nativeButton = try XCTUnwrap(tabBar.hitTest(centre, with: nil))
        let compactBottomBar = fixture.bar.traitCollection.horizontalSizeClass == .compact
            && fixture.window.bounds.height > fixture.window.bounds.width
        for opening in [true, false] {
            if opening { fixture.navigation.openRouter() } else { fixture.navigation.closeRouter() }
            fixture.layer.update(content: fixture.content, open: opening)
            try await waitUntil { fixture.stack.transitionCoordinator != nil }
            let transition = try XCTUnwrap(fixture.stack.transitionCoordinator, opening ? "Opening the chat" : "Closing the chat")
            let sourcePage = try XCTUnwrap(transition.viewController(forKey: opening ? .from : .to))
            let surface = try XCTUnwrap(fixture.layer.hosting.parent?.view)
            let landed = expectation(description: opening ? "Opened chat" : "Closed chat")
            transition.animate(alongsideTransition: nil) { _ in landed.fulfill() }
            try await waitUntil { source.isDescendant(of: sourcePage.view) || fixture.stack.transitionCoordinator == nil }
            XCTAssertTrue(source.isDescendant(of: sourcePage.view), "The page UIKit reveals must contain the whole button throughout the zoom")
            XCTAssertEqual(source.frame, try XCTUnwrap(tab.frame(in: fixture.layer.view)))
            XCTAssertFalse(badge.isDescendant(of: source), "The badge stays outside the zoom's circular clip")
            XCTAssertIdentical(badge.superview, fixture.layer.view, "During zoom, the badge sits above the navigation stack, unoccluded by the morph portal")
            XCTAssertEqual(badge.frame, try XCTUnwrap(tab.frame(in: fixture.layer.view)))
            if opening {
                XCTAssertTrue(fixture.bar.routerBadgeHidden, "Opening hides the badge so it never floats over the expanding chat")
            }
            if #available(iOS 26.0, *), compactBottomBar {
                let drawn = try XCTUnwrap(fixture.bar.view.layer.mask?.frame)
                XCTAssertFalse(drawn.intersects(try XCTUnwrap(tab.frame(in: fixture.bar.view))),
                               "The home screen must not draw a second empty circle")
                for regularTab in fixture.bar.tabs where regularTab !== tab {
                    let frame = try XCTUnwrap(regularTab.frame(in: fixture.bar.view))
                    XCTAssertTrue(drawn.contains(frame), "The other tabs stay visible")
                }
                XCTAssertNotNil(source.effect, "The zoom source itself carries Liquid Glass so UIKit morphs it cleanly across the whole card")
                XCTAssertFalse(source.isHidden)
                XCTAssertEqual(source.contentView.subviews.first?.frame, source.bounds, "The moving mark fills the source glass")
                XCTAssertIdentical(tabBar.hitTest(centre, with: nil), nativeButton, "The native action still accepts taps")
            }
            XCTAssertTrue(surface.clipsToBounds)
            if #available(iOS 26.0, *) {
                XCTAssertGreaterThanOrEqual(surface.effectiveRadius(corner: .topLeft), CommaTheme.cardRadius)
            }
            XCTAssertFalse(host.isHidden)
            XCTAssertNil(host.layer.mask)
            XCTAssertEqual(host.alpha, 1)
            XCTAssertEqual(host.bounds.width, fixture.window.bounds.width, accuracy: 0.5)
            await fulfillment(of: [landed], timeout: 3)
            try await waitUntil { fixture.stack.transitionCoordinator == nil }
            let owner = opening ? sourcePage.view : fixture.bar.view
            XCTAssertIdentical(source.superview, owner)
            XCTAssertEqual(source.frame, try XCTUnwrap(tab.frame(in: opening ? fixture.layer.view : fixture.bar.view)))
            let badgeOwner = opening ? fixture.layer.view : fixture.bar.view
            XCTAssertIdentical(badge.superview, badgeOwner)
            XCTAssertEqual(badge.frame, try XCTUnwrap(tab.frame(in: opening ? fixture.layer.view : fixture.bar.view)))
            XCTAssertEqual(fixture.bar.routerBadgeHidden, opening, opening ? "Badge stays hidden while chat is open" : "Badge is revealed when chat lands")
            XCTAssertEqual(host.isHidden, !opening)
            XCTAssertEqual(host.alpha, 1)
            if opening {
                XCTAssertFalse(surface.clipsToBounds, "Landed open, the chat has no corners of its own: the card clips it")
            }
            if !opening {
                XCTAssertNil(fixture.bar.view.layer.mask, "The native button draws its glass again when the chat lands")
                XCTAssertNil(source.effect, "The overlay glass clears once the native button takes over again")
            }
        }
    }
}

extension RouterLayerSafeAreaTests {
    /// Closing hands the tabs back at once, and an opening asked for while the chat is still on its way into its
    /// button opens it once it lands, instead of being lost to the moving stack.
    func testClosingLetsTouchesThroughAndAnOpeningMeanwhileLands() async throws {
        let fixture = try await RouterLayerFixture(open: true)
        defer { fixture.tearDown() }
        let returnPage = try XCTUnwrap(fixture.stack.viewControllers.first)
        XCTAssertIdentical(fixture.bar.routerFace.superview, returnPage.view, "A cold launch into chat already has its return mark")
        let middle = CGPoint(x: fixture.layer.view.bounds.midX, y: fixture.layer.view.bounds.midY)
        XCTAssertNotNil(fixture.layer.view.hitTest(middle, with: nil), "The open chat takes touches")

        fixture.navigation.closeRouter()
        fixture.layer.update(content: fixture.content, open: false)
        try await waitUntil { fixture.stack.transitionCoordinator != nil }
        XCTAssertNotNil(fixture.stack.transitionCoordinator, "The chat closes")
        XCTAssertNil(fixture.layer.view.hitTest(middle, with: nil), "The tabs take touches as soon as the chat starts closing")

        fixture.navigation.openRouter()
        fixture.layer.update(content: fixture.content, open: true)
        try await waitUntil(.seconds(5)) { fixture.chatOpen && fixture.stack.transitionCoordinator == nil }
        XCTAssertTrue(fixture.navigation.routerOpen)
        XCTAssertTrue(fixture.chatOpen, "The chat opens again once it has landed")
        XCTAssertNotNil(fixture.layer.view.hitTest(middle, with: nil), "The reopened chat takes touches")
    }

    /// The chat waits closed from shortly after launch. Its first opening must still count the reply in view as
    /// seen, offer its suggestions, and give the reply swipe its rows, though the chat was built while closed.
    func testAChatParkedBeforeItsFirstOpeningCountsItsReplyAndOffersSuggestions() async throws {
        let fixture = try await RouterLayerFixture(open: false) { PhoneRoutineUsageFixtures.configure($0) }
        defer { fixture.tearDown() }
        let store = fixture.harness.store
        let pane = try XCTUnwrap(store.router.pane)
        try await waitUntil { pane.messages.contains { $0.id == "answer-1" } }
        try await Task.sleep(for: .milliseconds(300))

        fixture.navigation.openRouter()
        store.router.setSurfaceVisible(true)
        fixture.layer.update(content: fixture.content, open: true)
        try await waitUntil(.seconds(5)) { fixture.chatOpen && fixture.stack.transitionCoordinator == nil }
        XCTAssertTrue(fixture.chatOpen)
        try await waitUntil(.seconds(3)) { store.router.displayedReplyID == "answer-1" && !pane.suggestions.isEmpty }
        XCTAssertEqual(store.router.displayedReplyID, "answer-1", "The reply in view counts as seen on the first opening")
        XCTAssertFalse(pane.suggestions.isEmpty, "The opened chat offers its suggestions")
        let id = ObjectIdentifier(pane)
        let screen = try XCTUnwrap(fixture.layer.hosting.view.window).bounds
        XCTAssertTrue((1..<40).contains { row in
            (1..<20).contains { column in
                ReplySwipeRegions.shared.claims(CGPoint(x: screen.width * CGFloat(column) / 20,
                                                        y: screen.height * CGFloat(row) / 40), in: id)
            }
        }, "The reply swipe knows where the messages are")
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
}

/// The router layer and the system tab bar share a window as siblings, just as they do in the shell.
@MainActor
private struct RouterLayerFixture {
    let harness: StoreHarness
    let window: UIWindow
    let original: UIWindow?
    let navigation: AppNavigation
    let content: HostedContent<RouterLayerContent>
    let layer: RouterLayerController
    let stack: UINavigationController
    let bar: SystemShellTabBarController

    init(open: Bool, configure: (FakeCore) -> Void = { _ in }) async throws {
        harness = try StoreHarness()
        configure(harness.core)
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        original = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        navigation = AppNavigation(routerOpen: open)
        content = HostedContent(content: RouterLayerContent(store: harness.store, navigation: navigation),
                                environment: EnvironmentValues())
        layer = RouterLayerController(content: content, open: open)
        bar = SystemShellTabBarController(store: harness.store, navigation: navigation, bar: ShellTabBar())
        let shell = UIViewController()
        window.rootViewController = shell
        for child in [bar, layer] as [UIViewController] {
            shell.addChild(child)
            child.view.frame = shell.view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shell.view.addSubview(child.view)
            child.didMove(toParent: shell)
        }
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        stack = try XCTUnwrap(layer.children.compactMap { $0 as? UINavigationController }.first)
        let deadline = ContinuousClock.now + .seconds(3)
        while stack.viewControllers.count != (open ? 2 : 1) || stack.transitionCoordinator != nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stack.viewControllers.count, open ? 2 : 1)
    }

    /// The chat is on the stack's top page, not waiting closed under it.
    var chatOpen: Bool { stack.viewControllers.count == 2 && layer.hosting.parent === stack.topViewController }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
        original?.makeKeyAndVisible()
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
