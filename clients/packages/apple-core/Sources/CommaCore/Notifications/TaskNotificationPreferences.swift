import Foundation

// The device-local notification choice and the store that persists it.

public struct TaskNotificationRecord: Codable, Equatable, Sendable {
    public var intent: Bool
    public var retirementRequested: Bool
    public var registrationSessionID: String?
    public var registrationID: String?
    public var workspaceID: String?
    public var groupID: String?
    public var fullAuthorizationRequested: Bool?
    public init(intent: Bool, retirementRequested: Bool = false, registrationID: String? = nil, workspaceID: String? = nil, groupID: String? = nil, registrationSessionID: String? = nil, fullAuthorizationRequested: Bool? = nil) {
        self.intent = intent; self.retirementRequested = retirementRequested
        self.registrationSessionID = registrationSessionID
        self.registrationID = registrationID; self.workspaceID = workspaceID; self.groupID = groupID
        self.fullAuthorizationRequested = fullAuthorizationRequested
    }
}

@MainActor public protocol TaskNotificationPreferences: AnyObject {
    func load(key: String) throws -> TaskNotificationRecord?
    func save(_ record: TaskNotificationRecord, key: String) throws
    func remove(key: String) throws
}

/// Device-local, excluded from backup. Holds intent, requested options and public registration/scope IDs;
/// no bearer, APNs token, user content or cross-device synchronization.
@MainActor public final class FileTaskNotificationPreferences: TaskNotificationPreferences {
    private let url: URL
    public init(url: URL) { self.url = url }
    private func records() throws -> [String: TaskNotificationRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: TaskNotificationRecord].self, from: Data(contentsOf: url))
    }
    public func load(key: String) throws -> TaskNotificationRecord? { try records()[key] }
    public func save(_ record: TaskNotificationRecord, key: String) throws {
        var values = try records(); values[key] = record; try write(values)
    }
    public func remove(key: String) throws {
        var values = try records(); values.removeValue(forKey: key); try write(values)
    }
    private func write(_ records: [String: TaskNotificationRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var value = url
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try value.setResourceValues(resources)
    }
}
