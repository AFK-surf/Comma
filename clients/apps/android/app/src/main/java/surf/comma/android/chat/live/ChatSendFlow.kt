package surf.comma.android.chat.live

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.requestKey
import surf.comma.android.ui.composer.ComposerAttachment
import surf.comma.android.ui.composer.ComposerView
import java.util.UUID
import kotlin.coroutines.resume

/**
 * One send, from the composer through the repository to the list, in this order:
 *
 * 1. hold: the composer still shows the draft; the flight freezes a copy of it.
 * 2. admit: the repository saves the pending message. Its rows may be committed right away;
 *    the flight hides them before they are drawn.
 * 3. complete + accept, in the same frame: the composer clears (its height spring starts) and
 *    the frozen copy stands in for it.
 * 4. With the rows committed and laid out, the list glides to its new end and the pieces fly.
 *
 * Nothing waits for an animation: the request is delivered as soon as it is admitted, and a
 * reply that comes back during the flight is laid out as usual. The chat screen and its device
 * fixture both send through here, so tests exercise this exact order.
 */
internal class ChatSendFlow(
    private val scope: CoroutineScope,
    private val composer: ComposerView,
    private val timeline: ChatTimelineView,
    private val flight: SendFlightView,
    /** The client request id the next draft send will use. */
    private val draftRequestId: () -> String,
    /** Admits the draft with [draftRequestId]; false when it was refused. */
    private val sendDraft: suspend (String, List<ComposerAttachment>) -> Boolean,
    /** Admits a voice message under the given request id; false when it was refused. */
    private val sendVoice: suspend (text: String, requestId: String) -> Boolean,
    private val onRefused: () -> Unit = {},
) {
    private var conversationId: String? = null

    fun bind() {
        composer.onSubmit = { text, attachments, complete ->
            val turn = requestKey(draftRequestId())
            flight.hold(composer.captureSendSnapshot(), turn)
            scope.launch {
                val accepted = try { sendDraft(text, attachments) }
                catch (cancelled: CancellationException) { flight.cancel(turn); throw cancelled }
                catch (_: Exception) { false }
                complete(accepted)
                if (accepted) flight.accept(turn) else {
                    flight.cancel(turn)
                    onRefused()
                }
            }
        }
        composer.onVoiceSend = ::sendVoiceMessage
    }

    /** A voice message. Its bubble is already gone from the composer, so the frozen copy shows at once. */
    private fun sendVoiceMessage(text: String) {
        if (text.isBlank()) return
        val requestId = UUID.randomUUID().toString()
        val turn = requestKey(requestId)
        flight.hold(composer.captureSendSnapshot(), turn)
        flight.accept(turn)
        scope.launch {
            try { if (!sendVoice(text, requestId)) flight.cancel(turn) }
            catch (cancelled: CancellationException) { flight.cancel(turn); throw cancelled }
            catch (error: Exception) { flight.cancel(turn); throw error }
        }
    }

    /** Commits [rows]; a held send finds its rows in the same commit, before they are drawn. */
    suspend fun submit(rows: List<PreparedChatMessage>) {
        suspendCancellableCoroutine { continuation ->
            timeline.submitPrepared(rows) {
                flight.onCommitted(rows)
                if (continuation.isActive) continuation.resume(Unit)
            }
        }
    }

    /** Another conversation is shown: nothing sent from the previous one may fly into it. */
    fun showConversation(id: String?) {
        if (id == conversationId) return
        if (conversationId != null) flight.cancel()
        conversationId = id
    }

    /** The input capsule's top moved to [capsuleTop], in the timeline's coordinates. */
    fun updateBoundary(capsuleTop: Float) {
        timeline.setComposerInset(kotlin.math.round(timeline.height - capsuleTop).toInt())
        flight.invalidate()
    }

    fun release() = flight.cancel()
}
