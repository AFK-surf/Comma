package surf.comma.android.ui.composer

/** Upload progress of one attachment. The composer only displays it; the host drives it. */
sealed interface AttachmentUploadState {
    data object Pending : AttachmentUploadState
    /** [progress] in 0..1, or null when the uploader cannot tell. */
    data class Uploading(val progress: Float? = null) : AttachmentUploadState
    data object Failed : AttachmentUploadState
    data object Done : AttachmentUploadState
}

/** The single button at the trailing edge of the input row. */
enum class TrailingAction { MIC, SEND }

/** Which voice interaction owns the composer, if any. */
enum class VoiceMode { NONE, DICTATION, HOLD }

/**
 * The composer's state, free of Android types so every transition is unit-testable.
 * The view renders from it and forwards user intent to it; nothing else mutates it.
 */
class ComposerModel(
    val maxAttachments: Int = MAX_ATTACHMENTS,
    private val newId: () -> String,
) {
    data class Slot(val id: String, val state: AttachmentUploadState)

    /** Outcome of asking to start a voice interaction. */
    enum class VoiceStart { STARTED, UNAVAILABLE, IGNORED }

    var text: String = ""
        private set
    private val slots = ArrayList<Slot>()
    val attachments: List<Slot> get() = slots

    var generating: Boolean = false
        private set
    var voiceAvailable: Boolean = false

    var voice: VoiceMode = VoiceMode.NONE
        private set

    val remainingSlots: Int get() = maxAttachments - slots.size
    val hasContent: Boolean get() = text.isNotBlank() || slots.isNotEmpty()
    val uploadsSettled: Boolean get() = slots.all { it.state == AttachmentUploadState.Done }

    /**
     * Send stays visible while a reply generates. An empty, idle composer offers the microphone.
     */
    val trailingAction: TrailingAction
        get() = when {
            hasContent || generating -> TrailingAction.SEND
            else -> TrailingAction.MIC
        }

    /** Send is enabled with content once every upload has finished, whether or not a reply generates. */
    val canSend: Boolean
        get() = voice == VoiceMode.NONE && hasContent && uploadsSettled

    fun updateText(value: String) {
        text = value
    }

    fun setGenerating(value: Boolean) {
        generating = value
    }

    /**
     * Adds up to [remainingSlots] attachments and returns the new ids, in order.
     * Anything past the limit is dropped; the caller reports how many.
     */
    fun addAttachments(count: Int): List<String> {
        val accepted = count.coerceAtMost(remainingSlots).coerceAtLeast(0)
        return List(accepted) { newId() }.onEach { slots += Slot(it, AttachmentUploadState.Pending) }
    }

    fun removeAttachment(id: String): Boolean = slots.removeAll { it.id == id }

    fun setAttachmentState(id: String, state: AttachmentUploadState): Boolean {
        val index = slots.indexOfFirst { it.id == id }
        if (index < 0) return false
        slots[index] = slots[index].copy(state = state)
        return true
    }

    /** Dictation fills the input; it is allowed while a reply is generating. */
    fun beginDictation(): VoiceStart = beginVoice(VoiceMode.DICTATION)

    /** Hold-to-talk sends on release; like a typed send it is allowed while a reply generates. */
    fun beginHold(): VoiceStart = beginVoice(VoiceMode.HOLD)

    private fun beginVoice(mode: VoiceMode): VoiceStart {
        if (voice != VoiceMode.NONE) return VoiceStart.IGNORED
        if (mode == VoiceMode.HOLD && hasContent) return VoiceStart.IGNORED
        if (!voiceAvailable) return VoiceStart.UNAVAILABLE
        voice = mode
        return VoiceStart.STARTED
    }

    /**
     * Ends dictation. With [transcript] it is inserted into the text at [selectionStart] ..
     * [selectionEnd]; returns the new text and caret, or null when there was nothing to insert.
     */
    fun endDictation(transcript: String?, selectionStart: Int, selectionEnd: Int): Insertion? {
        if (voice != VoiceMode.DICTATION) return null
        voice = VoiceMode.NONE
        val words = transcript?.trim().orEmpty()
        if (words.isEmpty()) return null
        return insert(words, selectionStart, selectionEnd).also { text = it.text }
    }

    /** Ends hold-to-talk; returns the text to send, or null when cancelled or silent. */
    fun endHold(transcript: String?, cancelled: Boolean): String? {
        if (voice != VoiceMode.HOLD) return null
        voice = VoiceMode.NONE
        if (cancelled) return null
        return transcript?.trim()?.takeIf { it.isNotEmpty() }
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
    data class Insertion(val text: String, val caret: Int)

    private fun insert(words: String, selectionStart: Int, selectionEnd: Int): Insertion {
        val start = selectionStart.coerceIn(0, text.length)
        val end = selectionEnd.coerceIn(start, text.length)
        val before = text.substring(0, start)
        val after = text.substring(end)
        // Space-separated scripts need a gap; CJK text does not.
        val lead = if (before.isNotEmpty() && needsSpace(before.last(), words.first())) " " else ""
        val trail = if (after.isNotEmpty() && needsSpace(words.last(), after.first())) " " else ""
        val inserted = lead + words + trail
        return Insertion(before + inserted + after, before.length + inserted.length)
    }

    private fun needsSpace(left: Char, right: Char): Boolean =
        !left.isWhitespace() && !right.isWhitespace() && !left.isCjk() && !right.isCjk()

    private fun Char.isCjk(): Boolean {
        val block = Character.UnicodeBlock.of(this)
        return block == Character.UnicodeBlock.CJK_UNIFIED_IDEOGRAPHS ||
            block == Character.UnicodeBlock.CJK_SYMBOLS_AND_PUNCTUATION ||
            block == Character.UnicodeBlock.HALFWIDTH_AND_FULLWIDTH_FORMS ||
            block == Character.UnicodeBlock.HIRAGANA ||
            block == Character.UnicodeBlock.KATAKANA ||
            block == Character.UnicodeBlock.HANGUL_SYLLABLES
    }

    companion object {
        /** The files a message takes: the client core's upload limit (`chatAttachmentUploadLimit`). */
        const val MAX_ATTACHMENTS = 8
    }
}
