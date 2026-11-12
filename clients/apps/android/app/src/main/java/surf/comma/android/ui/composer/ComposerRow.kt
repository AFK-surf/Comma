package surf.comma.android.ui.composer

import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.max

/**
 * The input row: [leading] button, [center] field, [microphone] and [trailing] buttons, with [capsule] over the
 * collapsed surface. [capsule] is measured whether or not it shows, so showing it costs no layout.
 *
 * The resting field sits beside the attachment button. Focused in regular height, the field
 * takes the full width on top and the buttons keep the row underneath. The buttons hold the
 * bottom corners in both arrangements, so only the field moves, and it moves on the same spring
 * as the surface's height ([ComposerPill]).
 *
 * [wantsStack] follows focus, attachments and available height.
 */
internal class ComposerRow(
    context: Context,
    style: ComposerStyle,
    private val leading: View,
    private val center: View,
    private val trailing: View,
    private val microphone: View,
    private val capsule: View,
    private val wantsStack: () -> Boolean,
    private val wantsExpanded: () -> Boolean,
    private val onArrangement: (Boolean, Boolean) -> Unit,
) : ViewGroup(context) {

    private val slot = style.dp(SLOT_DP)
    private val collapsedInset = style.dp(52)
    private val stackedInset = style.dp(STACKED_INSET_DP)

    private var expanded = false
    var stacked = false
        private set

    /** Where the field was drawn when the arrangement last changed: start edge and gap to the bottom. */
    private var moveFrom: FloatArray? = null
    private val slideX = DesignSpring(center, DynamicAnimation.TRANSLATION_X, DesignMotion.springSize)
    private val slideY = DesignSpring(center, DynamicAnimation.TRANSLATION_Y, DesignMotion.springSize)

    init {
        clipChildren = false
        addView(center)
        addView(leading)
        addView(trailing)
        addView(microphone)
        addView(capsule)
    }

    /** Re-evaluates [wantsStack]. With [animate] the field travels to its new place. */
    fun refresh(animate: Boolean) {
        val next = wantsStack()
        val nextExpanded = wantsExpanded()
        onArrangement(next, nextExpanded)
        expanded = nextExpanded
        if (next == stacked) { requestLayout(); return }
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
        val beforeTrailing = if (microphone.visibility == GONE) 0 else slot
        val inline = max(0, width - (if (expanded) slot else collapsedInset) - slot - beforeTrailing)
        val slotSpec = MeasureSpec.makeMeasureSpec(slot, MeasureSpec.EXACTLY)
        leading.measure(slotSpec, slotSpec)
        trailing.measure(slotSpec, slotSpec)
        microphone.measure(slotSpec, slotSpec)
        capsule.measure(MeasureSpec.makeMeasureSpec(max(0, width - collapsedInset), MeasureSpec.EXACTLY), slotSpec)
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
        place(leading, if (rtl) width - slot else 0, height)
        place(trailing, if (rtl) 0 else width - slot, height)
        place(microphone, if (rtl) slot else width - 2 * slot, height)
        place(capsule, if (rtl) 0 else collapsedInset, height)
        val inset = if (stacked) stackedInset else if (expanded) slot else collapsedInset
        val bottom = if (stacked) height - slot else height
        place(center, if (rtl) width - inset - center.measuredWidth else inset, bottom)

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
        const val SLOT_DP = 44
        /** Lines the stacked field's text up with the "+" glyph under it. */
        private const val STACKED_INSET_DP = 14
    }
}
