package surf.comma.android.settings

import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.auth.Account
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.Workspace
import surf.comma.android.auth.WorkspaceSelection
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.scope
import surf.comma.android.settings.devices.HomeDevices
import surf.comma.android.settings.devices.MemoryPairedDeviceStore
import surf.comma.android.ui.Appearance
import java.util.concurrent.TimeUnit

/** The pages on a real activity, with the account settings on a fake of the client core. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SettingsPagesTest {
    private val core = FakeAccountCore()
    private val sessions = FakeSessions().apply { scopes.value = scope(1) }
    // The settings' work runs on the main looper, which the test advances.
    private val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val account = SettingsRepository(sessions, core, owner).apply { start() }
    private val homeDevices = HomeDevices(sessions, core, { JSONObject().put("sessionId", "ses-this") }, { "wsp_test" },
        MemoryPairedDeviceStore(), owner).apply { start() }
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val frame = FrameLayout(activity).also(activity::setContentView)
    private var signOuts = 0
    private val opened = mutableListOf<SettingsPage>()

    private val ctx = object : SettingsContext {
        override val activity: ComponentActivity get() = this@SettingsPagesTest.activity
        override val account: SettingsRepository get() = this@SettingsPagesTest.account
        override val local = LocalSettings(object : LocalSettingsBackend {
            override fun read() = LocalSettingsState(Appearance.SYSTEM, TextSize.DEFAULT, Language.SYSTEM)
            override fun applyTheme(value: Appearance) = Unit
            override fun applyTextSize(value: TextSize) = Unit
            override fun applyLanguage(value: Language) = Unit
        })
        override val auth: AuthState = AuthState.Connected(Account("usr_test_a", "ada@example.test", null, "active"),
            WorkspaceSelection(Workspace("wsp_test", "grp_test_1", "Test"), "cnv_test_main"))
        override val replyNotifications = object : ReplyNotificationSetting {
            override val state get() = replyState
            override fun set(enabled: Boolean) {
                replySets += enabled
                replyState = if (enabled) ReplyNotificationState.ON else ReplyNotificationState.OFF
            }
        }
        override val devices get() = homeDevices
        override val workspaces get() = workspaceList
        override fun requestBluetoothPermission() = Unit
        override fun requestBluetoothOn() = Unit
        override fun open(page: SettingsPage) { opened += page }
        override fun back() = Unit
        override fun pickAvatar() = Unit
        override fun signOut() { signOuts++ }
        override fun onRender(page: SettingsPage, render: () -> Unit) {
            renders += render
            render()
        }
        override fun toast(text: String, failure: Boolean) { toasts += text to failure }
    }
    private val renders = mutableListOf<() -> Unit>()
    private val toasts = mutableListOf<Pair<String, Boolean>>()
    private val test = Workspace("wsp_test", "grp_test_1", "Test")
    private var workspaceList = listOf(test)
    private var replyState = ReplyNotificationState.ON
    private val replySets = mutableListOf<Boolean>()

    @After fun tearDown() {
        owner.cancel()
    }

    private fun show(page: SettingsPage): View {
        frame.removeAllViews()
        frame.addView(page.view, FrameLayout.LayoutParams(-1, -1))
        settle()
        return page.view
    }

    /** Rows below the fold are not attached to the list, so look through every section. */
    private fun find(page: View, id: Int): View? =
        (page as SettingsPageLayout).sections.firstNotNullOfOrNull { it.findViewById<View>(id) }

    private fun settle() = ShadowLooper.idleMainLooper(1, TimeUnit.SECONDS)

    private fun waitFor(condition: () -> Boolean) {
        settle()
        assertTrue(condition())
    }

    private fun confirmDialog(): View {
        settle()
        val dialog = ShadowDialog.getLatestDialog()
        assertNotNull("a confirmation is shown", dialog)
        assertTrue(dialog.isShowing)
        return dialog.window!!.decorView.findViewById(R.id.settings_dialog_confirm)
    }

    @Test fun signingOutAsksFirst() {
        val root = show(RootPage(ctx))
        find(root, R.id.settings_sign_out)!!.performClick()
        assertEquals("nothing happens before confirming", 0, signOuts)
        confirmDialog().performClick()
        settle()
        assertEquals(1, signOuts)
    }

    @Test fun cancellingTheConfirmationKeepsTheSession() {
        val root = show(RootPage(ctx))
        find(root, R.id.settings_sign_out)!!.performClick()
        val dialog = ShadowDialog.getLatestDialog()
        settle()
        dialog.window!!.decorView.findViewById<View>(R.id.settings_dialog_confirm).let { confirm ->
            // Cancel sits beside confirm.
            (confirm.parent as android.view.ViewGroup).getChildAt(0).performClick()
        }
        ShadowLooper.idleMainLooper(2, TimeUnit.SECONDS)
        assertEquals(0, signOuts)
        assertTrue(!dialog.isShowing)
    }

    @Test fun signingOutOtherDevicesAsksFirstAndKeepsThisOne() {
        val page = show(DevicesPage(ctx))
        waitFor { account.state.value.sessions?.size == 2 }
        settle()
        find(page, R.id.settings_devices_sign_out_others)!!.performClick()
        settle()
        assertTrue(core.called("accountSessions.revokeOthers").isEmpty())
        confirmDialog().performClick()
        waitFor { core.called("accountSessions.revokeOthers").isNotEmpty() }
        waitFor { account.state.value.sessions?.map { it.id } == listOf("ses-this") }
    }

    @Test fun commaDevicesAreListedWithAddDevice() {
        val page = show(DevicesPage(ctx))
        waitFor { homeDevices.state.value.devices?.size == 1 }
        renders.forEach { it() }
        settle()
        val add = find(page, R.id.devices_add)!!
        val card = add.parent as android.view.ViewGroup
        assertEquals(2, card.childCount)
        assertEquals("Kitchen", (card.getChildAt(0) as SettingsRow).title.text.toString())
        card.getChildAt(0).performClick()
        assertTrue(opened.last() is HomeDevicePage)
        add.performClick()
        assertTrue(opened.last() is AddDevicePage)
    }

    @Test fun deviceResultsRenderWhenLoadingStartsBeforeThePageJoinsTheStack() {
        val host = PageHost(activity) {}
        frame.addView(host, FrameLayout.LayoutParams(-1, -1))
        val pageContext = object : SettingsContext by ctx {
            override fun onRender(page: SettingsPage, render: () -> Unit) {
                host.onRender(page, render)
                // A loading update can redraw the stack before the new page's constructor returns.
                homeDevices.show(true)
                host.render()
                val loading = find(page.view, R.id.devices_home_status) as TextView
                assertTrue("loading appears before the page joins the stack", loading.isVisible)
                assertEquals(activity.getString(R.string.settings_devices_loading), loading.text.toString())
            }
        }
        val updates = owner.launch {
            combine(account.state, homeDevices.state) { _, _ -> }.collect { host.render() }
        }
        try {
            val page = DevicesPage(pageContext)
            host.push(page, animate = false)
            settle()
            val card = find(page.view, R.id.devices_add)!!.parent as android.view.ViewGroup
            assertEquals("loaded devices appear without reopening the page", 2, card.childCount)
            assertEquals("Kitchen", (card.getChildAt(0) as SettingsRow).title.text.toString())
            assertFalse(find(page.view, R.id.settings_devices_status)!!.isVisible)

            core.devices.value = listOf(core.device(status = "disconnected"))
            settle()
            assertEquals(activity.getString(R.string.devices_offline),
                (card.getChildAt(0) as SettingsRow).detail.text.toString())
        } finally {
            updates.cancel()
            host.clear()
        }
    }

    @Test fun closingHostReleasesAPageThatCannotJoinTheStack() {
        val host = PageHost(activity) {}
        frame.addView(host, FrameLayout.LayoutParams(-1, -1))
        host.push(object : SettingsPage {
            override val key = "root"
            override val view = View(activity)
        }, animate = false)
        host.pop()

        val label = TextView(activity)
        var removed = 0
        val page = object : SettingsPage {
            override val key = "late"
            override val view = label
            override fun onRemoved() { removed++ }
        }
        var status = "Loading"
        host.onRender(page) { label.text = status }
        host.push(page, animate = false)
        assertEquals("a rejected page stops its work", 1, removed)
        assertFalse(page in host.pages())

        status = "Loaded"
        host.render()
        assertEquals("a rejected page no longer renders", "Loading", label.text.toString())
        host.clear()
        assertEquals(1, removed)
    }

    @Test fun theDeviceListIsFollowedWhileOnScreen() {
        val page = DevicesPage(ctx)
        show(page)
        waitFor { homeDevices.state.value.devices?.singleOrNull()?.online == true }
        val follows = { core.subscribed.count { it.getString("topic") == "devices" } }
        assertEquals(1, follows())

        // On screen, it follows the device without being touched.
        core.devices.value = listOf(core.device(status = "disconnected"))
        waitFor { homeDevices.state.value.devices?.singleOrNull()?.online == false }

        // A page over it lets the list go; coming back follows it again, as a visit of its own.
        page.onTopChanged(false)
        page.onTopChanged(true)
        waitFor { follows() == 2 }
        val visits = core.subscribed.filter { it.getString("topic") == "devices" }.map { it.getString("visit") }
        assertEquals(2, visits.toSet().size)
        page.onRemoved()
    }

    @Test fun aPasswordIsMaskedUntilShownAndTheFieldOpensWithTheKeyboard() {
        TextFieldDialog(activity, "Home", "Enter the Wi-Fi password.", "",
            android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD, "Join", { true }) {}.show()
        settle()
        val dialog = ShadowDialog.getLatestDialog()
        val input = dialog.findViewById<android.widget.EditText>(R.id.devices_text_input)
        val reveal = dialog.findViewById<View>(R.id.devices_text_reveal)
        assertTrue(input.transformationMethod is android.text.method.PasswordTransformationMethod)
        assertTrue(input.hasFocus())
        val keyboard = dialog.window!!.attributes.softInputMode and android.view.WindowManager.LayoutParams.SOFT_INPUT_MASK_STATE
        assertEquals(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE, keyboard)
        assertEquals(activity.getString(R.string.devices_password_show), reveal.contentDescription)

        input.setText("secret")
        input.setSelection(6)
        reveal.performClick()
        assertNull(input.transformationMethod)
        assertEquals(activity.getString(R.string.devices_password_hide), reveal.contentDescription)
        assertEquals("the caret stays put", 6, input.selectionStart)
        reveal.performClick()
        assertTrue(input.transformationMethod is android.text.method.PasswordTransformationMethod)
    }

    @Test fun aPlainFieldHasNoRevealButton() {
        TextFieldDialog(activity, "Name", "Name the device.", "Kitchen",
            android.text.InputType.TYPE_CLASS_TEXT, "Save", { true }) {}.show()
        settle()
        val dialog = ShadowDialog.getLatestDialog()
        assertNull(dialog.findViewById<View>(R.id.devices_text_reveal))
        assertNull(dialog.findViewById<android.widget.EditText>(R.id.devices_text_input).transformationMethod
            as? android.text.method.PasswordTransformationMethod)
    }

    @Test fun removingACommaDeviceAsksFirstThenRevokesAndDeletesIt() {
        assertHardwareRemoval("t-circle")
    }

    @Test fun removingAStickS3AsksFirstThenRevokesAndDeletesIt() {
        assertHardwareRemoval("m5stack-sticks3")
    }

    private fun assertHardwareRemoval(clientSource: String) {
        core.devices.value = listOf(core.device().apply {
            getJSONObject("system_info").put("client_source", clientSource)
        })
        homeDevices.refresh()
        waitFor { homeDevices.state.value.devices?.size == 1 }
        val device = homeDevices.state.value.devices!!.single()
        val page = show(HomeDevicePage(ctx, device))
        find(page, R.id.devices_remove)!!.performClick()
        settle()
        assertTrue(core.called("devices.remove").isEmpty())
        confirmDialog().performClick()
        waitFor { core.called("devices.remove").isNotEmpty() }
        // Set up from another phone: no token to revoke, the core finds the voice key by its name.
        val removals = core.calls.map { it.first }.filter { it in setOf("connector.unprovisionDevice", "devices.remove") }
        assertEquals(listOf("connector.unprovisionDevice", "devices.remove"), removals)
        val unprovision = core.called("connector.unprovisionDevice").single()
        assertEquals("dev_test_1", unprovision.getString("deviceId"))
        assertFalse(unprovision.has("connectorToken"))
        assertEquals("dev_test_1", core.called("devices.remove").single().getString("device"))
    }

    @Test fun allowingOperationsAsksFirstAndStoppingThemDoesNot() {
        homeDevices.refresh()
        waitFor { homeDevices.state.value.devices?.size == 1 }
        val page = show(HomeDevicePage(ctx, homeDevices.state.value.devices!!.single()))
        val row = find(page, R.id.devices_access) as SettingsRow
        val switch = row.findSwitch()
        assertFalse(switch.checked)
        assertTrue(row.isEnabled)

        row.performClick()
        settle()
        assertTrue(core.called("devices.setAccess").isEmpty())
        confirmDialog().performClick()
        waitFor { renders.forEach { it() }; homeDevices.state.value.accessPending.isEmpty() && switch.checked }
        assertEquals(true, core.called("devices.setAccess").single().getBoolean("allow"))

        // Off goes straight through.
        val dialogs = ShadowDialog.getShownDialogs().size
        row.performClick()
        waitFor { renders.forEach { it() }; homeDevices.state.value.accessPending.isEmpty() && !switch.checked }
        assertEquals(dialogs, ShadowDialog.getShownDialogs().size)
        assertEquals(false, core.called("devices.setAccess").last().getBoolean("allow"))
    }

    @Test fun anOfflineDeviceCannotBeSwitched() {
        core.devices.value = listOf(core.device(status = "disconnected"))
        homeDevices.refresh()
        waitFor { homeDevices.state.value.devices?.size == 1 }
        val page = show(HomeDevicePage(ctx, homeDevices.state.value.devices!!.single()))
        renders.forEach { it() }
        val row = find(page, R.id.devices_access) as SettingsRow
        val notice = find(page, R.id.devices_access_notice) as android.widget.TextView
        assertFalse(row.isEnabled)
        assertEquals(View.VISIBLE, notice.visibility)
        assertEquals(activity.getString(R.string.devices_access_offline), notice.text.toString())
        row.performClick()
        settle()
        assertTrue(core.called("devices.setAccess").isEmpty())
    }

    private fun SettingsRow.findSwitch(): SettingsSwitch {
        fun walk(view: View): SettingsSwitch? = view as? SettingsSwitch
            ?: (view as? android.view.ViewGroup)?.let { group -> (0 until group.childCount).firstNotNullOfOrNull { walk(group.getChildAt(it)) } }
        return walk(this)!!
    }

    @Test fun pagesScrollWithTheScrollModuleOnly() {
        val root = show(RootPage(ctx))
        val classes = mutableListOf<String>()
        fun walk(view: View) {
            classes += view.javaClass.name
            if (view is android.view.ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        walk(root)
        assertTrue(classes.contains(surf.comma.android.scroll.widget.RecyclerView::class.java.name))
        // The groups are the list's items; the first ones are laid out on screen.
        val list = (root as SettingsPageLayout).list
        assertEquals(root.sections.size, list.adapter!!.itemCount)
        assertTrue(list.childCount > 0)
    }

    @Test fun theDeveloperSectionIsOnlyInDebugBuilds() {
        assertEquals(BuildConfig.DEBUG, DeveloperSettings.available)
        val root = show(RootPage(ctx))
        val id = activity.resources.getIdentifier("settings_developer", "id", activity.packageName)
        if (BuildConfig.DEBUG) {
            assertNotNull(find(root, id))
        } else {
            assertTrue(id == 0 || find(root, id) == null)
            assertNull(DeveloperSettings.section(ctx))
        }
    }

    @Test fun theRootShowsWhoIsSignedInAndTheCurrentValues() {
        val root = show(RootPage(ctx))
        waitFor { account.state.value.profile != null }
        renders.forEach { it() }
        settle()
        val texts = mutableListOf<String>()
        fun walk(view: View) {
            if (view is android.widget.TextView) texts += view.text.toString()
            if (view is android.view.ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        (root as SettingsPageLayout).sections.forEach(::walk)
        assertTrue(texts.contains("Ada"))
        assertTrue(texts.contains("ada@example.test"))
        assertTrue(texts.contains(activity.getString(R.string.settings_reply_notifications_on)))
        assertTrue(texts.contains(activity.getString(R.string.settings_theme_system)))
        assertTrue(texts.contains(activity.getString(R.string.settings_font_size_default)))
        assertTrue(texts.contains(activity.getString(R.string.settings_version_value, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE)))
    }

    @Test fun theReplyNotificationsRowShowsWhetherRepliesCanNotify() {
        val root = show(RootPage(ctx))
        val row = find(root, R.id.settings_reply_notifications) as SettingsRow
        fun shown(): List<String> {
            renders.forEach { it() }
            settle()
            val texts = mutableListOf<String>()
            fun walk(view: View) {
                if (view is android.widget.TextView) texts += view.text.toString()
                if (view is android.view.ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
            }
            walk(row)
            return texts
        }
        assertTrue(shown().contains(activity.getString(R.string.settings_reply_notifications_on)))
        replyState = ReplyNotificationState.BLOCKED
        assertTrue(shown().contains(activity.getString(R.string.settings_reply_notifications_blocked)))
        ctx.replyNotifications.set(false)
        assertTrue(shown().contains(activity.getString(R.string.settings_reply_notifications_off)))
    }

    @Test fun turningOnWhileBlockedAsksTheSystemAgain() {
        replyState = ReplyNotificationState.BLOCKED
        val page = show(NotificationsPage(ctx))
        val blocked = find(page, R.id.settings_notifications_toggle)!!.parent as android.view.ViewGroup
        // The blocked note under the switch is the way to ask the system again.
        val note = (0 until blocked.childCount).map(blocked::getChildAt).last { it.visibility == View.VISIBLE } as SettingsRow
        assertEquals(activity.getString(R.string.settings_reply_notifications_blocked), note.title.text.toString())
        note.performClick()
        assertEquals(listOf(true), replySets)
    }

    @Test fun turningNotificationsOffGoesStraightThrough() {
        val page = show(NotificationsPage(ctx))
        val toggle = find(page, R.id.settings_notifications_toggle) as SettingsRow
        val switch = toggle.findSwitch()
        assertTrue(switch.checked)
        toggle.performClick()
        renders.forEach { it() }
        settle()
        assertEquals(listOf(false), replySets)
        assertFalse(switch.checked)
        val section = toggle.parent as android.view.ViewGroup
        assertEquals("only the switch is left: no blocked note", listOf<View>(toggle),
            (0 until section.childCount).map(section::getChildAt).filter { it.visibility == View.VISIBLE })
    }

    @Test fun theWorkspaceRowLeadsToThePickerOnlyWhenThereIsAChoice() {
        val root = show(RootPage(ctx))
        val row = find(root, R.id.settings_workspace) as SettingsRow
        assertEquals("Test", row.value.text.toString())
        assertFalse(row.chevron.isVisible)
        row.performClick()
        assertTrue(opened.isEmpty())

        workspaceList = listOf(test, Workspace("wsp_other", "grp_test_2", "Other"))
        renders.forEach { it() }
        assertTrue(row.chevron.isVisible)
        row.performClick()
        assertTrue(opened.single() is WorkspacePage)
    }

    @Test fun theWorkspacePickerChecksTheCurrentOneAndClosesOnAChoice() {
        workspaceList = listOf(test, Workspace("wsp_other", "grp_test_2", "Other"))
        var backs = 0
        val page = show(WorkspacePage(object : SettingsContext by ctx {
            override fun back() { backs++ }
        }))
        val rows = mutableListOf<SettingsRow>()
        fun walk(view: View) {
            if (view is SettingsRow) rows += view
            else if (view is android.view.ViewGroup) for (i in 0 until view.childCount) walk(view.getChildAt(i))
        }
        (page as SettingsPageLayout).sections.forEach(::walk)
        assertEquals(listOf("Test", "Other"), rows.map { it.title.text.toString() })
        assertEquals(listOf(true, false), rows.map { it.isSelected })
        assertEquals(listOf(1f, 0f), rows.map { it.findViewWithTag<View>("check").alpha })

        // The current one only closes the picker.
        rows[0].performClick()
        assertEquals(1, backs)
        rows[1].performClick()
        settle()
        assertEquals(2, backs)
        assertTrue("a switch the core accepts says nothing", toasts.isEmpty())
    }

    @Test fun turningNotificationsOnGoesWhereTheSystemCanUnblockThem() {
        fun route(granted: Boolean = false, asked: Boolean = false, rationale: Boolean = false,
                  app: Boolean = true, channel: Boolean = true) = notificationUnblock(granted, asked, rationale, app, channel)
        // A fresh install: the dialog has never been shown.
        assertEquals(NotificationUnblock.REQUEST_PERMISSION, route())
        // Denied once: the system still shows the dialog.
        assertEquals(NotificationUnblock.REQUEST_PERMISSION, route(asked = true, rationale = true))
        // Denied for good: only system settings can grant it.
        assertEquals(NotificationUnblock.APP_SETTINGS, route(asked = true))
        // Granted, but the app's notifications are off.
        assertEquals(NotificationUnblock.APP_SETTINGS, route(granted = true, asked = true, app = false))
        // Granted, but the replies channel is off.
        assertEquals(NotificationUnblock.CHANNEL_SETTINGS, route(granted = true, asked = true, channel = false))
        assertEquals(NotificationUnblock.NONE, route(granted = true, asked = true))
    }

    @Config(qualifiers = "en-w360dp-h740dp-xxhdpi")
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    @Test fun descriptionsBesideAValueAreShownWhole() {
        val profile = show(ProfilePage(ctx))
        waitFor { account.state.value.profile != null }
        renders.forEach { it() }
        val row = find(profile, R.id.settings_name) as SettingsRow
        assertTrue("the name row has a description", row.detail.isVisible)
        // The width a row gets in its card on a 360 dp screen.
        val width = activity.resources.displayMetrics.widthPixels - (32 * activity.resources.displayMetrics.density).toInt()
        row.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        row.layout(0, 0, row.measuredWidth, row.measuredHeight)
        for (text in listOf(row.title, row.detail, row.value).filter { it.visibility == View.VISIBLE }) {
            val layout = text.layout
            assertNotNull("${text.text} is laid out", layout)
            val cut = (0 until layout.lineCount).sumOf { layout.getEllipsisCount(it) }
            assertEquals("\"${text.text}\" is cut short", 0, cut)
        }
        assertTrue("at most three lines", row.detail.lineCount <= 3)
    }
}
