import Foundation
import Observation

/// A single worker serializes actual server mutations, not just their UI results.
/// Changes coalesce while a request settles. A changed account is retired using the
/// captured old channel before any new channel is processed. Same-session workspace
/// replacement uses the server's atomic session/kind slot update.
@MainActor @Observable public final class TaskNotificationController {
    public enum Status: Equatable, Sendable {
        case loading, off, enabling, disabling, active, denied, quiet, noWorkspace
        case enableFailed, scopeFailed, disableFailed, legacyFailed
    }
    public internal(set) var status: Status = .off
    public private(set) var failure: CommaError?
    public private(set) var failureMessage: String?
    public internal(set) var permission = TaskNotificationPermission(authorization: .notDetermined)
    public internal(set) var record: TaskNotificationRecord?
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

    @ObservationIgnored let preferences: any TaskNotificationPreferences
    @ObservationIgnored let system: any TaskNotificationSystem
    @ObservationIgnored private let origin: String
    @ObservationIgnored let bundleID: String
    @ObservationIgnored let environment: PushEnvironment
    @ObservationIgnored private(set) var locale: String
    @ObservationIgnored private(set) var channel: (any DeviceNotificationTransport)?
    @ObservationIgnored var processedChannel: (any DeviceNotificationTransport)?
    @ObservationIgnored var confirmedSession: String?
    @ObservationIgnored var registeredToken: String?
    @ObservationIgnored var requestPermission = false
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored var loadFailed = false
    @ObservationIgnored var unsavedRecord = false
    private(set) var identitySuspended = false

    public init(origin: String, bundleID: String, environment: PushEnvironment, locale: String,
                preferences: any TaskNotificationPreferences, system: any TaskNotificationSystem) {
        self.origin = origin; self.bundleID = bundleID; self.environment = environment; self.locale = locale
        self.preferences = preferences; self.system = system
    }
    // This protected, non-backed-up file is installation-local. Choice survives Auth
    // Session replacement; only acknowledged registration authority is session-bound.
    func key(account: String) -> String { origin + "|" + bundleID + "|" + account }
    var currentKey: String? {
        guard let accountID, sessionID != nil else { return nil }; return key(account: accountID)
    }

    func loadRecord(key: String) throws -> TaskNotificationRecord? {
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
        identitySuspended = true; status = .loading; clearFailure(); schedule()
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
        clearFailure()
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
        catch {
            unsavedRecord = true; status = enabled ? .enableFailed : .disableFailed
            captureFailure(error); return
        }
        status = enabled ? .enabling : .disabling
        schedule()
    }
    private func schedule() {
        clearFailure()
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

    private func clearFailure() { failure = nil; failureMessage = nil }

    func captureFailure(_ error: any Error, acquiringDeviceToken: Bool = false) {
        failure = error as? CommaError
        if acquiringDeviceToken {
            failureMessage = "This iPhone could not register for notifications. Check your connection and try again."
        } else if let failure {
            // Input details can contain caller values. Only fixed error descriptions reach the UI.
            switch failure {
            case .invalidInput: failureMessage = nil
            case .http(_, "push_unavailable", _):
                failureMessage = failure.errorDescription
            case .http(let status, _, _) where [401, 403, 404, 429].contains(status):
                failureMessage = failure.errorDescription
            case .http: failureMessage = nil
            default: failureMessage = failure.errorDescription
            }
        } else { failureMessage = nil }
    }
}
