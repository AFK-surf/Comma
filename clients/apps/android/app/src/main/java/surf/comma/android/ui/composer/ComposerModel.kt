package surf.comma.android.ui.composer

/** Upload progress of one attachment. The composer only displays it; the host drives it. */
sealed interface AttachmentUploadState {
    data object Pending : AttachmentUploadState
    /** [progress] in 0..1, or null when the uploader cannot tell. */
    data class Uploading(val progress: Float? = null) : AttachmentUploadState
    data object Failed : AttachmentUploadState
    data object Done : AttachmentUploadState
}

/**
 * The composer's state, free of Android types so every transition is unit-testable.
 * The view renders from it and forwards user intent to it; nothing else mutates it.
 */
class ComposerModel(
    val maxAttachments: Int = MAX_ATTACHMENTS,
    private val newId: () -> String,
) {
    data class Slot(val id: String, val state: AttachmentUploadState)

    var text: String = ""
        private set
    private val slots = ArrayList<Slot>()
    val attachments: List<Slot> get() = slots

    val remainingSlots: Int get() = maxAttachments - slots.size
    val hasContent: Boolean get() = text.isNotBlank() || slots.isNotEmpty()
    enum class SendBlock { EMPTY, UPLOAD_FAILED, UPLOADING }
    val sendBlock: SendBlock?
        get() = when {
            !hasContent -> SendBlock.EMPTY
            slots.any { it.state == AttachmentUploadState.Failed } -> SendBlock.UPLOAD_FAILED
            !uploadsSettled -> SendBlock.UPLOADING
            else -> null
        }
    val uploadsSettled: Boolean get() = slots.all { it.state == AttachmentUploadState.Done }

    /** Send is enabled with content once every upload has finished, whether or not a reply generates. */
    val canSend: Boolean
        get() = hasContent && uploadsSettled

    fun updateText(value: String) {
        text = value
    }

    /**
     * Adds up to [remainingSlots] attachments and returns the new ids, in order.
     * Anything past the limit is dropped; the caller reports how many.
     */
    fun addAttachments(count: Int): List<String> {
        val accepted = count.coerceAtMost(remainingSlots).coerceAtLeast(0)
        return List(accepted) { newId() }.onEach { slots += Slot(it, AttachmentUploadState.Pending) }
    }

    /** Holds [listed], the draft's files as its host lists them, in place of the ones held. */
    fun showAttachments(listed: List<Slot>) {
        slots.clear()
        slots += listed
    }

    fun removeAttachment(id: String): Boolean = slots.removeAll { it.id == id }

    fun setAttachmentState(id: String, state: AttachmentUploadState): Boolean {
        val index = slots.indexOfFirst { it.id == id }
        if (index < 0) return false
        slots[index] = slots[index].copy(state = state)
        return true
    }

    /** Takes the message out of the composer, or null when [canSend] is false. */
    fun send(): Outgoing? {
        if (!canSend) return null
        val outgoing = Outgoing(text.trim(), slots.map { it.id })
        clearDraft()
        return outgoing
    }

    /** Consume the admitted snapshot while preserving edits and attachments added meanwhile. */
    fun consumeSentDraft(sentText: String, sentAttachmentIds: Set<String>) {
        if (text == sentText) text = ""
        slots.removeAll { it.id in sentAttachmentIds }
    }

    fun clearDraft() {
        text = ""
        slots.clear()
    }

    data class Outgoing(val text: String, val attachmentIds: List<String>)

    companion object {
        /** The files a message takes: the client core's upload limit (`chatAttachmentUploadLimit`). */
        const val MAX_ATTACHMENTS = 8
    }
}
