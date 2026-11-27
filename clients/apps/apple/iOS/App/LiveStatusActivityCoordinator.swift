// ActivityKit's legacy Activity references remain on MainActor.
@preconcurrency import ActivityKit
import Combine
import CommaCore
import Foundation

/// Serializes generalized Live Status (`live_status_v1`) push-to-start and per-key update registrations
/// through POST settlement and exact-ID retirement.
@MainActor
final class LiveStatusRegistrationController {
    private struct Entry: Codable {
        let id: String
        let workspaceID: String
        let groupID: String
        let activityID: String?
        let liveKey: String?
        var acknowledged: Bool
        var retirementReason: String?
    }
    private struct Attempt {
        let id: String
        let token: String?
        let activityID: String?
        let liveKey: String?
        let key: String
        let channel: any LiveStatusNotificationTransport
        var acknowledged: Bool
    }
    private struct Retirement {
        let id: String
        let key: String
        let channel: any LiveStatusNotificationTransport
    }

    private let preferences: UserDefaults
    private var channel: (any LiveStatusNotificationTransport)?
    private var workspace: Workspace?
    private var key: String?
    private var enabled = false
    private var startToken: String?
    private var liveTokens: [String: (token: String, activityID: String)] = [:]
    private var start: Attempt?
    private var liveByKey: [String: Attempt] = [:]
    private var replacements: [String: Attempt] = [:]
    private var retirements: [Retirement] = []
    private var worker: Task<Void, Never>?
    private var revision = 0
    var onFailure: (() -> Void)?
    var onSuccess: (() -> Void)?

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    func configure(channel: any LiveStatusNotificationTransport, workspace: Workspace, origin: String,
                   enabled: Bool, restoredActivityIDs: Set<String>) {
        let nextKey = "comma.activity.live-status-v1." + origin + "." + channel.sessionID
        guard self.key != nextKey || self.workspace != workspace || self.channel == nil else {
            self.channel = channel
            setEnabled(enabled)
            return
        }
        stop(reason: .authorityChanged)
        self.channel = channel
        self.workspace = workspace
        self.key = nextKey
        self.enabled = enabled

        for entry in entries(nextKey) {
            let exactScope = entry.workspaceID == workspace.id && entry.groupID == workspace.groupID
            let attempt = Attempt(id: entry.id, token: nil, activityID: entry.activityID, liveKey: entry.liveKey,
                                  key: nextKey, channel: channel, acknowledged: entry.acknowledged)
            let isStart = entry.activityID == nil && entry.liveKey == nil
            let isRestoredLive = entry.activityID != nil && entry.liveKey != nil && restoredActivityIDs.contains(entry.activityID!)
            if enabled, exactScope, entry.retirementReason == nil, entry.acknowledged, (isStart || isRestoredLive) {
                if isStart, start == nil {
                    start = attempt
                } else if let liveKey = entry.liveKey, liveByKey[liveKey] == nil {
                    liveByKey[liveKey] = attempt
                } else {
                    retire(attempt, reason: .finished)
                }
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
            retireAllLive(reason: .disabled)
            if let start { retire(start, reason: .disabled) }
            start = nil
        }
        schedule()
    }

    func setStartToken(_ token: String?) {
        startToken = token
        schedule()
    }

    func setLiveToken(_ token: String, activityID: String, liveKey: String) {
        liveTokens[liveKey] = (token, activityID)
        schedule()
    }

    func retireLive(liveKey: String, reason: ActivityRetirementReason) {
        liveTokens.removeValue(forKey: liveKey)
        if let existing = liveByKey.removeValue(forKey: liveKey) {
            retire(existing, reason: reason)
        }
    }

    func retireAllLive(reason: ActivityRetirementReason) {
        liveTokens.removeAll()
        let active = liveByKey
        liveByKey.removeAll()
        for attempt in active.values {
            retire(attempt, reason: reason)
        }
    }

    func stop(reason: ActivityRetirementReason) {
        enabled = false
        startToken = nil
        retireAllLive(reason: reason)
        if let start { retire(start, reason: reason) }
        start = nil
        channel = nil
        workspace = nil
        key = nil
        schedule()
    }

    func retry() { schedule() }
    func settle() async { while let worker { await worker.value } }

    private var dismissalKey: String? {
        guard let key, let workspace else { return nil }
        return key + "." + workspace.id + "." + workspace.groupID + ".dismissed-instances"
    }

    var dismissedInstances: [String: Int] {
        guard let dismissalKey, let data = preferences.data(forKey: dismissalKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    func setDismissedInstances(_ instances: [String: Int]) {
        guard let dismissalKey else { return }
        if instances.isEmpty {
            preferences.removeObject(forKey: dismissalKey)
        } else if let data = try? JSONEncoder().encode(instances) {
            preferences.set(data, forKey: dismissalKey)
        }
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
                update(retirement.key) { $0.removeAll { $0.id == retirement.id } }
                retirements.removeAll { $0.id == retirement.id && $0.key == retirement.key }
            } catch {
                failed = true
                onFailure?()
            }
        }
        if !failed, !retirements.isEmpty { schedule(); return }
        guard !failed, enabled, let channel, let workspace, let key else { return }
        if let startToken {
            await register(token: startToken, activityID: nil, liveKey: nil, channel: channel, workspace: workspace, key: key)
        }
        guard enabled, self.channel?.sessionID == channel.sessionID, self.key == key else { return }
        let snapshotTokens = liveTokens
        for (liveKey, info) in snapshotTokens.sorted(by: { $0.key < $1.key }) {
            guard enabled, self.channel?.sessionID == channel.sessionID, self.key == key else { return }
            await register(token: info.token, activityID: info.activityID, liveKey: liveKey,
                           channel: channel, workspace: workspace, key: key)
        }
    }

    private func register(token: String, activityID: String?, liveKey: String?,
                          channel: any LiveStatusNotificationTransport, workspace: Workspace, key: String) async {
        let previous = liveKey.map { liveByKey[$0] } ?? start
        if let previous, previous.token == token, previous.activityID == activityID,
           previous.liveKey == liveKey, previous.acknowledged { return }
        let attempt: Attempt
        if let previous, previous.token == token, previous.activityID == activityID, previous.liveKey == liveKey {
            attempt = previous
        } else {
            attempt = Attempt(id: UUID().uuidString.lowercased(), token: token, activityID: activityID,
                              liveKey: liveKey, key: key, channel: channel, acknowledged: false)
            update(key) {
                $0.append(Entry(id: attempt.id, workspaceID: workspace.id, groupID: workspace.groupID,
                                activityID: activityID, liveKey: liveKey, acknowledged: false, retirementReason: nil))
            }
            if let previous { replacements[attempt.id] = previous }
            if let liveKey { liveByKey[liveKey] = attempt } else { start = attempt }
        }
        do {
            let result = try await channel.register(token: token, activityID: activityID,
                                                    liveKey: liveKey, registrationID: attempt.id)
            guard result.id.caseInsensitiveCompare(attempt.id) == .orderedSame else { throw CommaError.invalidResponse }
            let stillDesired = enabled && self.key == key && self.channel?.sessionID == channel.sessionID &&
                (liveKey.map { liveByKey[$0]?.id == attempt.id } ?? (start?.id == attempt.id))
            if !stillDesired || entries(key).first(where: { $0.id == attempt.id })?.retirementReason != nil {
                retire(attempt, reason: .authorityChanged)
                return
            }
            update(key) { values in
                if let index = values.firstIndex(where: { $0.id == attempt.id }) { values[index].acknowledged = true }
            }
            var acknowledged = attempt
            acknowledged.acknowledged = true
            if let liveKey { liveByKey[liveKey] = acknowledged } else { start = acknowledged }
            if let previous = replacements.removeValue(forKey: attempt.id) { retire(previous, reason: .finished) }
            onSuccess?()
        } catch {
            onFailure?()
        }
    }
}

/// Manages up to 5 concurrent generalized Live Status activities (`LiveStatusAttributes`), keyed by `liveKey`.
@MainActor
final class LiveStatusActivityCoordinator: ObservableObject {
    static let maxConcurrentActivities = 5

    @Published private(set) var activeLiveKeys: [String] = []
    @Published private(set) var availabilityMessage: String?

    private var activities: [String: Activity<LiveStatusAttributes>] = [:]
    private var tokenObservations: [String: Task<Void, Never>] = [:]
    private var stateObservations: [String: Task<Void, Never>] = [:]
    private var latestItems: [LiveStatusItem] = []
    private var accountID: String?
    private var workspace: Workspace?
    private var channel: (any LiveStatusNotificationTransport)?
    private var automaticFollowing = true
    private var dismissals = LiveStatusDismissalTracker()
    private var generation = 0
    private var configurationGeneration = 0
    private var applyRevision = 0
    private var startObservation: Task<Void, Never>?
    private var activityObservation: Task<Void, Never>?
    private let startToken: @MainActor () -> Data?
    private let registrations: LiveStatusRegistrationController

    init(startToken: @escaping @MainActor () -> Data? = { Activity<LiveStatusAttributes>.pushToStartToken },
         preferences: UserDefaults = .standard) {
        self.startToken = startToken
        registrations = LiveStatusRegistrationController(preferences: preferences)
        registrations.onFailure = { [weak self] in
            self?.report("Live status background updates are unavailable. Reconnect and try again.")
        }
        registrations.onSuccess = { [weak self] in self?.report(nil) }
    }

    func settleRegistrations() async { await registrations.settle() }

    func configure(accountID: String, workspace: Workspace, origin: String, automaticFollowing: Bool,
                   channel: any LiveStatusNotificationTransport) async {
        configurationGeneration += 1
        let configurationEpoch = configurationGeneration
        let changed = self.accountID != accountID
            || self.workspace?.id != workspace.id
            || self.workspace?.groupID != workspace.groupID
            || self.channel?.sessionID != channel.sessionID
        if changed {
            generation += 1
            registrations.stop(reason: .authorityChanged)
            applyRevision += 1
            await stopAllActivities(reason: .authorityChanged)
            guard configurationEpoch == configurationGeneration else { return }
            startObservation?.cancel()
            activityObservation?.cancel()
            self.accountID = accountID
            self.workspace = workspace
            self.channel = channel
            let restored = Set(Activity<LiveStatusAttributes>.activities.filter { matches($0) }.map(\.id))
            registrations.configure(channel: channel, workspace: workspace, origin: origin,
                                    enabled: automaticFollowing, restoredActivityIDs: restored)
            dismissals = LiveStatusDismissalTracker(instances: registrations.dismissedInstances)
        }
        self.automaticFollowing = automaticFollowing
        registrations.setEnabled(automaticFollowing)
        let epoch = generation

        for candidate in Activity<LiveStatusAttributes>.activities {
            guard epoch == generation, configurationEpoch == configurationGeneration else { return }
            let liveKey = candidate.attributes.liveKey
            if !matches(candidate) || !automaticFollowing {
                await candidate.end(nil, dismissalPolicy: .immediate)
            } else if shouldSuppress(liveKey: liveKey, startedAt: candidate.attributes.startedAtEpochSeconds) {
                registrations.retireLive(liveKey: liveKey, reason: .dismissed)
                await candidate.end(nil, dismissalPolicy: .immediate)
            } else if let existing = activities[liveKey] {
                if existing.id != candidate.id {
                    await candidate.end(nil, dismissalPolicy: .immediate)
                }
            } else if activities.count < Self.maxConcurrentActivities {
                restore(candidate)
            } else {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }

        guard epoch == generation, configurationEpoch == configurationGeneration else { return }
        startObservation?.cancel()
        startObservation = Task { [weak self] in
            for await _ in Activity<LiveStatusAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                self.scheduleRegistrations()
            }
        }
        activityObservation?.cancel()
        activityObservation = Task { [weak self] in
            for await candidate in Activity<LiveStatusAttributes>.activityUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                let liveKey = candidate.attributes.liveKey
                guard self.matches(candidate), self.automaticFollowing,
                      !self.shouldSuppress(liveKey: liveKey, startedAt: candidate.attributes.startedAtEpochSeconds) else {
                    await candidate.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                if let existing = self.activities[liveKey], existing.id != candidate.id {
                    await self.stopActivity(liveKey: liveKey, reason: .finished)
                    guard epoch == self.generation else { return }
                }
                if self.activities[liveKey] == nil {
                    self.restore(candidate)
                }
            }
        }
        scheduleRegistrations()
    }

    func apply(_ items: [LiveStatusItem]) async {
        guard let accountID, let workspace else { return }
        let scoped = items.filter { $0.workspaceID == workspace.id && $0.groupID == workspace.groupID }
        latestItems = scoped
        applyRevision += 1
        let revision = applyRevision
        let epoch = generation

        let activeItems = scoped.filter { !LiveStatusAttributes.ContentState(item: $0).isTerminal }
        let terminalByKey = Dictionary(
            scoped
                .filter { LiveStatusAttributes.ContentState(item: $0).isTerminal }
                .map { ($0.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        // Prune dismissed entries that are no longer active or superseded by a newer instance.
        let activeStartedByKey = Dictionary(
            activeItems.map { ($0.key, $0.startedAtEpochSeconds) },
            uniquingKeysWith: { _, latest in latest }
        )
        let beforePrune = dismissals.instances
        dismissals.prune(activeStartedAtByKey: activeStartedByKey)
        if dismissals.instances != beforePrune {
            registrations.setDismissedInstances(dismissals.instances)
        }

        guard automaticFollowing else { return }

        let desiredActive = Array(
            activeItems
                .filter { !shouldSuppress(liveKey: $0.key, startedAt: $0.startedAtEpochSeconds) }
                .prefix(Self.maxConcurrentActivities)
        )
        let desiredActiveByKey = Dictionary(uniqueKeysWithValues: desiredActive.map { ($0.key, $0) })

        // Gracefully end terminal activities within their display window, and immediately stop removed ones.
        for liveKey in Array(activities.keys) where desiredActiveByKey[liveKey] == nil {
            if let terminalItem = terminalByKey[liveKey], let current = activities[liveKey] {
                let state = LiveStatusAttributes.ContentState(item: terminalItem)
                let content = Self.content(state: state, item: terminalItem)
                let policy: ActivityUIDismissalPolicy = terminalItem.dismissAtEpochSeconds.map {
                    .after(Date(timeIntervalSince1970: TimeInterval($0)))
                } ?? .default
                // Clear observers & retire token before awaiting end() so ActivityKit's `.ended` state
                // cannot increment `applyRevision` and abort updates for the remaining activities.
                clearActivity(liveKey: liveKey, reason: .finished)
                await current.end(content, dismissalPolicy: policy)
            } else {
                await stopActivity(liveKey: liveKey, reason: .finished)
            }
            guard epoch == generation, revision == applyRevision, automaticFollowing else { return }
        }

        // Update existing or start missing active activities (never start new activities for terminal items).
        for item in desiredActive {
            guard epoch == generation, revision == applyRevision, automaticFollowing else { return }
            let state = LiveStatusAttributes.ContentState(item: item)
            let content = Self.content(state: state, item: item)

            if let current = activities[item.key] {
                if let existingStarted = current.attributes.startedAtEpochSeconds,
                   let itemStarted = item.startedAtEpochSeconds,
                   itemStarted > existingStarted {
                    // Server restarted a new instance under the same liveKey: recreate the Activity so its
                    // immutable `attributes.startedAtEpochSeconds` tracks the new instance accurately.
                    await stopActivity(liveKey: item.key, reason: .finished)
                    guard epoch == generation, revision == applyRevision, automaticFollowing else { return }
                } else {
                    if current.content.state != state {
                        await current.update(content)
                    }
                    continue
                }
            }

            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                report("Live Activities are disabled in Settings.")
                continue
            }
            do {
                let attributes = LiveStatusAttributes(
                    accountID: accountID,
                    workspaceID: workspace.id,
                    groupID: workspace.groupID,
                    liveKey: item.key,
                    conversationID: item.conversationID,
                    startedAtEpochSeconds: item.startedAtEpochSeconds
                )
                let next = try Activity.request(attributes: attributes, content: content, pushType: .token)
                activities[item.key] = next
                publishActiveKeys()
                report(nil)
                observe(next)
            } catch {
                report("Live Activity could not start. Reconnect and try again.")
            }
        }
        scheduleRegistrations()
    }

    func retry() async {
        scheduleRegistrations()
        if !latestItems.isEmpty { await apply(latestItems) }
    }

    func setAutomaticFollowing(_ enabled: Bool) async {
        automaticFollowing = enabled
        applyRevision += 1
        registrations.setEnabled(enabled)
        if !enabled {
            await stopAllActivities(reason: .disabled)
        } else {
            dismissals.removeAll()
            registrations.setDismissedInstances(dismissals.instances)
            if !latestItems.isEmpty { await apply(latestItems) }
        }
        scheduleRegistrations()
    }

    func stop() async {
        configurationGeneration += 1
        generation += 1
        applyRevision += 1
        let old = Array(activities.values)
        clearAllActivities(reason: .authorityChanged)
        registrations.stop(reason: .authorityChanged)
        startObservation?.cancel(); startObservation = nil
        activityObservation?.cancel(); activityObservation = nil
        accountID = nil
        workspace = nil
        channel = nil
        latestItems = []
        dismissals.removeAll()
        for activity in old {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func shouldSuppress(liveKey: String, startedAt: Int?) -> Bool {
        let before = dismissals.instances
        let suppressed = dismissals.shouldSuppress(liveKey: liveKey, startedAt: startedAt)
        if dismissals.instances != before {
            registrations.setDismissedInstances(dismissals.instances)
        }
        return suppressed
    }

    private func matches(_ candidate: Activity<LiveStatusAttributes>) -> Bool {
        candidate.attributes.accountID == accountID
            && candidate.attributes.workspaceID == workspace?.id
            && candidate.attributes.groupID == workspace?.groupID
    }

    private func restore(_ candidate: Activity<LiveStatusAttributes>) {
        let liveKey = candidate.attributes.liveKey
        activities[liveKey] = candidate
        publishActiveKeys()
        observe(candidate)
    }

    private func observe(_ candidate: Activity<LiveStatusAttributes>) {
        let liveKey = candidate.attributes.liveKey
        tokenObservations[liveKey]?.cancel()
        stateObservations[liveKey]?.cancel()
        let epoch = generation
        tokenObservations[liveKey] = Task { [weak self] in
            for await _ in candidate.pushTokenUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation,
                      self.activities[liveKey]?.id == candidate.id else { return }
                self.scheduleRegistrations()
            }
        }
        stateObservations[liveKey] = Task { [weak self] in
            for await state in candidate.activityStateUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation,
                      self.activities[liveKey]?.id == candidate.id else { return }
                if state == .dismissed || state == .ended {
                    if state == .dismissed {
                        self.dismissals.recordDismissal(
                            liveKey: liveKey,
                            startedAt: candidate.attributes.startedAtEpochSeconds,
                            nowEpochSeconds: Int(Date().timeIntervalSince1970)
                        )
                        self.registrations.setDismissedInstances(self.dismissals.instances)
                    }
                    self.applyRevision += 1
                    self.clearActivity(liveKey: liveKey, reason: state == .dismissed ? .dismissed : .finished)
                    return
                }
            }
        }
        scheduleRegistrations()
    }

    private func stopActivity(liveKey: String, reason: ActivityRetirementReason) async {
        let old = activities[liveKey]
        clearActivity(liveKey: liveKey, reason: reason)
        await old?.end(nil, dismissalPolicy: .immediate)
    }

    private func stopAllActivities(reason: ActivityRetirementReason) async {
        let old = Array(activities.values)
        clearAllActivities(reason: reason)
        for activity in old {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func clearActivity(liveKey: String, reason: ActivityRetirementReason) {
        tokenObservations.removeValue(forKey: liveKey)?.cancel()
        stateObservations.removeValue(forKey: liveKey)?.cancel()
        registrations.retireLive(liveKey: liveKey, reason: reason)
        activities.removeValue(forKey: liveKey)
        publishActiveKeys()
    }

    private func clearAllActivities(reason: ActivityRetirementReason) {
        for task in tokenObservations.values { task.cancel() }
        for task in stateObservations.values { task.cancel() }
        tokenObservations.removeAll()
        stateObservations.removeAll()
        registrations.retireAllLive(reason: reason)
        activities.removeAll()
        publishActiveKeys()
    }

    private func publishActiveKeys() {
        let next = activities.keys.sorted()
        if activeLiveKeys != next { activeLiveKeys = next }
    }

    private func report(_ message: String?) {
        if availabilityMessage != message { availabilityMessage = message }
    }

    private func scheduleRegistrations() {
        registrations.setStartToken(startToken().map(Self.hex))
        for (liveKey, activity) in activities {
            if let token = activity.pushToken.map(Self.hex) {
                registrations.setLiveToken(token, activityID: activity.id, liveKey: liveKey)
            }
        }
        registrations.retry()
    }

    private static func content(state: LiveStatusAttributes.ContentState,
                                item: LiveStatusItem) -> ActivityContent<LiveStatusAttributes.ContentState> {
        let staleDate = item.staleEpochSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? Date().addingTimeInterval(300)
        return .init(state: state, staleDate: staleDate, relevanceScore: state.relevanceScore())
    }

    private static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
}
