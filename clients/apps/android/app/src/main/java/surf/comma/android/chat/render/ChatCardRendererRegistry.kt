package surf.comma.android.chat.render

import android.content.Context
import android.view.View
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.live.AgentRequestCardRenderer
import surf.comma.android.chat.live.AttachmentCardRenderer
import surf.comma.android.chat.live.CallLogCardRenderer
import surf.comma.android.chat.live.QuestionCardRenderer
import surf.comma.android.chat.live.ReplyActionsCardRenderer
import surf.comma.android.chat.live.ReservedReplyActionsRenderer
import surf.comma.android.chat.live.TaskRefCardRenderer
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.tasks.ui.TaskInfoCardRenderer

/** 卡片比它所在的行左右各窄 20dp。每个 Cell 的 onMeasure 里都是这个数。 */
internal const val CARD_SIDE_INSET_DP = 40f

/**
 * 卡片的比例：宽 4 高 2。
 *
 * 以前每张卡各写一个高度常量，都是照着「最满的时候」定的，于是常态下就是一张
 * 半空的卡——一屏放不下两张。改成按宽度算，卡片在任何屏宽上都是同一个横向的形
 * 状，行数少的时候还能更矮（见各 Cell 的 bodyHeightDp）。
 *
 * 例外是要给内容留地方的那两类：照片格子和地图，它们的高度由内容本身决定，不
 * 是排版留白。
 */
internal const val CARD_ASPECT_RATIO = 2f

internal fun cardHeightDp(cardWidthDp: Float): Float = cardWidthDp / CARD_ASPECT_RATIO

/**
 * Renderer boundary for structured timeline cards.
 *
 * Markdown, photos and status blocks use [ChatMessageCell]. A renderer is registered only when a
 * card needs a real native view (MapView today; weather and stock can be added without changing
 * ChatTimelineAdapter or the turn ordering code). The body height is known before the view loads,
 * which prevents network/image completion from reflowing the conversation.
 */
internal interface ChatCardRenderer {
    val kind: String
    val viewType: Int

    /** [cardWidthDp] 是卡片自己的宽度，也就是行宽减掉 [CARD_SIDE_INSET_DP]。 */
    fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float

    fun create(context: Context): View
    fun bind(view: View, item: PreparedChatMessage)
    fun release(view: View) = Unit
}

/**
 * Card heights that depend on text, measured ahead of time with the screen's own type. Returns
 * null for a card it does not measure, which then keeps its renderer's fixed height.
 */
fun interface ChatCardHeights {
    fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int?

    /** These heights, and [other]'s for the cards these do not measure. */
    fun then(other: ChatCardHeights): ChatCardHeights = ChatCardHeights { message, rowWidthPx, sideMarginPx ->
        bodyHeightPx(message, rowWidthPx, sideMarginPx) ?: other.bodyHeightPx(message, rowWidthPx, sideMarginPx)
    }
}

internal object ChatCardRendererRegistry {
    const val MESSAGE_VIEW_TYPE = 0
    private const val PHOTO_VIEW_TYPE = 104
    private const val TASK_REF_VIEW_TYPE = 105
    private const val ATTACHMENT_VIEW_TYPE = 106
    private const val REPLY_ACTIONS_VIEW_TYPE = 107
    private const val REPLY_ACTIONS_RESERVED_VIEW_TYPE = 108
    private const val TASK_INFO_VIEW_TYPE = 109
    private const val CALL_LOG_VIEW_TYPE = 110
    private const val QUESTION_VIEW_TYPE = 112
    private const val AGENT_REQUEST_VIEW_TYPE = 113
    private val renderers: List<ChatCardRenderer> = listOf(
        surf.comma.android.settings.devices.DeviceSetupOfferCardRenderer(111),
        PhotoCardRenderer(TimelineBlockKinds.PHOTO_GRID, PHOTO_VIEW_TYPE),
        PhotoCardRenderer(TimelineBlockKinds.INLINE_PHOTO, PHOTO_VIEW_TYPE),
        TaskRefCardRenderer(TASK_REF_VIEW_TYPE),
        AttachmentCardRenderer(ATTACHMENT_VIEW_TYPE),
        ReplyActionsCardRenderer(REPLY_ACTIONS_VIEW_TYPE),
        ReservedReplyActionsRenderer(REPLY_ACTIONS_RESERVED_VIEW_TYPE),
        TaskInfoCardRenderer(TASK_INFO_VIEW_TYPE),
        CallLogCardRenderer(CALL_LOG_VIEW_TYPE),
        QuestionCardRenderer(QUESTION_VIEW_TYPE),
        AgentRequestCardRenderer(AGENT_REQUEST_VIEW_TYPE),
    )

    fun forKind(kind: String?): ChatCardRenderer? =
        kind?.let { value -> renderers.firstOrNull { it.kind == value } }

    fun forViewType(viewType: Int): ChatCardRenderer? =
        renderers.firstOrNull { it.viewType == viewType }

    fun viewTypeFor(kind: String?): Int = forKind(kind)?.viewType ?: MESSAGE_VIEW_TYPE
}

private class PhotoCardRenderer(
    override val kind: String,
    override val viewType: Int,
) : ChatCardRenderer {
    // 照片格子同理：2×2 的图块自己决定高度。
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float =
        PHOTO_CARD_BODY_HEIGHT_DP
    override fun create(context: Context): View = PhotoGridCell(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as PhotoGridCell).bind(item)
    override fun release(view: View) = (view as PhotoGridCell).releaseMedia()
}
