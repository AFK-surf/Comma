package surf.comma.android.chat.render

import surf.comma.android.conversation.ReplyState
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
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
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TypingRowTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density

    private fun prepare(rows: List<ChatMessage>): List<PreparedChatMessage> = runBlocking {
        MessageLayoutPrecomputer().prepare(rows, viewportWidthPx = 1080, density = density, fontScale = 1f, darkTheme = false)
    }

    private fun waiting(status: String) = prepare(mapConversation(ConversationState(conversationId = "c",
        participant = ParticipantStatus("ptp_1", "active", status, null, null, null),
        reply = ReplyState(working = true))).rows).single()

    private fun bound(item: PreparedChatMessage) = ChatMessageCell(activity).apply {
        bind(item)
        measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        layout(0, 0, measuredWidth, measuredHeight)
    }

    @Test fun `the waiting row is a fixed box with no text to draw`() {
        val item = waiting("is working")
        assertTrue(TypingBubble.isTypingRow(item))
        assertTrue(item.blocks.isEmpty())
        assertTrue(item.contents.isEmpty())
        assertFalse(item.drawBubble)
        assertEquals(item.topMarginPx + (TypingBubble.HEIGHT_DP * density).toInt(), item.cellHeightPx)
        // Whatever the backend reports, the row is the same box.
        assertEquals(item.cellHeightPx, waiting("is searching the web for a very long list of things").cellHeightPx)
    }

    @Test fun `a status row never lays out text, even if one is given`() {
        val item = prepare(listOf(ChatMessage(id = 1, conversationId = "c", turnId = "t", role = ChatRole.AGENT,
            text = "Thinking…", createdAt = 0, status = MessageStatus.COMPLETED,
            cardKind = TimelineBlockKinds.LIVE_STATUS))).single()
        assertTrue(item.blocks.isEmpty())
    }

    @Test fun `the cell draws the bubble where replies start and describes it without status text`() {
        val item = waiting("is working")
        val cell = bound(item)
        assertEquals(item.cellHeightPx, cell.measuredHeight)
        assertEquals("Agent is replying", cell.contentDescription)
        val bitmap = Bitmap.createBitmap(cell.width, cell.height, Bitmap.Config.ARGB_8888)
        cell.draw(Canvas(bitmap))
        val bodyLeft = item.sideMarginPx + (TypingBubble.BODY_INSET_DP * density).toInt()
        val middle = item.topMarginPx + (TypingBubble.BODY_HEIGHT_DP * density / 2f).toInt()
        val grey = TypingBubble.bubbleColor(cell)
        // Between the pill's left edge and the first dot.
        assertEquals(grey, bitmap.getPixel(bodyLeft + (6 * density).toInt(), middle))
        // The middle dot, at the pill's centre.
        assertTrue(bitmap.getPixel(bodyLeft + (TypingBubble.BODY_WIDTH_DP * density / 2f).toInt(), middle) != grey)
        // Nothing to the right of the pill: no status text.
        val right = bodyLeft + (TypingBubble.BODY_WIDTH_DP * density).toInt()
        for (x in right + (4 * density).toInt() until cell.width) assertEquals(0, bitmap.getPixel(x, middle))
    }

    @Test fun `a streaming draft keeps the bubble, and the reply replaces it at the same top edge`() {
        val user = ChatMessage(id = 1, conversationId = "c", turnId = "t", role = ChatRole.USER, text = "q",
            createdAt = 0, status = MessageStatus.COMPLETED)
        val bubble = mapConversation(ConversationState(conversationId = "c", reply = ReplyState(coming = true))).rows.single()
        val draft = ReplyDraft("resp-1", listOf("msg_1"), "d1", 3, "Answer", false)
        val drafting = mapConversation(ConversationState(conversationId = "c",
            timeline = listOf(TimelineEntry.Draft(draft.key, draft)), reply = ReplyState(coming = true, streaming = true))).rows.single()
        assertEquals("the draft's text is not shown", bubble, drafting)
        val reply = ChatMessage(id = 2, conversationId = "c", turnId = "t", role = ChatRole.AGENT, text = "Answer",
            createdAt = 0, status = MessageStatus.COMPLETED)
        val waiting = prepare(listOf(user, bubble))
        val answered = prepare(listOf(user, reply))
        assertTrue(TypingBubble.isTypingRow(waiting.last()))
        assertFalse(TypingBubble.isTypingRow(answered.last()))
        assertEquals(waiting.last().topMarginPx, answered.last().topMarginPx)
        assertEquals(waiting.last().sideMarginPx, answered.last().sideMarginPx)
        assertEquals("Agent: Answer", bound(answered.last()).contentDescription)
    }
}
