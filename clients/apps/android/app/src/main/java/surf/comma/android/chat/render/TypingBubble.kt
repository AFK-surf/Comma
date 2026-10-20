package surf.comma.android.chat.render

import android.animation.ValueAnimator
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View
import android.view.animation.AnimationUtils
import androidx.core.content.ContextCompat
import surf.comma.android.R
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.ui.theme.DesignMotion
import java.util.WeakHashMap
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * The "typing" bubble shown where a reply will start: a grey pill holding three dots, with a
 * tail of two circles at its bottom-left.
 *
 * The dots brighten one after another in a loop and the pill breathes by a fraction of its
 * size. Both are read from the animation clock, so every bubble on screen is in the same phase
 * and a row that is bound again does not restart the loop.
 */
internal class TypingBubble {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    /**
     * Draws the bubble with its row's content column starting at [left] and its body's top at
     * [top]. [scale] is the pop-in scale around the tail; [alpha] fades the whole bubble.
     * With [animate] off the dots rest at one brightness and the pill does not breathe.
     */
    fun draw(
        canvas: Canvas, left: Float, top: Float, density: Float, bubbleColor: Int, dotColor: Int,
        timeMs: Long, scale: Float = 1f, alpha: Float = 1f, animate: Boolean = true,
    ) {
        if (alpha <= 0f || scale <= 0f) return
        val bodyLeft = left + BODY_INSET_DP * density
        val bodyRight = bodyLeft + BODY_WIDTH_DP * density
        val bodyBottom = top + BODY_HEIGHT_DP * density
        val restore = if (alpha < 1f) {
            // One layer, so the overlapping pill and tail fade as a single shape.
            canvas.saveLayerAlpha(left - density, top - density, bodyRight + density,
                top + HEIGHT_DP * density + density, (alpha * 255).toInt())
        } else {
            canvas.save()
        }
        canvas.scale(scale, scale, left, top + HEIGHT_DP * density)
        paint.color = bubbleColor
        canvas.drawCircle(bodyLeft + TAIL_LARGE_X_DP * density, bodyBottom + TAIL_LARGE_Y_DP * density,
            TAIL_LARGE_RADIUS_DP * density, paint)
        canvas.drawCircle(bodyLeft + TAIL_SMALL_X_DP * density, bodyBottom + TAIL_SMALL_Y_DP * density,
            TAIL_SMALL_RADIUS_DP * density, paint)
        val centerX = (bodyLeft + bodyRight) / 2f
        val centerY = (top + bodyBottom) / 2f
        val breath = if (animate) breathScale(timeMs) else 1f
        canvas.scale(breath, breath, centerX, centerY)
        val radius = BODY_HEIGHT_DP * density / 2f
        canvas.drawRoundRect(bodyLeft, top, bodyRight, bodyBottom, radius, radius, paint)
        val pitch = (DOT_RADIUS_DP * 2 + DOT_GAP_DP) * density
        val dotAlpha = dotColor ushr 24
        for (index in 0 until DOT_COUNT) {
            val brightness = if (animate) dotBrightness(timeMs, index) else DOT_REST_BRIGHTNESS
            paint.color = (dotColor and 0x00FFFFFF) or ((dotAlpha * brightness).toInt() shl 24)
            canvas.drawCircle(centerX + (index - (DOT_COUNT - 1) / 2f) * pitch, centerY, DOT_RADIUS_DP * density, paint)
        }
        canvas.restoreToCount(restore)
    }

    companion object {
        const val BODY_WIDTH_DP = 56f
        const val BODY_HEIGHT_DP = 34f
        /** The pill starts this far right of the column, which leaves room for the tail. */
        const val BODY_INSET_DP = 4f
        /** The row's height under its top margin: the pill plus the tail below it. */
        const val HEIGHT_DP = BODY_HEIGHT_DP + 6f

        const val DOT_COUNT = 3
        private const val DOT_RADIUS_DP = 3.5f
        private const val DOT_GAP_DP = 5f
        // Tail circles, placed from the pill's bottom-left corner.
        private const val TAIL_LARGE_RADIUS_DP = 5.5f
        private const val TAIL_LARGE_X_DP = 4.5f
        private const val TAIL_LARGE_Y_DP = -3.5f
        private const val TAIL_SMALL_RADIUS_DP = 2.5f
        private const val TAIL_SMALL_X_DP = -1f
        private const val TAIL_SMALL_Y_DP = 3.5f

        const val DOT_PERIOD_MS = 1200L
        /** How long after the previous dot each dot starts to brighten. */
        const val DOT_STAGGER_MS = 160L
        /** The part of the period a dot spends brightening and fading; it rests for the remainder. */
        private const val DOT_PULSE_FRACTION = 0.5f
        const val DOT_DIM_BRIGHTNESS = 0.35f
        private const val DOT_REST_BRIGHTNESS = 0.6f

        private const val BREATH_PERIOD_MS = DOT_PERIOD_MS * 2
        const val BREATH_AMPLITUDE = 0.02f

        /** How opaque dot [index] is at [timeMs], from [DOT_DIM_BRIGHTNESS] to 1. */
        fun dotBrightness(timeMs: Long, index: Int): Float {
            val phase = Math.floorMod(timeMs - index * DOT_STAGGER_MS, DOT_PERIOD_MS).toFloat() / DOT_PERIOD_MS
            if (phase >= DOT_PULSE_FRACTION) return DOT_DIM_BRIGHTNESS
            val pulse = 0.5f - 0.5f * cos(2.0 * PI * phase / DOT_PULSE_FRACTION).toFloat()
            return DOT_DIM_BRIGHTNESS + (1f - DOT_DIM_BRIGHTNESS) * pulse
        }

        /** The pill's scale at [timeMs]: within [BREATH_AMPLITUDE] of 1. */
        fun breathScale(timeMs: Long): Float {
            val phase = Math.floorMod(timeMs, BREATH_PERIOD_MS).toFloat() / BREATH_PERIOD_MS
            return 1f + BREATH_AMPLITUDE * sin(2.0 * PI * phase).toFloat()
        }

        /**
         * Whether the loop should draw another frame: only while the row is attached to a
         * visible window and some part of it is inside the list's viewport.
         */
        fun keepsAnimating(
            attached: Boolean, windowVisible: Boolean, visibleTop: Int, visibleHeight: Int, cellHeight: Int,
        ): Boolean = attached && windowVisible && visibleHeight > 0 && visibleTop < cellHeight &&
            visibleTop + visibleHeight > 0

        fun isTypingRow(item: PreparedChatMessage): Boolean =
            item.message.cardKind == TimelineBlockKinds.LIVE_STATUS &&
                item.message.cardPayload != TimelineBlockKinds.LIVE_STATUS_SKELETON

        fun bubbleColor(view: View): Int = ContextCompat.getColor(view.context, R.color.token_markdown_bg_message)
        fun dotColor(view: View): Int = ContextCompat.getColor(view.context, R.color.token_markdown_text_secondary)
    }
}

/** Where a typing bubble that just left the list is faded out. */
internal class TypingExit(
    /** The row the bubble sat under; null when it was the first row. */
    val anchorRowId: Long?,
    val sideMarginPx: Int,
    val topMarginPx: Int,
)

/**
 * The fade a typing bubble needs when the list changes from [previous] to [current], or null.
 *
 * It fades only when it was the last row, is gone from the new list, and the row above it is
 * still in place: the reply (or nothing) took its spot. A list that was replaced gets no fade.
 */
internal fun typingExit(previous: List<PreparedChatMessage>, current: List<PreparedChatMessage>): TypingExit? {
    val bubble = previous.lastOrNull()?.takeIf(TypingBubble::isTypingRow) ?: return null
    if (bubble.message.role != ChatRole.AGENT || current.any(TypingBubble::isTypingRow)) return null
    val anchorIndex = previous.size - 2
    val anchor = previous.getOrNull(anchorIndex)
    if (anchor != null && current.getOrNull(anchorIndex)?.message?.id != anchor.message.id) return null
    if (anchor == null && previous.size != 1) return null
    return TypingExit(anchor?.message?.id, bubble.sideMarginPx, bubble.topMarginPx)
}

/** Whether the bubble is new in [current] and should pop in, rather than being found there. */
internal fun typingEnters(previous: List<PreparedChatMessage>, current: List<PreparedChatMessage>): Boolean =
    previous.isNotEmpty() && previous.none(TypingBubble::isTypingRow) &&
        current.lastOrNull()?.let(TypingBubble::isTypingRow) == true

/**
 * Shrinks and fades the departed typing bubble over the spot it occupied, while the reply rises
 * in underneath. It draws over the list, so nothing is laid out and no row changes size.
 */
internal class TypingExitDecoration : RecyclerView.ItemDecoration() {
    private val bubble = TypingBubble()
    private var exit: TypingExit? = null
    private var startMs = 0L
    /** The row id each attached row view was last bound to. */
    val boundRows = WeakHashMap<View, Long>()

    fun start(next: TypingExit, list: RecyclerView) {
        if (!ValueAnimator.areAnimatorsEnabled()) return
        exit = next
        startMs = AnimationUtils.currentAnimationTimeMillis()
        list.invalidate()
    }

    fun cancel() { exit = null }

    override fun onDrawOver(canvas: Canvas, parent: RecyclerView, state: RecyclerView.State) {
        val exit = exit ?: return
        val now = AnimationUtils.currentAnimationTimeMillis()
        val seconds = (now - startMs) / 1000f
        // It shrinks into its tail on the size spring while it fades.
        val scale = 1f - DesignMotion.springSize.progressAt(seconds)
        val progress = (now - startMs).toFloat() / DesignMotion.stateChange
        if (progress >= 1f || scale <= SHRUNK) {
            this.exit = null
            return
        }
        val top = if (exit.anchorRowId == null) parent.paddingTop.toFloat() else {
            var bottom: Float? = null
            for (index in 0 until parent.childCount) {
                val child = parent.getChildAt(index)
                if (boundRows[child] == exit.anchorRowId) bottom = child.bottom + child.translationY
            }
            // The row above is not on screen, so neither is the spot.
            bottom ?: run { this.exit = null; return }
        }
        bubble.draw(canvas, exit.sideMarginPx.toFloat(), top + exit.topMarginPx, parent.resources.displayMetrics.density,
            TypingBubble.bubbleColor(parent), TypingBubble.dotColor(parent), now, scale = scale,
            alpha = 1f - DesignMotion.softInOut.getInterpolation(progress.coerceAtLeast(0f)))
        parent.postInvalidateOnAnimation()
    }

    private companion object {
        /** Small enough to stop drawing. */
        const val SHRUNK = 0.02f
    }
}
