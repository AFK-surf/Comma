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
import org.robolectric.shadows.ShadowChoreographer
import java.time.Duration
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaSource
import surf.comma.android.R
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class TimelinePinTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
    }

    private fun message(id: Long, turn: String, role: ChatRole, text: String, status: MessageStatus = MessageStatus.COMPLETED) =
        ChatMessage(id = id, conversationId = "c", turnId = turn, role = role, text = text, createdAt = id,
            status = status, retryable = status == MessageStatus.FAILED)

    private fun submit(rows: List<ChatMessage>) {
        val prepared = runBlocking {
            MessageLayoutPrecomputer().prepare(rows, viewportWidthPx = timeline.width, density = density,
                fontScale = 1f, darkTheme = false)
        }
        timeline.submitPrepared(prepared)
        settle()
    }

    /** Lets the list diff, lay out and finish any scroll animation. */
    private fun settle() = repeat(150) {
        ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
    }

    private fun positions(): List<Pair<Int, Int>> = (0 until timeline.childCount).map {
        val child = timeline.getChildAt(it)
        timeline.getChildAdapterPosition(child) to child.top
    }

    /** The list must already be where it belongs: an unrelated layout pass may not move it. */
    private fun assertSettled() {
        val before = positions()
        timeline.requestLayout()
        settle()
        assertEquals(before, positions())
    }

    // Each reply is taller than the screen, so the start of a turn is off screen when it is pinned.
    private val reply = (1..40).joinToString("\n\n") { "line $it" }
    private val history = (1..3).flatMap {
        listOf(message(it * 10L, "t$it", ChatRole.USER, "question $it"), message(it * 10L + 1, "t$it", ChatRole.AGENT, reply))
    }

    @Test fun `a new turn is pinned in the same pass, not on the next layout`() {
        submit(history)
        submit(history + message(99, "t4", ChatRole.USER, "not sent", MessageStatus.FAILED))
        assertSettled()
    }

    @Test fun `deleting an unsent last message leaves the list settled`() {
        submit(history)
        submit(history + message(99, "t4", ChatRole.USER, "not sent", MessageStatus.FAILED))
        submit(history)
        assertSettled()
    }

    @Test fun `a short turn rests at the bottom boundary`() {
        timeline.setPadding(0, 0, 0, (80 * density).toInt())
        submit(listOf(message(99, "t1", ChatRole.USER, "layout sample")))
        assertEquals(timeline.height - timeline.paddingBottom, timeline.viewForRow(99)!!.bottom)
    }

    private fun inset(dp: Int) {
        timeline.setComposerInset((dp * density).toInt())
        settle()
    }

    private fun assertGap(id: Long) {
        assertEquals("last visible row to capsule", activity.resources.getDimensionPixelSize(R.dimen.spacing_3xl),
            timeline.chatBottomPx - timeline.viewForRow(id)!!.bottom)
        assertEquals(0, timeline.bottomOffsetPx())
        assertSettled()
    }

    private fun image(id: Long) = message(id, "image-turn", ChatRole.USER, "").copy(
        cardKind = LiveRowKinds.ATTACHMENT,
        attachment = ChatAttachment(MediaAttachment("sample.png", "image/png", null,
            MediaSource.UploadedFile("/uploads/abcdefghijklmnopqrstuv-sample.png")), ImageDimensions(160, 960)),
    )

    @Test fun `keyboard text and tall images use the same bottom edge`() {
        inset(450)
        submit(listOf(message(1, "image-turn", ChatRole.USER, "layout sample"), image(2)))
        assertGap(2)
        assertTrue("oversized content stays scrollable", timeline.canScrollVertically(-1))
        for (bottom in listOf(520, 380, 150, 64, 380, 64)) {
            inset(bottom) // IME frames, attachment strip removal and multiline contraction.
            assertGap(2)
        }
    }

    @Test fun `image only and multiple images need not fit together`() {
        inset(380)
        submit(listOf(image(1)))
        assertGap(1)
        submit(listOf(image(1), image(2), image(3)))
        assertGap(3)
        assertTrue(timeline.canScrollVertically(-1))
        assertTrue("earlier images may be outside the viewport",
            timeline.viewForRow(1)?.bottom?.let { it <= timeline.paddingTop } ?: true)
    }

    @Test fun `typing and hidden action reservation add no visual gutter`() {
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(16))
        assertTrue(android.animation.ValueAnimator.areAnimatorsEnabled())
        inset(64)
        val question = message(1, "t", ChatRole.USER, "layout sample")
        val typing = message(2, "t", ChatRole.AGENT, "").copy(cardKind = TimelineBlockKinds.LIVE_STATUS)
        val reserve = message(3, "t", ChatRole.AGENT, "").copy(cardKind = LiveRowKinds.REPLY_ACTIONS_RESERVED)
        submit(listOf(question, typing, reserve))
        assertGap(2)
        inset(380)
        assertGap(2)
        val answer = message(2, "t", ChatRole.AGENT, "sample reply", MessageStatus.STREAMING)
        submit(listOf(question, answer, reserve))
        assertGap(2)
        val before = timeline.viewForRow(2)!!.bottom
        val completed = runBlocking {
            MessageLayoutPrecomputer().prepare(listOf(question, answer.copy(status = MessageStatus.COMPLETED),
                reserve.copy(id = 4, cardKind = LiveRowKinds.REPLY_ACTIONS)),
                viewportWidthPx = timeline.width, density = density, fontScale = 1f, darkTheme = false)
        }
        val frames = mutableListOf<Int>()
        val listener = android.view.ViewTreeObserver.OnPreDrawListener {
            timeline.viewForRow(2)?.let { frames += it.bottom }
            true
        }
        timeline.viewTreeObserver.addOnPreDrawListener(listener)
        timeline.submitPrepared(completed)
        repeat(150) {
            ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS)
            timeline.viewForRow(2)?.let { frames += it.bottom }
        }
        timeline.viewTreeObserver.removeOnPreDrawListener(listener)
        val after = timeline.viewForRow(2)!!.bottom
        assertTrue("buttons displace the reply gradually: $before -> $after; ${frames.distinct()}", frames.any { it in (after + 1) until before })
        assertTrue("no one-frame reservation jump", (listOf(before) + frames).zipWithNext().all {
            kotlin.math.abs(it.second - it.first) < (before - after) / 2
        })
        assertGap(4) // The button hit area's bottom, not the text or its glyph.
    }

    @Test fun `new turns and resizing do not pull a history reader to latest`() {
        inset(64)
        submit(history)
        timeline.revealRow(11)
        settle()
        assertFalse(timeline.isPinnedToEnd())
        val before = timeline.visibleAnchor()!!
        submit(history + message(99, "t4", ChatRole.USER, "another sample"))
        assertFalse(timeline.isPinnedToEnd())
        assertEquals(before, timeline.visibleAnchor())
        for (bottom in listOf(380, 520, 150, 64)) {
            inset(bottom)
            assertFalse(timeline.isPinnedToEnd())
            assertEquals(before, timeline.visibleAnchor())
        }
    }
}
