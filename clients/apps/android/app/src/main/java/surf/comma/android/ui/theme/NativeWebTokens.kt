package surf.comma.android.ui.theme

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import surf.comma.android.R

/** The design tokens the shared web runtimes (Mini Apps, Dynamic UI) take as CSS variables, as the iOS app gives them. */
object NativeWebTokens {
    /** Each token as `--comma-<name>` to a CSS `rgba()`, resolved for [dark]. */
    fun values(context: Context, dark: Boolean): Map<String, String> {
        val configuration = Configuration(context.resources.configuration).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        val themed = context.createConfigurationContext(configuration)
        val colors = mapOf(
            "background" to R.color.token_bg_primary, "surface" to R.color.token_bg_secondary,
            "surface-strong" to R.color.token_bg_tertiary, "foreground" to R.color.token_text_primary,
            "muted" to R.color.token_text_secondary, "subtle" to R.color.token_text_tertiary,
            "faint" to R.color.token_text_quaternary, "border" to R.color.token_border_primary,
            "border-subtle" to R.color.token_border_secondary, "primary" to R.color.token_bg_brand_solid,
            "accent" to R.color.token_bg_brand_solid, "danger" to R.color.token_fg_error,
            "success" to R.color.token_fg_success, "warning" to R.color.token_fg_attention,
        )
        return colors.entries.associate { (name, id) ->
            val color = themed.getColor(id)
            "--comma-$name" to "rgba(${Color.red(color)},${Color.green(color)},${Color.blue(color)},${Color.alpha(color) / 255f})"
        } + ("--comma-primary-foreground" to "rgba(255,255,255,1)")
    }
}
