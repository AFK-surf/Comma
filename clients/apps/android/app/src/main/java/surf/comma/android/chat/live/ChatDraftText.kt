package surf.comma.android.chat.live

import android.text.SpannableStringBuilder
import android.widget.EditText
import androidx.core.widget.doAfterTextChanged
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.ConversationState

/**
 * The composer's text as the draft of the conversation shown, which the client core keeps per account and
 * conversation, on the device too, as on iOS and the desktop. An edit goes to the core [SAVE_MS] after the last one
 * ([ChatView.editDraft]), with each mention as its link. Once the conversation has loaded, the field takes the core's
 * draft, with anything typed before then after it. Another conversation or account shown empties the field until its
 * own draft arrives. A send consumes the core's draft; the composer empties the field with it.
 */
internal class ChatDraftText(
    private val field: EditText,
    private val repository: ChatView,
    private val menu: TriggerMenu,
    scope: CoroutineScope,
    /** The field stopped being [shown]'s: what was on its way to that draft goes nowhere. */
    private val onLeft: () -> Unit = {},
) {
    /** The conversation whose draft the field holds. */
    private var shown: Pair<ConversationScope, String>? = null
    /** Whether the field took [shown]'s draft from the core; edits go to the core only after. */
    private var restored = false
    /** Set while the field's text is changed here rather than by the person. */
    private var applying = false
    private val save = Runnable { repository.saveDraft() }
    private val following: Job

    init {
        field.doAfterTextChanged { edited() }
        following = scope.launch(Dispatchers.Main.immediate) {
            combine(repository.state, repository.draftEdits) { state, edits -> state to (edits == 0) }
                .collect { (state, settled) -> show(state, settled) }
        }
    }

    private fun show(state: ConversationState, settled: Boolean) {
        val conversation = state.scope?.let { scope -> state.conversationId?.let { scope to it } }
        if (conversation != shown) {
            // The text was the previous conversation's, and went to the core as its draft.
            if (shown != null) {
                onLeft()
                field.removeCallbacks(save)
                menu.forgetMentions()
                put("")
            }
            shown = conversation
            restored = false
        }
        // Each edit made here is in the state first, so it is not put back older than it was typed.
        val saved = state.draft ?: return
        if (conversation == null || restored || !settled) return
        restored = true
        val typed = SpannableStringBuilder(field.text)
        val draft = menu.project(saved)
        if (typed.isEmpty() || typed.toString() == draft.toString()) return put(draft)
        put(SpannableStringBuilder(draft).apply { if (isNotEmpty()) append("\n\n") }.append(typed))
        edited()
    }

    /** Puts [text] in the field with the caret at its end, as the person left it; it opens no menu. */
    private fun put(text: CharSequence) {
        applying = true
        try {
            field.setText(text)
            field.setSelection(field.length())
        } finally {
            applying = false
        }
        menu.dismiss()
    }

    private fun edited() {
        if (applying || !restored) return
        // The text is [shown]'s: the view may show another conversation already, which the field has not taken yet.
        val (scope, conversationId) = shown ?: return
        repository.editDraft(scope, conversationId, menu.serialize(field.text.toString()))
        field.removeCallbacks(save)
        field.postDelayed(save, SAVE_MS)
    }

    /** The screen ends: the last edit goes to the core now. */
    fun release() {
        following.cancel()
        field.removeCallbacks(save)
        repository.saveDraft()
    }

    private companion object {
        /** How long typing rests before the draft goes to the core, as on iOS. */
        const val SAVE_MS = 400L
    }
}
