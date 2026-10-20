package surf.comma.android.chat.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds

class TypingBubbleTest {
    private fun row(id: Long, role: ChatRole, cardKind: String? = null) = PreparedChatMessage(
        message = ChatMessage(id = id, conversationId = "c", turnId = "t1", role = role, text = "",
            createdAt = 0L, status = MessageStatus.COMPLETED, cardKind = cardKind),
        cacheKey = "$id", contents = emptyList(), blocks = emptyList(),
        bubbleWidthPx = 0, bubbleHeightPx = 0, bubbleTopPx = 0, cellHeightPx = 10, horizontalPaddingPx = 0,
        verticalPaddingPx = 0, sideMarginPx = 48, topMarginPx = 84, cornerRadiusPx = 0f, drawBubble = false,
        imageCornerRadiusPx = 0f, imageSources = emptyList(),
    )

    private val user = row(1, ChatRole.USER)
    private val typing = row(2, ChatRole.AGENT, TimelineBlockKinds.LIVE_STATUS)
    private val reply = row(3, ChatRole.AGENT)

    @Test fun `the dots brighten one after another and rest dim`() {
        fun peakTime(index: Int) = (0 until TypingBubble.DOT_PERIOD_MS).maxByOrNull { TypingBubble.dotBrightness(it, index) }!!
        val peaks = (0 until TypingBubble.DOT_COUNT).map(::peakTime)
        assertEquals(listOf(TypingBubble.DOT_STAGGER_MS, TypingBubble.DOT_STAGGER_MS), peaks.zipWithNext { a, b -> b - a })
        for (index in 0 until TypingBubble.DOT_COUNT) {
            assertEquals(1f, TypingBubble.dotBrightness(peaks[index], index), 0.001f)
            assertEquals(TypingBubble.DOT_DIM_BRIGHTNESS, TypingBubble.dotBrightness(index * TypingBubble.DOT_STAGGER_MS, index), 0.001f)
            for (time in 0 until TypingBubble.DOT_PERIOD_MS) {
                val value = TypingBubble.dotBrightness(time, index)
                assertTrue(value in TypingBubble.DOT_DIM_BRIGHTNESS..1f)
            }
        }
    }

    @Test fun `the loop repeats without a jump`() {
        for (index in 0 until TypingBubble.DOT_COUNT) {
            assertEquals(TypingBubble.dotBrightness(5, index), TypingBubble.dotBrightness(5 + TypingBubble.DOT_PERIOD_MS, index), 0f)
            for (time in 0 until TypingBubble.DOT_PERIOD_MS * 2) {
                val step = TypingBubble.dotBrightness(time + 1, index) - TypingBubble.dotBrightness(time, index)
                assertTrue("dot $index jumps at $time", kotlin.math.abs(step) < 0.01f)
            }
        }
        assertEquals(TypingBubble.breathScale(7), TypingBubble.breathScale(7 + TypingBubble.DOT_PERIOD_MS * 2), 0f)
    }

    @Test fun `the bubble breathes by a small fraction of its size`() {
        val scales = (0 until TypingBubble.DOT_PERIOD_MS * 2).map(TypingBubble::breathScale)
        assertEquals(1f + TypingBubble.BREATH_AMPLITUDE, scales.max(), 0.0005f)
        assertEquals(1f - TypingBubble.BREATH_AMPLITUDE, scales.min(), 0.0005f)
        assertTrue(TypingBubble.BREATH_AMPLITUDE <= 0.03f)
    }

    @Test fun `the loop runs only for a row on screen in a visible window`() {
        assertTrue(TypingBubble.keepsAnimating(true, true, visibleTop = -300, visibleHeight = 2000, cellHeight = 200))
        assertFalse(TypingBubble.keepsAnimating(attached = false, windowVisible = true, -300, 2000, 200))
        // The app is in the background.
        assertFalse(TypingBubble.keepsAnimating(attached = true, windowVisible = false, -300, 2000, 200))
        // Scrolled above the list, below it, and not yet placed.
        assertFalse(TypingBubble.keepsAnimating(true, true, visibleTop = 200, visibleHeight = 2000, cellHeight = 200))
        assertFalse(TypingBubble.keepsAnimating(true, true, visibleTop = -2000, visibleHeight = 2000, cellHeight = 200))
        assertFalse(TypingBubble.keepsAnimating(true, true, visibleTop = 0, visibleHeight = 0, cellHeight = 200))
    }

    @Test fun `the bubble pops in when it is added, not when it is found`() {
        assertTrue(typingEnters(listOf(user), listOf(user, typing)))
        assertFalse(typingEnters(emptyList(), listOf(user, typing)))
        assertFalse(typingEnters(listOf(user, typing), listOf(user, typing)))
        assertFalse(typingEnters(listOf(user), listOf(user, reply)))
    }

    @Test fun `the bubble fades where it stood when the reply takes its place`() {
        val exit = typingExit(listOf(user, typing), listOf(user, reply))
        assertNotNull(exit)
        assertEquals(user.message.id, exit!!.anchorRowId)
        assertEquals(48, exit.sideMarginPx)
        assertEquals(84, exit.topMarginPx)
        // The agent stopped without replying.
        assertNotNull(typingExit(listOf(user, typing), listOf(user)))
        assertNull(typingExit(listOf(typing), listOf(reply))!!.anchorRowId)
    }

    @Test fun `no fade while waiting continues or when the list is replaced`() {
        assertNull(typingExit(listOf(user, typing), listOf(user, typing)))
        assertNull(typingExit(listOf(user), listOf(user, reply)))
        assertNull(typingExit(listOf(user, typing), emptyList()))
        assertNull(typingExit(listOf(user, typing), listOf(row(9, ChatRole.USER), reply)))
    }
}
