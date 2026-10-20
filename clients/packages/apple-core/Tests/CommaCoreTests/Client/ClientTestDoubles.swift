import Foundation
@testable import CommaCore

// In-memory credentials, a scripted transport and shared fixtures for CommaClient tests.

final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: StoredCredential] = [:]
    func load(origin: String) throws -> StoredCredential? { lock.withLock { values[origin] } }
    func save(_ credential: StoredCredential) throws { lock.withLock { values[credential.origin] = credential } }
    func delete(origin: String) throws { _ = lock.withLock { values.removeValue(forKey: origin) } }
}

final class StreamLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var opened = 0, closed = 0, maximumActive = 0
    func open(_ id: UUID) { lock.withLock { active.insert(id); opened += 1; maximumActive = max(maximumActive, active.count) } }
    func close(_ id: UUID) { lock.withLock { if active.remove(id) != nil { closed += 1 } } }
    func counts() -> (opened: Int, closed: Int, active: Int, maximumActive: Int) {
        lock.withLock { (opened, closed, active.count, maximumActive) }
    }
}

actor FixtureTransport: CommaTransport {
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

let origin = "https://api.comma.test"
let target = ConversationTarget(workspaceID: "w1", groupID: "g1", conversationID: "c1")
let workspace = Workspace(id: "w1", groupID: "g1", name: "Workspace")
func response(_ json: String, status: Int = 200, url: URL? = nil) -> HTTPResponse {
    HTTPResponse(data: Data(json.utf8), status: status, url: url)
}
let sessionJSON = """
{"session_id":"s1","expires_at":9999999999,"user":{"id":"u1","email":"u@example.com","name":null}}
"""
let issuedJSON = """
{"session_id":"s1","expires_at":9999999999,"token":"secret-bearer","user":{"id":"u1","email":"u@example.com","name":null}}
"""
let conversationJSON = """
{"id":"c1","group_id":"g1","title":"Chat","status":"open","kind":"user_chat","messages":[]}
"""
func storedSession(_ store: MemoryCredentials) throws {
    try store.save(StoredCredential(origin: origin, token: "secret-bearer", session: JSONDecoder().decode(CommaSession.self, from: Data(sessionJSON.utf8))))
}
func event(_ json: String) throws -> ConversationEvent { try JSONDecoder().decode(ConversationEvent.self, from: Data(json.utf8)) }
func snapshot(_ owner: String = "null", messages: String = "[]") throws -> ConversationEvent {
    try event("{\"type\":\"snapshot\",\"conversation_id\":\"c1\",\"group_id\":\"g1\",\"status\":\"open\",\"messages\":\(messages),\"participant_draft\":\(owner)}")
}
func draftFrame(_ kind: String = "started", text: String, revision: Int = 1, sources: [String] = ["m1"], key: String = "r1") throws -> ConversationEvent {
    let body: [String: JSONValue] = ["type": .string("message_draft_" + kind), "conversation_id": .string("c1"), "draft_id": .string("d1"),
        "response_key": .string(key), "source_message_ids": .array(sources.map(JSONValue.string)), "revision": .number(Double(revision)), "text": .string(text)]
    return try JSONDecoder().decode(ConversationEvent.self, from: JSONEncoder().encode(body))
}
