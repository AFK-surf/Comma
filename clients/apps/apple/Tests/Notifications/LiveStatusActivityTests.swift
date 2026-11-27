#if os(iOS)
// ActivityKit's legacy Activity references remain on MainActor.
@preconcurrency import ActivityKit
import CommaCore
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Comma

@MainActor
final class LiveStatusActivityTests: XCTestCase {
    func testContentStateDecodesFullMinimalAndNullBackendJSON() throws {
        let fullJSON = """
        {
          "category": "car",
          "status": "attention",
          "accent": "amber",
          "title": "沪A·D8821 司机已到达上车点",
          "subtitle": "请在静安嘉里中心南门上车",
          "compactLabel": "已到达",
          "etaEpochSeconds": 1800000180,
          "progress": 1.0,
          "stepCurrent": 3,
          "stepTotal": 4,
          "stepLabel": "已到达",
          "detailLeft": "张师傅 · 4.9★",
          "detailRight": "尾号 4821",
          "updatedAtEpochSeconds": 1800000000
        }
        """
        let full = try JSONDecoder().decode(LiveStatusAttributes.ContentState.self, from: Data(fullJSON.utf8))
        XCTAssertEqual(full.category, "car")
        XCTAssertEqual(full.status, "attention")
        XCTAssertTrue(full.needsAttention)
        XCTAssertFalse(full.isTerminal)
        XCTAssertEqual(full.compactLabel, "已到达")
        XCTAssertEqual(full.stepCurrent, 3)
        XCTAssertEqual(full.stepTotal, 4)
        XCTAssertEqual(full.detailRight, "尾号 4821")

        let roundTripped = try JSONDecoder().decode(LiveStatusAttributes.ContentState.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(roundTripped, full)

        // Minimal payload with omitted optionals
        let minimalJSON = """
        {
          "category": "progress",
          "status": "active",
          "accent": "auto",
          "title": "Deploying release v2.4",
          "updatedAtEpochSeconds": 1800000010
        }
        """
        let minimal = try JSONDecoder().decode(LiveStatusAttributes.ContentState.self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(minimal.title, "Deploying release v2.4")
        XCTAssertNil(minimal.subtitle)
        XCTAssertNil(minimal.compactLabel)
        XCTAssertNil(minimal.etaEpochSeconds)
        XCTAssertNil(minimal.progress)

        // Explicit JSON nulls for optional fields
        let nullsJSON = """
        {
          "category": "order",
          "status": "done",
          "accent": "auto",
          "title": "瑞幸咖啡 已出餐",
          "subtitle": null,
          "compactLabel": "A042",
          "etaEpochSeconds": null,
          "progress": null,
          "stepCurrent": null,
          "stepTotal": null,
          "stepLabel": null,
          "detailLeft": null,
          "detailRight": null,
          "updatedAtEpochSeconds": 1800000020
        }
        """
        let withNulls = try JSONDecoder().decode(LiveStatusAttributes.ContentState.self, from: Data(nullsJSON.utf8))
        XCTAssertTrue(withNulls.isTerminal)
        XCTAssertEqual(withNulls.compactLabel, "A042")
        XCTAssertNil(withNulls.subtitle)
        XCTAssertNil(withNulls.etaEpochSeconds)
    }

    func testDeepLinkURLBuilderAndParserRoundTrip() throws {
        let withConversation = LiveStatusAttributes(
            accountID: "u1", workspaceID: "w1", groupID: "g1",
            liveKey: "didi:order-123", conversationID: "task-42"
        )
        let url1 = try XCTUnwrap(withConversation.deepLinkURL)
        let parsed1 = try XCTUnwrap(LiveStatusDeepLink.parse(url: url1))
        XCTAssertEqual(parsed1, LiveStatusDeepLink(workspaceID: "w1", groupID: "g1", liveKey: "didi:order-123", conversationID: "task-42"))

        let withoutConversation = LiveStatusAttributes(
            accountID: "u1", workspaceID: "w1", groupID: "g1",
            liveKey: "flight:CA1501", conversationID: nil
        )
        let url2 = try XCTUnwrap(withoutConversation.deepLinkURL)
        let parsed2 = try XCTUnwrap(LiveStatusDeepLink.parse(url: url2))
        XCTAssertEqual(parsed2, LiveStatusDeepLink(workspaceID: "w1", groupID: "g1", liveKey: "flight:CA1501", conversationID: nil))

        // Invalid host or missing required params rejected
        XCTAssertNil(LiveStatusDeepLink.parse(url: URL(string: "comma://task?workspace=w1&group=g1&task=t1")!))
        XCTAssertNil(LiveStatusDeepLink.parse(url: URL(string: "comma://live-activity?workspace=w1&group=g1")!))
    }

    func testAttributesCodableSupportsStartedAtEpochSecondsPresentOmittedAndNull() throws {
        let withStarted = """
        {
          "accountID": "u1",
          "workspaceID": "w1",
          "groupID": "g1",
          "liveKey": "timer:pomodoro",
          "conversationID": "conv-1",
          "startedAtEpochSeconds": 1800000100
        }
        """
        let decodedFull = try JSONDecoder().decode(LiveStatusAttributes.self, from: Data(withStarted.utf8))
        XCTAssertEqual(decodedFull.startedAtEpochSeconds, 1_800_000_100)
        let roundTripped = try JSONDecoder().decode(LiveStatusAttributes.self, from: JSONEncoder().encode(decodedFull))
        XCTAssertEqual(roundTripped.startedAtEpochSeconds, 1_800_000_100)

        let omittedJSON = """
        {
          "accountID": "u1",
          "workspaceID": "w1",
          "groupID": "g1",
          "liveKey": "timer:pomodoro"
        }
        """
        let decodedOmitted = try JSONDecoder().decode(LiveStatusAttributes.self, from: Data(omittedJSON.utf8))
        XCTAssertNil(decodedOmitted.startedAtEpochSeconds)

        let nullJSON = """
        {
          "accountID": "u1",
          "workspaceID": "w1",
          "groupID": "g1",
          "liveKey": "timer:pomodoro",
          "startedAtEpochSeconds": null
        }
        """
        let decodedNull = try JSONDecoder().decode(LiveStatusAttributes.self, from: Data(nullJSON.utf8))
        XCTAssertNil(decodedNull.startedAtEpochSeconds)
    }

    func testDismissalTrackerSuppressesSameOrOlderInstanceAndReleasesRestartedInstance() {
        var tracker = LiveStatusDismissalTracker()
        tracker.recordDismissal(liveKey: "timer:pomodoro", startedAt: 1_000, nowEpochSeconds: 1_050)

        // Same instance, older instance, or missing startedAt remain suppressed
        XCTAssertTrue(tracker.shouldSuppress(liveKey: "timer:pomodoro", startedAt: 1_000))
        XCTAssertTrue(tracker.shouldSuppress(liveKey: "timer:pomodoro", startedAt: 999))
        XCTAssertTrue(tracker.shouldSuppress(liveKey: "timer:pomodoro", startedAt: nil))
        XCTAssertEqual(tracker.instances["timer:pomodoro"], 1_000)

        // Unrelated key is never suppressed
        XCTAssertFalse(tracker.shouldSuppress(liveKey: "order:luckin", startedAt: 900))

        // Restarted server instance with newer startedAt > dismissedAt is allowed and clears suppression
        XCTAssertFalse(tracker.shouldSuppress(liveKey: "timer:pomodoro", startedAt: 1_001))
        XCTAssertNil(tracker.instances["timer:pomodoro"])

        // Prune removes keys absent from active items or superseded by a newer startedAt
        tracker.recordDismissal(liveKey: "a", startedAt: 100, nowEpochSeconds: 110)
        tracker.recordDismissal(liveKey: "b", startedAt: 200, nowEpochSeconds: 210)
        tracker.recordDismissal(liveKey: "c", startedAt: nil, nowEpochSeconds: 300)
        tracker.prune(activeStartedAtByKey: ["a": 100, "b": 250])
        XCTAssertEqual(tracker.instances, ["a": 100])
    }

    func testContentStateRelevanceScoreMatchesBackendPriorityOrdering() {
        let nowEpoch = 1_800_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(nowEpoch))

        let attentionImminent = LiveStatusAttributes.ContentState(
            category: "car", status: "attention", title: "司机已到达",
            etaEpochSeconds: nowEpoch + 1, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let attention28Min = LiveStatusAttributes.ContentState(
            category: "flight", status: "attention", title: "开始登机",
            etaEpochSeconds: nowEpoch + 28 * 60, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let attentionNoETA = LiveStatusAttributes.ContentState(
            category: "car", status: "attention", title: "请确认上车",
            etaEpochSeconds: nil, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let activeDelivery12Min = LiveStatusAttributes.ContentState(
            category: "delivery", status: "active", title: "外卖配送中",
            etaEpochSeconds: nowEpoch + 12 * 60, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let activeFlight28Min = LiveStatusAttributes.ContentState(
            category: "flight", status: "active", title: "CA1501 登机中",
            etaEpochSeconds: nowEpoch + 28 * 60, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let activeNoETA = LiveStatusAttributes.ContentState(
            category: "progress", status: "active", title: "构建发布中",
            etaEpochSeconds: nil, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)
        let terminalDone = LiveStatusAttributes.ContentState(
            category: "order", status: "done", title: "已出餐",
            etaEpochSeconds: nowEpoch + 60, updatedAtEpochSeconds: nowEpoch
        ).relevanceScore(now: now)

        XCTAssertEqual(attentionImminent, 95.0, accuracy: 0.001)
        XCTAssertEqual(attention28Min, 92.7, accuracy: 0.001)
        XCTAssertEqual(attentionNoETA, 90.0, accuracy: 0.001)
        XCTAssertEqual(activeDelivery12Min, 81.0, accuracy: 0.001)
        XCTAssertEqual(activeFlight28Min, 75.7, accuracy: 0.001)
        XCTAssertEqual(activeNoETA, 40.0, accuracy: 0.001)
        XCTAssertEqual(terminalDone, 10.0, accuracy: 0.001)

        // Live voice call (100.0) > attention (short ETA) > attention (no ETA) > active (12m) > active (28m) > active (no ETA) > terminal
        XCTAssertGreaterThan(100.0, attentionImminent)
        XCTAssertGreaterThan(attentionImminent, attention28Min)
        XCTAssertGreaterThan(attention28Min, attentionNoETA)
        XCTAssertGreaterThan(attentionNoETA, activeDelivery12Min)
        XCTAssertGreaterThan(activeDelivery12Min, activeFlight28Min)
        XCTAssertGreaterThan(activeFlight28Min, activeNoETA)
        XCTAssertGreaterThan(activeNoETA, terminalDone)
    }

    func testRegistrationControllerHandlesPushToStartPerKeyTokensDismissalAndAuthorityChange() async throws {
        let suite = "LiveStatusRegistrationTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let probe = LiveStatusProbe()
        let oldChannel = LiveStatusTestChannel(sessionID: "session-1", accountID: "account-1", probe: probe)
        let newChannel = LiveStatusTestChannel(sessionID: "session-2", accountID: "account-2", probe: probe)
        let workspace = Workspace(id: "w1", groupID: "g1", name: "Main")

        let controller = LiveStatusRegistrationController(preferences: preferences)
        controller.configure(channel: oldChannel, workspace: workspace, origin: "https://live.test",
                             enabled: true, restoredActivityIDs: [])
        controller.setStartToken("pts-hex-token")
        controller.setLiveToken("car-hex-token", activityID: "act-car", liveKey: "didi:1")
        controller.setLiveToken("flight-hex-token", activityID: "act-flight", liveKey: "flight:CA1501")
        await controller.settle()

        let posts = await probe.posts
        XCTAssertEqual(posts.count, 3)
        XCTAssertTrue(posts.contains { $0.activityID == nil && $0.liveKey == nil && $0.token == "pts-hex-token" })
        XCTAssertTrue(posts.contains { $0.activityID == "act-car" && $0.liveKey == "didi:1" })
        XCTAssertTrue(posts.contains { $0.activityID == "act-flight" && $0.liveKey == "flight:CA1501" })

        // Dismiss one key -> exact ID retired with .dismissed
        let carID = try XCTUnwrap(posts.first { $0.liveKey == "didi:1" }?.registrationID)
        controller.retireLive(liveKey: "didi:1", reason: .dismissed)
        await controller.settle()
        let afterDismiss = await probe.deletions
        XCTAssertEqual(afterDismiss.count, 1)
        XCTAssertEqual(afterDismiss.first?.id, carID)
        XCTAssertEqual(afterDismiss.first?.reason, .dismissed)

        // Authority change -> remaining push-to-start and flight tokens retired with .authorityChanged
        controller.configure(channel: newChannel, workspace: workspace, origin: "https://live.test",
                             enabled: true, restoredActivityIDs: [])
        await controller.settle()
        let afterSwitch = await probe.deletions
        XCTAssertEqual(afterSwitch.count, 3)
        XCTAssertEqual(afterSwitch.dropFirst().map(\.reason), [.authorityChanged, .authorityChanged])
    }

    func testCoordinatorStopsCleanlyAndRetiresStartToken() async throws {
        let suite = "LiveStatusCoordinatorTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let probe = LiveStatusProbe()
        let channel = LiveStatusTestChannel(sessionID: "session-a", accountID: "account-a", probe: probe)
        let workspace = Workspace(id: "w1", groupID: "g1", name: "Main")
        let coordinator = LiveStatusActivityCoordinator(startToken: { Data([0xDE, 0xAD, 0xBE, 0xEF]) },
                                                        preferences: preferences)
        await coordinator.configure(accountID: "account-a", workspace: workspace, origin: "https://live.test",
                                    automaticFollowing: true, channel: channel)
        await coordinator.settleRegistrations()
        let posts = await probe.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.token, "deadbeef")

        await coordinator.stop()
        await coordinator.settleRegistrations()
        let deletions = await probe.deletions
        XCTAssertEqual(deletions.count, 1)
        XCTAssertEqual(deletions.first?.id, posts.first?.registrationID)
        XCTAssertEqual(deletions.first?.reason, .authorityChanged)
    }

    /// The system renders a Live Activity in the widget extension, where a live countdown takes all the width
    /// it is offered. A presentation that sizes itself to that countdown has no finite layout: the system
    /// then draws an empty Lock Screen card, or ends the activity when the presentation has a step track.
    /// This starts a real activity with both and checks that the system keeps it.
    func testActivityWithLiveCountdownAndStepTrackStaysActive() async throws {
        try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are off on this device")
        let now = Int(Date().timeIntervalSince1970)
        let state = LiveStatusAttributes.ContentState(
            category: "car", status: "active", accent: "green", title: "D8821", subtitle: "1.2 km",
            etaEpochSeconds: now + 240, progress: 0.65, stepCurrent: 2, stepTotal: 4, stepLabel: "Pickup",
            detailLeft: "4.9", detailRight: "17", updatedAtEpochSeconds: now
        )
        let attributes = LiveStatusAttributes(
            accountID: "live-countdown-test", workspaceID: "w1", groupID: "g1",
            liveKey: "ride:" + UUID().uuidString, conversationID: nil, startedAtEpochSeconds: now
        )
        let activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        addTeardownBlock { await activity.end(nil, dismissalPolicy: .immediate) }

        // The system ends an activity it cannot render after it has tried a few times: about five seconds on a
        // simulator that has not shown a Live Activity yet.
        let deadline = ContinuousClock.now + .seconds(12)
        while activity.activityState == .active, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(activity.activityState, .active)
    }

    func testDeepLinkRoutingOpensMatchingTaskOrFallsBackToRouter() async throws {
        let core = FakeCore()
        core.on("chat.prepare") { params in
            let id = params["conversationId"] as? String
            let kind = id == "task-99" ? "agent_task" : "router"
            return ["conversation": ["id": id ?? "", "kind": kind]]
        }
        let config = AppConfiguration(baseURL: URL(string: "https://live.test")!, credentialService: "LiveStatusActivityTests")
        let custody = try SessionCustody(record: MemoryRecord(), apiOrigin: "https://live.test")
        let suite = "LiveStatusDeepLinkTests." + UUID().uuidString
        let workspacePrefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { workspacePrefs.removePersistentDomain(forName: suite) }
        let store = CommaStore(configuration: config, core: core, custody: custody, apple: AppleSignInSheet(),
                               workspacePreferences: workspacePrefs)
        let w1 = Workspace(id: "w1", groupID: "g1", name: "Work")
        let session = CommaSession(id: "s1", expiresAt: 4_102_444_800,
                                   user: CommaUser(id: "u1", email: "test@comma.surf", name: "Test"))
        store.session = session
        store.workspaces = [w1]
        store.workspace = w1

        // 1. Conversation is a Task -> opens task pane
        let taskURL = URL(string: "comma://live-activity?workspace=w1&group=g1&key=deploy:1&conversation=task-99")!
        let handledTask = await CommaApp.handleLiveStatusDeepLink(taskURL, store: store)
        XCTAssertTrue(handledTask)
        XCTAssertEqual(store.task?.taskID, "task-99")

        // 2. Conversation omitted -> closes task and reveals router
        let routerURL = URL(string: "comma://live-activity?workspace=w1&group=g1&key=didi:1")!
        let handledRouter = await CommaApp.handleLiveStatusDeepLink(routerURL, store: store)
        XCTAssertTrue(handledRouter)
        XCTAssertNil(store.task)
    }

    func testDynamicIslandCompactIconsShrinkWithinNarrowMenuBarSlot() {
        func measured<V: View>(_ view: V, in limit: CGSize) -> CGSize {
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: limit)
        }

        let narrowSlot = CGSize(width: 9.5, height: 20)
        let islandSlot = CGSize(width: 40, height: 28)

        let narrowMark = measured(DynamicIslandCompactMark(), in: narrowSlot)
        XCTAssertGreaterThan(narrowMark.width, 0)
        XCTAssertLessThanOrEqual(narrowMark.width, narrowSlot.width + 0.5)
        XCTAssertLessThanOrEqual(narrowMark.height, narrowSlot.width + 0.5)

        let narrowClock = measured(DynamicIslandCompactSymbol(systemName: "clock"), in: narrowSlot)
        XCTAssertGreaterThan(narrowClock.width, 0)
        XCTAssertLessThanOrEqual(narrowClock.width, narrowSlot.width + 0.5)
        XCTAssertLessThanOrEqual(narrowClock.height, narrowSlot.width + 0.5)

        let islandMark = measured(DynamicIslandCompactMark(), in: islandSlot)
        XCTAssertEqual(islandMark.width, 13, accuracy: 0.5)
        XCTAssertEqual(islandMark.height, 13, accuracy: 0.5)

        let islandClock = measured(DynamicIslandCompactSymbol(systemName: "clock"), in: islandSlot)
        XCTAssertLessThanOrEqual(islandClock.width, 12.5)
        XCTAssertLessThanOrEqual(islandClock.height, 12.5)
        XCTAssertGreaterThanOrEqual(islandClock.height, 11.5)

        let carState = LiveStatusAttributes.ContentState(
            category: "car", status: "active", accent: "green",
            title: "D8821", updatedAtEpochSeconds: 1_800_000_000
        )
        let narrowLeading = measured(LiveStatusCompactLeadingView(state: carState), in: narrowSlot)
        XCTAssertLessThanOrEqual(narrowLeading.width, narrowSlot.width + 0.5)
        let narrowTrailingStale = measured(LiveStatusCompactTrailingView(state: carState, isStale: true), in: narrowSlot)
        XCTAssertLessThanOrEqual(narrowTrailingStale.width, narrowSlot.width + 0.5)
        let narrowTrailingFallback = measured(LiveStatusCompactTrailingView(state: carState, isStale: false), in: narrowSlot)
        XCTAssertLessThanOrEqual(narrowTrailingFallback.width, narrowSlot.width + 0.5)
    }
}

private actor LiveStatusProbe {
    struct Post: Sendable {
        let token: String
        let activityID: String?
        let liveKey: String?
        let registrationID: String
    }
    struct Deletion: Sendable {
        let id: String
        let reason: ActivityRetirementReason
    }
    private(set) var posts: [Post] = []
    private(set) var deletions: [Deletion] = []

    func register(token: String, activityID: String?, liveKey: String?, registrationID: String) throws -> NotificationRegistration {
        posts.append(Post(token: token, activityID: activityID, liveKey: liveKey, registrationID: registrationID))
        let data = try JSONSerialization.data(withJSONObject: ["id": registrationID, "status": "active"])
        return try JSONDecoder().decode(NotificationRegistration.self, from: data)
    }

    func retire(id: String, reason: ActivityRetirementReason) {
        deletions.append(Deletion(id: id, reason: reason))
    }
}

private struct LiveStatusTestChannel: LiveStatusNotificationTransport {
    let sessionID: String
    let accountID: String
    let probe: LiveStatusProbe

    func register(token: String, activityID: String?, liveKey: String?, registrationID: String) async throws -> NotificationRegistration {
        try await probe.register(token: token, activityID: activityID, liveKey: liveKey, registrationID: registrationID)
    }

    func retire(id: String, reason: ActivityRetirementReason) async throws {
        await probe.retire(id: id, reason: reason)
    }
}
#endif
