import XCTest
import SwiftUI
import UIKit
@testable import Comma

/// Production native views with local synthetic values. Captures contain no user data or real services.
@MainActor final class PhoneRoutineUsageScreenshotTests: XCTestCase {
    func testPhoneAcceptanceScreenshots() async throws {
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        let workspace = try XCTUnwrap(harness.store.workspace)
        let routines = PhoneRoutinesSettingsModel(store: harness.store, workspace: workspace)
        try await capture("01-routines", view: PhoneRoutinesSettingsView(model: routines)) { routines.loaded }
        let usage = PhoneUsageModel(store: harness.store, workspace: workspace)
        try await capture("02-usage", view: PhoneUsageView(model: usage)) { usage.status == "ready" }
        let pane = try XCTUnwrap(harness.store.router.pane)
        pane.open(); defer { pane.close() }
        pane.setSuggestionsVisible(true)
        try await ready { !pane.suggestions.isEmpty }
        try await capture("03-chat-suggestions", view: PhoneConversationView(store: harness.store, pane: pane)
            .environment(AppNavigation(routerOpen: true))) { !pane.suggestions.isEmpty }
        pane.draftText = "保留这段尚未发送的草稿"
        try await capture("04-suggestions-with-draft", view: PhoneConversationView(store: harness.store, pane: pane)
            .environment(AppNavigation(routerOpen: true))) { true }
        try await capture("05-usage-dark", view: PhoneUsageView(model: usage), dark: true) { usage.status == "ready" }
        try await capture("06-routines-large-text", view: PhoneRoutinesSettingsView(model: routines), textSize: .accessibility2) { routines.loaded }
        harness.core.serve("billing") { _ in ["status": "unavailable"] }
        let unavailable = PhoneUsageModel(store: harness.store, workspace: workspace)
        try await capture("07-usage-unavailable", view: PhoneUsageView(model: unavailable)) { unavailable.status == "unavailable" }
        harness.core.serve("billing") { _ in
            var value = PhoneRoutineUsageFixtures.billing
            value["summary"] = ["current_credits": 0, "active_grants": []]
            value["planUsage"] = NSNull(); value["allowance"] = NSNull()
            return value
        }
        let exhausted = PhoneUsageModel(store: harness.store, workspace: workspace)
        try await capture("08-usage-exhausted", view: PhoneUsageView(model: exhausted)) { exhausted.status == "ready" }
    }

    func testDuoColumnsAndChatAcceptanceScreenshots() async throws {
        let scene = try scene()
        let harness = try StoreHarness(); PhoneRoutineUsageFixtures.configure(harness.core); await harness.start()
        harness.store.tasksLoaded = true; harness.store.profileRead = true
        let navigation = AppNavigation(tab: .settings)
        let root = UIHostingController(rootView: ShellCard(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery()))
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(root); container.view.addSubview(root.view); root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        try await settle(window)
        let deadline = ContinuousClock.now + .seconds(12)
        while window.bounds.width < ShellTabs.minimumColumnWidth * 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard window.bounds.width >= ShellTabs.minimumColumnWidth * 2 else { throw XCTSkip("Run on the unfolded Duo display") }
        root.view.frame = window.bounds
        navigation.settingsPath = [.routines]
        try await settle(window)
        try assertColumns(root, window: window, detailTitle: String(localized: "Routines"))
        save(window, "09-duo-routines-split")
        navigation.settingsPath = [.usage]
        try await settle(window)
        try assertColumns(root, window: window)
        save(window, "10-duo-usage-split")
        let pane = try XCTUnwrap(harness.store.router.pane)
        pane.open()
        navigation.openRouter()
        try await settle(window)
        try await ready { !pane.suggestions.isEmpty }
        save(window, "11-duo-chat-suggestions")
        // Native rendering boundary: the composer and all suggestion hit targets stay in the trailing column.
        let chat = try XCTUnwrap(controllers(root).compactMap { $0 as? RouterLayerController }.first)
        let nodes = accessibilityNodes(chat.hosting.view)
        for id in ["chatComposer"] {
            let element = try XCTUnwrap(nodes.first {
                $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id
            }, "Missing \(id)")
            let frame = window.convert(element.accessibilityFrame, from: nil)
            XCTAssertGreaterThan(frame.minX, window.bounds.width * 0.3)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)
        }
        // SwiftUI's horizontal ScrollView exposes a virtual AX group, rather than stable UIKit button children.
        // Its native clipped viewport bounds all suggestion hit targets, including those revealed by scrolling.
        let chatScrolls = views(chat.hosting.view).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && visible($0) && $0.bounds.width > 0 && $0.bounds.height > 0 }
        XCTAssertGreaterThanOrEqual(chatScrolls.count, 2, "The transcript and suggestion row each own a native scroll viewport")
        for scroll in chatScrolls {
            let frame = scroll.convert(scroll.bounds, to: window)
            XCTAssertGreaterThan(frame.minX, window.bounds.width * 0.3)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)
            XCTAssertTrue(scroll.clipsToBounds, "Suggestion content must stay inside its column")
        }
        navigation.closeRouter()
        try await settle(window)
        XCTAssertEqual(navigation.settingsPath, [.usage])
        try assertColumns(root, window: window)
        // Keep the existing stack and page when the native window becomes compact, then wide again.
        let navigationController = try XCTUnwrap(controllers(root).compactMap { $0 as? UINavigationController }.first { $0.viewControllers.count > 1 })
        root.view.frame.size.width = 390
        try await settle(window)
        XCTAssertEqual(navigation.settingsPath, [.usage])
        XCTAssertTrue(controllers(root).contains { $0 === navigationController })
        root.view.frame = window.bounds
        try await settle(window)
        try assertColumns(root, window: window)
        save(window, "12-duo-usage-restored")
        pane.close()
    }

    private func assertColumns(_ root: UIViewController, window: UIWindow, detailTitle: String = String(localized: "Usage")) throws {
        let bar = try XCTUnwrap(controllers(root).compactMap { $0 as? ShellTabBarController }.first)
        let tabs = try XCTUnwrap(bar.parent)
        let page = try XCTUnwrap(tabs.children.first { $0 !== bar && !$0.view.isHidden })
        let scrolls = views(page.view).compactMap { $0 as? UIScrollView }
            .filter { visible($0) && $0.bounds.width > ShellTabs.minimumColumnWidth }
            .sorted { $0.convert($0.bounds, to: window).minX < $1.convert($1.bounds, to: window).minX }
        XCTAssertEqual(scrolls.count, 2)
        if scrolls.count == 2 {
            let left = scrolls[0].convert(scrolls[0].bounds, to: window)
            let right = scrolls[1].convert(scrolls[1].bounds, to: window)
            XCTAssertLessThanOrEqual(left.maxX, right.minX + 1)
            let headings = accessibilityNodes(window).filter { $0.accessibilityTraits.contains(.header) }
            let master = try XCTUnwrap(headings.first {
                $0.accessibilityLabel == String(localized: "Settings") && $0.accessibilityFrame.width > 0 &&
                    window.convert($0.accessibilityFrame, from: nil).midX < left.maxX
            }, "The master exposes its visible heading")
            let detail = try XCTUnwrap(headings.first {
                $0.accessibilityLabel == detailTitle && $0.accessibilityFrame.width > 0 &&
                    window.convert($0.accessibilityFrame, from: nil).minX >= right.minX - 1
            }, "The detail exposes its visible heading")
            let masterTitle = window.convert(master.accessibilityFrame, from: nil)
            let detailFrame = window.convert(detail.accessibilityFrame, from: nil)
            XCTAssertGreaterThanOrEqual(masterTitle.minX, left.minX)
            XCTAssertLessThanOrEqual(masterTitle.maxX, left.maxX)
            XCTAssertGreaterThanOrEqual(detailFrame.minX, right.minX)
            XCTAssertLessThanOrEqual(detailFrame.maxX, right.maxX)
            let bars = views(page.view).compactMap { $0 as? UINavigationBar }
                .filter { visible($0) && $0.bounds.width > 0 && $0.bounds.height > 0 }
            for (title, column) in [(String(localized: "Settings"), left), (detailTitle, right)] {
                let bar = try XCTUnwrap(bars.first {
                    $0.topItem?.title == title && column.contains(CGPoint(x: $0.convert($0.bounds, to: window).midX,
                                                                         y: column.midY))
                }, "The \(title) column uses its native navigation bar")
                XCTAssertFalse(bar.isHidden)
            }
        }
    }

    private func capture<V: View>(_ name: String, view: V, dark: Bool = false, textSize: DynamicTypeSize = .large,
                                  ready condition: @escaping @MainActor () -> Bool) async throws {
        let scene = try scene()
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView: NavigationStack { view }
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.dynamicTypeSize, textSize))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await ready(condition)
        try await settle(window)
        save(window, name)
    }

    private func scene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .max { $0.coordinateSpace.bounds.width < $1.coordinateSpace.bounds.width })
    }

    private func ready(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    private func settle(_ window: UIWindow) async throws {
        try await Task.sleep(for: .milliseconds(900)); window.layoutIfNeeded()
    }
    private func save(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ios-routines-usage-evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func controllers(_ controller: UIViewController) -> [UIViewController] { [controller] + controller.children.flatMap(controllers) }
    private func visible(_ view: UIView) -> Bool { !view.isHidden && view.alpha > 0 && (view.superview.map(visible) ?? true) }
    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        var nodes: [NSObject] = []
        func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            nodes.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            if let children = node.automationElements ?? node.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach(visit)
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count < 256 {
                    for index in 0..<count {
                        if let child = node.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
        }
        visit(root)
        return nodes
    }
}
