package surf.comma.android.chat.live

import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.conversation.AgentQuestion
import surf.comma.android.conversation.DraftAttachment
import surf.comma.android.conversation.DraftAttachmentStatus
import surf.comma.android.conversation.QuestionStatus

/** What this device knows of the question cards' images beyond the core's rows for them. */
data class QuestionImagesShown(
    /** A local preview (content URI) of each image this device added, by the card's row id for it. */
    val previews: Map<String, String> = emptyMap(),
    /** Images being made ready on this device and not handed to the core yet, by question. */
    val preparing: Map<String, Int> = emptyMap(),
)

/** One image of a card's other answer: the core's row for it, and this device's preview when it added it. */
internal data class QuestionImage(
    val id: String,
    val name: String,
    val status: DraftAttachmentStatus,
    val preview: String? = null,
)

/**
 * A question row's payload ([LiveRowKinds.QUESTION]): the question as the core reads it and the images its other
 * answer holds. Everything the card draws is in it, so a change to any of it lays the row out again.
 */
internal data class QuestionCardPayload(
    val question: AgentQuestion,
    val images: List<QuestionImage> = emptyList(),
    /** Images being made ready on this device, not yet the core's rows. */
    val preparing: Int = 0,
) {
    /** Images the other answer holds or is about to. */
    val imageCount: Int get() = images.size + preparing
    val uploading: Boolean get() = preparing > 0 || images.any { it.status == DraftAttachmentStatus.UPLOADING }
    val uploadFailed: Boolean get() = images.any { it.status == DraftAttachmentStatus.FAILED }

    fun encode(): String = JSONObject().put("question", question.json())
        .put("images", JSONArray(images.map { image ->
            JSONObject().put("id", image.id).put("name", image.name).put("status", image.status.name)
                .apply { image.preview?.let { put("preview", it) } }
        }))
        .put("preparing", preparing)
        .toString()

    companion object {
        fun of(question: AgentQuestion, rows: List<DraftAttachment>, shown: QuestionImagesShown) = QuestionCardPayload(
            question,
            rows.map { QuestionImage(it.id, it.name, it.status, shown.previews[it.id]) },
            shown.preparing[question.messageId] ?: 0,
        )

        fun decode(payload: String?): QuestionCardPayload? {
            val json = runCatching { JSONObject(payload ?: return null) }.getOrNull() ?: return null
            val question = AgentQuestion.parse(json.optJSONObject("question")) ?: return null
            val listed = json.optJSONArray("images") ?: JSONArray()
            val images = (0 until listed.length()).mapNotNull { index ->
                val image = listed.optJSONObject(index) ?: return@mapNotNull null
                QuestionImage(
                    id = image.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null,
                    name = image.optString("name"),
                    status = DraftAttachmentStatus.entries.firstOrNull { it.name == image.optString("status") }
                        ?: DraftAttachmentStatus.FAILED,
                    preview = image.optString("preview").takeIf { it.isNotEmpty() },
                )
            }
            return QuestionCardPayload(question, images, json.optInt("preparing").coerceAtLeast(0))
        }
    }
}

/** Why an open card holds its answer back, said under the choices. */
internal enum class QuestionNote { PICK_ONE, PICK_ANY, OTHER_EMPTY, UPLOAD_FAILED, WAIT_UPLOAD }

/** What the card sends: the picks, the other answer when it is chosen, or a skip. */
internal data class QuestionCardAnswer(val choiceIds: List<String>, val other: String?, val skipped: Boolean = false) {
    companion object {
        val SKIP = QuestionCardAnswer(emptyList(), null, skipped = true)
    }
}

/**
 * The person's picks and words on one open card, kept on this device until the answer is sent. A single-select card
 * starts on the recommended choice, a multi-select one with none; after a failed answer it starts on what was sent.
 * Typing or adding an image picks the other answer (a single-select card lets go of its listed pick); emptying the
 * field gives the listed pick back.
 */
internal class QuestionForm(question: AgentQuestion) {
    var question: AgentQuestion = question
        private set
    val multiple: Boolean get() = question.multiSelect
    var picks: List<String>
        private set
    var other: String
        private set
    var otherOn: Boolean
        private set
    var note: QuestionNote? = null
        private set
    /** An answer was asked for while its images upload: it goes once they have. */
    var waitingForUploads = false
        private set
    /** An answer is with the core and has not come back yet. */
    var sending = false
    /** The core took no answer from this card: it shows as failed until the next try. */
    var refused = false
    private var lastPick: String? = question.recommended
    private var imageCount = 0

    init {
        val failed = question.state.status == QuestionStatus.FAILED
        val offered = question.choices.map { it.id }
        picks = if (failed) offered.filter { it in question.state.choiceIds } else listOfNotNull(question.recommended)
        other = if (failed) question.state.other.orEmpty() else ""
        otherOn = failed && question.state.other != null
    }

    /** The card's question as the core reads it now; its choices and kind do not change. */
    fun update(next: AgentQuestion) {
        question = next
    }

    fun choose(id: String) {
        if (question.choices.none { it.id == id }) return
        note = null
        if (!multiple) {
            lastPick = id
            otherOn = false
            picks = listOf(id)
            return
        }
        picks = question.choices.map { it.id }.filter { if (it == id) it !in picks else it in picks }
    }

    /** The other answer's own control: a radio picks it, a box turns it on or off. */
    fun pickOther() {
        note = null
        if (multiple) {
            otherOn = !otherOn
            return
        }
        otherOn = true
        picks = emptyList()
    }

    /** The field changed to [text]. */
    fun write(text: String) {
        if (text == other) return
        note = null
        other = text
        follow(text.isNotBlank() || imageCount > 0)
    }

    /** The field took focus: an answer already in it is picked again. */
    fun focusOther() {
        if (other.isNotBlank() || imageCount > 0) follow(true)
    }

    /** The other answer holds [count] images now (being made ready included); adding one picks it. */
    fun images(count: Int) {
        if (count == imageCount) return
        imageCount = count
        if (count > 0 && !otherOn) follow(true)
    }

    private fun follow(has: Boolean) {
        if (has == otherOn) return
        otherOn = has
        if (multiple) return
        if (has) picks = emptyList() else lastPick?.let { picks = listOf(it) }
    }

    /**
     * The answer to send, or null with [note] saying what is missing. Images still uploading hold it back until
     * [uploading] is false ([waitingForUploads]).
     */
    fun submit(uploading: Boolean, uploadFailed: Boolean): QuestionCardAnswer? {
        val hasOther = other.isNotBlank() || imageCount > 0
        if (picks.isEmpty() && !(otherOn && hasOther)) {
            note = when {
                multiple -> QuestionNote.PICK_ANY
                otherOn -> QuestionNote.OTHER_EMPTY
                else -> QuestionNote.PICK_ONE
            }
            waitingForUploads = false
            return null
        }
        if (otherOn && uploadFailed) {
            note = QuestionNote.UPLOAD_FAILED
            waitingForUploads = false
            return null
        }
        if (otherOn && uploading) {
            note = QuestionNote.WAIT_UPLOAD
            waitingForUploads = true
            return null
        }
        note = null
        waitingForUploads = false
        return QuestionCardAnswer(picks, if (otherOn) other else null)
    }
}

/** The open cards' forms, by question, while the page lives: a card scrolled away and back keeps its picks. */
internal class QuestionForms {
    private val forms = HashMap<String, QuestionForm>()

    fun of(question: AgentQuestion): QuestionForm =
        forms.getOrPut(question.messageId) { QuestionForm(question) }.also { it.update(question) }

    /** The card closed (sent, skipped, answered in the chat): a later failure starts again from what was sent. */
    fun drop(questionMessageId: String) {
        forms.remove(questionMessageId)
    }
}

/** What a question card does on the page that shows it. A page without one shows each card's receipt only. */
internal interface QuestionCardHost {
    val forms: QuestionForms

    /** Sends [answer] to question [questionMessageId]; [done] says on the main thread whether the core took it. */
    fun answer(questionMessageId: String, answer: QuestionCardAnswer, done: (Boolean) -> Unit)

    /** Opens the photo picker for up to [remaining] images of the card's other answer. */
    fun pickImages(questionMessageId: String, remaining: Int)

    /** Images pasted into the card's field. */
    fun addImages(questionMessageId: String, uris: List<Uri>)

    fun removeImage(questionMessageId: String, attachmentId: String)

    fun retryImage(questionMessageId: String, attachmentId: String)
}

/** The words a closed card shows for its question. */
internal class QuestionReceiptLabels(
    val sending: String,
    val skipped: String,
    val replied: String,
    val replaced: String,
)

/** What was answered: the picked choices' labels, then the other answer, joined as one line. */
internal fun questionAnswerLine(question: AgentQuestion): String {
    val labels = question.choices.filter { it.id in question.state.choiceIds }.map { it.label }
    val other = question.state.other?.trim()?.takeIf { it.isNotEmpty() }
    return (labels + listOfNotNull(other)).joinToString("、")
}

/**
 * The receipt's line under the question: the answer while it is sent and once it is, or how the card closed
 * otherwise. Empty for a card still open (a page that cannot answer it shows the question alone).
 */
internal fun questionReceiptLine(question: AgentQuestion, labels: QuestionReceiptLabels): String = when (question.state.status) {
    QuestionStatus.ANSWERED -> questionAnswerLine(question)
    QuestionStatus.SENDING -> questionAnswerLine(question).let { if (it.isEmpty()) labels.sending else "$it · ${labels.sending}" }
    QuestionStatus.SKIPPED -> labels.skipped
    QuestionStatus.REPLIED -> labels.replied
    QuestionStatus.REPLACED -> labels.replaced
    QuestionStatus.OPEN, QuestionStatus.FAILED -> ""
}
