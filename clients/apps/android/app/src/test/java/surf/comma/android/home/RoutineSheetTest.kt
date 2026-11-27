package surf.comma.android.home

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import androidx.core.view.isVisible
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.TestSessionCore
import surf.comma.android.auth.awaitState
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The whole routine in its sheet: how many cards are left beside the refresh, the cleared line once the server
 * answers a briefing with no card left, a refused dismissal, a linked Task that ends, and cards again after a refresh.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class RoutineSheetTest {
    /** The core's `recommendations` and `tasks` topics, and the calls the sheet makes of it. */
    private class Core : CoreApi {
        val briefing = MutableStateFlow<JSONObject?>(null)
        val tasks = MutableStateFlow<JSONObject?>(null)
        val calls = CopyOnWriteArrayList<String>()
        /** The server refuses to stop a card's suggestions. */
        @Volatile var refusesDismissal = false

        override suspend fun call(name: String, params: JSONObject): Any? {
            calls += name
            if (name == "recommendations.dismiss" && refusesDismissal) throw CoreError("unavailable", "refused", 503)
            return if (name == "recommendations.refresh") JSONObject().put("rateLimited", false) else null
        }

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = when (topic.getString("topic")) {
            "recommendations" -> briefing.filterNotNull().map { TopicValue.Value(read(it)) }
            "tasks" -> tasks.filterNotNull().map { TopicValue.Value(read(it)) }
            else -> emptyFlow()
        }
    }

    /** A briefing whose one Slack card has `rows`. */
    private fun briefing(generation: Int, rows: List<JSONObject>) = JSONObject().put("refreshing", false).put("envelope", JSONObject("""
        {"state":"fresh","settings":{"sources":[
          {"appId":"slack","appName":"Slack","connectionId":"conn-sl","enabled":true,"kind":"composio","label":"acme"}]},
         "snapshot":{"generation":$generation,"summary":[{"kind":"markdown","text":"Your work briefing"}],"cards":[]}}
    """.trimIndent()).apply {
        if (rows.isEmpty()) return@apply
        getJSONObject("snapshot").put("cards", JSONArray().put(JSONObject("""
            {"id":"slack","title":"Slack","template":"text-list@1","sourceIds":["conn-sl"],"items":[]}
        """.trimIndent()).put("items", JSONArray(rows))))
    })

    /** A briefing of Slack rows, each a member task that names its source item, so the member can stop it. */
    private fun briefing(generation: Int, vararg rows: String) = briefing(generation, rows.map { row ->
        val url = "https://acme.slack.com/archives/C1/$row"
        JSONObject().put("id", row)
            .put("parts", JSONArray().put(JSONObject().put("kind", "inline-link").put("link", JSONObject()
                .put("href", url).put("label", "Decide on $row").put("sourceId", "conn-sl").put("objective", "Decide on $row"))))
            .put("action", JSONObject().put("type", "send_to_comma").put("label", "Decide").put("memberTask", true)
                .put("prompt", "Decide on $row\n\n$url").put("requiresConfirmation", true))
    })

    /** A row that stands for one Task: it shows while the Task is open. */
    private fun taskRow(task: String) = JSONObject().put("id", "row-$task")
        .put("parts", JSONArray().put(JSONObject().put("kind", "inline-task").put("task", JSONObject()
            .put("conversationId", task).put("label", "Follow up on $task").put("sourceId", "conn-sl"))))
        .put("action", JSONObject().put("type", "open_url").put("label", "Open").put("href", "https://acme.slack.com/archives/C1/$task")
            .put("requiresConfirmation", false))

    /** The core's task list with one Task of `group`. */
    private fun taskList(group: String, task: String, status: String) = JSONObject().put("source", "live-sync").put("hasMore", false)
        .put("lastSyncedAt", status.hashCode()).put("items", JSONArray().put(JSONObject()
            .put("id", "$group:$task").put("groupId", group).put("conversationId", task).put("kind", "agent_task").put("title", "Task $task")
            .put("status", status).put("statusBucket", if (status == "completed") "done" else "in_progress").put("statusFailed", false)
            .put("archiveVersion", 1_700L).put("updatedAt", 1)))

    /** What a test reads of the sheet and does to it. */
    private class Shown(val activity: ComponentActivity, val core: Core, val store: WorkspaceStore, val group: String) {
        val root: ViewGroup get() = activity.findViewById(android.R.id.content)
        /** The status line: the words on the refresh's line. */
        val line: TextView get() = (refresh.parent as ViewGroup).descendants.filterIsInstance<TextView>().first()
        val status: String get() = line.text.toString()
        val cleared: View? get() = root.findViewById(R.id.routines_cleared)
        val refresh: View get() = root.findViewById(R.id.routines_refresh)
        fun left(count: Int): String = activity.resources.getQuantityString(R.plurals.routines_status_count, count, count)
        fun card(words: String): View? = root.descendants.firstOrNull { it.isShown && it.contentDescription?.toString()?.startsWith(words) == true }

        /** The member stops the card's suggestions: the minus, then the menu's one row, wherever the menu is drawn. */
        fun stop(card: View) {
            val title = activity.getString(R.string.routines_dismiss)
            (card as ViewGroup).descendants.first { it.contentDescription == title }.performClick()
            ShadowLooper.idleMainLooper()
            val roots = listOfNotNull(
                activity.window.decorView as? ViewGroup,
                shadowOf(RuntimeEnvironment.getApplication()).latestPopupWindow?.contentView as? ViewGroup,
            )
            (roots.flatMap { it.descendants.filterIsInstance<TextView>().toList() }.last { it.text.toString() == title }.parent as View).performClick()
            ShadowLooper.idleMainLooper()
        }

        fun say(briefing: JSONObject) {
            core.briefing.value = briefing
            ShadowLooper.idleMainLooper()
        }
    }

    /** Signs in, has the store read `first`, opens the sheet and runs `test` on it. */
    private fun sheet(first: JSONObject, tasks: (group: String) -> JSONObject? = { null }, test: Shown.() -> Unit) {
        val sessions = MemorySessions()
        AuthGraph.install(TestAuthRepository(sessions, core = TestSessionCore(sessions)), CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
        val auth = AuthGraph.get(RuntimeEnvironment.getApplication())
        runBlocking {
            auth.start()
            auth.awaitState<AuthState.Login>()
            auth.sendCode("alice@example.test")
            auth.awaitState<AuthState.Login> { it.challengeId != null }
            auth.verify("123456")
            auth.awaitState<AuthState.Connected>()
        }
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.create().start().resume().visible()
            val core = Core()
            val group = checkNotNull(auth.conversationScope.value).groupId
            core.tasks.value = tasks(group)
            val repository = ServerTaskRepository(AuthConversationSessions(auth), core, io = Dispatchers.Unconfined)
            val store = WorkspaceStore(activity, auth, repository, CommaApi(core)).apply { start() }
            try {
                repository.start()
                repository.setForeground(true)
                ShadowLooper.idleMainLooper()
                core.briefing.value = first
                runBlocking { store.routines.load() }
                ShadowLooper.idleMainLooper()
                assertNotNull("the store reads the briefing", store.routines.feed.value)
                RoutineSheet(activity, store, RoutineActions(activity, usePrompt = {}, openTask = {})).show()
                ShadowLooper.idleMainLooper()
                Shown(activity, core, store, group).test()
            } finally {
                repository.close()
            }
        }
    }

    @Test fun `the sheet counts the cards the briefing has, shows it cleared once the server answers without the last, and a refresh brings cards back`() =
        sheet(briefing(1, "p1", "p2")) {
            assertEquals(left(2), status)
            // The refresh is on the status's line, at its end.
            assertTrue(line.isShown)
            assertTrue(IntArray(2).also(refresh::getLocationInWindow)[0] > IntArray(2).also(line::getLocationInWindow)[0])
            assertNull(cleared)

            // The member stops both cards, one after the other. Each leaves at once; the line counts what the server answers.
            for ((row, rest) in listOf("p1" to listOf("p2"), "p2" to emptyList())) {
                val before = status
                val card = checkNotNull(card("Decide on $row"))
                stop(card)
                assertFalse("the card leaves at once", card.isVisible)
                assertEquals("the line waits for the server", before, status)
                assertNull("so does the cleared line", cleared)
                say(briefing(1, *rest.toTypedArray()))
                assertNull("the card the server took stays gone", card("Decide on $row"))
                assertEquals(if (rest.isEmpty()) activity.getString(R.string.routines_status_cleared) else left(rest.size), status)
            }
            assertEquals(2, core.calls.count { it == "recommendations.dismiss" })
            assertTrue("the cleared line takes the cards' place", checkNotNull(cleared).isShown)

            // A refresh publishes a new briefing: its cards show, and the line counts them.
            assertTrue(refresh.isEnabled)
            refresh.performClick()
            ShadowLooper.idleMainLooper()
            assertEquals(1, core.calls.count { it == "recommendations.refresh" })
            say(briefing(2, "p3", "p4", "p5"))
            assertNull(cleared)
            assertEquals(left(3), status)
            assertNotNull(card("Decide on p3"))
        }

    @Test fun `a card the server refuses to stop comes back, and the sheet does not read as cleared`() =
        sheet(briefing(1, "p1")) {
            core.refusesDismissal = true
            val card = checkNotNull(card("Decide on p1"))
            stop(card)
            assertEquals(1, core.calls.count { it == "recommendations.dismiss" })
            assertTrue("the refusal is said", store.toast.value?.error == true)
            val back = checkNotNull(card("Decide on p1")) { "the card is back" }
            assertNotEquals(card, back)
            assertEquals(left(1), status)
            assertNull(cleared)
        }

    @Test fun `a row that stands for a Task leaves when the Task ends, and the sheet reads as cleared`() {
        val briefing = briefing(1, listOf(taskRow("t1")))
        sheet(briefing, tasks = { group -> taskList(group, "t1", "running") }) {
            assertEquals(left(1), status)
            assertNotNull(card("Follow up on t1"))
            // The Task ends: only the task list says so, the briefing is the same.
            core.tasks.value = taskList(group, "t1", "completed")
            ShadowLooper.idleMainLooper()
            assertNull(card("Follow up on t1"))
            assertEquals(activity.getString(R.string.routines_status_cleared), status)
            assertNotNull(cleared)
        }
    }
}
