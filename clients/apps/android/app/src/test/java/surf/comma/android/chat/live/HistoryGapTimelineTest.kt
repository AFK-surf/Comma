package surf.comma.android.chat.live

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.conversation.CHAT
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.display
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.message
import java.util.concurrent.TimeUnit

/**
 * The chat list while a history gap fills (cached 1–100, newest 131–180, then 101–130): the rows a
 * reader is looking at keep their ids and screen position, and a reader following the newest
 * messages stays on them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class HistoryGapTimelineTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)
    private var mapped: LiveTimeline? = null

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
        timeline.setComposerInset((80 * density).toInt())
        settle()
    }

    /** The timeline the repository publishes for [ranges]: one gap entry between ranges. */
    private fun state(vararg ranges: LongRange) = ConversationState(conversationId = CHAT, timeline = buildList {
        ranges.forEachIndexed { index, range ->
            if (index > 0) add(TimelineEntry.Gap("gap:${range.first}"))
            range.forEach { seq ->
                val display = display(message(seq, text = "A message\nsecond line"))!!
                add(TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:msg_test_$seq", display))
            }
        }
    })

    private fun submit(state: ConversationState) {
        val next = mapConversation(state, replyActions = true)
        val prepared = runBlocking {
            MessageLayoutPrecomputer(bubbles = true).prepare(next.rows, viewportWidthPx = timeline.width, density = density,
                fontScale = 1f, darkTheme = false)
        }
        mapped = next
        timeline.submitPrepared(prepared)
        settle()
    }

    private fun rowOf(seq: Long): Long = mapped!!.entryRows.getValue(if (seq % 2 == 1L) "r:req-$seq" else "m:msg_test_$seq")

    private fun settle() = repeat(150) {
        ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
    }

    private fun read(seq: Long): ChatTimelineView.VisibleAnchor {
        timeline.revealRow(rowOf(seq))
        settle()
        assertFalse(timeline.isPinnedToEnd())
        return requireNotNull(timeline.visibleAnchor())
    }

    private fun assertStill(anchor: ChatTimelineView.VisibleAnchor) {
        assertEquals("the row being read moved or left", anchor, timeline.visibleAnchor())
        assertFalse("reading was turned into following", timeline.isPinnedToEnd())
    }

    @Test fun `reading old history, the newest messages and then the gap fill arrive without moving it`() {
        submit(state(1L..100L))
        val anchor = read(40)
        val ids = (1L..100L).map(::rowOf)
        submit(state(1L..100L, 131L..180L))
        assertStill(anchor)
        assertEquals("history rows kept their ids", ids, (1L..100L).map(::rowOf))
        val gap = mapped!!.rows.single { it.role == ChatRole.SYSTEM }
        assertEquals(mapped!!.rows.indexOfFirst { it.id == rowOf(100) } + 2, mapped!!.rows.indexOf(gap)) // After 100's actions row.
        submit(state(1L..180L))
        assertStill(anchor)
        assertEquals(ids, (1L..100L).map(::rowOf))
        assertTrue(mapped!!.rows.none { it.role == ChatRole.SYSTEM })
    }

    @Test fun `reading the newest messages, the gap filling above them does not move them`() {
        submit(state(1L..100L, 131L..180L))
        val anchor = read(140)
        submit(state(1L..180L))
        assertStill(anchor)
    }

    @Test fun `a failed fill keeps the reader where they are until a later one succeeds`() {
        submit(state(1L..100L))
        val anchor = read(60)
        submit(state(1L..100L, 131L..180L))
        // Failure publishes nothing new; a retry that finds one more message below still keeps the place.
        submit(state(1L..100L, 131L..181L))
        assertStill(anchor)
        submit(state(1L..181L))
        assertStill(anchor)
    }

    @Test fun `reading old history, a second gap opening below and both fills keep its place`() {
        submit(state(1L..100L, 131L..180L))
        val anchor = read(40)
        submit(state(1L..100L, 131L..180L, 231L..280L))
        assertStill(anchor)
        assertEquals(2, mapped!!.rows.count { it.role == ChatRole.SYSTEM })
        submit(state(1L..100L, 131L..280L))
        assertStill(anchor)
        submit(state(1L..280L))
        assertStill(anchor)
    }

    @Test fun `reading between two gaps, each fill around it keeps its place`() {
        submit(state(1L..100L, 131L..180L, 231L..280L))
        val anchor = read(150)
        val ids = (131L..180L).map(::rowOf)
        submit(state(1L..100L, 131L..280L)) // The newer gap, below the reader.
        assertStill(anchor)
        submit(state(1L..280L)) // The older gap, above the reader.
        assertStill(anchor)
        assertEquals(ids, (131L..180L).map(::rowOf))
    }

    @Test fun `following the newest messages, they stay in view through the gap and the fill`() {
        submit(state(1L..100L))
        assertTrue(timeline.isPinnedToEnd())
        submit(state(1L..100L, 131L..180L))
        assertTrue(timeline.isPinnedToEnd())
        assertNotNull("the newest message is on screen", timeline.messageTopOnScreen(rowOf(180)))
        assertEquals(0, timeline.bottomOffsetPx())
        submit(state(1L..180L))
        assertTrue(timeline.isPinnedToEnd())
        assertNotNull(timeline.messageTopOnScreen(rowOf(180)))
        assertEquals(0, timeline.bottomOffsetPx())
        // A second gap: the newest messages are still the ones in view.
        submit(state(1L..180L, 231L..280L))
        assertTrue(timeline.isPinnedToEnd())
        assertNotNull(timeline.messageTopOnScreen(rowOf(280)))
        assertEquals(0, timeline.bottomOffsetPx())
    }
}
