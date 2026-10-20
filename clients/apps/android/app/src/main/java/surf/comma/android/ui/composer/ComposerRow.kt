package surf.comma.android.ui.composer

import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.ceil
import kotlin.math.max

/**
 * The input row: [leading] button, [center] field, [trailing] button.
 *
 * A draft that fits on one line sits between the buttons. A longer one is *stacked*: the field
 * takes the full width on top and the buttons keep the row underneath. The buttons hold the
 * bottom corners in both arrangements, so only the field moves, and it moves on the same spring
 * as the surface's height ([ComposerPill]).
 *
 * [wantsStack] decides from the width the field has between the buttons, never from the width it
 * has now, so a draft on the boundary cannot flip back and forth.
 */
internal class ComposerRow(
    context: Context,
    style: ComposerStyle,
    private val leading: View,
    private val center: View,
    private val trailing: View,
    private val wantsStack: (inlineWidthPx: Int) -> Boolean,
) : ViewGroup(context) {

    private val slot = style.dp(SLOT_DP)
    private val edge = style.dp(EDGE_DP)
    private val stackedInset = style.dp(STACKED_INSET_DP)

    var stacked = false
        private set

    /** Width of [center] between the buttons, in px; -1 before the first measure. */
    private var inlineWidth = -1

    /** Where the field was drawn when the arrangement last changed: start edge and gap to the bottom. */
    private var moveFrom: FloatArray? = null
    private val slideX = DesignSpring(center, DynamicAnimation.TRANSLATION_X, DesignMotion.springSize)
    private val slideY = DesignSpring(center, DynamicAnimation.TRANSLATION_Y, DesignMotion.springSize)

    init {
        clipChildren = false
        addView(center)
        addView(leading)
        addView(trailing)
    }

    /** Re-evaluates [wantsStack]. With [animate] the field travels to its new place. */
    fun refresh(animate: Boolean) {
        if (inlineWidth < 0) return
        val next = wantsStack(inlineWidth)
        if (next == stacked) return
        stacked = next
        if (animate && isLaidOut && ComposerStyle.motionEnabled) {
            moveFrom = floatArrayOf(center.left + center.translationX, height - center.bottom - center.translationY)
        } else {
            moveFrom = null
            rest()
        }
        requestLayout()
    }

    private fun rest() {
        slideX.cancel()
        slideY.cancel()
        center.translationX = 0f
        center.translationY = 0f
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = getDefaultSize(suggestedMinimumWidth, widthMeasureSpec)
        val inline = max(0, width - 2 * (slot + edge))
        if (inline != inlineWidth) {
            // A new width (first layout, rotation) re-decides in place, without travel.
            inlineWidth = inline
            val next = wantsStack(inline)
            if (next != stacked) {
                stacked = next
                moveFrom = null
                rest()
            }
        }
        val slotSpec = MeasureSpec.makeMeasureSpec(slot, MeasureSpec.EXACTLY)
        leading.measure(slotSpec, slotSpec)
        trailing.measure(slotSpec, slotSpec)
        val centerWidth = if (stacked) max(0, width - 2 * stackedInset) else inline
        center.measure(
            MeasureSpec.makeMeasureSpec(centerWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        val height = if (stacked) center.measuredHeight + slot else max(slot, center.measuredHeight)
        setMeasuredDimension(width, height)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val width = r - l
        val height = b - t
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        place(leading, if (rtl) width - edge - slot else edge, height)
        place(trailing, if (rtl) edge else width - edge - slot, height)
        val inset = if (stacked) stackedInset else edge + slot
        val bottom = if (stacked) height - slot else height
        place(center, inset, bottom)

        val from = moveFrom ?: return
        moveFrom = null
        rest()
        center.translationX = from[0] - center.left
        center.translationY = (height - center.bottom) - from[1]
        slideX.animateTo(0f)
        slideY.animateTo(0f)
    }

    /** Lays [child] out at its measured size, [start] px from the left, sitting on [bottom]. */
    private fun place(child: View, start: Int, bottom: Int) {
        child.layout(start, bottom - child.measuredHeight, start + child.measuredWidth, bottom)
    }

    companion object {
        const val SLOT_DP = 48
        private const val EDGE_DP = 2
        /** Lines the stacked field's text up with the "+" glyph under it. */
        private const val STACKED_INSET_DP = 13
        private const val PROBE_CHARS = 128

        /**
         * Whether [text] needs a row of its own: it has a line break, or is wider than
         * [inlineWidthPx]. [desiredWidth] measures a run of text on one line.
         */
        fun needsOwnRow(text: CharSequence, inlineWidthPx: Int, desiredWidth: (CharSequence) -> Float): Boolean {
            if (text.isEmpty()) return false
            if (text.indexOf('\n') >= 0) return true
            if (inlineWidthPx <= 0) return false
            // A long draft is decided by its head, so typing into it never measures all of it.
            if (text.length > PROBE_CHARS && ceil(desiredWidth(text.subSequence(0, PROBE_CHARS))) > inlineWidthPx) return true
            return ceil(desiredWidth(text)) > inlineWidthPx
        }
    }
}
