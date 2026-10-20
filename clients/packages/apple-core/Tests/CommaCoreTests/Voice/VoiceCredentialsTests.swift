import Foundation
import Testing
@testable import CommaCore

final class MemoryVoiceKeys: VoiceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: VoiceKeyRecord?
    init(_ value: VoiceKeyRecord? = nil) { self.value = value }
    var saved: VoiceKeyRecord? { lock.withLock { value } }
    func read() throws -> VoiceKeyRecord? { lock.withLock { value } }
    func write(_ record: VoiceKeyRecord) throws { lock.withLock { value = record } }
    func clear() throws { lock.withLock { value = nil } }
}

@Suite("Voice device keys")
struct VoiceCredentialsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func signedIn(_ responses: [HTTPResponse]) async throws -> (CommaClient, FixtureTransport) {
        let store = MemoryCredentials()
        try storedSession(store)
        let transport = FixtureTransport([response(sessionJSON)] + responses)
        let client = try CommaClient(baseURL: URL(string: origin)!, credentialStore: store, transport: transport)
        _ = try await client.restoreSession()
        return (client, transport)
    }

    private func issued(_ id: String, expiresAt: Int) -> HTTPResponse {
        response(#"{"key_id":"\#(id)","key":"salix_vk_\#(id)","expires_at":\#(expiresAt),"name":"iOS voice calls","#
                 + #""sessions_url":"wss://voice.comma.test/v1/agent-groups/g1/voice/sessions","#
                 + #""readiness_url":"https://voice.comma.test/v1/agent-groups/g1/voice"}"#, status: 201)
    }

    private func record(_ id: String, expiresIn days: Double, session: String = "s1") -> VoiceKeyRecord {
        VoiceKeyRecord(accountID: "u1", sessionID: session, workspaceID: "w1", keyID: id,
                       expiresAt: Int(now.timeIntervalSince1970 + days * 86_400),
                       sessionsURL: "wss://voice.comma.test/s", readinessURL: "https://voice.comma.test/r", key: "salix_vk_" + id)
    }

    @Test func mintsAThirtyDayKeyOnceAndReusesIt() async throws {
        let expiry = Int(now.timeIntervalSince1970) + 30 * 86_400
        let (client, transport) = try await signedIn([issued("k1", expiresAt: expiry)])
        let keys = MemoryVoiceKeys()
        let credentials = VoiceKeyCredentials(client: client, store: keys, now: { [now] in now })
        let first = try await credentials.endpoint(workspaceID: "w1")
        let second = try await credentials.endpoint(workspaceID: "w1")
        #expect(first == second && first.bearer == "salix_vk_k1")
        #expect("\(first)" == "VoiceEndpoint([redacted])")

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[1].httpMethod == "POST" && requests[1].url?.path == "/v1/comma/workspaces/w1/voice-api-keys")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(requests[1].httpBody))
        #expect(ISO8601DateFormatter().date(from: body["expires_at"] ?? "")?.timeIntervalSince1970 == TimeInterval(expiry))
        #expect(keys.saved?.keyID == "k1" && keys.saved?.sessionID == "s1")
    }

    @Test func renewsAKeyNearExpiryAndDeletesTheOldOne() async throws {
        let (client, transport) = try await signedIn([issued("k2", expiresAt: Int(now.timeIntervalSince1970) + 30 * 86_400), response("{\"deleted\":true}")])
        let keys = MemoryVoiceKeys(record("k1", expiresIn: 2))
        let credentials = VoiceKeyCredentials(client: client, store: keys, now: { [now] in now })
        #expect(try await credentials.endpoint(workspaceID: "w1").bearer == "salix_vk_k2")
        let requests = await transport.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "DELETE"])
        #expect(requests[2].url?.path == "/v1/comma/workspaces/w1/voice-api-keys/k1")
        #expect(keys.saved?.keyID == "k2")
    }

    @Test func aKeyFromAnotherSessionIsNotUsed() async throws {
        let (client, _) = try await signedIn([issued("k2", expiresAt: Int(now.timeIntervalSince1970) + 30 * 86_400)])
        let keys = MemoryVoiceKeys(record("k1", expiresIn: 20, session: "old"))
        let credentials = VoiceKeyCredentials(client: client, store: keys, now: { [now] in now })
        #expect(try await credentials.endpoint(workspaceID: "w1").bearer == "salix_vk_k2")
    }

    @Test func anUnusableIssuedKeyIsDeletedAndNotSaved() async throws {
        let bad = response(#"{"key_id":"k9","key":"salix_vk_k9","expires_at":1,"sessions_url":"wss://v/s","readiness_url":"https://v/r"}"#, status: 201)
        let (client, transport) = try await signedIn([bad, response("{\"deleted\":true}")])
        let keys = MemoryVoiceKeys()
        let credentials = VoiceKeyCredentials(client: client, store: keys, now: { [now] in now })
        await #expect(throws: VoiceFailure(.unavailable)) { try await credentials.endpoint(workspaceID: "w1") }
        #expect(await transport.requests().last?.url?.path == "/v1/comma/workspaces/w1/voice-api-keys/k9")
        #expect(keys.saved == nil)
    }

    @Test func invalidateAndSignOutDeleteTheKey() async throws {
        let (client, transport) = try await signedIn([response("{\"deleted\":true}"), response("{\"deleted\":true}")])
        let keys = MemoryVoiceKeys(record("k1", expiresIn: 20))
        let credentials = VoiceKeyCredentials(client: client, store: keys, now: { [now] in now })
        _ = try await credentials.endpoint(workspaceID: "w1")
        await credentials.invalidate()
        #expect(keys.saved == nil)
        try keys.write(record("k2", expiresIn: 20))
        await credentials.revokeStored()
        #expect(keys.saved == nil)
        #expect(await transport.requests().compactMap(\.url?.path).suffix(2) == [
            "/v1/comma/workspaces/w1/voice-api-keys/k1", "/v1/comma/workspaces/w1/voice-api-keys/k2"])
    }

    @Test func inAppCallsIgnorePhoneOnlyReadiness() throws {
        func status(_ json: String) throws -> VoiceIntegrationStatus { try JSONDecoder().decode(VoiceIntegrationStatus.self, from: Data(json.utf8)) }
        #expect(try status(#"{"readiness":{"ready":true,"reason":null}}"#).callsAvailable)
        #expect(try status(#"{"readiness":{"ready":false,"reason":"no_platform_lines"}}"#).callsAvailable)
        #expect(try !status(#"{"readiness":{"ready":false,"reason":"disabled"}}"#).callsAvailable)
        #expect(try !status(#"{}"#).callsAvailable)
    }
}
