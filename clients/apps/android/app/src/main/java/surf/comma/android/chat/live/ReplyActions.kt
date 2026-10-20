package surf.comma.android.chat.live

import android.content.Context
import android.content.res.ColorStateList
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.ui.composer.ButtonScale

/**
 * What the buttons under a finished reply can do, in the order they are shown. Adding share or
 * retry is a new entry here and a branch where the chat handles [ReplyActionsRow.onAction].
 */
internal enum class ReplyAction(val icon: Int, val label: Int, val doneIcon: Int? = null) {
    COPY(R.drawable.ic_chat_copy, R.string.chat_reply_copy, doneIcon = R.drawable.ic_composer_check),
}

/** The row of small icon buttons under a finished reply; see [LiveRowKinds.REPLY_ACTIONS]. */
internal class ReplyActionsCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.REPLY_ACTIONS
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = REPLY_ACTIONS_HEIGHT_DP
    override fun create(context: Context): View = ReplyActionsRow(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as ReplyActionsRow).bind(item)
}

/** The same height, blank, while the reply is on its way. */
internal class ReservedReplyActionsRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.REPLY_ACTIONS_RESERVED
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = REPLY_ACTIONS_HEIGHT_DP
    override fun create(context: Context): View = ReservedRow(context)
    override fun bind(view: View, item: PreparedChatMessage) {
        (view as ReservedRow).heightPx = item.cellHeightPx
    }
}

/** Button height: a 20 dp glyph in a 36 dp target, like the other small icon buttons. */
private const val REPLY_ACTIONS_HEIGHT_DP = 36f

private class ReservedRow(context: Context) : View(context) {
    var heightPx = 0
        set(value) {
            if (field == value) return
            field = value
            requestLayout()
        }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), heightPx)
}

/**
 * The buttons, left-aligned so the first glyph lines up with the reply's text. A button whose
 * action succeeded shows its done glyph (Copy turns into a check mark) for [DONE_MS]; there is
 * no toast, since the system confirms a copy itself from Android 13.
 */
internal class ReplyActionsRow(context: Context) : FrameLayout(context) {
    /** Runs [ReplyAction] for the reply; returns whether it happened, which shows the done glyph. */
    var onAction: ((ReplyAction, PreparedChatMessage) -> Boolean)? = null

    private val density = resources.displayMetrics.density
    private val buttons = ReplyAction.entries.map { action -> ActionButton(context, action) }
    private var item: PreparedChatMessage? = null
    private var done: ActionButton? = null
    private val clearDone = Runnable { done?.showDone(false); done = null }
    // Not View.postDelayed, which holds its callbacks until the view is attached.
    private val clock = Handler(Looper.getMainLooper())

    init {
        buttons.forEach { button ->
            addView(button, LayoutParams(dp(BUTTON_DP), dp(BUTTON_DP)))
            button.setOnClickListener {
                val current = item ?: return@setOnClickListener
                if (onAction?.invoke(button.action, current) == true && button.action.doneIcon != null) {
                    clock.removeCallbacks(clearDone)
                    done?.showDone(false)
                    done = button
                    button.showDone(true)
                    clock.postDelayed(clearDone, DONE_MS)
                }
            }
        }
    }

    fun bind(item: PreparedChatMessage) {
        // A recycled row that was showing a check mark for another reply starts clean.
        if (this.item?.message?.id != item.message.id) {
            clock.removeCallbacks(clearDone)
            clearDone.run()
        }
        this.item = item
        requestLayout()
    }

    override fun onDetachedFromWindow() {
        clock.removeCallbacks(clearDone)
        clearDone.run()
        super.onDetachedFromWindow()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.makeMeasureSpec(dp(BUTTON_DP), MeasureSpec.EXACTLY)
        buttons.forEach { it.measure(size, size) }
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), item?.cellHeightPx ?: 0)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        // The glyph, not the touch target, sits on the text's left edge.
        var left = current.sideMarginPx - dp(BUTTON_DP - ICON_DP) / 2
        buttons.forEach { button ->
            button.layout(left, current.topMarginPx, left + button.measuredWidth, current.topMarginPx + button.measuredHeight)
            left += button.measuredWidth
        }
    }

    private fun dp(value: Int) = (value * density).toInt()

    // Tinted here in code, on platform widgets like the composer's icon buttons.
    @android.annotation.SuppressLint("AppCompatCustomView")
    private class ActionButton(context: Context, val action: ReplyAction) : ImageView(context) {
        // Nullable: the platform constructor may touch pressed state before this class initialises.
        private var scale: ButtonScale? = null
        private val label = context.getString(action.label)

        init {
            setImageResource(action.icon)
            imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_fg_quaternary))
            scaleType = ScaleType.FIT_CENTER
            val inset = ((BUTTON_DP - ICON_DP) * resources.displayMetrics.density / 2).toInt()
            setPadding(inset, inset, inset, inset)
            contentDescription = label
            isClickable = true
            isFocusable = true
        }

        fun showDone(value: Boolean) {
            setImageResource(if (value) action.doneIcon ?: action.icon else action.icon)
            contentDescription = if (value) context.getString(R.string.copied) else label
        }

        override fun setPressed(pressed: Boolean) {
            val changed = pressed != isPressed
            super.setPressed(pressed)
            if (!changed) return
            // Made on the first press: most rows are scrolled past without one.
            val scale = scale ?: ButtonScale(this, action = true).also { scale = it }
            scale.setPressed(pressed)
        }
    }

    private companion object {
        const val BUTTON_DP = 36
        const val ICON_DP = 20
        const val DONE_MS = 2_000L
    }
}
