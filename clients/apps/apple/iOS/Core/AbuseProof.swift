import CryptoKit
import DeviceCheck
import Foundation
import Security

protocol AppAttestProvider: Sendable {
    var supported: Bool { get }
    func generateKey() async throws -> String
    func attest(_ key: String, hash: Data) async throws -> Data
    func assert(_ key: String, hash: Data) async throws -> Data
}

struct AppleAppAttestProvider: AppAttestProvider {
    var supported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { key, error in
                if let key { continuation.resume(returning: key) }
                else { continuation.resume(throwing: error ?? HostFailure(message: "App Attest key is unavailable.")) }
            }
        }
    }
    func attest(_ key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(key, clientDataHash: hash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? HostFailure(message: "App Attest attestation is unavailable.")) }
            }
        }
    }
    func assert(_ key: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(key, clientDataHash: hash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? HostFailure(message: "App Attest assertion is unavailable.")) }
            }
        }
    }
}

protocol AppAttestRecords: Sendable {
    func read(_ account: String) throws -> [String: Any]?
    func write(_ account: String, _ record: [String: Any]) throws
}

/// App Attest identifiers are verification material, scoped to one backend, target, and Apple environment.
final class AbuseProof: @unchecked Sendable {
    private let lock = NSLock()
    private var activeScopes: Set<String> = []
    private let service: any AppAttestProvider
    private let records: any AppAttestRecords

    init(service: any AppAttestProvider = AppleAppAttestProvider(), records: any AppAttestRecords = KeychainAppAttestRecords()) {
        self.service = service
        self.records = records
    }

    static func digest(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    func request(_ challenge: [String: Any], audience: String) async throws -> [String: Any] {
        guard service.supported, let id = challenge["id"] as? String,
              let secret = challenge["secret"] as? String, let target = challenge["email"] as? String,
              let environment = challenge["apple_environment"] as? String,
              ["development", "production"].contains(environment) else {
            throw HostFailure(message: "App Attest is unavailable.")
        }
        let scope = try JSONSerialization.data(withJSONObject: [audience, target, environment])
        let account = Data(SHA256.hash(data: scope)).base64EncodedString()
        guard lock.withLock({ activeScopes.insert(account).inserted }) else {
            throw HostFailure(message: "App Attest is already in progress for this target.")
        }
        defer { _ = lock.withLock { activeScopes.remove(account) } }
        var record = try records.read(account)
        if record == nil {
            let key = try await service.generateKey()
            record = ["key": key, "attested": false]
            try records.write(account, record!)
        }
        let key = record!["key"] as! String
        let hash = Self.digest("comma-abuse:\(id):\(secret)")
        try Task.checkCancellation()
        if record!["attested"] as? Bool == true {
            let assertion = try await service.assert(key, hash: hash)
            try Task.checkCancellation()
            return ["provider": "apple", "apple": ["key_id": key, "assertion": assertion.base64EncodedString()]]
        }
        let attestation = try await service.attest(key, hash: hash)
        // Keep the identifier even if this operation or the server response is lost. Never generate keys on a transient error.
        try records.write(account, ["key": key, "attested": true])
        try Task.checkCancellation()
        return ["provider": "apple", "apple": ["key_id": key, "attestation": attestation.base64EncodedString()]]
    }

}

struct KeychainAppAttestRecords: AppAttestRecords {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "surf.comma.app-attest",
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) throws -> [String: Any]? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try JSONSerialization.jsonObject(with: data) as? [String: Any], record["key"] is String else {
            throw HostFailure(message: "App Attest key storage is unavailable.")
        }
        return record
    }

    func write(_ account: String, _ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record)
        let query = query(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HostFailure(message: "App Attest key storage is unavailable.") }
    }
}
