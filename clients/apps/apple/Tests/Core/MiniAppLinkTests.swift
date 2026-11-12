import CommaCore
import SwiftUI
import XCTest
@testable import Comma

@MainActor
final class MiniAppLinkTests: XCTestCase {
    private static let token = String(repeating: "b", count: 43)
    private static let origin = URL(string: "https://salix-staging.comma.surf")!
    private var url: URL { URL(string: "https://app-staging.comma.surf/a/" + Self.token)! }
    private var link: MiniAppSharedLink { MiniAppSharedLink(url: url, apiOrigin: Self.origin)! }

    nonisolated private static func app(installed: Bool = false) -> [String: Any] {
        ["id": "shared", "workspace_id": "owner", "icon_url": "/v1/comma/apps/shared/icon?v=2", "cover_url": "/v1/comma/apps/shared/cover?v=2", "screenshot_urls": ["/v1/comma/apps/shared/screenshots/0?v=2"], "name": "Reading tracker", "description": "A shared reading list.",
         "status": "active", "visibility": "link", "live_version": 2, "installed": installed,
         "install": ["pinned_version": 2], "author": ["name": "Alex"]]
    }

    func testShareURLsStayInTheirDeploymentAndDoNotSelectPrivateVersions() {
        XCTAssertEqual(MiniAppSharedLink(url: url, apiOrigin: Self.origin)?.token, Self.token)
        for value in ["https://evil.test/a/", "https://app.comma.surf/a/", "http://app-staging.comma.surf/a/",
                      "https://app-staging.comma.surf:443/a/", "https://user@app-staging.comma.surf/a/",
                      "https://app-staging.comma.surf/a//", "https://app-staging.comma.surf/a/%62"] {
            XCTAssertNil(MiniAppSharedLink(url: URL(string: value + Self.token)!, apiOrigin: Self.origin))
        }
        XCTAssertNil(MiniAppSharedLink(url: URL(string: "https://app-staging.comma.surf/a/short")!, apiOrigin: Self.origin))
    }

    func testAColdLinkWaitsForSignInButNeedsNoWorkspaceToOpen() {
        let pending = IncomingAppLink()
        pending.receive(url, accountID: nil)
        XCTAssertNil(pending.take(accountID: nil, hasWorkspace: false))
        pending.identityChanged(from: nil, to: "A")
        XCTAssertEqual(pending.take(accountID: "A", hasWorkspace: false), url)
        XCTAssertNil(pending.take(accountID: "A", hasWorkspace: false))
        pending.receive(url, accountID: "A")
        pending.identityChanged(from: "A", to: "B")
        XCTAssertNil(pending.take(accountID: "B", hasWorkspace: true))
        pending.receive(url, accountID: "B")
        pending.identityChanged(from: "B", to: nil)
        XCTAssertNil(pending.url)
    }

    func testWorkspaceRestorationPreservesTheIncomingSharedPage() async throws {
        let harness = try StoreHarness()
        harness.store.miniAppPresentation = .shared(link)
        await harness.start()
        guard case .shared(let kept) = harness.store.miniAppPresentation else {
            return XCTFail("Restoring the default workspace discarded the incoming shared app")
        }
        XCTAssertEqual(kept, link)
    }

    func testSharedAndInstalledRunsUseDifferentAccessPathsAndKeepTheIOSRestriction() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.core.on("miniApps.session.open") { _ in ["session": "mas-link", "app": Self.app(), "version": 2,
                                                         "capabilities": ["ai.chat"], "viewer": NSNull()] }
        let session = MiniAppSession(core: harness.core)
        await session.open(MiniAppTarget(workspaceID: "w1", appID: "shared", version: 99, shareToken: Self.token))
        let request = try XCTUnwrap(harness.core.calls("miniApps.session.open").first)
        XCTAssertEqual((request["via"] as? [String: String])?["token"], Self.token)
        XCTAssertNil(request["version"])
        XCTAssertEqual(request["platform"] as? String, "ios")
        XCTAssertTrue(harness.core.calls("miniApps.bundle").isEmpty)
        session.approve()
        let denied = await session.invoke(["op": "files.pick", "args": [:]])
        XCTAssertEqual((denied["error"] as? [String: String])?["code"], "unsupported")
        session.stop()
    }

    func testInstallingPinsOnlyAfterConfirmationAndUninstallRemovesOnlyTheChosenInstallation() async throws {
        let harness = try StoreHarness()
        await harness.start()
        let workspace = try XCTUnwrap(harness.store.workspace)
        let destination = Workspace(id: "selected", groupID: "selected-group", name: "Selected")
        harness.store.workspaces = [workspace, destination]
        harness.core.on("miniApps.link.resolve") { _ in ["app": Self.app(), "version": 2] }
        harness.core.serve("miniApp") { _ in ["status": "missing"] }
        harness.core.on("miniApps.install") { _ in Self.app(installed: true) }
        harness.core.on("miniApps.uninstall") { _ in nil }
        let model = MiniAppSharedModel(store: harness.store, link: link)
        model.selectWorkspace(destination.id)
        await model.resolve()
        let watching = Task { await model.followInstallation() }
        defer { watching.cancel() }
        await until { model.installationKnown }
        XCTAssertTrue(harness.core.calls("miniApps.install").isEmpty)
        XCTAssertEqual(model.sharedTarget()?.shareToken, Self.token)
        model.followLive = false
        let installed = await model.install()
        XCTAssertTrue(installed)
        let added = try XCTUnwrap(harness.core.calls("miniApps.install").first)
        XCTAssertEqual(added["workspace"] as? String, destination.id)
        XCTAssertEqual(added["pinnedVersion"] as? Int, 2)
        XCTAssertNil(model.installedTarget()?.shareToken)
        XCTAssertNil(model.installedTarget()?.version)
        let removed = await model.uninstall()
        XCTAssertTrue(removed)
        let deletion = try XCTUnwrap(harness.core.calls("miniApps.uninstall").first)
        XCTAssertEqual(deletion["workspace"] as? String, destination.id)
        XCTAssertEqual(deletion["app"] as? String, "shared")
        XCTAssertNil(model.installation)
        XCTAssertEqual(harness.store.workspace?.id, workspace.id)
        harness.store.session = nil
        let afterLogout = await model.install()
        XCTAssertFalse(afterLogout)
    }

    func testAnExistingInstallationIsNotReconfiguredByOpeningItsLink() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.store.workspaces = [try XCTUnwrap(harness.store.workspace)]
        harness.core.on("miniApps.link.resolve") { _ in ["app": Self.app(), "version": 2] }
        harness.core.serve("miniApp") { _ in
            var installed = Self.app(installed: true)
            installed["live_version"] = 3
            return ["status": "ready", "app": installed]
        }
        let model = MiniAppSharedModel(store: harness.store, link: link)
        await model.resolve()
        let watching = Task { await model.followInstallation() }
        defer { watching.cancel() }
        await until { model.installationKnown }
        XCTAssertEqual(model.installation?.pinnedVersion, 2)
        XCTAssertEqual(model.installation?.liveVersion, 3)
        XCTAssertEqual(model.installation?.runningVersion, 2)
        XCTAssertNil(model.installedTarget()?.version)
        XCTAssertFalse(model.canInstall)
        let installed = await model.install()
        XCTAssertFalse(installed)
        XCTAssertTrue(harness.core.calls("miniApps.install").isEmpty)
    }

    func testARevokedLinkShowsAnUnavailableStateWithoutRetainingAppMetadata() async throws {
        let harness = try StoreHarness()
        await harness.start()
        harness.core.on("miniApps.link.resolve") { _ in throw CoreError(code: "not_found", message: "not found", status: 404) }
        let model = MiniAppSharedModel(store: harness.store, link: link)
        await model.resolve()
        XCTAssertNil(model.app)
        XCTAssertNil(model.sharedTarget())
        XCTAssertNotNil(model.failure)
        XCTAssertFalse(model.failure?.contains(Self.token) == true)
    }

    func testSharedAppScreensRender() async throws {
        let harness = try StoreHarness()
        await harness.start()
        defer { harness.store.closeMiniApps() }
        try MiniAppMediaFixture.serve(harness.core)
        harness.store.workspaces = [Workspace(id: "w1", groupID: "g1", name: "Reading club")]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        for state in ["Install shared app", "Already installed", "Revoked link", "Continue shared app"] {
            harness.store.closeMiniApps()
            if state == "Continue shared app" {
                harness.core.on("miniApps.session.open") { _ in ["session": "retained-share", "app": Self.app(), "version": 2] }
                let target = MiniAppTarget(workspaceID: "w1", appID: "shared", shareToken: Self.token)
                let retained = MiniAppSession(core: harness.core, target: target)
                harness.store.retainMiniApp(retained, target: target)
                await retained.open(target); retained.approve(); retained.suspend()
            }
            let resolved = expectation(description: state)
            resolved.assertForOverFulfill = false
            harness.core.on("miniApps.link.resolve") { _ in
                resolved.fulfill()
                if state == "Revoked link" { throw CoreError(code: "not_found", message: "not found", status: 404) }
                return ["app": Self.app(), "version": 2]
            }
            harness.core.serve("miniApp") { _ in
                state == "Already installed" ? ["status": "ready", "app": Self.app(installed: true)] : ["status": "missing"]
            }
            let controller = UIHostingController(rootView: MiniAppSharedView(store: harness.store, link: link))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            await fulfillment(of: [resolved], timeout: 3)
            for _ in 0 ..< 5 { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = state; attachment.lifetime = .keepAlways
            add(attachment)
            window.rootViewController = nil
        }
    }

}
