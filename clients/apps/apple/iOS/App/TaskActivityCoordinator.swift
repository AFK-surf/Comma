// ActivityKit's legacy Activity references remain on MainActor.
@preconcurrency import ActivityKit
import Combine
import Foundation
import CommaCore

/// One Workspace activity presents the server's current two eligible Tasks.
@MainActor
final class TaskActivityCoordinator: ObservableObject {
    @Published private(set) var followedTaskIDs: [String] = []
    @Published private(set) var availabilityMessage: String?
    private var activity: Activity<TaskActivityAttributes>?
    private var projection: TaskActivityProjection?
    private var accountID: String?
    private var workspace: Workspace?
    private var channel: (any ActivityNotificationTransport)?
    private var automaticFollowing = true
    private var dismissedCohort: Set<String>?
    private var generation = 0
    private var configurationGeneration = 0
    private var applyRevision = 0
    private var tokenObservation: Task<Void, Never>?
    private var stateObservation: Task<Void, Never>?
    private var startObservation: Task<Void, Never>?
    private var activityObservation: Task<Void, Never>?
    private let startToken: @MainActor () -> Data?
    private let registrations: ActivityRegistrationController

    init(startToken: @escaping @MainActor () -> Data? = { Activity<TaskActivityAttributes>.pushToStartToken },
         preferences: UserDefaults = .standard) {
        self.startToken = startToken
        registrations = ActivityRegistrationController(preferences: preferences)
        registrations.onFailure = { [weak self] in
            self?.report("Background task updates are unavailable. Reconnect and try again.")
        }
        registrations.onSuccess = { [weak self] in self?.report(nil) }
    }

    func settleRegistrations() async { await registrations.settle() }

    func configure(accountID: String, workspace: Workspace, origin: String, automaticFollowing: Bool,
                   channel: any ActivityNotificationTransport) async {
        configurationGeneration += 1
        let configurationEpoch = configurationGeneration
        let changed = self.accountID != accountID || self.workspace?.id != workspace.id || self.workspace?.groupID != workspace.groupID || self.channel?.sessionID != channel.sessionID
        if changed {
            generation += 1
            registrations.stop(reason: .authorityChanged)
            applyRevision += 1
            await stopCurrentActivity(reason: .authorityChanged)
            guard configurationEpoch == configurationGeneration else { return }
            startObservation?.cancel(); activityObservation?.cancel()
            self.accountID = accountID; self.workspace = workspace; self.channel = channel
            dismissedCohort = nil
            registrations.configure(channel: channel, workspace: workspace, origin: origin, enabled: automaticFollowing,
                                    restoredActivityIDs: Set(Activity<TaskActivityAttributes>.activities.filter { matches($0) }.map(\.id)))
            dismissedCohort = registrations.dismissedCohort
        }
        self.automaticFollowing = automaticFollowing
        registrations.setEnabled(automaticFollowing)
        let epoch = generation
        for candidate in Activity<TaskActivityAttributes>.activities {
            guard epoch == generation, configurationEpoch == configurationGeneration else { return }
            if !matches(candidate) || !automaticFollowing {
                await candidate.end(nil, dismissalPolicy: .immediate)
            } else if dismissedCohort == Set(candidate.content.state.tasks.map(\.id)) {
                registrations.retireLive(reason: .stopped)
                await candidate.end(nil, dismissalPolicy: .immediate)
            } else if activity == nil {
                restore(candidate)
            } else if candidate.id != activity?.id {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard epoch == generation, configurationEpoch == configurationGeneration else { return }
        startObservation?.cancel()
        startObservation = Task { [weak self] in
            for await _ in Activity<TaskActivityAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                self.scheduleRegistrations()
            }
        }
        activityObservation?.cancel()
        activityObservation = Task { [weak self] in
            for await candidate in Activity<TaskActivityAttributes>.activityUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                guard self.matches(candidate), self.automaticFollowing,
                      self.dismissedCohort != Set(candidate.content.state.tasks.map(\.id)) else {
                    await candidate.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                if candidate.id != self.activity?.id {
                    await self.stopCurrentActivity(reason: .finished)
                    guard epoch == self.generation else { return }
                    self.restore(candidate)
                }
            }
        }
        scheduleRegistrations()
    }

    func apply(_ value: TaskActivityProjection) async {
        guard let accountID, let workspace, value.workspaceID == workspace.id, value.groupID == workspace.groupID,
              value.tasks.count <= 2 else { return }
        // Membership, rather than timestamps, controls stopping. The remaining Task may be older.
        if dismissedCohort != value.cohort { dismissedCohort = nil; registrations.setDismissedCohort(nil) }
        projection = value
        applyRevision += 1
        let revision = applyRevision
        let epoch = generation
        guard automaticFollowing, dismissedCohort != value.cohort else { return }
        if value.tasks.isEmpty {
            await stopCurrentActivity(reason: .finished)
            return
        }
        if let current = activity {
            if current.content.state != value.contentState { await current.update(Self.content(value)) }
            guard epoch == generation, revision == applyRevision, automaticFollowing,
                  self.activity?.id == current.id else { return }
            follow(value.tasks.map(\.id))
            scheduleRegistrations()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            report("Live Activities are disabled in Settings.")
            return
        }
        do {
            let next = try Activity.request(attributes: TaskActivityAttributes(accountID: accountID,
                workspaceID: workspace.id, groupID: workspace.groupID), content: Self.content(value), pushType: .token)
            activity = next; follow(value.tasks.map(\.id))
            report(nil)
            observe(next)
        } catch { report("Live Activity could not start. Reconnect and try again.") }
    }

    func retry() async {
        scheduleRegistrations()
        if let projection { await apply(projection) }
    }

    func reportRefreshFailure() {
        report("Task progress could not refresh. Reconnect and try again.")
    }

    func setAutomaticFollowing(_ enabled: Bool) async {
        automaticFollowing = enabled
        applyRevision += 1
        registrations.setEnabled(enabled)
        if !enabled {
            await stopCurrentActivity(reason: .disabled)
        } else {
            dismissedCohort = nil
            registrations.setDismissedCohort(nil)
            if let projection { await apply(projection) }
        }
        scheduleRegistrations()
    }

    func stopFollowingCurrent() async {
        dismissedCohort = activity.map { Set($0.content.state.tasks.map(\.id)) } ?? projection?.cohort ?? Set(followedTaskIDs)
        registrations.setDismissedCohort(dismissedCohort)
        applyRevision += 1
        await stopCurrentActivity(reason: .stopped)
    }

    func stop() async {
        configurationGeneration += 1
        generation += 1
        applyRevision += 1
        let old = activity
        clearCurrent(reason: .authorityChanged)
        registrations.stop(reason: .authorityChanged)
        startObservation?.cancel(); startObservation = nil
        activityObservation?.cancel(); activityObservation = nil
        accountID = nil; workspace = nil; channel = nil; projection = nil
        dismissedCohort = nil
        await old?.end(nil, dismissalPolicy: .immediate)
    }

    private func matches(_ candidate: Activity<TaskActivityAttributes>) -> Bool {
        candidate.attributes.accountID == accountID && candidate.attributes.workspaceID == workspace?.id && candidate.attributes.groupID == workspace?.groupID
    }

    private func restore(_ candidate: Activity<TaskActivityAttributes>) {
        activity = candidate
        projection = .init(workspaceID: candidate.attributes.workspaceID, groupID: candidate.attributes.groupID,
                           tasks: Array(candidate.content.state.tasks.prefix(2)))
        follow(projection?.tasks.map(\.id) ?? [])
        observe(candidate)
    }

    private func observe(_ candidate: Activity<TaskActivityAttributes>) {
        tokenObservation?.cancel(); stateObservation?.cancel()
        let epoch = generation
        tokenObservation = Task { [weak self] in
            for await _ in candidate.pushTokenUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation, self.activity?.id == candidate.id else { return }
                self.scheduleRegistrations()
            }
        }
        stateObservation = Task { [weak self] in
            for await state in candidate.activityStateUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation, self.activity?.id == candidate.id else { return }
                if state == .dismissed || state == .ended {
                    if state == .dismissed {
                        self.dismissedCohort = Set(candidate.content.state.tasks.map(\.id))
                        self.registrations.setDismissedCohort(self.dismissedCohort)
                    }
                    self.applyRevision += 1
                    self.clearCurrent(reason: state == .dismissed ? .dismissed : .finished)
                    return
                }
            }
        }
        scheduleRegistrations()
    }

    private func stopCurrentActivity(reason: ActivityRetirementReason) async {
        let old = activity
        clearCurrent(reason: reason)
        await old?.end(nil, dismissalPolicy: .immediate)
    }

    private func clearCurrent(reason: ActivityRetirementReason) {
        tokenObservation?.cancel(); stateObservation?.cancel()
        tokenObservation = nil; stateObservation = nil
        registrations.retireLive(reason: reason)
        activity = nil; follow([])
    }

    // @Published announces every assignment, equal or not, and the app's root shell observes this object.
    private func follow(_ ids: [String]) { if followedTaskIDs != ids { followedTaskIDs = ids } }
    private func report(_ message: String?) { if availabilityMessage != message { availabilityMessage = message } }

    private func scheduleRegistrations() {
        registrations.setStartToken(startToken().map(Self.hex))
        if let activity, let token = activity.pushToken.map(Self.hex) {
            registrations.setLiveToken(token, activityID: activity.id)
        }
        registrations.retry()
    }

    private static func content(_ value: TaskActivityProjection) -> ActivityContent<TaskActivityAttributes.ContentState> {
        .init(state: value.contentState, staleDate: Date().addingTimeInterval(120))
    }
    private static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
}
