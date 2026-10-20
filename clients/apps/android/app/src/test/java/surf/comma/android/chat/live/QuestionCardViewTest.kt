package surf.comma.android.chat.live

import android.net.Uri
import android.view.View
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.R
import surf.comma.android.conversation.AgentQuestion
import surf.comma.android.conversation.DraftAttachmentStatus
import surf.comma.android.conversation.QuestionChoice
import surf.comma.android.conversation.QuestionState
import surf.comma.android.conversation.QuestionStatus

// Invented test data only.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class QuestionCardViewTest {
    private class Host : QuestionCardHost {
        override val forms = QuestionForms()
        val answers = mutableListOf<Pair<String, QuestionCardAnswer>>()
        val picks = mutableListOf<Pair<String, Int>>()
        var takes = true

        override fun answer(questionMessageId: String, answer: QuestionCardAnswer, done: (Boolean) -> Unit) {
            answers += questionMessageId to answer
            done(takes)
        }

        override fun pickImages(questionMessageId: String, remaining: Int) {
            picks += questionMessageId to remaining
        }

        override fun addImages(questionMessageId: String, uris: List<Uri>) = Unit
        override fun removeImage(questionMessageId: String, attachmentId: String) = Unit
        override fun retryImage(questionMessageId: String, attachmentId: String) = Unit
    }

    private fun question(multi: Boolean = false, state: QuestionState = QuestionState(QuestionStatus.OPEN)) = AgentQuestion(
        "msg_q", "How should these two be handled?",
        listOf(QuestionChoice("c1", "Keep both", "Nothing is lost?", recommended = true), QuestionChoice("c2", "Merge them")),
        multi, allowOther = true, state = state,
    )

    private fun withCard(block: (QuestionCardView, Host, ComponentActivity) -> Unit) {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        try {
            val host = Host()
            val card = QuestionCardView(activity.get()).apply { hostOf = { host } }
            block(card, host, activity.get())
        } finally {
            activity.pause().stop().destroy()
        }
    }

    @Test fun `an open card sends the picked choice, skips, and keeps the choice when the answer is not taken`() = withCard { card, host, _ ->
        card.show(QuestionCardPayload(question()))
        assertNull(card.receiptLine)
        card.send.performClick()
        assertEquals(listOf("msg_q" to QuestionCardAnswer(listOf("c1"), null)), host.answers)
        assertFalse(card.failedShown)

        card.choiceRow("c2")!!.performClick()
        host.takes = false
        card.send.performClick()
        assertEquals("msg_q" to QuestionCardAnswer(listOf("c2"), null), host.answers.last())
        assertTrue(card.failedShown)

        card.skip.performClick()
        assertEquals("msg_q" to QuestionCardAnswer.SKIP, host.answers.last())
    }

    @Test fun `a multi-select card asks for a pick, and the other answer's words and images go with it`() = withCard { card, host, activity ->
        card.show(QuestionCardPayload(question(multi = true)))
        card.send.performClick()
        assertTrue(host.answers.isEmpty())
        assertEquals(activity.getString(R.string.chat_question_pick_any), card.noteShown?.toString())

        card.otherField.setText("Rename the older one")
        card.choiceRow("c2")!!.performClick()
        assertNull("picking clears the note", card.noteShown)
        // An image still uploading holds the answer back; it goes once the upload has.
        val uploading = QuestionImage("qatt-1", "a.png", DraftAttachmentStatus.UPLOADING)
        card.show(QuestionCardPayload(question(multi = true), listOf(uploading)))
        card.send.performClick()
        assertTrue(host.answers.isEmpty())
        assertEquals(activity.getString(R.string.chat_question_wait_upload), card.noteShown?.toString())
        card.show(QuestionCardPayload(question(multi = true), listOf(uploading.copy(status = DraftAttachmentStatus.UPLOADED))))
        assertEquals(listOf("msg_q" to QuestionCardAnswer(listOf("c2"), "Rename the older one")), host.answers)
    }

    @Test fun `a failed answer comes back with its choice and says it was not sent`() = withCard { card, host, _ ->
        card.show(QuestionCardPayload(question(state = QuestionState(QuestionStatus.FAILED, listOf("c2"), error = "No connection"))))
        assertTrue(card.failedShown)
        card.send.performClick()
        assertEquals(listOf("msg_q" to QuestionCardAnswer(listOf("c2"), null)), host.answers)
    }

    @Test fun `a closed card is a receipt, and so is an open one on a page that cannot answer`() = withCard { card, host, activity ->
        card.show(QuestionCardPayload(question(state = QuestionState(QuestionStatus.ANSWERED, listOf("c1", "c2")))))
        assertEquals("Keep both、Merge them", card.receiptLine.toString())
        card.show(QuestionCardPayload(question(state = QuestionState(QuestionStatus.SKIPPED))))
        assertEquals(activity.getString(R.string.chat_question_skipped), card.receiptLine.toString())

        // The card closed: a later failure starts again from what the core says was sent.
        host.forms.of(question()).choose("c2")
        card.show(QuestionCardPayload(question(state = QuestionState(QuestionStatus.REPLIED))))
        assertEquals(listOf("c1"), host.forms.of(question()).picks)

        // No host: the card cannot be answered here, so it shows the question alone.
        val readOnly = QuestionCardView(activity)
        readOnly.show(QuestionCardPayload(question()))
        assertEquals("", readOnly.receiptLine.toString())
    }

    @Test fun `the image button asks for the images the answer still has room for`() = withCard { card, host, _ ->
        card.show(QuestionCardPayload(question(), listOf(QuestionImage("qatt-1", "a.png", DraftAttachmentStatus.UPLOADED)), preparing = 1))
        card.findViewWithContentDescription(card.context.getString(R.string.chat_question_add_image))!!.performClick()
        assertEquals(listOf("msg_q" to 6), host.picks)
    }
}

private fun View.findViewWithContentDescription(description: String): View? {
    val found = ArrayList<View>()
    findViewsWithText(found, description, View.FIND_VIEWS_WITH_CONTENT_DESCRIPTION)
    return found.firstOrNull()
}
