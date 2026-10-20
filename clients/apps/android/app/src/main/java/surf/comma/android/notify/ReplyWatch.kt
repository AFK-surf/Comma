package surf.comma.android.notify

import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry

/**
 * Decides how long a hidden chat keeps receiving, so a reply on its way still reaches the core and the core can word
 * its notice ([AppendedNotice], posted as it comes). Nothing here decides what a notification says.
 *
 * Leaving the chat while a reply is on its way starts a hold of at most [windowMillis]. The hold ends when the reply
 * has landed (nothing pending, no reply text still in place of its message), when the window runs out, when the chat
 * is shown again, when notifications are turned off, or when the account changes. Nothing here touches Android;
 * callers apply [holding].
 */
internal class ReplyWatch(private val windowMillis: Long = WINDOW_MILLIS) {
    var holding = false
        private set
    var deadline: Long? = null
        private set
    var chatVisible = false
        private set
    private var heldScope: ConversationScope? = null

    /** The chat is on screen: whatever is on its way is shown live. */
    fun chatShown() {
        chatVisible = true
        release()
    }

    /** The chat left the screen. Returns true when a hold starts. */
    fun chatHidden(state: ConversationState, now: Long, allowed: Boolean): Boolean {
        chatVisible = false
        val scope = state.scope
        if (!allowed || scope == null || !replyComing(state)) return false
        holding = true
        heldScope = scope
        deadline = now + windowMillis
        return true
    }

    /** A new conversation state: the hold ends once the reply landed, or the state is another account's. */
    fun update(state: ConversationState, now: Long) {
        if (!holding) return
        if (state.scope !== heldScope || expired(now) || !replyComing(state)) release()
    }

    /** The window ran out. Returns true when that ended a hold. */
    fun expire(now: Long): Boolean {
        if (!holding || !expired(now)) return false
        release()
        return true
    }

    /** Notifications were turned off, or the account changed. */
    fun cancel() = release()

    private fun expired(now: Long) = deadline?.let { now >= it } == true

    private fun release() {
        holding = false
        heldScope = null
        deadline = null
    }

    companion object {
        /** How long a hidden chat keeps receiving at most. */
        const val WINDOW_MILLIS = 20 * 60 * 1000L
    }
}

/**
 * A reply is still on its way to the core: a send not yet answered, the agent at work, or a reply's text shown in
 * place of the message that is to replace it (the agent can report itself done before that message lands).
 */
internal fun replyComing(state: ConversationState): Boolean =
    state.reply.pending || state.timeline.any { it is TimelineEntry.Draft }

/** A notification as the core worded it and where it leads. Kept on the device. */
internal data class ReplyNotice(
    val accountId: String,
    val conversationId: String,
    val title: String,
    val body: String,
    /** The timeline key of the message, where tapping the notification scrolls. */
    val entryKey: String,
)

/** The core's notice for one message a conversation gained (`chatAppended`). */
internal data class AppendedNotice(
    val groupId: String,
    val conversationId: String,
    val messageId: String,
    val title: String,
    val body: String,
)
