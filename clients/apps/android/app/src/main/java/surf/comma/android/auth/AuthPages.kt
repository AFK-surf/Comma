package surf.comma.android.auth

import android.annotation.SuppressLint
import android.content.Context
import android.view.View
import android.view.ViewGroup
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * Full-width pages that slide horizontally: forward pages enter from the end edge, earlier
 * pages from the start edge. Position springs; opacity follows a timing curve.
 */
internal class AuthPages(private val pages: List<ViewGroup>) {
    private val springs = pages.map { DesignSpring(it, DynamicAnimation.TRANSLATION_X, DesignMotion.springSpatial) }
    var current = -1
        private set

    init {
        pages.forEach {
            it.alpha = 0f
            it.visibility = View.INVISIBLE
        }
    }

    fun show(index: Int, animated: Boolean) {
        if (index == current) return
        val previous = current
        current = index
        val width = pages[index].width
        val rtl = pages[index].layoutDirection == View.LAYOUT_DIRECTION_RTL
        val direction = (if (index > previous) 1 else -1) * (if (rtl) -1 else 1)
        pages.forEachIndexed { i, page ->
            val entering = i == index
            // Hidden pages stay out of focus order and accessibility while they fade.
            page.importantForAccessibility = if (entering) View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
            else View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            page.descendantFocusability = if (entering) ViewGroup.FOCUS_AFTER_DESCENDANTS
            else ViewGroup.FOCUS_BLOCK_DESCENDANTS
            if (!animated || previous < 0 || width == 0) {
                springs[i].cancel()
                page.animate().cancel()
                page.translationX = 0f
                page.alpha = if (entering) 1f else 0f
                page.visibility = if (entering) View.VISIBLE else View.INVISIBLE
            } else if (entering) {
                if (!page.isVisible) {
                    springs[i].cancel()
                    page.translationX = direction * width.toFloat()
                    page.alpha = 0f
                    page.visibility = View.VISIBLE
                }
                springs[i].animateTo(0f)
                page.animate().alpha(1f)
                    .setDuration(DesignMotion.durationMillis(DesignMotion.dialogEnter))
                    .setInterpolator(DesignMotion.smoothOut)
                    .withEndAction(null)
            } else if (page.isVisible) {
                springs[i].animateTo(-direction * width.toFloat())
                page.animate().alpha(0f)
                    .setDuration(DesignMotion.durationMillis(DesignMotion.dialogExit))
                    .setInterpolator(DesignMotion.smoothOut)
                    .withEndAction {
                        if (current == i) return@withEndAction
                        springs[i].cancel()
                        page.visibility = View.INVISIBLE
                        page.translationX = 0f
                    }
            }
        }
    }
}

/**
 * A centred line of text followed by an action. The text shrinks (and ellipsizes) before the
 * action is pushed off the line, so the action always keeps its full touch target.
 */
@SuppressLint("ViewConstructor")
internal class InlineRow(context: Context, private val label: View, private val action: View) : ViewGroup(context) {
    init {
        addView(label)
        addView(action)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val unspecified = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        action.measure(unspecified, unspecified)
        val available = (width - action.measuredWidth).coerceAtLeast(0)
        label.measure(MeasureSpec.makeMeasureSpec(available, MeasureSpec.AT_MOST), unspecified)
        setMeasuredDimension(width, maxOf(label.measuredHeight, action.measuredHeight))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val content = label.measuredWidth + action.measuredWidth
        var x = (width - content) / 2
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        val first = if (rtl) action else label
        val second = if (rtl) label else action
        for (child in listOf(first, second)) {
            val top = (height - child.measuredHeight) / 2
            child.layout(x, top, x + child.measuredWidth, top + child.measuredHeight)
            x += child.measuredWidth
        }
    }
}
