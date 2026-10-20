package surf.comma.android.settings

import android.view.View
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * The network failures this process has logged (debug builds log a category and status only, never
 * a URL, body or token). An app may read its own log without extra permissions.
 */
internal class NetworkLogPage(ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_developer_network_log)) { ctx.back() }
    override val view: View = layout
    private val body = activity.text(Level.SMALL, R.color.token_text_secondary).apply {
        id = R.id.settings_developer_network_log_text
        setTextIsSelectable(true)
        typeface = android.graphics.Typeface.MONOSPACE
        setPadding(activity.dp(4), 0, activity.dp(4), 0)
    }
    private val loading: Job

    init {
        layout.section(body, top = 0)
        loading = activity.lifecycleScope.launch {
            val lines = withContext(Dispatchers.IO) {
                runCatching {
                    val process = ProcessBuilder("logcat", "-d", "-v", "time", "-s", "NetworkFailure:D")
                        .redirectErrorStream(true).start()
                    process.inputStream.bufferedReader().use { reader -> reader.readLines() }
                        .filterNot { it.startsWith("---------") }
                        .takeLast(MAX_LINES)
                        .also { process.destroy() }
                }.getOrDefault(emptyList())
            }
            body.text = if (lines.isEmpty()) activity.getString(R.string.settings_developer_network_log_empty)
            else lines.asReversed().joinToString("\n")
        }
    }

    override fun onRemoved() = loading.cancel()

    companion object {
        const val KEY = "network-log"
        private const val MAX_LINES = 200
    }
}
