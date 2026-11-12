package surf.comma.android.chat.live

import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.FakeChatViewCore
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.GROUP
import surf.comma.android.conversation.scope
import surf.comma.android.conversation.viewState
import surf.comma.android.conversation.viewValue
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.tasks.pages.TaskDetailPane
import surf.comma.android.tasks.ui.TaskRefDirectory

/**
 * A task in a reply's text takes its title from the page's task directory: the chip the server sends carries none.
 * Until the directory knows the task the text says "Task"; it says the title once the directory learns it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class InlineTaskTitleTest {
    /** The core's task topics: `taskSummaries` knows what the test puts in [summaries]; `chatView` shows [chat]. */
    private class TaskCore(private val chat: JSONObject? = null) : CoreApi {
        val summaries = MutableStateFlow<Map<String, JSONObject>>(emptyMap())

        override suspend fun call(name: String, params: JSONObject): Any? = null

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = when (topic.getString("topic")) {
            "taskSummaries" -> {
                val ids = topic.getString("ids").split(",")
                summaries.map { known -> TopicValue.Value(read(JSONObject().put("summaries", JSONArray(ids.mapNotNull(known::get))))) }
            }
            "chatView" -> chat?.let { flowOf(TopicValue.Value(read(it))) } ?: emptyFlow()
            else -> emptyFlow()
        }
    }

    /** The Agent's reply: a task in the middle of a sentence, as the server sends it, without a title. */
    private val reply = JSONObject().put("message_id", "msg_2").put("seq", 2).put("actor_type", "agent").put("agent_id", "agt_1")
        .put("created_at", 1_700_000_000_002L).put("content", JSONArray()
            .put(JSONObject().put("type", "text").put("text", "见 "))
            .put(JSONObject().put("type", "conversation_ref").put("presentation", "inline").put("kind", "agent_task")
                .put("conversation_id", "cnv_a"))
            .put(JSONObject().put("type", "text").put("text", "。")))

    private fun summary(id: String, title: String) = JSONObject().put("id", id).put("group_id", GROUP).put("kind", "agent_task")
        .put("status", "running").put("status_bucket", "in_progress").put("status_failed", false).put("title", title)
        .put("updated_at", 2_400L)

    private fun copySelectedMessage(root: ViewGroup, title: String) {
        val cell = root.descendants.filterIsInstance<ChatMessageCell>()
            .single { "见" in it.contentDescription.toString() }
        org.junit.Assert.assertTrue(cell.performLongClick())
        val popup = org.robolectric.Shadows.shadowOf((root.context as ComponentActivity).application).latestPopupWindow
        (popup.contentView as ViewGroup).descendants.filterIsInstance<android.widget.TextView>()
            .single { it.text == root.context.getString(R.string.action_select_text) }.performClick()
        ShadowLooper.idleMainLooper()
        requireNotNull(cell.textSelection).selectAll()
        requireNotNull(cell.textSelection).copy()
        val copied = root.context.getSystemService(android.content.ClipboardManager::class.java)
            .primaryClip!!.getItemAt(0).text.toString()
        org.junit.Assert.assertTrue("clipboard must contain directory title: $copied", copied.contains(title))
        org.junit.Assert.assertFalse(copied.contains("comma:task/"))
        org.junit.Assert.assertFalse(copied.contains("cnv_a"))
    }

    @Test fun `the chat says a task's title in a reply once its directory learns it`() =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.setup()
            val sessions = FakeSessions().apply { scopes.value = scope(1) }
            val chat = ChatView(sessions, FakeChatViewCore().apply { show(listOf(reply)) }, io = Dispatchers.Unconfined)
                .apply { start(); setForeground(true) }
            val core = TaskCore()
            val tasks = ServerTaskRepository(sessions, core, io = Dispatchers.Unconfined).apply { start(); setForeground(true) }
            val screen = LiveChatScreen(activity, chat, AuthGraph.get(activity).state, retrySession = {}, onOpenAccount = {},
                taskData = tasks, taskSessions = sessions.scopes)
            try {
                activity.setContentView(screen.root)
                screen.bind()
                ShadowLooper.idleMainLooper()
                // What the reply's cell reads out, after who says it.
                fun replyText() = (screen.root as ViewGroup).descendants.filterIsInstance<ChatMessageCell>()
                    .map { it.contentDescription.toString() }.single { "见" in it }.substringAfter(": ")
                assertEquals("见 ${activity.getString(R.string.chat_task_ref)}。", replyText())

                core.summaries.value = mapOf("cnv_a" to summary("cnv_a", "Ship the report"))
                ShadowLooper.idleMainLooper()
                assertEquals("见 Ship the report。", replyText())
                copySelectedMessage(screen.root as ViewGroup, "Ship the report")
            } finally {
                screen.release()
                chat.close()
                tasks.close()
            }
        }

    @Test fun `the task page says a task's title in its messages once its directory learns it`() =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.setup()
            val sessions = FakeSessions().apply { scopes.value = scope(1) }
            val core = TaskCore(chat = viewValue(viewState(listOf(reply))))
            val tasks = ServerTaskRepository(sessions, core, io = Dispatchers.Unconfined).apply { start(); setForeground(true) }
            val pane = TaskDetailPane(activity, "cnv_parent", tasks, sessions.scopes, sheet = true)
            try {
                activity.setContentView(pane.view)
                val run = activity.lifecycleScope.launch { pane.run() }
                ShadowLooper.idleMainLooper()
                fun replyText() = pane.rows.map { it.message.text }.single { "见" in it }
                assertEquals("见 ${activity.getString(R.string.chat_task_ref)}。", replyText())

                core.summaries.value = mapOf("cnv_a" to summary("cnv_a", "Ship the report"))
                ShadowLooper.idleMainLooper()
                assertEquals("见 Ship the report。", replyText())
                copySelectedMessage(pane.view, "Ship the report")
                run.cancel()
            } finally {
                pane.release()
                tasks.close()
            }
        }

    @Test fun `the rows are made again when a task's title changes, not when only its progress does`() =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.setup().get()
            val running = TaskSummary("cnv_a", "Ship the report", TaskStatusBucket.IN_PROGRESS, progress = "Reading the notes")
            val states = MutableStateFlow(TaskDataState(groupId = GROUP, summaries = mapOf("cnv_a" to running)))
            val directory = TaskRefDirectory(MutableStateFlow(Any()), states) { true }
            val changes = directory.knownChanges()
            val run = activity.lifecycleScope.launch { directory.run() }
            ShadowLooper.idleMainLooper()
            val titles = mutableListOf<String?>()
            val seen = activity.lifecycleScope.launch { changes.collect { titles += it.summary("cnv_a")?.title } }
            ShadowLooper.idleMainLooper()

            states.value = TaskDataState(groupId = GROUP, summaries = mapOf("cnv_a" to running.copy(progress = "Writing it up")))
            ShadowLooper.idleMainLooper()
            states.value = TaskDataState(groupId = GROUP, summaries = mapOf("cnv_a" to running.copy(title = "Ship the final report")))
            ShadowLooper.idleMainLooper()
            assertEquals(listOf("Ship the report", "Ship the final report"), titles)
            seen.cancel()
            run.cancel()
        }
}
