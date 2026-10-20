import Foundation
import CommaCore

/// Serializes each existing Target UUID through POST settlement and exact-ID retirement.
/// Durable entries contain correlation and intent only; tokens and captured bearers stay in memory.
@MainActor
final class ActivityRegistrationController {
    private struct Entry: Codable {
        let id: String
        let workspaceID: String
        let groupID: String
        let activityID: String?
        var acknowledged: Bool
        var retirementReason: String?
    }
    private struct Attempt {
        let id: String
        let token: String?
        let activityID: String?
        let key: String
        let channel: any ActivityNotificationTransport
        var acknowledged: Bool
    }
    private struct Retirement {
        let id: String
        let key: String
        let channel: any ActivityNotificationTransport
    }
    private let preferences: UserDefaults
    private var channel: (any ActivityNotificationTransport)?
    private var workspace: Workspace?
    private var key: String?
    private var enabled = false
    private var startToken: String?
    private var liveToken: (token: String, activityID: String)?
    private var start: Attempt?
    private var live: Attempt?
    private var replacements: [String: Attempt] = [:]
    private var retirements: [Retirement] = []
    private var worker: Task<Void, Never>?
    private var revision = 0
    var onFailure: (() -> Void)?
    var onSuccess: (() -> Void)?

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    func configure(channel: any ActivityNotificationTransport, workspace: Workspace, origin: String,
                   enabled: Bool, restoredActivityIDs: Set<String>) {
        let nextKey = "comma.activity.tasks-v1." + origin + "." + channel.sessionID
        guard self.key != nextKey || self.workspace != workspace || self.channel == nil else {
            self.channel = channel
            setEnabled(enabled)
            return
        }
        stop(reason: .authorityChanged)
        self.channel = channel; self.workspace = workspace; key = nextKey; self.enabled = enabled
        // Adopt the previous single-field preference into the durable ledger before clearing it.
        let legacyKey = nextKey + "." + workspace.id
        if let legacyID = preferences.string(forKey: legacyKey), UUID(uuidString: legacyID) != nil,
           !entries(nextKey).contains(where: { $0.id == legacyID }) {
            update(nextKey) { $0.append(Entry(id: legacyID, workspaceID: workspace.id, groupID: workspace.groupID,
                activityID: nil, acknowledged: true, retirementReason: nil)) }
            preferences.removeObject(forKey: legacyKey)
        }
        for entry in entries(nextKey) {
            let exactScope = entry.workspaceID == workspace.id && entry.groupID == workspace.groupID
            let attempt = Attempt(id: entry.id, token: nil, activityID: entry.activityID, key: nextKey,
                                  channel: channel, acknowledged: entry.acknowledged)
            if enabled, exactScope, entry.retirementReason == nil, entry.acknowledged,
               entry.activityID == nil || restoredActivityIDs.contains(entry.activityID!) {
                // Keep a known live row for Stop/Delete even before ActivityKit yields its token.
                if entry.activityID == nil, start == nil { start = attempt }
                else if entry.activityID != nil, live == nil { live = attempt }
                else { retire(attempt, reason: .finished) }
            } else {
                retire(attempt, reason: ActivityRetirementReason(rawValue: entry.retirementReason ?? "")
                       ?? (enabled ? .authorityChanged : .disabled))
            }
        }
        schedule()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            retireLive(reason: .disabled)
            if let start { retire(start, reason: .disabled) }
            start = nil
        }
        schedule()
    }
    func setStartToken(_ token: String?) { startToken = token; schedule() }
    func setLiveToken(_ token: String, activityID: String) { liveToken = (token, activityID); schedule() }
    func retireLive(reason: ActivityRetirementReason) {
        liveToken = nil
        if let live { retire(live, reason: reason) }
        live = nil
    }
    func stop(reason: ActivityRetirementReason) {
        enabled = false; startToken = nil; liveToken = nil
        if let start { retire(start, reason: reason) }
        if let live { retire(live, reason: reason) }
        start = nil; live = nil
        channel = nil; workspace = nil; key = nil
        schedule()
    }
    func retry() { schedule() }
    func settle() async { while let worker { await worker.value } }

    private var dismissalKey: String? {
        guard let key, let workspace else { return nil }
        return key + "." + workspace.id + "." + workspace.groupID + ".dismissed"
    }
    var dismissedCohort: Set<String>? {
        guard let dismissalKey, let ids = preferences.stringArray(forKey: dismissalKey) else { return nil }
        return Set(ids)
    }
    func setDismissedCohort(_ ids: Set<String>?) {
        guard let dismissalKey else { return }
        if let ids { preferences.set(ids.sorted(), forKey: dismissalKey) }
        else { preferences.removeObject(forKey: dismissalKey) }
    }

    private func entries(_ key: String) -> [Entry] {
        guard let data = preferences.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    private func update(_ key: String, _ operation: (inout [Entry]) -> Void) {
        var values = entries(key)
        operation(&values)
        if values.isEmpty { preferences.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(values) { preferences.set(data, forKey: key) }
    }
    private func retire(_ attempt: Attempt, reason: ActivityRetirementReason) {
        update(attempt.key) { values in
            if let index = values.firstIndex(where: { $0.id == attempt.id }), values[index].retirementReason == nil {
                values[index].retirementReason = reason.rawValue
            }
        }
        if let replaced = replacements.removeValue(forKey: attempt.id) { retire(replaced, reason: reason) }
        if !retirements.contains(where: { $0.id == attempt.id && $0.key == attempt.key }) {
            retirements.append(Retirement(id: attempt.id, key: attempt.key, channel: attempt.channel))
        }
        schedule()
    }
    private func schedule() {
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            var observed: Int
            repeat {
                observed = self.revision
                await self.reconcile()
            } while observed != self.revision
            self.worker = nil
        }
    }
    private func reconcile() async {
        var failed = false
        for retirement in retirements.prefix(20) {
            guard let entry = entries(retirement.key).first(where: { $0.id == retirement.id }),
                  let reason = entry.retirementReason.flatMap(ActivityRetirementReason.init(rawValue:)) else {
                retirements.removeAll { $0.id == retirement.id && $0.key == retirement.key }
                continue
            }
            do {
                try await retirement.channel.retire(id: retirement.id, reason: reason)
                update(retirement.key) { $0.removeAll { $0.id == retirement.id } }
                retirements.removeAll { $0.id == retirement.id && $0.key == retirement.key }
            } catch CommaError.http(let status, _, _) where status == 401 && retirement.channel.sessionID != channel?.sessionID {
                // Revocation of an old captured Session also removes its delivery
                // authority. Current-session Stop/Disable still requires DELETE ACK.
                update(retirement.key) { $0.removeAll { $0.id == retirement.id } }
                retirements.removeAll { $0.id == retirement.id && $0.key == retirement.key }
            } catch { failed = true; onFailure?() }
        }
        if !failed, !retirements.isEmpty { schedule(); return }
        // Failed exact-ID cleanup remains durable and bounds new enrollment attempts.
        guard !failed, enabled, let channel, let workspace, let key else { return }
        if let startToken {
            await register(token: startToken, activityID: nil, channel: channel, workspace: workspace, key: key)
        }
        guard enabled, self.channel?.sessionID == channel.sessionID, self.key == key,
              let liveToken else { return }
        await register(token: liveToken.token, activityID: liveToken.activityID, channel: channel, workspace: workspace, key: key)
    }
    private func register(token: String, activityID: String?, channel: any ActivityNotificationTransport,
                          workspace: Workspace, key: String) async {
        let previous = activityID == nil ? start : live
        if let previous, previous.token == token, previous.activityID == activityID, previous.acknowledged { return }
        let attempt: Attempt
        if let previous, previous.token == token, previous.activityID == activityID {
            attempt = previous // A failed/unknown response retries the same pending UUID.
        } else {
            attempt = Attempt(id: UUID().uuidString.lowercased(), token: token, activityID: activityID, key: key,
                              channel: channel, acknowledged: false)
            update(key) { $0.append(Entry(id: attempt.id, workspaceID: workspace.id, groupID: workspace.groupID,
                activityID: activityID, acknowledged: false, retirementReason: nil)) }
            if let previous { replacements[attempt.id] = previous }
            if activityID == nil { start = attempt } else { live = attempt }
        }
        do {
            let result = try await channel.register(token: token, activityID: activityID, registrationID: attempt.id)
            guard result.id.caseInsensitiveCompare(attempt.id) == .orderedSame else { throw CommaError.invalidResponse }
            let stillDesired = enabled && self.key == key && self.channel?.sessionID == channel.sessionID &&
                (activityID == nil ? start?.id == attempt.id : live?.id == attempt.id)
            if !stillDesired || entries(key).first(where: { $0.id == attempt.id })?.retirementReason != nil {
                // The user's stopped/dismissed reason was persisted while POST was in flight.
                retire(attempt, reason: .authorityChanged)
                return
            }
            update(key) { values in
                if let index = values.firstIndex(where: { $0.id == attempt.id }) { values[index].acknowledged = true }
            }
            var acknowledged = attempt; acknowledged.acknowledged = true
            if activityID == nil { start = acknowledged } else { live = acknowledged }
            if let previous = replacements.removeValue(forKey: attempt.id) { retire(previous, reason: .finished) }
            onSuccess?()
        } catch { onFailure?() }
    }
}
