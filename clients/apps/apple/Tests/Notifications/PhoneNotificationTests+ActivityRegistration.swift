import XCTest
import Foundation
import CommaCore
import UserNotifications
@testable import Comma

// Durable Live Activity registration ledger: pending POSTs, failed retirements, session changes and stopped cohorts.
extension PhoneNotificationTests {
    func testStoppingWhileActivityPostIsPendingRetiresTheSameUUIDWithStoppedReason() async throws {
        let suite = "ActivityPendingTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let probe = DurableActivityProbe()
        await probe.pauseNextPost()
        let channel = DurableActivityChannel(sessionID: UUID().uuidString, probe: probe)
        let owner = ActivityRegistrationController(preferences: preferences)
        owner.configure(channel: channel, workspace: .init(id: "w", groupID: "g", name: ""),
                        origin: "https://ledger.test", enabled: true, restoredActivityIDs: [])
        owner.setLiveToken("test-live-token", activityID: "activity")
        await probe.waitForPost()
        owner.retireLive(reason: .stopped)
        await probe.releasePost()
        await owner.settle()
        let posts = await probe.postIDs
        let deletions = await probe.deletions
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(deletions.map(\.id), posts)
        XCTAssertEqual(deletions.map(\.reason), [.stopped])
        owner.retry(); await owner.settle()
        let remainingPosts = await probe.postIDs
        XCTAssertEqual(remainingPosts, posts)
    }

    func testFailedDisableDeletionSurvivesRestartUntilTheSameSessionAcknowledgesIt() async throws {
        let suite = "ActivityRetirementTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let probe = DurableActivityProbe()
        let channel = DurableActivityChannel(sessionID: UUID().uuidString, probe: probe)
        let workspace = Workspace(id: "w", groupID: "g", name: "")
        let owner = ActivityRegistrationController(preferences: preferences)
        owner.configure(channel: channel, workspace: workspace, origin: "https://ledger.test",
                        enabled: true, restoredActivityIDs: [])
        owner.setStartToken("test-start-token"); await owner.settle()
        await probe.failDeletes(status: 401)
        owner.setEnabled(false); await owner.settle()

        await probe.failDeletes(status: nil)
        let restarted = ActivityRegistrationController(preferences: preferences)
        restarted.configure(channel: channel, workspace: workspace, origin: "https://ledger.test",
                            enabled: false, restoredActivityIDs: [])
        await restarted.settle()
        let posts = await probe.postIDs
        let deletions = await probe.deletions
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(deletions.count, 2, "Current-session 401 cannot discard a failed disable")
        XCTAssertTrue(deletions.allSatisfy { $0.id == posts[0] && $0.reason == .disabled })
        let again = ActivityRegistrationController(preferences: preferences)
        again.configure(channel: channel, workspace: workspace, origin: "https://ledger.test",
                        enabled: false, restoredActivityIDs: [])
        await again.settle()
        let acknowledgedDeletes = await probe.deletions
        XCTAssertEqual(acknowledgedDeletes.count, 2)
    }

    func testRevokedOldSessionDoesNotBlockEnrollmentInTheNewSession() async throws {
        let suite = "ActivityAuthorityTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let probe = DurableActivityProbe()
        let old = DurableActivityChannel(sessionID: UUID().uuidString, probe: probe)
        let next = DurableActivityChannel(sessionID: UUID().uuidString, probe: probe)
        let owner = ActivityRegistrationController(preferences: preferences)
        let workspace = Workspace(id: "w", groupID: "g", name: "")
        owner.configure(channel: old, workspace: workspace, origin: "https://ledger.test",
                        enabled: true, restoredActivityIDs: [])
        owner.setStartToken("old-token"); await owner.settle()
        await probe.failDeletes(status: 401)
        owner.configure(channel: next, workspace: workspace, origin: "https://ledger.test",
                        enabled: true, restoredActivityIDs: [])
        owner.setStartToken("new-token"); await owner.settle()
        let sessions = await probe.postSessions
        XCTAssertEqual(sessions, [old.sessionID, next.sessionID])
        await probe.failDeletes(status: nil)
        owner.stop(reason: .authorityChanged); await owner.settle()
    }

    func testStoppedCohortSurvivesRestartAndDoesNotCreateAnotherLocalActivity() async throws {
        let suite = "ActivityDismissalTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let channel = DurableActivityChannel(sessionID: UUID().uuidString, probe: DurableActivityProbe())
        let workspace = Workspace(id: "w", groupID: "g", name: "")
        let prior = ActivityRegistrationController(preferences: preferences)
        prior.configure(channel: channel, workspace: workspace, origin: "https://ledger.test",
                        enabled: true, restoredActivityIDs: [])
        prior.setDismissedCohort(["desktop", "wechat"]); await prior.settle()
        let coordinator = TaskActivityCoordinator(startToken: { nil }, preferences: preferences)
        await coordinator.configure(accountID: channel.accountID, workspace: workspace, origin: "https://ledger.test",
                                    automaticFollowing: true, channel: channel)
        let projection = TaskActivityProjection(workspaceID: "w", groupID: "g", tasks: [
            .init(id: "desktop", title: "Working", status: "in_progress", updatedAtEpochSeconds: 100),
            .init(id: "wechat", title: "Review", status: "ready_for_review", updatedAtEpochSeconds: 90)
        ])
        await coordinator.apply(projection)
        XCTAssertTrue(coordinator.followedTaskIDs.isEmpty)
        XCTAssertNil(coordinator.availabilityMessage)
        await coordinator.stop(); await coordinator.settleRegistrations()
    }
}

private actor DurableActivityProbe {
    struct Deletion: Sendable { let id: String; let reason: ActivityRetirementReason }
    private(set) var postIDs: [String] = []
    private(set) var postSessions: [String] = []
    private(set) var deletions: [Deletion] = []
    private var pause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var deleteFailure: Int?
    func pauseNextPost() { pause = true }
    func failDeletes(status: Int?) { deleteFailure = status }
    func waitForPost() async {
        if paused != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releasePost() { paused?.resume(); paused = nil }
    func register(id: String, sessionID: String) async throws -> NotificationRegistration {
        postIDs.append(id); postSessions.append(sessionID)
        if pause {
            pause = false
            await withCheckedContinuation { paused = $0; waiter?.resume(); waiter = nil }
        }
        return try JSONDecoder().decode(NotificationRegistration.self, from: JSONSerialization.data(withJSONObject: ["id": id, "status": "active"]))
    }
    func retire(id: String, reason: ActivityRetirementReason) throws {
        deletions.append(.init(id: id, reason: reason))
        if let deleteFailure { throw CommaError.http(status: deleteFailure, code: "unauthorized", retryAfter: nil) }
    }
}

private struct DurableActivityChannel: ActivityNotificationTransport {
    let sessionID: String
    let accountID = "ledger-account"
    let probe: DurableActivityProbe
    func register(token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration {
        try await probe.register(id: registrationID, sessionID: sessionID)
    }
    func retire(id: String, reason: ActivityRetirementReason) async throws { try await probe.retire(id: id, reason: reason) }
}
