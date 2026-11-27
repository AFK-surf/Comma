import SwiftUI
import XCTest
import CommaCore
@testable import Comma

/// People on the phone, rendered against the test core: the tab, one person, starting a Collaborative Task, a request
/// to their Comma, taking an invite link, and an invitation in the Inbox. Each also checks what the page asked the
/// core for.
@MainActor final class PeopleScreenshotTests: XCTestCase {
    func testPeopleTabListsEveryoneByName() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let navigation = AppNavigation(tab: .people)
        try await shell(h, navigation: navigation, name: "people-01-list") { !h.core.topics("taskRequests").isEmpty }
        XCTAssertEqual(h.core.topics("collaborations").count, 1, "People follows its memberships once")
    }

    func testPersonPageShowsBothWaysAndSharedTasks() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        h.store.tasks = [.listed("together-1", title: "Plan our offsite in Kyoto", updatedAt: 1_795_390_000_000,
                                 group: "g1", extra: ["together": ["maya"]])]
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.follow() }
        defer { follow.cancel() }
        try await capture("people-02-person", view: PersonView(store: h.store, model: model, personID: "maya")) { model.loaded }
    }

    func testCollaborateSheetStartsWithThePerson() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.follow() }
        defer { follow.cancel() }
        await until { model.loaded }
        try await capture("people-03-collaborate", view: Color.clear.sheet(isPresented: .constant(true)) {
            CollaborateSheet(store: h.store, model: model, initial: ["maya", "sam"])
        }) { model.loaded }
    }

    func testRequestSheetNamesTheirComma() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.follow() }
        defer { follow.cancel() }
        await until { model.loaded }
        let person = try XCTUnwrap(model.person("maya"))
        let target = try XCTUnwrap(model.target(for: person))
        try await capture("people-04-request", view: Color.clear.sheet(isPresented: .constant(true)) {
            PersonRequestSheet(model: model.requests, person: person, target: target)
        }) { true }
    }

    func testEnterInviteShowsWhoSentIt() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        await model.requests.previewInvitation("https://comma.test/i/abc")
        try await capture("people-05-enter-invite", view: Color.clear.sheet(isPresented: .constant(true)) {
            EnterInviteSheet(store: h.store, model: model.requests)
        }) { model.requests.invitePreview.object != nil }
    }

    func testInboxListsAnInvitationAboveTasks() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        h.store.tasks = [.listed("done-1", title: "Summarise the venue quotes", status: "completed", section: "done",
                                 updatedAt: Date.now.timeIntervalSince1970 * 1000 - 3_600_000, group: "g1")]
        h.store.tasksLoaded = true
        let navigation = AppNavigation(tab: .inbox)
        try await shell(h, navigation: navigation, name: "people-06-inbox") { !h.core.topics("collaborations").isEmpty }
    }

    func testInvitationSheetJoinsAndOpensTheHostsTask() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.followCollaborations() }
        defer { follow.cancel() }
        await until { !model.collaborations.isEmpty }
        let item = try XCTUnwrap(model.collaborations.first)
        try await capture("people-07-invitation", view: Color.clear.sheet(isPresented: .constant(true)) {
            InvitationSheet(store: h.store, model: model, item: item)
        }) { true }
        let joined = await model.answer(item, join: true)
        XCTAssertTrue(joined)
        XCTAssertEqual(h.core.calls("collaborations.answer").first?["answer"] as? String, "accept")
        XCTAssertEqual(h.store.task?.workspace.groupID, "host-g", "The member reads the host's Task through its Group")
        XCTAssertEqual(h.store.task?.taskID, "kyoto")
    }

    func testInvitePreviewDropsStaleResponseWhenInvalidated() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let model = PeopleModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        nonisolated(unsafe) let requests = model.requests
        h.core.on("taskRequests.invitePreview") { _ in
            MainActor.assumeIsolated { requests.invalidateInvitePreview() }
            return ["own": false, "workspace": ["id": "ana-w", "name": "Ana's workspace", "owner": ["id": "ana", "name": "Ana Souza"]]]
        }
        await model.requests.previewInvitation("  https://comma.test/i/stale  ")
        XCTAssertNil(model.requests.invitePreview.object, "Stale invite preview response must be discarded after invalidation")

        h.core.on("taskRequests.invitePreview") { _ in
            ["own": false, "workspace": ["id": "ana-w", "name": "Ana's workspace", "owner": ["id": "ana", "name": "Ana Souza"]]]
        }
        h.core.on("taskRequests.acceptInvite") { _ in [:] }
        await model.requests.previewInvitation("  https://comma.test/i/fresh  ")
        XCTAssertNotNil(model.requests.invitePreview.object)
        let accepted = await model.requests.acceptInvitation("https://comma.test/i/fresh")
        XCTAssertTrue(accepted, "Trimmed invite matches previewed invite")
    }

    func testPhoneIncomingRequestReviewScreenshot() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let now = Int(Date.now.timeIntervalSince1970)
        let pending: [String: Any] = [
            "id": "req-1",
            "title": "Review the venue contract",
            "content": "Please check the cancellation terms before we sign tomorrow.",
            "status": "pending",
            "created_at": now - 7_200,
            "sender": PeopleFixtures.maya,
        ]
        let model = PhoneTaskRequestsModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.feed.follow() }
        defer { follow.cancel() }
        await until { !model.rows("incoming").isEmpty }
        try await capture("people-09-incoming-request", view: PhoneRequestDetail(model: model, request: pending as NSDictionary, incoming: true)) { true }
    }

    func testPhoneRequestDetailReadsUpdatedStatusFromReceived() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        let now = Int(Date.now.timeIntervalSince1970)
        let pending: [String: Any] = ["id": "req-1", "title": "Review the venue contract", "status": "pending",
                                      "created_at": now - 7_200, "sender": PeopleFixtures.maya]
        h.core.serve("taskRequests") { _ in
            let declined: [String: Any] = ["id": "req-1", "title": "Review the venue contract", "status": "declined",
                                           "decline_reason": "Not this week", "created_at": now - 7_200, "sender": PeopleFixtures.maya]
            return ["workspace": "w1", "incoming": [], "received": [declined], "sent": [],
                    "grants": [], "targets": [], "links": [], "own": "review", "people": [], "error": false] as [String: Any]
        }
        let model = PhoneTaskRequestsModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.feed.follow() }
        defer { follow.cancel() }
        await until { model.feed.loaded }
        let detail = PhoneRequestDetail(model: model, request: pending as NSDictionary, incoming: true)
        XCTAssertEqual(detail.current.string("status"), "declined")
        XCTAssertEqual(detail.current.string("decline_reason"), "Not this week")
    }

    func testClampUTF8EnforcesDeclineReasonByteLimit() {
        let ascii = String(repeating: "a", count: 1_001)
        let clampedAscii = PhoneRequestDetail.clampUTF8(ascii, maxBytes: PhoneRequestDetail.maxDeclineReasonBytes)
        XCTAssertEqual(clampedAscii.utf8.count, 1_000)

        let cjk = String(repeating: "中", count: 334)
        let clampedCjk = PhoneRequestDetail.clampUTF8(cjk, maxBytes: PhoneRequestDetail.maxDeclineReasonBytes)
        XCTAssertEqual(clampedCjk.count, 333)
        XCTAssertEqual(clampedCjk.utf8.count, 999)

        let emoji = String(repeating: "😀", count: 251)
        let clampedEmoji = PhoneRequestDetail.clampUTF8(emoji, maxBytes: PhoneRequestDetail.maxDeclineReasonBytes)
        XCTAssertEqual(clampedEmoji.count, 250)
        XCTAssertEqual(clampedEmoji.utf8.count, 1_000)
    }

    func testRequestStatusAndBucketReflectSentTaskStatus() {
        XCTAssertEqual(requestStatusName("accepted", taskStatus: "completed"), String(localized: "Done"))
        XCTAssertEqual(requestStatusName("accepted", taskStatus: "ready_for_review"), String(localized: "Needs review"))
        XCTAssertEqual(requestStatusName("accepted", taskStatus: "escalated"), String(localized: "Needs input"))
        XCTAssertEqual(requestStatusName("accepted", taskStatus: "failed"), String(localized: "Cancelled"))
        XCTAssertEqual(requestStatusName("accepted", taskStatus: "active"), String(localized: "In progress"))
        XCTAssertEqual(requestStatusName("accepted", taskStatus: nil), String(localized: "Accepted"))
        XCTAssertEqual(requestBucket("accepted", task: TaskBucket(status: "completed")), .done)
        XCTAssertEqual(requestBucket("accepted", task: TaskBucket(status: "ready_for_review")), .needsReview)
        XCTAssertEqual(requestBucket("accepted", task: TaskBucket(status: "failed")), .cancelled)
        XCTAssertEqual(requestBucket("pending", task: nil), nil)
    }

    func testSentRequestDetailShowsCompletedStatusAndMoreMenu() async throws {
        let h = try PeopleFixtures.harness(); await h.start()
        h.core.on("taskRequests.hide") { _ in [:] }
        let model = PhoneTaskRequestsModel(store: h.store, workspace: try XCTUnwrap(h.store.workspace))
        let follow = Task { await model.feed.follow() }
        defer { follow.cancel() }
        await until { model.feed.loaded }
        let sent = try XCTUnwrap(model.rows("sent").first)
        XCTAssertEqual(sent.string("task_status"), "completed")
        try await capture("people-08-sent-request", view: PhoneRequestDetail(model: model, request: sent, incoming: false)) { model.feed.loaded }
        let hidden = await model.scope.perform("taskRequests.hide", ["request": "sent-1"], workspaceParameter: false)
        XCTAssertNotNil(hidden)
        XCTAssertEqual(h.core.calls("taskRequests.hide").first?["request"] as? String, "sent-1")
    }

    func testPeopleSectionGroupingPlacesHashLast() {
        XCTAssertEqual(PeopleView.sectionLetter(for: "Élodie"), "E")
        XCTAssertEqual(PeopleView.sectionLetter(for: "alice"), "A")
        XCTAssertEqual(PeopleView.sectionLetter(for: "张三"), "#")
        XCTAssertEqual(PeopleView.sectionLetter(for: "123"), "#")
        let contacts: [PeoplePerson] = [
            ["id": "1", "name": "张三"],
            ["id": "2", "name": "Zoe"],
            ["id": "3", "name": "Élodie"],
            ["id": "4", "name": "123"],
            ["id": "5", "name": "Alice"],
        ].compactMap { PeoplePerson($0 as NSDictionary) }
        let keys = PeopleView.groupedSections(contacts).map(\.key)
        XCTAssertEqual(keys, ["A", "E", "Z", "#"])
    }

    // MARK: Capture

    private func shell(_ h: StoreHarness, navigation: AppNavigation, name: String,
                       ready: @escaping @MainActor () -> Bool) async throws {
        let scene = try scene()
        h.store.profileRead = true
        let root = UIHostingController(rootView: ShellTabs(store: h.store, activity: TaskActivityCoordinator(), query: HomeTaskQuery())
            .environment(navigation).providingInbox(store: h.store))
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(root); container.view.addSubview(root.view); root.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        root.view.frame = window.bounds
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(1100)); window.layoutIfNeeded()
        save(window, name)
    }

    private func capture<V: View>(_ name: String, view: V, ready: @escaping @MainActor () -> Bool) async throws {
        let scene = try scene()
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: NavigationStack { view }.environment(AppNavigation(tab: .people)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKeyAndVisible() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ready())
        try await Task.sleep(for: .milliseconds(900)); window.layoutIfNeeded()
        save(window, name)
    }

    private func scene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func save(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard let path = ProcessInfo.processInfo.environment["PEOPLE_SHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

/// Two people of People (Maya takes requests both ways; Sam only sends them), one request from Maya, and Maya's
/// invitation to a Task she hosts.
enum PeopleFixtures {
    @MainActor static func harness() throws -> StoreHarness {
        let h = try StoreHarness()
        configure(h.core)
        return h
    }

    nonisolated(unsafe) static let maya: [String: Any] = ["id": "maya", "name": "Maya Chen", "email": "maya@example.com"]

    static func configure(_ core: FakeCore) {
        let now = Int(Date.now.timeIntervalSince1970)
        core.serve("taskRequests") { _ in
            let request: [String: Any] = ["id": "req-1", "title": "Review the venue contract",
                                          "content": "Please check the cancellation terms before we sign tomorrow.",
                                          "status": "pending", "created_at": now - 7_200, "sender": maya]
            return [
                "workspace": "w1",
                "incoming": [request],
                "received": [request],
                "sent": [["id": "sent-1", "title": "Book the Kyoto train tickets", "content": "Please book two morning seats on the Nozomi from Tokyo to Kyoto.",
                          "status": "accepted", "task_status": "completed", "reply": "Booked the 09:15 Nozomi from Tokyo Station.",
                          "created_at": now - 86_400, "task_updated_at": now - 1_800,
                          "workspace": ["id": "maya-w", "name": "Maya's workspace", "owner": maya]]],
                "grants": [["id": "grant-maya", "status": "active", "mode": "review", "daily_limit": 10, "grantee": maya]],
                "targets": [["grant_id": "target-maya", "workspace": ["id": "maya-w", "name": "Maya's workspace", "owner": maya],
                             "daily_limit": 10, "pending_limit": 5, "sent_today": 1, "pending": 0]],
                "links": [], "own": "review", "error": false,
                "people": [
                    ["id": "maya", "name": "Maya Chen", "email": "maya@example.com", "avatar": NSNull(),
                     "sends": ["grant": "grant-maya", "mode": "review"],
                     "receives": [["grant": "target-maya", "workspace": "maya-w", "full": false]],
                     "waiting": ["count": 1, "first": "req-1"], "lastAt": now - 7_200, "lastTitle": "Review the venue contract"],
                    ["id": "sam", "name": "Sam Rivera", "email": "sam@example.com", "avatar": NSNull(),
                     "sends": ["grant": "grant-sam", "mode": "auto_accept"], "receives": [],
                     "waiting": NSNull(), "lastAt": now - 172_800, "lastTitle": NSNull()],
                    ["id": "ana", "name": "Ana Souza", "email": "ana@example.com", "avatar": NSNull(), "sends": NSNull(),
                     "receives": [["grant": "target-ana", "workspace": "ana-w", "full": false]],
                     "waiting": NSNull(), "lastAt": NSNull(), "lastTitle": NSNull()],
                ],
            ] as [String: Any]
        }
        core.serve("collaborations") { _ in
            ["items": [[
                "id": "invite-1", "status": "invited", "title": "Pick the dinner place for Friday",
                "task": ["id": "kyoto", "group_id": "host-g", "workspace_id": "maya-w"],
                "host": maya,
                "members": [["person": ["id": "phone-user", "name": "Lin Wei", "email": "phone@example.com"], "status": "invited"],
                            ["person": ["id": "sam", "name": "Sam Rivera", "email": "sam@example.com"], "status": "active"]],
                "invited_at": now - 600,
            ]], "error": false] as [String: Any]
        }
        core.on("taskRequests.invitePreview") { _ in
            ["own": false, "workspace": ["id": "ana-w", "name": "Ana's workspace", "owner": ["id": "ana", "name": "Ana Souza"]],
             "back": ["workspace": ["id": "w1", "name": "Comma"], "mode": "review"]]
        }
        core.on("collaborations.answer") { _ in NSNull() }
    }
}
