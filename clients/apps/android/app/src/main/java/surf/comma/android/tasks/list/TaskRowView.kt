package surf.comma.android.tasks.list

import android.animation.ValueAnimator
import android.content.Context
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.kit.AttentionDot
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glyph
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A compact Task row, the same on Home, in Search, in the Archive and in the Inbox: the status glyph and a
 * two-line title, then a pin when pinned and the caller's details (the Inbox's staleness and age). The Inbox's
 * unread dot sits before the glyph in room only it has. The press surface appears the moment a finger lands.
 */
class TaskRowView(context: Context) : FrameLayout(context) {
    private val theme = TaskTheme(context)
    private val unreadSlot = FrameLayout(context)
    private val dot = AttentionDot(context)
    private val status = TaskStatusIconView(context)
    private val title = context.label(Level.REGULAR, R.color.token_text_primary, lines = 2)
    private val pin = context.glyph(R.drawable.ic_action_pin_fill, R.color.token_text_placeholder)
    private val stale = context.label(Level.MINI, R.color.token_fg_attention, surf.comma.android.ui.theme.DesignFonts.medium).apply {
        setText(R.string.task_stale)
    }
    private val age = context.label(Level.MINI, R.color.token_text_tertiary).apply {
        fontFeatureSettings = "tnum"
    }
    private val content = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.TOP
    }
    private val pressFill = rounded(0, context.dp(10).toFloat())
    private val pressColor = ColorUtils.setAlphaComponent(context.getColor(R.color.token_sidebar_item), 179)
    private val scaleX = DesignSpring(content, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val scaleY = DesignSpring(content, DynamicAnimation.SCALE_Y, DesignMotion.springScale)

    var task: TaskSummary? = null
        private set

    init {
        minimumHeight = context.dp(44)
        // Opaque, so a row slid aside covers its swipe actions everywhere else.
        setBackgroundColor(context.getColor(R.color.token_bg_primary))
        isClickable = true
        isFocusable = true
        content.background = pressFill
        content.setPadding(context.dp(10), context.dp(10), context.dp(10), context.dp(10))
        unreadSlot.addView(dot, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER_VERTICAL))
        content.addView(unreadSlot, LinearLayout.LayoutParams(context.dp(AttentionDot.SIZE_DP + 8), context.dp(22)))
        content.addView(status, LinearLayout.LayoutParams(context.dp(18), context.dp(18)).apply { topMargin = context.dp(3) })
        title.ellipsize = TextUtils.TruncateAt.END
        content.addView(title, LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = context.dp(10) })
        val trailing = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(pin, LinearLayout.LayoutParams(context.dp(14), context.dp(14)))
            addView(stale, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = context.dp(6) })
            addView(age, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = context.dp(6) })
        }
        content.addView(trailing, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(24)).apply { marginStart = context.dp(6) })
        addView(content, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }

    /**
     * [unread] is the Inbox's read state (null in lists without one); [age] is the compact age the Inbox shows.
     * [placeholder] draws the row as a grey stand-in while the first page loads.
     */
    fun bind(task: TaskSummary, pinned: Boolean, unread: Boolean? = null, age: String? = null, placeholder: Boolean = false) {
        this.task = task
        unreadSlot.isVisible = unread == true
        dot.isVisible = unread == true
        // Archived rows show the status they were archived from, standing still.
        val bucket = task.listBucket.takeIf { it != TaskStatusBucket.ARCHIVED } ?: TaskStatusBucket.IN_PROGRESS
        status.setStatus(bucket, if (placeholder) theme.borderPrimary else tint(bucket), spin = !task.isArchived && !placeholder)
        title.text = task.title.ifBlank { context.getString(R.string.task_title_fallback) }
        if (placeholder) {
            title.setTextColor(0)
            title.background = rounded(theme.bgTertiary, context.dp(6).toFloat())
        } else {
            title.setTextColor(theme.textPrimary)
            title.background = null
        }
        pin.isVisible = pinned
        stale.isVisible = age != null && task.isStale
        this.age.isVisible = age != null
        this.age.text = age
        val parts = listOfNotNull(
            if (unread == true) context.getString(R.string.shell_unread) else null,
            task.title, theme.statusLabel(bucket),
            if (pinned) context.getString(R.string.task_pinned) else null,
            if (age != null && task.isStale) context.getString(R.string.task_stale) else null,
            age,
        )
        contentDescription = parts.joinToString(", ")
        importantForAccessibility = if (placeholder) IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    private fun tint(bucket: TaskStatusBucket): Int = when (bucket) {
        TaskStatusBucket.NEEDS_REVIEW -> context.getColor(R.color.token_fg_attention)
        TaskStatusBucket.DONE -> context.getColor(R.color.token_fg_success)
        TaskStatusBucket.CANCELLED -> context.getColor(R.color.token_cancelled)
        else -> context.getColor(R.color.token_sidebar_icon)
    }

    private var fill: ValueAnimator? = null

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> setPressedLook(true)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> setPressedLook(false)
        }
        return super.dispatchTouchEvent(event)
    }

    /** Pressed paints the fill at once and shrinks a hair; released lets both go on the release curve. */
    fun setPressedLook(pressed: Boolean) {
        fill?.cancel()
        if (pressed) {
            pressFill.setColor(pressColor)
        } else {
            val from = pressColor
            fill = ValueAnimator.ofFloat(1f, 0f).apply {
                duration = DesignMotion.durationMillis(DesignMotion.feedbackOut)
                interpolator = DesignMotion.softInOut
                addUpdateListener { pressFill.setColor(ColorUtils.setAlphaComponent(from, (179 * (it.animatedValue as Float)).toInt())) }
                start()
            }
        }
        scaleX.animateTo(if (pressed) 0.985f else 1f)
        scaleY.animateTo(if (pressed) 0.985f else 1f)
    }

    companion object {
        /** The desktop's compact age: "now" under a minute, then whole minutes, hours and days, each rounded. */
        fun age(context: Context, changedAtMillis: Long, nowMillis: Long): String {
            val seconds = maxOf(0L, (nowMillis - changedAtMillis) / 1000)
            if (seconds < 60) return context.getString(R.string.task_now)
            val minutes = Math.round(seconds / 60.0)
            if (minutes < 60) return "${minutes}m"
            val hours = Math.round(minutes / 60.0)
            if (hours < 24) return "${hours}h"
            return "${Math.round(hours / 24.0)}d"
        }
    }
}

/** A row's text, for the placeholder rows Home shows while its first page loads. */
internal fun placeholderTasks(context: Context): List<TaskSummary> = (0 until 6).map { index ->
    TaskSummary("placeholder-$index", if (index % 2 == 0) "Summarizing the latest updates and writing" else "Reviewing open changes", TaskStatusBucket.IN_PROGRESS)
}

/** A view whose holder never rebinds itself: headers, banners and states built once per page. */
internal fun View.fullWidth(): View = apply {
    layoutParams = surf.comma.android.scroll.widget.RecyclerView.LayoutParams(
        surf.comma.android.scroll.widget.RecyclerView.LayoutParams.MATCH_PARENT,
        surf.comma.android.scroll.widget.RecyclerView.LayoutParams.WRAP_CONTENT)
}

internal fun Context.sectionTitle(): TextView = label(Level.SMALL, R.color.token_text_quaternary, surf.comma.android.ui.theme.DesignFonts.semibold).apply {
    isAccessibilityHeading = true
}
