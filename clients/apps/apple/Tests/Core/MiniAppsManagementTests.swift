import CommaCore
import SwiftUI
import WebKit
import XCTest
@testable import Comma

/// Native projections and actions use the same named Core calls as Mac and web.
@MainActor
final class MiniAppsManagementTests: XCTestCase {
    nonisolated private static func app(_ id: String = "a1", workspace: String = "w1", live: Int = 1) -> [String: Any] {
        ["id": id, "workspace_id": workspace, "name": "Reading tracker", "description": "Keep a reading list and summarize your notes.",
         "icon_url": "/v1/comma/apps/\(id)/icon?v=\(live)", "cover_url": "/v1/comma/apps/\(id)/cover?v=\(live)", "screenshot_urls": ["/v1/comma/apps/\(id)/screenshots/0?v=\(live)"],
         "status": "active", "visibility": "private", "live_version": live, "installed": workspace != "w1", "author": ["name": "Alex"]]
    }

    nonisolated private static func detail(workspace: String = "w1") -> [String: Any] {
        ["status": "ready", "app": app(workspace: workspace), "versions": [
            ["number": 3, "state": "uploading", "live": false],
            ["number": 2, "state": "ready", "live": false, "conversation_id": "build", "commit": "abcdef1234", "notes": "Add reading goals"],
            ["number": 1, "state": "ready", "live": true, "conversation_id": "old-build"],
        ]]
    }

    nonisolated private static func review(_ version: Int = 7) -> [String: Any] {
        ["revision": version, "state": ["conversation": ["id": "build", "kind": "agent_task", "status": "ready_for_review", "review_version": version]]]
    }

    func testCoverVariableBlurKeepsTopDetailAndReducesBottomDetail() async throws {
        let width = 320, height = 240
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let v: UInt8 = (x / 4).isMultiple(of: 2) ? 0 : 255
                let offset = (y * width + x) * 4
                pixels[offset] = v; pixels[offset + 1] = v; pixels[offset + 2] = v
            }
        }
        let source = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let processed = await MiniAppCoverProcessor.shared.render(source, size: CGSize(width: width, height: height), scale: 1)
        let output = try XCTUnwrap(processed)
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(output.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func variation(_ y: Int) -> Double {
            let values = (40 ..< 280).map { Double(result[(y * width + $0) * 4]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.map { abs($0 - mean) }.reduce(0, +) / Double(values.count)
        }
        // Raster rows are read from the top of the CGImage.
        XCTAssertGreaterThan(variation(25), 80, "The top of the cover remains sharp")
        XCTAssertGreaterThan(variation(120), 80, "The middle of the cover also remains sharp")
        XCTAssertLessThan(variation(210), variation(25) * 0.35, "Actual image detail is blurred progressively at the bottom")
    }

    func testReturningRetainsIndependentAppsAndTheSameExecutionWithoutReopening() async throws {
        let harness = try StoreHarness()
        await harness.start()
        defer { harness.store.closeMiniApps() }
        harness.core.on("miniApps.session.open") { params in
            ["session": "session-" + (params["app"] as? String ?? ""), "app": Self.app(params["app"] as? String ?? "a1"), "version": 2]
        }
        let firstTarget = MiniAppTarget(workspaceID: "w1", appID: "a1", version: 2)
        let first = MiniAppSession(core: harness.core, target: firstTarget)
        let firstRuntime = RetainedMiniAppProbe()
        harness.store.retainMiniApp(first, target: firstTarget)
        await first.open(firstTarget); first.approve(); first.runtime = firstRuntime; first.started(); first.suspend()
        let otherTarget = MiniAppTarget(workspaceID: "w1", appID: "other")
        let other = MiniAppSession(core: harness.core, target: otherTarget)
        let otherRuntime = RetainedMiniAppProbe()
        harness.store.retainMiniApp(other, target: otherTarget)
        await other.open(otherTarget); other.approve(); other.runtime = otherRuntime; other.started(); other.suspend()
        XCTAssertTrue(harness.store.canContinueMiniApp(workspaceID: "w1", appID: "a1"))
        XCTAssertTrue(harness.store.canContinueMiniApp(workspaceID: "w1", appID: "other"))
        let resumed = try XCTUnwrap(harness.store.retainedMiniApp(for: MiniAppTarget(workspaceID: "w1", appID: "a1")))
        XCTAssertTrue(resumed === first)
        await resumed.open(firstTarget); resumed.resume()
        XCTAssertTrue(resumed.runtime === firstRuntime)
        XCTAssertEqual(harness.core.calls("miniApps.session.open").count, 2, "Resume must not create a second cloud session")
        XCTAssertTrue(harness.core.calls("miniApps.session.close").isEmpty)
        XCTAssertNil(harness.store.retainedMiniApp(for: MiniAppTarget(workspaceID: "w1", appID: "a1", version: 3)))
        XCTAssertNil(harness.store.retainedMiniApp(for: MiniAppTarget(workspaceID: "w1", appID: "a1", shareToken: "another-access-path")))
        harness.store.closeMiniApp(first, target: firstTarget)
        XCTAssertEqual(firstRuntime.stops, 1)
        XCTAssertTrue(other.canContinue)
        harness.core.on("chat.resolveWorkspaceChat") { _ in
            ["status": "ready", "workspaceId": "w2", "groupId": "g2", "conversationId": "router-w2"]
        }
        await harness.store.chooseWorkspace(Workspace(id: "w2", groupID: "g2", name: "Other workspace"))
        XCTAssertEqual(otherRuntime.stops, 1)
        XCTAssertTrue(harness.store.miniAppSessions.isEmpty)
        let accountTarget = MiniAppTarget(workspaceID: "w2", appID: "a1")
        let accountSession = MiniAppSession(core: harness.core, target: accountTarget)
        let accountRuntime = RetainedMiniAppProbe()
        harness.store.retainMiniApp(accountSession, target: accountTarget)
        await accountSession.open(accountTarget); accountSession.approve(); accountSession.runtime = accountRuntime
        harness.store.clearProduct()
        XCTAssertEqual(accountRuntime.stops, 1)
        XCTAssertTrue(harness.store.miniAppSessions.isEmpty)
    }

    func testMemoryPressureReleasesOnlySuspendedExecutionsAndBackgroundDoesNotCloseThem() async throws {
        let harness = try StoreHarness()
        await harness.start()
        defer { harness.store.closeMiniApps() }
        harness.core.on("miniApps.session.open") { _ in ["session": "screen", "app": Self.app(), "version": 1] }
        let target = MiniAppTarget(workspaceID: "w1", appID: "a1")
        let session = MiniAppSession(core: harness.core, target: target)
        let runtime = RetainedMiniAppProbe()
        harness.store.retainMiniApp(session, target: target)
        await session.open(target); session.approve(); session.runtime = runtime; session.started()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(runtime.stops, 0, "Memory pressure must not evict the visible app")
        harness.store.miniAppTarget = target
        harness.store.suspend()
        XCTAssertEqual(harness.store.miniAppTarget, target)
        XCTAssertTrue(session.isSuspended)
        XCTAssertEqual(runtime.stops, 0)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertEqual(runtime.stops, 1)
        XCTAssertFalse(harness.store.canContinueMiniApp(workspaceID: "w1", appID: "a1"))
        XCTAssertNotNil(session.failure)
        XCTAssertTrue(harness.store.miniAppSessions.isEmpty)
    }

    func testRunUsesTheOwnerPreviewBeforePublicationButKeepsInstallVersionSelection() throws {
        var app = Self.app()
        app.removeValue(forKey: "live_version")
        app["latest_version"] = 3
        XCTAssertEqual(try XCTUnwrap(MiniAppRecord(app as NSDictionary)).runningVersion, 3)
        app["installed"] = true
        XCTAssertNil(try XCTUnwrap(MiniAppRecord(app as NSDictionary)).runningVersion)
        app["live_version"] = 2
        app["install"] = ["pinned_version": 1]
        XCTAssertEqual(try XCTUnwrap(MiniAppRecord(app as NSDictionary)).runningVersion, 1)
    }

    func testTheAppListDoesNotReadEveryAppOrOpenAnyRuntime() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.core.serve("miniApps") { _ in ["status": "ready", "apps": [Self.app(), Self.app("shared", workspace: "other")]] }
        let model = MiniAppsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let following = Task { await model.followList() }
        defer { following.cancel() }
        await until { model.loaded }
        XCTAssertEqual(model.apps.map(\.id), ["a1", "shared"])
        XCTAssertTrue(model.apps[1].installed)
        XCTAssertTrue(harness.core.topics("miniApp").isEmpty)
        XCTAssertTrue(harness.core.calls("miniApps.session.open").isEmpty)
        XCTAssertTrue(harness.core.topics("chatView").allSatisfy { $0["conversation"] as? String == "router" })
    }

    func testPublicationKeepsThePreviewedVersionAndRefusesAChangedReview() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.core.serve("miniApp") { _ in Self.detail() }
        harness.core.serve("chatView") { _ in Self.review() }
        harness.core.on("miniApps.publish") { _ in Self.app(live: 2) }
        let model = MiniAppsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let detail = Task { await model.followApp("a1") }
        defer { detail.cancel() }
        await until { model.loaded }
        let version = try XCTUnwrap(model.versions.first { $0.number == 2 })
        XCTAssertNil(model.publication(for: version))
        let review = Task { await model.followReview(version.conversationID) }
        defer { review.cancel() }
        await until { model.review != nil }
        let publication = try XCTUnwrap(model.publication(for: version))
        XCTAssertNil(model.publication(for: model.versions[0]))
        let published = await model.publish(publication, visibility: "workspace")
        XCTAssertTrue(published)
        let params = try XCTUnwrap(harness.core.calls("miniApps.publish").last)
        XCTAssertEqual(params["version"] as? Int, 2)
        XCTAssertEqual(params["reviewVersion"] as? Int, 7)
        XCTAssertEqual(params["conversation"] as? String, "build")
        XCTAssertEqual(params["workspace"] as? String, "w1")
        XCTAssertEqual(params["group"] as? String, "g1")
        harness.core.publish("chatView", Self.review(8))
        await until { model.review?.object?.int("review_version") == 8 }
        let stale = await model.publish(publication, visibility: "workspace")
        XCTAssertFalse(stale)
        XCTAssertEqual(harness.core.calls("miniApps.publish").count, 1)
        harness.store.clearProduct()
        let oldWorkspace = await model.perform("miniApps.rollback", ["app": "a1", "version": 1])
        XCTAssertFalse(oldWorkspace)
        XCTAssertTrue(harness.core.calls("miniApps.rollback").isEmpty)
    }

    func testAnInstalledAppCannotPublishAndServerConflictsRemainVisible() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.core.serve("miniApp") { _ in Self.detail(workspace: "other") }
        let model = MiniAppsModel(store: harness.store, workspace: try XCTUnwrap(harness.store.workspace))
        let following = Task { await model.followApp("a1") }
        defer { following.cancel() }
        await until { model.loaded }
        XCTAssertFalse(model.owner)
        XCTAssertNil(model.publication(for: model.versions[1]))
        harness.core.on("miniApps.rollback") { _ in throw CoreError(code: "conflict", message: "The version changed.") }
        let changed = await model.perform("miniApps.rollback", ["app": "a1", "version": 1])
        XCTAssertFalse(changed)
        XCTAssertEqual(model.failure, "The version changed.")
    }

    func testAnAppOnlyMessageKeepsItsPreviewVersionInTheTimeline() throws {
        let value: NSDictionary = ["revision": 1, "state": ["status": "ready", "serverMessages": [
            ["messageId": "m", "role": "assistant", "actorType": "agent", "text": "", "parts": [
                ["kind": "mini-app", "appId": "a1", "appVersion": 2, "name": "Reading tracker", "summary": "A reading list", "conversationId": "build"],
            ]],
        ]]]
        let timeline = ChatViewReader().read(value).timeline
        guard case .message(_, let message) = try XCTUnwrap(timeline.first) else { return XCTFail("The app card was dropped") }
        XCTAssertEqual(message.miniApps.first?.version, 2)
        XCTAssertEqual(message.miniApps.first?.conversationID, "build")
        XCTAssertTrue(MessageExtras.hasContent(message))
    }

    func testNativeManagementScreensRender() async throws {
        let harness = try StoreHarness()
        await harness.start()
        defer { harness.store.closeMiniApps() }
        try MiniAppMediaFixture.serve(harness.core)
        harness.core.serve("miniApps") { _ in ["status": "ready", "apps": [Self.app()]] }
        harness.core.serve("miniApp") { _ in
            var detail = Self.detail()
            detail["versions"] = (detail["versions"] as? [[String: Any]])?.filter { $0["state"] as? String == "ready" }
            return detail
        }
        harness.core.serve("chatView") { _ in Self.review() }
        let workspace = try XCTUnwrap(harness.store.workspace)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        let model = MiniAppsModel(store: harness.store, workspace: workspace)
        let detail = Task { await model.followApp("a1") }
        defer { detail.cancel() }
        await until { model.loaded }
        let review = Task { await model.followReview("build") }
        defer { review.cancel() }
        await until { model.review != nil }
        let publication = try XCTUnwrap(model.publication(for: try XCTUnwrap(model.versions.first { $0.number == 2 })))
        let card = try XCTUnwrap(MiniAppCardValue(["appId": "a1", "appVersion": 2, "name": "Reading tracker",
                                                 "summary": "Keep a reading list and summarize your notes.", "conversationId": "build"]))
        let navigation = AppNavigation(tab: .apps)
        let screens: [(String, AnyView)] = [
            ("Apps main tab", AnyView(ShellTabs(store: harness.store, activity: TaskActivityCoordinator(), query: HomeTaskQuery())
                .environment(navigation).environment(InboxModel()))),
            ("Home task search", AnyView(VStack { HomeHeader(store: harness.store, openBriefing: {}, openSearch: {}); Spacer() }.background(CommaTheme.bgPrimary))),
            ("Mini Apps list", AnyView(MiniAppsView(store: harness.store, workspace: workspace).environment(navigation))),
            ("Mini App versions", AnyView(NavigationStack { MiniAppDetailView(store: harness.store, workspace: workspace, appID: "a1") })),
            ("Mini App publication", AnyView(MiniAppPublishView(model: model, publication: publication))),
            ("Mini App chat card", AnyView(VStack { MiniAppChatCard(app: card, open: {}).environment(\.inlineTaskStore, harness.store); Spacer() }.padding(GroupedSurface.margin).background(CommaTheme.bgPrimary))),
        ]
        for (name, view) in screens {
            if name == "Mini App versions" {
                harness.core.on("miniApps.session.open") { _ in ["session": "retained-screen", "app": Self.app(), "version": 1] }
                let target = MiniAppTarget(workspaceID: workspace.id, appID: "a1")
                let retained = MiniAppSession(core: harness.core, target: target)
                harness.store.retainMiniApp(retained, target: target)
                await retained.open(target); retained.approve(); retained.suspend()
            }
            let listReady = ["Apps main tab", "Mini Apps list"].contains(name) ? expectation(description: name + " loaded") : nil
            listReady?.assertForOverFulfill = false
            if let listReady {
                harness.core.serve("miniApps") { _ in
                    listReady.fulfill()
                    return ["status": "ready", "apps": [Self.app()]]
                }
            }
            let controller = UIHostingController(rootView: view)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            if let listReady { await fulfillment(of: [listReady], timeout: 3) }
            for _ in 0 ..< 3 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = name + (name == "Mini App versions" ? " Continue" : ""); attachment.lifetime = .keepAlways
            add(attachment)
            if name == "Mini App versions", let scroll = firstScroll(controller.view),
               scroll.contentSize.height > scroll.bounds.height {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                controller.view.layoutIfNeeded()
                await attachScreen(window, named: "Mini App versions bottom")
            }
            controller.rootView = AnyView(EmptyView())
            controller.view.layoutIfNeeded()
        }
    }

    private func firstScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScroll).first
    }
    func testRestrictedRuntimeScreensRender() async throws {
        let harness = try StoreHarness()
        defer { harness.store.closeMiniApps() }
        await harness.start()
        let opened = expectation(description: "The runtime opened its Core session")
        harness.core.on("miniApps.session.open") { _ in
            opened.fulfill()
            return ["session": "screen-session", "app": Self.app(), "version": 2, "viewer": NSNull(),
             "capabilities": ["ai.chat"], "grants": ["ai.chat"], "storage": ["user"], "backend": false]
        }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:17px -apple-system;color:var(--comma-foreground);background:#efe5d0;padding:24px}li{padding:16px 0;border-bottom:1px solid var(--comma-border)}small{color:var(--comma-muted)}</style></head>
        <body><h1>Reading tracker</h1><p>Your cloud reading list</p><ul><li>The Little Prince</li><li>A Brief History of Time</li></ul><p id="capabilities"></p><small>Test app inside the restricted container</small><p><input placeholder="Reading notes" aria-label="Reading notes"></p>
        <script>document.getElementById('capabilities').textContent=comma.supports('files.pick')?'Files available':'Native capabilities unavailable';</script></body></html>
        """
        let encoded = Data(html.utf8).base64EncodedString()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let session = MiniAppSession(core: harness.core)
        let original = scene.windows.first(where: \.isKeyWindow)
        let navigation = AppNavigation(tab: .apps)
        harness.store.profileRead = true
        harness.store.tasksLoaded = true
        harness.core.serve("miniApps") { _ in ["status": "ready", "apps": [Self.app()]] }
        let shell = UIHostingController(rootView: AnyView(AppShellView(store: harness.store, activity: TaskActivityCoordinator(), navigation: navigation)))
        window.rootViewController = shell
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        let controller = UIHostingController(rootView: AnyView(MiniAppRunView(store: harness.store,
            target: MiniAppTarget(workspaceID: "w1", appID: "a1", version: 2), session: session)))
        controller.modalPresentationStyle = .fullScreen
        shell.present(controller, animated: false)
        defer { controller.dismiss(animated: false); window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        await fulfillment(of: [opened], timeout: 4)
        try await Task.sleep(for: .milliseconds(1200))
        await attachScreen(window, named: "Runtime cloud consent")
        let loaded = expectation(description: "The approved runtime requested its bundle")
        harness.core.on("miniApps.bundle") { _ in
            loaded.fulfill()
            return ["files": [["path": "index.html", "mime": "text/html", "data": ["$bytes": encoded]]]]
        }
        session.approve()
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0 ..< 50 {
            if session.ready || session.failure != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(session.ready, session.failure ?? "The restricted runtime did not render")
        for orientation in [UIInterfaceOrientationMask.portrait, .landscapeLeft] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            try await Task.sleep(for: .milliseconds(800))
            window.layoutIfNeeded()
            let web = try XCTUnwrap(findWebView(controller.view))
            let frame = web.convert(web.bounds, to: window)
            XCTAssertEqual(frame.minX, 0, accuracy: 1)
            XCTAssertEqual(frame.minY, 0, accuracy: 1)
            XCTAssertEqual(frame.width, window.bounds.width, accuracy: 1)
            XCTAssertEqual(frame.height, window.bounds.height, accuracy: 1)
            XCTAssertTrue(scene.statusBarManager?.isStatusBarHidden == true, "The run screen requests immersive status-bar visibility")
            await attachScreen(window, named: "Immersive runtime " + (orientation == .portrait ? "portrait" : "landscape"))
        }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(for: .milliseconds(800))
        await attachScreen(window, named: "Apps after suspending runtime")
        // Release retained WebKit while the fixture window still has a live hosting hierarchy.
        controller.rootView = AnyView(EmptyView())
        controller.view.layoutIfNeeded()
        harness.store.closeMiniApps()
        shell.rootView = AnyView(EmptyView())
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

    }

    private func findWebView(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap(findWebView).first
    }

    private func attachScreen(_ window: UIWindow, named name: String) async {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            for visible in window.windowScene?.windows ?? [window] where !visible.isHidden {
                visible.drawHierarchy(in: visible.convert(visible.bounds, to: window), afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

}

@MainActor private final class RetainedMiniAppProbe: MiniAppRuntimeHandle {
    var stops = 0
    func suspend() {}
    func resume() {}
    func stop() { stops += 1 }
}
