package surf.comma.android.tasks.pages

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.core.view.descendants
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.live.ScrollToLatestButton
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.message
import surf.comma.android.conversation.scope
import surf.comma.android.conversation.viewState
import surf.comma.android.conversation.viewValue
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.data.ServerTaskRepository
import java.io.File
import java.util.concurrent.TimeUnit

/** A task's page, read far up its conversation, offers the same jump back to the latest message as the chat. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TaskDetailJumpTest {
    private class TaskCore(private val chat: JSONObject) : CoreApi {
        override suspend fun call(name: String, params: JSONObject): Any? = null
        override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = when (topic.getString("topic")) {
            "chatView" -> flowOf(TopicValue.Value(read(chat)))
            else -> emptyFlow()
        }
    }

    /** The person's numbered notes: their bubbles need no Markdown parse, and each screen shows which ones it holds. */
    private val conversation = (1L..40L).map { seq ->
        message(seq, actor = "user", text = "Note $seq\nWhat changed in the channel today, and who asked for it.")
    }

    @Test fun `far up a task's conversation, one tap goes back to its latest message`() =
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get().apply { setTheme(R.style.Theme_Chat) }
            controller.setup()
            val sessions = FakeSessions().apply { scopes.value = scope(1) }
            val tasks = ServerTaskRepository(sessions, TaskCore(viewValue(viewState(conversation))), io = Dispatchers.Unconfined)
                .apply { start(); setForeground(true) }
            val pane = TaskDetailPane(activity, "cnv_parent", tasks, sessions.scopes)
            try {
                activity.setContentView(pane.view)
                val run = activity.lifecycleScope.launch { pane.run() }
                settle()
                val timeline = pane.timeline
                assertTrue("opens on the latest message", timeline.isPinnedToEnd())
                val button = pane.view.descendants.filterIsInstance<ScrollToLatestButton>().firstOrNull()

                repeat(4) { drag(timeline, timeline.height) }
                shoot(pane.view, "task-page-scrolled-up")
                assertFalse(timeline.isPinnedToEnd())
                assertTrue("the jump shows far up the conversation", button?.shown == true)

                button!!.performClick()
                settle()
                shoot(pane.view, "task-page-after-jump")
                assertTrue("back on the latest message", timeline.isPinnedToEnd())
                assertFalse(button.shown)
                run.cancel()
            } finally {
                pane.release()
                tasks.close()
            }
        }

    private fun settle() = repeat(150) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    /** A finger drag down the list by [distancePx], back into the conversation's history. */
    private fun drag(view: android.view.View, distancePx: Int) {
        // Event times are the drag's own; only their spacing matters to the list.
        val start = 0L
        val x = view.width / 2f
        val y = view.height / 4f
        fun event(action: Int, dy: Float, at: Long) = MotionEvent.obtain(start, start + at, action, x, y + dy, 0).also {
            view.dispatchTouchEvent(it)
            it.recycle()
        }
        event(MotionEvent.ACTION_DOWN, 0f, 0)
        val steps = 20
        for (step in 1..steps) event(MotionEvent.ACTION_MOVE, distancePx * 0.6f * step / steps, step * 400L)
        event(MotionEvent.ACTION_UP, distancePx * 0.6f, (steps + 1) * 400L)
        settle()
    }

    /** Writes the page as drawn to `$COMMA_SHOTS`, for looking at it; nothing when unset. */
    private fun shoot(view: android.view.View, name: String) {
        val dir = System.getenv("COMMA_SHOTS") ?: return
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        view.draw(Canvas(bitmap))
        File(dir).mkdirs()
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
