import Foundation
import Security

/// Where the credential store's one record lives (the app's: a Keychain item). Tests put memory in its place.
protocol CredentialRecord: Sendable {
    /// The record, or nil when there is none.
    func read() throws -> Data?
    /// Replaces the record; done once this returns.
    func write(_ data: Data) throws
    /// Removes the record; a record that is already gone is removed.
    func delete() throws
}

/// The credential store's record as one Keychain item of this device only, never synced or backed up.
struct KeychainRecord: CredentialRecord {
    let service: String
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HostFailure(message: "The Keychain answered \(status).") }
        return data
    }

    func write(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HostFailure(message: "The Keychain answered \(status).") }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HostFailure(message: "The Keychain answered \(status).") }
    }
}

/// A session credential the app keeps. The bearer never leaves this file but for the request it is attached to.
struct StoredBearer: Sendable, CustomStringConvertible {
    let token: String
    let audience: String
    let sessionId: String
    let userId: String
    let email: String
    let expiresAtEpochSeconds: Int64
    var description: String { "StoredBearer([redacted])" }
}

/// A credential to revoke at the server.
struct PendingRevocation: Sendable, CustomStringConvertible {
    let token: String
    let audience: String
    let sessionId: String?
    var description: String { "PendingRevocation([redacted])" }
}

/// The session a product request is made for (no credential in it).
struct SessionLease: Equatable, Sendable {
    let audience: String
    let authorityInstanceId: String
    let generation: Int64
    let sessionId: String

    var json: [String: Any] {
        ["audience": audience, "authorityInstanceId": authorityInstanceId, "generation": generation, "sessionId": sessionId]
    }

    init(audience: String, authorityInstanceId: String, generation: Int64, sessionId: String) {
        self.audience = audience; self.authorityInstanceId = authorityInstanceId
        self.generation = generation; self.sessionId = sessionId
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any], let audience = json["audience"] as? String, !audience.isEmpty,
              let authority = json["authorityInstanceId"] as? String, !authority.isEmpty,
              let session = json["sessionId"] as? String, !session.isEmpty,
              let generation = (json["generation"] as? NSNumber)?.int64Value else { return nil }
        self.init(audience: audience, authorityInstanceId: authority, generation: generation, sessionId: session)
    }
}

/// The bearer for exactly one lease, while that lease is the open one.
struct LeasedBearer: Sendable, CustomStringConvertible {
    let lease: SessionLease
    let token: String
    let epoch: Int64
    var description: String { "LeasedBearer([redacted])" }
}

/// Whose credential the store keeps, without the bearer.
struct StoredIdentity: Equatable, Sendable {
    let userId: String
    let email: String
    let sessionId: String
    let expiresAtEpochSeconds: Int64
}

/**
 * The app's part of the session, as Android's `SessionCustody.kt` and Electron's Main have it. The client core runs
 * the session lifecycle and is its authority; the app keeps what the core must never see:
 *
 * - the bearer, in one Keychain record. The core names credentials by opaque references and asks for the store to be
 *   changed by reference (`vault`, `change`);
 * - a bearer in an auth answer (`keepBearer`): taken out and kept here, the core answered a reference instead;
 * - the gate (`gate`): it follows each snapshot the core publishes and gives the bearer for exactly the current lease
 *   (`acquire`). A 401 shuts it at once (`revoke`), and that generation never opens again.
 *
 * All of it is guarded by one lock; the record is written before a change is answered.
 */
final class SessionCustody: @unchecked Sendable {
    let audience: String
    let authorityInstanceId: String
    private let record: any CredentialRecord

    private struct Issued {
        let token: String
        let credential: StoredBearer?
        let sessionId: String?
        let request: UInt64?
    }

    private let lock = NSRecursiveLock()
    private var loaded = false
    private var unreadable = false
    private var active: StoredBearer?
    private var pending: [PendingRevocation] = []

    private var issued: [String: Issued] = [:]
    private var committed: Set<String> = []
    private var refs: [String: String] = [:]
    private var tokens: [String: String] = [:]

    // The gate.
    private var snapshot: [String: Any]?
    private var revision: Int64 = 0
    private var generation: Int64 = 0
    private var revokedGeneration: Int64 = -1
    private var open: LeasedBearer?
    private var epoch: Int64 = 0

    private static let maxRecordBytes = 1_048_576

    init(record: any CredentialRecord, apiOrigin: String, authorityInstanceId: String = UUID().uuidString) throws {
        self.record = record
        self.audience = try Self.canonicalAudience(apiOrigin)
        self.authorityInstanceId = authorityInstanceId
    }

    // MARK: The store

    private func load() {
        guard !loaded else { return }
        loaded = true
        unreadable = false
        active = nil
        pending = []
        do {
            guard let data = try record.read() else { return }
            guard data.count <= Self.maxRecordBytes,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HostFailure(message: "unreadable") }
            active = (json["active"] as? [String: Any]).flatMap(Self.credential)
            pending = try (json["pending"] as? [[String: Any]] ?? []).map { item in
                guard let token = item["token"] as? String, let audience = item["audience"] as? String else {
                    throw HostFailure(message: "unreadable")
                }
                return PendingRevocation(token: token, audience: audience, sessionId: (item["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        } catch {
            unreadable = true
            active = nil
            pending = []
        }
    }

    private static func credential(_ json: [String: Any]) -> StoredBearer? {
        guard let token = json["token"] as? String, let audience = json["audience"] as? String,
              let sessionId = json["sessionId"] as? String, let userId = json["userId"] as? String,
              let email = json["email"] as? String,
              let expires = (json["expiresAtEpochSeconds"] as? NSNumber)?.int64Value else { return nil }
        return StoredBearer(token: token, audience: audience, sessionId: sessionId, userId: userId, email: email, expiresAtEpochSeconds: expires)
    }

    /// Writes the store; a failure leaves memory as the record is (read again), and throws.
    private func save(_ nextActive: StoredBearer?, _ nextPending: [PendingRevocation]) throws {
        var json: [String: Any] = [:]
        if let it = nextActive {
            json["active"] = ["token": it.token, "audience": it.audience, "sessionId": it.sessionId, "userId": it.userId,
                              "email": it.email, "expiresAtEpochSeconds": it.expiresAtEpochSeconds]
        }
        json["pending"] = nextPending.map { item -> [String: Any] in
            var out: [String: Any] = ["token": item.token, "audience": item.audience]
            if let session = item.sessionId { out["sessionId"] = session }
            return out
        }
        do {
            try record.write(try JSONSerialization.data(withJSONObject: json))
        } catch {
            loaded = false
            throw error
        }
        active = nextActive
        pending = nextPending
        unreadable = false
    }

    private func queued(_ token: String) -> Bool { pending.contains { $0.token == token } }

    private func distinct(_ list: [PendingRevocation]) -> [PendingRevocation] {
        var seen: Set<String> = []
        return list.filter { seen.insert($0.token).inserted }
    }

    private func view() -> [String: Any] {
        if unreadable {
            return ["status": "indeterminate", "problem": ["code": "credential_store_unreadable", "operation": "initialize",
                                                          "recovery": "after_host_change", "retryable": false]]
        }
        var out: [String: Any] = ["status": "readable"]
        out["active"] = active.map { it -> Any in
            ["ref": refFor(it.token), "audience": it.audience, "sessionId": it.sessionId, "userId": it.userId,
             "email": it.email, "expiresAtEpochSeconds": it.expiresAtEpochSeconds]
        } ?? NSNull()
        out["pending"] = pending.map { item -> [String: Any] in
            var entry: [String: Any] = ["ref": refFor(item.token), "audience": item.audience]
            if let session = item.sessionId { entry["sessionId"] = session }
            return entry
        }
        out["cleanup"] = pending.isEmpty ? ["revocation": "idle"] : ["revocation": "pending", "pendingCount": pending.count]
        return out
    }

    /// Whose credential is kept, if any: known before the server confirms its session, and offline.
    func identity() -> StoredIdentity? {
        lock.withLock {
            load()
            guard let it = active, it.audience == audience else { return nil }
            return StoredIdentity(userId: it.userId, email: it.email, sessionId: it.sessionId, expiresAtEpochSeconds: it.expiresAtEpochSeconds)
        }
    }

    /**
     * A credential the app kept before it had this store (an earlier version's Keychain session) becomes the active
     * one. Only when the store has no record yet; true when it was taken.
     */
    @discardableResult
    func adoptEarlier(_ credential: StoredBearer) -> Bool {
        lock.withLock {
            guard (try? record.read()) == .some(nil) else { return false }
            loaded = true
            return (try? save(credential, [])) != nil
        }
    }

    /// The credential store, read again: no bearer in it, each credential by reference.
    func vault() -> [String: Any] {
        lock.withLock {
            loaded = false
            load()
            return view()
        }
    }

    /**
     * A change of the store the core asks for, by reference (`BearerVaultChange`). `quarantine` and `release` answer
     * whether it is done; the others the store after the change, or nil when it changed under the core.
     */
    func change(_ change: [String: Any]) throws -> Any? {
        try lock.withLock {
            load()
            let kind = change["kind"] as? String
            if unreadable && kind != "release" { return nil }
            switch kind {
            case "commit":
                guard let ref = change["issued"] as? String, let credential = issued[ref]?.credential else { return nil }
                let supersede = change["supersede"] as? [String] ?? []
                var retired: [PendingRevocation] = []
                if let current = active, current.token != credential.token {
                    retired.append(PendingRevocation(token: current.token, audience: current.audience, sessionId: current.sessionId))
                }
                for other in supersede {
                    guard let token = issued[other]?.token, token != credential.token else { continue }
                    retired.append(PendingRevocation(token: token, audience: audience, sessionId: issued[other]?.sessionId))
                }
                try save(credential, distinct(pending.filter { $0.token != credential.token } + retired))
                issued[ref] = nil
                committed.insert(ref)
                for other in supersede { issued[other] = nil }
                return view()
            case "adopt":
                guard let current = active, let ref = change["active"] as? String, tokenFor(ref) == current.token,
                      current.audience == audience, let identity = change["identity"] as? [String: Any],
                      let sessionId = identity["sessionId"] as? String, let userId = identity["userId"] as? String,
                      let email = identity["email"] as? String,
                      let expires = (identity["expiresAtEpochSeconds"] as? NSNumber)?.int64Value else { return nil }
                try save(StoredBearer(token: current.token, audience: current.audience, sessionId: sessionId, userId: userId,
                                      email: email, expiresAtEpochSeconds: expires), pending)
                return view()
            case "invalidate":
                guard let current = active, let ref = change["active"] as? String, tokenFor(ref) == current.token else { return nil }
                try save(nil, pending)
                return view()
            case "signOut":
                if let current = active {
                    try save(nil, distinct(pending + [PendingRevocation(token: current.token, audience: current.audience, sessionId: current.sessionId)]))
                }
                return view()
            case "quarantine":
                guard let ref = change["issued"] as? String else { return false }
                return quarantine(ref)
            case "release":
                if let ref = change["issued"] as? String { issued[ref] = nil }
                return true
            case "revoked":
                guard let ref = change["pending"] as? String, let token = tokenFor(ref), queued(token) else { return nil }
                try save(active, pending.filter { $0.token != token })
                return view()
            case "retainAudience":
                open = nil
                try save(active.flatMap { $0.audience == audience ? $0 : nil }, pending.filter { $0.audience == audience })
                return view()
            default:
                return nil
            }
        }
    }

    /**
     * Queues an issued bearer for revocation. The active credential of the session the core shows signed in stays (a
     * probe that reflected it); any other is queued.
     */
    private func quarantine(_ ref: String) -> Bool {
        let known = issued[ref]
        guard let token = known?.token ?? tokenFor(ref) else { return false }
        let current = active
        let shown = (snapshot?["phase"] as? String) == "signed_in"
            ? (snapshot?["session"] as? [String: Any])?["sessionId"] as? String : nil
        if let current, current.token == token, current.sessionId == shown {
            issued[ref] = nil
            return true
        }
        // A credential the store already keeps, named by the core (a reflected bearer): nothing to queue.
        if known == nil && !committed.contains(ref) { return current?.token == token || queued(token) }
        let sessionId = known?.sessionId ?? (current?.token == token ? current?.sessionId : nil)
        do {
            // Queuing the active credential (a sign-in whose commit a newer one overtook) removes it from the store.
            try save(current?.token == token ? nil : current,
                     distinct(pending + [PendingRevocation(token: token, audience: audience, sessionId: sessionId)]))
            issued[ref] = nil
            committed.remove(ref)
            return true
        } catch {
            return false
        }
    }

    /// The core never took the answer to request `request` (it gave the request up): what it carried is queued.
    func dropped(_ request: UInt64) {
        lock.withLock {
            load()
            for (ref, value) in issued where value.request == request { _ = quarantine(ref) }
        }
    }

    /// The core went: every bearer it had not settled is queued for revocation.
    func coreExited() {
        lock.withLock {
            load()
            for ref in Array(issued.keys) { _ = quarantine(ref) }
        }
    }

    /// The bearer `ref` names, for an auth request the core asks the app to make.
    func tokenFor(_ ref: String) -> String? { lock.withLock { issued[ref]?.token ?? tokens[ref] } }

    private func refFor(_ token: String) -> String {
        if let ref = refs[token] { return ref }
        let ref = "cred_\(UUID().uuidString.lowercased())"
        refs[token] = ref
        tokens[ref] = token
        return ref
    }

    /**
     * Takes a bearer out of an auth answer: kept here, the core answered its reference (`credential`). `request` is the
     * core's request that carried it.
     */
    func keepBearer(_ body: Data, request: UInt64) -> Data {
        lock.withLock {
            guard var value = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], value["token"] != nil else { return body }
            let token = value.removeValue(forKey: "token") as? String
            guard let token, !token.isEmpty else { return (try? JSONSerialization.data(withJSONObject: value)) ?? body }
            load()
            // A bearer the store already keeps (a probe that reflected it) is named, not taken into custody again.
            if active?.token == token || queued(token) {
                value["credential"] = refFor(token)
                return (try? JSONSerialization.data(withJSONObject: value)) ?? body
            }
            let user = value["user"] as? [String: Any]
            let sessionId = (value["session_id"] as? String).flatMap { !$0.isEmpty && $0.count <= 256 ? $0 : nil }
            let expiresAt = (value["expires_at"] as? NSNumber)?.int64Value ?? 0
            let userId = user?["id"] as? String ?? ""
            let email = user?["email"] as? String ?? ""
            let credential = sessionId != nil && expiresAt > 0 && !userId.isEmpty && !email.isEmpty
                ? StoredBearer(token: token, audience: audience, sessionId: sessionId!, userId: userId, email: email, expiresAtEpochSeconds: expiresAt)
                : nil
            let ref = refFor(token)
            issued[ref] = Issued(token: token, credential: credential, sessionId: sessionId, request: request)
            value["credential"] = ref
            return (try? JSONSerialization.data(withJSONObject: value)) ?? body
        }
    }

    // MARK: The gate

    /**
     * Where the gate is: the authority a core that starts continues. The first core too: the gate follows only
     * snapshots of this authority, so a core left to name its own would never be given a bearer.
     */
    func resume() -> [String: Any] {
        lock.withLock {
            ["authorityInstanceId": authorityInstanceId, "generation": generation, "revision": revision,
             "sessionId": open?.lease.sessionId ?? NSNull()]
        }
    }

    /**
     * The snapshot the core published and the lease it gives with it (nil: shut), applied in the order told. A
     * snapshot of another authority, an older one, or one whose generation went back shuts the gate. A lease opens only
     * for the active credential when it names the lease's session and audience, at a generation no 401 closed.
     */
    func gate(_ next: [String: Any], lease: SessionLease?) {
        lock.withLock {
            load()
            let authority = (next["authority"] as? [String: Any])?["authorityInstanceId"] as? String
            let nextRevision = (next["revision"] as? NSNumber)?.int64Value ?? -1
            let nextGeneration = (next["generation"] as? NSNumber)?.int64Value ?? -1
            if authority != authorityInstanceId || (snapshot != nil && nextRevision <= revision) || nextGeneration < generation {
                open = nil
                return
            }
            let session = next["session"] as? [String: Any]
            var opens = false
            if let lease, let credential = active, next["phase"] as? String == "signed_in" {
                opens = lease.authorityInstanceId == authorityInstanceId && lease.generation == nextGeneration &&
                    lease.sessionId == session?["sessionId"] as? String && lease.audience == audience &&
                    lease.generation > revokedGeneration && credential.audience == lease.audience &&
                    credential.sessionId == lease.sessionId
            }
            if !opens {
                open = nil
            } else if open?.lease != lease || open?.token != active!.token {
                epoch += 1
                open = LeasedBearer(lease: lease!, token: active!.token, epoch: epoch)
            }
            snapshot = next
            revision = nextRevision
            generation = nextGeneration
        }
    }

    /// The bearer for `lease`, when it is the open one.
    func acquire(_ lease: SessionLease) -> LeasedBearer? { lock.withLock { open?.lease == lease ? open : nil } }

    func isCurrent(_ leased: LeasedBearer) -> Bool { lock.withLock { open?.epoch == leased.epoch } }

    /// The lease open now, if any.
    func current() -> LeasedBearer? { lock.withLock { open } }

    /// A 401 the app saw for `leased`: the gate shuts now, and that generation never opens again.
    func revoke(_ leased: LeasedBearer) -> Bool {
        lock.withLock {
            guard open?.epoch == leased.epoch else { return false }
            revokedGeneration = max(revokedGeneration, leased.lease.generation)
            open = nil
            return true
        }
    }

    /// `scheme://host[:port]` with a default port left out, as the core names an audience.
    static func canonicalAudience(_ origin: String) throws -> String {
        guard let url = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else {
            throw HostFailure(message: "The session audience must be an HTTP(S) origin.")
        }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host.lowercased())\(port.map { ":\($0)" } ?? "")"
    }
}
