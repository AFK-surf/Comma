import XCTest
import CommaCore
@testable import CommaWatch

@MainActor
final class WatchCallTests: XCTestCase {
    func testComplicationPresentsBeforeContextAndCancelPreventsDelayedStart() async throws {
        let store = try store()
        store.workspace = nil
        let call = WatchCallController(store: store, microphonePermission: {
            XCTFail("A cancelled launch must not request the microphone")
            return false
        })
        call.presentPendingCall()
        XCTAssertTrue(call.presented)
        XCTAssertEqual(call.phase, .preparing)
        XCTAssertTrue(call.waitingForContext)
        call.hangUp()
        await call.startPendingCall()
        XCTAssertEqual(call.phase, .ended)
        XCTAssertFalse(call.waitingForContext)
    }

    func testPendingComplicationStartsOnceWhenContextIsReady() async throws {
        let permission = Permission()
        let call = WatchCallController(store: try store(), microphonePermission: { await permission.request() })
        call.presentPendingCall()
        let start = Task { await call.startPendingCall() }
        await permission.wait()
        call.presentPendingCall()
        await call.startPendingCall()
        XCTAssertEqual(permission.requests, 1)
        permission.complete(false)
        await start.value
        XCTAssertTrue(call.microphoneDenied)
    }

    func testMissingWorkspaceFailsWithoutRequestingMicrophone() async throws {
        let store = try store()
        store.workspace = nil
        let call = WatchCallController(store: store, microphonePermission: {
            XCTFail("No microphone without a Workspace")
            return false
        })
        await call.start()
        XCTAssertEqual(call.result, .unavailable)
        XCTAssertEqual(call.phase, .failed)
    }

    func testDeniedMicrophoneShowsRetryWithoutStartingCall() async throws {
        let call = WatchCallController(store: try store(), microphonePermission: { false })
        await call.start()
        XCTAssertEqual(call.phase, .failed)
        XCTAssertTrue(call.microphoneDenied)
        XCTAssertTrue(call.presented)
    }

    func testRepeatedEntryJoinsPendingStartAndHangupFencesPermissionCompletion() async throws {
        let permission = Permission()
        let call = WatchCallController(store: try store(), microphonePermission: { await permission.request() })
        let start = Task { await call.start() }
        await permission.wait()
        await call.start()
        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(call.phase, .preparing)
        call.hangUp()
        permission.complete(true)
        await start.value
        XCTAssertEqual(call.phase, .ended)
        XCTAssertEqual(call.result, .ended)
    }

    func testAccountBoundaryCancelsPendingPermissionWithoutReopeningCall() async throws {
        let permission = Permission()
        let call = WatchCallController(store: try store(), microphonePermission: { await permission.request() })
        let start = Task { await call.start() }
        await permission.wait()
        call.invalidate()
        permission.complete(true)
        await start.value
        XCTAssertFalse(call.presented)
        XCTAssertFalse(call.phase.isLive)
    }

    private func store() throws -> CommaStore {
        let configuration = AppConfiguration(baseURL: URL(string: "https://watch-call.test")!, credentialService: "WatchCallTests")
        let store = CommaStore(configuration: configuration, client: try configuration.makeClient())
        store.session = CommaSession(id: "session", expiresAt: 9_999_999_999,
                                    user: CommaUser(id: "user", email: "watch@example.test"))
        store.workspace = try JSONDecoder().decode(Workspace.self,
            from: Data(#"{"id":"workspace","group_id":"group","name":"Workspace"}"#.utf8))
        return store
    }
}

@MainActor
private final class Permission {
    var requests = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
    }
    func wait() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func complete(_ value: Bool) { continuation?.resume(returning: value); continuation = nil }
}
