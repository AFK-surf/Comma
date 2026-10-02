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

private let origin = "https://api.comma.test"
private let target = ConversationTarget(workspaceID: "w1", groupID: "g1", conversationID: "t1")
private let workspace = Workspace(id: "w1", groupID: "g1", name: "Workspace")
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
        let renamed = try await client.renameTask(target: target, title: "  Renamed  ")
        #expect(renamed.title == "Renamed" && renamed.shared == true)
        _ = try await client.setTaskArchived(target: target, archived: true, version: renamed.archiveVersion!)
        try await client.setTaskPinned(target: target, pinned: true)
        try await client.setTaskPinned(target: target, pinned: false)
        let sent = await transport.sent.dropFirst()
        let calls = sent.map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == ["PATCH /v1/comma/groups/g1/conversations/t1", "POST /v1/comma/groups/g1/conversations/t1/archive",
                          "PUT /v1/comma/groups/g1/conversations/t1/pin", "DELETE /v1/comma/groups/g1/conversations/t1/pin"])
        #expect(try body(sent[sent.startIndex]) == ["title": .string("Renamed")])
        #expect(try body(sent[sent.startIndex + 1]) == ["expected_updated_at": .number(1_700_000_000_123)])
        await #expect(throws: CommaError.self) { try await client.renameTask(target: target, title: "   ") }
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
        #expect(try await client.taskShare(target: target) == nil)
        let published = try await client.publishTaskShare(target: target)
        #expect(published.hasNewerMessages && published.messageCount == 3)
        _ = try await client.resetTaskShare(target: target)
        try await client.revokeTaskShare(target: target)
        let calls = await transport.sent.dropFirst().map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(calls == ["GET /v1/comma/groups/g1/conversations/t1/share", "PUT /v1/comma/groups/g1/conversations/t1/share",
                          "POST /v1/comma/groups/g1/conversations/t1/share/reset", "DELETE /v1/comma/groups/g1/conversations/t1/share"])
    }

    @Test func workerHistoryRejectsAPageForAnotherWorkerOrAStuckCursor() async throws {
        let page = #"{"conversation_id":"t1","participant_id":"p1","records":[{"id":"9","kind":"user","content":"hi"}],"has_more":true,"next_before":"9"}"#
        let other = #"{"conversation_id":"t1","participant_id":"p2","records":[],"has_more":false}"#
        let (client, transport) = try signedInClient([(page, 200), (page, 200), (other, 200)])
        _ = try await client.restoreSession()
        let first = try await client.workerHistory(target: target, participantID: "p1")
        #expect(first.nextBefore == "9")
        await #expect(throws: CommaError.invalidResponse) { try await client.workerHistory(target: target, participantID: "p1", before: "9") }
        await #expect(throws: CommaError.invalidResponse) { try await client.workerHistory(target: target, participantID: "p1") }
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

@Suite("Worker history projection")
struct WorkerHistoryProjectionTests {
    @Test func toolResultsJoinTheirCallOnlyByCallID() throws {
        let records: [WorkerHistoryRecord] = try JSONDecoder().decode([WorkerHistoryRecord].self, from: Data(#"""
        [
          {"id":"1","kind":"user","content":"Find the report","input_text":"Find the report"},
          {"id":"2","kind":"assistant","content":{"content":"","tool_calls":[
            {"id":"c1","function":{"name":"env.exec","arguments":"{\"command\":\"ls\",\"description\":\"List files\"}"}},
            {"id":"c2","name":"web.search","args":{"query":"report"}}]}},
          {"id":"3","kind":"tool","content":{"tool_call_id":"c1","status":"completed","output":"report.pdf"}},
          {"id":"4","kind":"tool","content":{"tool_call_id":"c2","is_error":true,"error_message":"Rate limited"}},
          {"id":"5","kind":"tool","content":{"tool_call_id":"c1","status":"running","progress":"late receipt"}},
          {"id":"6","kind":"system","content":"Inbound message source: telegram"},
          {"id":"7","kind":"assistant","content":{"content":"Found report.pdf"}}
        ]
        """#.utf8))
        let items = WorkerHistory.items(records)
        #expect(items.map(\.kind) == [.input, .success, .failure, .model])
        #expect(items[1].tool == "env.exec" && items[1].summary == "report.pdf")
        #expect(items[2].tool == "web.search" && items[2].summary == "Rate limited")
        #expect(items[3].summary == "Found report.pdf")
    }

    @Test func pagesMergeInLedgerOrderByNumericID() {
        let older = [WorkerHistoryRecord(id: "9", kind: "user", content: .string("a")), WorkerHistoryRecord(id: "10", kind: "user", content: .string("b"))]
        let newer = [WorkerHistoryRecord(id: "10", kind: "user", content: .string("b2")), WorkerHistoryRecord(id: "100", kind: "user", content: .string("c"))]
        let merged = WorkerHistory.merge(newer, older)
        #expect(merged.map(\.id) == ["9", "10", "100"])
        #expect(merged[1].content == .string("b"))
    }
}

@Suite("Recommendation feed decoding")
struct RecommendationFeedTests {
    @Test func promptReferencesResolveAndSourcesNameCardLogos() throws {
        let json = #"""
        {"state":"fresh","settings":{"sources":[
            {"appId":"github","appName":"GitHub","connectionId":"conn-gh","enabled":true,"kind":"composio","label":"acme"},
            {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme","needsReconnect":true}]},
         "snapshot":{"generatedAt":1700000000000,"generation":4,"protocolVersion":1,"sourceRevision":1,"templateCatalogVersion":1,"warnings":[],
          "summary":[{"kind":"markdown","text":"Two things need you. "},{"kind":"inline-task","task":{"conversationId":"t1","label":"Fix CI"}}],
          "prompts":{"p1":{"sourceId":"conn-gh","sourceUrl":"https://github.com/o/r/pull/1","objective":"Review PR 1","context":"…","contextLabel":"PR"}},
          "cards":[
            {"id":"c1","title":"Reviews","template":"text-list@1","sourceIds":["conn-gh"],"fallbackText":"x","items":[
              {"id":"i1","parts":[{"kind":"markdown","text":"PR 1 is waiting"}],"action":{"type":"send_to_comma","label":"Ask Comma","promptId":"p1","requiresConfirmation":true}},
              {"id":"i2","parts":[{"kind":"inline-task","task":{"conversationId":"t9","label":"Reply to Ada"}}],"action":{"type":"open_url","href":"https://mail.example/1","label":"Open","requiresConfirmation":false}}]},
            {"id":"c2","title":"Later","template":"future@9","sourceIds":["conn-gh","conn-sl"],"fallbackText":"Plain text"}]}}
        """#
        let feed = try RecommendationFeed(envelope: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        #expect(feed.summaryText == "Two things need you. Fix CI")
        #expect(feed.generation == 4 && feed.canRefresh)
        #expect(feed.sourcesNeedingReconnect.map(\.appName) == ["Slack"])
        #expect(feed.source(for: feed.cards[0])?.appID == "github")
        #expect(feed.source(for: feed.cards[1]) == nil)
        #expect(feed.cards[0].items[0].action == .prompt("Review PR 1\n\nhttps://github.com/o/r/pull/1", label: "Ask Comma", memberTask: true))
        #expect(feed.cards[0].items[1].linkedTaskID == "t9")
        #expect(feed.cards[1].items.isEmpty && feed.cards[1].fallbackText == "Plain text")
        #expect(RecommendationSource.brandKey("Google Calendar") == "googlecalendar")
    }

    @Test func emptyEnvelopeHasNoCards() throws {
        let feed = try RecommendationFeed(envelope: .object(["state": .string("empty"), "snapshot": .null]))
        #expect(feed.cards.isEmpty && !feed.hasSnapshot && !feed.canRefresh)
    }
}
