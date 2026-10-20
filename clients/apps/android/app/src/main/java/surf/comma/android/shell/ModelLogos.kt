package surf.comma.android.shell

import android.content.Context
import android.graphics.drawable.Drawable
import androidx.core.content.ContextCompat
import surf.comma.android.R

/**
 * The logo of a model's maker, keyed by the vendor the core names (`taskRun.vendor`, `TaskWorker.vendor`), as the
 * desktop's `ModelVendorIcon`: Comma's mark for Comma's own model. Every logo is one colour, tinted with the text colour.
 */
object ModelLogos {
    private val artwork = mapOf(
        "anthropic" to R.drawable.model_anthropic,
        "deepseek" to R.drawable.model_deepseek,
        "glm" to R.drawable.model_glm,
        "google" to R.drawable.model_google,
        "kimi" to R.drawable.model_kimi,
        "meta" to R.drawable.model_meta,
        "minimax" to R.drawable.model_minimax,
        "mistral" to R.drawable.model_mistral,
        "openai" to R.drawable.model_openai,
        "qwen" to R.drawable.model_qwen,
        "xai" to R.drawable.model_xai,
    )

    /** The vendors with a logo of their own. */
    val vendors: Set<String> get() = artwork.keys

    /** The vendor's logo; null when the vendor is not known or has none. */
    fun drawable(context: Context, vendor: String?): Drawable? {
        val resource = if (vendor == "comma") R.drawable.ic_cue_mark else artwork[vendor] ?: return null
        return ContextCompat.getDrawable(context, resource)?.mutate()?.apply { setTint(context.getColor(R.color.token_text_primary)) }
    }
}
