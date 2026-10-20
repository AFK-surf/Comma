import Foundation
import Testing
@testable import CommaCore

extension CommaClientTests {
    @Test func sendAcceptedByAServerThatIgnoresMessageLimitKeepsTheNewestTail() async throws {
        let store = MemoryCredentials()
        try storedSession(store)
        let messages = (1...30).map { "{\"message_id\":\"m\($0)\",\"kind\":\"message\",\"actor_type\":\"user\",\"content\":[]}" }
        let body = "{\"id\":\"c1\",\"group_id\":\"g1\",\"title\":\"Chat\",\"status\":\"open\",\"kind\":\"user_chat\",\"messages\":[\(messages.joined(separator: ","))]}"
        let transport = FixtureTransport([response(sessionJSON), response(body, status: 202)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let result = try await client.send(target: target, text: "Hello", requestID: "long-chat")
        #expect(result.messages.map(\.id) == (7...30).map { "m\($0)" })
    }

    /// The body the desktop pins in client.test.ts ("lists workspace skills and includes selected skill locations on
    /// sends"), less `client_timezone`, which iOS does not send.
    @Test func sendCarriesSkillLocationsLikeTheDesktop() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        _ = try await client.send(target: target, text: "hello /weekly-summary", requestID: "req_skills",
                                  skills: ["/.runtime/skills/weekly-summary/SKILL.md"], replyToMessageID: "earlier-card")
        let request = try #require(await transport.requests().last)
        #expect(request.url?.path == "/v1/comma/groups/g1/conversations/c1/messages")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(request.httpBody))
        #expect(body == ["message": .object(["type": .string("text"), "text": .string("hello /weekly-summary")]),
                         "client_request_id": .string("req_skills"), "reply_to_message_id": .string("earlier-card"),
                         "skills": .array([.object(["location": .string("/.runtime/skills/weekly-summary/SKILL.md")])])])
    }

    @Test func sendWithoutSkillsOmitsTheField() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        _ = try await client.send(target: target, text: "Hello", requestID: "plain")
        let request = try #require(await transport.requests().last)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(request.httpBody))
        #expect(body["skills"] == nil)
    }

    @Test func sendRefusesMoreThanTenSkills() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let locations = (1...11).map { "/.runtime/skills/s\($0)/SKILL.md" }
        for skills in [locations, [""], ["/a\nb"], ["/a\r\nb"], ["/" + String(repeating: "a", count: 1_024)]] {
            await #expect(throws: CommaError.invalidInput("Skill locations are invalid.")) {
                try await client.send(target: target, text: "Hello", requestID: "skills", skills: skills)
            }
        }
        #expect(await transport.requests().count == 1, "Only the session request reached the transport")
        _ = try await client.send(target: target, text: "Hello", requestID: "skills", skills: Array(locations.prefix(Skill.maxMentions)))
        let body = try JSONDecoder().decode([String: JSONValue].self, from: try #require(await transport.requests().last?.httpBody))
        #expect(body["skills"]?.array?.count == Skill.maxMentions)
    }

    @Test func taskSearchResolvesRealStatusesInOneBoundedSummaryRequest() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"data\":[{\"conversation_id\":\"c1\"}]}"), response("{\"data\":[{\"id\":\"c1\",\"group_id\":\"g1\",\"kind\":\"agent_task\",\"title\":\"Fix\",\"status\":\"ready_for_review\"}]}")])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let tasks = try await client.searchTasks(workspace: workspace, query: "Fix")
        #expect(tasks.first?.bucket == .needsReview)
        let requests = await transport.requests()
        #expect(requests.count == 3)
        #expect(requests[2].url?.path == "/v1/comma/groups/g1/task-summaries")
        #expect(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "c1")
    }

    @Test func taskStreamUsesGroupOwnerAndExplicitFiniteWait() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)])
        await transport.setChunks([Data("event: conversation_list_resync_required\ndata: {\"type\":\"conversation_list_resync_required\",\"group_id\":\"g1\"}\n\n".utf8)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        var events: [ConversationEvent] = []
        for try await event in await client.taskEvents(workspace: workspace, conversationID: "c1") { events.append(event) }
        #expect(events.count == 1)
        let request = await transport.requests().last!
        #expect(request.url?.path == "/v1/comma/groups/g1/conversations/events")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "wait", value: "30000")))
        #expect(query.contains(URLQueryItem(name: "conversation_id", value: "c1")))
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test func earlyBreakAndReconnectCancelTheUnderlyingConnectionBeforeOpeningItsReplacement() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)])
        await transport.keepStreamsOpen()
        await transport.setChunks([Data("data: {\"type\":\"snapshot\",\"conversation_id\":\"c1\",\"group_id\":\"g1\",\"messages\":[]}\n\n".utf8)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let first = await client.conversationEvents(target: target)
        for try await _ in first { break }
        let probe = transport.streamLifetime
        #expect(probe.counts().active == 1)
        let second = await client.conversationEvents(target: target)
        for try await _ in second { break }
        #expect(probe.counts().opened == 2)
        #expect(probe.counts().closed == 1)
        #expect(probe.counts().maximumActive == 1)
        first.cancel()
        #expect(probe.counts().active == 1)
        second.cancel()
        #expect(probe.counts().active == 0)
        #expect(probe.counts().closed == 2)
    }

    @Test func uploadUsesGroupMultipartAndSendUsesTheCurrentAttachmentProtocol() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"path\":\"/files/report.txt\",\"name\":\"report.txt\",\"size\":5}"), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let uploaded = try await client.uploadFile(workspace: workspace, filename: "report.txt", contentType: "text/plain", data: Data("hello".utf8))
        _ = try await client.send(target: target, text: "Read this", requestID: "file-send", attachments: [uploaded])
        let requests = await transport.requests()
        #expect(requests[1].url?.path == "/v1/comma/groups/g1/files")
        #expect(requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(String(data: requests[1].httpBody!, encoding: .utf8)?.contains("name=\"file\"; filename=\"report.txt\"") == true)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: requests[2].httpBody!)
        #expect(body["message"]?.object?["text"] == .string("Read this\n\nAttached files in your workspace:\n- report.txt (workspace file: /files/report.txt)"))
    }
}
