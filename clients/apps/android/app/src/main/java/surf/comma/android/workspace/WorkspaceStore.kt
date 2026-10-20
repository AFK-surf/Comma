package surf.comma.android.workspace

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConversationScope
import surf.comma.android.auth.Workspace
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.inbox.InboxMarks
import surf.comma.android.routines.RecommendationFeed
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskArchiveResult
import surf.comma.android.tasks.data.TaskGraph
import java.util.Locale
import java.util.TimeZone

/**
 * What the tabs share beyond the conversations: the pinned Tasks, the member's Task actions, the Routines
 * briefing, the skills, the Inbox marks, the open Task and the app's toast. The Task list itself is
 * [ServerTaskRepository]'s, which every surface reads. The client core keeps each of them as a topic, which this
 * class shows while the conversation scope lasts; everything resets when the scope changes (sign-out, another
 * account or Workspace).
 */
class WorkspaceStore internal constructor(
    private val context: Context,
    val auth: AuthRepository,
    val tasks: ServerTaskRepository,
    private val api: CommaApi,
) {
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val mutablePinned = MutableStateFlow<Set<String>>(emptySet())
    val pinned: StateFlow<Set<String>> = mutablePinned.asStateFlow()

    val routines = RoutinesModel()
    private val mutableSkills = MutableStateFlow<List<Skill>?>(null)
    /** The workspace's skills for the composer's / menu; null until read. */
    val skills: StateFlow<List<Skill>?> = mutableSkills.asStateFlow()
    private var skillsShown: Job? = null
    private val mutableModels = MutableStateFlow<List<MentionModel>?>(null)
    /** The models the router chat's @ menu offers to start a Task with; null until read. */
    val models: StateFlow<List<MentionModel>?> = mutableModels.asStateFlow()
    private var modelsShown: Job? = null

    private val mutableMarks = MutableStateFlow(InboxMarks())
    val inboxMarks: StateFlow<InboxMarks> = mutableMarks.asStateFlow()

    private val mutableOpenTask = MutableStateFlow<String?>(null)
    /** The Task shown in the dock. Opening another replaces it; the router chat is untouched. */
    val openTask: StateFlow<String?> = mutableOpenTask.asStateFlow()
    private val mutableTaskReveal = MutableStateFlow(0)
    /** Advances on every request to show a Task, including the one already open, so its sheet rises. */
    val taskReveal: StateFlow<Int> = mutableTaskReveal.asStateFlow()

    private val mutableToast = MutableStateFlow<Toast?>(null)
    val toast: StateFlow<Toast?> = mutableToast.asStateFlow()

    private var scope: ConversationScope? = null
    /** Runs what belongs to [scope]: its topics and the calls made for it. Cancelled when the scope changes. */
    private var scopeJobs: CoroutineScope? = null

    /** A notice over the app: what failed, or what just happened with a way to take it back. */
    data class Toast(val id: Long, val message: String, val error: Boolean, val undo: (suspend () -> Unit)? = null)

    fun start() {
        io.launch { auth.conversationScope.collect(::bind) }
    }

    private fun bind(next: ConversationScope?) {
        if (next === scope) return
        scope = next
        scopeJobs?.cancel()
        scopeJobs = null
        skillsShown = null
        modelsShown = null
        mutablePinned.value = emptySet()
        mutableSkills.value = null
        mutableModels.value = null
        mutableOpenTask.value = null
        mutableMarks.value = InboxMarks()
        routines.reset()
        if (next == null) return
        val jobs = CoroutineScope(io.coroutineContext + SupervisorJob(io.coroutineContext[Job]))
        scopeJobs = jobs
        jobs.launch {
            api.subscribe(JSONObject().put("topic", "taskPins").put("group", next.groupId)) { value ->
                // A failed read keeps the ids last read.
                (value as? JSONObject)?.takeIf { it.optString("status") != "loading" }?.optJSONArray("ids")?.let(::wireStrings)?.toSet()
            }.collect { value -> (value as? TopicValue.Value)?.value?.let { if (isCurrent(next)) mutablePinned.value = it } }
        }
        for (kind in MARK_KINDS) jobs.launch {
            api.subscribe(JSONObject().put("topic", "marks").put("kind", kind.name)) { value ->
                val marks = (value as? JSONObject)?.optJSONObject("marks") ?: JSONObject()
                marks.keys().asSequence().associateWith { marks.optLong(it) }
            }.collect { value ->
                val marks = (value as? TopicValue.Value)?.value ?: return@collect
                if (isCurrent(next)) mutableMarks.update { kind.write(it, marks) }
            }
        }
    }

    // MARK: Session facts

    val workspace: Workspace? get() = (auth.state.value as? AuthState.Connected)?.selection?.workspace
    val accountId: String? get() = (auth.state.value as? AuthState.Connected)?.account?.id

    fun task(id: String): TaskSummary? = tasks.state.value.summaries[id]

    fun isCurrent(value: ConversationScope) = scope === value && auth.isCurrentGeneration(value.generation)

    // MARK: Open Task

    fun openTask(id: String) {
        mutableTaskReveal.value++
        mutableOpenTask.value = id
        task(id)?.let(::markSeen)
    }

    fun closeTask() {
        mutableOpenTask.value = null
    }

    // MARK: Actions

    /** The desktop's Done: accepting the result of a Task in review. */
    fun acceptReview(task: TaskSummary) = act { scope -> api.accept(scope, task.id, task.reviewVersion) }

    /** Ends the Task by hand with `completed` or `cancelled`. Only the open Task's chat can say it; [chat] is that. */
    fun setStatus(task: TaskSummary, status: String, chat: surf.comma.android.conversation.ChatView) = act {
        chat.setTaskStatus(status, task.updatedAt)
    }

    fun rename(task: TaskSummary, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty() || trimmed.length > 200) return
        act { scope -> api.rename(scope, task.id, trimmed) }
    }

    fun setLabels(task: TaskSummary, labelIds: List<String>, done: () -> Unit = {}) = act(done) { scope ->
        api.setLabels(scope, task.id, labelIds)
    }

    /** Archives or restores; [done] runs once it succeeded. The core takes the Task off every list at once. */
    fun setArchived(task: TaskSummary, archived: Boolean, done: (TaskSummary) -> Unit = {}) {
        val scope = scope ?: return
        io.launch {
            try {
                val accepted = if (archived) when (tasks.archive(task.id)) {
                    TaskArchiveResult.ARCHIVED -> true
                    TaskArchiveResult.CONFLICT -> throw CoreError("conflict", "Archive conflict", 409)
                    TaskArchiveResult.NOT_ALLOWED -> throw CoreError("forbidden", "Archive refused", 403)
                    else -> throw CoreError("unavailable", "Archive failed")
                } else api.setArchived(scope, task.id, false, task.updatedAt)
                if (!isCurrent(scope)) return@launch
                // A refused restore (another archive change under way) would otherwise leave the tap unanswered.
                if (accepted) done(task) else showToast(context.getString(R.string.task_restore_busy), error = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: CoreError) {
                if (isCurrent(scope)) fail(error)
            }
        }
    }

    fun setPinned(taskId: String, pinned: Boolean) {
        val scope = scope ?: return
        mutablePinned.update { if (pinned) it + taskId else it - taskId }
        io.launch {
            try {
                api.setPinned(scope, taskId, pinned)
            } catch (error: CancellationException) {
                throw error
            } catch (error: CoreError) {
                if (!isCurrent(scope)) return@launch
                mutablePinned.update { if (pinned) it - taskId else it + taskId }
                fail(error)
            }
        }
    }

    fun refresh() = io.launch { tasks.refresh() }

    suspend fun search(query: String): List<TaskSummary> {
        val scope = scope ?: return emptyList()
        val results = api.search(scope, query, tasks.state.value.summaries)
        // As with [call]: results read for an account or Workspace no longer shown are not shown.
        if (!isCurrent(scope)) throw CancellationException("Scope changed")
        return results
    }

    /** Runs [scope]'s calls for the details card, labels page and share sheet. */
    suspend fun <T> call(block: suspend CommaApi.(ConversationScope) -> T): T {
        val scope = scope ?: throw CoreError("signed_out", "Signed out")
        val result = api.block(scope)
        if (!isCurrent(scope)) throw CancellationException("Scope changed")
        return result
    }

    private fun act(done: () -> Unit = {}, block: suspend (ConversationScope) -> Unit) {
        val scope = scope ?: return
        io.launch {
            try {
                block(scope)
                if (isCurrent(scope)) done()
            } catch (error: CancellationException) {
                throw error
            } catch (error: CoreError) {
                // The core reads the Task again after a refused change (a stale copy).
                if (isCurrent(scope)) fail(error)
            }
        }
    }

    // MARK: Skills

    /** Shows the workspace's skills to the core for as long as the scope lasts. */
    fun loadSkills() {
        val scope = scope ?: return
        val workspace = workspace ?: return
        if (skillsShown != null) return
        skillsShown = scopeJobs?.launch {
            api.subscribe(JSONObject().put("topic", "skills").put("workspace", workspace.id)) { value ->
                val json = value as? JSONObject
                when (json?.optString("status")) {
                    "ready" -> json.optJSONArray("skills")?.let { array -> (0 until array.length()).mapNotNull { array.optJSONObject(it)?.let(Skill::parse) } }.orEmpty()
                    // A failed read ends the menu's Searching row.
                    "error" -> emptyList()
                    else -> null
                }
            }.collect { value -> (value as? TopicValue.Value)?.value?.let { if (isCurrent(scope)) mutableSkills.value = it } }
        }
    }

    // MARK: Models

    /** Shows the Workspace's models to the core for as long as the scope lasts; the router chat asks on its first @. */
    fun loadModels() {
        val scope = scope ?: return
        val workspace = workspace ?: return
        if (modelsShown != null) return
        modelsShown = scopeJobs?.launch {
            api.subscribe(JSONObject().put("topic", "models").put("prefer", workspace.id), MentionModel::fromTopic)
                .collect { value ->
                    // A failed read ends the menu's Searching row.
                    val models = when (value) {
                        is TopicValue.Value -> value.value
                        is TopicValue.Failed -> emptyList()
                    }
                    if (models != null && isCurrent(scope)) mutableModels.value = models
                }
        }
    }

    // MARK: Inbox marks

    /** Applies [change] to the marks at once and gives the core the marks it made or took back. */
    fun changeMarks(change: (InboxMarks) -> InboxMarks) {
        val before = mutableMarks.value
        val next = change(before)
        val scope = scope ?: return
        val jobs = scopeJobs ?: return
        if (next == before) return
        mutableMarks.value = next
        // Under the scope's jobs, so a sign-out or switch mid-way stops it before it marks the next session's Inbox.
        jobs.launch {
            for (kind in MARK_KINDS) {
                if (!isCurrent(scope)) return@launch
                val old = kind.read(before)
                val new = kind.read(next)
                val added = new.filter { (id, revision) -> (old[id] ?: Long.MIN_VALUE) < revision }
                val removed = old.keys - new.keys
                try {
                    if (added.isNotEmpty()) api.call("marks.mark", JSONObject().put("kind", kind.name)
                        .put("entries", JSONArray(added.map { (id, revision) -> JSONArray().put(id).put(revision) })))
                    if (removed.isNotEmpty() && isCurrent(scope))
                        api.call("marks.unmark", JSONObject().put("kind", kind.name).put("ids", JSONArray(removed.toList())))
                } catch (error: CancellationException) {
                    throw error
                } catch (_: CoreError) {
                    // The topic shows the marks the core kept.
                }
            }
        }
    }

    fun markSeen(task: TaskSummary) = changeMarks { it.markSeen(task) }

    // MARK: Toast

    private var toastIds = 0L

    fun showToast(message: String, error: Boolean = false, undo: (suspend () -> Unit)? = null) {
        mutableToast.value = Toast(++toastIds, message, error, undo)
    }

    fun dismissToast(id: Long) {
        if (mutableToast.value?.id == id) mutableToast.value = null
    }

    fun fail(error: Throwable) {
        val status = (error as? CoreError)?.status
        val message = when {
            error !is CoreError || error.code == "network_unavailable" -> context.getString(R.string.app_failure_network)
            status == 409 -> context.getString(R.string.app_failure_conflict)
            else -> context.getString(R.string.app_failure_generic)
        }
        showToast(message, error = true)
    }

    // MARK: Routines

    /**
     * The workspace's Routines briefing, which Home shows as platform cards: the core's `recommendations` topic,
     * shown once a surface asks. The core reads it again while a run is under way, while sources are discovered and
     * when the app comes back; [reloadIfStale] tells it Home is shown again.
     */
    inner class RoutinesModel {
        private val mutableFeed = MutableStateFlow<RecommendationFeed?>(null)
        val feed: StateFlow<RecommendationFeed?> = mutableFeed.asStateFlow()
        private val mutableFailure = MutableStateFlow<RoutinesFailure?>(null)
        val failure: StateFlow<RoutinesFailure?> = mutableFailure.asStateFlow()
        private val mutableRequesting = MutableStateFlow(false)
        val requesting: StateFlow<Boolean> = mutableRequesting.asStateFlow()
        private var shown: Job? = null
        private var workspaceId: String? = null
        private var refreshing = false

        val isRefreshing: Boolean
            get() = mutableRequesting.value || refreshing ||
                (mutableFeed.value?.isRefreshing == true && mutableFailure.value != RoutinesFailure.UNAVAILABLE)

        fun reset() {
            shown?.cancel()
            shown = null
            mutableFeed.value = null; mutableFailure.value = null; mutableRequesting.value = false
            workspaceId = null; refreshing = false
        }

        /** Shows the briefing to the core for as long as the scope lasts. */
        private fun show(): Boolean {
            val scope = scope ?: return false
            val workspace = workspace ?: return false
            if (workspaceId != workspace.id) reset()
            if (shown != null) return true
            workspaceId = workspace.id
            shown = io.launch {
                api.subscribe(JSONObject().put("topic", "recommendations").put("workspace", workspace.id)
                    .put("timezone", TimeZone.getDefault().id).put("locale", Locale.getDefault().toLanguageTag())) { it as? JSONObject }
                    .collect { value ->
                        val json = (value as? TopicValue.Value)?.value ?: return@collect
                        if (!isCurrent(scope)) return@collect
                        refreshing = json.optBoolean("refreshing")
                        json.optJSONObject("envelope")?.let { envelope ->
                            runCatching { RecommendationFeed.parse(envelope) }.onSuccess { mutableFeed.value = it }
                        }
                        mutableFailure.value = when (json.optString("failure")) {
                            "unavailable" -> RoutinesFailure.UNAVAILABLE
                            "rate_limited" -> RoutinesFailure.RATE_LIMITED
                            else -> null
                        }
                    }
            }
            return true
        }

        /** A surface that comes back has the briefing read again. */
        fun reloadIfStale() {
            val shownBefore = shown != null
            if (!show() || !shownBefore) return
            val workspace = workspaceId ?: return
            io.launch { runCatching { api.call("recommendations.visit", JSONObject().put("workspace", workspace)) } }
        }

        /** Reads the briefing again after it could not be read. */
        fun retry() {
            reset()
            show()
        }

        /** Pull to refresh: shows the briefing, or has it read again. */
        suspend fun load(): Boolean {
            val shownBefore = shown != null
            if (!show()) return false
            val workspace = workspaceId ?: return false
            if (shownBefore) runCatching { api.call("recommendations.visit", JSONObject().put("workspace", workspace)) }
                .onFailure { if (it is CancellationException) throw it }
            return true
        }

        /** An explicit request for a new briefing. The hourly budget refusal is the one failure reported. */
        fun refresh() {
            if (isRefreshing || !show()) return
            val scope = scope ?: return
            val jobs = scopeJobs ?: return
            val workspace = workspaceId ?: return
            mutableRequesting.value = true
            mutableFailure.value = null
            // Under the scope's jobs, and only for the scope that asked: a late answer for another Workspace says nothing here.
            jobs.launch {
                try {
                    val answer = api.call("recommendations.refresh", JSONObject().put("workspace", workspace)) as? JSONObject
                    if (answer?.optBoolean("rateLimited") == true && isCurrent(scope)) mutableFailure.value = RoutinesFailure.RATE_LIMITED
                } catch (error: CancellationException) {
                    throw error
                } catch (_: CoreError) {
                    if (isCurrent(scope) && mutableFeed.value?.canRefresh != false) mutableFailure.value = RoutinesFailure.UNAVAILABLE
                } finally {
                    if (isCurrent(scope)) mutableRequesting.value = false
                }
            }
        }
    }

    enum class RoutinesFailure { UNAVAILABLE, RATE_LIMITED }

    private companion object {
        /** A core mark kind the Inbox keeps, and where it lives in [InboxMarks]. */
        class MarkKind(
            val name: String,
            val read: (InboxMarks) -> Map<String, Long>,
            val write: (InboxMarks, Map<String, Long>) -> InboxMarks,
        )

        val MARK_KINDS = listOf(
            MarkKind("taskReviewSeen", InboxMarks::seen) { marks, value -> marks.copy(seen = value) },
            MarkKind("inboxUnread", InboxMarks::unread) { marks, value -> marks.copy(unread = value) },
            MarkKind("inboxDeleted", InboxMarks::cleared) { marks, value -> marks.copy(cleared = value) },
        )
    }
}

/** The process's [WorkspaceStore], created with the session. */
object WorkspaceGraph {
    @Volatile private var store: WorkspaceStore? = null

    fun get(context: Context): WorkspaceStore = store ?: synchronized(this) {
        store ?: run {
            val app = context.applicationContext
            val auth = AuthGraph.get(app)
            WorkspaceStore(app, auth, TaskGraph.get(app, auth), CommaApi(AuthGraph.core(app))).also { it.start(); store = it }
        }
    }
}
