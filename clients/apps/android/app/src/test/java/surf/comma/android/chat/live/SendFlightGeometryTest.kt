package surf.comma.android.chat.live

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.PreparedChatMessage

class SendFlightGeometryTest {
    private val source = FlightBox(40f, 1_800f, 400f, 1_860f)
    private val target = FlightBox(600f, 700f, 1_000f, 790f)

    @Test fun `the text starts as the typed text grown by the bubble padding`() {
        val start = SendFlightGeometry.textSource(originX = 52f, originY = 1_810f, textWidth = 300f, textHeight = 44f,
            padH = 13f, padV = 10f)
        assertEquals(FlightBox(39f, 1_800f, 365f, 1_864f), start)
        // Width and height are the text's plus the padding on both sides: nothing is scaled.
        assertEquals(326f, start.width, 0f)
        assertEquals(64f, start.height, 0f)
    }

    @Test fun `a piece is drawn at its target plus what its springs have left`() {
        assertEquals(target, SendFlightGeometry.drawn(target, FloatArray(4)))
        val start = floatArrayOf(source.left - target.left, source.top - target.top,
            source.right - target.right, source.bottom - target.bottom)
        assertEquals(source, SendFlightGeometry.drawn(target, start))
    }

    @Test fun `the list carries a piece with its row`() {
        // The row scrolls or the keyboard moves it: the piece moves as much, its offset unchanged.
        val offset = floatArrayOf(-200f, 300f, -180f, 310f)
        val moved = FlightBox(target.left, target.top - 120f, target.right, target.bottom - 120f)
        assertEquals(SendFlightGeometry.drawn(target, offset).top - 120f, SendFlightGeometry.drawn(moved, offset).top, 0f)
    }

    @Test fun `an overshoot past the target is not clipped`() {
        val past = SendFlightGeometry.drawn(target, floatArrayOf(4f, -6f, 4f, -6f))
        assertEquals(target.top - 6f, past.top, 0f)
        assertEquals(target.left + 4f, past.left, 0f)
    }

    @Test fun `a piece below another leaves once the one above has passed its source`() {
        assertFalse(SendFlightGeometry.mayLeave(aboveBottom = 1_850f, gap = 18f, sourceTop = 1_760f))
        assertFalse(SendFlightGeometry.mayLeave(aboveBottom = 1_750f, gap = 18f, sourceTop = 1_760f))
        assertTrue(SendFlightGeometry.mayLeave(aboveBottom = 1_742f, gap = 18f, sourceTop = 1_760f))
    }

    @Test fun `the mask hides what would reach above the piece on top`() {
        assertEquals(target, SendFlightGeometry.masked(target, target.top - 10f))
        assertEquals(target.copy(top = 750f), SendFlightGeometry.masked(target, 750f))
        assertEquals(0f, SendFlightGeometry.masked(target, 2_000f).height, 0f)
    }

    private fun row(id: Long, turn: String, role: ChatRole = ChatRole.USER, cardKind: String? = null) =
        PreparedChatMessage(
            message = ChatMessage(id = id, conversationId = "c", turnId = turn, role = role, text = "",
                createdAt = 0L, cardKind = cardKind),
            cacheKey = "$id", contents = emptyList(), blocks = emptyList(), bubbleWidthPx = 0, bubbleHeightPx = 0,
            bubbleTopPx = 0, cellHeightPx = 0, horizontalPaddingPx = 0, verticalPaddingPx = 0, sideMarginPx = 0,
            topMarginPx = 0, cornerRadiusPx = 0f, drawBubble = true, imageCornerRadiusPx = 0f, imageSources = emptyList(),
        )

    private val earlier = listOf(row(1, "r:old"), row(2, "r:old", ChatRole.AGENT))

    @Test fun `text only flies into the text bubble`() {
        val rows = earlier + row(10, "r:new")
        val turn = SendFlightGeometry.turnRows("r:new", rows)
        assertEquals(listOf(FlightPiece(-1, 10)), SendFlightGeometry.pair(hasText = true, attachmentCount = 0, turn))
    }

    @Test fun `images only fly into the attachment rows in order`() {
        val rows = earlier + row(11, "r:new", cardKind = LiveRowKinds.ATTACHMENT) +
            row(12, "r:new", cardKind = LiveRowKinds.ATTACHMENT)
        val turn = SendFlightGeometry.turnRows("r:new", rows)
        assertEquals(listOf(FlightPiece(0, 11), FlightPiece(1, 12)),
            SendFlightGeometry.pair(hasText = false, attachmentCount = 2, turn))
    }

    @Test fun `images and text each find their own row`() {
        val rows = earlier + row(10, "r:new") + row(11, "r:new", cardKind = LiveRowKinds.ATTACHMENT) +
            row(12, "r:new", cardKind = LiveRowKinds.ATTACHMENT) + row(13, "r:new", ChatRole.AGENT)
        val turn = SendFlightGeometry.turnRows("r:new", rows)
        assertEquals(listOf(FlightPiece(-1, 10), FlightPiece(0, 11), FlightPiece(1, 12)),
            SendFlightGeometry.pair(hasText = true, attachmentCount = 2, turn))
        // A thumbnail with no row left for it does not fly.
        assertEquals(listOf(FlightPiece(-1, 10), FlightPiece(0, 11)),
            SendFlightGeometry.pair(hasText = true, attachmentCount = 1, turn))
    }

    @Test fun `a send finds only its own turn`() {
        // Another device's message is a newer turn too, but not this send's.
        val rows = earlier + row(10, "r:mine") + row(20, "r:elsewhere") + row(21, "r:mine", ChatRole.AGENT)
        assertEquals(listOf(10L), SendFlightGeometry.turnRows("r:mine", rows).map { it.message.id })
        assertTrue(SendFlightGeometry.turnRows("r:missing", rows).isEmpty())
    }
}
