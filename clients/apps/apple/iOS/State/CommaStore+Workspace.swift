import CommaCore
import Foundation

/// The Workspace and its Router chat: the core resolves them (`chat.resolveWorkspaceChat`), the task list follows the
/// Workspace in focus (`tasks.focus`).
extension CommaStore {
    /// How many times a Workspace still being made is asked about again before the app says it could not.
    private static let maxResolutions = 30

    private var workspacePreferenceKey: String? {
        session.map { "comma.selected-workspace." + configuration.baseURL.absoluteString + "." + $0.user.id }
    }

    func rememberWorkspace(_ workspace: Workspace) {
        if let key = workspacePreferenceKey { workspacePreferences.set(workspace.id, forKey: key) }
    }

    /// Finds the account's Workspace and its Router chat once signed in: the one chosen last on this phone, else the
    /// default one, which the server makes when there is none.
    func connect(_ shown: CommaSession) {
        let current = boundary
        resolving?.cancel()
        followProfile()
        let preferred = workspacePreferenceKey.flatMap { workspacePreferences.string(forKey: $0) }
        resolving = Task { [weak self] in
            guard let self else { return }
            await self.resolve(preferred: preferred, boundary: current)
        }
    }

    func chooseWorkspace(_ value: Workspace) async {
        guard value.id != workspace?.id else { return }
        let current = boundary
        resolving?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolve(preferred: value.id, boundary: current)
        }
        resolving = task
        await task.value
    }

    private func resolve(preferred initial: String?, boundary current: Int) async {
        var preferred = initial
        var wait: Int?
        loading = workspace == nil
        defer { if boundary == current { loading = false } }
        for _ in 0..<Self.maxResolutions {
            var params: [String: Any] = [:]
            if let preferred { params["workspaceId"] = preferred }
            if let wait { params["afterProvisioning"] = wait }
            let answer: NSDictionary
            do {
                answer = try await core.object("chat.resolveWorkspaceChat", params)
            } catch {
                guard boundary == current, !Task.isCancelled else { return }
                if workspace == nil { productFailed = true; tasksLoaded = true; taskListFailed = true }
                present(error, boundary: current)
                return
            }
            guard boundary == current, !Task.isCancelled else { return }
            switch answer.string("status") {
            case "ready":
                guard let id = answer.string("workspaceId"), let group = answer.string("groupId"),
                      let chat = answer.string("conversationId") else { return }
                let name = workspaces.first { $0.id == id }?.name ?? ""
                install(Workspace(id: id, groupID: group, name: name), chat: chat)
                productFailed = false
                return
            case "provisioning":
                let seconds = max(1, answer.int("retryAfterSeconds") ?? 2)
                wait = seconds
            case "hidden":
                // The Workspace chosen last is no longer this account's: the default one, then.
                guard preferred != nil else {
                    productFailed = true; tasksLoaded = true; taskListFailed = true
                    return
                }
                preferred = nil
            default:
                // The core's session lifecycle hears the same refusal and ends the session.
                return
            }
        }
        productFailed = workspace == nil
    }

    /// Shows `value` and its Router chat `chat`; a Task of the Workspace before closes.
    private func install(_ value: Workspace, chat: String) {
        if workspace?.id != value.id || router.pane?.conversationID != chat {
            closeTask()
            router.pane?.close()
            let pane = ConversationPane(kind: .router, workspace: value, conversationID: chat, store: self)
            router.install(pane)
            pane.open()
            routines.reset()
            skills.reset()
            mentionModels.reset()
            taskActivity = nil
            activityRequest += 1
        }
        let changed = workspace?.id != value.id
        workspace = value
        rememberWorkspace(value)
        if changed {
            tasks = []; tasksLoaded = false; taskListFailed = false; hasMoreTasks = false
            pinnedTaskIDs = []; taskBoardOrder = []
            lastTaskList = nil
            followTasks(value)
            followPins(value)
            followTaskOrder(value)
            onWorkspaceChanged?(value)
        }
    }

    /// Opens the Router chat again when it was closed (a sign-in, a Workspace chosen).
    func openRouter() async {
        guard let pane = router.pane else { return }
        if pane.closed { pane.open() }
    }

    /// Reads the task list and the open conversations again, as a pull to refresh asks.
    func refresh() async {
        guard session != nil else { return }
        guard workspace != nil else {
            if let session { connect(session) }
            return
        }
        await refreshTaskList()
        for pane in panes { pane.refresh() }
        await loadProfile()
    }

    // MARK: Profile

    /// Follows the account's profile (the core's `profile` topic): the name and the avatar's revision.
    func followProfile() {
        profileWatch?.cancel()
        let current = boundary
        let updates = core.subscribe(["topic": "profile"]) { value -> (UserProfile?, read: Bool) in
            let json = value as? NSDictionary
            return (CoreJSON(value: json?.object("profile")).decode(UserProfile.self), json?.string("status") != "loading")
        }
        profileWatch = Task { [weak self] in
            for await value in updates {
                guard let self, self.boundary == current, case .value(let next) = value else { continue }
                if self.profileRead != next.read { self.profileRead = next.read }
                await self.install(profile: next.0, boundary: current)
            }
        }
    }

    /// Reads the profile again, as a pull to refresh asks.
    func loadProfile() async { _ = try? await core.call("profile.refresh") }
    func reloadProfile() async { await loadProfile() }

    func updateProfile(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= UserProfile.maxNameLength else {
            throw CoreError(code: "invalid_params", message: String(localized: "Enter a name of at most \(UserProfile.maxNameLength) characters."))
        }
        // The core's `profile` shows the name at once, and the saved one again if the server refuses it.
        _ = try await core.call("profile.update", ["name": trimmed])
    }

    /// The core shows the new photo everywhere at once while it uploads (`files.read` answers its bytes), and the
    /// saved one again if the upload fails.
    func uploadAvatar(_ data: Data, contentType: String) async throws {
        let name = "avatar." + (contentType == "image/png" ? "png" : contentType == "image/webp" ? "webp" : "jpg")
        _ = try await core.call("profile.uploadAvatar", ["bytes": CoreBytes.json(data), "type": contentType, "name": name])
    }

    /// The core takes the photo down at once while the server removes it, and puts it back if that fails.
    func removeAvatar() async throws {
        _ = try await core.call("profile.removeAvatar")
    }

    private func install(profile value: UserProfile?, boundary current: Int) async {
        let changedAvatar = value?.avatarID != profile?.avatarID
        profile = value
        guard changedAvatar else { return }
        guard let id = value?.avatarID else { avatarData = nil; return }
        guard let answer = try? await core.object("files.read", ["source": "avatar", "revision": id]),
              let data = CoreBytes.read(answer["bytes"]), boundary == current, profile?.avatarID == id else { return }
        avatarData = data
    }
}
