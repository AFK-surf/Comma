// ActivityKit exposes concurrent update/end methods but omits Sendable on Activity.
// Keep all references and lifecycle selection on MainActor while importing its legacy annotations.
@preconcurrency import ActivityKit
import Combine
import Foundation

struct TaskActivityPushRegistration: Sendable {
    let activityID: String
    let projection: TaskActivityProjection
    let token: String
}

/// One user-selected Task is followed at a time. WidgetKit only receives public presentation facts.
@MainActor
final class TaskActivityCoordinator: ObservableObject {
    typealias Register = @Sendable (TaskActivityPushRegistration) async throws -> String
    typealias Unregister = @Sendable (String) async throws -> Void
    typealias RegisterStart = @Sendable (String) async throws -> String

    @Published private(set) var followedTaskID: String?
    @Published private(set) var availabilityMessage: String?
    private var activity: Activity<TaskActivityAttributes>?
    private var projection: TaskActivityProjection?
    private var registrationID: String?
    private var startRegistrationID: String?
    private var automaticFollowing = true
    private var startGeneration = 0
    private var accountID: String?
    private var register: Register?
    private var unregister: Unregister?
    private var registerStart: RegisterStart?
    private var tokenObservation: Task<Void, Never>?
    private var stateObservation: Task<Void, Never>?
    private var startObservation: Task<Void, Never>?
    private var activityObservation: Task<Void, Never>?
    private var generation = 0
    private var configurationGeneration = 0
    private var selectionGeneration = 0

    func configure(accountID: String, automaticFollowing: Bool = true,
                   register: @escaping Register, unregister: @escaping Unregister,
                   registerPushToStart: @escaping RegisterStart) async {
        configurationGeneration += 1
        let configurationEpoch = configurationGeneration
        if self.accountID != accountID { await resetAccount() }
        guard configurationEpoch == configurationGeneration else { return }
        self.accountID = accountID
        if startRegistrationID == nil {
            startRegistrationID = UserDefaults.standard.string(forKey: startRegistrationKey(accountID))
        }
        self.register = register
        self.unregister = unregister
        self.registerStart = registerPushToStart
        self.automaticFollowing = automaticFollowing
        await observeAutomaticFollowing()
        guard configurationEpoch == configurationGeneration else { return }
        let epoch = generation
        for candidate in Activity<TaskActivityAttributes>.activities {
            guard configurationEpoch == configurationGeneration else { return }
            if candidate.attributes.accountID != accountID {
                await candidate.end(nil, dismissalPolicy: .immediate)
            } else if activity == nil {
                restore(candidate)
            } else if candidate.id != activity?.id {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard configurationEpoch == configurationGeneration else { return }
        activityObservation?.cancel()
        activityObservation = Task { [weak self] in
            for await candidate in Activity<TaskActivityAttributes>.activityUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation else { return }
                guard candidate.attributes.accountID == accountID else {
                    await candidate.end(nil, dismissalPolicy: .immediate)
                    continue
                }
                if self.activity?.id != candidate.id {
                    // A failed remote revocation must not override the user's
                    // local preference. Manually selected current activities stay.
                    guard self.automaticFollowing else {
                        await candidate.end(nil, dismissalPolicy: .immediate)
                        continue
                    }
                    self.selectionGeneration += 1
                    let selectionEpoch = self.selectionGeneration
                    await self.stopCurrentActivity()
                    guard epoch == self.generation, !Task.isCancelled,
                          selectionEpoch == self.selectionGeneration else {
                        await candidate.end(nil, dismissalPolicy: .immediate)
                        return
                    }
                    self.restore(candidate)
                }
            }
        }
    }

    func follow(_ value: TaskActivityProjection) async {
        guard let accountID else { return }
        let epoch = generation
        selectionGeneration += 1
        let selectionEpoch = selectionGeneration
        if activity?.attributes.taskID == value.taskID {
            await apply(value)
            return
        }
        await stopCurrentActivity()
        guard epoch == generation, self.accountID == accountID,
              selectionEpoch == selectionGeneration else { return }
        guard !value.contentState.presentation.isTerminal else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            availabilityMessage = "Live Activities are disabled in Settings."
            return
        }
        do {
            let attributes = TaskActivityAttributes(accountID: accountID, workspaceID: value.workspaceID,
                                                   groupID: value.groupID, taskID: value.taskID)
            let next = try Activity.request(attributes: attributes,
                                            content: Self.content(value), pushType: .token)
            projection = value
            activity = next
            followedTaskID = value.taskID
            availabilityMessage = nil
            observe(next)
        } catch {
            availabilityMessage = "Live Activity could not start. Open the task in Comma."
        }
    }

    func apply(_ value: TaskActivityProjection) async {
        guard let activity, activity.attributes.taskID == value.taskID,
              activity.attributes.groupID == value.groupID,
              activity.attributes.workspaceID == value.workspaceID else { return }
        if let projection, value.updatedAt < projection.updatedAt { return }
        projection = value
        if value.contentState.presentation.isTerminal {
            await activity.end(Self.content(value), dismissalPolicy: .after(Date().addingTimeInterval(60)))
            if self.activity?.id == activity.id { await clearCurrent() }
        } else {
            await activity.update(Self.content(value))
        }
    }

    func stop() async {
        configurationGeneration += 1
        await resetAccount()
    }

    private func resetAccount() async {
        generation += 1
        selectionGeneration += 1
        startGeneration += 1
        startObservation?.cancel()
        startObservation = nil
        let oldStartRegistration = startRegistrationID
        setStartRegistration(nil)
        activityObservation?.cancel()
        activityObservation = nil
        let oldActivities = Activity<TaskActivityAttributes>.activities
        let oldUnregister = unregister
        accountID = nil
        register = nil
        registerStart = nil
        unregister = nil
        await clearCurrent(unregister: oldUnregister)
        if let id = oldStartRegistration { try? await oldUnregister?(id) }
        for candidate in oldActivities { await candidate.end(nil, dismissalPolicy: .immediate) }
    }

    func stopFollowingCurrent() async {
        selectionGeneration += 1
        await stopCurrentActivity()
    }

    func setAutomaticFollowing(_ enabled: Bool) async {
        automaticFollowing = enabled
        await observeAutomaticFollowing()
    }

    private func observeAutomaticFollowing() async {
        startGeneration += 1
        let epoch = startGeneration
        startObservation?.cancel()
        startObservation = nil
        let oldRegistration = startRegistrationID
        setStartRegistration(nil)
        if let id = oldRegistration {
            do { try await unregister?(id) }
            catch {
                if epoch == startGeneration {
                    setStartRegistration(id)
                    availabilityMessage = "Automatic follow could not be stopped. Reconnect and try again."
                }
                return
            }
        }
        guard automaticFollowing, epoch == startGeneration else { return }
        guard let registerStart else { return }
        startObservation = Task { [weak self] in
            for await token in Activity<TaskActivityAttributes>.pushToStartTokenUpdates {
                guard let self, !Task.isCancelled, self.automaticFollowing,
                      epoch == self.startGeneration else { return }
                do {
                    let id = try await registerStart(Self.hex(token))
                    guard !Task.isCancelled, self.automaticFollowing, epoch == self.startGeneration else {
                        try? await self.unregister?(id)
                        return
                    }
                    self.setStartRegistration(id)
                } catch {
                    if epoch == self.startGeneration && self.automaticFollowing {
                        self.availabilityMessage = "Background task updates are unavailable. Open Comma to refresh."
                    }
                }
            }
        }
    }

    private func restore(_ candidate: Activity<TaskActivityAttributes>) {
        activity = candidate
        followedTaskID = candidate.attributes.taskID
        let state = candidate.content.state
        projection = TaskActivityProjection(workspaceID: candidate.attributes.workspaceID,
            groupID: candidate.attributes.groupID, taskID: candidate.attributes.taskID,
            title: state.title, status: state.status,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(state.updatedAtEpochSeconds)))
        observe(candidate)
    }

    private func startRegistrationKey(_ accountID: String) -> String {
        "comma.activity.push-start." + accountID
    }

    private func setStartRegistration(_ id: String?) {
        startRegistrationID = id
        guard let accountID else { return }
        let key = startRegistrationKey(accountID)
        if let id { UserDefaults.standard.set(id, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func observe(_ candidate: Activity<TaskActivityAttributes>) {
        tokenObservation?.cancel()
        stateObservation?.cancel()
        let epoch = generation
        tokenObservation = Task { [weak self] in
            for await token in candidate.pushTokenUpdates {
                guard let self, !Task.isCancelled, epoch == self.generation,
                      self.activity?.id == candidate.id, let projection = self.projection,
                      let register = self.register else { return }
                do {
                    let id = try await register(.init(activityID: candidate.id, projection: projection,
                                                      token: Self.hex(token)))
                    guard epoch == self.generation, self.activity?.id == candidate.id else {
                        try? await self.unregister?(id)
                        return
                    }
                    self.registrationID = id
                    self.availabilityMessage = nil
                } catch {
                    if epoch == self.generation && self.activity?.id == candidate.id {
                        self.availabilityMessage = "Background task updates are unavailable. Open Comma to refresh."
                    }
                }
            }
        }
        stateObservation = Task { [weak self] in
            for await state in candidate.activityStateUpdates {
                guard let self, !Task.isCancelled, self.activity?.id == candidate.id else { return }
                if state == .dismissed || state == .ended {
                    await self.clearCurrent()
                    return
                }
            }
        }
    }

    private func stopCurrentActivity() async {
        let old = activity
        await clearCurrent()
        await old?.end(nil, dismissalPolicy: .immediate)
    }

    private func clearCurrent(unregister oldUnregister: Unregister? = nil) async {
        tokenObservation?.cancel()
        stateObservation?.cancel()
        tokenObservation = nil
        stateObservation = nil
        let oldRegistration = registrationID
        registrationID = nil
        activity = nil
        projection = nil
        followedTaskID = nil
        let remove = oldUnregister ?? unregister
        if let oldRegistration { try? await remove?(oldRegistration) }
    }

    private static func content(_ value: TaskActivityProjection) -> ActivityContent<TaskActivityAttributes.ContentState> {
        .init(state: value.contentState, staleDate: Date().addingTimeInterval(120))
    }

    private static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
