package surf.comma.android.conversation

import kotlinx.coroutines.flow.StateFlow
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.ConversationScope

/** What the conversation layer needs from the session owner. It never sees the credential. */
interface ConversationSessions {
    /** The current scope, or null while signed out. Each new value is a new generation. */
    val scopes: StateFlow<ConversationScope?>
    /** False once the scope's generation has ended; late responses for it are dropped. */
    fun isCurrent(scope: ConversationScope): Boolean
}

/** The signed-in session as seen by the conversation layer. */
internal class AuthConversationSessions(private val auth: AuthRepository) : ConversationSessions {
    override val scopes get() = auth.conversationScope
    override fun isCurrent(scope: ConversationScope) =
        auth.conversationScope.value === scope && auth.isCurrentGeneration(scope.generation)
}

enum class Connection { IDLE, CONNECTING, LIVE, RECONNECTING, BACKGROUND, PAUSED }

enum class ConversationProblem {
    NETWORK, UNAUTHORIZED, FORBIDDEN, NOT_FOUND, UNSUPPORTED, CONFLICT, INVALID, BILLING, TOO_LARGE, SERVER, STORAGE,
}

/**
 * A conversation as the client core's `chatView` topic says it, read into Kotlin values. Immutable: lists are never
 * changed after publication.
 */
data class ConversationState(
    val groupId: String? = null,
    val conversationId: String? = null,
    val title: String? = null,
    val status: String? = null,
    /** Visible canonical messages, then pending sends, then at most one streaming reply. */
    val timeline: List<TimelineEntry> = emptyList(),
    val participant: ParticipantStatus? = null,
    val activity: ReplyActivity? = null,
    val connection: Connection = Connection.IDLE,
    val problem: ConversationProblem? = null,
    val cacheLoaded: Boolean = false,
    val hasOlder: Boolean = false,
    val loadingOlder: Boolean = false,
    /** Where the next reply stands, as the core reads it for every client. */
    val reply: ReplyState = ReplyState(),
    /** The files the composer's draft holds, as the core uploads them. */
    val attachments: List<DraftAttachment> = emptyList(),
    /** The images each open question card's other answer holds, by the question's message; apart from the draft. */
    val questionAttachments: Map<String, List<DraftAttachment>> = emptyMap(),
    /** Orders this state against the receipt of a call: a receipt's revision is in every later state. */
    val revision: Long = 0,
    /** Identity only, used to reject prepared rows after their account generation ends. */
    internal val scope: ConversationScope? = null,
)

/** Where the conversation's next reply stands (the core's `reply`); see `replyState` in the client core. */
data class ReplyState(
    /** A reply is on its way: a send not yet answered, a wait not timed out, or a reply streaming in. */
    val coming: Boolean = false,
    /** This device's own send waits for its first answer. */
    val thinking: Boolean = false,
    val streaming: Boolean = false,
    /** The agent works on this conversation. */
    val working: Boolean = false,
    /** The agent stopped with an error. */
    val failed: Boolean = false,
    val timedOut: Boolean = false,
) {
    /** Something is on its way for this conversation: the typing bubble shows. */
    val pending: Boolean get() = (coming || working) && !failed
}

/** [key] is stable across a pending send becoming its canonical message. */
sealed interface TimelineEntry {
    val key: String
    data class Message(override val key: String, val message: ChatMessage) : TimelineEntry
    data class Pending(override val key: String, val pending: PendingMessage) : TimelineEntry
    data class Draft(override val key: String, val draft: ReplyDraft) : TimelineEntry
    /**
     * Messages the server has that this device has not read yet, between the history already
     * shown above and the newest messages below. It goes away once paging fills it.
     */
    data class Gap(override val key: String) : TimelineEntry
}

enum class ChatRole { USER, ASSISTANT }

data class ChatMessage(
    val messageId: String,
    /** The message's place in its conversation; 0 when the server gave none. */
    val seq: Long,
    val role: ChatRole,
    val actorType: String,
    val agentId: String?,
    val clientRequestId: String?,
    val replyToMessageId: String?,
    val threadRootMessageId: String?,
    val createdAt: Long?,
    /** Display parts in original block order. */
    val parts: List<MessagePart>,
    val attachments: List<MessageAttachment>,
    val refs: List<ConversationRef>,
    /** Workspace files the person's message names, as the core read them out of its text. */
    val workspaceFiles: List<WorkspaceFile>,
    /** The instructions a task works from (its brief, or a meeting's saved recording), as the core says. */
    val brief: Boolean = false,
    /** The tasks an agent's message announces, each once, as the core names them; a person's mention is none. */
    val createdTaskIds: List<String> = emptyList(),
    /** An agent's message as the core parsed it (`@comma/core/markdown`'s tree, as JSON); null for anything else. */
    val markdown: String? = null,
)

sealed interface MessagePart {
    data class SetupOffer(val offer: surf.comma.android.settings.devices.DeviceSetupOffer) : MessagePart
    data class Text(val text: String) : MessagePart
    /** Inline task reference. [conversationId] is null when [unavailable]. */
    data class TaskChip(
        val conversationId: String?,
        val title: String?,
        val status: String?,
        val activityStatus: String?,
        val unavailable: Boolean,
    ) : MessagePart
    /** Interactive content is shown as its summary only; null means show an "unavailable" label. */
    data class InteractiveSummary(
        val summary: String?,
        val uiRef: String?,
        val version: Long?,
        val originTaskId: String?,
        val blockIndex: Int,
    ) : MessagePart
    /** An Agent's question: a card of its own after the message's text, never part of its Markdown. */
    data class Question(val question: AgentQuestion) : MessagePart
}

data class BlobRef(val uuid: String, val hash: String, val size: Long)

data class MessageAttachment(
    /** `image` or `file`. */
    val blockType: String,
    /** The attachment's place in its message, as the attachment endpoint expects; negative when it cannot be served. */
    val blockIndex: Int,
    val fileName: String?,
    val title: String?,
    val mimeType: String?,
    val size: Long?,
    val workspacePath: String?,
    /** Pixel size when the block declares one; lets the list reserve the right shape. */
    val widthPx: Int?,
    val heightPx: Int?,
    val blobRef: BlobRef?,
    val agentId: String?,
    /** True when the per-message attachment endpoint can serve this block. */
    val downloadable: Boolean,
)

data class ConversationRef(
    val conversationId: String,
    val kind: String?,
    val title: String?,
    val status: String?,
    val activityStatus: String?,
)

data class WorkspaceFile(
    val name: String,
    val path: String,
    val mimeType: String? = null,
    val size: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
)

/**
 * A model mention in a person's words, `[GPT 5.5 · high](comma:model/<id>?effort=high)`: the client core's pattern
 * (`modelMentionMatches`), which is what the server starts a Task with. The core shows a sent message's mentions as
 * `@name`; [asWords] does the same for the words it hands over as written (a message still sending).
 */
object ModelMentionLinks {
    const val PREFIX = "comma:model/"
    /** Groups: the name shown, the model id, the thinking effort (empty for the model's default). */
    val PATTERN = Regex("\\[([^\\]\\n]{1,200})\\]\\(comma:model/([A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}?)(?:\\?effort=([a-z_]{1,32}))?\\)")

    fun asWords(text: String): String = if (PREFIX !in text) text else PATTERN.replace(text) { "@${it.groupValues[1]}" }
}

enum class PendingStatus { SENDING, FAILED }

data class PendingMessage(
    val clientRequestId: String,
    /** What the user wrote, without the manifest of [workspaceFiles]. */
    val text: String,
    val workspaceFiles: List<WorkspaceFile>,
    val replyToMessageId: String?,
    val createdAt: Long,
    val status: PendingStatus,
    /** Why the send failed, in the app's language, when the core said. */
    val error: String? = null,
    /** The send failed for lack of funds: the way on is billing, not another try. */
    val billing: Boolean = false,
)

enum class DraftAttachmentStatus { UPLOADING, UPLOADED, FAILED }

/** One file of the composer's draft. [path] is its place in the workspace once uploaded. */
data class DraftAttachment(
    val id: String,
    val name: String,
    val size: Long,
    val status: DraftAttachmentStatus,
    val path: String? = null,
    val error: String? = null,
)

data class ReplyDraft(
    val responseKey: String,
    val sourceMessageIds: List<String>,
    val draftId: String,
    val revision: Long?,
    val text: String,
    /** The server ended the draft; the text stays until the canonical message replaces it. */
    val ended: Boolean,
) {
    val key: String get() = draftKey(responseKey, sourceMessageIds)
}

internal fun draftKey(responseKey: String, sourceMessageIds: List<String>) =
    "d:${responseKey.length}:$responseKey:${sourceMessageIds.joinToString("\u0000")}"

data class ParticipantStatus(
    val participantId: String,
    /** `active`, `error` or `stopped`. */
    val state: String,
    /** Server-provided display text; never parsed for meaning. */
    val status: String?,
    val issue: String?,
    val workingProvider: String?,
    val updatedAt: Long?,
    /** Active only because the agent's own loop woke it, not because anyone wrote to it. */
    val loopWake: Boolean = false,
)

data class ReplyActivity(
    val responseKey: String,
    val sourceMessageIds: List<String>,
    val phase: String,
    val status: String,
    val summaryClass: String,
    val summary: String?,
    val toolName: String?,
)
