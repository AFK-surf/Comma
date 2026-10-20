package surf.comma.android.ui

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration

enum class Appearance {
    SYSTEM,
    LIGHT,
    DARK,
}

/** Survives process death; applied through [UiModeManager] so resource night qualifiers flip. */
object AppearanceStore {
    private const val PREFS = "appearance"
    private const val KEY = "mode"

    fun get(context: Context): Appearance {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, Appearance.SYSTEM.name)
        return Appearance.entries.firstOrNull { it.name == raw } ?: Appearance.SYSTEM
    }

    fun set(context: Context, appearance: Appearance) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, appearance.name)
            .apply()
        apply(context, appearance)
    }

    fun cycle(context: Context): Appearance {
        val next = when (get(context)) {
            Appearance.SYSTEM -> Appearance.LIGHT
            Appearance.LIGHT -> Appearance.DARK
            Appearance.DARK -> Appearance.SYSTEM
        }
        set(context, next)
        return next
    }

    fun apply(context: Context, appearance: Appearance = get(context)) {
        val mode = when (appearance) {
            Appearance.SYSTEM -> UiModeManager.MODE_NIGHT_AUTO
            Appearance.LIGHT -> UiModeManager.MODE_NIGHT_NO
            Appearance.DARK -> UiModeManager.MODE_NIGHT_YES
        }
        context.applicationContext
            .getSystemService(UiModeManager::class.java)
            .setApplicationNightMode(mode)
    }

    fun isNight(context: Context): Boolean =
        context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
}
