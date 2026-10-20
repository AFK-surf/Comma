package surf.comma.android.tasks.data

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.GROUP
import surf.comma.android.conversation.messages
import surf.comma.android.conversation.viewState
import surf.comma.android.conversation.viewValue
import surf.comma.android.conversation.scope
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskSection
import surf.comma.android.tasks.TaskStatusBucket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * What the task screens make of the client core's task topics, and the calls the person's actions become. Reading
 * and keeping the tasks is the core's and is tested there.
 */
class ServerTaskRepositoryTest {
    /** The core's task topics, each a value the test sets. */
    private class Core : CoreApi {
        val topics = mapOf("tasks" to MutableStateFlow<JSONObject?>(null), "taskLabels" to MutableStateFlow<JSONObject?>(null),
            "taskOrder" to MutableStateFlow<JSONObject?>(null), "chatView" to MutableStateFlow<JSONObject?>(null))
        /** The facts `taskSummaries` knows, by id: a subscription gets those it names. */
        val summaries = MutableStateFlow<Map<String, JSONObject>>(emptyMap())
        val subscribed = CopyOnWriteArrayList<JSONObject>()
        val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
        @Volatile var archive: () -> Any? = { true }

        override suspend fun call(name: String, params: JSONObject): Any? {
            calls += name to params
            return if (name == "tasks.archive") archive() else null
        }

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
            subscribed += topic
            val name = topic.getString("topic")
            if (name == "taskSummaries") {
                val ids = topic.getString("ids").split(",")
                return summaries.map { known ->
                    TopicValue.Value(read(JSONObject().put("summaries", JSONArray(ids.mapNotNull(known::get)))))
                }
            }
            val values = topics[name] ?: return emptyFlow()
            return values.map { TopicValue.Value(read(it)) }
        }
    }

    private val sessions = FakeSessions()
    private val core = Core()
    private val repository = ServerTaskRepository(sessions, core)

    @After fun after() = repository.close()

    private fun item(id: String, status: String = "running", kind: String = "agent_task", group: String = GROUP) = JSONObject()
        .put("id", "$group:$id").put("groupId", group).put("conversationId", id).put("kind", kind).put("title", "Task $id")
        .put("status", status).put("statusBucket", "in_progress").put("statusFailed", false).put("labels", JSONArray().put("lbl_1")).put("archiveVersion", 1_700L).put("updatedAt", 1)
        .put("archiveAvailability", JSONObject().put("allowed", true).put("reason", JSONObject.NULL))

    private fun summary(id: String, allowed: Boolean = true) = JSONObject().put("id", id).put("group_id", GROUP)
        .put("kind", "agent_task").put("status", "completed").put("status_bucket", "done").put("status_failed", false).put("title", "Task $id").put("updated_at", 2_400L)
        .put("archive_availability", JSONObject().put("allowed", allowed).put("reason", JSONObject.NULL))

    private fun list(vararg items: JSONObject, source: String = "live-sync", more: Boolean = false) = JSONObject()
        .put("items", JSONArray(items.toList())).put("source", source).put("hasMore", more).put("lastSyncedAt", 5)

    private suspend fun await(matches: (TaskDataState) -> Boolean): TaskDataState =
        repository.state.first(matches)

    private fun start() {
        sessions.scopes.value = scope(1)
        repository.start()
        repository.setForeground(true)
    }

    @Test fun `the list shows the group's agent tasks with the label catalog and the board's order`() = runBlocking {
        core.topics.getValue("tasks").value = list(item("task-a"), item("chat", kind = "user_chat"),
            item("other", group = "grp_other"), more = true)
        core.topics.getValue("taskLabels").value = JSONObject().put("catalog", JSONObject().put("labels", JSONArray()
            .put(JSONObject().put("id", "lbl_1").put("name", "Bug").put("color", "red"))
            .put(JSONObject().put("id", "lbl_2").put("name", "Idea"))))
        core.topics.getValue("taskOrder").value = JSONObject().put("sections", JSONArray()
            .put(JSONObject().put("bucket", "in_progress").put("ids", JSONArray().put("task-a")))
            .put(JSONObject().put("bucket", "done").put("ids", JSONArray())))
        start()
        val state = await { it.listLoaded && it.snapshot.labels.isNotEmpty() && it.sections.isNotEmpty() }
        assertEquals(listOf("task-a"), state.snapshot.tasks.map { it.id })
        val task = state.snapshot.tasks.single()
        // The section the core folded the status into.
        assertEquals(listOf("Task task-a", TaskStatusBucket.IN_PROGRESS, listOf("lbl_1"), 1_700L, true),
            listOf(task.title, task.bucket, task.labelIds, task.updatedAt, task.archiveAllowed))
        assertEquals(listOf(TaskLabel("lbl_1", "Bug", "red"), TaskLabel("lbl_2", "Idea", "gray")), state.snapshot.labels)
        assertEquals(listOf(TaskSection(TaskStatusBucket.IN_PROGRESS, listOf("task-a")), TaskSection(TaskStatusBucket.DONE, emptyList())),
            state.sections)
        assertTrue(state.hasMore)
        assertEquals(Connection.LIVE, state.connection)
        assertEquals(1, state.listReads)
        assertEquals(GROUP, state.groupId)
    }

    @Test fun `a list the core could only show from the device says why and can be read again`() = runBlocking {
        core.topics.getValue("tasks").value = list(item("task-a"), source = "cache").put("errorCode", "network_unavailable")
        start()
        val state = await { it.listLoaded }
        assertEquals(ConversationProblem.NETWORK, state.problem)
        assertEquals(Connection.RECONNECTING, state.connection)
        assertEquals(0, state.listReads)
        repository.refresh()
        repository.loadMore()
        assertEquals(listOf("tasks.refresh", "tasks.more"), core.calls.map { it.first })
    }

    @Test fun `tasks a chat refers to are known from their summaries, in batches of fifty`() = runBlocking {
        core.topics.getValue("tasks").value = list(item("task-a"))
        val ids = (1..120).map { "ref-$it" }
        core.summaries.value = ids.associateWith { summary(it) }
        start()
        assertTrue(repository.setConversationTaskIds("chat-1", ids))
        val state = await { it.summaries.size == 121 }
        assertEquals(ids, state.conversationTaskIds["chat-1"])
        assertEquals(120, repository.observeConversationTasks("chat-1").first { it.size == 120 }.size)
        val batches = core.subscribed.filter { it.getString("topic") == "taskSummaries" }.map { it.getString("ids").split(",").size }
        assertEquals(listOf(20, 50, 50), batches.takeLast(3).sorted())
    }

    @Test fun `archiving names the task's version, and says when the server no longer allows it`() = runBlocking {
        core.summaries.value = mapOf("task-a" to summary("task-a"), "task-b" to summary("task-b", allowed = false))
        start()
        assertEquals(TaskArchiveResult.ARCHIVED, repository.archive("task-a"))
        val params = core.calls.single { it.first == "tasks.archive" }.second
        assertEquals(listOf(GROUP, "task-a", "archive", 2_400L),
            listOf(params.getString("group"), params.getString("conversation"), params.getString("action"), params.getLong("version")))
        assertEquals(TaskArchiveResult.NOT_ALLOWED, repository.archive("task-b"))
        assertEquals(TaskArchiveResult.UNAVAILABLE, repository.archive("task-unknown"))
        core.archive = { throw CoreError("conflict", "changed", 409) }
        assertEquals(TaskArchiveResult.CONFLICT, repository.archive("task-a"))
    }

    @Test fun `an opened task shows the newest range of its conversation`() = runBlocking {
        start()
        val state = viewState(messages(1L..2L) + messages(7L..8L), listOf(1L..2L, 7L..8L))
        state.getJSONObject("history").put("hasOlder", true)
        core.topics.getValue("chatView").value = viewValue(state)
        repository.openDetail("task-a")
        val detail = repository.detail.first { it.timeline.isNotEmpty() }
        assertEquals("task-a", detail.taskId)
        assertEquals(listOf(7L, 8L), detail.timeline.map { it.message.seq })
        assertTrue(detail.hasOlder)
        val shown = core.subscribed.last { it.getString("topic") == "chatView" }
        assertEquals("task-a", shown.getString("conversation"))
        repository.loadOlderDetail()
        assertEquals("task-a", core.calls.single { it.first == "chatView.older" }.second.getString("conversation"))
        repository.closeDetail()
        assertEquals(null, repository.detail.first { it.taskId == null }.taskId)
    }
}
