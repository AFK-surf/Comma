package surf.comma.android.miniapps

import android.app.Activity
import android.widget.LinearLayout
import androidx.core.view.isVisible
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.ChoiceMenu
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignTypography.Level

/** Who can open an app, in the order every picker shows them. */
internal object MiniAppVisibility {
    val values = listOf("private", "workspace", "link")

    fun label(activity: Activity, value: String) = activity.getString(when (value) {
        "private" -> R.string.mini_apps_access_private
        "workspace" -> R.string.mini_apps_access_workspace
        else -> R.string.mini_apps_access_link
    })
}

/**
 * Publication names the previewed Version and its build review. The existing server path accepts the review and
 * merges the build at the previewed commit before it makes the Version live. A conflict stays visible; nothing is
 * retried automatically.
 */
internal class MiniAppPublishDialog(
    private val activity: Activity,
    private val model: MiniAppsModel,
    private val publication: MiniAppPublication,
) : SettingsDialog(activity) {
    private var visibility = "workspace"
    private var busy = false
    private val access = SettingsRow(activity, null, activity.getString(R.string.mini_apps_access_title))
    private val failure = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val publish = button(activity.getString(R.string.mini_app_publish_version, publication.version), R.color.token_bg_brand_solid, null)

    init {
        card.addView(title(activity.getString(R.string.mini_app_publish_title)))
        val section = SettingsSection(activity, null)
            .add(SettingsRow(activity, null, model.state.value.app?.name.orEmpty()).value("v${publication.version}"))
            .add(access.onClick { row ->
                ChoiceMenu.show(row, MiniAppVisibility.values.map { MiniAppVisibility.label(activity, it) },
                    MiniAppVisibility.values.indexOf(visibility)) { index ->
                    visibility = MiniAppVisibility.values[index]
                    render()
                }
            })
        card.addView(section, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(16) })
        card.addView(message(activity.getString(R.string.mini_app_publish_message, publication.version)),
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        card.addView(failure, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            val cancel = button(activity.getString(R.string.settings_cancel), R.color.token_bg_quaternary, R.color.token_text_primary)
            cancel.setOnClickListener { if (!busy) dismiss() }
            addView(cancel, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
            addView(publish, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(8) })
        }
        card.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        publish.setOnClickListener { confirm() }
        render()
    }

    private fun render() {
        access.value(MiniAppVisibility.label(activity, visibility), chevron = true)
        publish.isEnabled = !busy
        publish.alpha = if (busy) 0.5f else 1f
    }

    private fun confirm() {
        if (busy) return
        busy = true
        failure.isVisible = false
        render()
        (activity as LifecycleOwner).lifecycleScope.launch {
            val published = model.publish(publication, visibility)
            busy = false
            render()
            if (published) dismiss()
            else {
                failure.text = model.state.value.failure ?: activity.getString(R.string.mini_apps_action_failed)
                failure.isVisible = true
            }
        }
    }
}
