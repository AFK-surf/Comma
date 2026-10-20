package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class FailedSendTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density

    private fun prepare(message: ChatMessage, width: Int = 1080): PreparedChatMessage = runBlocking {
        MessageLayoutPrecomputer().prepare(listOf(message), viewportWidthPx = width, density = density,
            fontScale = 1f, darkTheme = false).single()
    }

    private fun userMessage(status: MessageStatus) = ChatMessage(id = 42, conversationId = "c", turnId = "r:req-1",
        role = ChatRole.USER, text = "hello there", createdAt = 1, status = status, requestId = "req-1",
        retryable = status == MessageStatus.FAILED)

    private fun laidOut(item: PreparedChatMessage, width: Int = 1080): ChatMessageCell = ChatMessageCell(activity).apply {
        bind(item)
        measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        layout(0, 0, width, measuredHeight)
        draw(Canvas(Bitmap.createBitmap(width, measuredHeight.coerceAtLeast(1), Bitmap.Config.ARGB_8888)))
    }

    private fun tap(view: View, x: Float, y: Float) {
        val time = SystemClock.uptimeMillis()
        view.dispatchTouchEvent(MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, x, y, 0))
        view.dispatchTouchEvent(MotionEvent.obtain(time, time + 50, MotionEvent.ACTION_UP, x, y, 0))
    }

    @Test fun `an unsent message keeps a dimmed bubble with no error text and a note under it`() {
        val failed = prepare(userMessage(MessageStatus.FAILED))
        val sent = prepare(userMessage(MessageStatus.COMPLETED))
        assertTrue(failed.drawBubble)
        assertEquals(0.55f, failed.contentAlpha, 0.001f)
        assertTrue(failed.contents.none { it is MessageContent.Status })
        assertTrue(failed.actions.isEmpty())
        assertNotNull(failed.sendFailedNote)
        assertEquals("未发送 · 点按重试", failed.sendFailedNote!!.text.toString())
        assertTrue(failed.sendFailedNoteTopPx >= failed.bubbleTopPx + failed.bubbleHeightPx)
        assertEquals(sent.bubbleHeightPx, failed.bubbleHeightPx)
        assertNull(sent.sendFailedNote)
    }

    @Test fun `tapping the failure mark or the note asks for the options`() {
        val item = prepare(userMessage(MessageStatus.FAILED))
        val cell = laidOut(item)
        val taps = ArrayList<Long>()
        cell.onSendFailed = { taps += it }
        val bubbleLeft = cell.width - item.sideMarginPx - item.bubbleWidthPx
        val markX = bubbleLeft - (8 + 10) * density
        val bubbleCenterY = item.bubbleTopPx + item.bubbleHeightPx / 2f
        tap(cell, markX, bubbleCenterY)
        // The 44dp touch target reaches beyond the 20dp mark.
        tap(cell, markX - 18 * density, bubbleCenterY)
        tap(cell, cell.width - item.sideMarginPx - 4f, item.sendFailedNoteTopPx + item.sendFailedNote!!.height / 2f)
        assertEquals(listOf(42L, 42L, 42L), taps)
        tap(cell, cell.width / 2f, 2f)
        assertEquals(3, taps.size)
    }

    @Test fun `an image-only failed send keeps the picture and opens the same resend choices`() {
        val pending = surf.comma.android.conversation.PendingMessage("photo-request", "",
            listOf(surf.comma.android.conversation.WorkspaceFile("photo.jpg", "/uploads/abcdefghijklmnopqrstuv-photo.jpg",
                "image/jpeg", 2000, 800, 400)), null, 1, surf.comma.android.conversation.PendingStatus.FAILED)
        val mapped = mapConversation(surf.comma.android.conversation.ConversationState(conversationId = "c",
            timeline = listOf(surf.comma.android.conversation.TimelineEntry.Pending("r:photo-request", pending))))
        val row = mapped.rows.single()
        assertEquals("photo-request", mapped.retryTargets[row.id])
        val item = prepare(row)
        val view = AttachmentView(activity).apply {
            bind(item)
            measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            layout(0, 0, 1080, measuredHeight)
        }
        activity.setContentView(view)
        var tapped: Long? = null
        view.onSendFailed = { tapped = it }
        val note = view.getChildAt(1) as android.widget.TextView
        assertEquals(activity.getString(R.string.chat_send_failed_note), note.text)
        assertEquals(View.VISIBLE, note.visibility)
        tap(view, note.right - 4f, note.top + note.height / 2f)
        ShadowLooper.idleMainLooper()
        assertEquals(row.id, tapped)
        val confirmed = prepare(row.copy(status = MessageStatus.COMPLETED))
        assertEquals(item.cellHeightPx - (32 * density).toInt(), confirmed.cellHeightPx)
        view.releaseMedia()
    }

    @Test fun `the sheet offers retry and delete and reports the choice`() {
        val choices = ArrayList<FailedSendChoice>()
        FailedSendSheet(activity) { choices += it }.show()
        ShadowLooper.idleMainLooper()
        val dialog = ShadowDialog.getLatestDialog()
        assertTrue(dialog.isShowing)
        assertEquals(activity.getString(R.string.chat_retry), dialog.findViewById<android.widget.TextView>(R.id.failed_send_retry).text.toString())
        assertEquals(activity.getString(R.string.chat_delete), dialog.findViewById<android.widget.TextView>(R.id.failed_send_delete).text.toString())
        dialog.findViewById<View>(R.id.failed_send_retry).performClick()
        assertFalse(dialog.isShowing)
        FailedSendSheet(activity) { choices += it }.show()
        ShadowDialog.getLatestDialog().findViewById<View>(R.id.failed_send_delete).performClick()
        assertEquals(listOf(FailedSendChoice.RETRY, FailedSendChoice.DELETE), choices)
    }

    @Test fun `retry uses the original request id and delete only removes the local copy`() {
        val retried = ArrayList<String>()
        val deleted = ArrayList<String>()
        val actions = FailedSendActions(requestIdFor = mapOf(42L to "req-1")::get, retry = { retried += it },
            delete = { deleted += it })
        assertTrue(actions.has(42))
        assertFalse(actions.has(7))
        actions.choose(42, FailedSendChoice.RETRY)
        actions.choose(42, FailedSendChoice.DELETE)
        actions.choose(7, FailedSendChoice.RETRY)
        assertEquals(listOf("req-1"), retried)
        assertEquals(listOf("req-1"), deleted)
    }

    @Test fun `a reply error is a full-width card with a bold title and a grey explanation`() {
        val card = prepare(ChatMessage(id = 9, conversationId = "c", role = ChatRole.AGENT, text = "回复出错了",
            createdAt = 0, cardKind = TimelineBlockKinds.REPLY_ERROR, cardPayload = "Model quota exceeded"))
        assertTrue(card.drawBubble)
        assertEquals(12f * density, card.cornerRadiusPx, 0.5f)
        assertEquals(MessageContent.Paragraph(surf.comma.android.chat.render.MarkdownText.bold("回复出错了")), card.contents.first())
        assertEquals("Model quota exceeded", (card.contents[1] as MessageContent.Status).label)
        assertTrue(card.actions.isEmpty())
        val retryable = prepare(ChatMessage(id = 9, conversationId = "c", role = ChatRole.AGENT, text = "回复出错了",
            createdAt = 0, cardKind = TimelineBlockKinds.REPLY_ERROR, cardPayload = "x", retryable = true))
        assertTrue(retryable.bubbleHeightPx > prepare(ChatMessage(id = 9, conversationId = "c", role = ChatRole.AGENT,
            text = "回复出错了", createdAt = 0, cardKind = TimelineBlockKinds.REPLY_ERROR, cardPayload = "x")).bubbleHeightPx)
    }
}
