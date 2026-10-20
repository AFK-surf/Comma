package surf.comma.android.settings

import android.view.View
import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph

/** Debug builds only: where the app talks to, which build this is, and the network failures seen. */
internal object DeveloperSettings {
    const val available = true

    /** The section and how to refresh it; the root page calls it on every render. */
    fun section(ctx: SettingsContext): Pair<View, () -> Unit> {
        val activity = ctx.activity
        val backend = SettingsRow(activity, R.drawable.ic_settings_backend, activity.getString(R.string.settings_developer_backend))
            .value(BuildConfig.BACKEND_BASE_URL.ifBlank { activity.getString(R.string.settings_developer_unset) })
        val build = SettingsRow(activity, R.drawable.ic_settings_build, activity.getString(R.string.settings_developer_build))
            .value("${BuildConfig.FLAVOR} · ${BuildConfig.BUILD_TYPE}")
        val generation = SettingsRow(activity, R.drawable.ic_settings_session, activity.getString(R.string.settings_developer_generation))
        val log = SettingsRow(activity, R.drawable.ic_settings_log, activity.getString(R.string.settings_developer_network_log))
            .value(null, chevron = true).onClick { ctx.open(NetworkLogPage(ctx)) }
        backend.id = R.id.settings_developer_backend
        log.id = R.id.settings_developer_network_log
        val section = SettingsSection(activity, activity.getString(R.string.settings_developer))
            .add(backend).add(build).add(generation).add(log)
        section.id = R.id.settings_developer
        return section to {
            generation.value(AuthGraph.get(activity).conversationScope.value?.generation?.toString()
                ?: activity.getString(R.string.settings_developer_unset))
        }
    }

    fun restores(key: String) = key == NetworkLogPage.KEY

    fun page(ctx: SettingsContext, key: String): SettingsPage? = if (key == NetworkLogPage.KEY) NetworkLogPage(ctx) else null
}
