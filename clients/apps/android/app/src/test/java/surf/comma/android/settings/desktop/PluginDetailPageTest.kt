package surf.comma.android.settings.desktop

import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows
import org.robolectric.shadows.ShadowDialog
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.Account
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.Workspace
import surf.comma.android.auth.WorkspaceSelection
import surf.comma.android.settings.Language
import surf.comma.android.settings.LocalSettings
import surf.comma.android.settings.LocalSettingsBackend
import surf.comma.android.settings.LocalSettingsState
import surf.comma.android.settings.ReplyNotificationSetting
import surf.comma.android.settings.ReplyNotificationState
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsRepository
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.TextSize
import surf.comma.android.settings.devices.HomeDevices
import surf.comma.android.settings.devices.MemoryPairedDeviceStore
import surf.comma.android.ui.Appearance

// Invented test data only.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "zh-rCN-w390dp-h844dp-xxhdpi")
class PluginDetailPageTest {
    private val h = DesktopHarness()
    private val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
    private val activity = controller.get()

    @After fun tearDown() {
        h.owner.cancel()
        controller.pause().stop().destroy()
    }

    private fun ctx(): SettingsContext = object : SettingsContext {
        override val activity: ComponentActivity get() = this@PluginDetailPageTest.activity
        override val account: SettingsRepository get() = throw UnsupportedOperationException()
        override val local = LocalSettings(object : LocalSettingsBackend {
            override fun read() = LocalSettingsState(Appearance.SYSTEM, TextSize.DEFAULT, Language.SYSTEM)
            override fun applyTheme(value: Appearance) = Unit
            override fun applyTextSize(value: TextSize) = Unit
            override fun applyLanguage(value: Language) = Unit
            override fun applyGlass(value: Boolean) = Unit
        })
        override val auth: AuthState = AuthState.Connected(
            Account("usr_test_a", "ada@example.test", null, "active"),
            WorkspaceSelection(Workspace("wsp_test", "grp_test_1", "Test"), "cnv_test_main"),
        )
        override val replyNotifications = object : ReplyNotificationSetting {
            override val state = ReplyNotificationState.ON
            override fun set(enabled: Boolean) = Unit
        }
        override val devices = HomeDevices(h.sessions, h.core, { json("sessionId" to "ses-1") }, { "wsp_test" }, MemoryPairedDeviceStore(), h.owner)
        override val workspaces = listOf(Workspace("wsp_test", "grp_test_1", "Test"))
        override fun requestBluetoothPermission() = Unit
        override fun requestBluetoothOn() = Unit
        override fun open(page: SettingsPage) = Unit
        override fun back() = Unit
        override fun pickAvatar() = Unit
        override fun signOut() = Unit
        override fun onRender(page: SettingsPage, render: () -> Unit) { render() }
        override fun toast(text: String, failure: Boolean) = Unit
        override val locationSharing = null
        override fun workspaceScope(): WorkspaceScope = h.scope
    }

    private lateinit var model: PluginsModel

    private fun installedMonoidPage(): PluginDetailPage {
        h.core.publish("plugins", json(
            "status" to "ready",
            "workspace" to "wsp_test",
            "plugins" to JSONArray().put(json(
                "id" to "stillfail",
                "name" to "Monoid",
                "summary" to "Monoid workspaces",
                "description" to "Connect Monoid workspaces.",
                "brand" to "stillfail",
                "installed" to true,
                "locked" to false,
                "activity" to "idle",
                "stations" to true,
                "credentialSetup" to json("key" to "STILLFAIL_CONNECT_LINE", "label" to "Connect line", "format" to "show"),
            )),
        ))
        h.core.publish("pluginStations", json(
            "stations" to JSONArray()
                .put(json(
                    "id" to "st_1",
                    "workspace" to "Alpha Studio",
                    "emoji" to "⚡",
                    "station" to "mac-mini-1",
                    "stationCount" to 3,
                    "connected" to true,
                    "connectedAt" to "2026-11-25T01:00:00Z",
                ))
                .put(json(
                    "id" to "st_2",
                    "workspace" to "Beta Lab",
                    "station" to "linux-box-2",
                    "stationCount" to 1,
                    "connected" to false,
                    "connectedAt" to "2026-11-24T12:00:00Z",
                )),
            "notificationLevel" to "action_needed",
            "notificationPending" to false,
            "pending" to null,
            "error" to null,
        ))
        model = PluginsModel(h.scope).also { it.follow() }
        val page = PluginDetailPage(ctx(), model, "stillfail")
        activity.setContentView(page.view)
        val width = activity.resources.displayMetrics.widthPixels
        val height = activity.resources.displayMetrics.heightPixels
        page.view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        page.view.layout(0, 0, width, height)
        return page
    }

    @Test fun `workspace rows say their status in words and disconnect from their actions menu`() {
        val page = installedMonoidPage()
        val sections = (page.view as SettingsPageLayout).sections.mapNotNull { (it as? ViewGroup)?.getChildAt(0) as? SettingsSection }
        val workspaces = sections.first { it.findViewWithTag<View>("station:st_1") != null }

        val onlineRow = workspaces.findViewWithTag<SettingsRow>("station:st_1")
        assertNotNull(onlineRow)
        assertEquals("Alpha Studio", onlineRow.title.text.toString())
        assertEquals("● 经 mac-mini-1 · 共 3 台 station", onlineRow.detail.text.toString())

        val offlineRow = workspaces.findViewWithTag<SettingsRow>("station:st_2")
        assertNotNull(offlineRow)
        assertEquals("Beta Lab", offlineRow.title.text.toString())
        assertEquals("● 经 linux-box-2 · 离线", offlineRow.detail.text.toString())

        // Offline notice lives in the section footer (not inside workspaces.card).
        val noticeText = activity.getString(R.string.ds_plugins_station_offline_notice)
        assertTrue(workspaces.allTextViews().any { it.isVisible && it.text.toString() == noticeText })
        assertFalse(workspaces.card.allTextViews().any { it.text.toString() == noticeText })

        // Tapping moreButton opens ActionMenu -> Disconnect -> ConfirmDialog -> plugin.station.disconnect.
        h.core.on("plugin.station.disconnect") { JSONObject() }
        val more = workspaces.findViewWithTag<View>("station_more:st_2")
        assertNotNull(more)
        more.performClick()
        ShadowLooper.idleMainLooper()
        val menu = Shadows.shadowOf(activity.application).latestPopupWindow
        assertNotNull(menu)
        val disconnectLabel = activity.getString(R.string.ds_plugins_station_disconnect)
        menu.contentView.clickRowWithText(disconnectLabel)
        ShadowLooper.idleMainLooper()

        val confirm = ShadowDialog.getLatestDialog()
        assertNotNull(confirm)
        confirm.findViewById<ViewGroup>(android.R.id.content).allTextViews()
            .last { it.text.toString() == disconnectLabel }.performClick()
        ShadowLooper.idleMainLooper()

        val called = h.core.called("plugin.station.disconnect").single()
        assertEquals("st_2", called.getString("station"))
        assertEquals("stillfail", called.getString("plugin"))
    }

    @Test fun `notification levels are checkmark rows and a save failure shows under them`() {
        val page = installedMonoidPage()
        val sections = (page.view as SettingsPageLayout).sections.mapNotNull { (it as? ViewGroup)?.getChildAt(0) as? SettingsSection }
        val notifications = sections.first { it.findViewWithTag<View>("stillfail_notifications:all") != null }
        fun row(wire: String) = notifications.findViewWithTag<SettingsRow>("stillfail_notifications:$wire")
        assertTrue(row("action_needed").isSelected)
        assertFalse(row("all").isSelected)
        assertEquals(activity.getString(R.string.ds_plugins_stillfail_notifications_all_description), row("all").detail.text.toString())

        // Picking a level checks it at once and saves it.
        h.core.on("plugin.station.notificationLevel.set") { JSONObject() }
        row("all").performClick()
        ShadowLooper.idleMainLooper()
        val call = h.core.called("plugin.station.notificationLevel.set").single()
        assertEquals("all", call.getString("level"))
        assertEquals("stillfail", call.getString("plugin"))
        assertTrue(row("all").isSelected)
        assertFalse(row("action_needed").isSelected)

        h.core.publish("pluginStations", json(
            "stations" to JSONArray(),
            "notificationLevel" to "all",
            "notificationPending" to false,
            "pending" to null,
            "error" to "notification_save_failed",
        ))
        val saveFailed = activity.getString(R.string.ds_plugins_stillfail_notifications_save_failed)
        assertTrue(notifications.allTextViews().any { it.isVisible && it.text.toString() == saveFailed })
        assertFalse(notifications.card.allTextViews().any { it.text.toString() == saveFailed })
    }

    @Test fun `a connected plugin shows no status group and removes from the bottom of the page`() {
        val page = installedMonoidPage()
        val sections = (page.view as SettingsPageLayout).sections.mapNotNull { (it as? ViewGroup)?.getChildAt(0) as? SettingsSection }
        val visible = sections.filter { it.isVisible }
        val remove = activity.getString(R.string.ds_plugins_remove)
        assertFalse(visible.any { s -> s.allTextViews().any { it.text.toString() == activity.getString(R.string.ds_status) } })
        assertTrue(visible.last().card.allTextViews().any { it.text.toString() == remove })
    }

    @Test fun `a connect line shows under the workspaces and closing it before a copy asks first`() {
        val page = installedMonoidPage()
        h.core.on("plugin.notice.claim") { true }
        kotlinx.coroutines.runBlocking { model.receiveNotice(json(
            "id" to 7, "kind" to "configure", "workspace" to "wsp_test", "plugin" to "stillfail", "origin" to "plugins",
            "configuration" to json("workspace" to "wsp_test", "plugin" to json("id" to "stillfail", "name" to "Monoid"), "operation" to "install",
                "setup" to json("key" to "STILLFAIL_CONNECT_LINE", "label" to "Connect line", "format" to "show", "value" to "comma https://example.test tok_test")),
        )) }
        ShadowLooper.idleMainLooper()
        val sections = (page.view as SettingsPageLayout).sections.mapNotNull { (it as? ViewGroup)?.getChildAt(0) as? SettingsSection }
        val workspaces = sections.first { it.findViewWithTag<View>("connect_line_done") != null }
        assertTrue(workspaces.allTextViews().any { it.text.toString() == "comma https://example.test tok_test" })
        assertTrue(workspaces.allTextViews().any { it.isVisible && it.text.toString() == activity.getString(R.string.ds_plugins_show_once) })

        workspaces.findViewWithTag<View>("connect_line_done").performClick()
        ShadowLooper.idleMainLooper()
        assertNotNull(ShadowDialog.getLatestDialog())
        assertNotNull(workspaces.findViewWithTag<View>("connect_line_done"))
    }
}

private fun View.clickRowWithText(label: String) {
    var current: View? = allTextViews().first { it.text.toString() == label }
    while (current != null && !current.hasOnClickListeners()) {
        current = current.parent as? View
    }
    assertNotNull("clickable row for '$label'", current)
    current!!.performClick()
}

private fun View.allTextViews(): List<TextView> {
    val out = ArrayList<TextView>()
    fun walk(v: View) {
        if (v is TextView) out += v
        if (v is ViewGroup) for (i in 0 until v.childCount) walk(v.getChildAt(i))
    }
    walk(this)
    return out
}
