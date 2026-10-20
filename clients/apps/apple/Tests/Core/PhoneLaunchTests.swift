import Foundation
import UIKit
import XCTest
@testable import Comma

/// A launch without a scene (ActivityKit starting the app for push-to-start), on the client core the app carries and a
/// fake Comma API.
@MainActor
final class PhoneLaunchTests: XCTestCase {
    private var directory: URL?
    private var runtime: CoreRuntime?

    override func tearDown() async throws {
        await runtime?.core.closed()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The kept session is checked, the Workspace found and the Live Activity's push-to-start token registered for it,
    /// with no conversation stream opened and no badge touched; a notification tap waits for a scene.
    func testBackgroundLaunchRestoresTheSessionAndRegistersActivityWithoutAScene() async throws {
        let server = FakeServer()
        server.on("GET", "/v1/comma/auth/session", json: [
            "expires_at": 4_102_444_800, "session_id": "bootstrap-session",
            "user": ["email": "bootstrap@example.com", "id": "bootstrap-user", "status": "active"],
        ])
        server.on("POST", "/v1/comma/me/bootstrap", json: [
            "status": "ready", "workspace": ["id": "bootstrap-workspace", "group_id": "bootstrap-group", "name": "Background"],
        ])
        server.on("POST", "/v1/comma/groups/bootstrap-group/assistant-chat", json: [
            "id": "router-chat", "group_id": "bootstrap-group", "title": "Router", "status": "active", "kind": "user_chat",
        ])
        server.on("POST", "/v1/comma/notifications/push-to-start") { request in
            (200, ["id": request.body["registration_id"] as? String ?? "", "status": "active"])
        }
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: server.origin)
        custody.adoptEarlier(StoredBearer(token: "bootstrap-bearer", audience: custody.audience, sessionId: "bootstrap-session",
                                          userId: "bootstrap-user", email: "bootstrap@example.com",
                                          expiresAtEpochSeconds: 4_102_444_800))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        let downloads = directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let runtime = try CoreRuntime.make(custody: custody, dataDirectory: directory.appendingPathComponent("core"),
                                           downloadRoot: downloads, configuration: server.configuration)
        self.runtime = runtime
        let store = CommaStore(configuration: AppConfiguration(baseURL: URL(string: server.origin)!, credentialService: "PhoneLaunchTests"),
                               runtime: runtime, workspacePreferences: UserDefaults(suiteName: UUID().uuidString)!)
        store.automaticallyFollowTasks = true

        let activity = TaskActivityCoordinator(startToken: { Data(repeating: 0x42, count: 32) })
        var constructions = 0
        let delegate = PhoneAppDelegate(activity: activity, makeStore: {
            constructions += 1
            return store
        }, notificationSetup: { delegate, store in delegate.attach(store: store) },
        badgePermission: { XCTFail("A background launch must not synchronize ordinary badges"); return false },
        setBadge: { _ in XCTFail("A background launch must not acknowledge or reset a badge") })

        XCTAssertTrue(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        delegate.background()
        XCTAssertTrue(delegate.store === store, "The UIKit launch owns the store before any scene exists")
        async let first: Void = delegate.bootstrap()
        async let second: Void = delegate.bootstrap()
        await first
        await second
        delegate.launch(state: .background)
        await delegate.bootstrap()
        XCTAssertEqual(constructions, 1, "Scene and notification entry points join one launch")

        await until { store.workspace?.groupID == "bootstrap-group" }
        XCTAssertEqual(store.session?.id, "bootstrap-session")
        let registration = await server.first("POST", "/v1/comma/notifications/push-to-start")
        XCTAssertEqual(registration.authorization, "Bearer bootstrap-bearer")
        XCTAssertEqual(registration.body["group_id"] as? String, "bootstrap-group")
        XCTAssertEqual(registration.body["activity_schema"] as? String, "tasks_v1")
        XCTAssertNil(activity.availabilityMessage)

        let route = try XCTUnwrap(NativeNotificationRoute([
            "session_id": "bootstrap-session", "workspace_id": "bootstrap-workspace",
            "group_id": "bootstrap-group", "task_id": "background-task",
        ]))
        await delegate.receiveTap(route)
        XCTAssertNil(store.task, "An inactive notification tap waits for a foreground scene")
        XCTAssertEqual(store.router.pane?.isShown, false, "A background launch follows no conversation's stream")

        await activity.stop()
        await activity.settleRegistrations()
    }
}
