package surf.comma.android.ui.composer

import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography

/**
 * The menu "+" opens: a rounded card of rows (camera, photos, files), each an icon and a
 * label, floating just above the composer's leading edge. The view itself is a full-size
 * transparent layer, so a tap anywhere outside the card closes the menu; the keyboard, if up,
 * stays where it is and nothing underneath moves.
 *
 * With no attachment slot left the rows are disabled and a line above them says so.
 */
internal class AttachMenuView(
    context: Context,
    private val style: ComposerStyle,
    private val onEntry: (AttachEntry) -> Unit,
    private val onDismiss: () -> Unit,
) : FrameLayout(context) {

    private val header = TextView(context)
    val card = LinearLayout(context)
    private val rows = LinkedHashMap<AttachEntry, View>()
    private val cardScaleX = DesignSpring(card, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val cardScaleY = DesignSpring(card, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    var state: AttachMenuState? = null
        private set
    var shown: Boolean = false
        private set

    init {
        visibility = GONE
        isClickable = true
        setOnClickListener { onDismiss() }
        header.apply {
            setTextColor(style.textTertiary)
            style.applyText(this, DesignTypography.Level.SMALL)
            setPadding(style.dp(ROW_START_DP), style.dp(8), style.dp(ROW_START_DP), style.dp(4))
            visibility = GONE
        }
        card.apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                // On a dark page the card has no shadow to speak of, so it steps up a background level.
                val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                    Configuration.UI_MODE_NIGHT_YES
                setColor(if (night) style.bgTertiary else style.bgPrimary)
                cornerRadius = resources.getDimension(R.dimen.radius_5xl)
                setStroke(1, style.borderPrimary) // DESIGN §4: hairlines are one physical pixel
            }
            clipToOutline = true
            elevation = style.dp(ELEVATION_DP.toFloat())
            setPadding(0, style.dp(CARD_PADDING_DP), 0, style.dp(CARD_PADDING_DP))
            isClickable = true // taps between rows must not reach the dismiss layer
            // It grows out of its bottom-leading corner, where "+" is.
            pivotX = 0f
            addOnLayoutChangeListener { v, _, top, _, bottom, _, _, _, _ -> v.pivotY = (bottom - top).toFloat() }
        }
        card.addView(header, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT,
        ))
        AttachEntry.entries.forEach { entry ->
            val row = row(entry)
            rows[entry] = row
            card.addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, style.dp(ROW_HEIGHT_DP)))
        }
        addView(card, LayoutParams(style.dp(CARD_WIDTH_DP), LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
    }

    /** Keeps the card just above a composer [composerHeight] tall and lifted by [lift], at [leading]. */
    fun follow(composerHeight: Int, lift: Float, leading: Int) {
        val lp = card.layoutParams as LayoutParams
        val bottom = composerHeight + style.dp(GAP_DP)
        if (lp.bottomMargin != bottom || lp.marginStart != leading) {
            lp.bottomMargin = bottom
            lp.marginStart = leading
            card.layoutParams = lp
        }
        card.translationY = -lift
    }

    fun bind(value: AttachMenuState) {
        if (state == value) return
        state = value
        header.visibility = if (value.full) VISIBLE else GONE
        header.text = resources.getQuantityString(R.plurals.composer_attach_full, value.max, value.max)
        rows.forEach { (entry, row) ->
            val enabled = value.enabled(entry)
            row.isEnabled = enabled
            row.alpha = if (enabled) 1f else DISABLED_ALPHA
        }
    }

    /** Grows in from the "+" corner on [DesignMotion.springScale] while it fades in. */
    fun show() {
        if (shown) return
        shown = true
        card.animate().cancel()
        visibility = VISIBLE
        if (!ComposerStyle.motionEnabled) {
            cardScaleX.cancel()
            cardScaleY.cancel()
            card.scaleX = 1f
            card.scaleY = 1f
            card.alpha = 1f
            return
        }
        card.scaleX = ENTER_SCALE
        card.scaleY = ENTER_SCALE
        card.alpha = 0f
        cardScaleX.animateTo(1f)
        cardScaleY.animateTo(1f)
        card.animate().alpha(1f)
            .setDuration(DesignMotion.durationMillis(DesignMotion.menuEnter))
            .setInterpolator(DesignMotion.smoothOut)
            .start()
    }

    /** Fades out in place; the scale is left alone so the card does not shrink as it goes. */
    fun hide() {
        if (!shown) return
        shown = false
        card.animate().cancel()
        if (!ComposerStyle.motionEnabled) {
            visibility = GONE
            return
        }
        card.animate().alpha(0f)
            .setDuration(DesignMotion.durationMillis(DesignMotion.menuExit))
            .setInterpolator(DesignMotion.softInOut)
            .withEndAction { if (!shown) visibility = GONE }
            .start()
    }

    private fun row(entry: AttachEntry) = PressableTile(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(style.dp(ROW_START_DP), 0, style.dp(ROW_START_DP), 0)
        background = RippleDrawable(ColorStateList.valueOf(0x14000000), null, GradientDrawable().apply {
            setColor(0xFF000000.toInt())
        })
        isClickable = true
        isFocusable = true
        val (icon, label) = when (entry) {
            AttachEntry.CAMERA -> R.drawable.ic_composer_camera to R.string.composer_attach_camera
            AttachEntry.PHOTOS -> R.drawable.ic_composer_photo to R.string.composer_attach_photos
            AttachEntry.FILES -> R.drawable.ic_composer_file to R.string.composer_attach_files
        }
        contentDescription = context.getString(label)
        setOnClickListener { if (isEnabled) onEntry(entry) }
        // Each icon sits on a soft round chip.
        addView(ImageView(context).apply {
            setImageResource(icon)
            setColorFilter(style.fgPrimary)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            val inset = style.dp((CHIP_DP - ICON_DP) / 2)
            setPadding(inset, inset, inset, inset)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(style.bgQuaternary)
            }
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(style.dp(CHIP_DP), style.dp(CHIP_DP)))
        addView(TextView(context).apply {
            setText(label)
            setTextColor(style.textPrimary)
            style.applyText(this, DesignTypography.Level.LARGE)
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginStart = style.dp(LABEL_GAP_DP)
        })
    }

    private companion object {
        const val CARD_WIDTH_DP = 264
        const val CARD_PADDING_DP = 10
        const val ROW_HEIGHT_DP = 64
        const val ROW_START_DP = 22
        const val CHIP_DP = 40
        const val ICON_DP = 20
        const val LABEL_GAP_DP = 16
        const val ELEVATION_DP = 12
        const val GAP_DP = 4
        const val ENTER_SCALE = 0.5f
        const val DISABLED_ALPHA = 0.4f
    }
}
