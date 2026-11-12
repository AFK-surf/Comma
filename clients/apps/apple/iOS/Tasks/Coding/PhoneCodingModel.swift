import Foundation
import Observation
import CommaCore

struct PhoneCodingRepo: Identifiable, Equatable {
    let owner: String
    let name: String
    let base: String?
    var id: String { owner + "/" + name }
    init?(_ json: NSDictionary) {
        guard let owner = json.string("owner"), let name = json.string("name") else { return nil }
        self.owner = owner; self.name = name; base = json.string("defaultBranch")
    }
}

struct PhoneRepositoryOwner: Identifiable, Equatable {
    let login: String
    let kind: String
    let avatarURL: URL?
    var id: String { login.lowercased() }
    init?(_ json: NSDictionary) {
        guard let login = json.string("login"), let kind = json.string("kind") else { return nil }
        self.login = login; self.kind = kind
        avatarURL = json.string("avatarUrl").flatMap(URL.init(string:))
    }
}

/// A sheet-local draft. Each search reads one page; typing waits 300 ms, with no polling or owner fan-out.
@MainActor @Observable final class PhoneRepositoryPickerModel: Identifiable {
    let scope: WorkspaceSettingsScope
    var selected: PhoneCodingRepo?
    var owner: PhoneRepositoryOwner? {
        didSet { if owner != oldValue { query = ""; resetSearch() } }
    }
    var query = "" {
        didSet { if query != oldValue { resetSearch() } }
    }
    private(set) var owners: [PhoneRepositoryOwner] = []
    private(set) var repos: [PhoneCodingRepo] = []
    private(set) var ownersLoaded = false
    private(set) var ownersLoading = false
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var moreOwners = false
    private(set) var moreRepos = false
    private(set) var limited = false
    private(set) var error: String?
    private var ownersPage = 0
    private var repoPage = 0
    private var generation = 0

    init(scope: WorkspaceSettingsScope, selected: PhoneCodingRepo?) {
        self.scope = scope; self.selected = selected
    }

    var searchKey: String { (owner?.id ?? "") + "\t" + query }
    var visibleOwners: [PhoneRepositoryOwner] {
        owners.filter { query.isEmpty || $0.login.localizedStandardContains(query) }
    }

    private func resetSearch() {
        generation += 1; repos = []; repoPage = 0; moreRepos = false
        loaded = false; loading = false; limited = false; error = nil
    }

    func loadOwners(more: Bool = false) async {
        guard scope.current, !ownersLoading, !more || moreOwners else { return }
        ownersLoading = true; defer { ownersLoading = false }
        let page = more ? ownersPage + 1 : 1
        do {
            let answer = try await scope.call("coding.repoOwners", ["workspaceId": scope.workspace.id, "page": page], workspaceParameter: false)
            let next = answer.object?.objects("owners").compactMap(PhoneRepositoryOwner.init) ?? []
            var seen = Set<String>()
            owners = ((more ? owners : []) + next).filter { seen.insert($0.id).inserted }
            ownersPage = page; moreOwners = answer.object?.bool("hasMore") == true; ownersLoaded = true
            error = nil
        } catch is CancellationError { }
        catch { if scope.current { self.error = error.localizedDescription } }
    }

    func search(debounce: Bool = true) async {
        guard owner != nil else { if !ownersLoaded { await loadOwners() }; return }
        let version = generation
        if debounce, !query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard version == generation, !Task.isCancelled else { return }
        await loadRepos()
    }

    func loadRepos(more: Bool = false) async {
        guard scope.current, let owner, !loading, !more || moreRepos else { return }
        let version = generation
        let page = more ? repoPage + 1 : 1
        loading = true; error = nil
        defer { if generation == version { loading = false } }
        do {
            let answer = try await scope.call("coding.repoSearch", ["workspaceId": scope.workspace.id,
                "owner": owner.login, "kind": owner.kind, "query": query.trimmingCharacters(in: .whitespacesAndNewlines), "page": page], workspaceParameter: false)
            guard version == generation, !Task.isCancelled else { return }
            let next = answer.object?.objects("repos").compactMap(PhoneCodingRepo.init) ?? []
            var seen = Set<String>()
            repos = ((more ? repos : []) + next).filter { seen.insert($0.id).inserted }
            repoPage = page; moreRepos = answer.object?.bool("hasMore") == true
            limited = answer.object?.bool("limited") == true; loaded = true
        } catch is CancellationError { }
        catch { if scope.current, generation == version { self.error = error.localizedDescription } }
    }
}

struct PhoneCodingRun: Identifiable {
    let runtime: String
    let profile: String?
    let model: String?
    let label: String
    var id: String { [runtime, profile ?? "", model ?? ""].joined(separator: "\t") }
}

struct PhoneTaskEnvironment: Identifiable {
    let id: String
    let name: String
    let online: Bool
}

@MainActor @Observable final class PhoneNewTaskModel {
    let scope: WorkspaceSettingsScope
    let models: PhoneModelsModel
    var text = ""
    var environmentID = ""
    var cloudModelID = ""
    private(set) var stations: [NSDictionary] = []
    private(set) var environmentsLoaded = false
    private(set) var stationProfiles: [NSDictionary] = []
    private var profilesStation: String?
    private(set) var profilesLoaded = false
    private(set) var profilesError: String?
    private var profileGeneration = 0
    private(set) var starting = false
    var repoID = "" {
        didSet {
            guard repoID != oldValue else { return }
            branchGeneration += 1; branch = ""; branches = []; moreBranches = false
        }
    }
    var branch = ""
    var runID = ""
    private(set) var repos: [PhoneCodingRepo] = []
    private(set) var branches: [String] = []
    private(set) var loading = false
    private(set) var reposLoaded = false
    private(set) var moreRepos = false
    private(set) var moreBranches = false
    private var repoPage = 1
    private var branchPage = 1
    private var branchGeneration = 0
    // Kept across an ambiguous failure. Retrying cannot create a second Task.
    private var key = UUID().uuidString
    private(set) var created: String?

    init(store: CommaStore, workspace: Workspace) {
        scope = WorkspaceSettingsScope(store: store, workspace: workspace)
        models = PhoneModelsModel(store: store, workspace: workspace)
    }

    var sandboxesAvailable: Bool { models.value.object?.object("agents")?.object("task_place")?.bool("sandboxes") == true }
    var inCoding: Bool { environmentID == "sandbox" }
    var inSandbox: Bool { inCoding || environmentID == "plain_sandbox" }
    var inCloud: Bool { environmentID == "salix" }
    var environments: [PhoneTaskEnvironment] {
        [.init(id: "salix", name: String(localized: "Comma cloud"), online: true),
         .init(id: "sandbox", name: String(localized: "Write code"), online: true)] +
        (sandboxesAvailable ? [.init(id: "plain_sandbox", name: String(localized: "Sandbox"), online: true)] : []) +
        stations.compactMap { station in
            guard let id = station.string("id") else { return nil }
            return .init(id: id, name: station.string("name") ?? id, online: station.object("link")?.string("state") == "online")
        }
    }
    var cloudModels: [PhoneModelOption] {
        let preferred = models.taskSelection.model
        let served = models.models.filter { !$0.serving.isEmpty }
        return served.filter { $0.id == preferred } + served.filter { $0.id != preferred }
    }
    var cloudModel: PhoneModelOption? { cloudModels.first { $0.id == cloudModelID } ?? cloudModels.first }
    var canStart: Bool {
        guard scope.current, environmentsLoaded, models.loaded, !starting, created == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              environments.contains(where: { $0.id == environmentID && $0.online }) else { return false }
        if inCloud { return cloudModel != nil }
        if inCoding { return repo != nil && run != nil }
        return run != nil
    }

    func followEnvironments() async {
        for await update in scope.store.core.subscribe(["topic": "stations", "workspace": scope.workspace.id], read: { CoreJSON(value: $0) }) {
            guard scope.current, !Task.isCancelled else { return }
            switch update {
            case .value(let value):
                guard let json = value.object, json.string("workspace") == scope.workspace.id else { continue }
                stations = json.objects("stations")
                environmentsLoaded = !json.bool("loading") || json.string("error") != nil
            case .failed: environmentsLoaded = true
            }
            // The first resolved choice holds through later presence updates, as on desktop.
            if environmentsLoaded, environmentID.isEmpty {
                environmentID = stations.first { $0.object("link")?.string("state") == "online" }?.string("id") ?? "salix"
            }
        }
    }

    func loadEnvironment() async {
        profileGeneration += 1
        let generation = profileGeneration
        stationProfiles = []; profilesStation = nil; profilesLoaded = false; profilesError = nil; runID = ""
        guard !inCloud, !inSandbox, !environmentID.isEmpty else { return }
        let station = environmentID
        do {
            let answer = try await scope.call("stations.profiles", ["station": station])
            guard generation == profileGeneration, environmentID == station else { return }
            stationProfiles = answer.array?.compactMap { $0 as? NSDictionary } ?? []
            profilesStation = station; profilesLoaded = true
        } catch is CancellationError { }
        catch {
            guard scope.current, generation == profileGeneration else { return }
            profilesError = error.localizedDescription; profilesLoaded = true
        }
    }

    var repo: PhoneCodingRepo? { repos.first { $0.id == repoID } }
    func selectRepository(_ repo: PhoneCodingRepo) {
        if !repos.contains(where: { $0.id == repo.id }) { repos.append(repo) }
        repoID = repo.id
    }

    var runs: [PhoneCodingRun] {
        guard inSandbox else {
            guard profilesStation == environmentID else { return [] }
            return stationProfiles.flatMap { profile -> [PhoneCodingRun] in
                guard let id = profile.string("id"), let runtime = profile.strings("runtimes").first else { return [] }
                let name = profile.string("name") ?? runtime
                let models = profile.strings("models")
                if models.isEmpty { return [.init(runtime: runtime, profile: id, model: profile.string("model"), label: name)] }
                return models.map { .init(runtime: runtime, profile: id, model: $0, label: name + " · " + $0) }
            }
        }
        return ["codex", "claude"].flatMap { runtime -> [PhoneCodingRun] in
            let profiles = models.profiles.filter { $0.bool("subscription") && $0.bool("usable") && $0.string("source") == runtime }
            if profiles.isEmpty { return [.init(runtime: runtime, profile: nil, model: nil, label: runtime == "codex" ? "Codex" : "Claude Code")] }
            return profiles.flatMap { profile -> [PhoneCodingRun] in
                guard let id = profile.string("id") else { return [] }
                let account = profile.string("name") ?? profile.string("email") ?? runtime
                return [.init(runtime: runtime, profile: id, model: nil, label: account + " · " + String(localized: "Default"))] +
                    models.models.filter { $0.serving.contains(id) }.map {
                        .init(runtime: runtime, profile: id, model: $0.id, label: account + " · " + $0.name)
                    }
            }
        }
    }
    var run: PhoneCodingRun? { runs.first { $0.id == runID } ?? runs.first }

    func loadRepos(more: Bool = false) async {
        guard !loading, scope.current, inCoding else { return }
        loading = true; defer { loading = false }
        let page = more ? repoPage + 1 : 1
        do {
            let result = try await scope.call("coding.repos", ["workspaceId": scope.workspace.id, "page": page], workspaceParameter: false)
            let next = result.array?.compactMap { ($0 as? NSDictionary).flatMap(PhoneCodingRepo.init) } ?? []
            var seen = Set<String>()
            repos = ((more ? repos : []) + next).filter { seen.insert($0.id).inserted }
            repoPage = page; moreRepos = page < 100 && next.count == 100; reposLoaded = true; scope.error = nil
        } catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }

    func loadBranches(more: Bool = false) async {
        branchGeneration += 1
        let generation = branchGeneration
        guard let repo else { branches = []; branch = ""; moreBranches = false; return }
        if !more { branches = []; branch = ""; moreBranches = false }
        let page = more ? branchPage + 1 : 1
        do {
            let result = try await scope.call("coding.branches", ["workspaceId": scope.workspace.id, "owner": repo.owner, "name": repo.name, "page": page], workspaceParameter: false)
            guard generation == branchGeneration else { return }
            let next = result.array?.compactMap { $0 as? String } ?? []
            var seen = Set<String>()
            branches = ((more ? branches : []) + next).filter { seen.insert($0).inserted }
            branchPage = page; moreBranches = page < 100 && next.count == 100
        } catch is CancellationError { }
        catch { if scope.current, generation == branchGeneration { scope.error = error.localizedDescription } }
    }

    func start() async -> String? {
        guard scope.current else { return nil }
        if let created { return created }
        guard canStart else { return nil }
        starting = true; scope.error = nil
        defer { starting = false }
        let method: String
        var params: [String: Any] = ["key": key, "text": text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if inCloud, let model = cloudModel {
            method = "chat.startTask"
            params["workspaceId"] = scope.workspace.id
            params["model"] = ["id": model.id, "name": model.name]
        } else if inSandbox, let run {
            method = "coding.start"
            params["workspaceId"] = scope.workspace.id
            var runtime: [String: Any] = ["provider": run.runtime]
            if let model = run.model { runtime["model"] = model }
            params["model"] = runtime
            if inCoding, let repo {
                var value = ["owner": repo.owner, "name": repo.name]
                if !branch.isEmpty { value["baseRef"] = branch }
                params["repo"] = value
            }
            if let account = run.profile { params["accountId"] = account }
        } else if let run, let profile = run.profile {
            method = "stations.newTask"
            params["workspace"] = scope.workspace.id
            params["station"] = environmentID; params["profile"] = profile; params["runtime"] = run.runtime
            if let model = run.model { params["model"] = model }
        } else { return nil }
        do {
            let answer = try await scope.call(method, params, workspaceParameter: false)
            created = answer.object?.string(method == "coding.start" ? "taskId" : "conversationId")
            return created
        } catch is CancellationError { return nil }
        catch {
            if scope.current {
                if (error as? CoreError)?.code == "refused" { key = UUID().uuidString }
                scope.error = error.localizedDescription
            }
            return nil
        }
    }

}

@MainActor @Observable final class PhoneCodingModel {
    let scope: WorkspaceSettingsScope
    let task: String
    private(set) var session = CoreJSON(value: nil)
    private(set) var changes = CoreJSON(value: nil)
    private(set) var history = CoreJSON(value: nil)
    private(set) var historyItems: [CoreJSON] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var branchCommits: [CoreJSON] = []
    private(set) var hasUncommitted = false
    var selection = ""
    var prTitle = ""
    var prBody = ""
    var prDraft = true
    private(set) var reviewedPR = CoreJSON(value: nil)

    init(store: CommaStore, workspace: Workspace, task: String) {
        scope = WorkspaceSettingsScope(store: store, workspace: workspace); self.task = task
    }
    var params: [String: Any] { ["workspaceId": scope.workspace.id, "taskId": task] }
    var pr: NSDictionary? { reviewedPR.object }
    var files: [NSDictionary] { changes.object?.objects("files") ?? [] }
    var commits: [NSDictionary] { branchCommits.compactMap(\.object) }

    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            session = try await scope.call("coding.session", params, workspaceParameter: false)
            await loadChanges()
            loaded = true
        } catch is CancellationError { }
        catch { if scope.current { loaded = true; scope.error = error.localizedDescription } }
    }

    func loadChanges() async {
        var params = params
        if selection == "uncommitted" { params["uncommitted"] = true }
        else if !selection.isEmpty { params["commit"] = selection }
        do {
            let answer = try await scope.call("coding.changes", params, workspaceParameter: false)
            changes = answer
            if selection.isEmpty {
                branchCommits = answer.object?.objects("commits").map { CoreJSON(value: $0) } ?? []
                hasUncommitted = answer.object?.bool("uncommitted") == true
                reviewedPR = CoreJSON(value: answer.object?.object("pullRequest"))
                prTitle = pr?.text("title") ?? ""; prBody = pr?.text("body") ?? ""
            }
            scope.error = nil
        } catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }

    func loadHistory(more: Bool = false) async {
        var params = params
        if more, let start = history.object?.int("start"), start > 0 { params["before"] = start }
        do {
            let answer = try await scope.call("coding.history", params, workspaceParameter: false)
            let next = answer.object?.objects("items").map { CoreJSON(value: $0) } ?? []
            historyItems = more ? historyItems + next : next; history = answer
        } catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }

    func savePR() async -> Bool {
        var params = params
        params["title"] = prTitle; params["body"] = prBody
        if pr == nil || pr?.bool("newCommits") == true { params["draft"] = prDraft }
        let method = pr == nil || pr?.bool("newCommits") == true ? "coding.pullRequest" : "coding.updatePullRequest"
        guard await scope.perform(method, params, workspaceParameter: false) != nil else { return false }
        selection = ""; await loadChanges(); return true
    }

    func readyPR() async {
        var params = params; params["ready"] = true
        if await scope.perform("coding.updatePullRequest", params, workspaceParameter: false) != nil { selection = ""; await loadChanges() }
    }

    /// The confirmation holds the exact PR and head the person reviewed. Refreshes cannot advance it.
    func merge(number: Int, head: String) async {
        var params = params; params["number"] = number; params["headSha"] = head
        if await scope.perform("coding.mergePullRequest", params, workspaceParameter: false) != nil { selection = ""; await loadChanges() }
    }

    func terminal() async -> URL? {
        let answer = await scope.perform("coding.terminal", params, workspaceParameter: false)
        guard let text = answer?.object?.string("url"), let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
}
