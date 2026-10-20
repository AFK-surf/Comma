package surf.comma.android.conversation

import org.json.JSONArray
import org.json.JSONObject

/**
 * An Agent's question, as the client core reads it out of the Agent's message (its `question` part): what is asked,
 * the choices, and where the card stands. The core keeps the state; the card only shows it and answers.
 */
data class AgentQuestion(
    /** The Agent message that asks; the answer replies to it. */
    val messageId: String,
    val prompt: String,
    /** Two to six, in the order the Agent gave them. */
    val choices: List<QuestionChoice>,
    val multiSelect: Boolean,
    val allowOther: Boolean,
    val state: QuestionState,
) {
    /** The choice a single-select card starts on; null for a multi-select card or when none is recommended. */
    val recommended: String? get() = if (multiSelect) null else choices.firstOrNull { it.recommended }?.id

    /** The core's own JSON of the part, read back by [parse]. */
    fun json(): JSONObject = JSONObject().put("kind", "question").put("messageId", messageId).put("prompt", prompt)
        .put("choices", JSONArray(choices.map { choice ->
            JSONObject().put("id", choice.id).put("label", choice.label).apply {
                choice.description?.let { put("description", it) }
                choice.reply?.let { put("reply", it) }
                if (choice.recommended) put("recommended", true)
            }
        }))
        .put("multiSelect", multiSelect).put("allowOther", allowOther)
        .put("state", JSONObject().put("status", state.status.wire).apply {
            if (state.choiceIds.isNotEmpty()) put("choiceIds", JSONArray(state.choiceIds))
            state.other?.let { put("other", it) }
            state.error?.let { put("error", it) }
        })

    companion object {
        /** Null for anything the core would not have made a card of. */
        fun parse(json: JSONObject?): AgentQuestion? {
            json ?: return null
            val messageId = json.string("messageId") ?: return null
            val prompt = json.string("prompt") ?: return null
            val listed = json.optJSONArray("choices") ?: return null
            val choices = (0 until listed.length()).mapNotNull { index ->
                val choice = listed.optJSONObject(index) ?: return@mapNotNull null
                QuestionChoice(
                    id = choice.string("id") ?: return@mapNotNull null,
                    label = choice.string("label") ?: return@mapNotNull null,
                    description = choice.string("description"),
                    reply = choice.string("reply"),
                    recommended = choice.optBoolean("recommended"),
                )
            }
            if (choices.size != listed.length() || choices.size !in 2..6 || choices.distinctBy { it.id }.size != choices.size) return null
            val state = json.optJSONObject("state") ?: return null
            val status = QuestionStatus.entries.firstOrNull { it.wire == state.optString("status") } ?: return null
            val picked = state.optJSONArray("choiceIds")
            return AgentQuestion(
                messageId = messageId, prompt = prompt, choices = choices,
                multiSelect = json.optBoolean("multiSelect"), allowOther = json.optBoolean("allowOther"),
                state = QuestionState(
                    status = status,
                    choiceIds = if (picked == null) emptyList() else (0 until picked.length()).mapNotNull { picked.opt(it) as? String },
                    // The other answer as written, blanks included: it is what the person had in the field.
                    other = state.opt("other") as? String,
                    error = state.string("error"),
                ),
            )
        }
    }
}

data class QuestionChoice(
    val id: String,
    val label: String,
    val description: String? = null,
    /** What the answer says for the person when this is the one pick; the label when absent. */
    val reply: String? = null,
    val recommended: Boolean = false,
)

/**
 * Where a question card stands: still open, being answered from this device (or that answer failed), answered on
 * the card, skipped, answered by writing in the chat, or replaced by a later question before any answer.
 */
enum class QuestionStatus(val wire: String) {
    OPEN("open"), SENDING("sending"), FAILED("failed"), ANSWERED("answered"), SKIPPED("skipped"),
    REPLIED("replied"), REPLACED("replaced");

    /** The card takes an answer: open, or open again after this device's answer failed. */
    val answerable: Boolean get() = this == OPEN || this == FAILED
}

data class QuestionState(
    val status: QuestionStatus,
    /** The choices the answer picked, when it was given on the card. */
    val choiceIds: List<String> = emptyList(),
    /** The other answer's text, when it was given on the card. */
    val other: String? = null,
    /** Why this device's answer was not sent. */
    val error: String? = null,
)
