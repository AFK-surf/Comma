import Foundation
import Testing
@testable import CommaCore

private final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StoredCredential] = [:]
    func load(origin: String) throws -> StoredCredential? { lock.withLock { values[origin] } }
    func save(_ credential: StoredCredential) throws { lock.withLock { values[credential.origin] = credential } }
    func delete(origin: String) throws { _ = lock.withLock { values.removeValue(forKey: origin) } }
}

private final class StreamLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var opened = 0, closed = 0, maximumActive = 0
    func open(_ id: UUID) { lock.withLock { active.insert(id); opened += 1; maximumActive = max(maximumActive, active.count) } }
    func close(_ id: UUID) { lock.withLock { if active.remove(id) != nil { closed += 1 } } }
    func counts() -> (opened: Int, closed: Int, active: Int, maximumActive: Int) {
        lock.withLock { (opened, closed, active.count, maximumActive) }
    }
}

private actor FixtureTransport: CommaTransport {
    private var responses: [HTTPResponse]
    private var captured: [URLRequest] = []
    private var delayed: CheckedContinuation<HTTPResponse, any Error>?
    private var delayedPath: String?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var streamChunks: [Data] = []
    private var holdStreams = false
    let streamLifetime = StreamLifetimeProbe()
    init(_ responses: [HTTPResponse] = []) { self.responses = responses }
    func delay(path: String) { delayedPath = path }
    func setChunks(_ chunks: [Data]) { streamChunks = chunks }
    func keepStreamsOpen() { holdStreams = true }
    func requests() -> [URLRequest] { captured }
    func waitForRequests(_ count: Int) async {
        if captured.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    private func record(_ request: URLRequest) {
        captured.append(request)
        let ready = waiters.filter { $0.0 <= captured.count }
        waiters.removeAll { $0.0 <= captured.count }
        for waiter in ready { waiter.1.resume() }
    }
    func resume(_ response: HTTPResponse) { delayed?.resume(returning: response); delayed = nil }
    func data(for request: URLRequest) async throws -> HTTPResponse {
        record(request)
        if request.url?.path == delayedPath { return try await withCheckedThrowingContinuation { delayed = $0 } }
        guard !responses.isEmpty else { throw CommaError.transport }
        return responses.removeFirst()
    }
    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        record(request)
        let chunks = streamChunks
        if holdStreams {
            let id = UUID(), probe = streamLifetime
            probe.open(id)
            let (sequence, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            for chunk in chunks { continuation.yield(chunk) }
            return HTTPStreamResponse(status: 200, url: request.url, headers: ["content-type": "text/event-stream"], chunks: sequence,
                cancel: { probe.close(id); continuation.finish() })
        }
        return HTTPStreamResponse(status: 200, url: request.url, headers: ["content-type": "text/event-stream"], chunks:
            AsyncThrowingStream { continuation in for chunk in chunks { continuation.yield(chunk) }; continuation.finish() })
    }
}

private let origin = "https://api.comma.test"
private let target = ConversationTarget(workspaceID: "w1", groupID: "g1", conversationID: "c1")
private let workspace = Workspace(id: "w1", groupID: "g1", name: "Workspace")
private func response(_ json: String, status: Int = 200, url: URL? = nil) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), status: status, url: url)
}
private let sessionJSON = """
{"session_id":"s1","expires_at":9999999999,"user":{"id":"u1","email":"u@example.com","name":null}}
"""
private let issuedJSON = """
{"session_id":"s1","expires_at":9999999999,"token":"secret-bearer","user":{"id":"u1","email":"u@example.com","name":null}}
"""
private let conversationJSON = """
{"id":"c1","group_id":"g1","title":"Chat","status":"open","kind":"user_chat","messages":[]}
"""
private func storedSession(_ store: MemoryCredentials) throws {
    try store.save(StoredCredential(origin: origin, token: "secret-bearer", session: JSONDecoder().decode(CommaSession.self, from: Data(sessionJSON.utf8))))
}
private func event(_ json: String) throws -> ConversationEvent { try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8)) }
private func snapshot(_ owner: String = "null", messages: String = "[]") throws -> ConversationEvent {
    try event("{\"type\":\"snapshot\",\"conversation_id\":\"c1\",\"group_id\":\"g1\",\"status\":\"open\",\"messages\":\(messages),\"participant_draft\":\(owner)}")
}
private func draftFrame(_ kind: String = "started", text: String, revision: Int = 1, sources: [String] = ["m1"], key: String = "r1") throws -> ConversationEvent {
    let body: [String: JSONValue] = ["type": .string("message_draft_" + kind), "conversation_id": .string("c1"), "draft_id": .string("d1"),
        "response_key": .string(key), "source_message_ids": .array(sources.map(JSONValue.string)), "revision": .number(Double(revision)), "text": .string(text)]
    return try JSONDecoder().decode(ConversationEvent.self, from: JSONEncoder().encode(body))
}

@Suite("Comma native client boundaries")
struct CommaClientTests {
    @Test func loginAndRetryKeepOneRequestIdentity() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([response("{\"challenge_id\":\"ch1\"}"), response(issuedJSON), response(conversationJSON), response(conversationJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        let challenge = try await client.requestEmailLogin(email: "u@example.com")
        let session = try await client.verifyEmailLogin(challengeID: challenge.challengeID, code: "123456")
        #expect(session.user.id == "u1")
        _ = try await client.send(target: target, text: "Hello", requestID: "one-intent")
        _ = try await client.send(target: target, text: "Hello", requestID: "one-intent")
        let requests = await transport.requests()
        let metadata = try JSONDecoder().decode([String: JSONValue].self, from: requests[1].httpBody!)
        #expect(metadata["client_kind"] == .string("ios"))
        #expect(metadata["client_platform"] == .string("ios"))
        #expect(requests.prefix(2).allSatisfy { $0.value(forHTTPHeaderField: "x-comma-session-transport") == "bearer" })
        for request in requests.suffix(2) {
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            #expect(body["client_request_id"] == .string("one-intent"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "message_limit", value: "24")) == true)
        }
        #expect(try store.load(origin: "https://another.comma.test") == nil)
    }

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

    @Test func logoutFencesResponseEvenWhenTransportIgnoresCancellation() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"signed_out\":true}")])
        await transport.delay(path: "/v1/comma/workspaces")
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let pending = Task { try await client.listWorkspaces() }
        await transport.waitForRequests(2)
        try await client.logout()
        await transport.resume(response("{\"data\":[{\"id\":\"private\",\"group_id\":\"g1\",\"name\":\"Old account\"}]}"))
        do { _ = try await pending.value; Issue.record("Old account data escaped logout") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func startingAnotherLoginInvalidatesTheOldChallengeBeforeTheNewResponseArrives() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([response("{\"challenge_id\":\"old-challenge\"}"), response(issuedJSON)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.requestEmailLogin(email: "old@example.com")
        await transport.delay(path: "/v1/comma/auth/email/login")
        let next = Task { try await client.requestEmailLogin(email: "u@example.com") }
        await transport.waitForRequests(2)
        do { _ = try await client.verifyEmailLogin(challengeID: "old-challenge", code: "123456"); Issue.record("Old login intent remained active") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await transport.requests().count == 2)
        await transport.resume(response("{\"challenge_id\":\"new-challenge\"}"))
        let challenge = try await next.value
        _ = try await client.verifyEmailLogin(challengeID: challenge.challengeID, code: "123456")
        #expect(await client.session?.id == "s1")
    }

    @Test func unauthorizedRetainsTypedErrorAndClearsSession() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"session_revoked\"}", status: 401)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { _ = try await client.listWorkspaces(); Issue.record("Expected session rejection") }
        catch { #expect(error as? CommaError == .http(status: 401, code: "session_revoked", retryAfter: nil)) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func failedSignoutRetainsCredentialForExplicitRevocationRetry() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"auth_unavailable\"}", status: 503), response("{\"signed_out\":true}")])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { try await client.logout(); Issue.record("Expected a failed remote signout") }
        catch { #expect(error as? CommaError == .http(status: 503, code: "auth_unavailable", retryAfter: nil)) }
        #expect(await client.session?.id == "s1")
        #expect(try store.load(origin: origin)?.session.id == "s1")
        try await client.logout()
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
        let requests = await transport.requests()
        #expect(requests.suffix(2).allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer" })
    }

    @Test func externalRevocationClearsLocalAuthorityAndFencesOldWorkWithoutClaimingRemoteLogout() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)])
        await transport.delay(path: "/v1/comma/workspaces")
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        let pending = Task { try await client.listWorkspaces() }
        await transport.waitForRequests(2)
        try await client.clearLocalSession()
        await transport.resume(response("{\"data\":[]}"))
        do { _ = try await pending.value; Issue.record("Revoked local authority accepted old work") }
        catch { #expect(error as? CommaError == .staleSession) }
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "x-comma-session-transport") == "bearer")
    }

    @Test func signoutOfAnAlreadyInvalidBearerDoesNotTrapTheUserInRetry() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"unauthorized\"}", status: 401)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        try await client.logout()
        #expect(await client.session == nil)
        #expect(try store.load(origin: origin) == nil)
    }

    @Test func originAndCanonicalOwnerCannotChangeDuringResponse() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response(conversationJSON, url: URL(string: "https://evil.example"))])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do { _ = try await client.conversation(target: target); Issue.record("Expected audience rejection") }
        catch { #expect(error as? CommaError == .originMismatch) }
        #expect(throws: CommaError.invalidOrigin) { try CommaClient(baseURL: URL(string: "http://public.example")!) }
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

    @Test func watchPairingExchangesOnlyShortGrantForItsOwnSession() async throws {
        let phoneStore = MemoryCredentials(); try storedSession(phoneStore)
        let phoneTransport = FixtureTransport([response(sessionJSON), response("{\"pairing_id\":\"p1\",\"pairing_secret\":\"short-pairing-grant\",\"expires_at\":9999999999}")])
        let phone = try CommaClient(baseURL: URL(string: origin)!, credentialStore: phoneStore, transport: phoneTransport)
        _ = try await phone.restoreSession()
        let pairing = try await phone.createWatchPairing()
        let watchStore = MemoryCredentials()
        let watchTransport = FixtureTransport([response("{\"session_id\":\"watch-session\",\"token\":\"watch-bearer\",\"expires_at\":9999999999,\"user\":{\"id\":\"u1\",\"email\":\"u@example.com\"}}")])
        let watch = try CommaClient(baseURL: URL(string: origin)!, platform: .watchos, credentialStore: watchStore, transport: watchTransport)
        let own = try await watch.exchangeWatchPairing(pairing)
        #expect(own.id == "watch-session")
        let request = await watchTransport.requests().first!
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
        #expect(body == ["pairing_id": .string("p1"), "pairing_secret": .string("short-pairing-grant")])
        #expect(try watchStore.load(origin: origin)?.token == "watch-bearer")
        #expect(try phoneStore.load(origin: origin)?.token == "secret-bearer")
    }

    @Test func appleAttemptNonceAndOTPLinkUseTheBoundChallenge() async throws {
        let store = MemoryCredentials()
        let transport = FixtureTransport([
            response("{\"attempt_id\":\"a1\",\"nonce\":\"server-nonce\",\"client_id\":\"surf.comma.ios\",\"expires_at\":9999999999}"),
            response("{\"status\":\"otp_required\",\"challenge_id\":\"apple-link\",\"email\":\"u@example.com\"}"), response(issuedJSON)
        ])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        let attempt = try await client.beginAppleLogin()
        #expect(attempt.nonce == "server-nonce")
        let result = try await client.completeAppleLogin(attemptID: attempt.attemptID, identityToken: "apple-identity-token")
        guard case .otpRequired(let challenge, let email) = result else { Issue.record("Expected existing-email confirmation"); return }
        #expect(challenge == "apple-link" && email == "u@example.com")
        #expect(await client.session == nil)
        let signedIn = try await client.verifyAppleLink(challengeID: challenge, code: "123456")
        #expect(signedIn.id == "s1")
        let requests = await transport.requests()
        let body = try JSONDecoder().decode([String: JSONValue].self, from: requests[1].httpBody!)
        #expect(body["attempt_id"] == .string("a1"))
        #expect(body["identity_token"] == .string("apple-identity-token"))
        #expect(requests[2].url?.path == "/v1/comma/auth/apple/link/verify")
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

    @Test func unavailablePushCannotAppearSuccessfullyRegistered() async throws {
        let store = MemoryCredentials(); try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON), response("{\"error\":\"push_unavailable\"}", status: 503)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        do {
            _ = try await client.registerLiveActivityToken("update-token", environment: .sandbox, workspace: workspace, activityID: "activity1", taskID: "c1")
            Issue.record("Unconfigured push appeared active")
        } catch { #expect(error as? CommaError == .http(status: 503, code: "push_unavailable", retryAfter: nil)) }
        #expect(await client.session?.id == "s1")
    }
}

@Suite("Conversation presentation")
struct ConversationStateTests {
    @Test func reconnectDraftsAreCumulativeAndReplaceAtomicallyWithCanonicalHistory() throws {
        var state = ConversationState(target: target)
        let first = state.beginStream()
        try state.apply(event: draftFrame(text: "Before snapshot"), incarnation: first)
        #expect(state.draft == nil)
        try state.apply(event: snapshot(), incarnation: first)
        try state.apply(event: draftFrame(text: "Hello"), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Hello world", revision: 3), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Hello", revision: 2), incarnation: first)
        #expect(state.draft?.text == "Hello world")
        let second = state.beginStream()
        try state.apply(event: draftFrame("delta", text: "Old callback", revision: 4), incarnation: first)
        #expect(state.draft?.text == "Hello world")
        let owner = "{\"conversation_id\":\"c1\",\"draft_id\":\"d1\",\"response_key\":\"r1\",\"source_message_ids\":[\"m1\"],\"revision\":4,\"text\":\"Hello world!\"}"
        try state.apply(event: snapshot(owner), incarnation: second)
        #expect(state.draft?.text == "Hello world!")
        let canonical = "[{\"message_id\":\"assistant1\",\"kind\":\"message\",\"actor_type\":\"agent\",\"content\":[{\"type\":\"text\",\"text\":\"Hello world!\"}]}]"
        try state.apply(event: snapshot(messages: canonical), incarnation: second)
        #expect(state.draft == nil)
        #expect(state.messages.map(\.text) == ["Hello world!"])
    }

    @Test func draftSourceOrderAndCancellationFencePreventQueuedResurrection() throws {
        var state = ConversationState(target: target)
        let first = state.beginStream()
        try state.apply(event: snapshot(), incarnation: first)
        try state.apply(event: draftFrame(text: "Reply", sources: ["m1", "m2"]), incarnation: first)
        try state.apply(event: draftFrame("delta", text: "Reply corrupted", revision: 2, sources: ["m2", "m1"]), incarnation: first)
        #expect(state.draft?.text == "Reply")
        let restart = try state.apply(event: draftFrame("cancelled", text: "Reply", sources: ["m1", "m2"]), incarnation: first)
        #expect(restart)
        #expect(state.draft?.text == "Reply")
        let second = state.beginStream()
        try state.apply(event: snapshot(), incarnation: second)
        try state.apply(event: draftFrame(text: "Queued duplicate", sources: ["m1", "m2"]), incarnation: second)
        #expect(state.draft == nil)
        let third = state.beginStream()
        try state.apply(event: snapshot(), incarnation: third)
        try state.apply(event: draftFrame(text: "New activation send", sources: ["m1", "m2"]), incarnation: third)
        #expect(state.draft?.text == "New activation send")
    }

    @Test func participantActivityCannotCompleteTaskAndLoadedHistorySurvivesTailRefresh() throws {
        var state = ConversationState(target: target)
        let old = Message(id: "old", kind: "message", actorType: "user", content: [ContentBlock(type: "text", fields: ["text": .string("Older")])])
        let task = Conversation(id: "c1", groupID: "g1", title: "Task", status: "ready_for_review", kind: "agent_task", reviewVersion: 4, messages: [old])
        try state.reconcile(conversation: task)
        let stream = state.beginStream()
        try state.apply(event: event("{\"type\":\"task_participant_statuses\",\"conversation_id\":\"c1\",\"bound_worker\":{\"participant_id\":\"p1\",\"name\":\"Research Worker\"},\"participants\":[{\"conversation_id\":\"c1\",\"participant_id\":\"p1\",\"state\":\"active\",\"status\":\"running\",\"updated_at\":12}]}"), incarnation: stream)
        #expect(state.conversation?.bucket == .needsReview)
        #expect(state.participantStatuses.first?.status == "running")
        #expect(state.boundWorker == BoundWorker(participantID: "p1", name: "Research Worker"))
        let tail = Message(id: "new", kind: "message", actorType: "agent", content: [])
        try state.reconcile(conversation: Conversation(id: "c1", groupID: "g1", title: "Task", status: "ready_for_review", kind: "agent_task", messages: [tail]))
        #expect(state.messages.map(\.id) == ["old", "new"])
        #expect(throws: CommaError.invalidResponse) {
            try state.reconcile(conversation: Conversation(id: "other", groupID: "g1", title: "Other", status: "active", kind: "agent_task"))
        }
    }

    @Test func malformedTransientOwnerDoesNotLoseReadableCanonicalHistory() throws {
        var state = ConversationState(target: target)
        let stream = state.beginStream()
        let message = "[{\"message_id\":\"m1\",\"kind\":\"message\",\"actor_type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Canonical\"}]}]"
        try state.apply(event: snapshot("{\"unexpected\":true}", messages: message), incarnation: stream)
        #expect(state.messages.first?.text == "Canonical")
        #expect(state.draft == nil)
    }

    @Test func contextAndPrivateFencesStayOutOfChatPresentation() throws {
        var state = ConversationState(target: target)
        let privateRow = Message(id: "context", kind: "message", actorType: "system", content: [ContentBlock(type: "text", fields: ["text": .string("[[comma-context]] internal instructions")])])
        let reply = Message(id: "reply", kind: "message", actorType: "agent", content: [ContentBlock(type: "text", fields: ["text": .string("Public\n```comma:private\ninternal\n```\nReply[[comma-protocol]]hidden")])])
        try state.reconcile(conversation: Conversation(id: "c1", groupID: "g1", title: "Chat", status: "open", kind: "user_chat", messages: [privateRow, reply]))
        #expect(state.messages.map(\.id) == ["reply"])
        #expect(state.messages.first?.text == "Public\n\nReply")
        #expect(Message.publicText("Visible\n```comma:private\ntruncated") == "Visible")
    }
}

@Suite("SSE framing")
struct SSEParserTests {
    @Test func fragmentedUTF8MultilineCRLFAndTruncatedTail() throws {
        var parser = SSEParser()
        let value = Data(": heartbeat\r\nevent: snapshot\r\ndata: {\"type\":\"snapshot\",\r\ndata: \"title\":\"你好\"}\r\n\r\n".utf8)
        var result: [SSEFrame] = []
        for byte in value { result += try parser.append(Data([byte])) }
        #expect(result.count == 1)
        #expect(try JSONDecoder().decode(ConversationEvent.self, from: result[0].data).title == "你好")
        #expect(try parser.append(Data("data: {\"type\":\"snapshot\"}".utf8)).isEmpty)
        #expect(try parser.finish().isEmpty)
    }
}

extension CommaClientTests {
    @Test func ordinaryDeviceDeleteIsAuthenticatedIdempotentAndRequires204() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let transport = FixtureTransport([response(sessionJSON), response("", status: 204), response("", status: 204), response("{}", status: 200)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        try await client.unregisterDeviceNotifications()
        try await client.unregisterDeviceNotifications()
        do { try await client.unregisterDeviceNotifications(); Issue.record("200 is not deletion confirmation") }
        catch { #expect(error as? CommaError == .invalidResponse) }
        let requests = await transport.requests().dropFirst()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy {
            $0.httpMethod == "DELETE" && $0.url?.path == "/v1/comma/notifications/devices" &&
            $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer"
        })
    }

    @Test func everyPushKindCarriesMainPhoneBundleAndLocaleWithoutChangingLiveActivityContent() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let registration = response("{\"id\":\"r1\",\"status\":\"active\"}")
        let transport = FixtureTransport([response(sessionJSON), registration, registration, registration])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        _ = try await client.registerDeviceToken("test-only-device", environment: .production, workspace: workspace, bundleID: "test.main.phone", locale: "zh-Hans")
        _ = try await client.registerPushToStartToken("test-only-start", environment: .production, workspace: workspace, bundleID: "test.main.phone", locale: "zh-Hans")
        _ = try await client.registerLiveActivityToken("test-only-activity", environment: .production, workspace: workspace, activityID: "activity", taskID: "task", bundleID: "test.main.phone", locale: "zh-Hans")
        let requests = await transport.requests().dropFirst()
        for request in requests {
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            #expect(body["bundle_id"] == .string("test.main.phone"))
            #expect(body["locale"] == .string("zh-Hans"))
            #expect(body["environment"] == .string("production"))
            #expect(body["group_id"] == .string("g1"))
        }
        let activity = try JSONDecoder().decode([String: JSONValue].self, from: requests.last!.httpBody!)
        #expect(activity["task_id"] == .string("task"))
        #expect(activity["activity_id"] == .string("activity"))
    }

    @Test func delayedOrdinaryMutationCanBeRetiredWithItsCapturedSessionAfterLocalAuthorityChanges() async throws {
        let credentials = MemoryCredentials(); try storedSession(credentials)
        let transport = FixtureTransport([response(sessionJSON), response("", status: 204)])
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: credentials, transport: transport)
        _ = try await client.restoreSession()
        let channel = try await client.deviceNotificationChannel()
        await transport.delay(path: "/v1/comma/notifications/devices")
        let pending = Task { try await channel.register(token: "test-only-device", environment: .sandbox, workspace: workspace, bundleID: "test.main.phone", locale: "en-US") }
        await transport.waitForRequests(2)
        try await client.clearLocalSession()
        await transport.resume(response("{\"id\":\"old-slot\",\"status\":\"active\"}"))
        _ = try await pending.value
        await transport.delay(path: "/unused")
        try await channel.retire()
        #expect(await client.session == nil)
        let deletion = await transport.requests().last!
        #expect(deletion.httpMethod == "DELETE")
        #expect(deletion.url?.path == "/v1/comma/notifications/devices")
        #expect(deletion.value(forHTTPHeaderField: "Authorization") == "Bearer secret-bearer")
        do {
            _ = try await channel.register(token: "test-only-device", environment: .sandbox, workspace: workspace, bundleID: "test.main.phone", locale: "en-US")
            Issue.record("An old channel initiated a new registration")
        } catch { #expect(error as? CommaError == .staleSession) }
        #expect(await transport.requests().count == 3)
    }
}
