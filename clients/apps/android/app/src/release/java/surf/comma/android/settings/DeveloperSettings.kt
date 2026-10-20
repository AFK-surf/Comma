package surf.comma.android.settings

import android.view.View

/** Non-debug builds have no developer section. */
internal object DeveloperSettings {
    const val available = false
    fun section(@Suppress("UNUSED_PARAMETER") ctx: SettingsContext): Pair<View, () -> Unit>? = null
    fun restores(@Suppress("UNUSED_PARAMETER") key: String) = false
    fun page(@Suppress("UNUSED_PARAMETER") ctx: SettingsContext, @Suppress("UNUSED_PARAMETER") key: String): SettingsPage? = null
}
