import Foundation
import Testing
@testable import CommaCore

private final class Credentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StoredCredential] = [:]
    func load(origin: String) throws -> StoredCredential? { lock.withLock { values[origin] } }
    func save(_ credential: StoredCredential) throws { lock.withLock { values[credential.origin] = credential } }
    func delete(origin: String) throws { _ = lock.withLock { values.removeValue(forKey: origin) } }
}

/// Answers each request with the next queued response and records what was sent.
private actor QueueTransport: CommaTransport {
    private var responses: [HTTPResponse]
    private(set) var sent: [URLRequest] = []
    init(_ responses: [(String, Int)]) { self.responses = responses.map { HTTPResponse(data: Data($0.0.utf8), status: $0.1) } }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        sent.append(request)
        guard !responses.isEmpty else { throw CommaError.transport }
        return responses.removeFirst()
    }
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse { throw CommaError.transport }
}

private let taskTarget = ConversationTarget(workspaceID: "w1", groupID: "g1", conversationID: "t1")
private let taskJSON = #"{"id":"t1","group_id":"g1","title":"Renamed","status":"in_progress","kind":"agent_task","updated_at":1700000000123,"shared":true}"#

private func signedInClient(_ responses: [(String, Int)]) throws -> (CommaClient, QueueTransport) {
    let credentials = Credentials()
    try credentials.save(StoredCredential(origin: origin, token: "bearer", session:
        CommaSession(id: "s-phone", expiresAt: 9_999_999_999, user: CommaUser(id: "u1", email: "u@example.com"))))
    let transport = QueueTransport([(#"{"session_id":"s-phone","expires_at":9999999999,"user":{"id":"u1","email":"u@example.com"}}"#, 200)] + responses)
    return (try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport), transport)
}

private func body(_ request: URLRequest) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody ?? Data("{}".utf8))
}

@Suite("Task management, sharing and account endpoints")
struct ProductFeatureTests {
    @Test func renameArchiveAndPinUseTheTaskResourceWithItsVersion() async throws {
        let (client, transport) = try signedInClient([(taskJSON, 200), (taskJSON, 200), (#"{"conversation":\#(taskJSON),"pinned_at":1}"#, 200), ("", 204)])
        _ = try await client.restoreSession()
        let renamed = try await client.renameTask(target: taskTarget, title: "  Renamed  ")
        #expect(renamed.title == "Renamed" && renamed.shared == true)
        _ = try await client.setTaskArchived(target: taskTarget, archived: true, version: renamed.archiveVersion!)
        try await client.setTaskPinned(target: taskTarget, pinned: true)
        try await client.setTaskPinned(target: taskTarget, pinned: false)
        let sent = await transport.sent.dropFirst()
        let calls = sent.map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == ["PATCH /v1/comma/groups/g1/conversations/t1", "POST /v1/comma/groups/g1/conversations/t1/archive",
                          "PUT /v1/comma/groups/g1/conversations/t1/pin", "DELETE /v1/comma/groups/g1/conversations/t1/pin"])
        #expect(try body(sent[sent.startIndex]) == ["title": .string("Renamed")])
        #expect(try body(sent[sent.startIndex + 1]) == ["expected_updated_at": .number(1_700_000_000_123)])
        await #expect(throws: CommaError.self) { try await client.renameTask(target: taskTarget, title: "   ") }
    }

    @Test func manualStatusSendsTheStatusAndTheVersionTheMemberSaw() async throws {
        let ended = #"{"id":"t1","group_id":"g1","title":"Renamed","status":"cancelled","kind":"agent_task","updated_at":1700000000124}"#
        let (client, transport) = try signedInClient([(ended, 200)])
        _ = try await client.restoreSession()
        let running = try JSONDecoder().decode(Conversation.self, from: Data(#"{"id":"t1","group_id":"g1","title":"Renamed","status":"active","kind":"agent_task","updated_at":1700000000123}"#.utf8))
        #expect(running.canSetStatus)
        let result = try await client.setTaskStatus(target: taskTarget, status: .cancelled, expectedUpdatedAt: running.archiveVersion!)
        #expect(result.status == "cancelled" && !result.canSetStatus)
        let sent = await transport.sent.last!
        #expect("\(sent.httpMethod!) \(sent.url!.path)" == "POST /v1/comma/groups/g1/conversations/t1/status")
        #expect(try body(sent) == ["status": .string("cancelled"), "expected_updated_at": .number(1_700_000_000_123)])
        await #expect(throws: CommaError.self) {
            try await client.setTaskStatus(target: taskTarget, status: .completed, expectedUpdatedAt: 0)
        }
    }

    @Test func archivedListingAsksOnlyForArchivedTasks() async throws {
        let (client, transport) = try signedInClient([(#"{"data":[],"has_more":false}"#, 200)])
        _ = try await client.restoreSession()
        _ = try await client.listTasks(workspace: workspace, archived: true)
        let query = await URLComponents(url: transport.sent.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "archive", value: "only")))
    }

    @Test func unsharedTaskReadsAsNilAndShareLifecycleMapsToItsRoutes() async throws {
        let share = #"{"url":"https://comma.test/s/abc","created_at":1,"shared_at":2,"message_count":3,"artifact_count":0,"has_newer_messages":true}"#
        let (client, transport) = try signedInClient([(#"{"error":"not_found"}"#, 404), (share, 200), (share, 200), (#"{"revoked":true}"#, 200)])
        _ = try await client.restoreSession()
        #expect(try await client.taskShare(target: taskTarget) == nil)
        let published = try await client.publishTaskShare(target: taskTarget)
        #expect(published.hasNewerMessages && published.messageCount == 3)
        _ = try await client.resetTaskShare(target: taskTarget)
        try await client.revokeTaskShare(target: taskTarget)
        let calls = await transport.sent.dropFirst().map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == ["GET /v1/comma/groups/g1/conversations/t1/share", "PUT /v1/comma/groups/g1/conversations/t1/share",
                          "POST /v1/comma/groups/g1/conversations/t1/share/reset", "DELETE /v1/comma/groups/g1/conversations/t1/share"])
    }

    @Test func workerHistoryRejectsAPageForAnotherWorkerOrAStuckCursor() async throws {
        let page = #"{"conversation_id":"t1","participant_id":"p1","records":[{"id":"9","kind":"user","content":"hi"}],"has_more":true,"next_before":"9"}"#
        let other = #"{"conversation_id":"t1","participant_id":"p2","records":[],"has_more":false}"#
        let (client, transport) = try signedInClient([(page, 200), (page, 200), (other, 200)])
        _ = try await client.restoreSession()
        let first = try await client.workerHistory(target: taskTarget, participantID: "p1")
        #expect(first.nextBefore == "9")
        await #expect(throws: CommaError.invalidResponse) { try await client.workerHistory(target: taskTarget, participantID: "p1", before: "9") }
        await #expect(throws: CommaError.invalidResponse) { try await client.workerHistory(target: taskTarget, participantID: "p1") }
        let url = await transport.sent[1].url!
        #expect(url.path == "/v1/comma/groups/g1/conversations/t1/participants/p1/history")
    }

    @Test func labelCatalogKeepsLabelsWhenAProposalShapeIsUnknown() throws {
        let json = #"{"labels":[{"id":"l1","name":"Bug","color":"error"}],"proposals":[{"unexpected":true}],"approval_policy":"auto"}"#
        let catalog = try JSONDecoder().decode(TaskLabelCatalog.self, from: Data(json.utf8))
        #expect(catalog.labels.map(\.id) == ["l1"])
        #expect(catalog.proposals.isEmpty && catalog.approvalPolicy == "auto")
    }

    @Test func labelChangesAndProposalDecisionsPostTheDesktopContract() async throws {
        let catalog = #"{"labels":[],"proposals":[],"colors":["blue"],"approval_policy":"ask"}"#
        let (client, transport) = try signedInClient(Array(repeating: (catalog, 200), count: 5))
        _ = try await client.restoreSession()
        _ = try await client.createTaskLabel(groupID: "g1", name: "Bug", color: "error")
        _ = try await client.updateTaskLabel(groupID: "g1", labelID: "l1", name: "Bugs", color: "#112233", description: "")
        _ = try await client.deleteTaskLabel(groupID: "g1", labelID: "l1")
        _ = try await client.resolveTaskLabelProposal(groupID: "g1", proposalID: "p1", approve: false)
        _ = try await client.setTaskLabelApprovalPolicy(groupID: "g1", policy: "auto")
        let sent = Array(await transport.sent.dropFirst())
        #expect(sent.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "POST /v1/comma/groups/g1/task-labels", "PATCH /v1/comma/groups/g1/task-labels/l1",
            "DELETE /v1/comma/groups/g1/task-labels/l1", "POST /v1/comma/groups/g1/task-labels/proposals/p1/resolve",
            "PATCH /v1/comma/groups/g1/task-labels/policy"])
        #expect(try body(sent[3]) == ["decision": .string("reject")])
        #expect(try body(sent[4]) == ["approval_policy": .string("auto")])
    }

    @Test func avatarUploadIsBoundedMultipartUnderTheAvatarField() async throws {
        let profile = #"{"id":"u1","email":"u@example.com","name":"Ada","avatar_id":"a1"}"#
        let (client, transport) = try signedInClient([(profile, 200)])
        _ = try await client.restoreSession()
        let result = try await client.uploadAvatar(data: Data([0xFF, 0xD8, 0xFF]), contentType: "image/jpeg")
        #expect(result.avatarID == "a1")
        let request = await transport.sent.last!
        #expect(request.httpMethod == "PUT" && request.url!.path == "/v1/comma/me/avatar")
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("name=\"avatar\"; filename=\"avatar.jpg\""))
        await #expect(throws: CommaError.self) {
            try await client.uploadAvatar(data: Data(count: UserProfile.maxAvatarBytes + 1), contentType: "image/jpeg")
        }
        await #expect(throws: CommaError.self) { try await client.updateProfile(name: String(repeating: "a", count: 65)) }
    }

    @Test func thisDeviceIsNeverRevokedThroughSessionManagement() async throws {
        let (client, transport) = try signedInClient([(#"{"revoked":true}"#, 200), (#"{"revoked_count":2}"#, 200)])
        _ = try await client.restoreSession()
        await #expect(throws: CommaError.self) { try await client.revokeAuthSession(id: "s-phone") }
        try await client.revokeAuthSession(id: "s-watch")
        #expect(try await client.revokeOtherAuthSessions() == 2)
        let sent = Array(await transport.sent.dropFirst())
        #expect(sent.map { "\($0.httpMethod!) \($0.url!.path)" } == ["DELETE /v1/comma/auth/sessions/s-watch", "POST /v1/comma/auth/sessions/revoke-all"])
        #expect(try body(sent[1]) == ["keep_current": .bool(true)])
    }
}

@Suite("Workspace task activity and Router unread delivery")
struct NativeDeliveryFeatureTests {
    @Test func routerBeforeCreationHasZeroUnreadWithoutAConversationIdentity() async throws {
        let empty = #"{"conversation_id":null,"unread_count":0,"latest_message_id":null,"latest_seq":0}"#
        let invalid = #"{"conversation_id":null,"unread_count":1,"latest_message_id":"m1","latest_seq":1}"#
        let (client, _) = try signedInClient([(empty, 200), (invalid, 200)])
        _ = try await client.restoreSession()
        let snapshot = try await client.routerNotifications(workspace: workspace)
        #expect(snapshot.conversationID == nil && snapshot.unreadCount == 0)
        await #expect(throws: CommaError.invalidResponse) { try await client.routerNotifications(workspace: workspace) }
    }

    @Test func activityReadsTheServerSelectionIncludingExistingTasksFromOtherSources() async throws {
        let second = #"{"id":"t2","group_id":"g1","title":"WeChat task","status":"ready_for_review","kind":"agent_task","updated_at":1600000000123,"origin":"wechat","client_platform":"wechat"}"#
        let (client, transport) = try signedInClient([(#"{"data":[\#(taskJSON),\#(second)]}"#, 200), (#"{"data":[\#(second)]}"#, 200)])
        _ = try await client.restoreSession()
        let first = try await client.taskActivity(workspace: workspace)
        #expect(first.data.map(\.id) == ["t1", "t2"])
        let next = try await client.taskActivity(workspace: workspace)
        #expect(next.data.map(\.id) == ["t2"], "The timestamp may decrease when the newest Task leaves")
        let calls = await transport.sent.dropFirst()
        #expect(calls.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/comma/groups/g1/task-activity" })
    }

    @Test func activityRejectsAnOverfullOrWrongScopeProjection() async throws {
        let alien = #"{"id":"alien","group_id":"other","title":"private","status":"in_progress","kind":"agent_task"}"#
        let (client, _) = try signedInClient([(#"{"data":[\#(alien)]}"#, 200), (#"{"data":[\#(taskJSON),\#(taskJSON),\#(taskJSON)]}"#, 200)])
        _ = try await client.restoreSession()
        for _ in 0..<2 { await #expect(throws: CommaError.invalidResponse) { try await client.taskActivity(workspace: workspace) } }
    }

    @Test func routerReadAcknowledgesTheDisplayedMessageAndReturnsTheAbsoluteCount() async throws {
        let unread = #"{"conversation_id":"home","unread_count":2,"latest_message_id":"m2","latest_seq":9}"#
        let read = #"{"conversation_id":"home","unread_count":1,"latest_message_id":"m2","latest_seq":9}"#
        let (client, transport) = try signedInClient([(unread, 200), (read, 200)])
        _ = try await client.restoreSession()
        #expect(try await client.routerNotifications(workspace: workspace).unreadCount == 2)
        #expect(try await client.readRouterNotifications(workspace: workspace, messageID: "m1").unreadCount == 1)
        let request = await transport.sent.last!
        #expect(request.httpMethod == "POST" && request.url?.path == "/v1/comma/groups/g1/router-notifications/read")
        #expect(try body(request) == ["message_id": .string("m1")])
    }

    @Test func activityRetirementRetainsItsOriginalSessionAfterLocalSignOut() async throws {
        let (client, transport) = try signedInClient([("", 204)])
        _ = try await client.restoreSession()
        let channel = try await client.activityNotificationChannel(workspace: workspace, environment: .production, bundleID: "surf.comma.ios", locale: "en-US")
        try await client.clearLocalSession()
        try await channel.retire(id: "activity-registration", reason: .dismissed)
        let request = await transport.sent.last!
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "reason", value: "dismissed")])
        await #expect(throws: CommaError.staleSession) { try await channel.register(token: "test-only-token", activityID: nil, registrationID: UUID().uuidString) }
    }
}
