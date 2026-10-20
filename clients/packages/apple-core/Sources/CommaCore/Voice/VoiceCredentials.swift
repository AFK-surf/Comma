import Foundation
import Security

/// Where and how one call connects. No generated description can expose the bearer.
public struct VoiceEndpoint: Sendable, Equatable, CustomStringConvertible {
    public let sessionsURL: URL
    public let readinessURL: URL
    public let bearer: String

    public init(sessionsURL: String, readinessURL: String, bearer: String) throws {
        guard let sessions = Self.url(sessionsURL, schemes: ["wss", "ws"]),
              let readiness = Self.url(readinessURL, schemes: ["https", "http"]),
              !bearer.isEmpty, bearer.utf8.count <= 16_384,
              bearer.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw VoiceFailure(.unavailable)
        }
        self.sessionsURL = sessions; self.readinessURL = readiness; self.bearer = bearer
    }

    public var description: String { "VoiceEndpoint([redacted])" }

    /// Plain-text `ws`/`http` only for loopback development servers.
    private static func url(_ value: String, schemes: [String]) -> URL? {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(), schemes.contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        if scheme == schemes[1], !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return nil }
        return parts.url
    }
}

public struct VoiceFailure: Error, Equatable, Sendable {
    public let result: VoiceCallResult
    public let networkCode: Int?
    public init(_ result: VoiceCallResult, networkCode: Int? = nil) {
        self.result = result
        self.networkCode = networkCode
    }
}

/// A device voice key, bound to the account, Auth Session and Workspace that minted it.
public struct VoiceKeyRecord: Codable, Sendable, Equatable, CustomStringConvertible {
    public let accountID: String
    public let sessionID: String
    public let workspaceID: String
    public let keyID: String
    /// Epoch seconds.
    public let expiresAt: Int
    let sessionsURL: String
    let readinessURL: String
    let key: String

    public var description: String { "VoiceKeyRecord([redacted])" }
    public func endpoint() throws -> VoiceEndpoint { try VoiceEndpoint(sessionsURL: sessionsURL, readinessURL: readinessURL, bearer: key) }

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", sessionID = "session_id", workspaceID = "workspace_id", keyID = "key_id"
        case expiresAt = "expires_at", sessionsURL = "sessions_url", readinessURL = "readiness_url", key
    }
}

public protocol VoiceKeyStore: Sendable {
    func read() throws -> VoiceKeyRecord?
    func write(_ record: VoiceKeyRecord) throws
    func clear() throws
}

/// This device only, never synchronized or backed up, separate from the session credential.
public struct KeychainVoiceKeyStore: VoiceKeyStore {
    public let service: String
    public let account: String
    public init(service: String = "surf.comma.ios.voice-key", account: String) { self.service = service; self.account = account }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    public func read() throws -> VoiceKeyRecord? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw CommaError.credentialStorage(status) }
        return try JSONDecoder().decode(VoiceKeyRecord.self, from: data)
    }

    public func write(_ record: VoiceKeyRecord) throws {
        let data = try JSONEncoder().encode(record)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CommaError.credentialStorage(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CommaError.credentialStorage(status) }
    }
}

/// What a call needs from its credential owner.
public protocol VoiceCredentialSource: Sendable {
    func endpoint() async throws -> VoiceEndpoint
    /// Retires the key the last `endpoint()` returned, after the server refused it.
    func invalidate() async
}

/// A thirty-day device key, replaced before a call when fewer than three days remain.
/// Routers cannot mint voice keys; only the signed-in member's session does (docs/messaging-voice.md#voice-agent-api-keys).
public actor VoiceKeyCredentials {
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let renewal: TimeInterval = 3 * 24 * 60 * 60
    private let client: CommaClient
    private let store: any VoiceKeyStore
    private let now: @Sendable () -> Date
    private var issued: VoiceKeyRecord?

    public init(client: CommaClient, store: any VoiceKeyStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client; self.store = store; self.now = now
    }

    /// The source a call in `workspaceID` uses.
    public nonisolated func source(workspaceID: String) -> any VoiceCredentialSource {
        WorkspaceVoiceCredentials(owner: self, workspaceID: workspaceID)
    }

    public func endpoint(workspaceID: String) async throws -> VoiceEndpoint {
        do {
            guard let session = await client.session else { throw VoiceFailure(.credentialsExpired) }
            let saved = try store.read()
            if let saved, saved.accountID == session.user.id, saved.sessionID == session.id, saved.workspaceID == workspaceID,
               TimeInterval(saved.expiresAt) > now().timeIntervalSince1970 + Self.renewal {
                issued = saved
                return try saved.endpoint()
            }
            let record = try await client.mintVoiceKey(workspaceID: workspaceID,
                                                       expiresAt: now().addingTimeInterval(Self.lifetime), now: now())
            guard await client.session?.id == session.id, record.sessionID == session.id else {
                await retire(record)
                throw VoiceFailure(.credentialsExpired)
            }
            do { try store.write(record) } catch { await retire(record); throw error }
            // The replaced key is now unused; the new one is already saved, so a failure here only leaves it to expire.
            if let saved, saved.keyID != record.keyID, saved.accountID == session.user.id { await retire(saved) }
            issued = record
            return try record.endpoint()
        } catch let failure as VoiceFailure { throw failure }
        catch CommaError.http(let status, _, _) { throw VoiceFailure(VoiceProtocol.result(code: status) == .ended ? .unavailable : VoiceProtocol.result(code: status)) }
        catch CommaError.staleSession, CommaError.notSignedIn { throw VoiceFailure(.credentialsExpired) }
        catch CommaError.transport { throw VoiceFailure(.interrupted) }
        catch { throw VoiceFailure(.unavailable) }
    }

    public func invalidate() async {
        guard let issued else { return }
        self.issued = nil
        if (try? store.read())?.keyID == issued.keyID { try? store.clear() }
        await retire(issued)
    }

    /// Sign-out: deletes this device's key while the session can still authorize it, then forgets it.
    public func revokeStored() async {
        let saved = try? store.read()
        issued = nil
        try? store.clear()
        if let saved, await client.session?.id == saved.sessionID { await retire(saved) }
    }

    /// The session ended elsewhere: its key can no longer be deleted from here, and expires on its own.
    public func forget() {
        issued = nil
        try? store.clear()
    }

    private func retire(_ record: VoiceKeyRecord) async {
        try? await client.deleteVoiceKey(workspaceID: record.workspaceID, keyID: record.keyID)
    }
}

private struct WorkspaceVoiceCredentials: VoiceCredentialSource {
    let owner: VoiceKeyCredentials
    let workspaceID: String
    func endpoint() async throws -> VoiceEndpoint { try await owner.endpoint(workspaceID: workspaceID) }
    func invalidate() async { await owner.invalidate() }
}

/// The voice integration status a member's session reads; it never spends a voice credential.
public struct VoiceIntegrationStatus: Decodable, Sendable, Equatable {
    public struct Readiness: Decodable, Sendable, Equatable {
        public let ready: Bool
        public let reason: String?
    }
    public let readiness: Readiness?

    /// In-app calls. The readiness also covers calling in by phone, so a platform without phone lines
    /// reports not ready even though the voice service itself is up.
    public var callsAvailable: Bool {
        guard let readiness else { return false }
        return readiness.ready || ["twilio_not_configured", "no_platform_lines"].contains(readiness.reason ?? "")
    }
}

extension CommaClient {
    public func voiceStatus(workspaceID: String) async throws -> VoiceIntegrationStatus {
        try await json("GET", ["workspaces", workspaceID, "integrations", "voice"])
    }

    /// Once sent, the request completes even if the caller or a backgrounding suspend cancels:
    /// the response holds the only copy of the key, and a lost one would leave an unknown live key.
    func mintVoiceKey(workspaceID: String, expiresAt: Date, now: Date) async throws -> VoiceKeyRecord {
        guard let session else { throw CommaError.notSignedIn }
        let formatter = ISO8601DateFormatter()
        let body = try JSONEncoder().encode(["name": JSONValue.string("iOS voice calls"),
                                             "expires_at": .string(formatter.string(from: expiresAt))])
        let response = try await unsuspendable("POST", ["workspaces", workspaceID, "voice-api-keys"], body: body)
        let raw = try decode([String: JSONValue].self, data: response.data)
        guard let keyID = raw["key_id"]?.string, !keyID.isEmpty else { throw CommaError.invalidResponse }
        let record: VoiceKeyRecord
        do {
            guard let key = raw["key"]?.string, let sessions = raw["sessions_url"]?.string,
                  let readiness = raw["readiness_url"]?.string, let expiry = raw["expires_at"]?.number,
                  expiry > now.timeIntervalSince1970, expiry <= expiresAt.timeIntervalSince1970 + 1 else {
                throw CommaError.invalidResponse
            }
            record = VoiceKeyRecord(accountID: session.user.id, sessionID: session.id, workspaceID: workspaceID, keyID: keyID,
                                    expiresAt: Int(expiry), sessionsURL: sessions, readinessURL: readiness, key: key)
            _ = try record.endpoint()
        } catch {
            try? await deleteVoiceKey(workspaceID: workspaceID, keyID: keyID)
            throw CommaError.invalidResponse
        }
        return record
    }

    func deleteVoiceKey(workspaceID: String, keyID: String) async throws {
        _ = try await unsuspendable("DELETE", ["workspaces", workspaceID, "voice-api-keys", keyID], body: nil)
    }

    private func unsuspendable(_ method: String, _ path: [String], body: Data?) async throws -> HTTPResponse {
        let request = try makeRequest(method, path, query: [], body: body)
        let transport = self.transport
        // An unstructured task: cancelling the awaiting caller does not cancel the request.
        let response: HTTPResponse
        do { response = try await Task { try await transport.data(for: request) }.value }
        catch let typed as CommaError { throw typed }
        catch { throw CommaError.transport }
        try validateHTTP(response, authenticated: true)
        return response
    }
}
