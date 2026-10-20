package surf.comma.android.ui.composer

import android.animation.ValueAnimator
import android.content.Context
import android.util.TypedValue
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

/** The shared `token_*` colours the composer uses, resolved once per view tree. */
internal class ComposerStyle(private val context: Context) {
    val bgPrimary = color(R.color.token_bg_primary)
    val bgSecondary = color(R.color.token_bg_secondary)
    val bgTertiary = color(R.color.token_bg_tertiary)
    val bgQuaternary = color(R.color.token_bg_quaternary)
    val brand = color(R.color.token_bg_brand_solid)
    val textPrimary = color(R.color.token_text_primary)
    val textTertiary = color(R.color.token_text_tertiary)
    val textQuaternary = color(R.color.token_text_quaternary)
    val textPlaceholder = color(R.color.token_text_placeholder)
    val textError = color(R.color.token_text_error_primary)
    val fgPrimary = color(R.color.token_fg_primary)
    val fgQuaternary = color(R.color.token_fg_quaternary)
    val borderPrimary = color(R.color.token_border_primary)
    val composerBg = color(R.color.token_composer_bg)
    val composerBorder = color(R.color.token_composer_border)
    val composerShadowAmbient = color(R.color.token_composer_shadow_ambient)
    val composerShadowSpot = color(R.color.token_composer_shadow_spot)
    val onBrand = 0xFFFFFFFF.toInt()
    val scrim = 0x73000000

    fun dp(value: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, context.resources.displayMetrics)

    fun dp(value: Int): Int = dp(value.toFloat()).toInt()

    /** Shared type scale and Inter (DesignTypography / DesignFonts), without extra font padding. */
    fun applyText(
        view: TextView,
        level: DesignTypography.Level = DesignTypography.Level.REGULAR,
        weight: Int = DesignFonts.regular,
    ) {
        DesignTypography.applyTo(view, level, weight)
        view.includeFontPadding = false
    }

    private fun color(id: Int): Int = context.getColor(id)

    companion object {
        /** The system "remove animations" switch: every composer motion honours it. */
        val motionEnabled: Boolean get() = ValueAnimator.areAnimatorsEnabled()
    }
}
