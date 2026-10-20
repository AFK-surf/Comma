package surf.comma.android.tasks.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.clipToRoundedBackground
import surf.comma.android.ui.theme.DesignMotion

/**
 * Task detail: a fixed bar with the back button and the task's title, over [messageArea], which
 * the host fills with the chat renderer (the task's status line is the list's first row, so it
 * scrolls away with the messages). [setNotice] shows a line there instead while there are no
 * messages to show; a failed read also offers a retry.
 *
 * The bar matches the settings pages: 56dp tall, a 48dp back button whose glyph sits on the 16dp
 * page gutter. A hairline appears under it once the list has scrolled.
 */
// Built in code only, never inflated from XML.
@android.annotation.SuppressLint("ViewConstructor")
class TaskDetailView(
    context: Context,
    /**
     * The body of the chat's task sheet: a drag handle over the bar instead of a back button,
     * rounded top corners, and no status-bar padding (the sheet places it below the bar).
     */
    private val sheet: Boolean = false,
) : LinearLayout(context) {
    private val theme = TaskTheme(context)
    private val gutter = theme.dpInt(GUTTER_DP)

    private val back = ImageView(context).apply {
        setImageResource(R.drawable.ic_task_back)
        imageTintList = ColorStateList.valueOf(theme.textPrimary)
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        val pad = theme.dpInt(12f)
        setPadding(pad, pad, pad, pad)
        contentDescription = context.getString(R.string.task_action_back)
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        clipToRoundedBackground(theme.dp(24f))
        setOnClickListener { onBack?.invoke() }
    }

    /** The task's title, one line. */
    val title = TextView(context).apply {
        theme.applyTo(this, TaskType.barTitle, theme.textPrimary)
        maxLines = 1
        isSingleLine = true
        ellipsize = TextUtils.TruncateAt.END
        isAccessibilityHeading = true
    }

    /** Under the bar; shown while the list is scrolled away from its top. */
    val hairline = View(context).apply {
        setBackgroundColor(theme.borderPrimary)
        alpha = 0f
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private val notice = TextView(context).apply {
        theme.applyTo(this, TaskType.meta, theme.textQuaternary)
        gravity = Gravity.CENTER
        maxLines = 3
        ellipsize = TextUtils.TruncateAt.END
    }

    /** The retry under a failed read's notice. */
    val retry = TextView(context).apply {
        theme.applyTo(this, TaskType.metaMedium, theme.textPrimary)
        text = context.getString(R.string.task_detail_retry)
        gravity = Gravity.CENTER
        val padH = theme.dpInt(16f)
        val padV = theme.dpInt(8f)
        setPadding(padH, padV, padH, padV)
        minHeight = theme.dpInt(40f)
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        clipToRoundedBackground(theme.dp(20f))
        isVisible = false
        setOnClickListener { onRetry?.invoke() }
    }

    private val noticeColumn = LinearLayout(context).apply {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        addView(notice, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(retry, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = theme.dpInt(12f) })
        isVisible = false
    }

    /** Where the host puts the message list. */
    val messageArea = FrameLayout(context)

    var onBack: (() -> Unit)? = null
    var onRetry: (() -> Unit)? = null

    private var scrolled = false

    init {
        orientation = VERTICAL
        if (sheet) {
            background = GradientDrawable().apply {
                setColor(theme.bgPrimary)
                val radius = theme.dp(SHEET_RADIUS_DP)
                cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
            }
            clipToOutline = true
            val handle = View(context).apply {
                background = GradientDrawable().apply {
                    setColor(theme.borderPrimary)
                    cornerRadius = theme.dp(2f)
                }
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            addView(FrameLayout(context).apply {
                addView(handle, FrameLayout.LayoutParams(theme.dpInt(36f), theme.dpInt(4f), Gravity.CENTER))
            }, LayoutParams(LayoutParams.MATCH_PARENT, theme.dpInt(HANDLE_HEIGHT_DP)))
        } else {
            setBackgroundColor(theme.bgPrimary)
        }
        val bar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            if (sheet) {
                setPadding(gutter, 0, gutter, 0)
                addView(title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            } else {
                setPadding(gutter - theme.dpInt(12f), 0, gutter, 0)
                addView(back, LayoutParams(theme.dpInt(48f), theme.dpInt(48f)))
                addView(title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = theme.dpInt(4f) })
            }
        }
        addView(bar, LayoutParams(LayoutParams.MATCH_PARENT, theme.dpInt(if (sheet) SHEET_BAR_HEIGHT_DP else BAR_HEIGHT_DP)))

        val messages = FrameLayout(context).apply {
            addView(messageArea, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            addView(
                noticeColumn,
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
                    .apply { setMargins(gutter, 0, gutter, 0) },
            )
            addView(hairline, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, 1, Gravity.TOP))
        }
        addView(messages, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(0, if (sheet) 0 else bars.top, 0, bars.bottom)
            insets
        }
    }

    /** A line in the message area, e.g. "No messages yet"; null hides it. [retry] adds a retry. */
    fun setNotice(text: String?, retry: Boolean = false) {
        notice.text = text
        noticeColumn.isVisible = text != null
        this.retry.isVisible = text != null && retry
    }

    /** The task's title; [text] null while it is not known. */
    fun setTitle(text: String?) {
        if (title.text?.toString() != text) title.text = text
    }

    /** Whether the list is away from its top; the hairline fades in or out to match. */
    fun setScrolled(value: Boolean) {
        if (scrolled == value) return
        scrolled = value
        hairline.animate().cancel()
        hairline.animate()
            .alpha(if (value) 1f else 0f)
            .setDuration(DesignMotion.durationMillis(DesignMotion.dialogExit))
            .setInterpolator(DesignMotion.smoothOut)
            .start()
    }

    val isScrolled: Boolean get() = scrolled

    /** In a sheet: the handle and bar, where a drag moves the sheet itself. */
    val gripHeightPx: Int get() = if (sheet) theme.dpInt(HANDLE_HEIGHT_DP + SHEET_BAR_HEIGHT_DP) else 0

    private companion object {
        /** DESIGN §4's page gutter: the back glyph, the status line and the messages share it. */
        const val GUTTER_DP = 16f
        const val BAR_HEIGHT_DP = 56f
        const val HANDLE_HEIGHT_DP = 20f
        /** Under the handle, the bar loses the back button's height. */
        const val SHEET_BAR_HEIGHT_DP = 40f
        const val SHEET_RADIUS_DP = 16f
    }
}
