package surf.comma.android.settings

import android.app.Application
import android.app.LocaleManager
import android.app.UiModeManager
import android.os.LocaleList
import org.robolectric.RuntimeEnvironment
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.ui.Appearance
import surf.comma.android.ui.theme.DesignTypography

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalSettingsTest {
    private val app = RuntimeEnvironment.getApplication()

    @After fun tearDown() {
        DesignTypography.promoteOneStep = false
    }

    private class FakeBackend(var fail: Boolean = false) : LocalSettingsBackend {
        val applied = mutableListOf<Any>()
        override fun read() = LocalSettingsState(Appearance.SYSTEM, TextSize.DEFAULT, Language.SYSTEM)
        override fun applyTheme(value: Appearance) = apply(value)
        override fun applyTextSize(value: TextSize) = apply(value)
        override fun applyLanguage(value: Language) = apply(value)
        private fun apply(value: Any) {
            if (fail) throw IllegalStateException("not saved")
            applied += value
        }
    }

    @Test fun changesShowAtOnceAndAreApplied() {
        val backend = FakeBackend()
        val settings = LocalSettings(backend)
        settings.setTheme(Appearance.DARK)
        settings.setTextSize(TextSize.LARGE)
        settings.setLanguage(Language.ENGLISH)
        assertEquals(LocalSettingsState(Appearance.DARK, TextSize.LARGE, Language.ENGLISH), settings.state.value)
        assertEquals(listOf(Appearance.DARK, TextSize.LARGE, Language.ENGLISH), backend.applied)
        // Choosing the current value again does nothing.
        settings.setTheme(Appearance.DARK)
        assertEquals(3, backend.applied.size)
    }

    @Test fun aChangeThatCannotBeAppliedRevertsAndSaysSo() = runBlocking {
        val backend = FakeBackend(fail = true)
        val settings = LocalSettings(backend)
        val notice = async(kotlinx.coroutines.Dispatchers.Unconfined) { settings.notices.first() }
        settings.setTextSize(TextSize.LARGE)
        assertEquals(TextSize.DEFAULT, settings.state.value.textSize)
        assertEquals(SettingsNotice(SettingsAction.TEXT_SIZE, SettingsProblem.STORAGE), notice.await())
    }

    @Test fun languageUsesThePerAppLocaleAndFollowsTheSystemWhenCleared() {
        val android = AndroidLocalSettings(app)
        val locales = app.getSystemService(LocaleManager::class.java)
        android.applyLanguage(Language.ENGLISH)
        assertEquals(LocaleList.forLanguageTags("en"), locales.applicationLocales)
        assertEquals(Language.ENGLISH, android.read().language)
        android.applyLanguage(Language.CHINESE)
        assertEquals("zh", locales.applicationLocales[0].language)
        assertEquals(Language.CHINESE, android.read().language)
        android.applyLanguage(Language.SYSTEM)
        assertTrue(locales.applicationLocales.isEmpty)
        assertEquals(Language.SYSTEM, android.read().language)
    }

    @Test fun themeUsesThePerAppNightMode() {
        val android = AndroidLocalSettings(app)
        val modes = app.getSystemService(UiModeManager::class.java)
        android.applyTheme(Appearance.DARK)
        assertEquals(UiModeManager.MODE_NIGHT_YES, shadowNightMode(modes))
        assertEquals(Appearance.DARK, android.read().theme)
        android.applyTheme(Appearance.LIGHT)
        assertEquals(UiModeManager.MODE_NIGHT_NO, shadowNightMode(modes))
        android.applyTheme(Appearance.SYSTEM)
        assertEquals(UiModeManager.MODE_NIGHT_AUTO, shadowNightMode(modes))
        assertEquals(Appearance.SYSTEM, android.read().theme)
    }

    @Test fun largeTextPromotesTheTypeScaleAndChatTextByTheSameRatio() {
        val android = AndroidLocalSettings(app)
        android.applyTextSize(TextSize.LARGE)
        assertTrue(DesignTypography.promoteOneStep)
        assertEquals(TextSize.LARGE, android.read().textSize)
        assertEquals(18f, DesignTypography.regular.sp)
        assertEquals(1.2f, DesignTypography.chatScale(), 0.0001f)

        // A new process reads it back before the first screen.
        DesignTypography.promoteOneStep = false
        TextSizeStore.load(app)
        assertTrue(DesignTypography.promoteOneStep)

        android.applyTextSize(TextSize.DEFAULT)
        assertFalse(DesignTypography.promoteOneStep)
        assertEquals(1f, DesignTypography.chatScale(), 0f)
    }

    private fun shadowNightMode(modes: UiModeManager): Int =
        org.robolectric.Shadows.shadowOf(modes).applicationNightMode
}
