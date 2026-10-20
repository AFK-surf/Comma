package surf.comma.android.ui

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import androidx.annotation.DrawableRes
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.pressedFill
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A menu as the iOS app's context and toolbar menus draw it: a rounded card of rows, each its title with the
 * glyph at the trailing edge, groups split by a thicker rule, destructive rows in red, a check on a chosen row and
 * disabled rows greyed. It grows out of its anchor on the scale spring and fades in with the menu timing; a
 * long press opens it with a tick. Choosing a row closes the menu first, then acts.
 */
class ActionMenu(private val context: Context) {
    private sealed interface Entry
    private class Item(
        val title: CharSequence,
        @DrawableRes val icon: Int?,
        val iconDrawable: Drawable?,
        val destructive: Boolean,
        val enabled: Boolean,
        val checked: Boolean,
        val action: () -> Unit,
    ) : Entry
    private data object Divider : Entry

    private val entries = mutableListOf<Entry>()

    fun item(title: CharSequence, @DrawableRes icon: Int? = null, destructive: Boolean = false, enabled: Boolean = true,
             checked: Boolean = false, iconDrawable: Drawable? = null, action: () -> Unit) = apply {
        entries += Item(title, icon, iconDrawable, destructive, enabled, checked, action)
    }

    fun divider() = apply { if (entries.isNotEmpty() && entries.last() != Divider) entries += Divider }

    val isEmpty: Boolean get() = entries.none { it is Item }

    /** Opens under [anchor] (or over it when there is no room below), aligned to its trailing edge. */
    fun show(anchor: View, haptic: Boolean = false) {
        if (isEmpty) return
        if (haptic) anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val width = context.dp(WIDTH_DP)
        val list = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val radius = context.dp(14).toFloat()
            background = rounded(context.getColor(R.color.token_card_primary), radius, context.getColor(R.color.token_border_primary), 1)
            clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) =
                    outline.setRoundRect(0, 0, view.width, view.height, radius)
            }
            elevation = context.dp(16).toFloat()
            alpha = 0f
        }
        val frame = FrameLayout(context).apply {
            setPadding(context.dp(12), context.dp(12), context.dp(12), context.dp(12))
            addView(list, FrameLayout.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        val popup = PopupWindow(frame, width + context.dp(24), ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
            animationStyle = 0
            isOutsideTouchable = true
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            elevation = 0f
        }
        entries.dropLastWhile { it == Divider }.forEach { entry ->
            when (entry) {
                Divider -> list.addView(View(context).apply { setBackgroundColor(context.getColor(R.color.token_bg_tertiary)) },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, context.dp(6)))
                is Item -> list.addView(row(entry, popup), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            }
        }
        frame.measure(View.MeasureSpec.makeMeasureSpec(width + context.dp(24), View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        val screen = Rect().also { anchor.getWindowVisibleDisplayFrame(it) }
        val location = IntArray(2).also(anchor::getLocationInWindow)
        val below = location[1] + anchor.height + frame.measuredHeight - context.dp(12) <= screen.bottom
        val x = (location[0] + anchor.width - width - context.dp(12)).coerceIn(screen.left, maxOf(screen.left, screen.right - width - context.dp(24)))
        val y = if (below) location[1] + anchor.height - context.dp(8) else location[1] - frame.measuredHeight + context.dp(8)
        popup.showAtLocation(anchor, Gravity.NO_GRAVITY, x, y.coerceAtLeast(screen.top))
        list.pivotX = width.toFloat()
        list.pivotY = if (below) 0f else frame.measuredHeight.toFloat()
        list.scaleX = 0.9f
        list.scaleY = 0.9f
        DesignSpring(list, DynamicAnimation.SCALE_X, DesignMotion.springScale).animateTo(1f)
        DesignSpring(list, DynamicAnimation.SCALE_Y, DesignMotion.springScale).animateTo(1f)
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = DesignMotion.durationMillis(DesignMotion.menuEnter)
            interpolator = DesignMotion.smoothOut
            addUpdateListener { list.alpha = it.animatedValue as Float }
            start()
        }
    }

    private fun row(item: Item, popup: PopupWindow): View {
        val ink = when {
            !item.enabled -> R.color.token_text_placeholder
            item.destructive -> R.color.token_text_error_primary
            else -> R.color.token_text_primary
        }
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = context.dp(46)
            setPadding(context.dp(16), 0, context.dp(14), 0)
            if (item.checked) addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_action_check)
                imageTintList = ColorStateList.valueOf(context.getColor(ink))
            }, LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginEnd = context.dp(8) })
            addView(context.label(Level.REGULAR, ink, lines = 2).apply { text = item.title }, LinearLayout.LayoutParams(0, -2, 1f))
            if (item.icon != null || item.iconDrawable != null) addView(ImageView(context).apply {
                if (item.iconDrawable != null) setImageDrawable(item.iconDrawable) else {
                    setImageResource(item.icon!!)
                    imageTintList = ColorStateList.valueOf(context.getColor(ink))
                }
            }, LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginStart = context.dp(12) })
            isEnabled = item.enabled
            contentDescription = item.title
            pressedFill(R.color.token_surface_ink)
            setOnClickListener {
                popup.dismiss()
                item.action()
            }
        }
    }

    private companion object { const val WIDTH_DP = 240 }
}
