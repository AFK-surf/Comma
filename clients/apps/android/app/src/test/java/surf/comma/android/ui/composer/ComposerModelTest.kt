package surf.comma.android.ui.composer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ComposerModelTest {
    private var nextId = 0
    private fun model() = ComposerModel(newId = { "a${nextId++}" })

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

    // ---- Content ----

    @Test
    fun `text or an attachment is content`() {
        assertTrue(model().apply { updateText("hi") }.hasContent)
        assertTrue(model().apply { addAttachments(1) }.hasContent)
    }

    @Test
    fun `whitespace alone is not content`() {
        val m = model().apply { updateText("  \n ") }
        assertFalse(m.hasContent)
        assertFalse(m.canSend)
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

    @Test fun `failed uploads explain the send block until retried or removed`() {
        val m = model()
        val (failed, pending) = m.addAttachments(2)
        assertEquals(ComposerModel.SendBlock.UPLOADING, m.sendBlock)
        m.setAttachmentState(failed, AttachmentUploadState.Failed)
        assertEquals(ComposerModel.SendBlock.UPLOAD_FAILED, m.sendBlock)
        assertFalse(m.canSend)
        m.setAttachmentState(failed, AttachmentUploadState.Uploading())
        assertEquals(ComposerModel.SendBlock.UPLOADING, m.sendBlock)
        m.removeAttachment(failed)
        assertEquals(ComposerModel.SendBlock.UPLOADING, m.sendBlock)
        m.setAttachmentState(pending, AttachmentUploadState.Done)
        assertEquals(null, m.sendBlock)
        assertTrue(m.canSend)
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
        assertFalse(m.hasContent)
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
}
