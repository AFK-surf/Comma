package surf.comma.android.routines

import android.content.Context
import android.graphics.drawable.Drawable
import androidx.core.content.ContextCompat
import surf.comma.android.R
import surf.comma.android.ui.icons.IconSources

/**
 * A connected app's mark, keyed like the desktop logo resolver: the shipped brand artwork when there is one, the
 * Comma mark for Comma itself, else the plug-in puzzle piece. Monochrome marks (GitHub, Notion) follow the text
 * colour.
 */
object ProviderMarks {
    fun drawable(context: Context, appId: String?): Drawable {
        val key = RecommendationSource.brandKey(appId)
        val resource = when (key) {
            null -> null
            "comma" -> R.drawable.ic_cue_mark
            "googleworkspace" -> R.drawable.provider_google
            // The desktop's resolver names Google Colab both ways.
            "colab" -> R.drawable.provider_googlecolab
            else -> artwork[key]
        }
        val drawable = resource?.let { ContextCompat.getDrawable(context, it)?.mutate() }
        if (drawable == null) {
            return ContextCompat.getDrawable(context, R.drawable.ic_routine_puzzle)!!.mutate().apply {
                setTint(context.getColor(R.color.token_sidebar_icon))
            }
        }
        if (key == "comma" || key in IconSources.MONOCHROME_PROVIDERS) drawable.setTint(context.getColor(R.color.token_text_primary))
        return drawable
    }

    /** Whether the app has artwork of its own. */
    fun hasArtwork(appId: String?): Boolean = RecommendationSource.brandKey(appId)?.let { it in artwork || it == "googleworkspace" || it == "colab" } == true

    /** The decorative sample shown before any source is connected, as on the desktop. */
    val samples = listOf("linear", "slack", "github", "googledrive")

    private val artwork = mapOf(
        "amap" to R.drawable.provider_amap,
        "baidumaps" to R.drawable.provider_baidumaps,
        "blender" to R.drawable.provider_blender,
        "canva" to R.drawable.provider_canva,
        "didi" to R.drawable.provider_didi,
        "dropbox" to R.drawable.provider_dropbox,
        "fastmail" to R.drawable.provider_fastmail,
        "feishu" to R.drawable.provider_feishu,
        "feishuproject" to R.drawable.provider_feishuproject,
        "flomo" to R.drawable.provider_flomo,
        "gitee" to R.drawable.provider_gitee,
        "github" to R.drawable.provider_github,
        "gmail" to R.drawable.provider_gmail,
        "google" to R.drawable.provider_google,
        "googlecalendar" to R.drawable.provider_googlecalendar,
        "googlecolab" to R.drawable.provider_googlecolab,
        "googledrive" to R.drawable.provider_googledrive,
        "hubspot" to R.drawable.provider_hubspot,
        "imessage" to R.drawable.provider_imessage,
        "lark" to R.drawable.provider_lark,
        "linear" to R.drawable.provider_linear,
        "luckin" to R.drawable.provider_luckin,
        "meegle" to R.drawable.provider_meegle,
        "notion" to R.drawable.provider_notion,
        "outlook" to R.drawable.provider_outlook,
        "pixso" to R.drawable.provider_pixso,
        "posthog" to R.drawable.provider_posthog,
        "qcc" to R.drawable.provider_qcc,
        "signal" to R.drawable.provider_signal,
        "slack" to R.drawable.provider_slack,
        "stillfail" to R.drawable.provider_stillfail,
        "stripe" to R.drawable.provider_stripe,
        "telegram" to R.drawable.provider_telegram,
        "tencentdocs" to R.drawable.provider_tencentdocs,
        "tencentmaps" to R.drawable.provider_tencentmaps,
        "wechat" to R.drawable.provider_wechat,
        "x" to R.drawable.provider_x,
        "zhipusearch" to R.drawable.provider_zhipusearch,
    )
}
