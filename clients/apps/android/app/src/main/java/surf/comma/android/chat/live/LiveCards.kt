package surf.comma.android.chat.live

import android.content.Context
import android.util.TypedValue
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.messageTextColor
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.TaskRefCardView
import surf.comma.android.tasks.ui.TaskRefDirectory
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.UiSansTypeface

/**
 * A task referenced from a message, as a card as wide as the reply's text. Title and status are the
 * task's canonical summary from the page's [TaskRefDirectory]; until it arrives the card shows the
 * reference's own title and no state, with a quiet glyph. Tapping opens the task through the
 * directory.
 */
internal class TaskRefCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.TASK_REF

    /** A one-line title; pages measure the real height with [surf.comma.android.tasks.ui.TaskRefCardLayout]. */
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = CARD_HEIGHT_DP

    override fun create(context: Context): View = TaskRefRow(context)

    override fun bind(view: View, item: PreparedChatMessage) = (view as TaskRefRow).bind(item)

    private companion object {
        const val CARD_HEIGHT_DP = 70f
    }
}

/** What a task card shows, given what the page's directory knows about its task. */
internal sealed interface TaskRefDisplay {
    /** Not confirmed yet: the reference's own title, if it has one, and no state. */
    data class Loading(val taskId: String, val title: String?) : TaskRefDisplay
    data class Ready(val task: TaskSummary) : TaskRefDisplay
    /** The reference cannot be opened, or the server has no such task. */
    data object Unavailable : TaskRefDisplay
}

internal fun taskRefDisplay(ref: LiveRowKinds.TaskRef, directory: TaskRefDirectory?): TaskRefDisplay {
    val id = ref.conversationId
    if (ref.unavailable || id.isNullOrBlank()) return TaskRefDisplay.Unavailable
    directory?.summary(id)?.let { return TaskRefDisplay.Ready(it) }
    if (directory?.isMissing(id) == true) return TaskRefDisplay.Unavailable
    return TaskRefDisplay.Loading(id, ref.title?.takeIf { it.isNotBlank() })
}

internal class TaskRefRow(context: Context) : FrameLayout(context) {
    val card = TaskRefCardView(context).apply { onOpenTask = { id -> directory?.open(id) } }
    /** Punctuation that followed the reference in the message, set in the message's body type. */
    private val suffix = TextView(context).apply {
        typeface = UiSansTypeface
        includeFontPadding = false
        setTextSize(TypedValue.COMPLEX_UNIT_SP, BODY_TEXT_SP * DesignTypography.chatScale())
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val palette = ChatPalette.from(context)
    private var item: PreparedChatMessage? = null
    private var directory: TaskRefDirectory? = null
    private val refresh: () -> Unit = { render() }

    /** The punctuation shown after the card, for tests. */
    val suffixText: CharSequence get() = if (suffix.visibility == VISIBLE) suffix.text else ""

    init {
        addView(card)
        addView(suffix, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        directory = TaskRefDirectory.find(this)?.also { it.addListener(refresh) }
        render()
    }

    override fun onDetachedFromWindow() {
        directory?.removeListener(refresh)
        directory = null
        super.onDetachedFromWindow()
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        val punctuation = LiveRowKinds.decodeTask(item.message.cardPayload).suffix
        suffix.text = punctuation
        suffix.visibility = if (punctuation.isEmpty()) GONE else VISIBLE
        suffix.setTextColor(messageTextColor(item.message.role, palette))
        render()
        requestLayout()
    }

    /** The row's height is fixed by the layout pass, so a new title or state never moves the list. */
    private fun render() {
        val current = item ?: return
        when (val display = taskRefDisplay(LiveRowKinds.decodeTask(current.message.cardPayload), directory)) {
            is TaskRefDisplay.Ready -> card.bind(display.task)
            is TaskRefDisplay.Loading ->
                card.bindPlaceholder(display.taskId, display.title ?: context.getString(R.string.chat_task_ref))
            TaskRefDisplay.Unavailable -> card.bindPlaceholder(null, context.getString(R.string.chat_task_unavailable))
        }
    }

    /**
     * The card takes the text column less the punctuation, which is measured first and follows
     * the card on its status line, so it never starts a line of its own.
     */
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val current = item
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = current?.cellHeightPx ?: 0
        setMeasuredDimension(width, height)
        val unbounded = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        if (suffix.visibility == VISIBLE) suffix.measure(unbounded, unbounded)
        val suffixWidth = if (suffix.visibility == VISIBLE) suffix.measuredWidth else 0
        val side = current?.sideMarginPx ?: 0
        val cardWidth = (width - side * 2 - suffixWidth).coerceAtLeast(0)
        val cardHeight = (height - (current?.topMarginPx ?: 0)).coerceAtLeast(0)
        card.measure(MeasureSpec.makeMeasureSpec(cardWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(cardHeight, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val top = current.topMarginPx
        val suffixWidth = if (suffix.visibility == VISIBLE) suffix.measuredWidth else 0
        val left = if (current.message.role == ChatRole.USER) {
            width - current.sideMarginPx - card.measuredWidth - suffixWidth
        } else {
            current.sideMarginPx
        }
        card.layout(left, top, left + card.measuredWidth, top + card.measuredHeight)
        if (suffixWidth > 0) {
            // On the card's status line, sharing its baseline.
            val suffixTop = top + card.metaBaseline - suffix.baseline
            suffix.layout(card.right, suffixTop, card.right + suffixWidth, suffixTop + suffix.measuredHeight)
        }
    }

    private companion object {
        /** The message body size before the chat scale; see MessageLayoutPrecomputer. */
        const val BODY_TEXT_SP = 16f
    }
}
