package surf.comma.android.tasks.ui

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskListRow
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.coreSections

/** What a card and the detail's status line say, on a narrow screen with large text. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-w320dp-h640dp-xhdpi", fontScale = 1.3f)
class TaskCardContentTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val theme = TaskTheme(activity)
    private val now = 1_759_650_000_000L // 2025-10-05, mid-day UTC
    private val strings = TaskStrings(activity) { now }
    private val preparer = TaskRowPreparer(theme, strings)
    private val width = activity.resources.displayMetrics.widthPixels
    private val labels = listOf(
        TaskLabel("a", "一个相当长的标签名字", "blue"),
        TaskLabel("b", "Research", "green"),
        TaskLabel("c", "Ops", "red"),
    )

    private fun card(task: TaskSummary): PreparedTaskRow.Card =
        preparer.prepare(listOf(TaskListRow.Card(task)), labels, width).single() as PreparedTaskRow.Card

    private fun text(block: TextBlock?) = block?.layout?.text?.toString()

    @Test fun `a card adds only what the section header does not already say`() {
        val done = card(TaskSummary("1", "Done task", TaskStatusBucket.DONE, updatedAt = now - 3_600_000))
        assertNull(done.status)
        assertTrue(done.contentDescription.contains(activity.getString(R.string.task_status_done)))

        val failed = card(TaskSummary("2", "Broke", TaskStatusBucket.CANCELLED, updatedAt = now, failed = true))
        assertEquals(activity.getString(R.string.task_status_failed), text(failed.status))
        assertFalse(failed.contentDescription.contains(activity.getString(R.string.task_status_cancelled)))

        val running = card(TaskSummary("3", "Busy", TaskStatusBucket.IN_PROGRESS, progress = "  Reading the inbox ", updatedAt = now))
        assertEquals("Reading the inbox", text(running.status))
        assertTrue(running.contentDescription.contains(activity.getString(R.string.task_status_in_progress)))

        // Running with nothing to report: the turning glyph and the header carry it.
        assertNull(card(TaskSummary("4", "Quiet", TaskStatusBucket.IN_PROGRESS, progress = " ")).status)
    }

    @Test fun `the updated time is never made up and is precise when recent`() {
        val unknown = card(TaskSummary("1", "No time", TaskStatusBucket.DONE))
        assertNull(unknown.footer)
        assertFalse(unknown.contentDescription.contains(activity.getString(R.string.task_updated_recently)))

        val today = text(card(TaskSummary("2", "Today", TaskStatusBucket.DONE, updatedAt = now - 60_000)).footer)!!
        assertTrue(today, today.contains(":"))
        val earlier = text(card(TaskSummary("3", "Earlier", TaskStatusBucket.DONE, updatedAt = now - 40L * 86_400_000)).footer)!!
        assertFalse(earlier, earlier.contains(":"))
        // Seconds are accepted as well as milliseconds.
        assertEquals(today, text(card(TaskSummary("4", "Today", TaskStatusBucket.DONE, updatedAt = (now - 60_000) / 1000)).footer))
    }

    @Test fun `long titles, many labels and no extras stack without overlapping on a narrow screen`() {
        val long = card(TaskSummary("1", "A rather long task title that keeps going ".repeat(6), TaskStatusBucket.CANCELLED, failed = true, labelIds = listOf("a", "b", "c"),
            updatedAt = now))
        // Two lines at most (Robolectric does not wrap text, so the cap is what can be checked here).
        assertTrue(long.title.layout.lineCount <= 2)
        val status = long.status!!
        assertTrue(long.statusTop >= theme.dpInt(12f) + long.title.heightPx)
        val pillsBottom = long.pills.maxOf { it.top + it.height }
        assertTrue(long.pills.minOf { it.top } >= long.statusTop + status.heightPx)
        assertTrue(long.footerTop >= pillsBottom)
        assertTrue(long.cardHeightPx >= long.footerTop + long.footer!!.heightPx)
        // Every pill fits inside the card.
        val metrics = preparer.metrics
        assertTrue(long.pills.all { it.left + it.width <= width - metrics.gutter * 2 - metrics.pad })

        val bare = card(TaskSummary("2", "", TaskStatusBucket.of(null)))
        assertEquals(activity.getString(R.string.task_untitled), text(bare.title))
        assertNull(bare.status)
        assertNull(bare.footer)
        assertTrue(bare.pills.isEmpty())
        // An unknown status still reads as something, and the card is title plus padding.
        assertTrue(bare.contentDescription.contains(activity.getString(R.string.task_status_in_progress)))
        assertEquals(theme.dpInt(12f) * 2 + bare.title.heightPx, bare.cardHeightPx)

        val view = TaskCardView(activity, theme, metrics)
        view.bind(long)
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        assertEquals(long.heightPx, view.measuredHeight)
    }

    @Test fun `the problem line and its retry share a narrow row`() {
        val list = TaskListView(activity)
        activity.setContentView(list)
        val tasks = listOf(TaskSummary("1", "One", TaskStatusBucket.DONE))
        list.submit(TaskSnapshot(tasks, emptyList()), coreSections(tasks))
        list.setProblem(activity.getString(R.string.task_list_refresh_failed))
        repeat(40) {
            list.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(activity.resources.displayMetrics.heightPixels, View.MeasureSpec.EXACTLY))
            list.layout(0, 0, list.measuredWidth, list.measuredHeight)
            ShadowLooper.idleMainLooper()
        }
        val texts = descendantsOf(list).filterIsInstance<TextView>().filter { it.isShown }
        val line = texts.single { it.text.toString() == activity.getString(R.string.task_list_refresh_failed) }
        val retry = texts.single { it.text.toString() == activity.getString(R.string.task_detail_retry) }
        val lineBox = IntArray(2).also(line::getLocationInWindow)
        val retryBox = IntArray(2).also(retry::getLocationInWindow)
        assertTrue(lineBox[0] + line.width <= retryBox[0])
        assertTrue(retryBox[0] + retry.width <= width)
        assertTrue(retry.height >= theme.dpInt(40f))
    }

    @Test fun `the detail's status line says failed and leaves out an unknown time`() {
        val info = TaskInfoRow.decode(TaskInfoRow.message(TaskSummary("1", "T", TaskStatusBucket.CANCELLED, failed = true), labels, strings).cardPayload)
        assertEquals(listOf(activity.getString(R.string.task_status_failed)), TaskInfoRow.parts(info, theme))
    }

    private fun descendantsOf(node: View): List<View> = listOf(node) +
        if (node is ViewGroup) (0 until node.childCount).flatMap { descendantsOf(node.getChildAt(it)) } else emptyList()
}
