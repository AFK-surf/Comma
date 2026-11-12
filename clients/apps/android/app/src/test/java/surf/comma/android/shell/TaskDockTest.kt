package surf.comma.android.shell

import android.view.View
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.awaitState
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.GROUP
import surf.comma.android.conversation.scope
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.list.TaskActions
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TaskDockTest {
    @Before fun jumpSprings() = setDurationScale(0f)
    @After fun restoreSprings() = setDurationScale(1f)

    private fun setDurationScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, scale)
    }

    /** The core's `tasks` topic with one running Task, so the header shows its title over its status. */
    private class Core : CoreApi {
        override suspend fun call(name: String, params: JSONObject): Any? = null

        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
            if (topic.getString("topic") != "tasks") return emptyFlow()
            val task = JSONObject().put("id", "$GROUP:task-a").put("groupId", GROUP).put("conversationId", "task-a")
                .put("kind", "agent_task").put("title", "Summarise today's Slack").put("status", "running")
                .put("statusBucket", "in_progress").put("statusFailed", false).put("updatedAt", 1)
            return flowOf(TopicValue.Value(read(JSONObject().put("items", JSONArray().put(task)).put("source", "live-sync")
                .put("hasMore", false).put("lastSyncedAt", 5))))
        }
    }

    @Test fun `the raised sheet shows a grabber between its top edge and the title capsule, hidden under the details and when minimized`() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.create()
            val auth = TestAuthRepository(MemorySessions())
            AuthGraph.install(auth, CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
            runBlocking { auth.start(); auth.awaitState<AuthState.Login>() }
            val sessions = FakeSessions().apply { scopes.value = scope(1) }
            val tasks = ServerTaskRepository(sessions, Core(), io = Dispatchers.Unconfined).apply { start(); setForeground(true) }
            val store = WorkspaceStore(activity, auth, tasks, CommaApi(null))
            val shell = object : Shell {
                override val activity = activity
                override val store = store
                override val actions = TaskActions(activity, store)
                override fun openRouter(focus: Boolean) = Unit
                override fun insertIntoRouter(text: String) = Unit
                override fun openSearch() = Unit
                override fun notificationsOff(): (() -> Unit)? = null
            }
            val dock = TaskDock(shell) { _, _ -> }
            activity.setContentView(dock)
            controller.start().resume().visible()
            try {
                dock.open("task-a")
                ShadowLooper.idleMainLooper()
                val panel = dock.findViewById<View>(R.id.task_dock)
                val grabber = dock.findViewById<View>(R.id.task_dock_grabber)
                val title = dock.descendants.filterIsInstance<TextView>().single { it.text == "Summarise today's Slack" }
                val titleBlock = title.parent as View
                val density = activity.resources.displayMetrics.density
                fun top(view: View) = IntArray(2).also(view::getLocationInWindow)[1] - IntArray(2).also(panel::getLocationInWindow)[1]
                fun left(view: View) = IntArray(2).also(view::getLocationInWindow)[0] - IntArray(2).also(panel::getLocationInWindow)[0]

                assertEquals("the title row centres 35dp below the sheet's top edge", 35 * density,
                    top(titleBlock) + titleBlock.height / 2f, density)
                assertTrue("the raised sheet shows the grabber", grabber.isShown)
                assertEquals(1f, grabber.alpha, 0f)
                assertEquals("centred across the sheet", panel.width / 2f, left(grabber) + grabber.width / 2f, 1f)
                // The capsule the closed card draws around the title and its status line.
                val capsuleTop = top(title) - 5 * density
                assertTrue("below the sheet's top edge", top(grabber) > 0)
                assertTrue("clear of the title capsule", top(grabber) + grabber.height + 3 * density <= capsuleTop)

                titleBlock.performClick()
                ShadowLooper.idleMainLooper()
                assertEquals("the open details card covers its spot", 0f, grabber.alpha, 0f)
                titleBlock.performClick()
                ShadowLooper.idleMainLooper()
                assertEquals("it returns once the card closes", 1f, grabber.alpha, 0f)

                dock.minimize()
                ShadowLooper.idleMainLooper()
                assertEquals("the minimized bar has none", 0f, grabber.alpha, 0f)
            } finally {
                dock.release()
                tasks.close()
            }
        }
    }
}
