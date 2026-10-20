import Foundation
import SQLite3

/**
 * The core's databases: SQLite files in `directory`, one per name, used from the core's thread alone (it is their only
 * writer). Each statement is prepared once and kept. A blob crosses the bridge as `{"$bytes": base64}`.
 */
final class HostSQL: @unchecked Sendable {
    private final class Database {
        let handle: OpaquePointer
        var statements: [String: OpaquePointer] = [:]
        init(handle: OpaquePointer) { self.handle = handle }
    }

    private static let bytesKey = "$bytes"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maxSafeInteger = 9_007_199_254_740_991.0

    private let directory: URL
    private var open: [Int: Database] = [:]
    private var next = 1

    init(directory: URL) { self.directory = directory }

    private func path(_ name: String) throws -> URL {
        guard name.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw HostFailure(message: "not a database name")
        }
        return directory.appendingPathComponent("\(name).sqlite")
    }

    func open(_ name: String) throws -> Int {
        let file: String
        if name == ":memory:" {
            file = ":memory:"
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = try path(name).path
        }
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(file, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let failure = Self.failure(handle, status)
            sqlite3_close_v2(handle)
            throw failure
        }
        let database = Database(handle: handle)
        if name != ":memory:" {
            do {
                // One process at a time, a write-ahead log, as the core's other hosts open theirs.
                try exec(database, "PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
            } catch {
                sqlite3_close_v2(handle)
                throw error
            }
        }
        let id = next
        next += 1
        open[id] = database
        return id
    }

    func exec(_ id: Int, _ sql: String) throws { try exec(try database(id), sql) }

    private func exec(_ database: Database, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database.handle, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard status == SQLITE_OK else {
            throw Self.failure(database.handle, status, error.map { String(cString: $0) })
        }
    }

    /// One statement; how many rows it changed.
    func run(_ id: Int, _ sql: String, _ params: [Any]?) throws -> Int {
        let database = try database(id)
        let statement = try prepared(database, sql, params)
        defer { sqlite3_reset(statement) }
        try step(database, statement) { }
        return Int(sqlite3_changes(database.handle))
    }

    /// One statement's rows, each its columns in order.
    func all(_ id: Int, _ sql: String, _ params: [Any]?) throws -> [[Any]] {
        let database = try database(id)
        let statement = try prepared(database, sql, params)
        defer { sqlite3_reset(statement) }
        var rows: [[Any]] = []
        let columns = sqlite3_column_count(statement)
        try step(database, statement) {
            var row: [Any] = []
            row.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    let data = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count)
                    row.append([Self.bytesKey: data.base64EncodedString()])
                default: row.append(NSNull())
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func step(_ database: Database, _ statement: OpaquePointer, row: () -> Void) throws {
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { row(); continue }
            if status == SQLITE_DONE { return }
            throw Self.failure(database.handle, status)
        }
    }

    func close(_ id: Int) {
        guard let database = open.removeValue(forKey: id) else { return }
        for statement in database.statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(database.handle)
    }

    /// A database gone from the device: its files deleted.
    func delete(_ name: String) throws {
        let file = try path(name)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + suffix))
        }
    }

    func closeAll() {
        for id in Array(open.keys) { close(id) }
    }

    private func database(_ id: Int) throws -> Database {
        guard let database = open[id] else { throw HostFailure(message: "the database is closed") }
        return database
    }

    private func prepared(_ database: Database, _ sql: String, _ params: [Any]?) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let kept = database.statements[sql] {
            statement = kept
        } else {
            var made: OpaquePointer?
            let status = sqlite3_prepare_v3(database.handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &made, nil)
            guard status == SQLITE_OK, let made else { throw Self.failure(database.handle, status) }
            database.statements[sql] = made
            statement = made
        }
        sqlite3_clear_bindings(statement)
        for (index, value) in (params ?? []).enumerated() {
            let at = Int32(index + 1)
            switch value {
            case is NSNull: sqlite3_bind_null(statement, at)
            case let text as String: sqlite3_bind_text(statement, at, text, -1, Self.transient)
            case let number as NSNumber:
                let double = number.doubleValue
                if CFGetTypeID(number) != CFBooleanGetTypeID(), double == double.rounded(), abs(double) <= Self.maxSafeInteger {
                    sqlite3_bind_int64(statement, at, number.int64Value)
                } else if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    sqlite3_bind_int64(statement, at, number.boolValue ? 1 : 0)
                } else {
                    sqlite3_bind_double(statement, at, double)
                }
            case let object as [String: Any]:
                guard let encoded = object[Self.bytesKey] as? String, let data = Data(base64Encoded: encoded) else {
                    throw HostFailure(message: "not a value SQLite takes")
                }
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, at, $0.baseAddress, Int32(data.count), Self.transient) }
            default:
                throw HostFailure(message: "not a value SQLite takes")
            }
        }
        return statement
    }

    private static func failure(_ handle: OpaquePointer?, _ status: Int32, _ detail: String? = nil) -> HostFailure {
        let message = detail ?? handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite failed (\(status))"
        let primary = status & 0xff
        let kind: String? = primary == SQLITE_FULL ? "full" : primary == SQLITE_BUSY || primary == SQLITE_LOCKED ? "busy" : nil
        return HostFailure(message: message, kind: kind)
    }
}
