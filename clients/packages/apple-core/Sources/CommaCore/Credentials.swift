import Foundation
import Security

/// Persisted only by the credential owner. Never send this value to widgets or WatchConnectivity.
public struct StoredCredential: Codable, Sendable {
    public let origin: String
    public let token: String
    public let session: CommaSession
    public init(origin: String, token: String, session: CommaSession) {
        self.origin = origin; self.token = token; self.session = session
    }
}

public protocol CredentialStore: Sendable {
    func load(origin: String) throws -> StoredCredential?
    func save(_ credential: StoredCredential) throws
    func delete(origin: String) throws
}

public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public init(service: String) { self.service = service }

    private func query(origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: origin,
         kSecAttrSynchronizable as String: false]
    }

    public func load(origin: String) throws -> StoredCredential? {
        var query = query(origin: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CommaError.credentialStorage(status) }
        let credential = try JSONDecoder().decode(StoredCredential.self, from: data)
        guard credential.origin == origin else { throw CommaError.originMismatch }
        return credential
    }

    public func save(_ credential: StoredCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query = query(origin: credential.origin)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CommaError.credentialStorage(status) }
    }

    public func delete(origin: String) throws {
        let status = SecItemDelete(query(origin: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CommaError.credentialStorage(status) }
    }
}
