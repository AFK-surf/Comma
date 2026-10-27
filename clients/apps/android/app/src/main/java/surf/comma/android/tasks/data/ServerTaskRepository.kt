package surf.comma.android.tasks.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationSessions
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.ChatView
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.TaskHost
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskRepository
import surf.comma.android.tasks.TaskSection
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.ui.Background
import surf.comma.android.workspace.wireMillis
import surf.comma.android.workspace.wireStrings
import java.io.Closeable
import java.util.UUID

/**
 * The Group's tasks as the app's screens see them. The client core keeps them: its `tasks` topic is the list (kept on
 * the device, read again while shown and whenever the Group's event stream says it changed), `taskLabels` the label
 * catalog, `taskOrder` the board's arrangement, `taskSummaries` the facts of tasks a chat refers to outside the
 * list, and `chatView` the opened task's messages. This class shows those topics while the app is in front, puts
 * them together as one [TaskDataState], and forwards what the person does to the core's calls.
 */
class ServerTaskRepository internal constructor(
    private val sessions: ConversationSessions,
    private val core: CoreApi?,
    private val io: CoroutineDispatcher = Background.files,
) : TaskRepository, Closeable {
    private val root = CoroutineScope(SupervisorJob() + io)
    private val mutableState = MutableStateFlow(TaskDataState())
    val state: StateFlow<TaskDataState> = mutableState.asStateFlow()
    /** The opened task's conversation, as the core shows it to this app. */
    private val detailView = ChatView(sessions, core, main = false, io = io)
    private val mutableDetail = MutableStateFlow(TaskDetailState())
    val detail: StateFlow<TaskDetailState> = mutableDetail.asStateFlow()

    /** The list as the core's `tasks` topic says it, read off the core client's thread. */
    private class Listed(
        val tasks: List<TaskSummary>,
        val hasMore: Boolean,
        val workspaces: List<surf.comma.android.auth.Workspace>,
        val source: String,
        val syncedAt: Long,
        val errorCode: String?,
    )

    private val lock = Any()
    private var scope: ConversationScope? = null
    private var foreground = false
    private var started = false
    private var shown: Job? = null
    private var summariesShown: Job? = null
    private var listed: Listed? = null
    private var labels = emptyList<TaskLabel>()
    private var sections = emptyList<TaskSection>()
    private var referred = emptyMap<String, TaskSummary>()
    private var references = emptyMap<String, List<String>>()
    private val watchers = HashMap<String, Int>()
    private var opened: String? = null
    private var reads = 0
    private var readsEpoch = UUID.randomUUID().toString()
    private var lastSyncedAt = 0L

    @Synchronized fun start() {
        if (started) return
        started = true
        // The scope there is now applies before this returns: what is asked right after finds it.
        switchTo(sessions.scopes.value)
        root.launch { sessions.scopes.collect(::switchTo) }
        detailView.start()
        root.launch {
            detailView.state.collect { read ->
                val taskId = read.conversationId
                // Only the newest range is the task's page; what lies before a gap loads as it is reached.
                val tail = read.timeline.subList(read.timeline.indexOfLast { it is TimelineEntry.Gap } + 1, read.timeline.size)
                mutableDetail.value = if (taskId == null) TaskDetailState() else TaskDetailState(taskId,
                    tail.filterIsInstance<TimelineEntry.Message>(), hasOlder = read.hasOlder,
                    loading = read.loadingOlder || !read.cacheLoaded, problem = read.problem)
            }
        }
    }

    private fun switchTo(next: ConversationScope?) = synchronized(lock) {
        val wanted = next?.takeIf(sessions::isCurrent)
        if (scope === wanted) return@synchronized
        scope = wanted
        listed = null
        labels = emptyList()
        sections = emptyList()
        referred = emptyMap()
        references = emptyMap()
        watchers.clear()
        opened = null
        reads = 0
        lastSyncedAt = 0
        readsEpoch = UUID.randomUUID().toString()
        mutableState.value = TaskDataState(groupId = wanted?.groupId, listReadsEpoch = readsEpoch)
        show()
    }

    /** May be driven directly in tests; TaskGraph connects it to the process lifecycle. */
    fun setForeground(visible: Boolean) = synchronized(lock) {
        if (foreground == visible) return@synchronized
        foreground = visible
        detailView.setForeground(visible)
        show()
        if (!visible) mutableState.value = mutableState.value.copy(connection = Connection.BACKGROUND, loading = false)
    }

    /** Shows the Group's topics to the core while the app is in front. Call under [lock]. */
    private fun show() {
        shown?.cancel()
        shown = null
        summariesShown?.cancel()
        summariesShown = null
        val current = scope
        val running = core
        if (current == null || running == null || !foreground) return
        val group = current.groupId
        shown = root.launch {
            launch {
                // With the Tasks the workspace's stations host among them.
                running.subscribe(JSONObject().put("topic", "tasks").put("workspace", current.workspaceId).put("hosted", "1")) {
                    readList(it, group)
                }
                    .collect { value -> if (value is TopicValue.Value) update(current) { listed = value.value } }
            }
            launch {
                running.subscribe(JSONObject().put("topic", "taskLabels").put("group", group), ::readLabels)
                    .collect { value -> if (value is TopicValue.Value) update(current) { labels = value.value } }
            }
            launch {
                running.subscribe(JSONObject().put("topic", "taskOrder").put("group", group), ::readSections)
                    .collect { value -> if (value is TopicValue.Value) update(current) { sections = value.value } }
            }
        }
        showSummaries()
    }

    /** Shows the facts of the tasks referred to outside the list. Call under [lock]. */
    private fun showSummaries() {
        summariesShown?.cancel()
        summariesShown = null
        val current = scope
        val running = core
        if (current == null || running == null || !foreground) return
        val ids = demanded()
        if (ids.isEmpty()) return
        summariesShown = root.launch {
            // The topic names its tasks in a parameter: a long list goes as several.
            for (batch in ids.chunked(SUMMARY_BATCH)) launch {
                running.subscribe(JSONObject().put("topic", "taskSummaries").put("group", current.groupId)
                    .put("ids", batch.joinToString(","))) { readSummaries(it, current.groupId) }
                    .collect { value ->
                        if (value is TopicValue.Value) update(current) {
                            referred = (referred - batch.toSet()) + value.value.associateBy { it.id }
                        }
                    }
            }
        }
    }

    private fun demanded(): List<String> = (references.values.flatten() + watchers.keys + listOfNotNull(opened)).distinct()

    private inline fun update(current: ConversationScope, change: () -> Unit) = synchronized(lock) {
        if (scope !== current || !sessions.isCurrent(current)) return@synchronized
        change()
        publish()
    }

    /** Call under [lock]. */
    private fun publish() {
        val current = scope ?: return
        val list = listed
        if (list != null && list.source == "live-sync" && list.syncedAt != lastSyncedAt) {
            lastSyncedAt = list.syncedAt
            reads++
        }
        val known = LinkedHashMap<String, TaskSummary>()
        referred.values.forEach { known[it.id] = it }
        list?.tasks?.forEach { known[it.id] = it }
        val failed = list?.errorCode
        mutableState.value = TaskDataState(
            groupId = current.groupId,
            snapshot = TaskSnapshot(list?.tasks.orEmpty(), labels),
            summaries = known,
            conversationTaskIds = references,
            sections = sections,
            hasMore = list?.hasMore == true,
            workspaces = list?.workspaces.orEmpty(),
            loading = list == null,
            cacheLoaded = list != null,
            listLoaded = list != null && (list.source == "live-sync" || list.source == "cache"),
            listReads = reads,
            listReadsEpoch = readsEpoch,
            connection = when {
                !foreground -> Connection.BACKGROUND
                list == null -> Connection.CONNECTING
                list.source == "live-sync" -> Connection.LIVE
                failed == "session_product_lease_unavailable" -> Connection.PAUSED
                else -> Connection.RECONNECTING
            },
            problem = when (failed) {
                null -> null
                "network_unavailable" -> ConversationProblem.NETWORK
                "session_product_lease_unavailable" -> ConversationProblem.UNAUTHORIZED
                else -> ConversationProblem.SERVER
            },
        )
    }

    private fun readList(value: Any?, group: String): Listed? {
        val json = value as? JSONObject ?: return null
        val items = json.optJSONArray("items") ?: JSONArray()
        val tasks = ArrayList<TaskSummary>(items.length())
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            if (item.optString("groupId") != group || item.optString("kind") != "agent_task") continue
            val id = item.optString("conversationId").takeIf { it.isNotEmpty() } ?: continue
            tasks += TaskSummary(id, item.optString("title"), TaskStatusBucket.of(item.optString("statusBucket")),
                failed = item.optBoolean("statusFailed"),
                labelIds = wireStrings(item.optJSONArray("labels")),
                // The version an archive names, as the server gave it.
                updatedAt = item.optLong("archiveVersion"),
                // Missing availability must never activate the UI's legacy fallback.
                archiveAllowed = item.optJSONObject("archiveAvailability")?.opt("allowed") == true,
                status = item.optString("status"),
                reviewVersion = item.optLong("reviewVersion"),
                origin = item.optString("origin").takeIf(String::isNotEmpty),
                clientPlatform = item.optString("clientPlatform").takeIf(String::isNotEmpty),
                scheduled = item.optBoolean("scheduled"),
                changedAt = wireMillis(item.optLong("updatedAt")),
                host = item.optJSONObject("host")?.let { readHost(it, item.optString("workspaceId")) },
                unsupported = wireStrings(item.optJSONArray("unsupported")).toSet())
        }
        val workspaces = json.optJSONArray("workspaces")?.let { array ->
            (0 until array.length()).mapNotNull { index ->
                val row = array.optJSONObject(index) ?: return@mapNotNull null
                val id = row.optString("id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
                surf.comma.android.auth.Workspace(id, row.optString("group_id"), row.optString("name"))
            }
        }.orEmpty()
        return Listed(tasks, json.optBoolean("hasMore"), workspaces, json.optString("source"), json.optLong("lastSyncedAt"),
            json.optString("errorCode").takeIf { it.isNotEmpty() })
    }

    /** A station-hosted Task's chat and machine; null when it names no chat this app can open. */
    private fun readHost(json: JSONObject, workspace: String): TaskHost? {
        val station = json.optString("station").takeIf(String::isNotEmpty) ?: return null
        val thread = json.optString("thread").toLongOrNull() ?: return null
        val machine = json.optJSONObject("machine")
        return TaskHost(workspace, station, thread, machine?.optString("name")?.takeIf(String::isNotEmpty),
            machine?.optBoolean("online"))
    }

    private fun readLabels(value: Any?): List<TaskLabel> {
        val catalog = (value as? JSONObject)?.optJSONObject("catalog")?.optJSONArray("labels") ?: return emptyList()
        return (0 until catalog.length()).mapNotNull { index ->
            val row = catalog.optJSONObject(index) ?: return@mapNotNull null
            val id = row.optString("id").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val name = row.optString("name").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            // Keep the preset or HEX for DesignLabelColors; never infer a name/color from an ID.
            TaskLabel(id, name, row.optString("color").takeIf { it.isNotBlank() } ?: "gray")
        }.distinctBy { it.id }
    }

    private fun readSections(value: Any?): List<TaskSection> {
        // The statuses in the order every client shows them, each bucket's tasks in board order.
        val rows = (value as? JSONObject)?.optJSONArray("sections") ?: return emptyList()
        return (0 until rows.length()).mapNotNull { index ->
            val row = rows.optJSONObject(index) ?: return@mapNotNull null
            TaskSection(TaskStatusBucket.of(row.optString("bucket")), wireStrings(row.optJSONArray("ids")).distinct())
        }
    }

    private fun readSummaries(value: Any?, group: String): List<TaskSummary> {
        val rows = (value as? JSONObject)?.optJSONArray("summaries") ?: return emptyList()
        return (0 until rows.length()).mapNotNull { index ->
            rows.optJSONObject(index)?.takeIf { it.optString("group_id") == group }?.let(::taskSummaryOf)
        }
    }

    override fun observeTasks(): Flow<TaskSnapshot> = state.map { it.snapshot }.distinctUntilChanged()
    override fun observeConversationTasks(conversationId: String): Flow<List<TaskSummary>> = state.map { value ->
        value.conversationTaskIds[conversationId].orEmpty().mapNotNull(value.summaries::get)
    }.distinctUntilChanged()

    override fun observeTask(taskId: String): Flow<TaskSummary?> = flow {
        val owner = synchronized(lock) {
            watchers[taskId] = (watchers[taskId] ?: 0) + 1
            if (watchers[taskId] == 1) showSummaries()
            scope
        }
        try {
            emitAll(state.map { it.summaries[taskId] }.distinctUntilChanged())
        } finally {
            // Do not let an old collector release a new account's interest in the same ID.
            synchronized(lock) {
                if (scope === owner) {
                    val count = watchers[taskId] ?: 0
                    if (count <= 1) { watchers.remove(taskId); showSummaries() } else watchers[taskId] = count - 1
                }
            }
        }
    }

    private fun target(): JSONObject? = synchronized(lock) { scope?.takeIf(sessions::isCurrent) }
        ?.let { JSONObject().put("workspace", it.workspaceId) }

    private suspend fun call(name: String, params: JSONObject): Any? = try {
        core?.call(name, params)
    } catch (e: CancellationException) {
        throw e
    } catch (_: CoreError) {
        null
    }

    override suspend fun refresh() {
        call("tasks.refresh", target() ?: return)
    }

    suspend fun loadMore() {
        call("tasks.more", target() ?: return)
    }

    /** Explicit retry after a failure paused the list. */
    fun reconnect() {
        root.launch { refresh() }
    }

    /** A one-shot read of the facts of [taskIds]; what is known within a few seconds. */
    suspend fun resolveSummaries(taskIds: Collection<String>): Map<String, TaskSummary> {
        val ids = validIds(taskIds)
        val current = synchronized(lock) { scope?.takeIf(sessions::isCurrent) } ?: return emptyMap()
        val running = core ?: return emptyMap()
        if (ids.isEmpty()) return emptyMap()
        val found = LinkedHashMap<String, TaskSummary>()
        for (batch in ids.chunked(SUMMARY_BATCH)) {
            var latest = emptyList<TaskSummary>()
            withTimeoutOrNull(RESOLVE_MILLIS) {
                running.subscribe(JSONObject().put("topic", "taskSummaries").put("group", current.groupId)
                    .put("ids", batch.joinToString(","))) { readSummaries(it, current.groupId) }
                    .first { value ->
                        if (value is TopicValue.Value) latest = value.value
                        value is TopicValue.Failed || latest.size == batch.size
                    }
            }
            latest.forEach { found[it.id] = it }
        }
        return found
    }

    /**
     * Replace the references from the currently loaded chat history; empty IDs release its demand. Returns true
     * once the summaries are known for the current session; false when the session has changed or they could not
     * be read in time, so the caller can ask again.
     */
    suspend fun setConversationTaskIds(conversationId: String, taskIds: Collection<String>): Boolean {
        val ids = validIds(taskIds)
        val current = synchronized(lock) {
            val current = scope?.takeIf(sessions::isCurrent) ?: return false
            references = references + (conversationId to ids)
            showSummaries()
            publish()
            current
        }
        if (ids.isEmpty()) return true
        return withTimeoutOrNull(RESOLVE_MILLIS) {
            state.first { value -> ids.all(value.summaries::containsKey) }
            true
        } == true && synchronized(lock) { scope === current }
    }

    /** The tasks the conversation's messages announce, as the core names them, populate the panel. */
    suspend fun setConversationMessages(conversationId: String, messages: List<ChatMessage>): Boolean =
        setConversationTaskIds(conversationId, messages.sortedBy { it.seq }.flatMap { it.createdTaskIds })

    suspend fun archive(taskId: String): TaskArchiveResult {
        val current = synchronized(lock) { scope?.takeIf(sessions::isCurrent) } ?: return TaskArchiveResult.UNAVAILABLE
        // Always confirm availability and use the canonical version unchanged.
        val task = resolveSummaries(listOf(taskId))[taskId] ?: state.value.summaries[taskId]
            ?: return TaskArchiveResult.UNAVAILABLE
        if (task.archiveAllowed != true || task.updatedAt <= 0) return TaskArchiveResult.NOT_ALLOWED
        return try {
            val done = core?.call("tasks.archive", JSONObject().put("group", current.groupId).put("conversation", taskId)
                .put("action", "archive").put("version", task.updatedAt))
            if (done == false) TaskArchiveResult.UNAVAILABLE else TaskArchiveResult.ARCHIVED
        } catch (e: CancellationException) {
            throw e
        } catch (e: CoreError) {
            when (e.status) {
                409 -> TaskArchiveResult.CONFLICT
                403 -> TaskArchiveResult.NOT_ALLOWED
                else -> TaskArchiveResult.UNAVAILABLE
            }
        }
    }

    /** Shows the task's messages: the core's view of its conversation, the newest range of it. */
    suspend fun openDetail(taskId: String) {
        synchronized(lock) {
            scope?.takeIf(sessions::isCurrent) ?: return
            opened = taskId
            showSummaries()
        }
        detailView.open(taskId)
    }

    suspend fun closeDetail() {
        synchronized(lock) {
            opened = null
            showSummaries()
        }
        detailView.open(null)
    }

    suspend fun loadOlderDetail() = detailView.loadOlder()

    /** Lets every topic go. */
    override fun close() {
        detailView.close()
        root.cancel()
    }

    private fun validIds(ids: Collection<String>) = ids.filter { it.isNotBlank() && ',' !in it }.distinct()

    private companion object {
        const val SUMMARY_BATCH = 50
        const val RESOLVE_MILLIS = 5_000L
    }
}

/** A Task as the core's `TaskSummary` says it (`taskSummaries`, `archivedTasks`); null for a chat or a row without an id. */
internal fun taskSummaryOf(row: JSONObject): TaskSummary? {
    if (row.optString("kind") != "agent_task") return null
    val id = row.optString("id").takeIf { it.isNotEmpty() } ?: return null
    return TaskSummary(id, row.optString("title"), TaskStatusBucket.of(row.optString("status_bucket")),
        failed = row.optBoolean("status_failed"),
        labelIds = wireStrings(row.optJSONArray("labels")),
        updatedAt = row.optLong("updated_at"),
        archiveAllowed = row.optJSONObject("archive_availability")?.opt("allowed") == true,
        status = row.optString("status"),
        origin = row.optString("origin").takeIf(String::isNotEmpty),
        clientPlatform = row.optString("client_platform").takeIf(String::isNotEmpty),
        archivedAt = wireMillis(row.optLong("archived_at")),
        archivedFrom = row.optString("archived_from_bucket").takeIf(String::isNotEmpty)?.let(TaskStatusBucket::of),
        changedAt = wireMillis(row.optLong("updated_at")))
}
