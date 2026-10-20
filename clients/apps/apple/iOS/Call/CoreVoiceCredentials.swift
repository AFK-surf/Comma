import CommaCore
import Foundation

/// Whom a voice key is for: the signed-in account's session, in its Workspace.
struct VoiceAccess: Equatable, Sendable {
    let accountID: String
    let sessionID: String
    let workspaceID: String
}

/**
 * A thirty-day device voice key, made through the client core (`voice.createKey`) and replaced before a call when fewer
 * than three days remain, as Android's `VoiceKeyCredentials` does. A key this phone no longer uses is deleted at once
 * (`voice.deleteKey`); one that cannot be deleted then (offline) ends on its own when it expires, and this phone no
 * longer holds it.
 */
actor CoreVoiceCredentials {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let renewal: TimeInterval = 3 * 24 * 60 * 60

    private let core: any CoreAPI
    private let store: any VoiceKeyStore
    private let access: @Sendable () async -> VoiceAccess?
    private let now: @Sendable () -> Date
    private var issued: VoiceKeyRecord?

    init(core: any CoreAPI, store: any VoiceKeyStore, access: @escaping @Sendable () async -> VoiceAccess?,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.core = core; self.store = store; self.access = access; self.now = now
    }

    /// The source a call uses.
    nonisolated func source() -> any VoiceCredentialSource { Source(owner: self) }

    func endpoint() async throws -> VoiceEndpoint {
        do {
            guard let owner = await access() else { throw VoiceFailure(.credentialsExpired) }
            let saved = try store.read()
            if let saved, saved.accountID == owner.accountID, saved.sessionID == owner.sessionID, saved.workspaceID == owner.workspaceID,
               TimeInterval(saved.expiresAt) > now().timeIntervalSince1970 + Self.renewal {
                issued = saved
                return try saved.endpoint()
            }
            // Once a mint starts, its one-time answer is taken even if the caller hangs up, so the key is not lost.
            return try await Task { try await mint(owner, replacing: saved) }.value
        } catch let failure as VoiceFailure {
            throw failure
        } catch let error as CoreError {
            throw VoiceFailure(error.status.map { VoiceProtocol.result(code: $0) == .ended ? .unavailable : VoiceProtocol.result(code: $0) }
                ?? (error.code == "network" || error.code == "timeout" ? .interrupted : .unavailable))
        } catch {
            throw VoiceFailure(.unavailable)
        }
    }

    private func mint(_ owner: VoiceAccess, replacing saved: VoiceKeyRecord?) async throws -> VoiceEndpoint {
        let expiry = Int(now().addingTimeInterval(Self.lifetime).timeIntervalSince1970)
        let answer = try await core.object("voice.createKey", ["workspace": owner.workspaceID, "name": "iOS voice calls",
                                                               "expiresAt": expiry])
        let keyID = answer.string("key_id") ?? ""
        let record: VoiceKeyRecord
        do {
            guard !keyID.isEmpty, let expiresAt = answer.int("expires_at"), expiresAt > Int(now().timeIntervalSince1970),
                  expiresAt <= expiry + 1, let key = answer.string("key"), let sessions = answer.string("sessions_url"),
                  let readiness = answer.string("readiness_url") else { throw VoiceFailure(.unavailable) }
            let json: [String: Any] = ["account_id": owner.accountID, "session_id": owner.sessionID, "workspace_id": owner.workspaceID,
                                       "key_id": keyID, "expires_at": expiresAt, "sessions_url": sessions,
                                       "readiness_url": readiness, "key": key]
            record = try JSONDecoder().decode(VoiceKeyRecord.self, from: JSONSerialization.data(withJSONObject: json))
            _ = try record.endpoint()
        } catch {
            if !keyID.isEmpty { await delete(owner.workspaceID, keyID) }
            throw VoiceFailure(.unavailable)
        }
        // The account or its session changed while the key was made: it is no one's here.
        guard await access() == owner else {
            await delete(record.workspaceID, record.keyID)
            throw VoiceFailure(.credentialsExpired)
        }
        do { try store.write(record) } catch {
            await delete(record.workspaceID, record.keyID)
            throw error
        }
        if let saved, saved.keyID != record.keyID { await delete(saved.workspaceID, saved.keyID) }
        issued = record
        return try record.endpoint()
    }

    /// The server refused the key the last `endpoint()` returned: it goes.
    func invalidate() async {
        guard let record = issued else { return }
        issued = nil
        guard (try? store.read())?.keyID == record.keyID else { return }
        try? store.clear()
        await delete(record.workspaceID, record.keyID)
    }

    /// Deletes this phone's key at the server, before the session that made it ends; the phone forgets it either way.
    func retire() async {
        let record = try? store.read()
        issued = nil
        try? store.clear()
        if let record { await delete(record.workspaceID, record.keyID) }
    }

    /// The session ended elsewhere: its key can no longer be deleted from here, and expires on its own.
    func forget() {
        issued = nil
        try? store.clear()
    }

    private func delete(_ workspaceID: String, _ keyID: String) async {
        // It expires on its own when this fails; nothing here holds it any more.
        _ = try? await core.call("voice.deleteKey", ["workspace": workspaceID, "key": keyID])
    }

    private struct Source: VoiceCredentialSource {
        let owner: CoreVoiceCredentials
        func endpoint() async throws -> VoiceEndpoint { try await owner.endpoint() }
        func invalidate() async { await owner.invalidate() }
    }
}

extension CommaStore {
    /// Whether the Workspace shown can take voice calls, from its voice integration status (the core's `voice` topic);
    /// nil when that is not known (signed out, offline, or the read failed). It never touches a voice credential.
    func voiceCallsAvailable(workspace: Workspace) async -> Bool? {
        let id = workspace.id
        return await core.first(["topic": "voice", "prefer": id]) { value -> Bool? in
            guard let json = value as? NSDictionary, json.string("workspace") == id else { return nil }
            if json.bool("integrationError") { return false }
            guard let readiness = json.object("integration")?.object("readiness") else { return nil }
            // The readiness also covers calling in by phone: a platform without phone lines still takes app calls.
            return readiness.bool("ready") || ["twilio_not_configured", "no_platform_lines"].contains(readiness.string("reason") ?? "")
        }
    }
}
