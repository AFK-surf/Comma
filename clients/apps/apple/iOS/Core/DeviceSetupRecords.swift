import Foundation

/// The Keychain owns each secret record. SQLite indexes only its scope, device id and pending flag.
final class DeviceSetupRecords: @unchecked Sendable {
    private let lock = NSLock()
    private let sql: HostSQL
    private var database: Int?
    private var cursors: [String: String] = [:]
    private let recordFor: @Sendable (String) -> any CredentialRecord
    init(directory: URL, recordFor: @escaping @Sendable (String) -> any CredentialRecord = {
        KeychainRecord(service: "surf.comma.device-setup", account: $0)
    }) { sql = HostSQL(directory: directory); self.recordFor = recordFor }

    deinit { sql.closeAll() }

    private static func text(_ values: [String]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self) }

    func call(_ op: String, _ input: [String: Any]) throws -> Any {
        try lock.withLock {
            if database == nil {
                let db = try sql.open("paired-device-index")
                try sql.exec(db, "CREATE TABLE IF NOT EXISTS paired(scope TEXT NOT NULL, id TEXT NOT NULL, pending INTEGER NOT NULL, PRIMARY KEY(scope,id)); CREATE INDEX IF NOT EXISTS paired_pending ON paired(scope,pending,id)")
                database = db
            }
            let db = database!
            let scope = try Self.text([input["audience"] as? String ?? "", input["account"] as? String ?? "", input["workspace"] as? String ?? ""])
            func item(_ id: String) throws -> any CredentialRecord { recordFor(try Self.text([scope, id])) }
            if op == "put" {
                guard let record = input["record"] as? [String: Any], let id = record["deviceId"] as? String,
                      record["connectorToken"] is String, record["voiceKeyId"] is String else { throw HostFailure(message: "Invalid revocation record") }
                let bytes = try JSONSerialization.data(withJSONObject: record)
                // Index first: an interrupted Keychain write must not leave an undiscoverable record.
                _ = try sql.run(db, "INSERT INTO paired(scope,id,pending) VALUES(?,?,?) ON CONFLICT(scope,id) DO UPDATE SET pending=excluded.pending", [scope, id, 1])
                try item(id).write(bytes)
                if record["confirmed"] as? Bool == true { _ = try sql.run(db, "UPDATE paired SET pending=0 WHERE scope=? AND id=?", [scope, id]) }
                return NSNull()
            }
            let device = input["deviceId"] as? String
            if op == "remove", let device {
                try item(device).delete()
                _ = try sql.run(db, "DELETE FROM paired WHERE scope=? AND id=?", [scope, device])
                return NSNull()
            }
            guard op == "records" else { throw HostFailure(message: "Unknown revocation record operation") }
            let rows: [[Any]]
            if let device { rows = try sql.all(db, "SELECT id FROM paired WHERE scope=? AND id=?", [scope, device]) }
            else {
                rows = try sql.all(db, "SELECT id FROM paired WHERE scope=? AND pending=1 AND id>? ORDER BY id LIMIT 20", [scope, cursors[scope] ?? ""])
                cursors[scope] = rows.count == 20 ? rows.last?.first as? String : ""
            }
            return try rows.compactMap { row -> [String: Any]? in
                guard let id = row.first as? String, let bytes = try item(id).read() else { return nil }
                return try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? [String: Any]
            }
        }
    }
}
