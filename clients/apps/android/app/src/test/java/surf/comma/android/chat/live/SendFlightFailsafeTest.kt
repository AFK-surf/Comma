package surf.comma.android.chat.live

import android.graphics.PointF
import android.graphics.RectF
import android.net.Uri
import android.os.Looper
import android.text.TextPaint
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowChoreographer
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.FlightTarget
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.ui.composer.ComposerSendSnapshot
import surf.comma.android.ui.theme.DesignMotion
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SendFlightFailsafeTest {
    @Test fun `the failsafe allows a normal flight and then some`() {
        val settle = SendFlightGeometry.settleMillis(DesignMotion.springFlight)
        // A near-critically damped spring with response 0.44 s settles in about half a second.
        assertTrue("settle $settle", settle in 350L..800L)
        assertEquals(((settle + 8 * 17L) * 1.5).toLong(), SendFlightGeometry.failsafeMillis(DesignMotion.springFlight, 6))
    }

    @Test fun `hidden rows come back even when the spring never finishes`() {
        // One frame per 16 ms of looper time; eager frames would run the clock past the checks.
        ShadowChoreographer.setPaused(true)
        try { stalledFlight() } finally { ShadowChoreographer.setPaused(false) }
    }

    private fun stalledFlight() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val root = FrameLayout(activity)
            val timeline = ChatTimelineView(activity)
            val flight = SendFlightView(activity, timeline)
            val target = object : View(activity), FlightTarget {
                override fun flightBounds(out: RectF): Boolean { out.set(0f, 0f, 300f, 300f); return true }
                override val flightCornerRadius = 0f
            }
            root.addView(timeline, FrameLayout.LayoutParams(1080, 2000))
            root.addView(target, FrameLayout.LayoutParams(300, 300))
            root.addView(flight, FrameLayout.LayoutParams(1080, 2000))
            activity.setContentView(root)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(100))
            flight.findTarget = { target }
            flight.stallSprings = true // A spring that stalls, is cancelled or never starts.

            val thumb = ComposerSendSnapshot.Attachment("a", Uri.EMPTY, RectF(40f, 1700f, 200f, 1860f), null)
            flight.hold(ComposerSendSnapshot("", null, TextPaint(), PointF(), RectF(0f, 1690f, 1080f, 1900f), 20f,
                listOf(thumb), fromVoice = false), "r:new")
            flight.accept("r:new")
            flight.onCommitted(listOf(row(11, "r:new")))
            assertEquals(setOf(11L), timeline.hiddenRows)
            assertTrue(flight.isFlying)

            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(flight.failsafeMillis - 50))
            assertEquals(setOf(11L), timeline.hiddenRows)
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(100))
            assertEquals(emptySet<Long>(), timeline.hiddenRows)
            assertFalse(flight.isFlying)
        }
    }

    private fun row(id: Long, turn: String) = PreparedChatMessage(
        message = ChatMessage(id = id, conversationId = "c", turnId = turn, role = ChatRole.USER, text = "",
            createdAt = 0L, cardKind = LiveRowKinds.ATTACHMENT),
        cacheKey = "$id", contents = emptyList(), blocks = emptyList(), bubbleWidthPx = 0, bubbleHeightPx = 0,
        bubbleTopPx = 0, cellHeightPx = 300, horizontalPaddingPx = 0, verticalPaddingPx = 0, sideMarginPx = 0,
        topMarginPx = 0, cornerRadiusPx = 0f, drawBubble = false, imageCornerRadiusPx = 0f, imageSources = emptyList(),
    )
}
