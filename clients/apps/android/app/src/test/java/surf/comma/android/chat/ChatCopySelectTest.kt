package surf.comma.android.chat

import android.content.ClipboardManager
import android.text.style.TypefaceSpan
import android.view.View
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.live.ReplyAction
import surf.comma.android.chat.live.ReplyActionsRow
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.SelectableText
import surf.comma.android.chat.render.Md
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.ui.MessageActionsPopup
import java.util.concurrent.TimeUnit

// Invented test data only.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en-rUS-xxhdpi")
class ChatCopySelectTest {
    private val context: android.app.Application get() = RuntimeEnvironment.getApplication()

    private fun prepared(message: ChatMessage, previousRole: ChatRole? = ChatRole.AGENT): PreparedChatMessage = runBlocking {
        MessageLayoutPrecomputer().prepareChanged(emptyList(), listOf(message), viewportWidthPx = 1080, density = 3f,
            fontScale = 1f, darkTheme = false, firstPreviousRole = previousRole).single()
    }

    private fun message(text: String, role: ChatRole = ChatRole.AGENT, kind: String? = null, payload: String? = null) =
        ChatMessage(id = text.hashCode().toLong(), conversationId = "cnv_1", turnId = "r:req-1", role = role, text = text,
            createdAt = 0L, cardKind = kind, cardPayload = payload,
            // An agent's text as the core parsed it.
            markdown = if (role == ChatRole.AGENT && kind == null && text.isNotEmpty()) Md.of(text) else null)

    @Test fun `the long-press menu keeps both copies and adds select text with the whole message`() {
        val item = prepared(message("Run:\n```sh\nls\n```"))
        val entries = MessageActionsPopup.entriesFor(item, Md.blocks("Run:\n```sh\nls\n```\n\nand more after the card"))
        assertEquals(listOf(R.string.action_copy_code, R.string.action_copy_message, R.string.action_select_text),
            entries.map { it.labelRes })
        assertEquals(listOf(false, false, true), entries.map { it.selects })
        assertEquals("Run:\n\nls\n\nand more after the card", entries.last().text)
    }

    @Test fun `user messages can select text too, and a message without text has no menu`() {
        val user = MessageActionsPopup.entriesFor(prepared(message("hello there", ChatRole.USER)),
            listOf(MessageContent.Paragraph(Md.plain("hello there"))))
        assertEquals(listOf(R.string.action_copy_message, R.string.action_select_text), user.map { it.labelRes })
        assertTrue(MessageActionsPopup.entriesFor(prepared(message("")), emptyList()).isEmpty())
    }

    @Test fun `the reply's copy button copies through the callback and turns into a check for a moment`() {
        val row = ReplyActionsRow(context)
        val item = prepared(message("", kind = LiveRowKinds.REPLY_ACTIONS, payload = "r:req-1"))
        row.bind(item)
        val copied = ArrayList<Pair<ReplyAction, Long>>()
        row.onAction = { action, bound ->
            copied += action to bound.message.id
            MessageActionsPopup.copyMessage(context, "**the** reply")
            true
        }
        row.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        assertEquals(item.cellHeightPx, row.measuredHeight)
        val button = row.getChildAt(0)
        assertEquals(context.getString(R.string.chat_reply_copy), button.contentDescription)
        assertTrue(button.performClick())
        assertEquals(listOf(ReplyAction.COPY to item.message.id), copied)
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        assertEquals("**the** reply", clipboard.primaryClip!!.getItemAt(0)!!.text.toString())
        assertEquals(context.getString(R.string.copied), button.contentDescription)
        ShadowLooper.idleMainLooper(2_100, TimeUnit.MILLISECONDS)
        assertEquals(context.getString(R.string.chat_reply_copy), button.contentDescription)
    }

    @Test fun `a copy that did not happen shows no check`() {
        val row = ReplyActionsRow(context)
        row.bind(prepared(message("", kind = LiveRowKinds.REPLY_ACTIONS, payload = "r:req-1")))
        row.onAction = { _, _ -> false }
        row.getChildAt(0).performClick()
        assertEquals(context.getString(R.string.chat_reply_copy), row.getChildAt(0).contentDescription)
    }

    @Test fun `select text shows the core's parse of the message without its syntax`() {
        val text = SelectableText.build(Md.blocks("# Plan\n\nSome **bold** and `code`.\n\n- one\n- two\n  - nested\n1. first\n\n" +
            "```kt\nval x = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\nEnd"))
        assertEquals("Plan\n\nSome bold and code.\n\n• one\n• two\n    ◦ nested\n1. first\n\nval x = 1\n\na\tb\n1\t2\n\nEnd",
            text.toString())
        val code = text.getSpans(0, text.length, TypefaceSpan::class.java).filter { it.family == "monospace" }
        assertEquals(listOf("code", "val x = 1"), code.map { text.subSequence(text.getSpanStart(it), text.getSpanEnd(it)).toString() })
    }

}
