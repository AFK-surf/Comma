import SwiftUI
import UIKit
import XCTest
import CommaCore
@testable import Comma

/// Native shell layout, safe areas, and phone search presentation.
@MainActor
final class TaskSearchPresentationTests: XCTestCase {
    func testMinimizedTaskAndMainCardFollowTheDisplayCorners() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires native corner geometry") }
        let harness = try StoreHarness()
        await harness.start()
        let pane = ConversationPane(kind: .task("corner-task"), workspace: try XCTUnwrap(harness.store.workspace),
                                    conversationID: "corner-task", store: harness.store)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        container.view.backgroundColor = .black
        container.view.cornerConfiguration = .corners(radius: .containerConcentric())
        window.rootViewController = container
        let card = AppCardViewController(content: Color.white, environment: EnvironmentValues(),
            bottomInset: TaskDockViewController.barHeight + AppShellView.gap, rounded: true)
        let dock = TaskDockViewController(store: harness.store, pane: pane, revealRequest: 0, onExpand: {})
        for child in [card as UIViewController, dock] {
            container.addChild(child); container.view.addSubview(child.view); child.didMove(toParent: container)
            child.view.frame = window.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            dock.animator?.stopAnimation(true); window.isHidden = true; window.rootViewController = nil
            original?.makeKeyAndVisible(); scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            // The next test measures safe areas in the scene this one rotated.
            let restored = ContinuousClock.now + .seconds(3)
            while scene.effectiveGeometry.interfaceOrientation != .portrait, ContinuousClock.now < restored {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        try await Task.sleep(for: .milliseconds(800))
        dock.animator?.stopAnimation(true); dock.animator = nil
        let main = try XCTUnwrap(card.children.first?.view)
        for orientation in [UIInterfaceOrientationMask.portrait, .landscapeLeft] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            try await Task.sleep(for: .milliseconds(400))
            window.layoutIfNeeded(); dock.apply(0)
            let displayLeft = container.view.effectiveRadius(corner: .bottomLeft)
            let displayRight = container.view.effectiveRadius(corner: .bottomRight)
            print("Display corner radii (\(orientation.rawValue)): left=\(displayLeft), right=\(displayRight)")
            XCTAssertGreaterThan(displayRight, 0, "The fixture must resolve the actual display geometry")
            XCTAssertEqual(main.effectiveRadius(corner: .bottomLeft), min(CommaTheme.cardRadius, displayLeft), accuracy: 0.5)
            XCTAssertEqual(main.effectiveRadius(corner: .bottomRight), min(CommaTheme.cardRadius, displayRight), accuracy: 0.5)
            let barLeft = dock.panel.effectiveRadius(corner: .topLeft)
            let barRight = dock.panel.effectiveRadius(corner: .topRight)
            XCTAssertGreaterThan(barLeft, 0); XCTAssertGreaterThan(barRight, 0)
            XCTAssertLessThanOrEqual(barLeft, displayLeft); XCTAssertLessThanOrEqual(barRight, displayRight)
            if displayLeft != displayRight {
                XCTAssertEqual(barLeft < barRight, displayLeft < displayRight, "The smaller hardware corner follows rotation")
            }
            attach(window, named: "Minimized Task display corners \(orientation.rawValue)")
            dock.apply(1)
            XCTAssertEqual(dock.panel.effectiveRadius(corner: .topLeft), dock.panel.effectiveRadius(corner: .topRight), accuracy: 0.5,
                           "The expanded sheet restores its symmetric corners")
        }
    }

    func testAppDetailsPresentAboveTheWholeWideShell() async throws {
        let harness = try StoreHarness()
        harness.core.serve("miniApp") { _ in
            ["status": "ready", "app": ["id": "full-app", "workspace_id": "w1", "name": "Full-screen App",
                                          "status": "active", "latest_version": 1], "versions": []]
        }
        await harness.start()
        harness.store.tasksLoaded = true
        harness.store.profileRead = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let navigation = AppNavigation(tab: .apps)
        let root = UIHostingController(rootView: AppShellView(store: harness.store,
            activity: TaskActivityCoordinator(), navigation: navigation))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { root.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        harness.store.miniAppPresentation = .details(MiniAppTarget(workspaceID: "w1", appID: "full-app"))
        let deadline = ContinuousClock.now + .seconds(3)
        while root.presentedViewController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let details = try XCTUnwrap(root.presentedViewController)
        try await Task.sleep(for: .milliseconds(500))
        details.view.layoutIfNeeded()
        let frame = details.view.convert(details.view.bounds, to: window)
        XCTAssertEqual(frame.minX, 0, accuracy: 1)
        XCTAssertEqual(frame.minY, 0, accuracy: 1)
        XCTAssertEqual(frame.width, window.bounds.width, accuracy: 1,
                       "App details must cover both columns, independent of the Apps tab's content inset")
        XCTAssertEqual(frame.height, window.bounds.height, accuracy: 1)
        let detailNavigation = try XCTUnwrap(controllers(details).compactMap { $0 as? UINavigationController }.first)
        let detailItem = try XCTUnwrap(detailNavigation.navigationBar.topItem)
        let closeItems = detailItem.leadingItemGroups.flatMap(\.barButtonItems) + (detailItem.leftBarButtonItems ?? [])
        XCTAssertTrue(closeItems.contains { $0.isEnabled }, "Full-screen details keep an enabled native close action")
        harness.store.miniAppPresentation = nil
        let dismissed = ContinuousClock.now + .seconds(2)
        while root.presentedViewController != nil, ContinuousClock.now < dismissed {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(root.presentedViewController)
        XCTAssertEqual(navigation.tab, .apps, "Closing details returns to the same Apps list")
    }

    func testMinimizedTaskRailControlsStayClearOfItsRoundedCorners() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.store.tasks = [.listed("rail-task", title: "Rail layout")]
        let pane = ConversationPane(kind: .task("rail-task"), workspace: try XCTUnwrap(harness.store.workspace),
                                    conversationID: "rail-task", store: harness.store)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let state = TaskDockState()
        state.bottomInset = window.safeAreaInsets.bottom
        let rail = UIHostingController(rootView: TaskDockRail(store: harness.store, pane: pane, state: state, actions: TaskDockActions()))
        rail.safeAreaRegions = []
        window.rootViewController = container
        container.addChild(rail)
        container.view.addSubview(rail.view)
        rail.didMove(toParent: container)
        window.makeKeyAndVisible()
        rail.view.frame = CGRect(x: 0, y: 0, width: TaskDockViewController.barHeight, height: window.bounds.height)
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        rail.view.layoutIfNeeded()
        let nodes = accessibilityNodes(rail.view)
        for label in [String(localized: "Close task"), String(localized: "Task actions")] {
            let control = try XCTUnwrap(nodes.first { $0.accessibilityLabel == label })
            let frame = rail.view.convert(window.convert(control.accessibilityFrame, from: nil), from: window)
            XCTAssertGreaterThanOrEqual(frame.minY, CommaTheme.cardRadius - 1,
                                       "The entire control must clear the top corner")
            XCTAssertLessThanOrEqual(frame.maxY, rail.view.bounds.height - CommaTheme.cardRadius + 1,
                                     "The entire control must clear the bottom corner")
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, rail.view.bounds.width)
        }
    }

    func testMainChatKeepsItsToolbarWhileTranscriptScrollsInEitherDirection() async throws {
        #if canImport(SwiftUI, _version: 8.0)
        guard #available(iOS 27.0, *) else { throw XCTSkip("Navigation bar minimization") }
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": (0..<30).map { index in
                ["messageId": "message-\(index)", "role": "assistant", "actorType": "agent",
                 "text": "Message \(index). " + String(repeating: "Scroll the conversation in either direction. ", count: 6)]
            },
        ]] }
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let navigation = AppNavigation(routerOpen: true)
        let controller = UIHostingController(rootView: RouterLayerContent(store: harness.store, navigation: navigation))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        let nav = try XCTUnwrap(controllers(controller).compactMap { $0 as? UINavigationController }.first)
        let item = try XCTUnwrap(nav.navigationBar.topItem)
        XCTAssertEqual(item.navigationBarMinimization.minimizationBehavior, .never,
                       "Reversing a scroll must not first enter a navigation-bar restoration state")
        let transcript = try XCTUnwrap(descendants(window).filter(isVisible).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && $0.contentSize.height > $0.bounds.height + 300 }
            .max { $0.contentSize.height < $1.contentSize.height })
        let barFrame = nav.navigationBar.convert(nav.navigationBar.bounds, to: window)
        let start = max(-transcript.adjustedContentInset.top, transcript.contentOffset.y - 240)
        for offset in [start, start + 100, start] {
            transcript.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(transcript.contentOffset.y, offset, accuracy: 1)
            XCTAssertEqual(nav.navigationBar.convert(nav.navigationBar.bounds, to: window), barFrame)
            XCTAssertEqual(item.navigationBarMinimization.minimizationBehavior, .never)
        }
        #else
        throw XCTSkip("Requires the iOS 27 SDK")
        #endif
    }

    func testWideMainChatKeepsItsNavigationBarInTheTrailingColumn() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        guard window.bounds.width >= ShellColumnLayout.minimumColumnWidth * 2 else {
            throw XCTSkip("Requires a window wide enough for the Routines column")
        }
        let navigation = AppNavigation(routerOpen: true)
        let controller = UIHostingController(rootView: RouterLayerContent(store: harness.store, navigation: navigation,
                                                                          sharesRoutineColumn: true))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        let layout = ShellColumnLayout(width: window.bounds.width, folded: false, division: nil)
        XCTAssertTrue(layout.isWide)
        let nav = try XCTUnwrap(controllers(controller).compactMap { $0 as? UINavigationController }.first)
        let bar = nav.navigationBar.convert(nav.navigationBar.bounds, to: window)
        XCTAssertEqual(bar.minX, layout.contentLeadingInset, accuracy: 1,
                       "The Routines column covers the leading column, so the chat's bar starts after it")
        XCTAssertEqual(bar.maxX, window.bounds.maxX, accuracy: 1)
    }

    func testDuoMainChatUsesNativeVerticalActionsWithoutAHorizontalHeader() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { throw XCTSkip("Duo vertical toolbar") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        guard scene.traitCollection.verticalBarEdge != .unspecified else { throw XCTSkip("Requires Duo") }
        let harness = try StoreHarness()
        harness.core.serve("voice") { _ in
            ["workspace": "w1", "integration": ["readiness": ["ready": true]]]
        }
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": [["messageId": "long-message", "role": "assistant", "actorType": "agent",
                                "text": String(repeating: "A message for layout verification. ", count: 100)]],
        ]] }
        await harness.start()
        let call = CallController(store: harness.store, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        await call.refreshAvailability()
        XCTAssertTrue(call.available)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let navigation = AppNavigation(routerOpen: true)
        let root = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation)
            .environment(call))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(700))
        root.view.layoutIfNeeded()
        let router = try XCTUnwrap(controllers(root).compactMap { $0 as? RouterLayerController }.first)
        XCTAssertFalse(router.gestureRecognizerShouldBegin(DownwardChatPan()),
                       "With no Duo header, a downward message scroll must not be claimed as a header-dismiss drag")
        let nav = try XCTUnwrap(controllers(router).compactMap { $0 as? UINavigationController }.first)
        let item = try XCTUnwrap(nav.navigationBar.topItem)
        let items = item.leadingItemGroups.flatMap(\.barButtonItems) + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        let verticalItems = Set(items.filter { $0.axisBehavior == .verticalPreferred }.map(ObjectIdentifier.init))
        XCTAssertEqual(verticalItems.count, 2, "Close and Call use native vertical toolbar placements")
        let nodes = accessibilityNodes(router.hosting.view)
        let close = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Close chat") })
        let phone = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Call") })
        let closeFrame = window.convert(close.accessibilityFrame, from: nil)
        let phoneFrame = window.convert(phone.accessibilityFrame, from: nil)
        XCTAssertGreaterThan(closeFrame.midX, window.bounds.midX)
        XCTAssertEqual(closeFrame.midX, phoneFrame.midX, accuracy: 8, "The system aligns both actions in its right column")
        XCTAssertFalse(closeFrame.intersects(phoneFrame), "Native action slots must not overlap")
        XCTAssertFalse(nodes.contains { $0.accessibilityLabel == String(localized: "Comma") && $0.accessibilityTraits.contains(.header) },
                       "Duo has no Comma header")
        let transcript = try XCTUnwrap(descendants(router.hosting.view).filter(isVisible).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && $0.contentSize.height > $0.bounds.height }
            .max { $0.contentSize.height < $1.contentSize.height })
        let transcriptFrame = transcript.convert(transcript.bounds, to: window)
        XCTAssertLessThanOrEqual(transcriptFrame.minY, window.safeAreaInsets.top + 1,
                                 "There must be no empty horizontal header above the transcript")
        #else
        throw XCTSkip("Requires the iOS 27.1 SDK")
        #endif
    }

    func testDuoBottomTaskUsesFullWidthAndPlacesActionsBesideComposer() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { throw XCTSkip("Duo vertical bar") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        guard scene.traitCollection.verticalBarEdge != .unspecified else { throw XCTSkip("Requires Duo's system bar") }
        let harness = try StoreHarness()
        await harness.start()
        harness.store.tasks = [.listed("duo-task", title: "Duo layout")]
        let pane = ConversationPane(kind: .task("duo-task"), workspace: try XCTUnwrap(harness.store.workspace),
                                    conversationID: "duo-task", store: harness.store)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let dock = TaskDockViewController(store: harness.store, pane: pane, revealRequest: 0, onExpand: {})
        window.rootViewController = dock
        window.makeKeyAndVisible()
        defer { dock.animator?.stopAnimation(true); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(650))
        dock.view.layoutIfNeeded()
        XCTAssertEqual(dock.state.sideInset, 0, "Duo's status column must not create two transcript gutters")
        let controls = descendants(dock.view).filter(isVisible)
        let nodes = accessibilityNodes(dock.view)
        let menu = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Task actions") })
        let menuFrame = window.convert(menu.accessibilityFrame, from: nil)
        let field = try XCTUnwrap(controls.filter { $0 is UITextField || $0 is UITextView }.max { $0.bounds.width < $1.bounds.width })
        let fieldFrame = field.convert(field.bounds, to: window)
        XCTAssertGreaterThan(menuFrame.minY, window.bounds.midY, "The menu must be below the camera")
        let close = try XCTUnwrap(nodes.first { $0.accessibilityLabel == String(localized: "Close task") })
        let closeFrame = window.convert(close.accessibilityFrame, from: nil)
        XCTAssertLessThan(closeFrame.midX, window.bounds.midX)
        XCTAssertLessThan(closeFrame.midY, window.bounds.midY, "Close remains in the upper-left corner")
        XCTAssertGreaterThan(menuFrame.minX, fieldFrame.maxX, "The menu sits outside the input's right edge")
        XCTAssertTrue(menuFrame.intersects(CGRect(x: 0, y: fieldFrame.minY - 44, width: window.bounds.width,
                                                height: fieldFrame.height + 88)))
        dock.update(pane: pane, revealRequest: 0, placement: .leading(width: window.bounds.width * 0.45))
        dock.view.layoutIfNeeded()
        XCTAssertFalse(dock.state.actionsByComposer, "The expanded left column can keep its unobstructed header menu")
        #else
        throw XCTSkip("Requires the iOS 27.1 SDK")
        #endif
    }

    func testSideTaskMinimizesAndReopensBeforeAnExplicitClose() async throws {
        let harness = try StoreHarness()
        await harness.start()
        await harness.store.openTask(id: "side-task")
        let pane = try XCTUnwrap(harness.store.task)
        pane.draftText = "Keep this while minimized"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let dock = TaskDockViewController(store: harness.store, pane: pane, revealRequest: 0,
            placement: .leading(width: window.bounds.width * 0.45), onExpand: {})
        window.rootViewController = dock
        window.makeKeyAndVisible()
        defer { dock.animator?.stopAnimation(true); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        dock.apply(0.2)
        dock.handlePan(EndedTaskDockPan())
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(harness.store.task === pane, "Minimizing must not close the Task")
        XCTAssertTrue(dock.state.covered)
        XCTAssertEqual(dock.panel.frame.maxX, dock.minimizedWidth, accuracy: 1)
        XCTAssertNil(dock.view.hitTest(CGPoint(x: window.bounds.width * 0.75, y: window.bounds.midY), with: nil))
        dock.headerTapped()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(dock.state.covered)
        XCTAssertEqual(dock.progress, 1, accuracy: 0.01)
        XCTAssertEqual(pane.draftText, "Keep this while minimized")
        dock.dismiss()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(harness.store.task, "Only an explicit close removes the Task")
        XCTAssertLessThan(dock.panel.frame.maxX, 0)
    }

    func testTaskSidePanelUsesTheWideLandscapeRoutineColumn() {
        XCTAssertEqual(TaskDockPlacement.resolve(size: CGSize(width: 390, height: 844), leadingInset: 0,
                                                folded: false, division: nil), .bottom)
        XCTAssertEqual(TaskDockPlacement.resolve(size: CGSize(width: 1024, height: 1366), leadingInset: 0,
                                                folded: false, division: nil), .bottom)
        XCTAssertEqual(TaskDockPlacement.resolve(size: CGSize(width: 916, height: 650), leadingInset: 0,
                                                folded: false, division: nil), .leading(width: 458))
        let division = CGRect(x: 492, y: 0, width: 16, height: 650)
        let columns = ShellColumnLayout(width: 916, folded: true, division: division)
        XCTAssertEqual(TaskDockPlacement.resolve(size: CGSize(width: 916, height: 650), leadingInset: 0,
                                                folded: true, division: division), .leading(width: columns.leadingWidth, gap: columns.gap))
    }

    func testTaskSidePanelSlidesHorizontallyAndPassesTouchesToTheList() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let pane = ConversationPane(kind: .task("side-task"), workspace: try XCTUnwrap(harness.store.workspace),
                                    conversationID: "side-task", store: harness.store)
        pane.draftText = "Keep this draft when rotating"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let width = window.bounds.width * 0.45
        let dock = TaskDockViewController(store: harness.store, pane: pane, revealRequest: 0,
                                         placement: .leading(width: width), onExpand: {})
        window.rootViewController = dock
        window.makeKeyAndVisible()
        defer { dock.animator?.stopAnimation(true); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(600))
        dock.animator?.stopAnimation(true)
        dock.animator = nil
        dock.apply(1)
        XCTAssertEqual(dock.panel.frame.width, width, accuracy: 1)
        XCTAssertEqual(dock.panel.frame.minX, 0, accuracy: 1)
        XCTAssertEqual(dock.panel.frame.minY, 0, accuracy: 1, "The side panel reaches the top edge")
        XCTAssertEqual(dock.panel.frame.maxY, dock.view.bounds.maxY, accuracy: 1,
                       "The side panel fills the container's height")
        let listPoint = CGPoint(x: window.bounds.width * 0.75, y: window.bounds.midY)
        XCTAssertNil(dock.view.hitTest(listPoint, with: nil), "The right Task list remains interactive")
        let hosts = dock.children.map(ObjectIdentifier.init)
        dock.apply(0.5)
        XCTAssertEqual(dock.panel.transform.tx, -dock.travel * 0.5, accuracy: 1)
        XCTAssertEqual(dock.panel.transform.ty, 0, accuracy: 1)
        dock.apply(0)
        XCTAssertEqual(dock.panel.frame.maxX, dock.minimizedWidth, accuracy: 1,
                       "Minimizing leaves a visible side bar")
        dock.update(pane: pane, revealRequest: 0, placement: .bottom)
        dock.view.layoutIfNeeded()
        dock.apply(0)
        XCTAssertEqual(dock.panel.transform.tx, 0, accuracy: 1)
        XCTAssertGreaterThan(dock.panel.transform.ty, 0, "Portrait retains the bottom dock's vertical travel")
        XCTAssertEqual(dock.children.map(ObjectIdentifier.init), hosts, "Rotation keeps the conversation hosts")
        XCTAssertEqual(pane.draftText, "Keep this draft when rotating")
    }

    func testTaskBrowserUsesRemainingWidthAndKeepsItsViewerAcrossRotation() async throws {
        let harness = try StoreHarness()
        PhoneMigrationFixtures.configure(harness.core)
        harness.core.serve("chatView") { topic in
            let conversation = topic["conversation"] as? String ?? ""
            return ["revision": 1, "state": ["status": "ready", "loaded": true,
                "conversation": ["id": conversation], "draft": "Keep the Task draft",
                "boundWorker": ["participantId": "worker-" + conversation, "name": "Worker"]]]
        }
        await harness.start()
        harness.store.tasks = [.listed("browser-task", title: "Browser task")]
        let pane = ConversationPane(kind: .task("browser-task"), workspace: try XCTUnwrap(harness.store.workspace),
                                    conversationID: "browser-task", store: harness.store)
        defer { pane.close() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let dock = TaskDockViewController(store: harness.store, pane: pane, revealRequest: 0,
                                         placement: .leading(width: 480), onExpand: {})
        window.rootViewController = container
        container.addChild(dock)
        container.view.addSubview(dock.view)
        dock.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            container.dismiss(animated: false)
            dock.animator?.stopAnimation(true)
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
        }
        dock.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 700)
        try await Task.sleep(for: .milliseconds(600))
        dock.animator?.stopAnimation(true)
        dock.animator = nil
        dock.apply(1)
        let transcript = try XCTUnwrap(dock.children.compactMap { $0 as? UIHostingController<TaskDockContent> }.first)
        let browser = try XCTUnwrap(dock.children.compactMap { $0 as? UIHostingController<TaskDockBrowser> }.first)
        dock.openBrowser()
        let viewer = try XCTUnwrap(dock.state.browser)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(browser.view.layer.presentation()?.bounds.width ?? browser.view.bounds.width,
                       browser.view.bounds.width, accuracy: 1,
                       "The browser keeps its final layout while the outer panel reveals it")
        XCTAssertTrue(harness.core.topics("sessionBrowser").isEmpty, "Wait for a Task participant before querying its browser")
        pane.open()
        let ready = ContinuousClock.now + .seconds(3)
        while viewer.value.object == nil, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(viewer.value.object)
        XCTAssertEqual(viewer.conversation, pane.conversationID)
        XCTAssertEqual(viewer.participant, "worker-browser-task")
        XCTAssertEqual(dock.panel.bounds.width, 1024, accuracy: 1)
        XCTAssertEqual(transcript.view.frame.width, 480, accuracy: 1, "Opening the browser preserves the chat column")
        XCTAssertEqual(browser.view.frame.minX, transcript.view.frame.maxX, accuracy: 1)
        XCTAssertEqual(browser.view.frame.maxX, dock.panel.bounds.maxX, accuracy: 1)
        XCTAssertNil(container.presentedViewController, "A wide Task opens its browser beside the chat")
        XCTAssertTrue(dock.owns(CGPoint(x: 900, y: 350)), "Browser input belongs to the expanded Task panel")
        let image = UIGraphicsImageRenderer(bounds: dock.view.bounds).image { _ in
            dock.view.drawHierarchy(in: dock.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Task browser beside conversation"
        attachment.lifetime = .keepAlways
        add(attachment)

        dock.view.frame = CGRect(x: 0, y: 0, width: 650, height: 1024)
        dock.update(pane: pane, revealRequest: 0, placement: .bottom)
        dock.view.layoutIfNeeded()
        let presented = ContinuousClock.now + .seconds(3)
        while container.presentedViewController == nil, ContinuousClock.now < presented {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(container.presentedViewController, "Portrait presents the browser as a sheet")
        XCTAssertTrue(browser.view.isHidden)
        XCTAssertTrue(dock.state.browser === viewer)

        dock.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 700)
        dock.update(pane: pane, revealRequest: 0, placement: .leading(width: 480))
        dock.view.layoutIfNeeded()
        let dismissed = ContinuousClock.now + .seconds(3)
        while container.presentedViewController != nil, ContinuousClock.now < dismissed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(container.presentedViewController)
        XCTAssertTrue(dock.state.browser === viewer, "Rotation preserves the selected browser and control identity")
        XCTAssertEqual(pane.draftText, "Keep the Task draft")
        dock.update(pane: pane, revealRequest: 0, placement: .leading(width: 480, gap: 64))
        dock.view.layoutIfNeeded()
        XCTAssertEqual(browser.view.frame.minX, 544, accuracy: 1, "Browser controls stay beyond the fold gap")
        XCTAssertEqual(browser.view.frame.maxX, dock.panel.bounds.maxX, accuracy: 1)
        dock.state.browser = nil
        XCTAssertEqual(dock.panel.bounds.width, 480, accuracy: 1, "Closing the browser restores the original Task width")
        XCTAssertNil(dock.view.hitTest(CGPoint(x: 900, y: 350), with: nil), "Closing returns input to the adjacent app")

        dock.openBrowser()
        let next = ConversationPane(kind: .task("next-task"), workspace: pane.workspace,
                                    conversationID: "next-task", store: harness.store)
        next.open()
        defer { next.close() }
        let workerReady = ContinuousClock.now + .seconds(3)
        while next.boundWorker == nil, ContinuousClock.now < workerReady { try await Task.sleep(for: .milliseconds(20)) }
        dock.update(pane: next, revealRequest: 1, placement: .leading(width: 480))
        XCTAssertNil(dock.state.browser, "Another Task must not inherit the old Task's browser")
        XCTAssertEqual(dock.panel.bounds.width, 480, accuracy: 1)
        dock.openBrowser()
        let replaced = ContinuousClock.now + .seconds(3)
        while harness.core.topics("sessionBrowser").count != 1 ||
                harness.core.topics("sessionBrowser").first?["conversation"] as? String != "next-task" {
            if ContinuousClock.now >= replaced { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(harness.core.topics("sessionBrowser").count, 1)
        XCTAssertEqual(harness.core.topics("sessionBrowser").first?["conversation"] as? String, "next-task")

        dock.animator?.stopAnimation(true)
        dock.animator = nil
        dock.apply(0)
        dock.view.frame = CGRect(x: 0, y: 0, width: 650, height: 1024)
        dock.update(pane: next, revealRequest: 1, placement: .bottom)
        dock.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(container.presentedViewController, "Rotating a minimized Task does not raise its browser over the app")
        XCTAssertNil(dock.state.browser)
    }

    func testShellChangesTaskPresentationWithoutReplacingItsPane() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.store.tasksLoaded = true
        harness.store.profileRead = true
        await harness.store.openTask(id: "side-task")
        let pane = try XCTUnwrap(harness.store.task)
        pane.draftText = "Preserve the open Task"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let root = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator()))
        window.rootViewController = container
        container.addChild(root)
        container.view.addSubview(root.view)
        root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        root.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 700)
        try await Task.sleep(for: .milliseconds(700))
        root.view.layoutIfNeeded()
        let dock = try XCTUnwrap(controllers(root).compactMap { $0 as? TaskDockViewController }.first)
        XCTAssertTrue(dock.placement.isLeading, "A wide landscape Task occupies the left column")
        let bar = try XCTUnwrap(controllers(root).compactMap { $0 as? ShellTabBarController }.first)
        let tabs = try XCTUnwrap(bar.parent)
        let deadline = ContinuousClock.now + .seconds(2)
        while tabs.view.convert(tabs.view.bounds, to: root.view).minX == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            root.view.layoutIfNeeded()
        }
        let cardFrame = tabs.view.convert(tabs.view.bounds, to: root.view)
        XCTAssertEqual(cardFrame.minX - dock.minimizedWidth, AppShellView.gap, accuracy: 1,
                       "The app card reserves the side bar and its gap")
        let hit = root.view.hitTest(CGPoint(x: 850, y: 350), with: nil)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit?.isDescendant(of: dock.view) ?? true, "The list beside the Task keeps receiving touches")
        dock.toggle()
        let minimized = ContinuousClock.now + .seconds(2)
        while !dock.state.covered, ContinuousClock.now < minimized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(dock.state.covered)
        XCTAssertEqual(cardFrame.minX - dock.panel.frame.maxX, AppShellView.gap, accuracy: 1,
                       "The minimized Task and app card retain a visible gap")
        root.view.frame = CGRect(x: 0, y: 0, width: 650, height: 1024)
        try await Task.sleep(for: .milliseconds(300))
        root.view.layoutIfNeeded()
        let rotated = try XCTUnwrap(controllers(root).compactMap { $0 as? TaskDockViewController }.first)
        XCTAssertTrue(rotated === dock)
        XCTAssertEqual(rotated.placement, .bottom)
        XCTAssertTrue(rotated.state.covered, "Rotation retains the Task's minimized state")
        XCTAssertTrue(harness.store.task === pane)
        XCTAssertEqual(pane.draftText, "Preserve the open Task")
    }

    /// A short transcript fills its scroll view from the scroll geometry. Filled with `containerRelativeFrame`, its height
    /// followed the scroll offset under a top inset, the bottom anchor moved the offset back, and the open Task froze.
    func testShortTaskTranscriptSettlesWhileMinimizedAndRotated() async throws {
        let harness = try StoreHarness()
        harness.core.serve("chatView") { topic in
            let conversation = topic["conversation"] as? String ?? ""
            let messages: [[String: Any]] = (0..<3).map { index in
                ["messageId": "m\(index)", "role": index % 2 == 0 ? "user" : "assistant",
                 "actorType": index % 2 == 0 ? "user" : "agent", "createdBy": "u1", "text": "Message \(index)"]
            }
            return ["revision": 1, "state": ["status": "ready", "loaded": true, "serverMessages": messages,
                "pending": [], "messages": [], "conversation": ["id": conversation, "kind": "task"]]]
        }
        await harness.start()
        harness.store.tasksLoaded = true
        harness.store.profileRead = true
        harness.store.tasks = [.listed("short-task", title: "Short task")]
        await harness.store.openTask(id: "short-task")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator()))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        // The first run after a build takes longer to show the dock's transcript.
        var found: UIScrollView?
        for _ in 0..<50 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            found = controllers(root).compactMap { $0 as? TaskDockViewController }.first.flatMap { dock in
                descendants(dock.view).compactMap { $0 as? UIScrollView }.first { $0.bounds.height > 200 }
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        let dock = try XCTUnwrap(controllers(root).compactMap { $0 as? TaskDockViewController }.first)
        let transcript = try XCTUnwrap(found)
        func assertSettled(_ stage: String) {
            let inset = transcript.adjustedContentInset
            XCTAssertLessThanOrEqual(transcript.bounds.height, dock.view.bounds.height + 1,
                                     "The transcript does not outgrow the dock: \(stage)")
            XCTAssertEqual(transcript.contentSize.height + inset.top + inset.bottom, transcript.bounds.height, accuracy: 1,
                           "The short transcript exactly fills its viewport: \(stage)")
            XCTAssertLessThan(transcript.layer.animationKeys()?.count ?? 0, 8, "No offset animations pile up: \(stage)")
        }
        assertSettled("expanded")
        dock.toggle()
        try await Task.sleep(for: .milliseconds(800))
        assertSettled("minimized")
        let wide = window.bounds.size
        UIView.animate(withDuration: 0.3) {
            window.frame.size = CGSize(width: wide.height, height: wide.width)
            window.layoutIfNeeded()
        }
        UIView.animate(withDuration: 0.3) {
            window.frame.size = wide
            window.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(800))
        assertSettled("minimized after resizing and back")
    }

    func testHomeSwitcherReturnsWhenTheKeyboardEndsOffScreen() {
        let screen = UIScreen.main
        func note(_ end: CGRect) -> Notification {
            Notification(name: UIResponder.keyboardWillChangeFrameNotification, object: screen,
                         userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: end)])
        }
        let height = screen.bounds.height
        XCTAssertTrue(HomeView.keyboardOnScreen(note(CGRect(x: 0, y: height - 300, width: screen.bounds.width, height: 300))))
        XCTAssertFalse(HomeView.keyboardOnScreen(note(CGRect(x: 0, y: height, width: screen.bounds.width, height: 300))),
                       "A keyboard announced below the screen does not hide the status switcher")
    }

    func testWidePhoneSearchUsesTheNativeDismissalWithoutExtraChrome() async throws {
        guard #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("This presentation belongs to iPhone on iOS 26 or later")
        }
        let harness = try StoreHarness()
        await harness.start()
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let navigation = AppNavigation()
        navigation.openSearch()
        let controller = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation))
        if scene.coordinateSpace.bounds.width > 600 { controller.traitOverrides.horizontalSizeClass = .regular }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let settled = expectation(description: "Native search presentation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 3)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            controller.view.layoutIfNeeded()
            if descendants(window).filter(isVisible).contains(where: {
                ($0 as? UITextField)?.placeholder == String(localized: "Search tasks")
            }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let views = descendants(window).filter(isVisible)
        if let field = views.compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == String(localized: "Search tasks") }) {
            let frame = field.convert(field.bounds, to: window)
            XCTAssertLessThan(abs(frame.midX - window.bounds.midX), window.bounds.width * 0.2,
                              "Search must occupy the wide phone rather than leave the right side empty")
        }
        let bars = views.compactMap { $0 as? UINavigationBar }
        XCTAssertFalse(bars.contains { $0.topItem?.title == String(localized: "Search") }, "Phone search must not add a separate Search title")
        XCTAssertFalse(views.contains { $0.accessibilityIdentifier == "closeTaskSearch" }, "The native search dismissal must not get an extra app Close button")
        XCTAssertTrue(views.contains { ($0 as? UITextField)?.placeholder == String(localized: "Search tasks") }, "The native search field remains available")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Phone search chrome"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSystemTabSafeAreaCanSettleAfterTheContainerLayout() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let shell = ShellTabsController(store: harness.store, navigation: AppNavigation(), bar: ShellTabBar()) { _ in
            HostedContent(content: AnyView(Color.clear), environment: EnvironmentValues())
        }
        window.rootViewController = shell
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let native = try XCTUnwrap(shell.children.compactMap { $0 as? ShellTabBarController }.first)
        let standIn = try XCTUnwrap(native.selectedViewController)
        let page = try XCTUnwrap(shell.children.compactMap { $0 as? UIHostingController<HostedContent<AnyView>> }.first { !$0.view.isHidden })
        let before = page.view.safeAreaInsets.right
        standIn.additionalSafeAreaInsets.right += 40
        standIn.view.layoutIfNeeded()
        shell.view.layoutIfNeeded()
        XCTAssertEqual(page.view.safeAreaInsets.right, standIn.view.safeAreaInsets.right, accuracy: 1,
                       "A late system tab inset must update the visible page without a tab switch")
        shell.view.setNeedsLayout()
        shell.view.layoutIfNeeded()
        standIn.additionalSafeAreaInsets.right -= 40
        standIn.view.layoutIfNeeded()
        shell.view.layoutIfNeeded()
        XCTAssertEqual(page.view.safeAreaInsets.right, before, accuracy: 1,
                       "A settled system tab must release its earlier right reservation without switching tabs")
    }

    func testColdHomeLayoutDoesNotNeedATabSwitch() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        for orientation in [UIInterfaceOrientationMask.landscapeLeft, .portrait] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            try await Task.sleep(for: .milliseconds(800))
            let harness = try StoreHarness()
            harness.store.profileRead = true
            harness.store.tasksLoaded = true
            let navigation = AppNavigation(routerOpen: true)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            let controller = UIHostingController(rootView: AnyView(ColdShellFixture(store: harness.store, navigation: navigation)))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await harness.start()
            try await Task.sleep(for: .milliseconds(800))
            navigation.closeRouter()
            try await Task.sleep(for: .milliseconds(800))
            window.layoutIfNeeded()
            let cold = try coldHomeGeometry(window)
            XCTAssertGreaterThan(cold.width, 0, "Cold Home receives its column width on first appearance")
            coldLayoutAttachment(window, controller: controller, named: "Cold Home " + (orientation == .portrait ? "portrait" : "landscape"))
            navigation.select(.inbox)
            try await Task.sleep(for: .milliseconds(300))
            navigation.select(.home)
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            let revisited = try coldHomeGeometry(window)
            coldLayoutAttachment(window, controller: controller, named: "Revisited Home " + (orientation == .portrait ? "portrait" : "landscape"))
            XCTAssertEqual(cold.width, revisited.width, accuracy: 1, "The first Home must have the same content width as Home after a tab switch")
            XCTAssertEqual(cold.right, revisited.right, accuracy: 1, "The first Home must not retain a larger right inset")
            controller.rootView = AnyView(EmptyView())
            controller.dismiss(animated: false)
            controller.view.layoutIfNeeded()
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
        }
        original?.makeKeyAndVisible()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(for: .milliseconds(800))
    }

    private func coldHomeGeometry(_ window: UIWindow) throws -> (width: CGFloat, right: CGFloat) {
        let root = try XCTUnwrap(window.rootViewController)
        let bar = try XCTUnwrap(controllers(root).compactMap { $0 as? ShellTabBarController }.first)
        let shell = try XCTUnwrap(bar.parent)
        let page = try XCTUnwrap(shell.children.first { $0 !== bar && $0.isViewLoaded && !$0.view.isHidden })
        XCTAssertEqual(page.view.bounds.width, shell.view.bounds.width, accuracy: 1,
                       "The selected page fills its allocated column")
        return (page.view.safeAreaLayoutGuide.layoutFrame.width, page.view.safeAreaInsets.right)
    }

    private func coldLayoutAttachment(_ window: UIWindow, controller: UIViewController, named name: String) {
        let layout = controllers(controller).map { child in
            "\(String(describing: type(of: child)).split(separator: "<").first ?? "controller") frame=\(child.view.convert(child.view.bounds, to: window)) safe=\(child.view.safeAreaInsets) extra=\(child.additionalSafeAreaInsets)"
        }.joined(separator: "\n")
        print("COLD_HOME_GEOMETRY \(name)\n\(layout)")
        let text = XCTAttachment(string: layout)
        text.name = name + " geometry"; text.lifetime = .keepAlways; add(text)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWidePhoneTabsFillTheirColumn() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone layout") }
        let harness = try StoreHarness()
        await harness.start()
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        try MiniAppMediaFixture.serve(harness.core)
        harness.core.serve("miniApps") { _ in
            ["status": "ready", "apps": [
                ["id": "reading", "workspace_id": "w1", "name": "Reading tracker",
                 "description": "Keep a reading list and summarize your notes.", "status": "active", "live_version": 2,
                 "icon_url": "/v1/comma/apps/reading/icon?v=2",
                 "cover_url": "/v1/comma/apps/reading/cover?v=2", "screenshot_urls": ["/v1/comma/apps/reading/screenshots/0?v=2"]],
                ["id": "draft", "workspace_id": "w1", "name": "未发布的小程序 · A longer app name",
                 "description": "还没有截图的应用，也应保持完整的卡片和清晰的文字。", "status": "active"],
                ["id": "disabled", "workspace_id": "w1", "name": "Disabled app",
                 "description": "This app cannot run right now.", "status": "disabled", "live_version": 1],
            ]]
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let navigation = AppNavigation()
        let controller = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation))
        if scene.coordinateSpace.bounds.width > 600 { controller.traitOverrides.horizontalSizeClass = .regular }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        for orientation in [UIInterfaceOrientationMask.portrait, .landscapeLeft] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            let rotates = expectation(description: "Scene geometry settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { rotates.fulfill() }
            await fulfillment(of: [rotates], timeout: 3)
            XCTAssertEqual(scene.interfaceOrientation.isLandscape, orientation == .landscapeLeft)
            for tab in [AppTab.home, .inbox, .apps, .settings] {
                navigation.select(tab)
                let settled = expectation(description: tab.title + " layout settled")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
                await fulfillment(of: [settled], timeout: 3)
                controller.view.layoutIfNeeded()
                let lists = descendants(window).filter(isVisible).compactMap { $0 as? UIScrollView }
                let bar = try XCTUnwrap(controllers(controller).compactMap { $0 as? ShellTabBarController }.first)
                let tabs = try XCTUnwrap(bar.parent)
                #if canImport(SwiftUI, _version: 8.0.85)
                if #available(iOS 27.1, *), tab == .home, bar.traitCollection.verticalBarEdge != .unspecified {
                    let items = controllers(controller).compactMap { $0 as? UINavigationController }
                        .filter { isVisible($0.view) }
                        .flatMap { nav -> [UIBarButtonItem] in
                            guard let item = nav.navigationBar.topItem else { return [] }
                            return item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? [])
                        }
                    let verticalItems = Set(items.filter { $0.axisBehavior == .verticalPreferred }.map(ObjectIdentifier.init))
                    XCTAssertGreaterThanOrEqual(verticalItems.count, 2,
                                                "Filter and Archive stay in Duo's vertical bar in either orientation")
                }
                #endif
                let column = tabs.view.convert(tabs.view.bounds, to: window)
                XCTAssertTrue(lists.contains {
                    let frame = $0.convert($0.bounds, to: window)
                    return frame.midX >= column.minX && frame.width >= column.width * 0.9
                }, "The selected main page fills its column")
                if tab == .apps {
                    let field = try XCTUnwrap(descendants(window).filter(isVisible).compactMap { $0 as? UITextField }
                        .first { $0.placeholder == String(localized: "Search apps") })
                    let searchFrame = field.convert(field.bounds, to: window)
                    XCTAssertLessThan(searchFrame.maxY, window.bounds.midY, "Apps search stays at the top of the full shell")
                    let routerFrame = navigation.routerButtonFrame
                    XCTAssertFalse(routerFrame.isEmpty, "The full shell must expose the Comma entry geometry")
                    XCTAssertFalse(searchFrame.intersects(routerFrame), "Apps search must not cover the Comma entry")
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Main " + tab.title + (orientation == .portrait ? " portrait" : " landscape")
                attachment.lifetime = .keepAlways
                add(attachment)
                if tab == .apps {
                    controller.overrideUserInterfaceStyle = .dark
                    try await Task.sleep(for: .milliseconds(200))
                    attach(window, named: "Apps grid dark " + (orientation == .portrait ? "portrait" : "landscape"))
                    controller.overrideUserInterfaceStyle = .light
                    if let scroll = lists.first(where: { $0.contentSize.height > $0.bounds.height + 100 }) {
                        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                        try await Task.sleep(for: .milliseconds(200))
                        attach(window, named: "Apps grid lower cards " + (orientation == .portrait ? "portrait" : "landscape"))
                        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    controller.overrideUserInterfaceStyle = .unspecified
                }
            }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        let restored = expectation(description: "Portrait restored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 3)
    }

    func testInitialChatAndMiniAppCardFillWindow() async throws {
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": [["messageId": "preview", "role": "assistant", "actorType": "agent", "text": "Your app preview is ready.",
                                "parts": [["kind": "mini-app", "appId": "reading", "appVersion": 2, "name": "Reading tracker",
                                           "summary": "Keep your reading list and summarize notes.", "conversationId": "build"]]]],
        ]] }
        await harness.start()
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let navigation = AppNavigation(routerOpen: true)
        let controller = UIHostingController(rootView: AppShellView(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        for orientation in [UIInterfaceOrientationMask.portrait, .landscapeLeft] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            let settled = expectation(description: "Initial chat layout")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
            await fulfillment(of: [settled], timeout: 3)
            window.layoutIfNeeded()
            let routers = controllers(controller).compactMap { $0 as? RouterLayerController }
            let router = try XCTUnwrap(routers.first)
            XCTAssertEqual(router.view.bounds.width, window.bounds.width, accuracy: 1)
            XCTAssertEqual(router.hosting.view.bounds.width, window.bounds.width, accuracy: 1)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Chat Mini App card " + (orientation == .portrait ? "portrait" : "landscape")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(for: .milliseconds(800))
    }

    func testDuoMainChatKeepsRoutinesBesideSettingsAndRestoresItsDetail() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { throw XCTSkip("Requires Duo") }
        let harness = try StoreHarness()
        PhoneFeatureFixtures.configure(harness.core)
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": [["messageId": "briefing", "role": "assistant", "actorType": "agent",
                                "text": "今天的安排已经整理好了。\n\n我们可以先检查发布清单，再处理代码评审。左侧的 Routines 会保留在原位，你可以随时选择一项加入聊天。"]],
        ]] }
        harness.core.serve("recommendations") { _ in
            ["envelope": ["state": "fresh", "settings": ["sources": []],
                          "snapshot": ["generation": 1, "summary": [["kind": "markdown", "text":
                            "### 今日概览\n\n发布准备工作已整理，接下来可以逐项检查。\n\n- 检查客户端功能与截图\n- 确认待处理的代码评审\n- 整理今天的后续安排\n\n聊天打开时，这份概览仍保留在左侧。"]], "cards": []]]]
        }
        await harness.start()
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .max { $0.coordinateSpace.bounds.width < $1.coordinateSpace.bounds.width })
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let navigation = AppNavigation(tab: .settings)
        navigation.settingsPath = [.models]
        let controller = UIHostingController(rootView: ShellCard(store: harness.store,
            activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery()))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
        try await Task.sleep(for: .milliseconds(850))
        guard scene.traitCollection.verticalBarEdge != .unspecified else { throw XCTSkip("Requires Duo's system bar") }
        print("Duo Chat: waiting for the unfolded inner display")
        let deadline = ContinuousClock.now + .seconds(30)
        while window.bounds.width < ShellColumnLayout.minimumColumnWidth * 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard window.bounds.width >= ShellColumnLayout.minimumColumnWidth * 2 else {
            XCTFail("Run on Duo's unfolded inner display"); return
        }
        try await Task.sleep(for: .milliseconds(850))
        let sidebar = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first {
            $0.convert($0.bounds, to: window).maxX < 1 && $0.bounds.width > 100
        })
        let offset = sidebar.contentOffset
        attach(window, named: "24-duo-chat-settings-before")
        navigation.openRouter()
        try await Task.sleep(for: .milliseconds(850))
        let router = try XCTUnwrap(controllers(controller).compactMap { $0 as? RouterLayerController }.first)
        XCTAssertFalse(router.view.accessibilityViewIsModal)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: window)
        XCTAssertEqual(sidebarFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(sidebar.contentOffset, offset)
        let transcript = try XCTUnwrap(descendants(router.hosting.view).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) && $0.bounds.height > 200 }.max { $0.bounds.height < $1.bounds.height })
        let chatFrame = transcript.convert(transcript.bounds, to: window)
        XCTAssertGreaterThanOrEqual(chatFrame.minX, sidebarFrame.maxX - 1, "Main Chat must not cover Routines")
        XCTAssertLessThan(chatFrame.width, window.bounds.width * 0.6)
        let point = sidebar.convert(CGPoint(x: 50, y: min(sidebar.bounds.midY, sidebar.contentSize.height / 2)), to: window)
        let hit = try XCTUnwrap(window.hitTest(point, with: nil))
        XCTAssertTrue(hit === sidebar || hit.isDescendant(of: sidebar),
                      "Visible Routines content must receive touches: \(type(of: hit)), point \(point), content \(sidebar.contentSize)")
        attach(window, named: "25-duo-chat-right-column")
        navigation.closeRouter()
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(navigation.settingsPath, [.models])
        XCTAssertTrue(sidebar.isDescendant(of: controller.view))
        XCTAssertLessThanOrEqual(sidebar.convert(sidebar.bounds, to: window).maxX, 1)
        attach(window, named: "26-duo-chat-settings-restored")
        #else
        throw XCTSkip("Requires the Duo SDK")
        #endif
    }

    func testMainChatKeepsTheSameRoutineSidebarVisibleAndInteractive() async throws {
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": [["messageId": "welcome", "role": "assistant", "actorType": "agent",
                                "text": "Your briefing stays on the left while we chat here."]],
        ]] }
        harness.core.serve("recommendations") { _ in
            ["envelope": ["state": "fresh", "settings": ["sources": []],
                          "snapshot": ["generation": 1,
                                       "summary": [["kind": "markdown", "text": String(repeating: "Your daily briefing.\n\n", count: 80)]],
                                       "cards": []]]]
        }
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let navigation = AppNavigation()
        let controller = UIHostingController(rootView: ShellCard(store: harness.store,
            activity: TaskActivityCoordinator(), navigation: navigation, query: HomeTaskQuery()))
        window.rootViewController = container
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 700)
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1200))
        let sidebar = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first {
            let frame = $0.convert($0.bounds, to: controller.view)
            return frame.minX < 1 && frame.width > 100 && frame.width < 600 && $0.contentSize.height > $0.bounds.height
        })
        sidebar.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        let offset = sidebar.contentOffset
        for open in [true, false] {
            if open { navigation.openRouter() } else { navigation.closeRouter() }
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertTrue(sidebar.isDescendant(of: controller.view), "The same sidebar survives chat open and close")
            XCTAssertEqual(sidebar.contentOffset, offset, "Opening chat preserves the briefing's scroll position")
            let point = sidebar.convert(CGPoint(x: 50, y: sidebar.bounds.midY), to: controller.view)
            let hit = try XCTUnwrap(controller.view.hitTest(point, with: nil))
            XCTAssertTrue(hit === sidebar || hit.isDescendant(of: sidebar), "The visible Routines remain interactive")
            var ancestor: UIView? = sidebar
            while let view = ancestor {
                XCTAssertFalse(view.accessibilityElementsHidden, "Routines must remain in the accessibility tree")
                XCTAssertFalse(view.isHidden)
                XCTAssertGreaterThan(view.alpha, 0)
                ancestor = view.superview
            }
            if open {
                let router = try XCTUnwrap(controllers(controller).compactMap { $0 as? RouterLayerController }.first)
                XCTAssertFalse(router.view.accessibilityViewIsModal)
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Chat with persistent Routines"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testMainChatFollowsTheHomeTrailingColumnWhenResized() async throws {
        let harness = try StoreHarness()
        harness.core.serve("chatView") { _ in ["revision": 2, "state": [
            "status": "ready", "loaded": true, "conversation": ["id": "router", "kind": "workspace_chat"],
            "serverMessages": [["messageId": "long-message", "role": "assistant", "actorType": "agent",
                                "text": String(repeating: "A message for layout verification. ", count: 100)]],
        ]] }
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let home = UIHostingController(rootView: ShellTabs(store: harness.store,
            activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(AppNavigation()).providingInbox(store: harness.store))
        let controller = UIHostingController(rootView: RouterLayerContent(store: harness.store,
            navigation: AppNavigation(routerOpen: true)))
        window.rootViewController = container
        container.addChild(home)
        container.view.addSubview(home.view)
        home.didMove(toParent: container)
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }

        for width: CGFloat in [390, 1024, 390] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            home.view.frame = controller.view.frame
            try await Task.sleep(for: .milliseconds(800))
            controller.view.layoutIfNeeded()
            let homeNav = try XCTUnwrap(controllers(home).compactMap { $0 as? UINavigationController }.first)
            let homeContent = homeNav.view.convert(homeNav.view.safeAreaLayoutGuide.layoutFrame, to: controller.view)
            let transcript = try XCTUnwrap(descendants(controller.view).filter(isVisible).compactMap { $0 as? UIScrollView }
                .filter { !($0 is UITextView) && $0.contentSize.height > $0.bounds.height }
                .max { $0.contentSize.height < $1.contentSize.height })
            let content = transcript.convert(transcript.safeAreaLayoutGuide.layoutFrame, to: controller.view)
            XCTAssertEqual(content.minX, homeContent.minX, accuracy: 1,
                           "Chat reserves the same leading column as Home")
            XCTAssertEqual(content.width, homeContent.width, accuracy: 1,
                           "Returning to a compact viewport restores the full chat width")
        }
    }

    func testWideShellKeepsTheRoutineColumnAcrossTabChanges() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        let navigation = AppNavigation()
        let controller = UIHostingController(rootView: ShellTabs(store: harness.store,
            activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(navigation).providingInbox(store: harness.store))
        window.rootViewController = container
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }

        // Window space decides, even on a phone with a compact size class.
        controller.traitOverrides.horizontalSizeClass = .compact
        for width: CGFloat in [390, 1024, 390] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            let bar = try XCTUnwrap(controllers(controller).compactMap { $0 as? ShellTabBarController }.first)
            let tabs = try XCTUnwrap(bar.parent)
            let frame = tabs.view.convert(tabs.view.bounds, to: controller.view)
            XCTAssertEqual(frame.width, width, accuracy: 1,
                           "The native toolbar keeps the full viewport while content columns resize")
            let page = try XCTUnwrap(tabs.children.first { $0 !== bar && $0.isViewLoaded && !$0.view.isHidden })
            if width >= 700 {
                XCTAssertGreaterThan(page.view.safeAreaInsets.left, width * 0.35,
                                     "Page content reserves the persistent Routine column")
                XCTAssertLessThan(page.view.safeAreaLayoutGuide.layoutFrame.width, width * 0.6)
            } else {
                XCTAssertLessThan(page.view.safeAreaInsets.left, width * 0.1,
                                  "Compact content releases the Routine reservation")
            }
            for tab in [AppTab.inbox, .settings, .home] {
                navigation.select(tab)
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutIfNeeded()
                XCTAssertTrue(bar.parent === tabs, "A tab switch retains the column's native container")
                XCTAssertEqual(tabs.view.convert(tabs.view.bounds, to: controller.view), frame,
                               "Switching tabs preserves the room reserved for Routines")
                XCTAssertEqual(tabs.children.filter { $0 !== bar && $0.isViewLoaded && !$0.view.isHidden }.count, 1)
            }
        }
    }

    func testDuoTaskToolbarUsesNativeImageItemsWhileItsColumnResizes() async throws {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { throw XCTSkip("Duo vertical toolbar") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        guard scene.traitCollection.verticalBarEdge != .unspecified else { throw XCTSkip("Requires a vertical system bar") }
        let harness = try StoreHarness()
        await harness.start()
        harness.store.tasksLoaded = true
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let query = HomeTaskQuery()
        let navigation = AppNavigation()
        var environment = EnvironmentValues()
        environment.homeTaskColumn = true
        let controller = ShellTabsController(store: harness.store, navigation: navigation, bar: ShellTabBar()) { _ in
            HostedContent(content: HomeView(store: harness.store, query: query).environment(navigation), environment: environment)
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        var firstBarWidth: CGFloat?
        for fraction: CGFloat in [0.5, 0.55, 0.5] {
            query.filter.labels = fraction > 0.5 ? ["urgent"] : nil
            controller.update(bar: ShellTabBar(), environment: environment,
                              contentLeadingInset: window.bounds.width * fraction) { _ in
                HostedContent(content: HomeView(store: harness.store, query: query).environment(navigation), environment: environment)
            }
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let page = try XCTUnwrap(controller.children.first { !($0 is ShellTabBarController) && !$0.view.isHidden })
            let nav = try XCTUnwrap(controllers(page).compactMap { $0 as? UINavigationController }.first)
            if let firstBarWidth {
                XCTAssertEqual(nav.navigationBar.bounds.width, firstBarWidth, accuracy: 1,
                               "Resizing the content column must not resize the native navigation bar")
            } else { firstBarWidth = nav.navigationBar.bounds.width }
            let items = (nav.navigationBar.topItem?.trailingItemGroups.flatMap(\.barButtonItems) ?? [])
                + (nav.navigationBar.topItem?.rightBarButtonItems ?? [])
            var seen: Set<ObjectIdentifier> = []
            let actions = items.filter { $0.axisBehavior == .verticalPreferred && seen.insert(ObjectIdentifier($0)).inserted }
            XCTAssertEqual(actions.count, 2)
            XCTAssertTrue(actions.allSatisfy { $0.image != nil && $0.customView == nil },
                          "Filter and Archive remain native image items during content resizing")
        }
        #else
        throw XCTSkip("Requires the iOS 27.1 SDK")
        #endif
    }

    func testColumnResizePassesIntermediateInsetsWithoutResizingNativeBar() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let motion = ColumnMotionFixtureState(inset: window.bounds.width * 0.25)
        let navigation = AppNavigation()
        let controller = UIHostingController(rootView: ColumnMotionFixture(store: harness.store,
            navigation: navigation, motion: motion))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        let bar = try XCTUnwrap(controllers(controller).compactMap { $0 as? ShellTabBarController }.first)
        let shell = try XCTUnwrap(bar.parent)
        let page = try XCTUnwrap(shell.children.first { $0 !== bar && !$0.view.isHidden })
        let barWidth = bar.view.bounds.width
        let start = page.additionalSafeAreaInsets.left
        let end = window.bounds.width * 0.4
        withAnimation(.linear(duration: 1)) { motion.inset = end }
        var intermediateInsets: [CGFloat] = []
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(80))
            controller.view.layoutIfNeeded()
            let inset = page.additionalSafeAreaInsets.left
            if inset > start + 1, inset < end - 1 { intermediateInsets.append(inset) }
            #if canImport(SwiftUI, _version: 8.0.85)
            if #available(iOS 27.1, *), bar.traitCollection.verticalBarEdge != .unspecified {
                XCTAssertEqual(bar.view.bounds.width, barWidth, accuracy: 1,
                               "Only content moves; Duo's native bar retains its viewport")
            }
            #endif
        }
        XCTAssertGreaterThan(intermediateInsets.count, 2,
                             "Content width must pass through intermediate values rather than jump to its target")
        XCTAssertGreaterThan((intermediateInsets.max() ?? start) - (intermediateInsets.min() ?? start), 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(page.additionalSafeAreaInsets.left, end, accuracy: 1)
    }

    func testWideShellLoadsRoutinesOnFirstAppearanceWithoutRotation() async throws {
        let harness = try StoreHarness()
        harness.core.serve("recommendations") { _ in
            ["envelope": ["state": "fresh", "snapshot": ["generation": 1,
                "summary": [["kind": "markdown", "text": "The first briefing is ready."]], "cards": []]]]
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let navigation = AppNavigation(tab: .settings)
        let controller = UIHostingController(rootView: ShellTabs(store: harness.store,
            activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(navigation).providingInbox(store: harness.store)
            .frame(width: 1024, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        // The sidebar appears before the initial Workspace restoration completes.
        await harness.start()
        for read in 0..<2 {
            if read == 1 {
                navigation.select(.inbox)
                harness.store.routines.reset()
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while harness.store.routines.feed == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let feed = try XCTUnwrap(harness.store.routines.feed,
                                    "The visible sidebar loads on first appearance and after a reset without a rotation or Home visit")
            XCTAssertEqual(feed.summaryText, "The first briefing is ready.")
            let topics = harness.core.topics("recommendations")
            XCTAssertEqual(topics.count, 1, "The sidebar shares one Workspace subscription")
            XCTAssertEqual(topics.first?["workspace"] as? String, "w1")
        }
    }

    func testRoutineGreetingKeepsRoomAboveTheScrollingBriefing() async throws {
        let harness = try StoreHarness()
        let summary = (1...18).map { "Update \($0): Review the project notes and reply to the team before the next meeting." }.joined(separator: "\n\n")
        harness.core.serve("recommendations") { _ in
            ["envelope": ["state": "fresh", "settings": ["sources": []],
                          "snapshot": ["generation": 1, "summary": [["kind": "markdown", "text": summary]], "cards": []]]]
        }
        await harness.start()
        harness.store.profileRead = true
        _ = await harness.store.routines.load(store: harness.store)
        await until { harness.store.routines.feed != nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: RoutineSidebar(store: harness.store).environment(AppNavigation()))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first)
        XCTAssertGreaterThanOrEqual(scroll.adjustedContentInset.top, controller.view.safeAreaInsets.top + 60,
                                    "The pinned greeting reserves its height and breathing room below the top safe area")
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 100 - scroll.adjustedContentInset.top), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        attach(window, named: "Routine greeting light")
        controller.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(150))
        attach(window, named: "Routine greeting dark")
    }

    func testPlatformCardsKeepTheirWidthInWiderWindows() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var width: CGFloat = 0
        let controller = UIHostingController(rootView: PlatformCardSizingFixture(availableWidth: 390, typeSize: .large) { width = $0 })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for available: CGFloat in [390, 1024] {
                controller.rootView = PlatformCardSizingFixture(availableWidth: available, typeSize: typeSize) { width = $0 }
                try await Task.sleep(for: .milliseconds(150))
                controller.view.layoutIfNeeded()
                XCTAssertEqual(width, typeSize.isAccessibilitySize ? 280 : 160, accuracy: 0.5,
                               "Wider windows reveal more cards instead of stretching each card")
            }
        }
    }

    func testStatusSwitcherOnlyExpandsTheSelectedStatus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var width: CGFloat = 0
        let controller = UIHostingController(rootView: StatusSwitcherSizingFixture(selection: .needsReview) { width = $0 })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutIfNeeded()
        let longLabelWidth = width
        XCTAssertGreaterThan(longLabelWidth, 0)
        XCTAssertLessThan(longLabelWidth, 360, "Inactive icons must not stretch the capsule to fill its container")

        controller.rootView = StatusSwitcherSizingFixture(selection: .done) { width = $0 }
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThan(width, longLabelWidth, "The capsule follows the selected label's width")
    }

    func testFoldedColumnsClearThePhysicalFoldWithASideBar() {
        // A 1000pt display leaves 916pt for content after its 84pt right system bar.
        // The physical fold remains at x=500 in this content coordinate space.
        let fold = CGRect(x: 488, y: 0, width: 24, height: 700)
        let layout = ShellColumnLayout(width: 916, folded: true, division: fold)
        let leadingEdge = layout.leadingWidth
        let trailingEdge = 916 - layout.trailingWidth
        XCTAssertEqual(fold.midX - leadingEdge, trailingEdge - fold.midX, accuracy: 0.5,
                       "Both content edges stay equally far from the physical fold")
        XCTAssertGreaterThanOrEqual(trailingEdge - leadingEdge, 64)
        XCTAssertEqual(layout.leadingWidth - layout.trailingWidth, 84, accuracy: 0.5,
                       "The right content column leaves room for the right system bar")

        let widerFold = CGRect(x: 452, y: 0, width: 96, height: 700)
        let wider = ShellColumnLayout(width: 916, folded: true, division: widerFold)
        XCTAssertLessThanOrEqual(wider.leadingWidth, widerFold.minX)
        XCTAssertGreaterThanOrEqual(916 - wider.trailingWidth, widerFold.maxX,
                                    "A wider system-reserved division must stay entirely clear")

        let flat = ShellColumnLayout(width: 916, folded: false, division: widerFold)
        XCTAssertEqual(flat.leadingWidth, flat.trailingWidth)
        XCTAssertEqual(flat.gap, 0)
    }

    func testHomeFoldLayoutKeepsItsModeAcrossSmallAngleChanges() {
        var folded = false
        for angle in [180.0, 177, 175] {
            folded = HomeFoldLayout.isFolded(angle: angle, wasFolded: folded)
            XCTAssertFalse(folded)
        }
        folded = HomeFoldLayout.isFolded(angle: 174.9, wasFolded: folded)
        XCTAssertTrue(folded)
        for angle in [175.0, 176, 177.9] {
            folded = HomeFoldLayout.isFolded(angle: angle, wasFolded: folded)
            XCTAssertTrue(folded)
        }
        XCTAssertFalse(HomeFoldLayout.isFolded(angle: 178, wasFolded: folded))
        XCTAssertFalse(HomeFoldLayout.isFolded(angle: nil, wasFolded: folded),
                       "Leaving a hinge-capable display restores the normal layout")
    }

    private func attach(_ window: UIWindow, named name: String) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }

    private func isVisible(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0 else { return false }
        return view.superview.map(isVisible) ?? true
    }

    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        var nodes: [NSObject] = []
        func visit(_ node: NSObject) {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            nodes.append(node)
            if let view = node as? UIView { view.subviews.forEach(visit) }
            let children = node.automationElements ?? node.accessibilityElements
            if let children {
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

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}


private final class DownwardChatPan: UIPanGestureRecognizer {
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 100, y: 30) }
    override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: 100) }
    override func translation(in view: UIView?) -> CGPoint { .zero }
}

private final class EndedTaskDockPan: UIPanGestureRecognizer {
    override var state: UIGestureRecognizer.State {
        get { .ended }
        set { }
    }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}

@Observable
private final class ColumnMotionFixtureState {
    var inset: CGFloat
    init(inset: CGFloat) { self.inset = inset }
}

private struct ColumnMotionFixture: View {
    let store: CommaStore
    let navigation: AppNavigation
    let motion: ColumnMotionFixtureState

    var body: some View {
        ShellColumns(store: store, navigation: navigation, bar: ShellTabBar(), wide: true,
                     leadingWidth: motion.inset - 32, contentLeadingInset: motion.inset) { _ in
            Color.clear
        }
        .environment(navigation)
    }
}

private struct PlatformCardSizingFixture: View {
    let availableWidth: CGFloat
    let typeSize: DynamicTypeSize
    let measure: (CGFloat) -> Void

    var body: some View {
        PlatformCard.placeholder(0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measure($0) }
            .frame(width: availableWidth, height: 160)
            .environment(\.dynamicTypeSize, typeSize)
    }
}

private struct StatusSwitcherSizingFixture: View {
    let selection: TaskBucket
    let measure: (CGFloat) -> Void

    var body: some View {
        TaskStatusSwitcher(selection: selection, select: { _ in })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measure($0) }
            .frame(width: 360, height: 100)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.dynamicTypeSize, .large)
            .transaction { $0.disablesAnimations = true }
    }
}

private struct ColdShellFixture: View {
    let store: CommaStore
    let navigation: AppNavigation

    var body: some View {
        Group {
            if store.initialized {
                AppShellView(store: store, activity: TaskActivityCoordinator(), navigation: navigation)
                    .transition(.opacity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CommaTheme.bgPrimary.ignoresSafeArea())
            }
        }
        .animation(CommaMotion.stageExit, value: store.initialized)
    }
}
