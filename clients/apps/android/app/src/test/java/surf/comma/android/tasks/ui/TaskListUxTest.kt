package surf.comma.android.tasks.ui

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.coreSections
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.tasks.pages.TaskListActivity

/**
 * The task list page as a reader uses it: filtering, opening a task and coming back while the
 * list changes underneath, a recreated page, failures over a cached list, and archiving.
 * Driven through the activity's own state-to-view binding, with built data and no account.
 */
@RunWith(RobolectricTestRunner::class)
// The window lays the page out too; give it the width the manual layout uses, so both agree.
@Config(sdk = [35], qualifiers = "zh-w360dp-h600dp-xxhdpi")
class TaskListUxTest {
    private val host = Robolectric.buildActivity(ComponentActivity::class.java).setup()
    private val activity get() = host.get()
    private var view = TaskListView(activity)
    private var page = pageFor(view)
    private val render = TaskListActivity::class.java.getDeclaredMethod("render", TaskDataState::class.java)
        .apply { isAccessible = true }
    private val opened = ArrayList<String>()
    private val archived = ArrayList<String>()
    private var retries = 0

    init { attach(view) }

    @After fun after() { host.pause().stop().destroy() }

    private fun pageFor(list: TaskListView) = Robolectric.buildActivity(TaskListActivity::class.java).get().also {
        TaskListActivity::class.java.getDeclaredField("list").apply { isAccessible = true }.set(it, list)
    }

    private fun attach(list: TaskListView) {
        list.onOpenTask = { opened += it }
        list.onArchiveTask = { archived += it }
        list.onRetry = { retries++ }
        activity.setContentView(list)
    }

    /** A new page, as after the activity was recreated. */
    private fun recreate() {
        view = TaskListView(activity)
        page = pageFor(view)
        attach(view)
    }

    private fun layOut() {
        view.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(1800, View.MeasureSpec.EXACTLY))
        view.layout(0, 0, 1080, 1800)
        ShadowLooper.idleMainLooper()
    }

    private fun render(state: TaskDataState) {
        render.invoke(page, state)
        settle()
    }

    /** Row preparation and the diff run in place in tests (TestCommaApplication); their results come on the looper. */
    private fun settle() {
        layOut()
        assertTrue("the list never settled", view.isIdle)
        layOut()
    }

    private fun descendants(node: View = view): List<View> = listOf(node) +
        if (node is ViewGroup) (0 until node.childCount).flatMap { descendants(node.getChildAt(it)) } else emptyList()

    private fun visibleTexts() = descendants().filterIsInstance<TextView>().filter { it.isShown }.map { it.text.toString() }

    private fun shownText(text: String) = descendants().filterIsInstance<TextView>().single { it.isShown && it.text.toString() == text }

    private val list get() = descendants().filterIsInstance<RecyclerView>().single { it.adapter is TaskListAdapter }

    private val adapter get() = list.adapter as TaskListAdapter

    private fun cards() = adapter.currentList.filterIsInstance<PreparedTaskRow.Card>()

    /** Every row on screen, top down, as its key and its top. */
    private fun shownRows(): List<Pair<String, Int>> = (0 until list.childCount).map(list::getChildAt)
        .filter { it.bottom > 0 && it.top < list.height }
        .map { adapter.currentList[list.getChildAdapterPosition(it)].key to it.top }.sortedBy { it.second }

    /** The first card whose top is on screen, and that top. */
    private fun firstShownCard(): Pair<String, Int> {
        val child = (0 until list.childCount).map(list::getChildAt).first { it is TaskCardView && it.top >= 0 }
        return (child as TaskCardView).card!!.task.id to child.top
    }

    private fun cardView(id: String) = (0 until list.childCount).map(list::getChildAt)
        .filterIsInstance<TaskCardView>().single { it.card?.task?.id == id }

    private fun loaded(tasks: List<TaskSummary>, group: String = "g1", reads: Int = 1, epoch: String = "e1") = TaskDataState(
        groupId = group, cacheLoaded = true, listLoaded = true, listReads = reads, listReadsEpoch = epoch,
        connection = Connection.LIVE,
        snapshot = TaskSnapshot(tasks, LABELS), sections = coreSections(tasks),
    )

    /** 12 running and 30 finished tasks; even ones carry the Work label. */
    private fun seed(): List<TaskSummary> = (1..42).map { n ->
        TaskSummary(
            id = "t$n", title = "Task $n", bucket = if (n <= 12) TaskStatusBucket.IN_PROGRESS else TaskStatusBucket.DONE,
            labelIds = if (n % 2 == 0) listOf("work") else listOf("home"),
            updatedAt = 1_700_000_000_000L - n * 60_000L, archiveAllowed = n > 12,
        )
    }

    @Test fun `coming back from a task keeps the filter and the place even when the list changed`() {
        val tasks = seed()
        render(loaded(tasks))
        shownText("Work").performClick()
        settle()
        assertTrue(cards().all { "work" in it.task.labelIds })
        // A card partly scrolled away at the top: the row the list anchors on.
        val start = adapter.currentList.indexOfFirst { it.key == "task:t8" }
        (list.layoutManager as LinearLayoutManager).scrollToPositionWithOffset(start, -20)
        settle()
        val rows = shownRows()
        val topId = rows[0].first.removePrefix("task:")
        val next = rows[1]
        cardView(topId).performClick()
        assertEquals(listOf(topId), opened)

        // While the task is open: it finishes and moves group, a task above it is archived, a new
        // one starts at the very top, and the shared order moves things around.
        val changed = tasks.map {
            when (it.id) {
                topId -> it.copy(bucket = TaskStatusBucket.DONE, updatedAt = it.updatedAt + 1)
                "t2" -> it.copy(bucket = TaskStatusBucket.ARCHIVED)
                else -> it
            }
        } + TaskSummary("t99", "New", TaskStatusBucket.IN_PROGRESS, labelIds = listOf("work"), updatedAt = 1_800_000_000_000L)
        val moved = coreSections(changed).map { section ->
            if (section.bucket != TaskStatusBucket.DONE) section
            else section.copy(ids = listOf("t42", "t40") + (section.ids - setOf("t42", "t40")))
        }
        render(loaded(changed, reads = 2).copy(sections = moved))

        assertTrue(cards().all { "work" in it.task.labelIds })
        assertTrue(cards().none { it.task.id == "t2" })
        // The task that moved is not followed; the row that was under it holds the reader's place.
        assertEquals(next, shownRows().first { it.first == next.first })
        assertTrue(list.canScrollVertically(-1))
    }

    @Test fun `a list read at the top stays at the top when new tasks arrive`() {
        val tasks = seed()
        render(loaded(tasks))
        assertFalse(list.canScrollVertically(-1))
        render(loaded(tasks + TaskSummary("t99", "New", TaskStatusBucket.IN_PROGRESS, updatedAt = 1_800_000_000_000L), reads = 2))
        assertFalse(list.canScrollVertically(-1))
        assertEquals("t99", firstShownCard().first)
    }

    @Test fun `picking another filter goes to the top`() {
        render(loaded(seed()))
        list.scrollBy(0, 900)
        settle()
        shownText("Home").performClick()
        settle()
        assertFalse(list.canScrollVertically(-1))
    }

    @Test fun `a recreated page gets its filter and place back, in the same group only`() {
        val tasks = seed()
        render(loaded(tasks))
        shownText("Work").performClick()
        settle()
        list.scrollBy(0, 700)
        settle()
        val place = firstShownCard()
        val saved = Bundle().also { page.saveInto(it, loaded(tasks)) }

        recreate()
        page.restoreFrom(saved)
        // The first frames have nothing to restore into yet.
        render(TaskDataState())
        render(TaskDataState(groupId = "g1", cacheLoaded = true, loading = true))
        render(loaded(tasks))
        assertTrue(shownText("Work").isSelected)
        assertTrue(cards().all { "work" in it.task.labelIds })
        assertEquals(place, firstShownCard())

        // Another account's page never starts from this one's filter or place.
        recreate()
        page.restoreFrom(saved)
        render(loaded(tasks.map { it.copy(id = "other-${it.id}") }, group = "g2"))
        assertTrue(shownText("全部").isSelected)
        assertFalse(list.canScrollVertically(-1))
        assertEquals(tasks.size, cards().size)
    }


    @Test fun `a late commit does not undo a scroll the reader made while it was being diffed`() {
        val tasks = seed()
        render(loaded(tasks))
        list.scrollBy(0, 700)
        settle()
        var moved: List<Pair<String, Int>>? = null
        view.beforeCommit = {
            view.beforeCommit = null
            // The reader keeps scrolling between the update's start and its commit.
            list.scrollBy(0, 300)
            moved = shownRows()
        }
        render(loaded(tasks.map { if (it.id == "t20") it.copy(title = "Renamed") else it }, reads = 2))
        assertNotNull(moved)
        assertEquals(moved!!.take(3), shownRows().take(3))
    }

    @Test fun `a recreated page hands over to the next row when the top task changed group`() {
        val tasks = seed()
        render(loaded(tasks))
        val start = adapter.currentList.indexOfFirst { it.key == "task:t8" }
        (list.layoutManager as LinearLayoutManager).scrollToPositionWithOffset(start, -20)
        settle()
        val rows = shownRows()
        assertEquals("task:t8", rows[0].first)
        val saved = Bundle().also { page.saveInto(it, loaded(tasks)) }

        // t8 finished while the page was gone; it now sits in the done group.
        recreate()
        page.restoreFrom(saved)
        render(loaded(tasks.map { if (it.id == "t8") it.copy(bucket = TaskStatusBucket.DONE) else it }, reads = 2))
        assertEquals(rows[1], shownRows().first { it.first == rows[1].first })
        assertEquals(rows[1].first, shownRows().first { it.second >= 0 }.first)
    }

    @Test fun `a recreated page keeps an unanswered failure until a read succeeds`() {
        val state = loaded(seed(), reads = 3)
        val failed = activity.getString(R.string.task_list_refresh_failed)
        render(state.copy(problem = ConversationProblem.SERVER))
        assertTrue(visibleTexts().contains(failed))
        // The stream's next attempt cleared the repository's problem; nothing was read since.
        render(state)
        val saved = Bundle().also { page.saveInto(it, state) }

        recreate()
        page.restoreFrom(saved)
        render(state)
        assertTrue(visibleTexts().contains(failed))
        render(state.copy(listReads = 4))
        assertFalse(visibleTexts().contains(failed))

        // Never into another group.
        recreate()
        page.restoreFrom(saved)
        render(loaded(seed(), group = "g2", reads = 3))
        assertFalse(visibleTexts().contains(failed))
    }

    @Test fun `a restarted process clears a saved failure once it has read, whatever its count`() {
        val old = loaded(seed(), reads = 1, epoch = "old-process")
        val failed = activity.getString(R.string.task_list_refresh_failed)
        render(old.copy(problem = ConversationProblem.SERVER))
        render(old)
        val saved = Bundle().also { page.saveInto(it, old) }

        // The new process read once before the page came back: also a count of 1, another epoch.
        recreate()
        page.restoreFrom(saved)
        render(loaded(seed(), reads = 1, epoch = "new-process"))
        assertFalse(visibleTexts().contains(failed))

        // Recreated before the new process has read anything: the failure still stands.
        recreate()
        page.restoreFrom(saved)
        render(loaded(seed(), reads = 0, epoch = "new-process"))
        assertTrue(visibleTexts().contains(failed))
        render(loaded(seed(), reads = 1, epoch = "new-process"))
        assertFalse(visibleTexts().contains(failed))
    }

    @Test fun `a failed refresh keeps the list and offers a retry until a read succeeds`() {
        val state = loaded(seed())
        render(state)
        val failed = activity.getString(R.string.task_list_refresh_failed)
        render(state.copy(problem = ConversationProblem.SERVER))
        assertEquals(cards().size, seed().size)
        assertTrue(visibleTexts().contains(failed))
        // The retry sits beside the line, not in place of the list.
        shownText(activity.getString(R.string.task_detail_retry)).performClick()
        assertEquals(1, retries)
        // A retry starting clears the repository's problem; the line waits for a real answer.
        render(state.copy(problem = null, loading = true))
        assertTrue(visibleTexts().contains(failed))
        render(state.copy(listReads = state.listReads + 1))
        assertFalse(visibleTexts().contains(failed))
        // A cache that could not be written is not a failed refresh.
        render(state.copy(listReads = state.listReads + 1, problem = ConversationProblem.STORAGE))
        assertFalse(visibleTexts().contains(failed))
    }

    @Test fun `an empty list that failed to load says so with a retry`() {
        render(TaskDataState(groupId = "g1", cacheLoaded = true, problem = ConversationProblem.SERVER, connection = Connection.PAUSED))
        assertTrue(visibleTexts().contains(activity.getString(R.string.task_list_problem)))
        assertFalse(visibleTexts().contains(activity.getString(R.string.task_list_empty)))
        // Said once, in the empty notice, not again in the line above the list.
        assertFalse(visibleTexts().contains(activity.getString(R.string.task_list_refresh_failed)))
        shownText(activity.getString(R.string.task_detail_retry)).performClick()
        assertEquals(1, retries)

        render(TaskDataState(groupId = "g1", cacheLoaded = true, listLoaded = true, listReads = 1, connection = Connection.LIVE))
        assertTrue(visibleTexts().contains(activity.getString(R.string.task_list_empty)))
        assertFalse(visibleTexts().contains(activity.getString(R.string.task_detail_retry)))
    }

    @Test fun `archive hides the card until the host answers, once, and brings it back on failure`() {
        val tasks = listOf(
            TaskSummary("done", "Finished", TaskStatusBucket.DONE, updatedAt = 2, archiveAllowed = true),
            TaskSummary("busy", "Running", TaskStatusBucket.IN_PROGRESS, updatedAt = 1, archiveAllowed = false),
        )
        render(loaded(tasks))
        val archive = activity.getString(R.string.task_action_archive)
        fun actionOn(id: String) = cardView(id).createAccessibilityNodeInfo().actionList.firstOrNull { it.label == archive }
        assertNull(actionOn("busy"))
        val action = assertNotNullAndGet(actionOn("done"))
        val card = cardView("done")
        card.performAccessibilityAction(action.id, null)
        card.performAccessibilityAction(action.id, null)
        settle()
        assertEquals(listOf("done"), archived)
        assertTrue(cards().none { it.task.id == "done" })
        // A slow answer does not bring the card back early.
        ShadowLooper.idleMainLooper(10, java.util.concurrent.TimeUnit.SECONDS)
        settle()
        assertTrue(cards().none { it.task.id == "done" })

        // Refused or conflicted: the host answers without archiving, and the card returns.
        view.archiveFinished("done")
        settle()
        assertTrue(cards().any { it.task.id == "done" })

        // Archived: the snapshot has dropped it before the answer, so it does not flash back.
        cardView("done").performAccessibilityAction(action.id, null)
        settle()
        render(loaded(tasks.map { if (it.id == "done") it.copy(bucket = TaskStatusBucket.ARCHIVED) else it }, reads = 2))
        view.archiveFinished("done")
        settle()
        assertTrue(cards().none { it.task.id == "done" })
        assertEquals(listOf("done", "done"), archived)
    }

    private fun <T> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    private companion object {
        val LABELS = listOf(TaskLabel("work", "Work", "blue"), TaskLabel("home", "Home", "green"))
    }
}
