package surf.comma.android.ui

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
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
import surf.comma.android.ui.widget.GlassBackdrop
import surf.comma.android.ui.widget.GlassMenuLayer
import surf.comma.android.ui.widget.GlassMenuMorph
import surf.comma.android.ui.widget.LiquidGlass

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
        val rows = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        list.addView(rows, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        // The popup window clips what it draws, so the frame leaves room for the card's whole shadow; it falls
        // further below the card than above or beside it.
        val side = context.dp(SHADOW_SIDE_DP)
        val top = context.dp(SHADOW_TOP_DP)
        val bottom = context.dp(SHADOW_BOTTOM_DP)
        val frame = FrameLayout(context).apply {
            setPadding(side, top, side, bottom)
            clipChildren = false
            clipToPadding = false
            addView(list, FrameLayout.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        var dismiss: () -> Unit = {}
        // A tap in the shadow room is a tap outside the card.
        frame.setOnClickListener { dismiss() }
        list.isClickable = true
        // A choice menu keeps its titles in one column whether or not a row is checked.
        val checkColumn = entries.any { it is Item && it.checked }
        entries.dropLastWhile { it == Divider }.forEach { entry ->
            when (entry) {
                Divider -> rows.addView(View(context).apply { setBackgroundColor(context.getColor(R.color.token_bg_tertiary)) },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, context.dp(6)))
                is Item -> rows.addView(row(entry, { dismiss() }, checkColumn), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            }
        }
        frame.measure(View.MeasureSpec.makeMeasureSpec(width + side * 2, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        val card = frame.measuredHeight - top - bottom
        val screen = Rect().also { anchor.getWindowVisibleDisplayFrame(it) }
        val location = IntArray(2).also(anchor::getLocationInWindow)
        val gap = context.dp(4)
        val edge = context.dp(12)
        // A small glass control turns into its menu, so the card opens over it, not beside it. A press may still be bouncing.
        val morphs = LiquidGlass.enabled && anchor.width <= width && anchor.height <= context.dp(MORPH_ANCHOR_DP)
        val restX = location[0] + anchor.width * anchor.scaleX / 2f - anchor.width / 2f
        val restY = location[1] + anchor.height * anchor.scaleY / 2f - anchor.height / 2f
        val rest = RectF(restX, restY, restX + anchor.width, restY + anchor.height)
        // The card's own place: under the anchor's trailing edge, or over the anchor when there is no room below.
        val below = (if (morphs) rest.top.toInt() + card else location[1] + anchor.height + gap + card) + edge <= screen.bottom
        val clampX = { x: Int -> x.coerceIn(screen.left + edge, maxOf(screen.left + edge, screen.right - width - edge)) }
        val cardX = clampX(if (morphs) rest.centerX().toInt() - width / 2 else location[0] + anchor.width - width)
        val cardY = when {
            morphs && below -> rest.top.toInt()
            morphs -> rest.bottom.toInt() - card
            below -> location[1] + anchor.height + gap
            else -> location[1] - gap - card
        }.coerceAtLeast(screen.top + edge)
        val placed = RectF(cardX.toFloat(), cardY.toFloat(), (cardX + width).toFloat(), (cardY + card).toFloat())
        val layer = GlassMenuLayer.over(anchor, placed)
        if (layer != null) {
            val radius = context.dp(if (morphs) MORPH_RADIUS_DP else 14).toFloat()
            val backdrop = layer.backdrop(placed, radius, if (morphs) GlassBackdrop.REST_SHADOW else 0f)
            list.background = backdrop
            dismiss = layer::dismiss
            layer.show(frame, cardX - side, cardY - top)
            if (morphs) {
                val whole = RectF(0f, 0f, width.toFloat(), card.toFloat())
                val start = RectF(rest).apply {
                    offset(-placed.left, -placed.top)
                    intersect(whole)
                }
                val morph = GlassMenuMorph(list, rows, anchor, backdrop, start, whole, radius)
                // The glass draws the shadow past the card, so only the rows are clipped.
                list.clipToOutline = false
                list.elevation = 0f
                rows.outlineProvider = morph
                rows.clipToOutline = true
                list.alpha = 1f
                layer.morph = morph
                morph.open()
                return
            }
        } else {
            val popup = PopupWindow(frame, width + side * 2, ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
                animationStyle = 0
                isOutsideTouchable = true
                setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                elevation = 0f
                // Only the transparent shadow room may pass the screen edge; the card itself is kept on screen below.
                isClippingEnabled = false
            }
            dismiss = popup::dismiss
            popup.showAtLocation(anchor, Gravity.NO_GRAVITY, cardX - side, cardY - top)
        }
        list.pivotX = width.toFloat()
        list.pivotY = if (below) 0f else card.toFloat()
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

    private fun row(item: Item, dismiss: () -> Unit, checkColumn: Boolean): View {
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
            if (checkColumn) addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_action_check)
                imageTintList = ColorStateList.valueOf(context.getColor(ink))
                visibility = if (item.checked) View.VISIBLE else View.INVISIBLE
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
            isSelected = item.checked
            pressedFill(R.color.token_surface_ink)
            setOnClickListener {
                dismiss()
                item.action()
            }
        }
    }

    private companion object {
        const val WIDTH_DP = 240
        const val MORPH_ANCHOR_DP = 64
        const val MORPH_RADIUS_DP = 26
        const val SHADOW_SIDE_DP = 28
        const val SHADOW_TOP_DP = 20
        const val SHADOW_BOTTOM_DP = 40
    }
}
