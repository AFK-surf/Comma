package surf.comma.android.ui.theme

import android.content.Context
import androidx.annotation.ColorInt
import surf.comma.android.R

/** Resolves a task label's color field to an opaque Android color. */
object DesignLabelColors {
    private val presets = mapOf(
        "gray" to R.color.token_label_gray,
        "blue" to R.color.token_label_blue,
        "indigo" to R.color.token_label_indigo,
        "purple" to R.color.token_label_purple,
        "pink" to R.color.token_label_pink,
        "orange" to R.color.token_label_orange,
        "warning" to R.color.token_label_warning,
        "success" to R.color.token_label_success,
        "error" to R.color.token_label_error,
        "brand" to R.color.token_label_brand,
    )
    private val hexRgb = Regex("#[0-9a-fA-F]{6}")

    @ColorInt
    fun resolve(context: Context, color: String?): Int = resolve(color, context::getColor)

    @ColorInt
    internal fun resolve(color: String?, readColor: (Int) -> Int): Int {
        if (color != null && hexRgb.matches(color)) {
            return 0xFF000000.toInt() or color.substring(1).toInt(16)
        }
        return readColor(presets[color] ?: R.color.token_label_gray)
    }
}
