import XCTest
import SwiftUI
import UIKit
@testable import Comma

/// The real shell, native navigation controllers and Duo system bar share the same window.
@MainActor final class PhoneSettingsColumnsTests: XCTestCase {
    func testDuoSettingsReplacesRoutinesAndKeepsItsStackAcrossColumnChanges() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { throw XCTSkip("Requires Duo") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .max { $0.coordinateSpace.bounds.width < $1.coordinateSpace.bounds.width })
        let original = scene.windows.first(where: \.isKeyWindow)
        let harness = try StoreHarness()
        PhoneFeatureFixtures.configure(harness.core)
        await harness.start()
        harness.store.tasksLoaded = true
        harness.store.profileRead = true
        let navigation = AppNavigation(tab: .settings)
        let root = UIHostingController(rootView: ShellTabs(store: harness.store,
            activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(navigation).providingInbox(store: harness.store))
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(root)
        container.view.addSubview(root.view)
        root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        try await settle(window)
        print("Duo settings: waiting for the unfolded inner display")
        let unfolded = ContinuousClock.now + .seconds(30)
        while window.bounds.width < ShellTabs.minimumColumnWidth * 2, ContinuousClock.now < unfolded {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard window.bounds.width > ShellTabs.minimumColumnWidth * 2 else {
            XCTFail("Run on Duo's unfolded inner display")
            return
        }
        root.view.frame = window.bounds
        try await settle(window)
        let bar = try XCTUnwrap(controllers(root).compactMap { $0 as? ShellTabBarController }.first)
        let tabs = try XCTUnwrap(bar.parent)
        let page = try XCTUnwrap(tabs.children.first { $0 !== bar && !$0.view.isHidden })
        XCTAssertLessThan(page.view.safeAreaInsets.left, window.bounds.width * 0.2,
                          "Settings owns stable columns before navigation starts")
        XCTAssertEqual(stacks(page).count, 2)
        var master = try XCTUnwrap(scrolls(page).first)
        let masterStart = master.convert(master.bounds, to: window)
        XCTAssertGreaterThan(masterStart.minX, window.bounds.width * 0.3)
        capture(window, "16-duo-settings-root")

        navigation.settingsPath = [.models]
        let masterDuringPush = try await motionFrame(master, in: window, startX: masterStart.minX)
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertEqual(masterDuringPush.minX, 0, accuracy: 1, "Reduce Motion removes column travel")
        } else {
            XCTAssertGreaterThan(masterDuringPush.minX, 0, "The master travels through the viewport")
            XCTAssertLessThan(masterDuringPush.minX, masterStart.minX, "The master slides left instead of being replaced")
        }
        try await settle(window)
        XCTAssertFalse(harness.core.topics("models").isEmpty)
        XCTAssertLessThan(page.view.safeAreaInsets.left, window.bounds.width * 0.2,
                          "The settings master takes the space previously reserved for Routines")
        try assertColumns(page, in: window)
        let nativeNavigation = try XCTUnwrap(stacks(page).first { $0.viewControllers.count > 1 })
        try assertPopGestures(nativeNavigation, enabled: false)
        capture(window, "17-duo-models-split")

        // A third-level page stays inside the detail column; its native swipe does not move the shell.
        nativeNavigation.pushViewController(UIViewController(), animated: false)
        try await settle(window)
        try assertPopGestures(nativeNavigation, enabled: true)
        nativeNavigation.popViewController(animated: false)
        try await settle(window)
        try assertPopGestures(nativeNavigation, enabled: false)

        navigation.settingsPath = [.plugins]
        try await settle(window)
        XCTAssertFalse(harness.core.topics("plugins").isEmpty)
        try assertColumns(page, in: window)
        capture(window, "18-duo-plugins-split")
        let detail = try XCTUnwrap(stacks(page).first { $0.viewControllers.count > 1 })
        let subscriptions = harness.core.topics("plugins").count

        // Resize the actual native container deterministically. Duo's simulator can ignore a scene's
        // orientation preference while the physical device posture remains landscape.
        root.view.frame.size.width = 390
        try await settle(window)
        XCTAssertEqual(stacks(page).count, 1)
        XCTAssertTrue(stacks(page).contains { $0 === detail }, "A compact window keeps the existing detail stack")
        try assertPopGestures(detail, enabled: true)
        XCTAssertEqual(navigation.settingsPath, [.plugins])
        XCTAssertEqual(harness.core.topics("plugins").count, subscriptions, "A column change does not reload the page")

        root.view.frame = window.bounds
        try await settle(window)
        try assertColumns(page, in: window)
        try assertPopGestures(detail, enabled: false)
        master = try XCTUnwrap(scrolls(page).min { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX })
        XCTAssertTrue(stacks(page).contains { $0 === detail })
        navigation.select(.home)
        try await settle(window)
        let home = try XCTUnwrap(tabs.children.first { $0 !== bar && !$0.view.isHidden })
        XCTAssertGreaterThan(home.view.safeAreaInsets.left, window.bounds.width * 0.3,
                             "Leaving Settings restores Routines for the other tab")
        navigation.select(.settings)
        try await settle(window)
        try assertColumns(page, in: window)
        // Opening the simulator can finish changing hinge posture after the first screenshot.
        // Compare against the current native detail column rather than that earlier geometry.
        let returnPosition = detail.view.convert(detail.view.bounds, to: window).minX
        navigation.settingsPath = []
        let masterDuringPop = try await motionFrame(master, in: window, startX: returnPosition)
        XCTAssertGreaterThan(masterDuringPop.minX, 0)
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertEqual(masterDuringPop.minX, returnPosition, accuracy: 1)
        } else {
            XCTAssertLessThan(masterDuringPop.minX, returnPosition, "Returning reverses the same travel")
        }
        try await settle(window)
        XCTAssertTrue(navigation.settingsPath.isEmpty)
        XCTAssertEqual(stacks(page).count, 2)
        XCTAssertEqual(master.convert(master.bounds, to: window).minX,
                       detail.view.convert(detail.view.bounds, to: window).minX, accuracy: 1)
        capture(window, "20-duo-settings-restored")
        navigation.settingsPath = [.router]
        try await settle(window)
        capture(window, "21-duo-router-settings-split")
        navigation.select(.settings)
        try await settle(window)
        XCTAssertTrue(navigation.settingsPath.isEmpty, "Reselecting Settings also restores its root layout")

        // Reverse an unfinished push. The same master and native detail stack must survive.
        navigation.settingsPath = [.plugins]
        try await Task.sleep(for: .milliseconds(60))
        navigation.settingsPath = []
        try await settle(window)
        XCTAssertEqual(master.convert(master.bounds, to: window).minX,
                       detail.view.convert(detail.view.bounds, to: window).minX, accuracy: 1)
        XCTAssertEqual(stacks(page).count, 2)
        XCTAssertTrue(stacks(page).allSatisfy { $0.viewControllers.count == 1 })
        navigation.settingsPath = [.models]
        try await settle(window)
        _ = detail.popToRootViewController(animated: true)
        try await settle(window)
        XCTAssertTrue(navigation.settingsPath.isEmpty, "The native Back action still closes the detail")
        navigation.settingsPath = [.models]
        try await settle(window)
        try assertPopGestures(detail, enabled: false)
        _ = detail.popToRootViewController(animated: true)
        try await settle(window)
        XCTAssertTrue(navigation.settingsPath.isEmpty, "Reopening the same page keeps button return available")
        #else
        throw XCTSkip("Requires the Duo SDK")
        #endif
    }

    private func assertColumns(_ page: UIViewController, in window: UIWindow) throws {
        let columns = scrolls(page).filter { $0.bounds.width > ShellTabs.minimumColumnWidth }
            .sorted { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX }
        XCTAssertEqual(columns.count, 2)
        guard columns.count == 2 else { return }
        let left = columns[0].convert(columns[0].bounds, to: window)
        let right = columns[1].convert(columns[1].bounds, to: window)
        XCTAssertGreaterThan(left.width, ShellTabs.minimumColumnWidth)
        XCTAssertGreaterThan(right.width, ShellTabs.minimumColumnWidth)
        XCTAssertLessThanOrEqual(left.maxX, right.minX + 1, "Settings and detail must not overlap")
        let navigation = stacks(page)
        XCTAssertEqual(navigation.count, 2, "Each column owns its native navigation bar")
        XCTAssertEqual(navigation.filter { $0.viewControllers.count > 1 }.count, 1,
                       "Only the detail pushes nested pages")
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func assertPopGestures(_ navigation: UINavigationController, enabled: Bool) throws {
        XCTAssertEqual(try XCTUnwrap(navigation.interactivePopGestureRecognizer).isEnabled, enabled,
                       "Edge swipe policy follows the visible Settings boundary")
        if #available(iOS 26.0, *) {
            XCTAssertEqual(try XCTUnwrap(navigation.interactiveContentPopGestureRecognizer).isEnabled, enabled,
                           "Content swipe must follow the same policy as edge swipe")
        }
    }

    private func scrolls(_ page: UIViewController) -> [UIScrollView] {
        views(page.view).compactMap { $0 as? UIScrollView }.filter { visible($0) }
    }

    private func presentedFrame(_ view: UIView, in window: UIWindow) -> CGRect {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }

    private func motionFrame(_ view: UIView, in window: UIWindow, startX: CGFloat) async throws -> CGRect {
        if UIAccessibility.isReduceMotionEnabled {
            try await settle(window)
            return presentedFrame(view, in: window)
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            let frame = presentedFrame(view, in: window)
            if frame.minX > 1, frame.minX < startX - 1 { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        return presentedFrame(view, in: window)
    }

    private func stacks(_ page: UIViewController) -> [UINavigationController] {
        controllers(page).compactMap { $0 as? UINavigationController }.filter { visible($0.view) }
    }

    private func visible(_ view: UIView) -> Bool {
        !view.isHidden && view.alpha > 0 && (view.superview.map(visible) ?? true)
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }

    private func settle(_ window: UIWindow) async throws {
        try await Task.sleep(for: .milliseconds(850))
        window.layoutIfNeeded()
    }

    private func capture(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
