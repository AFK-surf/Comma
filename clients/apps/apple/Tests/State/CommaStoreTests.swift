import Foundation
import XCTest
@testable import Comma

/// What the store makes of the core's topics and answers: the Home list, an open Task the member archives, and the
/// account changing.
@MainActor
final class CommaStoreTests: XCTestCase {
    private func item(_ id: String, group: String = "g1", section: String = "in_progress", archiveVersion: Int = 7) -> [String: Any] {
        ["conversationId": id, "groupId": group, "title": "Task \(id)", "status": "active", "statusBucket": section,
         "kind": "agent_task", "updatedAt": 1, "archiveVersion": archiveVersion]
    }

    /// The list shows the Workspace's Tasks once the server answered; another Group's rows never show.
    func testTheListShowsTheWorkspacesTasksOnceRead() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        XCTAssertFalse(store.tasksLoaded)

        harness.core.publish("tasks", matching: ["workspace": "w1"], [
            "source": "live-sync", "activeWorkspaceId": "w1", "hasMore": true,
            "items": [item("a"), item("other", group: "g2"), item("b", section: "needs_review")],
            "workspaces": [["id": "w1", "group_id": "g1", "name": "Mine"]],
        ])
        await until { store.tasksLoaded }
        XCTAssertEqual(store.tasks.map(\.id), ["a", "b"])
        XCTAssertEqual(store.tasks.map(\.bucket), [.inProgress, .needsReview])
        XCTAssertTrue(store.hasMoreTasks)
        XCTAssertEqual(store.workspace?.name, "Mine", "The Workspace takes the name the list knows")
    }

    /// A list kept on the device whose read failed is a list read and failed: Home leaves the skeleton.
    func testAKeptListWhoseReadFailedIsShownAsFailed() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()

        harness.core.publish("tasks", matching: ["workspace": "w1"], [
            "source": "cache", "errorCode": "network_unavailable", "activeWorkspaceId": "w1", "items": [], "workspaces": [],
        ])
        await until { store.tasksLoaded }
        XCTAssertTrue(store.taskListFailed)
    }

    /// Archiving the open Task names the version the list had and closes its sheet.
    func testArchivingTheOpenTaskClosesItWithItsListedVersion() async throws {
        let harness = try StoreHarness()
        harness.core.on("tasks.archive") { _ in true }
        let store = harness.store
        await harness.start()
        await store.openTask(id: "a")
        XCTAssertEqual(store.task?.taskID, "a")

        let archived = await store.setTaskArchived(.listed("a", group: "g1", extra: ["archiveVersion": 7]), archived: true)
        XCTAssertTrue(archived)
        XCTAssertNil(store.task)
        let call = try XCTUnwrap(harness.core.calls("tasks.archive").first)
        XCTAssertEqual(call["conversation"] as? String, "a")
        XCTAssertEqual(call["group"] as? String, "g1")
        XCTAssertEqual(call["action"] as? String, "archive")
        XCTAssertEqual(call["version"] as? Int, 7)
    }

    /// Signing out drops what the account had: the open Task, the list and the Workspace.
    func testSigningOutClearsTheAccountsProduct() async throws {
        let harness = try StoreHarness()
        let store = harness.store
        await harness.start()
        harness.core.publish("tasks", matching: ["workspace": "w1"], [
            "source": "live-sync", "activeWorkspaceId": "w1", "items": [item("a")], "workspaces": [],
        ])
        await until { store.tasksLoaded }
        await store.openTask(id: "a")

        harness.core.publish("session", [
            "phase": "signed_out",
            "lifecycle": ["phase": "signed_out", "generation": 2, "authority": ["authorityInstanceId": "authority-1"]],
        ])
        await until { store.session == nil }
        XCTAssertNil(store.task)
        XCTAssertNil(store.workspace)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNil(store.router.pane)
    }
}
