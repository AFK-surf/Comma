package surf.comma.android.tasks.ui

import android.os.SystemClock
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.render.ChatCardRendererRegistry
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.message
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.pages.taskDetailRetryable
import surf.comma.android.tasks.pages.taskDetailRows

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TaskDetailPageTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val theme = TaskTheme(activity)
    private val strings = TaskStrings(activity)
    private val density = activity.resources.displayMetrics.density
    private val precomputer = MessageLayoutPrecomputer(sideMarginDp = 16f)

    private fun layOut(view: View, width: Int = 1080, height: Int? = null) {
        view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            height?.let { View.MeasureSpec.makeMeasureSpec(it, View.MeasureSpec.EXACTLY) }
                ?: View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }

    private fun prepare(vararg rows: ChatMessage): List<PreparedChatMessage> = runBlocking {
        precomputer.prepare(rows.toList(), viewportWidthPx = 1080, density = density, fontScale = 1f, darkTheme = false)
    }

    // --- The bar ---------------------------------------------------------------------------------

    @Test fun `the title sits in the bar beside back, on one line that ellipsizes`() {
        val page = TaskDetailView(activity)
        val long = "Summarise what everyone talked about in Slack today, grouped by channel, with anything waiting on me marked, and every thread where I was asked to decide"
        page.setTitle(long)
        layOut(page, height = 2000)

        assertEquals(long, page.title.text.toString())
        assertEquals(1, page.title.maxLines)
        assertEquals(TextUtils.TruncateAt.END, page.title.ellipsize)
        val bar = page.title.parent as View
        assertSame(bar, page.getChildAt(0))
        assertTrue("title is not in the bar's height", page.title.bottom <= bar.height)
        assertTrue("one line", page.title.layout.lineCount == 1)
        assertTrue("cut short", page.title.layout.getEllipsisCount(0) > 0)
        // Same bar as the settings pages.
        assertEquals((56 * density).toInt(), bar.height)
    }

    @Test fun `the hairline under the bar shows only once the list has scrolled`() {
        val page = TaskDetailView(activity)
        assertEquals(0f, page.hairline.alpha)
        page.setScrolled(true)
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertEquals(1f, page.hairline.alpha)
        page.setScrolled(false)
        ShadowLooper.idleMainLooper(1, java.util.concurrent.TimeUnit.SECONDS)
        assertEquals(0f, page.hairline.alpha)
    }

    @Test fun `a failed read offers a retry, a missing task does not`() {
        val page = TaskDetailView(activity)
        var retried = 0
        page.onRetry = { retried++ }
        page.setNotice("Couldn't load messages.", retry = taskDetailRetryable(ConversationProblem.NETWORK))
        assertTrue(page.retry.isVisible)
        page.retry.performClick()
        assertEquals(1, retried)

        page.setNotice("This task doesn't exist", retry = taskDetailRetryable(ConversationProblem.NOT_FOUND))
        assertFalse(page.retry.isVisible)
        page.setNotice(null)
        assertFalse(page.retry.isVisible)
        assertTrue(taskDetailRetryable(ConversationProblem.SERVER))
        assertFalse(taskDetailRetryable(null))
    }

    // --- The status line -------------------------------------------------------------------------

    private val labels = listOf(TaskLabel("l1", "Work", "blue"), TaskLabel("l2", "Research", "indigo"))
    private val updatedAt = 1_790_000_000_000L

    private fun infoRow(task: TaskSummary): TaskInfoRowView {
        val prepared = prepare(TaskInfoRow.message(task, labels, strings)).single()
        val renderer = ChatCardRendererRegistry.forKind(TaskInfoRow.KIND)!!
        return (renderer.create(activity) as TaskInfoRowView).also { renderer.bind(it, prepared); layOut(it) }
    }

    @Test fun `with no messages the status line stays under the title`() {
        val task = TaskSummary("t1", "Open WeChat", TaskStatusBucket.DONE, updatedAt = updatedAt)
        val rows = prepare(TaskInfoRow.message(task, labels, strings))
        fun rowTop(stacksFromEnd: Boolean): Int {
            val timeline = surf.comma.android.chat.render.ChatTimelineView(activity)
            timeline.stacksFromEnd = stacksFromEnd
            timeline.submitPrepared(rows)
            ShadowLooper.idleMainLooper()
            layOut(timeline, height = 2000)
            ShadowLooper.idleMainLooper()
            layOut(timeline, height = 2000)
            return timeline.getChildAt(0).top
        }
        assertEquals("a task page with no messages starts at the top", 0, rowTop(stacksFromEnd = false))
        assertTrue("a chat's short list rests on the bottom", rowTop(stacksFromEnd = true) > 1000)
    }

    @Test fun `the status line reads status, labels, then the updated time`() {
        val row = infoRow(TaskSummary("t1", "Title", TaskStatusBucket.DONE, labelIds = listOf("l1", "l2"), updatedAt = updatedAt))
        assertEquals(listOf("Done", "Work", "Research", strings.updatedAt(updatedAt)), row.shownParts)

        val bare = infoRow(TaskSummary("t1", "Title", TaskStatusBucket.IN_PROGRESS, updatedAt = updatedAt))
        assertEquals(listOf(theme.statusLabel(surf.comma.android.tasks.TaskStatusBucket.IN_PROGRESS),
            strings.updatedAt(updatedAt)), bare.shownParts)
    }

    @Test fun `the status line stays one line and cuts the labels, never the time`() {
        val many = (1..12).map { TaskLabel("l$it", "Label number $it", "pink") }
        val task = TaskSummary("t1", "Title", TaskStatusBucket.DONE, labelIds = many.map { it.id }, updatedAt = updatedAt)
        val prepared = prepare(TaskInfoRow.message(task, many, strings)).single()
        val row = TaskInfoRowView(activity).also { it.bind(prepared); layOut(it) }
        val texts = (0 until row.childCount).map { row.getChildAt(it) }.filterIsInstance<TextView>()
        texts.forEach { assertEquals(1, it.layout.lineCount) }
        assertTrue("labels are cut", texts[0].layout.getEllipsisCount(0) > 0)
        assertEquals("the time is whole", 0, texts[1].layout.getEllipsisCount(0))
        assertTrue(texts[1].right <= row.width)
        // One small line plus the gap under it: the row never grows with labels.
        assertEquals(prepared.cellHeightPx, row.height)
    }

    // --- The brief -------------------------------------------------------------------------------

    private val longBrief = (1..10).joinToString("\n\n") {
        "Step $it: search with `SLACK_SEARCH_MESSAGES` between after: and before:, then summarise every channel."
    }

    private fun briefRow(text: String, expanded: Boolean = false) = ChatMessage(
        id = 42, conversationId = "t1", role = ChatRole.AGENT, text = text, createdAt = 1,
        cardKind = TimelineBlockKinds.TASK_BRIEF,
        cardPayload = TimelineBlockKinds.TASK_BRIEF_EXPANDED.takeIf { expanded },
    )

    @Test fun `the brief is found from the data and folded, and the results follow it`() {
        val brief = display(message(1, actor = "agent", text = longBrief) {
            put("metadata", org.json.JSONObject().put("message_type", "task_command"))
        })!!
        // Reads like instructions, but nothing in the data says it is the brief.
        val result = display(message(2, actor = "agent", text = "Time window: today. Output: the summary."))!!
        val entries = listOf(TimelineEntry.Message("m1", brief), TimelineEntry.Message("m2", result))
        val mapped = mapConversation(ConversationState(conversationId = "t1", timeline = entries))
        val task = TaskSummary("t1", "Title", TaskStatusBucket.DONE, updatedAt = updatedAt)

        val rows = taskDetailRows(mapped, entries, task, labels, strings, expanded = emptySet())
        assertEquals(listOf(TaskInfoRow.KIND, TimelineBlockKinds.TASK_BRIEF, null), rows.map { it.cardKind })
        assertNull("closed by default", rows[1].cardPayload)

        val open = taskDetailRows(mapped, entries, task, labels, strings, expanded = setOf(rows[1].id))
        assertEquals(TimelineBlockKinds.TASK_BRIEF_EXPANDED, open[1].cardPayload)

        // A meeting task: a note first, then its instructions from the user's side, folded and set as page text.
        val note = display(message(1, actor = "agent", text = "Meeting detected. Waiting for recording.") {
            put("metadata", org.json.JSONObject().put("message_type", "meeting_context"))
        })!!
        val recording = display(message(2, actor = "user", text = longBrief) {
            put("metadata", org.json.JSONObject().put("message_type", "meeting_recording"))
        })!!
        val meetingEntries = listOf(TimelineEntry.Message("n1", note), TimelineEntry.Message("n2", recording))
        val meetingRows = taskDetailRows(mapConversation(ConversationState(conversationId = "t1", timeline = meetingEntries)),
            meetingEntries, null, labels, strings, emptySet())
        assertEquals(listOf(null, TimelineBlockKinds.TASK_BRIEF), meetingRows.map { it.cardKind })
        assertEquals(ChatRole.AGENT, meetingRows[1].role)

        // Without a known task there is no status line yet; the brief is still folded.
        assertEquals(listOf(TimelineBlockKinds.TASK_BRIEF, null),
            taskDetailRows(mapped, entries, null, labels, strings, emptySet()).map { it.cardKind })
    }

    @Test fun `a closed brief shows its first lines and opens to its full height`() {
        val closed = prepare(briefRow(longBrief)).single()
        val brief = closed.brief!!
        assertTrue(brief.expandable)
        assertFalse(brief.expanded)
        assertEquals(brief.collapsedCellHeightPx, closed.cellHeightPx)
        assertTrue(brief.collapsedCellHeightPx < brief.expandedCellHeightPx)
        // Title, three body lines, footer: well under the full text.
        assertTrue(closed.cellHeightPx < 200 * density)
        assertTrue(closed.cellHeightPx * 2 < brief.expandedCellHeightPx)

        val open = prepare(briefRow(longBrief, expanded = true)).single()
        assertTrue(open.brief!!.expanded)
        assertEquals(open.brief!!.expandedCellHeightPx, open.cellHeightPx)
        assertEquals(brief.expandedCellHeightPx, open.cellHeightPx)
    }

    @Test fun `a short brief shows whole, with nothing to open`() {
        val short = prepare(briefRow("Summarise today's Slack.")).single()
        assertFalse(short.brief!!.expandable)
        assertNull(short.brief!!.footer)
        assertEquals(short.brief!!.expandedCellHeightPx, short.cellHeightPx)
    }

    private fun tap(view: View, y: Float) {
        val now = SystemClock.uptimeMillis()
        view.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, view.width / 2f, y, 0))
        view.dispatchTouchEvent(MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, view.width / 2f, y, 0))
    }

    @Test fun `tapping a closed brief opens it, and an open one closes from its footer only`() {
        val cell = ChatMessageCell(activity)
        val toggled = ArrayList<Long>()
        cell.onToggleBrief = { toggled += it }
        cell.bind(prepare(briefRow(longBrief)).single())
        layOut(cell)
        tap(cell, cell.height / 2f)
        assertEquals(listOf(42L), toggled)
        // A swipe whose moves never arrived is not a tap.
        val now = SystemClock.uptimeMillis()
        cell.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, 100f, 20f, 0))
        cell.dispatchTouchEvent(MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, 100f, cell.height - 20f, 0))
        assertEquals(listOf(42L), toggled)

        val open = prepare(briefRow(longBrief, expanded = true)).single()
        cell.bind(open)
        layOut(cell)
        assertEquals(open.cellHeightPx, cell.height)
        tap(cell, cell.height / 2f)
        assertEquals("reading the open text does not close it", 1, toggled.size)
        tap(cell, cell.height - open.brief!!.bottomGapPx - open.verticalPaddingPx - 4f)
        assertEquals(listOf(42L, 42L), toggled)
    }
}
