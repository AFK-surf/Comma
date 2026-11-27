package surf.comma.android.chat.model

enum class ChatRole {
    USER,
    AGENT,
    SYSTEM;

    companion object {
        fun fromStorage(value: String): ChatRole =
            entries.firstOrNull { it.name == value } ?: SYSTEM
    }
}

enum class MessageStatus {
    PENDING,
    STREAMING,
    COMPLETED,
    FAILED;

    val isActive: Boolean
        get() = this == PENDING || this == STREAMING

    companion object {
        fun fromStorage(value: String): MessageStatus =
            entries.firstOrNull { it.name == value } ?: COMPLETED
    }
}

enum class MessageSource {
    VOICE;

    companion object {
        fun fromStorage(value: String?): MessageSource? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * 一次会话。标题取第一条用户消息的开头，会话本身在第一条消息落库时才创建，
 * 所以「打开 app 但没说话」不会留下空会话。
 */
data class Conversation(
    val id: String,
    val title: String,
    val createdAt: Long,
    val updatedAt: Long,
    /**
     * The kinds of device that have spoken in it (`phone`, `mac`), as Core last listed them;
     * empty when Core has not said. A label for the list, see [DeviceOrigin].
     */
    val deviceKinds: List<String> = emptyList(),
)

/** Displayed dimensions known before local-image decoding; Cue persistence is deferred to P4. */
data class ImageDimensions(val widthPx: Int, val heightPx: Int) {
    init { require(widthPx > 0 && heightPx > 0) }
}

/**
 * 一条消息。
 *
 * [id] 是 SQLite 的 rowid，不是内存计数器——RecyclerView 的 stable id 直接用它，
 * 进程重启后同一条消息还是同一个 id，列表不会整体重建。
 *
 * [text] 在流式过程中是**增长的**：transport 每吐一段就换一个更长的 text。
 * 这里刻意不再保留「全文 + 已送达字符数」那套，因为真 SSE 下根本拿不到全文，
 * 提前把渲染路径按拿得到全文来设计，等 Core 换成 SSE 时就得重写。
 */
const val SPEAKER_ROUTER = "router"
const val SPEAKER_WORKER = "worker"
const val SPEAKER_PERSON = "person:"
/** A Task's notice: it sits on the speakers' left edge, right of the avatar gutter, and has no avatar of its own. */
const val SPEAKER_NOTICE = "notice"

data class ChatMessage(
    val id: Long,
    val conversationId: String,
    /** A user message and everything the agent does in response share one turn id. */
    val turnId: String = "",
    val role: ChatRole,
    val text: String,
    val createdAt: Long,
    /** Persisted so process death never makes a partial reply look complete. */
    val status: MessageStatus = MessageStatus.COMPLETED,
    val requestId: String? = null,
    /** Human-readable failure/interruption detail; kept outside copyable answer text. */
    val statusDetail: String? = null,
    /** A retry must reuse [requestId]; persisted so process recreation keeps the safe entry point. */
    val retryable: Boolean = false,
    /** 正文上方的图片：相册选的 `content://`、文件路径、URL，或 Core 媒体键。 */
    val imageSource: String? = null,
    val imageDimensions: ImageDimensions? = null,
    /**
     * Core 发来的图片（`image` 事件）。非空时 [imageSource] 就是它的
     * [CoreMediaAttachment.imageSource]——两者一致，渲染路径照旧走 [imageSource]，
     * 而下载、方向、宽高这些只有 Core 媒体才有的事实从这里读。
     *
     * 相册图、Markdown 远程图、`photo.inline` 卡片一律为 null：它们没有 Core 身份，
     * 也因此永远拿不到 Core 的凭据。
     */
    val coreMedia: CoreMediaAttachment? = null,
    /** 结构化卡：`photo.grid` / `calendar.events` / `app.open` / `map.preview`。 */
    val cardKind: String? = null,
    val cardPayload: String? = null,
    val attachment: ChatAttachment? = null,
    /** Grouped image attachments belonging to one message (1..N images rendered by MediaImageGroupView). */
    val attachments: List<ChatAttachment> = emptyList(),
    /** 消息来自哪种输入通道；空值表示普通文字聊天。 */
    val source: MessageSource? = null,
    /**
     * The kind of device that sent this user message (`origin.kind` on Core's stream), or null
     * when Core did not say -- which includes every message this phone sent itself. Written once,
     * when catch-up brings the row in. A label only, see [DeviceOrigin].
     */
    val originKind: String? = null,
    /**
     * An agent's text as the client core parsed it (`@comma/core/markdown`'s tree, as JSON): what the row draws.
     * Null for anything else, drawn as written.
     */
    val markdown: String? = null,
    /** The chat platform a person's message came in from; its bubble takes that platform's colour. */
    val platformSource: String? = null,
    /**
     * In a Task together, the name of another person who wrote this row's message. Their rows sit on the left in
     * the incoming bubble, as an Agent's do (desktop `MessageRow`), on every page; the account's own rows have none.
     */
    val otherWriterName: String? = null,
    /** That person's user id: consecutive rows with the same one are one run of theirs. */
    val otherWriterId: String? = null,
    /** Where their avatar is read (a `files.read` source, as JSON), when People has one. */
    val otherWriterAvatar: String? = null,
    /** The first row of a run of [otherWriterName]'s messages: their name shows over its bubble. */
    val writerLabel: Boolean = false,
    /**
     * In a Task, who says this left-side row: [SPEAKER_ROUTER], [SPEAKER_WORKER], [SPEAKER_PERSON] and the other
     * person's id, or [SPEAKER_NOTICE]. Every such row sits right of the avatar gutter, so their left edges line up
     * (iOS `showsIdentity`); null for the account's own rows and the Router chat, where notices stay centred.
     */
    val speaker: String? = null,
    /** The Participant row that authored this message (splits consecutive worker runs by session). */
    val participantId: String? = null,
    /** The last row of a run of one [speaker]: the speaker's avatar shows in the gutter, level with its foot. */
    val speakerAvatar: Boolean = false,
) {
    /** All image attachments rendered in this row, whether single or grouped. */
    val imageGroup: List<ChatAttachment>
        get() = when {
            attachments.isNotEmpty() -> attachments
            attachment?.display == surf.comma.android.media.AttachmentDisplay.IMAGE -> listOf(attachment)
            else -> emptyList()
        }
}
