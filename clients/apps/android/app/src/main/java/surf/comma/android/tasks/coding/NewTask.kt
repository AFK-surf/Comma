package surf.comma.android.tasks.coding

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.workspace.WorkspaceCalls
import java.util.UUID

/** A GitHub repository the Workspace's connected account reaches. */
data class CodingRepo(val owner: String, val name: String, val base: String?) {
    val id: String get() = "$owner/$name"

    companion object {
        fun parse(json: JSONObject): CodingRepo? {
            val owner = json.text("owner") ?: return null
            val name = json.text("name") ?: return null
            return CodingRepo(owner, name, json.text("defaultBranch"))
        }
    }
}

/** The connected GitHub account (`user`) or one of its organizations, with its avatar's https address. */
data class RepositoryOwner(val login: String, val kind: String, val avatarUrl: String?) {
    val id: String get() = login.lowercase()

    companion object {
        fun parse(json: JSONObject): RepositoryOwner? {
            val login = json.text("login") ?: return null
            val kind = json.text("kind") ?: return null
            return RepositoryOwner(login, kind, json.text("avatarUrl")?.takeIf { it.startsWith("https://") })
        }
    }
}

/**
 * The repository picker's draft, local to its sheet until Confirm. Owners and repositories are read a page at a time
 * (at most 100 rows); a name search runs on the server within the chosen owner once typing pauses for 300 ms. Nothing
 * polls and no request is made per row or per owner.
 */
class RepositoryPicker(private val calls: WorkspaceCalls, var selected: CodingRepo?) {
    var onChange: () -> Unit = {}
    var owners: List<RepositoryOwner> = emptyList(); private set
    var repos: List<CodingRepo> = emptyList(); private set
    var ownersLoaded = false; private set
    var ownersLoading = false; private set
    var loading = false; private set
    var loaded = false; private set
    var moreOwners = false; private set
    var moreRepos = false; private set
    var limited = false; private set
    var error: String? = null; private set
    private var ownersPage = 0
    private var repoPage = 0
    private var generation = 0

    var owner: RepositoryOwner? = null
        private set
    var query = ""
        private set

    /** Organizations filter by name as the member types; inside an owner the server searches. */
    val visibleOwners: List<RepositoryOwner> get() = owners.filter { query.isEmpty() || it.login.contains(query, ignoreCase = true) }

    fun choose(next: RepositoryOwner?) {
        if (next == owner) return
        owner = next
        query = ""
        resetSearch()
    }

    fun type(next: String) {
        if (next == query) return
        query = next
        resetSearch()
    }

    private fun resetSearch() {
        generation++
        repos = emptyList(); repoPage = 0; moreRepos = false
        loaded = false; loading = false; limited = false; error = null
        onChange()
    }

    suspend fun loadOwners(more: Boolean = false) {
        if (!calls.current || ownersLoading || (more && !moreOwners)) return
        ownersLoading = true
        onChange()
        val page = if (more) ownersPage + 1 else 1
        try {
            val answer = calls.call("coding.repoOwners", JSONObject().put("workspaceId", calls.workspaceId).put("page", page)) as? JSONObject
            val next = answer?.objects("owners").orEmpty().mapNotNull(RepositoryOwner::parse)
            owners = ((if (more) owners else emptyList()) + next).distinctBy { it.id }
            ownersPage = page
            moreOwners = answer?.optBoolean("hasMore") == true
            ownersLoaded = true
            error = null
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (calls.current) error = WorkspaceCalls.message(failure)
        } finally {
            ownersLoading = false
            onChange()
        }
    }

    /** Reads the chosen owner's repositories for the current words, after the typing pause when [debounce]. */
    suspend fun search(debounce: Boolean = true) {
        if (owner == null) { if (!ownersLoaded) loadOwners(); return }
        val version = generation
        if (debounce && query.isNotEmpty()) delay(SEARCH_PAUSE_MS)
        if (version != generation) return
        loadRepos()
    }

    suspend fun loadRepos(more: Boolean = false) {
        val owner = owner ?: return
        if (!calls.current || loading || (more && !moreRepos)) return
        val version = generation
        val page = if (more) repoPage + 1 else 1
        loading = true
        error = null
        onChange()
        try {
            val answer = calls.call("coding.repoSearch", JSONObject().put("workspaceId", calls.workspaceId).put("owner", owner.login)
                .put("kind", owner.kind).put("query", query.trim()).put("page", page)) as? JSONObject
            if (version != generation) return
            val next = answer?.objects("repos").orEmpty().mapNotNull(CodingRepo::parse)
            repos = ((if (more) repos else emptyList()) + next).distinctBy { it.id }
            repoPage = page
            moreRepos = answer?.optBoolean("hasMore") == true
            limited = answer?.optBoolean("limited") == true
            loaded = true
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (calls.current && version == generation) error = WorkspaceCalls.message(failure)
        } finally {
            if (version == generation) loading = false
            onChange()
        }
    }

    private companion object { const val SEARCH_PAUSE_MS = 300L }
}

/** One way to run a Task: its runtime, the account (profile) and model, as the menu names it. */
data class CodingRun(val runtime: String, val profile: String?, val model: String?, val label: String) {
    val id: String get() = listOf(runtime, profile.orEmpty(), model.orEmpty()).joinToString("\t")
}

/** Where a Task can run: Comma's cloud, a coding or plain sandbox, or one of the Workspace's computers. */
data class TaskEnvironment(val id: String, val name: String, val online: Boolean)

/** A model the Workspace serves. */
data class ModelOption(val id: String, val name: String, val serving: List<String>)

/**
 * The New task form, as the iOS app's: the environment (Comma cloud, Write code, a sandbox when the Workspace offers
 * them, or a Workspace computer that is online), the repository and branch for coding, and the model or account to run
 * with. Starting names a creation key that a retry keeps, so a retried start never makes a second Task; only a refused
 * start takes a new one. [labels] names the fixed environments and the default model in the member's language.
 */
class NewTaskForm(private val calls: WorkspaceCalls, private val labels: Labels) {
    data class Labels(val cloud: String, val code: String, val sandbox: String, val defaultModel: String, val modelsUnavailable: String)

    var onChange: () -> Unit = {}
    var text = ""
    var environmentId = ""
        private set
    var cloudModelId = ""
    var runId = ""
    var branch = ""
    var stations: List<JSONObject> = emptyList(); private set
    var environmentsLoaded = false; private set
    var modelsValue: JSONObject? = null; private set
    var modelsLoaded = false; private set
    private var stationProfiles: List<JSONObject> = emptyList()
    private var profilesStation: String? = null
    var profilesLoaded = false; private set
    var profilesError: String? = null; private set
    private var profileGeneration = 0
    var starting = false; private set
    var repoId = ""
        private set
    var repos: List<CodingRepo> = emptyList(); private set
    var branches: List<String> = emptyList(); private set
    var reposLoaded = false; private set
    var moreBranches = false; private set
    private var repoLoading = false
    private var branchPage = 1
    private var branchGeneration = 0
    private var key = UUID.randomUUID().toString()
    var created: String? = null; private set
    var error: String? = null; private set

    val inCoding: Boolean get() = environmentId == "sandbox"
    val inSandbox: Boolean get() = inCoding || environmentId == "plain_sandbox"
    val inCloud: Boolean get() = environmentId == "salix"

    private val sandboxesAvailable: Boolean
        get() = modelsValue?.optJSONObject("agents")?.optJSONObject("task_place")?.optBoolean("sandboxes") == true

    val environments: List<TaskEnvironment>
        get() = listOf(TaskEnvironment("salix", labels.cloud, true), TaskEnvironment("sandbox", labels.code, true)) +
            (if (sandboxesAvailable) listOf(TaskEnvironment("plain_sandbox", labels.sandbox, true)) else emptyList()) +
            stations.mapNotNull { station ->
                val id = station.text("id") ?: return@mapNotNull null
                TaskEnvironment(id, station.text("name") ?: id, station.optJSONObject("link")?.text("state") == "online")
            }

    val models: List<ModelOption>
        get() = modelsValue?.objects("models").orEmpty().mapNotNull { json ->
            val id = json.text("id") ?: return@mapNotNull null
            ModelOption(id, json.text("name") ?: return@mapNotNull null, strings(json.optJSONArray("serving")))
        }

    /** The served models, the Workspace's Task model first. */
    val cloudModels: List<ModelOption>
        get() {
            val preferred = modelsValue?.optJSONObject("agents")?.optJSONObject("task_model")?.optJSONObject("selection")?.text("model")
            val served = models.filter { it.serving.isNotEmpty() }
            return served.filter { it.id == preferred } + served.filter { it.id != preferred }
        }
    val cloudModel: ModelOption? get() = cloudModels.firstOrNull { it.id == cloudModelId } ?: cloudModels.firstOrNull()
    val repo: CodingRepo? get() = repos.firstOrNull { it.id == repoId }

    val runs: List<CodingRun>
        get() {
            if (!inSandbox) {
                if (profilesStation != environmentId) return emptyList()
                return stationProfiles.flatMap { profile ->
                    val id = profile.text("id") ?: return@flatMap emptyList()
                    val runtime = strings(profile.optJSONArray("runtimes")).firstOrNull() ?: return@flatMap emptyList()
                    val name = profile.text("name") ?: runtime
                    val listed = strings(profile.optJSONArray("models"))
                    if (listed.isEmpty()) listOf(CodingRun(runtime, id, profile.text("model"), name))
                    else listed.map { CodingRun(runtime, id, it, "$name · $it") }
                }
            }
            val profiles = modelsValue?.objects("profiles").orEmpty()
            return listOf("codex", "claude").flatMap { runtime ->
                val usable = profiles.filter { it.optBoolean("subscription") && it.optBoolean("usable") && it.text("source") == runtime }
                if (usable.isEmpty()) return@flatMap listOf(CodingRun(runtime, null, null, if (runtime == "codex") "Codex" else "Claude Code"))
                usable.flatMap { profile ->
                    val id = profile.text("id") ?: return@flatMap emptyList()
                    val account = profile.text("name") ?: profile.text("email") ?: runtime
                    listOf(CodingRun(runtime, id, null, "$account · ${labels.defaultModel}")) +
                        models.filter { id in it.serving }.map { CodingRun(runtime, id, it.id, "$account · ${it.name}") }
                }
            }
        }
    val run: CodingRun? get() = runs.firstOrNull { it.id == runId } ?: runs.firstOrNull()

    val canStart: Boolean
        get() {
            if (!calls.current || !environmentsLoaded || !modelsLoaded || starting || created != null || text.isBlank()) return false
            if (environments.none { it.id == environmentId && it.online }) return false
            return when {
                inCloud -> cloudModel != null
                inCoding -> repo != null && run != null
                else -> run != null
            }
        }

    /** The `models` topic's value for this Workspace. */
    fun modelsChanged(value: TopicValue<JSONObject?>) {
        when (value) {
            is TopicValue.Value -> {
                val json = value.value ?: return
                if (json.text("workspace") != calls.workspaceId) {
                    if (json.optBoolean("error") || json.has("workspace")) { modelsLoaded = true; error = labels.modelsUnavailable }
                    onChange(); return
                }
                modelsValue = json
                modelsLoaded = json.has("catalog") || json.optBoolean("error")
            }
            is TopicValue.Failed -> { modelsLoaded = true; error = WorkspaceCalls.message(value.error) }
        }
        onChange()
    }

    /** The `stations` topic's value; the first resolved environment holds through later presence updates. */
    fun stationsChanged(value: TopicValue<JSONObject?>) {
        when (value) {
            is TopicValue.Value -> {
                val json = value.value ?: return
                if (json.text("workspace") != calls.workspaceId) return
                stations = json.objects("stations")
                environmentsLoaded = !json.optBoolean("loading") || json.text("error") != null
            }
            is TopicValue.Failed -> environmentsLoaded = true
        }
        if (environmentsLoaded && environmentId.isEmpty()) {
            environmentId = stations.firstOrNull { it.optJSONObject("link")?.text("state") == "online" }?.text("id") ?: "salix"
        }
        onChange()
    }

    /** Picks where the Task runs; a computer's accounts are read again for it. */
    fun chooseEnvironment(id: String) {
        if (id == environmentId) return
        environmentId = id
        onChange()
    }

    suspend fun loadEnvironment() {
        val mine = ++profileGeneration
        stationProfiles = emptyList(); profilesStation = null; profilesLoaded = false; profilesError = null; runId = ""
        onChange()
        if (inCloud || inSandbox || environmentId.isEmpty()) return
        val station = environmentId
        try {
            val answer = calls.call("stations.profiles", JSONObject().put("station", station).put("workspace", calls.workspaceId))
            if (mine != profileGeneration || environmentId != station) return
            stationProfiles = (answer as? JSONArray).objects()
            profilesStation = station
            profilesLoaded = true
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (calls.current && mine == profileGeneration) { profilesError = WorkspaceCalls.message(failure); profilesLoaded = true }
        }
        onChange()
    }

    fun selectRepository(next: CodingRepo) {
        if (repos.none { it.id == next.id }) repos = repos + next
        if (repoId != next.id) {
            repoId = next.id
            branchGeneration++
            branch = ""; branches = emptyList(); moreBranches = false
        }
        onChange()
    }

    /** The connected account's first page of repositories, so a choice made before can show. */
    suspend fun loadRepos() {
        if (repoLoading || !calls.current || !inCoding) return
        repoLoading = true
        try {
            val answer = calls.call("coding.repos", JSONObject().put("workspaceId", calls.workspaceId).put("page", 1))
            val next = (answer as? JSONArray).objects().mapNotNull(CodingRepo::parse)
            repos = (repos + next).distinctBy { it.id }
            reposLoaded = true
            error = null
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (calls.current) error = WorkspaceCalls.message(failure)
        } finally {
            repoLoading = false
            onChange()
        }
    }

    suspend fun loadBranches(more: Boolean = false) {
        val mine = ++branchGeneration
        val repo = repo ?: run { branches = emptyList(); branch = ""; moreBranches = false; onChange(); return }
        if (!more) { branches = emptyList(); branch = ""; moreBranches = false }
        val page = if (more) branchPage + 1 else 1
        try {
            val answer = calls.call("coding.branches", JSONObject().put("workspaceId", calls.workspaceId).put("owner", repo.owner)
                .put("name", repo.name).put("page", page))
            if (mine != branchGeneration) return
            val next = strings(answer as? JSONArray)
            branches = ((if (more) branches else emptyList()) + next).distinct()
            branchPage = page
            moreBranches = page < 100 && next.size == 100
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (calls.current && mine == branchGeneration) error = WorkspaceCalls.message(failure)
        }
        onChange()
    }

    /** The new Task's conversation; the same one again after it was made. */
    suspend fun start(): String? {
        if (!calls.current) return null
        created?.let { return it }
        if (!canStart) return null
        val params = JSONObject().put("key", key).put("text", text.trim())
        val method: String
        val run = run
        val cloud = cloudModel
        when {
            inCloud && cloud != null -> {
                method = "chat.startTask"
                params.put("workspaceId", calls.workspaceId).put("model", JSONObject().put("id", cloud.id).put("name", cloud.name))
            }
            inSandbox && run != null -> {
                method = "coding.start"
                params.put("workspaceId", calls.workspaceId)
                params.put("model", JSONObject().put("provider", run.runtime).apply { run.model?.let { put("model", it) } })
                val repo = repo
                if (inCoding && repo != null) {
                    params.put("repo", JSONObject().put("owner", repo.owner).put("name", repo.name).apply {
                        if (branch.isNotEmpty()) put("baseRef", branch)
                    })
                }
                run.profile?.let { params.put("accountId", it) }
            }
            run?.profile != null -> {
                method = "stations.newTask"
                params.put("workspace", calls.workspaceId).put("station", environmentId).put("profile", run.profile)
                    .put("runtime", run.runtime)
                run.model?.let { params.put("model", it) }
            }
            else -> return null
        }
        starting = true
        error = null
        onChange()
        try {
            val answer = calls.call(method, params) as? JSONObject
            created = answer?.text(if (method == "coding.start") "taskId" else "conversationId")
            return created
        } catch (cancel: CancellationException) {
            return null
        } catch (failure: Exception) {
            if (calls.current) {
                // A refused start made nothing: the next one is a new request.
                if ((failure as? CoreError)?.code == "refused") key = UUID.randomUUID().toString()
                error = WorkspaceCalls.message(failure)
            }
            return null
        } finally {
            starting = false
            onChange()
        }
    }

    /** The key the next start sends; tests read it. */
    internal val creationKey: String get() = key

    private companion object {
        fun strings(array: JSONArray?): List<String> =
            if (array == null) emptyList() else (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotEmpty) }
    }
}
