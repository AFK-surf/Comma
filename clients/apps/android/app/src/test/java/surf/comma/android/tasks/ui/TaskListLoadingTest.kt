package surf.comma.android.tasks.ui

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.coreSections
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.tasks.pages.TaskListActivity

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh")
class TaskListLoadingTest {
    private val host = Robolectric.buildActivity(ComponentActivity::class.java).setup()
    private val view = TaskListView(host.get())
    // Exercise the activity's actual state-to-view binding without opening an authenticated page.
    private val page = Robolectric.buildActivity(TaskListActivity::class.java).get().also {
        TaskListActivity::class.java.getDeclaredField("list").apply { isAccessible = true }.set(it, view)
    }
    private val render = TaskListActivity::class.java.getDeclaredMethod("render", TaskDataState::class.java)
        .apply { isAccessible = true }

    init { host.get().setContentView(view) }

    @After fun after() { host.pause().stop().destroy() }

    private fun layOut() {
        view.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, 1080, 1800)
        ShadowLooper.idleMainLooper()
    }

    private fun descendants(node: View = view): List<View> = listOf(node) +
        if (node is ViewGroup) (0 until node.childCount).flatMap { descendants(node.getChildAt(it)) } else emptyList()

    private fun visibleTexts() = descendants().filterIsInstance<TextView>()
        .filter { it.isShown }.map { it.text.toString() }

    private fun assertNotice(resource: Int) {
        assertTrue(visibleTexts().contains(host.get().getString(resource)))
        if (resource != R.string.task_list_empty) {
            assertFalse(visibleTexts().contains(host.get().getString(R.string.task_list_empty)))
        }
    }

    private fun render(state: TaskDataState) {
        render.invoke(page, state)
        layOut()
    }

    @Test fun `pending first list never displays the successful empty message`() {
        // The initial state and a paused first load also have no confirmed list yet.
        render(TaskDataState())
        assertNotice(R.string.task_list_loading)
        render(TaskDataState(cacheLoaded = true, loading = true, connection = Connection.LIVE))
        assertNotice(R.string.task_list_loading)
        render(TaskDataState(cacheLoaded = true, connection = Connection.BACKGROUND))
        assertNotice(R.string.task_list_loading)
    }

    @Test fun `only a successful empty list displays no tasks`() {
        render(TaskDataState(cacheLoaded = true, loading = true, connection = Connection.LIVE))
        assertNotice(R.string.task_list_loading)
        render(TaskDataState(cacheLoaded = true, listLoaded = true, connection = Connection.LIVE))
        assertNotice(R.string.task_list_empty)
        assertFalse(visibleTexts().contains(host.get().getString(R.string.task_list_loading)))
    }

    @Test fun `first load failure shows the error and retry returns to loading`() {
        render(TaskDataState(cacheLoaded = true, problem = ConversationProblem.SERVER, connection = Connection.PAUSED))
        assertNotice(R.string.task_list_problem)
        render(TaskDataState(cacheLoaded = true, problem = ConversationProblem.NETWORK, connection = Connection.RECONNECTING))
        assertNotice(R.string.task_list_offline)
        render(TaskDataState(cacheLoaded = true, loading = true, connection = Connection.LIVE))
        assertNotice(R.string.task_list_loading)
    }

    @Test fun `data replaces loading and foreground refresh retains the cached rows and scroll position`() {
        render(TaskDataState(cacheLoaded = true, loading = true, connection = Connection.LIVE))
        assertNotice(R.string.task_list_loading)
        val tasks = (1..30).map { TaskSummary("task-$it", "Task $it", TaskStatusBucket.DONE) }
        val loaded = TaskDataState(cacheLoaded = true, listLoaded = true, connection = Connection.LIVE,
            snapshot = TaskSnapshot(tasks, emptyList()), sections = coreSections(tasks))
        render(loaded)
        val list = descendants().filterIsInstance<RecyclerView>().single { it.adapter is TaskListAdapter }
        val count = list.adapter!!.itemCount
        assertEquals(31, count) // One status heading plus the tasks.
        list.scrollBy(0, 450)
        layOut()
        val first = list.getChildAt(0)
        val top = first.top
        val position = list.getChildAdapterPosition(first)
        val offline = host.get().getString(R.string.task_list_offline)
        for ((state, problemShown) in listOf(
            loaded.copy(connection = Connection.BACKGROUND) to false,
            loaded to false,
            loaded.copy(loading = true) to false,
            loaded.copy(problem = ConversationProblem.NETWORK, connection = Connection.RECONNECTING) to true,
            // The stream trying again clears the problem, but nothing has been read yet.
            loaded.copy(connection = Connection.LIVE) to true,
            loaded.copy(listReads = 1) to false,
        )) {
            render(state)
            assertEquals(count, list.adapter!!.itemCount)
            assertSame(first, list.getChildAt(0))
            assertEquals(top, first.top)
            assertEquals(position, list.getChildAdapterPosition(first))
            // The list is never swapped for a notice; a failure is one line above it.
            val statusStrings = listOf(R.string.task_list_empty, R.string.task_list_loading,
                R.string.task_list_problem).map { host.get().getString(it) }
            assertTrue(visibleTexts().none { it in statusStrings })
            assertEquals(problemShown, visibleTexts().contains(offline))
        }
    }
}
