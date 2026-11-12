package surf.comma.android.settings

import android.app.Activity
import android.app.Application
import android.app.LocaleManager
import android.content.Context
import android.os.Bundle
import android.os.LocaleList
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import surf.comma.android.ui.Appearance
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.widget.LiquidGlass
import java.util.Collections
import java.util.WeakHashMap

enum class TextSize { DEFAULT, LARGE }

/** [tag] is the BCP 47 tag handed to the system; null follows the system language. */
enum class Language(val tag: String?) {
    SYSTEM(null),
    CHINESE("zh-CN"),
    ENGLISH("en");

    companion object {
        fun of(locales: LocaleList): Language = when (locales.takeUnless { it.isEmpty }?.get(0)?.language) {
            null -> SYSTEM
            "zh" -> CHINESE
            "en" -> ENGLISH
            else -> SYSTEM
        }
    }
}

data class LocalSettingsState(val theme: Appearance, val textSize: TextSize, val language: Language, val glass: Boolean = false)

/** Where the device-only preferences live and how they take effect. */
interface LocalSettingsBackend {
    fun read(): LocalSettingsState
    fun applyTheme(value: Appearance)
    fun applyTextSize(value: TextSize)
    fun applyLanguage(value: Language)
    fun applyGlass(value: Boolean)
}

/**
 * Theme, text size, language and the experimental glass: kept on this device and applied at once. The new value shows
 * immediately; if applying it fails, the previous value comes back with a [SettingsNotice].
 */
class LocalSettings(private val backend: LocalSettingsBackend) {
    private val mutableState = MutableStateFlow(backend.read())
    val state: StateFlow<LocalSettingsState> = mutableState.asStateFlow()
    private val mutableNotices = MutableSharedFlow<SettingsNotice>(extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val notices: SharedFlow<SettingsNotice> = mutableNotices.asSharedFlow()

    fun setTheme(value: Appearance) = change(SettingsAction.THEME, { it.theme == value }, { it.copy(theme = value) }) {
        backend.applyTheme(value)
    }

    fun setTextSize(value: TextSize) = change(SettingsAction.TEXT_SIZE, { it.textSize == value }, { it.copy(textSize = value) }) {
        backend.applyTextSize(value)
    }

    fun setLanguage(value: Language) = change(SettingsAction.LANGUAGE, { it.language == value }, { it.copy(language = value) }) {
        backend.applyLanguage(value)
    }

    fun setGlass(value: Boolean) = change(SettingsAction.GLASS, { it.glass == value }, { it.copy(glass = value) }) {
        backend.applyGlass(value)
    }

    private fun change(
        action: SettingsAction,
        unchanged: (LocalSettingsState) -> Boolean,
        next: (LocalSettingsState) -> LocalSettingsState,
        apply: () -> Unit,
    ) {
        val before = mutableState.value
        if (unchanged(before)) return
        mutableState.update(next)
        try {
            apply()
        } catch (_: Exception) {
            mutableState.value = before
            mutableNotices.tryEmit(SettingsNotice(action, SettingsProblem.STORAGE))
        }
    }
}

/**
 * The Android side: the theme through [AppearanceStore] (the platform's per-app night mode), the
 * language through [LocaleManager] (Android's per-app language, also shown in system settings), and
 * the text size as a preference that promotes [DesignTypography] one step, and the glass as a preference
 * that [LiquidGlass] reads. The first two restart visible screens by themselves; the others recreate them
 * through [OpenActivities].
 */
class AndroidLocalSettings(context: Context) : LocalSettingsBackend {
    private val app = context.applicationContext

    override fun read() = LocalSettingsState(AppearanceStore.get(app), TextSizeStore.get(app), readLanguage(), GlassStore.get(app))

    override fun applyTheme(value: Appearance) = AppearanceStore.set(app, value)

    override fun applyTextSize(value: TextSize) {
        TextSizeStore.set(app, value)
        OpenActivities.recreateAll()
    }

    override fun applyGlass(value: Boolean) {
        GlassStore.set(app, value)
        OpenActivities.recreateAll()
    }

    override fun applyLanguage(value: Language) {
        app.getSystemService(LocaleManager::class.java).applicationLocales =
            value.tag?.let(LocaleList::forLanguageTags) ?: LocaleList.getEmptyLocaleList()
    }

    private fun readLanguage(): Language =
        Language.of(app.getSystemService(LocaleManager::class.java).applicationLocales)
}

/** Text size preference. [load] runs before the first screen binds its typography. */
object TextSizeStore {
    private const val PREFS = "appearance"
    private const val KEY = "text_size"

    fun get(context: Context): TextSize {
        val raw = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
        return TextSize.entries.firstOrNull { it.name == raw } ?: TextSize.DEFAULT
    }

    fun set(context: Context, value: TextSize) {
        check(context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, value.name).commit()) { "Text size not saved" }
        DesignTypography.promoteOneStep = value == TextSize.LARGE
    }

    fun load(context: Context) {
        DesignTypography.promoteOneStep = get(context) == TextSize.LARGE
    }
}

/** The experimental glass, off until the member turns it on. [load] runs before the first screen binds. */
object GlassStore {
    private const val PREFS = "appearance"
    private const val KEY = "glass"

    fun get(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)

    fun set(context: Context, value: Boolean) {
        check(context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY, value).commit()) { "Glass not saved" }
        LiquidGlass.enabled = value
    }

    fun load(context: Context) {
        LiquidGlass.enabled = get(context)
    }
}

/** Activities that are alive now, so a typography change can rebuild every screen. */
object OpenActivities : Application.ActivityLifecycleCallbacks {
    private val open: MutableSet<Activity> = Collections.newSetFromMap(WeakHashMap())

    fun register(application: Application) = application.registerActivityLifecycleCallbacks(this)

    /** Call on the main thread. */
    fun recreateAll() = open.toList().forEach { if (!it.isFinishing) it.recreate() }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) { open += activity }
    override fun onActivityDestroyed(activity: Activity) { open -= activity }
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
}
