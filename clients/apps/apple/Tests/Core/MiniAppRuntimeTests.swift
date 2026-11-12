import SwiftUI
import CommaCore
import Foundation
import WebKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Comma

/// Real WebKit and Hermes, with an in-process API. No rendered UI drives business behavior.
@available(iOS 18.4, *)
@MainActor
final class MiniAppRuntimeTests: XCTestCase {
    private var runtime: CoreRuntime?
    private var directory: URL?
    private var host: MiniAppWebHost?
    private var fixtureApp: [String: Any] = [:]

    override func tearDown() async throws {
        host?.stop()
        host = nil
        await runtime?.core.closed()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testOnlyTheCurrentDeploymentsRunLinksSelectAnAppAndVersion() throws {
        let origin = URL(string: "https://salix-staging.comma.surf")!
        let target = try XCTUnwrap(MiniAppTarget(url: URL(string: "https://app-staging.comma.surf/#/apps/wsp/a1/run?version=3")!, apiOrigin: origin))
        XCTAssertEqual(target, MiniAppTarget(workspaceID: "wsp", appID: "a1", version: 3))
        for link in ["https://evil.test/#/apps/wsp/a1/run", "https://app.comma.surf/#/apps/wsp/a1/run",
                     "https://app-staging.comma.surf/#/apps/wsp/a1/run?version=bad",
                     "https://app-staging.comma.surf/#/apps/wsp/a%2F1/run"] {
            XCTAssertNil(MiniAppTarget(url: URL(string: link)!, apiOrigin: origin))
        }
    }

    private func start(_ server: FakeServer, html: String) async throws -> MiniAppSession {
        server.on("GET", "/v1/comma/auth/session", json: [
            "expires_at": 4_102_444_800, "session_id": "mini-session",
            "user": ["email": "mini@example.com", "id": "mini-user", "status": "active"],
        ])
        let app: [String: Any] = [
            "id": "a1", "slug": "abcd1234", "workspace_id": "wsp", "name": "Cloud app", "description": "Test",
            "icon_url": NSNull(), "repo": ["owner": "test", "name": "app"], "visibility": "private", "status": "active",
            "live_version": 2, "latest_version": 2, "author": ["name": "Test"],
            "capabilities": ["ai.chat", "web.search", "identity.basic", "files.pick", "clipboard.write"],
            "egress": [], "storage": ["app", "user", "device"], "has_backend": true, "secrets": [],
            "grants": ["ai.chat", "web.search", "identity.basic"], "installed": false, "install": NSNull(),
            "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-01T00:00:00Z",
        ]
        fixtureApp = app
        server.on("POST", "/v1/comma/apps/a1/open", json: [
            "app": app, "version": 2, "digest": "fixture", "guest": false,
            "viewer": ["id": "private-viewer", "name": "Private Name", "avatar_url": NSNull()],
        ])
        server.on("GET", "/v1/comma/workspaces/wsp/apps/a1/versions/2/bundle", json: Self.tar([
            "index.html": html,
            // Exercise several bridge chunks, including non-ASCII bytes, without loading another script.
            "large.txt": String(repeating: "字", count: 50_000),
        ]))
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "mini-secret", audience: custody.audience, sessionId: "mini-session",
                                          userId: "mini-user", email: "mini@example.com", expiresAtEpochSeconds: 4_102_444_800))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: directory.appendingPathComponent("downloads"), configuration: server.configuration)
        self.runtime = runtime
        _ = await runtime.core.first(["topic": "session"]) { value in SessionSnapshot(value).phase == "signed_in" ? true : nil }
        let session = MiniAppSession(core: runtime.core)
        await session.open(MiniAppTarget(workspaceID: "wsp", appID: "a1", version: 2))
        XCTAssertNil(session.failure)
        return session
    }

    func testSuspendedAppCannotPlayAudioWhileAnotherAppRuns() async throws {
        let server = FakeServer()
        let html = "<!doctype html><p>Audio app</p><script>globalThis.savedNote = 'Keep my note';</script>"
        let first = try await start(server, html: html)
        let core = try XCTUnwrap(runtime).core
        var secondApp = fixtureApp
        secondApp["id"] = "a2"
        server.on("POST", "/v1/comma/apps/a2/open", json: ["app": secondApp, "version": 2, "digest": "fixture", "guest": false,
            "viewer": ["id": "private-viewer", "name": "Private Name", "avatar_url": NSNull()]])
        server.on("GET", "/v1/comma/workspaces/wsp/apps/a2/versions/2/bundle", json: Self.tar(["index.html": html]))
        let second = MiniAppSession(core: core)
        await second.open(MiniAppTarget(workspaceID: "wsp", appID: "a2", version: 2))
        XCTAssertNil(second.failure)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        func load(_ session: MiniAppSession) async throws -> (MiniAppWebHost, WKFrameInfo) {
            session.approve()
            let host = try MiniAppWebHost(session: session, dark: false)
            session.runtime = host
            let frames = MiniAppFrameProbe()
            let world = WKContentWorld.world(name: "AudioTest")
            host.webView.configuration.userContentController.add(frames, contentWorld: world, name: "frame")
            host.webView.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.webkit.messageHandlers.frame.postMessage(null)", injectionTime: .atDocumentEnd,
                forMainFrameOnly: false, in: world))
            host.webView.frame = controller.view.bounds
            controller.view.addSubview(host.webView)
            host.load()
            let loaded = expectation(description: "The audio app loaded")
            let observation = Task { await until { session.ready || session.failure != nil }; loaded.fulfill() }
            defer { observation.cancel() }
            await fulfillment(of: [loaded], timeout: 10)
            XCTAssertTrue(session.ready, session.failure ?? "The audio app did not become ready")
            return (host, try XCTUnwrap(frames.frame))
        }
        let (a, frameA) = try await load(first)
        self.host = a
        let (b, frameB) = try await load(second)
        defer { second.stop() }
        let tone = """
        globalThis.audio = new AudioContext();
        const tone = audio.createOscillator(), gain = audio.createGain();
        gain.gain.value = 0.001; tone.connect(gain).connect(audio.destination); tone.start();
        void audio.resume(); return audio.state;
        """
        _ = try await a.webView.callAsyncJavaScript(tone, arguments: [:], in: frameA, contentWorld: .page)
        func expect(_ host: MiniAppWebHost, _ expected: WKMediaPlaybackState, file: StaticString = #filePath, line: UInt = #line) async throws {
            var actual = await host.webView.requestMediaPlaybackState()
            for _ in 0 ..< 20 where actual != expected {
                try await Task.sleep(for: .milliseconds(50))
                actual = await host.webView.requestMediaPlaybackState()
            }
            XCTAssertEqual(actual, expected, file: file, line: line)
        }
        try await expect(a, .playing)
        first.suspend()
        second.resume()
        _ = try await b.webView.callAsyncJavaScript(tone, arguments: [:], in: frameB, contentWorld: .page)
        try await expect(b, .playing)
        try await expect(a, .suspended)
        _ = try await a.webView.callAsyncJavaScript("void audio.resume(); return null;", arguments: [:], in: frameA, contentWorld: .page)
        try await expect(a, .suspended) // Background JavaScript cannot restart its sound.
        second.suspend()
        first.resume()
        try await expect(b, .suspended)
        try await expect(a, .playing)
        let note = try await a.webView.callAsyncJavaScript("return savedNote;", arguments: [:], in: frameA, contentWorld: .page)
        XCTAssertEqual(note as? String, "Keep my note")
        first.suspend(); first.resume(); first.suspend()
        try await expect(a, .suspended) // Rapid returns must leave the last lifecycle state in control.
    }

    func testPhotoImportRemovesMetadataAndLimitsImageDimensions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try (encoded as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary as String])
        for png in [false, true] {
            let asset = try MiniAppPhotoEncoding.file(url, png: png)
            let output = try XCTUnwrap(CGImageSourceCreateWithData(asset.data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [String: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
            XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth as String] as? Int), 2048)
            XCTAssertEqual(CGImageSourceGetType(output) as String?, png ? UTType.png.identifier : UTType.jpeg.identifier)
        }
    }

    func testPhotoSDKNeedsHostConfirmationAndReturnsArrayBuffers() async throws {
        let server = FakeServer()
        let proof = expectation(description: "The SDK received the selected bytes")
        server.on("POST", "/v1/comma/apps/a1/backend/photo-proof") { _ in
            proof.fulfill(); return (200, ["ok": true])
        }
        let session = try await start(server, html: """
        <!doctype html><script>
        (async () => {
          const files = await comma.files.pick({accept: ['image/png']});
          const f = files[0];
          await comma.backend.fetch('/photo-proof', {method:'POST', body:JSON.stringify({
            name:f.name,mime:f.mime,buffer:f.data instanceof ArrayBuffer,bytes:Array.from(new Uint8Array(f.data))
          })});
        })();
        </script>
        """)
        session.approve()
        let host = try MiniAppWebHost(session: session, dark: false)
        self.host = host; session.runtime = host; host.load()
        let waiting = expectation(description: "The SDK waits for the host photo sheet")
        let observation = Task { await until { session.photoRequest != nil }; waiting.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [waiting], timeout: 10)
        let request = try XCTUnwrap(session.photoRequest)
        XCTAssertTrue(request.png)
        XCTAssertTrue(server.requests("POST", "/v1/comma/apps/a1/backend/photo-proof").isEmpty)
        session.finishPhotoRequest(id: request.id, assets: [MiniAppPhotoAsset(data: Data([0, 127, 128, 255]), png: true)])
        await fulfillment(of: [proof], timeout: 10)
        let received = try XCTUnwrap(server.requests("POST", "/v1/comma/apps/a1/backend/photo-proof").first)
        XCTAssertEqual(received.body["name"] as? String, "photo-1.png")
        XCTAssertEqual(received.body["mime"] as? String, "image/png")
        XCTAssertEqual(received.body["buffer"] as? Bool, true)
        XCTAssertEqual(received.body["bytes"] as? [Int], [0, 127, 128, 255])
    }

    func testPhotoAuthorizationCannotOutliveItsForegroundPresentation() async throws {
        let server = FakeServer()
        let initial = try await start(server, html: "<!doctype html><p>Photo authorization</p>")
        initial.stop()
        let base = try XCTUnwrap(runtime).core
        for confirmed in [false, true] {
            let entered = expectation(description: "Core photo authorization is pending")
            let gate = PhotoCallGate(entered: entered)
            let core = DelayedPhotoCore(base: base, gate: gate, confirmed: confirmed)
            let session = MiniAppSession(core: core)
            await session.open(MiniAppTarget(workspaceID: "wsp", appID: "a1", version: 2))
            session.approve()
            var answer: [String: Any] = [:]
            let completed = expectation(description: "The stale photo request is rejected")
            let request = Task { answer = await session.invoke(["op": "files.pick", "args": [:]]); completed.fulfill() }
            defer { request.cancel(); session.stop(); Task { await gate.release() } }
            if confirmed {
                await until { session.photoRequest != nil }
                let selection = try XCTUnwrap(session.photoRequest)
                session.finishPhotoRequest(id: selection.id, assets: [MiniAppPhotoAsset(data: Data([1]), png: false)])
            }
            await fulfillment(of: [entered], timeout: 3)
            session.suspend(); session.resume()
            await gate.release()
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertNil(session.photoRequest)
            session.cancelPhotoRequest()
            await request.value
            XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, "unavailable")
        }
    }

    func testPhotoCancellationOnSuspendDoesNotDeliverToAContinuedApp() async throws {
        let server = FakeServer()
        let session = try await start(server, html: "<!doctype html><p>Photos</p>")
        session.approve()
        var answer: [String: Any] = [:]
        let picking = Task { answer = await session.invoke(["op": "files.pick", "args": [:], "confirmed": true]) }
        await until { session.photoRequest != nil }
        let stale = try XCTUnwrap(session.photoRequest)
        session.suspend(); session.resume()
        session.finishPhotoRequest(id: stale.id, assets: [MiniAppPhotoAsset(data: Data([1]), png: false)])
        await picking.value
        XCTAssertEqual((answer["error"] as? [String: Any])?["code"] as? String, "unavailable")
        XCTAssertNil(session.photoRequest)
        var cancelled: [String: Any] = [:]
        let again = Task { cancelled = await session.invoke(["op": "files.pick", "args": [:]]) }
        await until { session.photoRequest != nil }
        let current = try XCTUnwrap(session.photoRequest)
        XCTAssertNotEqual(current.id, stale.id)
        session.cancelPhotoRequest(id: stale.id)
        XCTAssertEqual(session.photoRequest?.id, current.id)
        session.cancelPhotoRequest(id: current.id)
        await again.value
        XCTAssertEqual(cancelled["ok"] as? Bool, true)
        XCTAssertEqual((cancelled["value"] as? [Any])?.count, 0)
        XCTAssertNil(session.photoRequest)
    }

    func testSharedInstallationAndRemovalReachTheAPIThroughHermes() async throws {
        let server = FakeServer()
        let initial = try await start(server, html: "<!doctype html><p>Shared app</p>")
        initial.stop()
        let runtime = try XCTUnwrap(runtime)
        let token = String(repeating: "b", count: 43)
        let link = try XCTUnwrap(MiniAppSharedLink(
            url: URL(string: "https://app-staging.comma.surf/a/" + token)!,
            apiOrigin: URL(string: "https://salix-staging.comma.surf")!))
        server.on("GET", "/v1/comma/apps/links/" + token, json: ["app": fixtureApp, "version": 2])
        var installed = fixtureApp
        installed["installed"] = true
        installed["install"] = ["pinned_version": 2, "grants": ["ai.chat"], "installed_at": "2026-10-01T00:00:00Z"]
        server.on("POST", "/v1/comma/workspaces/viewer/apps/install", json: installed)
        server.on("DELETE", "/v1/comma/workspaces/viewer/apps/a1/install", json: [:])
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!, credentialService: "CommaTests"), runtime: runtime)
        store.session = CommaSession(id: "mini-session", expiresAt: 4_102_444_800,
                                     user: CommaUser(id: "mini-user", email: "mini@example.com"))
        store.workspace = Workspace(id: "viewer", groupID: "viewer-group", name: "Viewer")
        store.workspaces = [try XCTUnwrap(store.workspace)]
        let model = MiniAppSharedModel(store: store, link: link)
        await model.resolve()
        XCTAssertNil(model.failure)
        let following = Task { await model.followInstallation() }
        defer { following.cancel() }
        await until { model.installationKnown }
        XCTAssertTrue(server.requests("POST", "/v1/comma/workspaces/viewer/apps/install").isEmpty)
        model.followLive = false
        let added = await model.install()
        XCTAssertTrue(added, model.failure ?? "Install failed")
        let request = try XCTUnwrap(server.requests("POST", "/v1/comma/workspaces/viewer/apps/install").first)
        XCTAssertEqual(request.authorization, "Bearer mini-secret")
        XCTAssertEqual(request.body["token"] as? String, token)
        XCTAssertEqual(request.body["pinned_version"] as? Int, 2)
        XCTAssertEqual(model.installation?.pinnedVersion, 2)
        let removed = await model.uninstall()
        XCTAssertTrue(removed)
        XCTAssertNil(model.installation)
        XCTAssertEqual(server.requests("DELETE", "/v1/comma/workspaces/viewer/apps/a1/install").count, 1)
        XCTAssertTrue(server.requests("DELETE", "/v1/comma/workspaces/wsp/apps/a1").isEmpty)
        let sharedSession = MiniAppSession(core: runtime.core)
        await sharedSession.open(try XCTUnwrap(model.sharedTarget()))
        XCTAssertNil(sharedSession.failure)
        sharedSession.approve()
        let denied = await sharedSession.invoke(["op": "calendar.events", "args": [:]])
        XCTAssertEqual((denied["error"] as? [String: Any])?["code"] as? String, "unsupported")
        sharedSession.stop()
    }

    func testWebKitUsesGrantedIdentityAndKeepsNativeAuthorityIsolated() async throws {
        let server = FakeServer()
        let proof = expectation(description: "The app called its backend through the Core")
        server.on("POST", "/v1/comma/apps/a1/ai/chat", json: ["message": ["role": "assistant", "content": "Cloud reply"]])
        server.on("POST", "/v1/comma/apps/a1/web/search", json: ["results": []])
        server.on("PUT", "/v1/comma/apps/a1/storage/user/note", json: ["key": "note", "value": "saved", "version": 1])
        server.on("GET", "/v1/comma/apps/a1/storage/user/note", json: ["key": "note", "value": "saved", "version": 1])
        server.on("POST", "/v1/comma/apps/a1/backend/bytes", json: Data([0, 127, 128, 255]))
        server.on("POST", "/v1/comma/apps/a1/backend/proof") { _ in proof.fulfill(); return (200, [:]) }
        let session = try await start(server, html: """
        <!doctype html><script>
        (async () => {
          const proof = {};
          try {
            proof.nativeBridge = typeof window.webkit?.messageHandlers?.miniApp;
            proof.background = getComputedStyle(document.documentElement).getPropertyValue('--comma-background');
            try { proof.viewerName = (await comma.viewer()).name; } catch (error) { proof.viewerCode = error.code; }
            proof.nativeSupported = comma.supports('clipboard.write');
            try { parent.document.body; proof.parent = true; } catch { proof.parent = false; }
            try { localStorage.getItem('x'); proof.localStorage = true; } catch { proof.localStorage = false; }
            try { await fetch('https://127.0.0.1:1/blocked'); proof.network = true; } catch { proof.network = false; }
            proof.chat = (await comma.ai.chat([{role: 'user', content: 'Hi'}])).content;
            proof.search = (await comma.web.search('weather')).length;
            await comma.storage.user.put('note', 'saved');
            proof.saved = (await comma.storage.user.get('note')).value;
            proof.bytes = Array.from(new Uint8Array(await (await comma.backend.fetch('/bytes')).arrayBuffer()));
          } catch (error) { proof.error = String(error); }
          await comma.backend.fetch('/proof', {method: 'POST', body: JSON.stringify(proof)});
        })();
        </script>
        """)
        let beforeConsent = await session.invoke(["op": "ai.chat", "args": [:]])
        XCTAssertEqual((beforeConsent["error"] as? [String: Any])?["code"] as? String, "denied")
        XCTAssertTrue(server.requests("POST", "/v1/comma/apps/a1/ai/chat").isEmpty)
        XCTAssertTrue(server.requests("GET", "/v1/comma/workspaces/wsp/apps/a1/versions/2/bundle").isEmpty)
        session.approve()
        let host = try MiniAppWebHost(session: session, dark: false)
        self.host = host
        let picker = MiniAppPickerProbe(host: host, denied: expectation(description: "The WebKit file picker was denied"))
        let frames = MiniAppFrameProbe()
        let testWorld = WKContentWorld.world(name: "MiniAppTest")
        host.webView.configuration.userContentController.add(frames, contentWorld: testWorld, name: "frame")
        host.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.frame.postMessage(null)", injectionTime: .atDocumentEnd,
            forMainFrameOnly: false, in: testWorld))
        host.load()
        await fulfillment(of: [proof], timeout: 20)
        XCTAssertNil(session.failure)
        let request = try XCTUnwrap(server.requests("POST", "/v1/comma/apps/a1/backend/proof").first)
        XCTAssertNil(request.body["error"])
        XCTAssertEqual(request.body["nativeBridge"] as? String, "undefined")
        XCTAssertFalse((request.body["background"] as? String ?? "").isEmpty)
        XCTAssertNil(request.body["viewerCode"])
        XCTAssertEqual(request.body["viewerName"] as? String, "Private Name")
        XCTAssertEqual(request.body["nativeSupported"] as? Bool, true)
        XCTAssertEqual(request.body["parent"] as? Bool, false)
        XCTAssertEqual(request.body["localStorage"] as? Bool, false)
        XCTAssertEqual(request.body["network"] as? Bool, false)
        XCTAssertEqual(request.body["chat"] as? String, "Cloud reply")
        XCTAssertEqual(request.body["search"] as? Int, 0)
        XCTAssertEqual(request.body["saved"] as? String, "saved")
        XCTAssertEqual(request.body["bytes"] as? [Int], [0, 127, 128, 255])
        XCTAssertEqual(request.authorization, "Bearer mini-secret")
        // Real WebKit supplies the frame and picker parameters. The probe forwards the native request to the host.
        host.webView.uiDelegate = picker
        let frame = try XCTUnwrap(frames.frame)
        let initialPadding = try await host.webView.callAsyncJavaScript(
            "const s = getComputedStyle(document.documentElement); return [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft];",
            arguments: [:], in: frame, contentWorld: .page)
        XCTAssertEqual(initialPadding as? [String], ["0px", "0px", "0px", "0px"],
                       "The host must not reserve viewport space for system safe areas or floating controls")
        _ = try await host.webView.callAsyncJavaScript(
            "const input = document.createElement('input'); input.type = 'file'; document.body.append(input); input.click(); return null;",
            arguments: [:], in: frame, contentWorld: .page)
        await fulfillment(of: [picker.denied], timeout: 3)
        host.webView.uiDelegate = host
        // An app cannot bypass the SDK by passing a native op directly to the broker.
        let native = await session.invoke(["op": "calendar.events", "args": [:], "confirmed": true])
        XCTAssertEqual((native["error"] as? [String: Any])?["code"] as? String, "unsupported")
        let cleared = expectation(description: "Closing removed the running document")
        let navigation = MiniAppClearingProbe(host: host, cleared: cleared)
        host.webView.navigationDelegate = navigation
        host.stop()
        await fulfillment(of: [cleared], timeout: 3)
        let empty = try await host.webView.callAsyncJavaScript("return document.querySelector('iframe') === null;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(empty as? Bool, true)
        let closed = await session.invoke(["op": "ai.chat", "args": [:]])
        XCTAssertEqual((closed["error"] as? [String: Any])?["code"] as? String, "denied")
    }

    func testClosingDiscardsACloudResponseThatArrivesLater() async throws {
        let server = FakeServer()
        let entered = expectation(description: "The cloud call reached the API")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        server.on("POST", "/v1/comma/apps/a1/ai/chat") { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, ["message": ["role": "assistant", "content": "Late reply"]])
        }
        let session = try await start(server, html: "<!doctype html>")
        session.approve()
        let pending = Task { CoreJSON(value: await session.invoke(["op": "ai.chat", "args": ["messages": [["role": "user", "content": "Hi"]]]])) }
        await fulfillment(of: [entered], timeout: 3)
        session.stop()
        release.signal()
        let answer = await pending.value.object
        XCTAssertEqual(answer?.object("error")?.string("code"), "unavailable")
        XCTAssertNil(answer?["value"])
        XCTAssertEqual(server.requests("POST", "/v1/comma/apps/a1/ai/chat").count, 1)
    }

    func testCloudResultCompletedAcrossBackgroundReachesTheContinuedApp() async throws {
        let server = FakeServer()
        let entered = expectation(description: "The cloud call reached the API")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        server.on("POST", "/v1/comma/apps/a1/ai/chat") { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (200, ["message": ["role": "assistant", "content": "Reply"]])
        }
        let session = try await start(server, html: "<!doctype html>")
        session.approve()
        let pending = Task { CoreJSON(value: await session.invoke(["op": "ai.chat", "args": ["messages": [["role": "user", "content": "Hi"]]]])) }
        await fulfillment(of: [entered], timeout: 3)
        session.suspend(); session.resume()
        release.signal()
        let answer = await pending.value.object
        XCTAssertEqual(answer?.bool("ok"), true, "\(String(describing: answer))")
        XCTAssertEqual(server.requests("POST", "/v1/comma/apps/a1/ai/chat").count, 1)
        session.stop()
    }

    private static func tar(_ files: [String: String]) -> Data {
        var result = Data()
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let body = Data(text.utf8)
            var header = Data(repeating: 0, count: 512)
            header.replaceSubrange(0 ..< name.utf8.count, with: name.utf8)
            let size = String(repeating: "0", count: 11 - String(body.count, radix: 8).count) + String(body.count, radix: 8)
            header.replaceSubrange(124 ..< 135, with: size.utf8)
            header[156] = 0x30
            header.replaceSubrange(257 ..< 262, with: "ustar".utf8)
            result.append(header)
            result.append(body)
            result.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }
}

@available(iOS 18.4, *)
@MainActor
private final class MiniAppFrameProbe: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if !message.frameInfo.isMainFrame { frame = message.frameInfo }
    }
}

@available(iOS 18.4, *)
@MainActor
private final class MiniAppPickerProbe: NSObject, WKUIDelegate {
    let host: MiniAppWebHost
    let denied: XCTestExpectation
    init(host: MiniAppWebHost, denied: XCTestExpectation) { self.host = host; self.denied = denied }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let delegate: any WKUIDelegate = host
        delegate.webView?(webView, runOpenPanelWith: parameters, initiatedByFrame: frame) { [denied] urls in
            XCTAssertNil(urls)
            completionHandler(urls)
            denied.fulfill()
        }
    }
}

@available(iOS 18.4, *)
@MainActor
private final class MiniAppClearingProbe: NSObject, WKNavigationDelegate {
    let host: MiniAppWebHost
    let cleared: XCTestExpectation
    init(host: MiniAppWebHost, cleared: XCTestExpectation) { self.host = host; self.cleared = cleared }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await host.webView(webView, decidePolicyFor: action)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { cleared.fulfill() }
}

private actor PhotoCallGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func pause() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class DelayedPhotoCore: CoreAPI, @unchecked Sendable {
    let base: any CoreAPI
    let gate: PhotoCallGate
    let confirmed: Bool
    init(base: any CoreAPI, gate: PhotoCallGate, confirmed: Bool) { self.base = base; self.gate = gate; self.confirmed = confirmed }
    nonisolated(nonsending) func call(_ name: String, _ params: [String: Any]) async throws -> CoreJSON {
        if name == "miniApps.invoke", params["op"] as? String == "files.pick", (params["confirmed"] as? Bool ?? false) == confirmed {
            await gate.pause()
        }
        return try await base.call(name, params)
    }
    func subscribe<T: Sendable>(_ topic: [String: Any], read: @escaping @Sendable (Any?) -> T) -> AsyncStream<TopicValue<T>> {
        base.subscribe(topic, read: read)
    }
}
