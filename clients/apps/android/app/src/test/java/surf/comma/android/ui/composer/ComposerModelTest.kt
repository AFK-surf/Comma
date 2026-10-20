package surf.comma.android.ui.composer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.ui.composer.ComposerModel.VoiceStart

class ComposerModelTest {
    private var nextId = 0
    private fun model(voice: Boolean = true) =
        ComposerModel(newId = { "a${nextId++}" }).apply { voiceAvailable = voice }

    @Test fun `admitting a send preserves the next text and newly added images`() {
        val m = model().apply { updateText("first") }
        val sent = m.addAttachments(1)
        sent.forEach { m.setAttachmentState(it, AttachmentUploadState.Done) }
        m.updateText("next")
        val next = m.addAttachments(1)
        m.consumeSentDraft("first", sent.toSet())
        assertEquals("next", m.text)
        assertEquals(next, m.attachments.map { it.id })
        assertFalse(m.uploadsSettled)
        m.consumeSentDraft("next", next.toSet())
        assertFalse(m.hasContent)
    }

    // ---- Trailing button ----

    @Test
    fun `empty composer shows the microphone`() {
        assertEquals(TrailingAction.MIC, model().trailingAction)
    }

    @Test
    fun `text or an attachment turns the microphone into send`() {
        val withText = model().apply { updateText("hi") }
        assertEquals(TrailingAction.SEND, withText.trailingAction)

        val withImage = model().apply { addAttachments(1) }
        assertEquals(TrailingAction.SEND, withImage.trailingAction)
    }

    @Test
    fun `whitespace alone is not content`() {
        val m = model().apply { updateText("  \n ") }
        assertEquals(TrailingAction.MIC, m.trailingAction)
        assertFalse(m.canSend)
    }

    @Test
    fun `an empty composer keeps send while generating and the microphone afterwards`() {
        val m = model()
        m.setGenerating(true)
        assertEquals(TrailingAction.SEND, m.trailingAction)
        assertFalse(m.canSend)
        m.setGenerating(false)
        assertEquals(TrailingAction.MIC, m.trailingAction)
    }

    @Test
    fun `content shows send whether or not a reply is generating`() {
        val m = model()
        m.setGenerating(true)
        m.updateText("draft")
        assertEquals(TrailingAction.SEND, m.trailingAction)
        m.updateText("")
        assertEquals(TrailingAction.SEND, m.trailingAction)
        m.updateText("draft")
        m.setGenerating(false)
        assertEquals(TrailingAction.SEND, m.trailingAction)
    }

    @Test fun `admitted image draft clears even after its consumed uploads leave the queue`() {
        val model = model()
        model.updateText("caption")
        val id = model.addAttachments(1).single()
        model.setAttachmentState(id, AttachmentUploadState.Done)
        assertTrue(model.canSend)
        model.setAttachmentState(id, AttachmentUploadState.Failed)
        model.clearDraft()
        assertFalse(model.hasContent)
        assertTrue(model.attachments.isEmpty())
        assertEquals("", model.text)
    }

    // ---- Sending ----

    @Test
    fun `send takes text and attachment ids and clears the composer`() {
        val m = model()
        m.updateText("  look at these  ")
        val ids = m.addAttachments(2)
        ids.forEach { m.setAttachmentState(it, AttachmentUploadState.Done) }

        val outgoing = m.send()!!
        assertEquals("look at these", outgoing.text)
        assertEquals(ids, outgoing.attachmentIds)
        assertEquals("", m.text)
        assertTrue(m.attachments.isEmpty())
        assertEquals(TrailingAction.MIC, m.trailingAction)
    }

    @Test
    fun `can send while generating`() {
        val m = model()
        m.updateText("next question")
        m.setGenerating(true)
        assertTrue(m.canSend)
        assertEquals("next question", m.send()!!.text)
        assertEquals("", m.text)
        assertEquals(TrailingAction.SEND, m.trailingAction)
        assertFalse(m.canSend)
    }

    @Test
    fun `images still uploading block send until every one is done`() {
        val m = model()
        val (first, second) = m.addAttachments(2)
        assertFalse(m.canSend)
        m.setAttachmentState(first, AttachmentUploadState.Done)
        m.setAttachmentState(second, AttachmentUploadState.Uploading(0.4f))
        assertFalse(m.canSend)
        m.setAttachmentState(second, AttachmentUploadState.Failed)
        assertFalse(m.canSend)
        m.setAttachmentState(second, AttachmentUploadState.Done)
        assertTrue(m.canSend)
    }

    // ---- Attachments ----

    @Test
    fun `at most eight attachments, the core's limit`() {
        val m = model()
        assertEquals(7, m.addAttachments(7).size)
        assertEquals(1, m.addAttachments(5).size)
        assertEquals(8, m.attachments.size)
        assertTrue(m.addAttachments(1).isEmpty())
        assertEquals(0, m.remainingSlots)
    }

    @Test
    fun `removing an attachment frees its slot`() {
        val m = model()
        val ids = m.addAttachments(10)
        assertTrue(m.removeAttachment(ids[3]))
        assertEquals(1, m.remainingSlots)
        assertEquals(1, m.addAttachments(4).size)
        assertFalse(m.removeAttachment("missing"))
    }

    @Test
    fun `new attachments start pending and unknown ids are ignored`() {
        val m = model()
        val id = m.addAttachments(1).single()
        assertEquals(AttachmentUploadState.Pending, m.attachments.single().state)
        assertFalse(m.setAttachmentState("nope", AttachmentUploadState.Done))
        assertTrue(m.setAttachmentState(id, AttachmentUploadState.Uploading()))
        assertEquals(AttachmentUploadState.Uploading(null), m.attachments.single().state)
    }

    // ---- Dictation ----

    @Test
    fun `dictation hides the send button and confirm fills the input without sending`() {
        val m = model()
        assertEquals(VoiceStart.STARTED, m.beginDictation())
        assertEquals(VoiceMode.DICTATION, m.voice)
        assertFalse(m.canSend)

        val insertion = m.endDictation("明天早上八点提醒我", 0, 0)!!
        assertEquals("明天早上八点提醒我", insertion.text)
        assertEquals(insertion.text.length, insertion.caret)
        assertEquals(VoiceMode.NONE, m.voice)
        assertEquals(TrailingAction.SEND, m.trailingAction)
    }

    @Test
    fun `dictation inserts at the caret with spacing only where the script needs it`() {
        val m = model()
        m.updateText("Remind me tomorrow")
        m.beginDictation()
        val latin = m.endDictation("at nine", 18, 18)!!
        assertEquals("Remind me tomorrow at nine", latin.text)

        val cjk = model().apply { updateText("提醒我") }
        cjk.beginDictation()
        assertEquals("提醒我明天开会", cjk.endDictation("明天开会", 3, 3)!!.text)
    }

    @Test
    fun `cancelled or silent dictation leaves the text untouched`() {
        val m = model()
        m.updateText("keep me")
        m.beginDictation()
        assertNull(m.endDictation(null, 0, 0))
        assertEquals("keep me", m.text)
        m.beginDictation()
        assertNull(m.endDictation("   ", 0, 0))
        assertEquals("keep me", m.text)
        assertEquals(VoiceMode.NONE, m.voice)
    }

    @Test
    fun `dictation and hold to talk are both allowed while generating`() {
        val m = model()
        m.setGenerating(true)
        assertEquals(VoiceStart.STARTED, m.beginDictation())
        m.endDictation(null, 0, 0)
        assertEquals(VoiceStart.STARTED, m.beginHold())
        assertEquals("next", m.endHold("next", cancelled = false))
    }

    // ---- Hold to talk ----

    @Test
    fun `hold release returns the transcript to send`() {
        val m = model()
        assertEquals(VoiceStart.STARTED, m.beginHold())
        assertEquals("今天天气怎么样", m.endHold(" 今天天气怎么样 ", cancelled = false))
        assertEquals(VoiceMode.NONE, m.voice)
    }

    @Test
    fun `cancelled hold sends nothing`() {
        val m = model()
        m.beginHold()
        assertNull(m.endHold("本来要说的话", cancelled = true))
        assertEquals(VoiceMode.NONE, m.voice)
        assertEquals("", m.text)
    }

    @Test
    fun `hold that ends after a reply started generating still sends`() {
        val m = model()
        m.beginHold()
        m.setGenerating(true)
        assertEquals("not too late", m.endHold("not too late", cancelled = false))
    }

    @Test
    fun `hold needs an empty composer and only one voice session at a time`() {
        val drafted = model().apply { updateText("draft") }
        assertEquals(VoiceStart.IGNORED, drafted.beginHold())

        val m = model()
        m.beginDictation()
        assertEquals(VoiceStart.IGNORED, m.beginHold())
        assertEquals(VoiceStart.IGNORED, m.beginDictation())
    }

    // ---- Voice unavailable ----

    @Test
    fun `without credentials both voice entries report unavailable and change nothing`() {
        val m = model(voice = false)
        assertEquals(VoiceStart.UNAVAILABLE, m.beginDictation())
        assertEquals(VoiceStart.UNAVAILABLE, m.beginHold())
        assertEquals(VoiceMode.NONE, m.voice)
        assertEquals(TrailingAction.MIC, m.trailingAction)
    }
}
