package surf.comma.android.chat.live

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.conversation.AgentQuestion
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.DraftAttachment
import surf.comma.android.conversation.DraftAttachmentStatus
import surf.comma.android.conversation.QuestionChoice
import surf.comma.android.conversation.QuestionState
import surf.comma.android.conversation.QuestionStatus
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.conversation.display

// Invented test data only.
class QuestionCardTest {
    private val choices = listOf(
        QuestionChoice("c1", "Keep both", "Nothing is lost?", recommended = true),
        QuestionChoice("c2", "Merge them", reply = "Merge them, please."),
        QuestionChoice("c3", "Drop the older one"),
    )

    private fun question(multi: Boolean = false, state: QuestionState = QuestionState(QuestionStatus.OPEN)) =
        AgentQuestion("msg_2", "How should these two be handled?", choices, multi, allowOther = true, state = state)

    private fun asked(seq: Long, text: String?, question: AgentQuestion = question()): TimelineEntry.Message {
        val content = JSONArray()
        text?.let { content.put(JSONObject().put("type", "text").put("text", it)) }
        val part = question.json()
        content.put(JSONObject().put("type", "question").put("prompt", question.prompt).put("choices", part.getJSONArray("choices"))
            .put("multi_select", question.multiSelect).put("allow_other", question.allowOther).put("state", part.getJSONObject("state")))
        val message = display(JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", "agent")
            .put("agent_id", "agt_1").put("content", content).put("created_at", 1_700_000_000_000L + seq))!!
        return TimelineEntry.Message("m:msg_$seq", message)
    }

    private fun answered(seq: Long, words: String, questionMessageId: String): TimelineEntry.Message {
        val message = display(JSONObject().put("message_id", "msg_$seq").put("seq", seq).put("actor_type", "user")
            .put("client_request_id", "question-answer:$questionMessageId").put("created_at", 1_700_000_000_000L + seq)
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", words))
                .put(JSONObject().put("type", "question_answer").put("question_message_id", questionMessageId)
                    .put("choice_ids", JSONArray().put("c2")).put("skipped", false))))!!
        return TimelineEntry.Message("r:question-answer:$questionMessageId", message)
    }

    @Test fun `a question is a card row after the message's text, carrying its images`() {
        val state = ConversationState(conversationId = "cnv_1", timeline = listOf(asked(2, "Anything else?")),
            questionAttachments = mapOf("msg_2" to listOf(DraftAttachment("qatt-1", "a.png", 3, DraftAttachmentStatus.UPLOADING))))
        val rows = mapConversation(state, questionImages = QuestionImagesShown(
            previews = mapOf("qatt-1" to "content://media/1"), preparing = mapOf("msg_2" to 1))).rows
        assertEquals(listOf(null, LiveRowKinds.QUESTION), rows.map { it.cardKind })
        assertEquals("Anything else?", rows[0].text)
        val card = rows[1]
        assertEquals(rowId("m:msg_2#qmsg_2"), card.id)
        assertEquals(ChatRole.AGENT, card.role)
        assertEquals(rows[0].turnId, card.turnId)
        val payload = QuestionCardPayload.decode(card.cardPayload)!!
        assertEquals(question(), payload.question)
        assertEquals(listOf(QuestionImage("qatt-1", "a.png", DraftAttachmentStatus.UPLOADING, "content://media/1")), payload.images)
        assertEquals(2, payload.imageCount)
        assertTrue(payload.uploading)
        assertFalse(payload.uploadFailed)
    }

    @Test fun `a message that only asks is its card alone, and the answer shows as the person's words`() {
        val state = ConversationState(conversationId = "cnv_1", timeline = listOf(asked(2, null), answered(3, "Merge them, please.", "msg_2")))
        val rows = mapConversation(state).rows
        assertEquals(listOf(LiveRowKinds.QUESTION, null), rows.map { it.cardKind })
        assertEquals(listOf(ChatRole.AGENT, ChatRole.USER), rows.map { it.role })
        assertEquals("Merge them, please.", rows[1].text)
        // The card is not part of the message's words.
        assertEquals("", entryText(state, "m:msg_2"))
    }

    @Test fun `the payload reads back what it wrote`() {
        val failed = question(multi = true, state = QuestionState(QuestionStatus.FAILED, listOf("c1", "c3"), "both", "No connection"))
        val payload = QuestionCardPayload(failed, listOf(QuestionImage("q1", "a.png", DraftAttachmentStatus.FAILED)), preparing = 2)
        assertEquals(payload, QuestionCardPayload.decode(payload.encode()))
        assertTrue(payload.uploadFailed)
        assertNull(QuestionCardPayload.decode("not json"))
        assertNull(QuestionCardPayload.decode(null))
    }

    @Test fun `a single-select card starts on the recommended choice and the other answer takes the pick while it says something`() {
        val form = QuestionForm(question())
        assertEquals(listOf("c1"), form.picks)
        assertFalse(form.otherOn)
        form.write("Both, but rename one")
        assertTrue(form.otherOn)
        assertEquals(emptyList<String>(), form.picks)
        form.write("   ")
        assertFalse(form.otherOn)
        assertEquals(listOf("c1"), form.picks)

        form.choose("c2")
        form.write("x")
        form.write("")
        assertEquals("emptying the field gives back the last listed pick", listOf("c2"), form.picks)

        form.images(1)
        assertTrue("adding an image picks the other answer", form.otherOn)
        assertEquals(emptyList<String>(), form.picks)
        assertEquals(QuestionCardAnswer(emptyList(), ""), form.submit(uploading = false, uploadFailed = false))
    }

    @Test fun `a multi-select card starts empty, keeps choice order and asks for at least one`() {
        val form = QuestionForm(question(multi = true))
        assertEquals(emptyList<String>(), form.picks)
        assertNull(form.submit(uploading = false, uploadFailed = false))
        assertEquals(QuestionNote.PICK_ANY, form.note)
        form.choose("c3")
        assertNull("picking clears the note", form.note)
        form.choose("c1")
        assertEquals(listOf("c1", "c3"), form.picks)
        form.write("and tell me")
        assertEquals("a multi-select card keeps its picks beside the other answer", listOf("c1", "c3"), form.picks)
        form.choose("c3")
        assertEquals(QuestionCardAnswer(listOf("c1"), "and tell me"), form.submit(uploading = false, uploadFailed = false))
        form.pickOther()
        assertFalse(form.otherOn)
        assertEquals(QuestionCardAnswer(listOf("c1"), null), form.submit(uploading = false, uploadFailed = false))
    }

    @Test fun `an answer without anything says what is missing, and images hold it until they upload`() {
        val form = QuestionForm(AgentQuestion("msg_2", "Which?", choices.map { it.copy(recommended = false) }, false, true,
            QuestionState(QuestionStatus.OPEN)))
        assertNull(form.submit(uploading = false, uploadFailed = false))
        assertEquals(QuestionNote.PICK_ONE, form.note)
        form.pickOther()
        assertNull(form.submit(uploading = false, uploadFailed = false))
        assertEquals(QuestionNote.OTHER_EMPTY, form.note)

        form.images(1)
        assertNull(form.submit(uploading = true, uploadFailed = false))
        assertEquals(QuestionNote.WAIT_UPLOAD, form.note)
        assertTrue(form.waitingForUploads)
        assertNull(form.submit(uploading = false, uploadFailed = true))
        assertEquals(QuestionNote.UPLOAD_FAILED, form.note)
        assertFalse(form.waitingForUploads)
        assertEquals(QuestionCardAnswer(emptyList(), ""), form.submit(uploading = false, uploadFailed = false))
        assertNull(form.note)
    }

    @Test fun `a failed answer comes back as it was sent`() {
        val form = QuestionForm(question(state = QuestionState(QuestionStatus.FAILED, listOf("c2"), "", "No connection")))
        assertEquals(listOf("c2"), form.picks)
        assertTrue("the other answer was sent (empty), so it is picked again", form.otherOn)
        val forms = QuestionForms()
        assertEquals(listOf("c1"), forms.of(question()).picks)
        forms.of(question()).choose("c3")
        assertEquals("a card scrolled away and back keeps its picks", listOf("c3"), forms.of(question()).picks)
        forms.drop("msg_2")
        assertEquals(listOf("c1"), forms.of(question()).picks)
    }

    @Test fun `a closed card's receipt says the answer or how it closed`() {
        val labels = QuestionReceiptLabels(sending = "Sending", skipped = "Skipped", replied = "Answered in the chat", replaced = "Replaced")
        val picked = QuestionState(QuestionStatus.ANSWERED, listOf("c3", "c1"), " rename one ")
        assertEquals("Keep both、Drop the older one、rename one", questionReceiptLine(question(state = picked), labels))
        assertEquals("Keep both、Drop the older one、rename one · Sending",
            questionReceiptLine(question(state = picked.copy(status = QuestionStatus.SENDING)), labels))
        assertEquals("Sending", questionReceiptLine(question(state = QuestionState(QuestionStatus.SENDING)), labels))
        assertEquals("Skipped", questionReceiptLine(question(state = QuestionState(QuestionStatus.SKIPPED)), labels))
        assertEquals("Answered in the chat", questionReceiptLine(question(state = QuestionState(QuestionStatus.REPLIED)), labels))
        assertEquals("Replaced", questionReceiptLine(question(state = QuestionState(QuestionStatus.REPLACED)), labels))
        assertEquals("", questionReceiptLine(question(), labels))
    }
}
