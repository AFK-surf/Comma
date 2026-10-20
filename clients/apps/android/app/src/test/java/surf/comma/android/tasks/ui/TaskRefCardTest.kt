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
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.live.TaskRefRow
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRendererRegistry
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.ui.theme.UiSansTypeface

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w360dp-h740dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TaskRefCardTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val theme = TaskTheme(activity)
    private val strings = TaskStrings(activity)
    private val width = activity.resources.displayMetrics.widthPixels
    private val cardLayout = TaskRefCardLayout(theme, activity.getString(R.string.chat_task_ref), UiSansTypeface)
    private val precomputer = MessageLayoutPrecomputer(cardHeights = cardLayout)
    private val updatedAt = 1_790_000_000_000L

    private fun refMessage(title: String?, status: String? = null, suffix: String = "", id: String = "task-1") = ChatMessage(
        id = 7, conversationId = "chat", role = ChatRole.AGENT, text = "", createdAt = 1,
        cardKind = LiveRowKinds.TASK_REF,
        cardPayload = LiveRowKinds.encode(LiveRowKinds.TaskRef(id, title, status, unavailable = false, suffix = suffix)),
    )

    private fun prepare(message: ChatMessage): PreparedChatMessage = runBlocking {
        precomputer.prepare(listOf(message), viewportWidthPx = width, density = activity.resources.displayMetrics.density,
            fontScale = 1f, darkTheme = false).single()
    }

    /** A row as the chat shows it, with the page's directory knowing [known]. */
    private fun row(message: ChatMessage, vararg known: TaskSummary): TaskRefRow {
        val states = MutableStateFlow(TaskDataState(groupId = "g", summaries = known.associateBy { it.id }))
        val directory = TaskRefDirectory(MutableStateFlow(Any()), states) { true }
        val host = FrameLayout(activity)
        directory.install(host)
        val prepared = prepare(message)
        val renderer = ChatCardRendererRegistry.forKind(LiveRowKinds.TASK_REF)!!
        val row = renderer.create(activity) as TaskRefRow
        renderer.bind(row, prepared)
        host.addView(row)
        activity.setContentView(host)
        val job = activity.lifecycleScope.launch { directory.run() }
        ShadowLooper.idleMainLooper()
        host.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        host.layout(0, 0, host.measuredWidth, host.measuredHeight)
        job.cancel()
        return row
    }

    @Test fun `a running task shows its turning glyph, title and latest progress`() {
        val task = TaskSummary("task-1", "Summarise today's Slack", TaskStatusBucket.IN_PROGRESS, progress = "Reading #general", updatedAt = updatedAt)
        val card = row(refMessage("Summarise today's Slack"), task).card
        assertEquals("Summarise today's Slack", card.titleText.toString())
        assertEquals("${theme.statusLabel(TaskStatusBucket.IN_PROGRESS)} · Reading #general", card.metaText.toString())
        assertTrue("turns while running", card.isSpinning)
        assertTrue(card.isClickable)
    }

    @Test fun `a finished task shows its status and when it was updated`() {
        val task = TaskSummary("task-1", "Summarise today's Slack", TaskStatusBucket.DONE, progress = "stale", updatedAt = updatedAt)
        val card = row(refMessage("Summarise today's Slack"), task).card
        assertEquals("Done · ${strings.updatedAt(updatedAt)}", card.metaText.toString())
        assertFalse(card.isSpinning)
        assertEquals(TaskStatusBucket.DONE, card.glyphBucket)
    }

    @Test fun `before the task is confirmed the card shows the message's own title and no state`() {
        val card = row(refMessage("From the message", status = "running")).card
        assertEquals("From the message", card.titleText.toString())
        assertEquals("the message's status may be stale", "", card.metaText.toString())
        assertFalse("an unconfirmed task does not turn", card.isSpinning)
        assertEquals("an unconfirmed task shows the neutral glyph, as the desktop does", null, card.glyphBucket)
        assertTrue(card.isClickable)
    }

    @Test fun `an unavailable reference is an inert card`() {
        val message = refMessage("x").copy(cardPayload = LiveRowKinds.encode(LiveRowKinds.TaskRef(null, "x", null, unavailable = true)))
        val card = row(message).card
        assertEquals(activity.getString(R.string.chat_task_unavailable), card.titleText.toString())
        assertFalse(card.isClickable)
    }

    @Test fun `the title takes two lines at most, and the card is laid out for it`() {
        val short = row(refMessage("Short title")).card
        val long = "Summarise what everyone talked about in Slack today, by channel, with anything waiting on me marked " +
            "and every thread where somebody asked me to decide something"
        val tall = row(refMessage(long)).card
        assertEquals(1, short.titleMaxLines)
        assertEquals(2, tall.titleMaxLines)
        assertEquals(cardLayout.metrics.heightPx(1), short.height)
        assertEquals(cardLayout.metrics.heightPx(2), tall.height)
    }

    @Test fun `the card is as wide as the reply's text`() {
        val row = row(refMessage("Title"))
        val side = prepare(refMessage("Title")).sideMarginPx
        assertEquals(side, row.card.left)
        assertEquals(width - side, row.card.right)
    }

    @Test fun `punctuation after the card stays with it, on its status line`() {
        val row = row(refMessage("Title", suffix = "。"))
        assertEquals("。", row.suffixText.toString())
        val suffix = (0 until row.childCount).map { row.getChildAt(it) }.single { it !== row.card }
        assertEquals("follows the card", row.card.right, suffix.left)
        assertTrue("on the card's last line, not a line of its own", suffix.bottom <= row.card.bottom)
        assertTrue(suffix.top >= row.card.top)
    }
}
