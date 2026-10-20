import Combine
import XCTest
import Foundation
import CommaCore
import UserNotifications
@testable import Comma

@MainActor final class PhoneNotificationTests: XCTestCase {
    func testPushEnvironmentUsesInfoContractAndRejectsUnknownRatherThanSandboxFallback() throws {
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "development"), .sandbox)
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "sandbox"), .sandbox)
        XCTAssertEqual(try AppConfiguration.pushEnvironment(value: "production"), .production)
        XCTAssertThrowsError(try AppConfiguration.pushEnvironment(value: nil))
        XCTAssertThrowsError(try AppConfiguration.pushEnvironment(value: "typo"))
    }

    func testQuietPresentationRequiresProvisionalOrVerifiedNotificationCenterOnly() {
        let normal = PhoneNotificationSystem.permission(authorization: .authorized, alert: .enabled, lockScreen: .enabled, center: .enabled)
        XCTAssertEqual(normal.authorization, .allowed)
        XCTAssertFalse(normal.quiet, "Muted sounds or Focus are not inputs to quiet classification")
        let centerOnly = PhoneNotificationSystem.permission(authorization: .authorized, alert: .disabled, lockScreen: .disabled, center: .enabled)
        XCTAssertTrue(centerOnly.quiet)
        let lockScreen = PhoneNotificationSystem.permission(authorization: .authorized, alert: .disabled, lockScreen: .enabled, center: .enabled)
        XCTAssertFalse(lockScreen.quiet)
        let provisional = PhoneNotificationSystem.permission(authorization: .provisional, alert: .disabled, lockScreen: .disabled, center: .enabled)
        XCTAssertTrue(provisional.quiet)
        let denied = PhoneNotificationSystem.permission(authorization: .denied, alert: .disabled, lockScreen: .disabled, center: .disabled)
        XCTAssertEqual(denied.authorization, .denied)
    }

    /// The root shell observes the coordinator, and @Published announces every assignment: repeats must not.
    func testActivityCoordinatorAnnouncesOnlyRealChanges() {
        let suite = "PhoneNotificationTests." + UUID().uuidString
        let coordinator = TaskActivityCoordinator(startToken: { nil }, preferences: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var announcements = 0
        let observation = coordinator.objectWillChange.sink { announcements += 1 }
        defer { observation.cancel() }
        coordinator.reportRefreshFailure()
        coordinator.reportRefreshFailure()
        XCTAssertEqual(announcements, 1)
    }

    func testTokenAcquisitionTimeoutSettlesAndAnotherExplicitAttemptCanRetry() async {
        var acquisitions = 0
        let system = PhoneNotificationSystem(acquisitionTimeout: .milliseconds(1), acquire: { acquisitions += 1 })
        for _ in 0..<2 {
            do { _ = try await system.deviceToken(); XCTFail("Missing APNs callback must time out") }
            catch { XCTAssertEqual(error as? CommaError, .transport) }
        }
        XCTAssertEqual(acquisitions, 2)
    }
}

extension PhoneNotificationTests {
    func testBadgeSettingIsIndependentOfBannerAuthorization() {
        let permission = PhoneNotificationSystem.permission(authorization: .authorized, alert: .enabled,
            lockScreen: .enabled, center: .enabled, badge: .disabled)
        XCTAssertEqual(permission.authorization, .allowed)
        XCTAssertFalse(permission.badgeAllowed)
        XCTAssertTrue(PhoneNotificationSystem.permission(authorization: .authorized, alert: .disabled,
            lockScreen: .disabled, center: .enabled, badge: .enabled).badgeAllowed)
    }

    func testAggregateActivityWireStateHasTwoIndividuallyRoutableTasksAndSurvivesNewestRemoval() throws {
        let attributes = TaskActivityAttributes(accountID: "account", workspaceID: "workspace", groupID: "group")
        let newer = TaskActivityAttributes.TaskState(id: "desktop", title: "Desktop work", status: "in_progress", updatedAtEpochSeconds: 200)
        let older = TaskActivityAttributes.TaskState(id: "wechat", title: "WeChat review", status: "escalated", updatedAtEpochSeconds: 100)
        let projection = TaskActivityProjection(workspaceID: "workspace", groupID: "group", tasks: [newer, older])
        let decoded = try JSONDecoder().decode(TaskActivityAttributes.ContentState.self, from: JSONEncoder().encode(projection.contentState))
        XCTAssertEqual(decoded.tasks.map(\.id), ["desktop", "wechat"])
        XCTAssertTrue(decoded.needsAttention)
        XCTAssertEqual(decoded.updatedAtEpochSeconds, 200)
        let next = TaskActivityProjection(workspaceID: "workspace", groupID: "group", tasks: [older])
        XCTAssertEqual(next.contentState.updatedAtEpochSeconds, 100)
        for task in decoded.tasks {
            let url = try XCTUnwrap(attributes.taskURL(id: task.id))
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "task", value: task.id)))
            XCTAssertTrue(query.contains(URLQueryItem(name: "group", value: "group")))
        }
    }

    func testRouterPayloadRoutesToHomeAndRejectsMissingAuthority() throws {
        let payload: [AnyHashable: Any] = ["type": "router_message", "session_id": "phone-session", "workspace_id": "w1",
            "group_id": "g1", "conversation_id": "home", "message_id": "m1"]
        let route = try XCTUnwrap(NativeNotificationRoute(payload))
        XCTAssertEqual(route.destination, .router(conversationID: "home", messageID: "m1"))
        var invalid = payload
        invalid.removeValue(forKey: "session_id")
        XCTAssertNil(NativeNotificationRoute(invalid))
    }

    /// Old: a failed POST waited forever for another token event. New: foreground/Retry uses the cached token.
    func testPushToStartRetriesTheSameTokenAfterRegistrationFailure() async throws {
        let probe = ActivityRegistrationProbe()
        await probe.failNext()
        let channel = ActivityChannelProbe(sessionID: UUID().uuidString, accountID: "test-account", probe: probe)
        let coordinator = TaskActivityCoordinator(startToken: { Data([0x42]) })
        await coordinator.configure(accountID: channel.accountID, workspace: Workspace(id: "test-workspace", groupID: "test-group", name: ""),
                                    origin: "https://activity.test", automaticFollowing: true, channel: channel)
        await coordinator.settleRegistrations()
        XCTAssertNotNil(coordinator.availabilityMessage)
        await coordinator.retry()
        await coordinator.settleRegistrations()
        let events = await probe.events
        XCTAssertEqual(events.filter { $0 == "register:42" }.count, 2)
        XCTAssertNil(coordinator.availabilityMessage)
        await coordinator.setAutomaticFollowing(false)
        await coordinator.settleRegistrations()
        let retiredEvents = await probe.events
        XCTAssertTrue(retiredEvents.contains("retire:disabled"))
        await coordinator.stop()
        await coordinator.settleRegistrations()
    }
}

private actor ActivityRegistrationProbe {
    private var shouldFail = false
    private(set) var events: [String] = []
    func failNext() { shouldFail = true }
    func register(_ token: String, id: String) throws -> NotificationRegistration {
        events.append("register:" + token)
        if shouldFail { shouldFail = false; throw CommaError.transport }
        return try JSONDecoder().decode(NotificationRegistration.self, from: JSONSerialization.data(withJSONObject: ["id": id, "status": "active"]))
    }
    func retire(_ reason: ActivityRetirementReason) { events.append("retire:" + reason.rawValue) }
}
private struct ActivityChannelProbe: ActivityNotificationTransport {
    let sessionID: String
    let accountID: String
    let probe: ActivityRegistrationProbe
    func register(token: String, activityID: String?, registrationID: String) async throws -> NotificationRegistration { try await probe.register(token, id: registrationID) }
    func retire(id: String, reason: ActivityRetirementReason) async throws { await probe.retire(reason) }
}
