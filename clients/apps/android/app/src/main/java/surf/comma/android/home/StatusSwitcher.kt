package surf.comma.android.home

import android.animation.ValueAnimator
import android.content.Context
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.list.TaskListFilter
import surf.comma.android.tasks.list.statusTint
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.selectionTick
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The floating status switcher over Home: In progress, Needs review, Done and Cancelled in one glass
 * capsule. The chosen status shows its name on a grey pill and the others share the remaining width as glyphs, so
 * all five fit on a phone; the segments trade width on the settle spring as the choice moves. A filter that is not
 * exactly one of these statuses highlights none. A touch chooses the status under the finger at once; once the
 * finger moves along the switcher it scrubs, choosing each status it passes, with a tick on each.
 */
class StatusSwitcher(context: Context) : ViewGroup(context) {
    var onSelect: ((TaskStatusBucket) -> Unit)? = null

    private val order = TaskListFilter.STATUS_BUCKETS
    private val theme = TaskTheme(context)
    private val pill = View(context).apply { background = rounded(context.getColor(R.color.token_glass_selection), context.dp(20).toFloat()) }
    private val segments = order.map { Segment(context, it) }
    /** How far each segment is opened out to its name, 0 to 1. */
    private val opened = FloatArray(order.size)
    private var from = FloatArray(order.size)
    private var to = FloatArray(order.size)
    private var selection: TaskStatusBucket? = null
    private var scrubbing = false
    private var downX = 0f

    init {
        glass(fill = R.color.token_glass_frosted)
        clipChildren = true
        addView(pill)
        segments.forEach(::addView)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        contentDescription = context.getString(R.string.task_status_switcher)
    }

    /** Shows [bucket] chosen; [animate] false jumps there, as when Home first shows. */
    fun select(bucket: TaskStatusBucket?, animate: Boolean = true) {
        if (bucket == selection && !spring.isRunning) { applyFractions(); return }
        selection = bucket
        to = FloatArray(order.size) { if (order[it] == bucket) 1f else 0f }
        if (!animate || !ValueAnimator.areAnimatorsEnabled() || !isLaidOut) {
            spring.cancel()
            to.copyInto(opened)
            applyFractions()
            return
        }
        from = opened.copyOf()
        progress = 0f
        spring.cancel()
        spring.animateTo(1f)
    }

    /** How far the segments have come from [from] to [to]; driven by the settle spring. */
    private var progress = 1f
        set(value) {
            field = value
            for (i in opened.indices) opened[i] = from[i] + (to[i] - from[i]) * value
            applyFractions()
        }
    private val spring = surf.comma.android.ui.theme.DesignSpring(this, PROGRESS, surf.comma.android.ui.theme.DesignMotion.springSize, 0.001f)

    private fun applyFractions() {
        segments.forEachIndexed { index, segment ->
            segment.name.alpha = opened[index]
            segment.isSelected = order[index] == selection
        }
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val height = context.dp(HEIGHT_DP)
        val width = MeasureSpec.getSize(widthMeasureSpec)
        segments.forEach {
            it.measure(MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED), MeasureSpec.makeMeasureSpec(height - 2 * context.dp(INSET_DP), MeasureSpec.EXACTLY))
        }
        setMeasuredDimension(width, height)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val inset = context.dp(INSET_DP)
        val inner = width - 2 * inset
        val glyph = context.dp(GLYPH_SLOT_DP)
        // Each segment needs its glyph's slot; the open one adds its name; the rest of the width goes to the closed.
        val named = segments.mapIndexed { index, segment -> (segment.namedWidth() - glyph) * opened[index] }
        val spare = (inner - glyph * segments.size - named.sum()).coerceAtLeast(0f)
        val closedShare = segments.indices.map { 1f - opened[it] }
        val shareTotal = closedShare.sum().takeIf { it > 0f } ?: 1f
        var x = inset.toFloat()
        val height = height - 2 * inset
        segments.forEachIndexed { index, segment ->
            val w = glyph + named[index] + spare * closedShare[index] / shareTotal
            segment.layout(x.roundToInt(), inset, (x + w).roundToInt(), inset + height)
            segment.place(opened[index])
            x += w
        }
        val pillIndex = opened.indices.maxByOrNull { opened[it] }
        if (pillIndex != null && opened[pillIndex] > 0f && selection != null) {
            val chosen = segments[order.indexOf(selection!!)]
            pill.alpha = 1f
            pill.layout(chosen.left, chosen.top, chosen.right, chosen.bottom)
        } else {
            pill.alpha = 0f
            pill.layout(0, 0, 0, 0)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                downX = event.x
                scrubbing = false
                choose(at(event.x))
            }
            MotionEvent.ACTION_MOVE -> {
                if (!scrubbing && abs(event.x - downX) > context.dp(4)) scrubbing = true
                if (event.y < -context.dp(44) || event.y > height + context.dp(44)) return true
                if (scrubbing) choose(scrubAt(event.x))
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> scrubbing = false
        }
        return true
    }

    /** The segment under [x]; past either end, the end segment. */
    private fun at(x: Float): TaskStatusBucket {
        val index = segments.indexOfFirst { x >= it.left && x < it.right }
        return order[if (index >= 0) index else if (x < width / 2) 0 else order.lastIndex]
    }

    /** While scrubbing, each status owns an equal share of the capsule, so the finger passes them at one pace. */
    private fun scrubAt(x: Float): TaskStatusBucket {
        val inset = context.dp(INSET_DP)
        val share = (width - 2f * inset) / order.size
        return order[((x - inset) / share).toInt().coerceIn(0, order.lastIndex)]
    }

    private fun choose(bucket: TaskStatusBucket) {
        if (bucket == selection) return
        selectionTick()
        select(bucket)
        onSelect?.invoke(bucket)
    }

    /** A status: its glyph, and its name opening out of the glyph's trailing side. */
    private inner class Segment(context: Context, val bucket: TaskStatusBucket) : FrameLayout(context) {
        val icon = TaskStatusIconView(context).apply { setStatus(this@Segment.bucket, statusTint(context, this@Segment.bucket), spin = false) }
        val name: TextView = context.label(Level.SMALL, R.color.token_text_primary, DesignFonts.medium).apply {
            text = theme.statusLabel(bucket)
            alpha = 0f
        }

        init {
            addView(icon, LayoutParams(context.dp(20), context.dp(20)))
            addView(name, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
            contentDescription = theme.statusLabel(bucket)
            isClickable = false
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
            clipChildren = true
        }

        fun namedWidth(): Float = context.dp(14 * 2 + 20 + 6).toFloat() + name.measuredWidth

        /** Centres the glyph while closed and slides it to the leading padding as the name opens. */
        fun place(open: Float) {
            val h = bottom - top
            val w = right - left
            val iconSize = context.dp(20)
            val closedX = (w - iconSize) / 2f
            val openX = context.dp(14).toFloat()
            val ix = closedX + (openX - closedX) * open
            icon.layout(ix.roundToInt(), (h - iconSize) / 2, ix.roundToInt() + iconSize, (h + iconSize) / 2)
            val nx = ix + iconSize + context.dp(6) * open
            name.layout(nx.roundToInt(), (h - name.measuredHeight) / 2, nx.roundToInt() + name.measuredWidth, (h + name.measuredHeight) / 2)
        }

        override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) = Unit

        override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
            super.onInitializeAccessibilityNodeInfo(info)
            info.className = android.widget.Button::class.java.name
            info.isSelected = bucket == selection
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK)
        }

        override fun performAccessibilityAction(action: Int, arguments: android.os.Bundle?): Boolean {
            if (action == AccessibilityNodeInfo.ACTION_CLICK) { choose(bucket); return true }
            return super.performAccessibilityAction(action, arguments)
        }
    }

    companion object {
        const val HEIGHT_DP = 48
        const val INSET_DP = 4
        const val GLYPH_SLOT_DP = 36
        private val PROGRESS = object : androidx.dynamicanimation.animation.FloatPropertyCompat<StatusSwitcher>("progress") {
            override fun getValue(view: StatusSwitcher) = view.progress
            override fun setValue(view: StatusSwitcher, value: Float) { view.progress = value }
        }
    }
}
