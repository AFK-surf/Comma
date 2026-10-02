import Foundation
import Observation

/// Ordinary alerts only. ActivityKit and push-to-start do not share this consent.
public protocol DeviceNotificationTransport: Sendable {
    var sessionID: String { get }
    var accountID: String { get }
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration
    func retire() async throws
}

struct SessionDeviceNotificationChannel: DeviceNotificationTransport {
    let sessionID: String
    let accountID: String
    let registerOperation: @Sendable (String, PushEnvironment, Workspace, String, String) async throws -> NotificationRegistration
    let retireOperation: @Sendable () async throws -> Void
    func register(token: String, environment: PushEnvironment, workspace: Workspace, bundleID: String, locale: String) async throws -> NotificationRegistration {
        try await registerOperation(token, environment, workspace, bundleID, locale)
    }
    func retire() async throws { try await retireOperation() }
}

public struct TaskNotificationPermission: Equatable, Sendable {
    public enum Authorization: Equatable, Sendable { case notDetermined, denied, allowed }
    public let authorization: Authorization
    public let quiet: Bool
    public init(authorization: Authorization, quiet: Bool = false) {
        self.authorization = authorization; self.quiet = quiet
    }
}

@MainActor public protocol TaskNotificationSystem: AnyObject {
    func settings() async -> TaskNotificationPermission
    /// Called only by an explicit opt-in and only when settings are not determined.
    func requestAuthorization() async throws -> TaskNotificationPermission
    /// Must settle with a token or an error within a bounded time.
    func deviceToken() async throws -> String
}

public struct TaskNotificationRecord: Codable, Equatable, Sendable {
    public var intent: Bool
    public var retirementRequested: Bool
    public var registrationSessionID: String?
    public var registrationID: String?
    public var workspaceID: String?
    public var groupID: String?
    public init(intent: Bool, retirementRequested: Bool = false, registrationID: String? = nil, workspaceID: String? = nil, groupID: String? = nil, registrationSessionID: String? = nil) {
        self.intent = intent; self.retirementRequested = retirementRequested
        self.registrationSessionID = registrationSessionID
        self.registrationID = registrationID; self.workspaceID = workspaceID; self.groupID = groupID
    }
}

@MainActor public protocol TaskNotificationPreferences: AnyObject {
    func load(key: String) throws -> TaskNotificationRecord?
    func save(_ record: TaskNotificationRecord, key: String) throws
    func remove(key: String) throws
}

/// Device-local, excluded from backup. Holds intent and public registration/scope IDs only;
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

/// A single worker serializes actual server mutations, not just their UI results.
/// Changes coalesce while a request settles. A changed account is retired using the
/// captured old channel before any new channel is processed. Same-session workspace
/// replacement uses the server's atomic session/kind slot update.
@MainActor @Observable public final class TaskNotificationController {
    public enum Status: Equatable, Sendable {
        case loading, off, enabling, disabling, active, denied, quiet, noWorkspace
        case enableFailed, scopeFailed, disableFailed, legacyFailed
    }
    public private(set) var status: Status = .off
    public private(set) var permission = TaskNotificationPermission(authorization: .notDetermined)
    public private(set) var record: TaskNotificationRecord?
    public private(set) var sessionID: String?
    public private(set) var accountID: String?
    public private(set) var workspace: Workspace?
    public var intent: Bool {
        get { record?.intent ?? false }
        set { setIntent(newValue) }
    }
    public var busy: Bool { [.loading, .enabling, .disabling].contains(status) }
    public var canToggle: Bool { !identitySuspended && sessionID != nil && !busy && record != nil && (intent || workspace != nil) }
    public var hasFailure: Bool { [.enableFailed, .scopeFailed, .disableFailed, .legacyFailed].contains(status) }
    public func allowsForegroundAlert(sessionID: String?, workspaceID: String?, groupID: String?) -> Bool {
        canPresent && sessionID != nil && sessionID == self.sessionID && workspaceID == workspace?.id && groupID == workspace?.groupID
    }
    public var canPresent: Bool {
        !identitySuspended && record?.intent == true && record?.retirementRequested == false && status != .disabling &&
        permission.authorization == .allowed && confirmedSession == sessionID &&
        record?.workspaceID == workspace?.id && record?.groupID == workspace?.groupID &&
        record?.registrationID != nil && workspace != nil
    }

    @ObservationIgnored private let preferences: any TaskNotificationPreferences
    @ObservationIgnored private let system: any TaskNotificationSystem
    @ObservationIgnored private let origin: String
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let environment: PushEnvironment
    @ObservationIgnored private var locale: String
    @ObservationIgnored private var channel: (any DeviceNotificationTransport)?
    @ObservationIgnored private var processedChannel: (any DeviceNotificationTransport)?
    @ObservationIgnored private var confirmedSession: String?
    @ObservationIgnored private var registeredToken: String?
    @ObservationIgnored private var requestPermission = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var unsavedRecord = false
    private var identitySuspended = false

    public init(origin: String, bundleID: String, environment: PushEnvironment, locale: String,
                preferences: any TaskNotificationPreferences, system: any TaskNotificationSystem) {
        self.origin = origin; self.bundleID = bundleID; self.environment = environment; self.locale = locale
        self.preferences = preferences; self.system = system
    }
    // This protected, non-backed-up file is installation-local. Choice survives Auth
    // Session replacement; only acknowledged registration authority is session-bound.
    private func key(account: String) -> String { origin + "|" + bundleID + "|" + account }
    private var currentKey: String? {
        guard let accountID, sessionID != nil else { return nil }; return key(account: accountID)
    }

    private func loadRecord(key: String) throws -> TaskNotificationRecord? {
        guard var saved = try preferences.load(key: key) else { return nil }
        if saved.registrationID != nil && saved.registrationSessionID != sessionID {
            saved.registrationID = nil; saved.registrationSessionID = nil
            saved.workspaceID = nil; saved.groupID = nil
            try preferences.save(saved, key: key)
        }
        return saved
    }

    /// Suppress old-account presentation and mutations immediately, while logout or
    /// local revocation is still awaiting its authority owner. Failed logout resumes
    /// the retained choice; success transitions to nil and retires the old channel.
    public func suspendIdentity() {
        identitySuspended = true; status = .loading; schedule()
    }
    public func resumeIdentity() {
        guard identitySuspended else { return }
        identitySuspended = false; schedule()
    }

    /// Requires an authenticated task/group access check, then fences all identities
    /// again after that await. Routing metadata alone never authorizes presentation.
    public func authorizeForegroundAlert(taskID: String?, sessionID: String?, workspaceID: String?, groupID: String?,
        check: @Sendable (ConversationTarget) async throws -> Bool) async -> Bool {
        guard let taskID, !taskID.isEmpty, taskID.utf8.count <= 256,
              let workspace, allowsForegroundAlert(sessionID: sessionID, workspaceID: workspaceID, groupID: groupID) else { return false }
        let boundary = revision, account = accountID
        let target = ConversationTarget(workspaceID: workspace.id, groupID: workspace.groupID, conversationID: taskID)
        do {
            guard try await check(target) else { return false }
            return revision == boundary && accountID == account && allowsForegroundAlert(sessionID: sessionID, workspaceID: workspaceID, groupID: groupID)
        } catch { return false }
    }

    /// Invoke synchronously at the identity/scope boundary, before unrelated awaits.
    public func setContext(sessionID: String?, accountID: String?, workspace: Workspace?) {
        let identityChanged = self.sessionID != sessionID || self.accountID != accountID
        let scopeChanged = self.workspace?.id != workspace?.id || self.workspace?.groupID != workspace?.groupID
        guard identityChanged || scopeChanged else { return }
        self.sessionID = sessionID; self.accountID = accountID; self.workspace = workspace
        if identityChanged {
            identitySuspended = false
            channel = nil; record = nil; registeredToken = nil; confirmedSession = nil; requestPermission = false
            loadFailed = false; unsavedRecord = false
            if let currentKey {
                do { record = try loadRecord(key: currentKey) }
                catch { loadFailed = true }
            }
        }
        status = sessionID == nil ? .off : .loading
        schedule()
    }
    public func attach(_ channel: any DeviceNotificationTransport) {
        guard channel.sessionID == sessionID, channel.accountID == accountID else { return }
        self.channel = channel; schedule()
    }
    public func refresh(locale: String? = nil) {
        if let locale, self.locale != locale { self.locale = locale; registeredToken = nil }
        schedule()
    }
    public func tokenChanged() { registeredToken = nil; schedule() }
    public func retry() {
        if record?.intent == true && record?.retirementRequested == false { requestPermission = true }
        schedule()
    }

    private func setIntent(_ enabled: Bool) {
        guard canToggle, var next = record, let currentKey else { return }
        if enabled {
            next.intent = true; next.retirementRequested = false
            requestPermission = true
        } else {
            // Preserve the last confirmed ON intent until the server proves retirement.
            next.retirementRequested = true; requestPermission = false
        }
        record = next
        do { try preferences.save(next, key: currentKey); unsavedRecord = false }
        catch { unsavedRecord = true; status = enabled ? .enableFailed : .disableFailed; return }
        status = enabled ? .enabling : .disabling
        schedule()
    }
    private func schedule() {
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while true {
                let expected = self.revision
                await self.reconcile(expected: expected)
                if expected == self.revision { break }
            }
            self.worker = nil
        }
    }
    /// Test/owner synchronization without polling. Does not cancel mutations.
    public func settle() async { await worker?.value }

    private func retire(_ channel: any DeviceNotificationTransport, allowRevokedOldSession: Bool = false) async throws {
        do { try await channel.retire() }
        catch CommaError.http(let status, _, _) where status == 401 && allowRevokedOldSession {
            // Only compensating an old captured session accepts proof of revocation.
            // Current migration/disable always requires the endpoint's 204 acknowledgment.
        }
    }
    private func reconcile(expected: Int) async {
        // Account change compensation uses the original channel even if no new login exists.
        if let previous = processedChannel,
           previous.sessionID != sessionID || previous.accountID != accountID {
            do {
                try await retire(previous, allowRevokedOldSession: true)
                let previousKey = key(account: previous.accountID)
                if var saved = try preferences.load(key: previousKey), saved.registrationSessionID == previous.sessionID {
                    saved.registrationID = nil; saved.registrationSessionID = nil
                    saved.workspaceID = nil; saved.groupID = nil
                    try preferences.save(saved, key: previousKey)
                }
                processedChannel = nil
            } catch {
                if expected == revision { status = .legacyFailed }
                return
            }
        }
        guard !identitySuspended, let channel, let currentKey, expected == revision else { return }
        processedChannel = channel
        do {
            if loadFailed { record = try loadRecord(key: currentKey); loadFailed = false }
            if unsavedRecord, let record { try preferences.save(record, key: currentKey); unsavedRecord = false }
            // No recorded choice is not consent. The current-session DELETE is safe even
            // when the legacy registration ID was never saved, and needs no OS permission.
            if record == nil || record?.retirementRequested == true {
                let legacy = record == nil
                status = legacy ? .loading : .disabling
                try await retire(channel)
                let off = TaskNotificationRecord(intent: false)
                try preferences.save(off, key: currentKey)
                guard expected == revision else { return }
                record = off; registeredToken = nil; confirmedSession = nil
                status = .off
                return
            }
            permission = await system.settings()
            guard expected == revision else { return }
            guard record?.intent == true else { status = .off; return }
            guard expected == revision else { return }
            if permission.authorization == .notDetermined, requestPermission {
                requestPermission = false
                status = .enabling
                permission = try await system.requestAuthorization()
                guard expected == revision else { return }
            }
            requestPermission = false
            guard permission.authorization == .allowed else {
                status = permission.authorization == .denied ? .denied : .enableFailed
                return
            }
            guard let workspace else {
                if record?.registrationID != nil {
                    try await retire(channel)
                    var saved = TaskNotificationRecord(intent: true)
                    saved.retirementRequested = false
                    try preferences.save(saved, key: currentKey)
                    guard expected == revision else { return }
                    record = saved; confirmedSession = nil; registeredToken = nil
                }
                status = .noWorkspace; return
            }
            status = .enabling
            let token = try await system.deviceToken()
            guard expected == revision else { return }
            if registeredToken != token || confirmedSession != sessionID || record?.workspaceID != workspace.id || record?.groupID != workspace.groupID {
                var saved = record ?? TaskNotificationRecord(intent: true)
                let result = try await channel.register(token: token, environment: environment, workspace: workspace, bundleID: bundleID, locale: locale)
                // Persist this acknowledged scope under its captured session even when a
                // later workspace is selected. The next serialized iteration replaces it.
                saved.registrationSessionID = channel.sessionID
                saved.registrationID = result.id; saved.workspaceID = workspace.id; saved.groupID = workspace.groupID
                try preferences.save(saved, key: currentKey)
                guard channel.sessionID == sessionID, channel.accountID == accountID else { return }
                record = saved; registeredToken = token; confirmedSession = sessionID
                guard expected == revision else { return }
            }
            status = permission.quiet ? .quiet : .active
        } catch {
            guard expected == revision else { return }
            if record == nil || loadFailed { status = .legacyFailed }
            else if record?.retirementRequested == true { status = .disableFailed }
            else if record?.workspaceID != nil && (record?.workspaceID != workspace?.id || record?.groupID != workspace?.groupID) { status = .scopeFailed }
            else { status = .enableFailed }
        }
    }
}
