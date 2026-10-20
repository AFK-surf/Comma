package surf.comma.android.tasks.ui

import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRendererRegistry
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.tasks.TaskPanelCounts
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.tasks.pages.TaskDetailActivity
import surf.comma.android.tasks.pages.TaskListActivity
import surf.comma.android.tasks.pages.TaskPages

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class TaskSurfacesViewTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val theme = TaskTheme(activity)
    private val strings = TaskStrings(activity)

    /** A chat row for one task reference, laid out by the chat's own precomputer. */
    private fun taskRow(taskId: String, title: String?): View {
        val message = ChatMessage(id = 7, conversationId = "chat", role = ChatRole.AGENT, text = "", createdAt = 1,
            cardKind = LiveRowKinds.TASK_REF,
            cardPayload = LiveRowKinds.encode(LiveRowKinds.TaskRef(taskId, title, "completed", unavailable = false)))
        val prepared = runBlocking {
            MessageLayoutPrecomputer().prepare(listOf(message), viewportWidthPx = 1080,
                density = activity.resources.displayMetrics.density, fontScale = 1f, darkTheme = false).single()
        }
        val renderer = ChatCardRendererRegistry.forKind(LiveRowKinds.TASK_REF)!!
        return renderer.create(activity).also { renderer.bind(it, prepared) }
    }

    private fun chipIn(row: View): TaskRefCardView = (row as FrameLayout).getChildAt(0) as TaskRefCardView

    private fun layOut(view: View) {
        view.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }

    @Test fun `the chat card shows a placeholder, then the real title and state, and opens the task`() {
        val session = Any()
        val states = MutableStateFlow(TaskDataState(groupId = "g"))
        val directory = TaskRefDirectory(MutableStateFlow(session), states) { true }
        val opened = ArrayList<String>()
        directory.onOpenTask = { opened += it }
        val host = FrameLayout(activity)
        directory.install(host)
        val row = taskRow("task-9", "Title from the message")
        host.addView(row)
        activity.setContentView(host)
        val job = activity.lifecycleScope.launch { directory.run() }
        ShadowLooper.idleMainLooper()
        layOut(host)

        val chip = chipIn(row)
        // The reference claims "completed", but until the server says so the card shows no state.
        assertEquals("Title from the message", chip.contentDescription)
        assertEquals("task-9", chip.taskId)
        val rowHeight = row.measuredHeight

        states.value = TaskDataState(groupId = "g", summaries = mapOf(
            "task-9" to TaskSummary("task-9", "Canonical title", TaskStatusBucket.IN_PROGRESS),
        ))
        ShadowLooper.idleMainLooper()
        layOut(host)
        assertEquals("Canonical title, ${theme.statusLabel(TaskStatusBucket.IN_PROGRESS)} · ${strings.updatedAt(0)}",
            chip.contentDescription)
        // A new title or state never changes the row's height, so the list does not move.
        assertEquals(rowHeight, row.measuredHeight)

        chip.performClick()
        assertEquals(listOf("task-9"), opened)
        job.cancel()
    }

    @Test fun `an unavailable card is inert`() {
        val chip = TaskRefCardView(activity)
        val opened = ArrayList<String>()
        chip.onOpenTask = { opened += it }
        chip.bindPlaceholder(null, activity.getString(R.string.chat_task_unavailable))
        assertFalse(chip.isClickable)
        chip.performClick()
        assertTrue(opened.isEmpty())
        chip.bind(TaskSummary("task-1", "Ready", TaskStatusBucket.DONE))
        assertTrue(chip.isClickable)
        chip.performClick()
        assertEquals(listOf("task-1"), opened)
    }

    @Test fun `cards find the page's directory up the view tree`() {
        val directory = TaskRefDirectory(MutableStateFlow(Any()), MutableStateFlow(TaskDataState())) { true }
        val outer = FrameLayout(activity)
        val inner = FrameLayout(activity)
        val leaf = View(activity)
        outer.addView(inner)
        inner.addView(leaf)
        assertNull(TaskRefDirectory.find(leaf))
        directory.install(outer)
        assertSame(directory, TaskRefDirectory.find(leaf))
    }

    @Test fun `opening a task goes to the detail page with its id`() {
        val intent = TaskPages.detailIntent(activity, "task-5")
        assertEquals(TaskDetailActivity::class.java.name, intent.component!!.className)
        assertEquals("task-5", intent.getStringExtra(TaskPages.EXTRA_TASK_ID))
        TaskPages.openList(activity)
        assertEquals(TaskListActivity::class.java.name, shadowOf(activity).nextStartedActivity.component!!.className)
    }

    @Test fun `the pill counts the panel rows and a new session clears it`() {
        val panel = TaskConversationPanel(activity)
        val tasks = listOf(
            TaskSummary("a", "A", TaskStatusBucket.IN_PROGRESS),
            TaskSummary("b", "B", TaskStatusBucket.IN_PROGRESS),
            TaskSummary("c", "C", TaskStatusBucket.DONE),
            TaskSummary("d", "D", TaskStatusBucket.ARCHIVED),
        )
        panel.submit(tasks)
        assertEquals(TaskPanelCounts(total = 3, running = 2), panel.counts)
        assertEquals(View.VISIBLE, panel.pill.visibility)
        assertEquals(strings.panelCounts(TaskPanelCounts(3, 2)), panel.pill.contentDescription)

        panel.reset()
        assertTrue(panel.counts.isEmpty)
        assertFalse(panel.pill.visibility == View.VISIBLE)
    }

    @Test fun `a sideways drag on a card is not a tap`() {
        val preparer = TaskRowPreparer(theme, strings)
        val row = preparer.prepare(listOf(surf.comma.android.tasks.TaskListRow.Card(
            TaskSummary("bound", "Weekly sync", TaskStatusBucket.DONE, archiveAllowed = false))), emptyList(), 1080)
            .single() as PreparedTaskRow.Card
        val card = TaskCardView(activity, theme, preparer.metrics)
        val opened = ArrayList<String>()
        card.onOpenTask = { opened += it }
        card.bind(row)
        // Attached, so the click View posts on release actually runs.
        activity.setContentView(card)
        ShadowLooper.idleMainLooper()
        fun touch(action: Int, x: Float) = card.dispatchTouchEvent(
            android.view.MotionEvent.obtain(0, 0, action, x, 40f, 0))
        touch(android.view.MotionEvent.ACTION_DOWN, 900f)
        touch(android.view.MotionEvent.ACTION_MOVE, 500f)
        touch(android.view.MotionEvent.ACTION_UP, 200f)
        ShadowLooper.idleMainLooper()
        assertTrue(opened.isEmpty())
        touch(android.view.MotionEvent.ACTION_DOWN, 500f)
        touch(android.view.MotionEvent.ACTION_UP, 500f)
        ShadowLooper.idleMainLooper()
        assertEquals(listOf("bound"), opened)
    }

    @Test fun `task pages without a session close at once`() {
        val list = Robolectric.buildActivity(TaskListActivity::class.java).create().get()
        assertTrue(list.isFinishing)
        val detail = Robolectric.buildActivity(TaskDetailActivity::class.java,
            TaskPages.detailIntent(activity, "task-1")).create().get()
        assertTrue(detail.isFinishing)
        assertNotNull(detail)
    }
}
