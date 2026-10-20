package surf.comma.android.chat.render

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import java.util.concurrent.TimeUnit

/** The chat list with bubbles and tails: following the newest reply, reading history, paging. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class BubbleTimelineTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)
    private val precomputer = MessageLayoutPrecomputer(bubbles = true)
    private var shown: List<PreparedChatMessage> = emptyList()

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
        timeline.setComposerInset((80 * density).toInt())
        settle()
    }

    private fun message(id: Long, turn: String, role: ChatRole, text: String, cardKind: String? = null) =
        ChatMessage(id = id, conversationId = "c", turnId = turn, role = role, text = text, createdAt = id, cardKind = cardKind)

    private fun submit(rows: List<ChatMessage>) {
        shown = runBlocking {
            precomputer.prepareChanged(shown, rows, viewportWidthPx = timeline.width, density = density,
                fontScale = 1f, darkTheme = false)
        }
        timeline.submitPrepared(shown)
        settle()
    }

    private fun settle() = repeat(150) {
        ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
    }

    private fun assertRestsAboveComposer(id: Long) {
        assertTrue(timeline.isPinnedToEnd())
        assertEquals("the last row, tail included, to the capsule",
            activity.resources.getDimensionPixelSize(R.dimen.spacing_3xl),
            timeline.chatBottomPx - timeline.viewForRow(id)!!.bottom)
        assertEquals(0, timeline.bottomOffsetPx())
    }

    private val paragraphs = (1..12).joinToString("\n\n") { "Paragraph $it of a long answer, with enough words to wrap." }
    private fun history(turns: Int) = (1..turns).flatMap {
        listOf(message(it * 10L, "t$it", ChatRole.USER, "question $it"), message(it * 10L + 1, "t$it", ChatRole.AGENT, paragraphs))
    }

    @Test fun `following the bottom, each message of a reply lands whole and stays in view`() {
        val past = history(3)
        val question = message(100, "t9", ChatRole.USER, "and then?")
        val typing = message(101, "t9", ChatRole.AGENT, "", TimelineBlockKinds.LIVE_STATUS)
        val reserved = message(102, "t9", ChatRole.AGENT, "", LiveRowKinds.REPLY_ACTIONS_RESERVED)
        submit(past + question + typing + reserved)
        assertTrue(timeline.isPinnedToEnd())
        val first = message(110, "t9", ChatRole.AGENT, paragraphs)
        submit(past + question + first + typing + reserved)
        assertTrue(timeline.isPinnedToEnd())
        assertEquals("no tail while the reply goes on", 0, shown.single { it.message.id == 110L }.tailPx)
        val second = message(111, "t9", ChatRole.AGENT, "Short closing line.")
        val actions = message(103, "t9", ChatRole.AGENT, "", LiveRowKinds.REPLY_ACTIONS).copy(cardPayload = "t9")
        submit(past + question + first + second + actions)
        assertEquals(0, shown.single { it.message.id == 110L }.tailPx)
        assertTrue("the last message ends the run", shown.single { it.message.id == 111L }.tailPx > 0)
        assertRestsAboveComposer(103)
    }

    @Test fun `a short exchange rests with its tail above the composer`() {
        submit(listOf(message(1, "t", ChatRole.USER, "hi"), message(2, "t", ChatRole.AGENT, "Hello!")))
        assertTrue(shown.last().tailPx > 0)
        assertRestsAboveComposer(2)
    }

    @Test fun `a reply arriving while reading history does not move the reader`() {
        submit(history(4))
        timeline.revealRow(21)
        settle()
        assertFalse(timeline.isPinnedToEnd())
        val before = timeline.visibleAnchor()!!
        submit(history(4) + message(100, "t9", ChatRole.USER, "another") +
            message(101, "t9", ChatRole.AGENT, "", TimelineBlockKinds.LIVE_STATUS))
        assertEquals(before, timeline.visibleAnchor())
        submit(history(4) + message(100, "t9", ChatRole.USER, "another") + message(110, "t9", ChatRole.AGENT, paragraphs))
        assertEquals(before, timeline.visibleAnchor())
        assertFalse(timeline.isPinnedToEnd())
    }

    @Test fun `older history paged in above keeps the row being read in place`() {
        val newer = (5..8).flatMap {
            listOf(message(it * 10L, "t$it", ChatRole.USER, "question $it"), message(it * 10L + 1, "t$it", ChatRole.AGENT, paragraphs))
        }
        submit(newer)
        timeline.revealRow(61)
        settle()
        val before = timeline.visibleAnchor()!!
        submit(history(4) + newer)
        assertEquals(before, timeline.visibleAnchor())
        assertFalse(timeline.isPinnedToEnd())
    }
}
