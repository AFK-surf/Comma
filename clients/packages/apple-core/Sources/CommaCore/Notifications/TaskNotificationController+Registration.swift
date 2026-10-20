import Foundation

// The serialized worker pass that reconciles the server registration with the recorded choice.
extension TaskNotificationController {
    private func retire(_ channel: any DeviceNotificationTransport, allowRevokedOldSession: Bool = false) async throws {
        do { try await channel.retire() }
        catch CommaError.http(let status, _, _) where status == 401 && allowRevokedOldSession {
            // Only compensating an old captured session accepts proof of revocation.
            // Current migration/disable always requires the endpoint's 204 acknowledgment.
        }
    }
    func reconcile(expected: Int) async {
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
                if expected == revision { status = .legacyFailed; captureFailure(error) }
                return
            }
        }
        guard !identitySuspended, let channel, let currentKey, expected == revision else { return }
        processedChannel = channel
        var acquiringDeviceToken = false
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
            if permission.authorization == .allowed, permission.badgeAllowed,
               record?.fullAuthorizationRequested != true, var saved = record {
                saved.fullAuthorizationRequested = true
                try preferences.save(saved, key: currentKey)
                record = saved
            }
            let upgradeOptions = permission.authorization == .allowed && permission.explicitlyAuthorized &&
                !permission.badgeAllowed && (record?.fullAuthorizationRequested != true || requestPermission)
            if (permission.authorization == .notDetermined && requestPermission) || upgradeOptions {
                requestPermission = false
                if var saved = record {
                    // Persist the request, not a grant. Relaunches never repeatedly request
                    // options the user disabled; OS settings remain authoritative.
                    saved.fullAuthorizationRequested = true
                    try preferences.save(saved, key: currentKey)
                    record = saved
                }
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
                    var saved = TaskNotificationRecord(intent: true, fullAuthorizationRequested: record?.fullAuthorizationRequested)
                    saved.retirementRequested = false
                    try preferences.save(saved, key: currentKey)
                    guard expected == revision else { return }
                    record = saved; confirmedSession = nil; registeredToken = nil
                }
                status = .noWorkspace; return
            }
            status = .enabling
            acquiringDeviceToken = true
            let token = try await system.deviceToken()
            acquiringDeviceToken = false
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
            captureFailure(error, acquiringDeviceToken: acquiringDeviceToken)
            if record == nil || loadFailed { status = .legacyFailed }
            else if record?.retirementRequested == true { status = .disableFailed }
            else if record?.workspaceID != nil && (record?.workspaceID != workspace?.id || record?.groupID != workspace?.groupID) { status = .scopeFailed }
            else { status = .enableFailed }
        }
    }
}
