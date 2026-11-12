package surf.comma.android.chat.render

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import java.util.concurrent.TimeUnit

/**
 * Rows stay drawn when a commit moves them, and what the list reads from them stays theirs. A
 * reconnect's snapshot can drop older rows from the window in the same commit that brings a reply
 * or a sent message: until the next layout, the views on screen still sit at their old positions,
 * and a row's own state (the reply's fade, the send flight hiding its row) must not land on
 * whichever row was laid out at its new position, nor may a row's place be read from that row.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class TimelineRowVisibilityTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
        timeline.setComposerInset((80 * density).toInt())
        settle()
    }

    private fun message(id: Long, turn: String, role: ChatRole, text: String) =
        ChatMessage(id = id, conversationId = "c", turnId = turn, role = role, text = text, createdAt = id)

    private val history = (1..12).flatMap {
        listOf(message(it * 10L, "t$it", ChatRole.USER, "question $it"), message(it * 10L + 1, "t$it", ChatRole.AGENT, "answer $it"))
    }
    private val sent = message(990, "t-new", ChatRole.USER, "a new question")
    private val reply = message(991, "t-new", ChatRole.AGENT, "a reply that arrived whole")

    /** Every row object is new, as in a snapshot; ids stay the same. */
    private fun snapshot(rows: List<ChatMessage>) = rows.map { it.copy() }

    private fun prepare(rows: List<ChatMessage>) = runBlocking {
        MessageLayoutPrecomputer(bubbles = true).prepare(rows, viewportWidthPx = timeline.width, density = density,
            fontScale = 1f, darkTheme = false)
    }

    private fun submit(rows: List<ChatMessage>, onCommitted: () -> Unit = {}) {
        timeline.submitPrepared(prepare(rows), onCommitted)
        settle()
    }

    /** Lets the list diff, lay out and finish its reveals and glides. */
    private fun settle() = repeat(150) {
        ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
    }

    private fun rowOf(child: View): Long = timeline.getChildItemId(child)

    /** Every laid-out row shows its own message, and shows it whole. */
    private fun assertEveryRowDrawn(shown: List<ChatMessage>) {
        val ids = shown.map { it.id }.toSet()
        assertTrue("no rows laid out", timeline.childCount > 0)
        for (index in 0 until timeline.childCount) {
            val child = timeline.getChildAt(index)
            assertTrue("row ${rowOf(child)} is not one of the list's", rowOf(child) in ids)
            assertEquals("row ${rowOf(child)} is not drawn", 1f, child.alpha)
            assertTrue("row ${rowOf(child)} has no height", child.height > 0)
        }
    }

    /** Away by two screens and back, so rows come back from the view cache without a new bind. */
    private fun scrollAwayAndBack() {
        timeline.scrollBy(0, -timeline.height * 2)
        settle()
        timeline.scrollBy(0, timeline.height * 2)
        settle()
    }

    @Test fun `a reply landing in a snapshot that drops older rows leaves every row drawn`() {
        submit(history)
        submit(history + sent)
        val next = snapshot(history.drop(2) + sent) + reply
        submit(next)
        assertEveryRowDrawn(next)
        scrollAwayAndBack()
        assertEveryRowDrawn(next)
    }

    @Test fun `a sent row hidden for its flight in a commit that drops older rows hides only itself`() {
        submit(history)
        val next = snapshot(history.drop(2)) + sent
        // The send flight hides its rows from the commit callback, before the list lays them out.
        submit(next) { timeline.setHiddenRows(setOf(sent.id)) }
        timeline.setHiddenRows(emptySet())
        settle()
        assertEveryRowDrawn(next)
        scrollAwayAndBack()
        assertEveryRowDrawn(next)
    }

    /** What the list reads from the rows on screen: the first row, the last row's bottom, the fade below it. */
    private fun readings() = Triple(timeline.visibleAnchor(), timeline.bottomOffsetPx(), timeline.bottomOverflowPx())

    @Test fun `before a commit that removes the first visible row is laid out, the anchor is the next kept visible row`() {
        submit(history)
        val visibleIds = (0 until timeline.childCount).map { rowOf(timeline.getChildAt(it)) }
            .filter { timeline.messageTopOnScreen(it) != null }
            .sortedBy { timeline.messageTopOnScreen(it) }
        assertTrue("need two visible rows", visibleIds.size >= 2)
        val removedId = visibleIds[0]
        val nextId = visibleIds[1]
        val nextTop = timeline.messageTopOnScreen(nextId)!!
        assertEquals(removedId, timeline.visibleAnchor()!!.messageId)
        var committed = false
        submit(snapshot(history.filterNot { it.id == removedId })) {
            committed = true
            val anchor = timeline.visibleAnchor()!!
            assertTrue("anchor ${anchor.messageId} is no longer in the list", timeline.positionOf(anchor.messageId) >= 0)
            assertEquals("the next visible row", nextId, anchor.messageId)
            assertEquals("the next row's screen position before layout", nextTop, anchor.topPx)
        }
        assertTrue("commit callback did not run", committed)
    }

    @Test fun `before a commit that drops older rows is laid out, what the list reads from the screen is unchanged`() {
        submit(history)
        // The last row hangs below its boundary by half its height, so there is a fade to read.
        timeline.scrollBy(0, -timeline.viewForRow(history.last().id)!!.height / 2)
        settle()
        val before = readings()
        assertTrue("nothing to read: $before", before.first != null && before.second != null && before.third > 0)
        var atCommit: Triple<ChatTimelineView.VisibleAnchor?, Int?, Int>? = null
        submit(snapshot(history.drop(2))) { atCommit = readings() }
        // Nothing has moved on screen yet, so nothing read from the screen has changed.
        assertEquals("the first row on screen", before.first, atCommit?.first)
        assertEquals("the last row's bottom", before.second, atCommit?.second)
        assertEquals("the fade below the last row", before.third, atCommit?.third)
    }
}
