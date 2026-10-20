package surf.comma.android.ui.theme

import android.content.Context
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.FontStyle
import surf.comma.android.R
import java.util.concurrent.ConcurrentHashMap

/**
 * Weight requested from the system fallback, which is where Chinese glyphs come from.
 * At the same nominal weight Noto Sans CJK reads lighter than Inter or Roboto, and API 36
 * only has whole-hundred CJK instances and rounds down (Inter 450 lands on CJK 400).
 * Body weights therefore ask for 500; heavier weights pass through. The Latin face is untouched.
 */
internal fun cjkFallbackWeight(weight: Int) = maxOf(weight, DesignFonts.medium)

/** One bundled variable font; cached instances are safe to use during background text layout. */
object DesignFonts {
    const val regular = 450
    const val medium = 500
    const val semibold = 600
    const val bold = 700

    private val cache = ConcurrentHashMap<Int, Typeface>()

    fun inter(context: Context, weight: Int = regular): Typeface {
        require(weight in 100..900) { "Inter weight must be between 100 and 900" }
        return cache.getOrPut(weight) {
            val font = Font.Builder(context.applicationContext.resources, R.font.inter_variable)
                .setFontVariationSettings("'wght' $weight")
                .setWeight(weight)
                .build()
            Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build())
                .setStyle(FontStyle(cjkFallbackWeight(weight), FontStyle.FONT_SLANT_UPRIGHT))
                .setSystemFallback("sans-serif")
                .build()
        }
    }
}
