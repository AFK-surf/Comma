package surf.comma.android.settings

import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.settings.devices.HomeDevices
import surf.comma.android.ui.Appearance
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/** What every settings page can reach. */
internal interface SettingsContext {
    val activity: androidx.activity.ComponentActivity
    val account: SettingsRepository
    val local: LocalSettings
    val auth: AuthState
    val replyNotifications: ReplyNotificationSetting
    /** The workspace's Connector devices, including the Comma devices this phone sets up. */
    val devices: HomeDevices
    /** The member's Workspaces, as the Task list's read names them. */
    val workspaces: List<surf.comma.android.auth.Workspace>
    fun open(page: SettingsPage)
    /** Asks for the Bluetooth permissions, or opens the app's settings once they were denied for good. */
    fun requestBluetoothPermission()
    fun requestBluetoothOn()
    fun back()
    fun pickAvatar()
    /** Signs out through the account's own logout; the confirmation has already been given. */
    fun signOut()
    /** Pages redraw from the latest state through this. */
    fun onRender(page: SettingsPage, render: () -> Unit)
    /** Shows a short notice; [failure] marks it as one. */
    fun toast(text: String, failure: Boolean)
}

enum class ReplyNotificationState { ON, OFF, BLOCKED }

/** The reply notifications switch. Turning it on may ask for the permission or open system settings. */
internal interface ReplyNotificationSetting {
    /** [ReplyNotificationState.BLOCKED]: on here, but the system does not let notifications through. */
    val state: ReplyNotificationState
    fun set(enabled: Boolean)
}

/** What turning reply notifications on has to do before they can reach the user. */
internal enum class NotificationUnblock { NONE, REQUEST_PERMISSION, APP_SETTINGS, CHANNEL_SETTINGS }

/**
 * The permission dialog while the system still shows it; once denied for good, or with the app's
 * notifications switched off, the app's notification settings; with only the replies channel
 * switched off, that channel's settings.
 */
internal fun notificationUnblock(
    permissionGranted: Boolean,
    askedBefore: Boolean,
    showsRationale: Boolean,
    appEnabled: Boolean,
    channelEnabled: Boolean,
): NotificationUnblock = when {
    !permissionGranted && (!askedBefore || showsRationale) -> NotificationUnblock.REQUEST_PERMISSION
    !permissionGranted || !appEnabled -> NotificationUnblock.APP_SETTINGS
    !channelEnabled -> NotificationUnblock.CHANNEL_SETTINGS
    else -> NotificationUnblock.NONE
}

internal fun SettingsContext.displayName(): String {
    val account = (auth as? AuthState.Connected)?.account
    val profile = this.account.state.value.profile
    return profile?.displayName(account?.name) ?: account?.name?.takeIf { it.isNotBlank() } ?: account?.email.orEmpty()
}

internal fun SettingsContext.email(): String =
    account.state.value.profile?.email ?: (auth as? AuthState.Connected)?.account?.email.orEmpty()

/**
 * The main list, as the iOS app's Settings tab: the member (photo, name and email, leading to the profile), the
 * Workspace, Comma's own settings (notifications and Task labels), devices, the app itself and sign-out. The
 * Android app adds its own appearance and text size, the open-source licenses and, in debug builds, the
 * developer settings.
 */
internal class RootPage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val tab = (ctx as? SettingsHost)?.isTab == true
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_title), showBack = !tab) { ctx.back() }
    override val view: View = layout
    private val auth = surf.comma.android.auth.AuthGraph.get(activity)

    private val avatar = AvatarView(activity)
    private val name = activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
        maxLines = 2
    }
    private val email = activity.text(Level.SMALL, R.color.token_text_tertiary).apply { maxLines = 1 }
    private val workspace = SettingsRow(activity, R.drawable.ic_settings_workspace, activity.getString(R.string.settings_workspace))
    private val workspaceSection = SettingsSection(activity, null).add(workspace)
    private val notifications = SettingsRow(activity, R.drawable.ic_settings_bell, activity.getString(R.string.settings_notifications))
    private val labels = SettingsRow(activity, R.drawable.ic_filter_label, activity.getString(R.string.settings_task_labels))
    private val language = SettingsRow(activity, R.drawable.ic_settings_globe, activity.getString(R.string.settings_language))
    private val theme = SettingsRow(activity, R.drawable.ic_settings_theme, activity.getString(R.string.settings_theme))
    private val textSize = SettingsRow(activity, R.drawable.ic_settings_text_size, activity.getString(R.string.settings_font_size))
    private var developer: (() -> Unit)? = null

    init {
        val account = LinearLayout(activity).apply {
            id = R.id.settings_profile_header
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(72)
            setPadding(activity.dp(14), activity.dp(12), activity.dp(10), activity.dp(12))
            addView(avatar, LinearLayout.LayoutParams(activity.dp(48), activity.dp(48)))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(name)
                addView(email, LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(2) })
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(12) })
            addView(android.widget.ImageView(activity).apply {
                setImageResource(R.drawable.ic_settings_chevron)
                imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_quaternary))
            }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
            contentDescription = activity.getString(R.string.settings_profile)
            PressFeedback(this, R.color.token_surface_ink, scale = false)
            setOnClickListener { ctx.open(ProfilePage(ctx)) }
        }
        layout.section(SettingsSection(activity, null).add(account), top = 0)

        workspace.id = R.id.settings_workspace
        layout.section(workspaceSection)

        notifications.id = R.id.settings_reply_notifications
        notifications.value(null, chevron = true).onClick { ctx.open(NotificationsPage(ctx)) }
        labels.id = R.id.settings_label_changes
        labels.value(null, chevron = true).onClick { ctx.open(surf.comma.android.labels.TaskLabelsPage(ctx)) }
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_section_comma)).add(notifications).add(labels))

        val devices = SettingsRow(activity, R.drawable.ic_settings_signed_in, activity.getString(R.string.settings_signed_in_devices))
            .value(null, chevron = true).onClick { ctx.open(DevicesPage(ctx)) }
        devices.id = R.id.settings_devices
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_section_devices)).add(devices))

        language.id = R.id.settings_language
        language.onClick { row ->
            val options = Language.entries
            ChoiceMenu.show(row, options.map(::languageLabel), options.indexOf(ctx.local.state.value.language)) {
                ctx.local.setLanguage(options[it])
            }
        }
        theme.id = R.id.settings_theme
        theme.onClick { row ->
            val options = Appearance.entries
            ChoiceMenu.show(row, options.map(::themeLabel), options.indexOf(ctx.local.state.value.theme)) { ctx.local.setTheme(options[it]) }
        }
        textSize.id = R.id.settings_font_size
        textSize.onClick { row ->
            val options = TextSize.entries
            ChoiceMenu.show(row, options.map(::textSizeLabel), options.indexOf(ctx.local.state.value.textSize)) {
                ctx.local.setTextSize(options[it])
            }
        }
        val version = SettingsRow(activity, R.drawable.ic_settings_info, activity.getString(R.string.settings_version))
            .value(activity.getString(R.string.settings_version_value, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        version.id = R.id.settings_version
        val licenses = SettingsRow(activity, R.drawable.ic_settings_licenses, activity.getString(R.string.settings_licenses))
            .value(null, chevron = true).onClick { ctx.open(LicensesPage(ctx)) }
        licenses.id = R.id.settings_licenses
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_section_general))
            .add(language).add(theme).add(textSize).add(version).add(licenses))

        developer = DeveloperSettings.section(ctx)?.also { layout.section(it.first) }?.second

        val signOut = SettingsRow(activity, R.drawable.ic_settings_arrow_box_left, activity.getString(R.string.settings_sign_out),
            tint = R.color.token_text_error_primary).onClick { confirmSignOut() }
        signOut.id = R.id.settings_sign_out
        signOut.icon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_error_primary))
        layout.section(SettingsSection(activity, null).add(signOut))

        ctx.onRender(this, ::render)
        if (ctx.account.state.value.profile == null) ctx.account.refreshProfile()
    }

    private fun confirmSignOut() {
        ConfirmDialog(activity, activity.getString(R.string.settings_sign_out_confirm), activity.getString(R.string.settings_sign_out_message),
            activity.getString(R.string.settings_sign_out), destructive = true) { ctx.signOut() }.show()
    }

    private fun render() {
        val state = ctx.account.state.value
        val shownName = ctx.displayName()
        name.text = shownName
        email.text = ctx.email()
        email.isVisible = email.text.isNotEmpty() && email.text != shownName
        avatar.show(state.avatar, shownName, state.generation)
        val connected = ctx.auth as? AuthState.Connected
        val workspaces = ctx.workspaces
        workspace.value(connected?.selection?.workspace?.name ?: activity.getString(R.string.settings_choose_workspace),
            chevron = workspaces.size > 1)
        workspace.onClick(if (workspaces.size > 1) { _ -> ctx.open(WorkspacePage(ctx)) } else null)
        workspaceSection.isVisible = connected != null
        notifications.value(activity.getString(when (ctx.replyNotifications.state) {
            ReplyNotificationState.ON -> R.string.settings_reply_notifications_on
            ReplyNotificationState.OFF -> R.string.settings_reply_notifications_off
            ReplyNotificationState.BLOCKED -> R.string.settings_reply_notifications_blocked
        }), chevron = true)
        labels.isVisible = connected != null
        val local = ctx.local.state.value
        language.value(languageLabel(local.language))
        theme.value(themeLabel(local.theme))
        textSize.value(textSizeLabel(local.textSize))
        developer?.invoke()
    }

    private fun languageLabel(value: Language) = activity.getString(when (value) {
        Language.SYSTEM -> R.string.settings_language_system
        Language.CHINESE -> R.string.settings_language_chinese
        Language.ENGLISH -> R.string.settings_language_english
    })

    private fun themeLabel(value: Appearance) = activity.getString(when (value) {
        Appearance.SYSTEM -> R.string.settings_theme_system
        Appearance.LIGHT -> R.string.settings_theme_light
        Appearance.DARK -> R.string.settings_theme_dark
    })

    private fun textSizeLabel(value: TextSize) = activity.getString(when (value) {
        TextSize.DEFAULT -> R.string.settings_font_size_default
        TextSize.LARGE -> R.string.settings_font_size_large
    })

    companion object { const val KEY = "root" }
}

/** Picture and name. The email is shown but cannot be changed here. */
internal class ProfilePage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_profile)) { ctx.back() }
    override val view: View = layout
    private val avatar = AvatarView(activity)
    private val change = SettingsRow(activity, R.drawable.ic_composer_photo, activity.getString(R.string.settings_avatar_choose))
    private val remove = SettingsRow(activity, R.drawable.ic_settings_trash, activity.getString(R.string.settings_avatar_remove),
        tint = R.color.token_text_error_primary)
    private val name = SettingsRow(activity, R.drawable.ic_settings_edit, activity.getString(R.string.settings_name))
    private val email = SettingsRow(activity, null, activity.getString(R.string.settings_email))

    init {
        layout.section(LinearLayout(activity).apply {
            gravity = Gravity.CENTER
            setPadding(0, activity.dp(8), 0, activity.dp(8))
            addView(avatar, LinearLayout.LayoutParams(activity.dp(96), activity.dp(96)))
        }, top = 0)
        change.id = R.id.settings_avatar_choose
        change.onClick { ctx.pickAvatar() }
        remove.id = R.id.settings_avatar_remove
        remove.icon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_fg_error))
        remove.onClick { ctx.account.removeAvatar() }
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_avatar)).add(change).add(remove))
        name.id = R.id.settings_name
        name.detail(activity.getString(R.string.settings_name_description))
        name.onClick {
            NameDialog(activity, ctx.account.state.value.profile?.name ?: ctx.displayName()) { ctx.account.rename(it) }.show()
        }
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_account)).add(name).add(email))
        ctx.onRender(this, ::render)
    }

    private fun render() {
        val state = ctx.account.state.value
        val shown = ctx.displayName()
        avatar.show(state.avatar, shown, state.generation)
        name.value(shown, chevron = true)
        name.isEnabled = state.profile != null
        email.value(ctx.email())
        remove.isVisible = state.avatar != AvatarSource.None
        change.isEnabled = state.profile != null
    }

    companion object { const val KEY = "profile" }
}

/**
 * The workspace's devices (Comma devices and computers running Connector, with "Add device"), then
 * where this account is signed in; other sessions can be signed out one by one or all together.
 */
internal class DevicesPage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_devices)) { ctx.back() }
    override val view: View = layout
    private val homeList = SettingsSection(activity, activity.getString(R.string.devices_section))
    private val homeStatus = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
        id = R.id.devices_home_status
        setPadding(activity.dp(16), activity.dp(12), activity.dp(16), 0)
    }
    private val addDevice = SettingsRow(activity, R.drawable.ic_composer_plus, activity.getString(R.string.devices_add))
        .value(null, chevron = true).onClick { ctx.open(AddDevicePage(ctx)) }
    private var shownHome: List<HomeDevice>? = null
    private val list = SettingsSection(activity, activity.getString(R.string.settings_devices_signed_in))
    private val status = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
        id = R.id.settings_devices_status
        setPadding(activity.dp(16), activity.dp(12), activity.dp(16), 0)
    }
    private val removeOthers = SettingsRow(activity, R.drawable.ic_settings_sign_out, activity.getString(R.string.settings_devices_sign_out_others),
        tint = R.color.token_text_error_primary)
    private val othersSection = SettingsSection(activity, null).add(removeOthers)
    private var shown: List<DeviceSession>? = null

    init {
        addDevice.id = R.id.devices_add
        layout.section(homeList, top = 0)
        layout.section(homeStatus, top = 0)
        layout.section(list)
        layout.section(status, top = 0)
        removeOthers.id = R.id.settings_devices_sign_out_others
        removeOthers.icon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_fg_error))
        removeOthers.onClick {
            ConfirmDialog(activity, activity.getString(R.string.settings_devices_sign_out_others_title),
                activity.getString(R.string.settings_devices_sign_out_others_message),
                activity.getString(R.string.settings_devices_sign_out_others_confirm), destructive = true) {
                ctx.account.removeOtherSessions()
            }.show()
        }
        layout.section(othersSection)
        ctx.onRender(this, ::render)
        ctx.account.refreshSessions()
    }

    /** The list is followed while it is on screen; the core reads it again meanwhile (a Connector drops). */
    private var top = true
    private val following = activity.lifecycleScope.launch {
        activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (top) ctx.devices.show(true)
            try { awaitCancellation() } finally { ctx.devices.show(false) }
        }
    }

    override fun onTopChanged(top: Boolean) {
        this.top = top
        ctx.devices.show(top)
    }

    override fun onRemoved() {
        following.cancel()
        ctx.devices.show(false)
    }

    private fun renderHome() {
        val state = ctx.devices.state.value
        val devices = state.devices?.filterNot { it.id in state.removing }
        if (devices != shownHome || homeList.card.childCount == 0) {
            shownHome = devices
            homeList.card.removeAllViews()
            devices.orEmpty().forEach { device ->
                homeList.add(SettingsRow(activity, if (device.isCommaDevice) R.drawable.ic_settings_comma_device else R.drawable.ic_device_mac,
                    device.name).detail(activity.getString(if (device.online) R.string.devices_online else R.string.devices_offline))
                    .value(null, chevron = true).onClick { ctx.open(HomeDevicePage(ctx, device)) }.apply { tag = device.id })
            }
            homeList.add(addDevice)
        }
        homeStatus.isVisible = (state.loading && devices == null) || state.problem != null
        homeStatus.text = when {
            state.problem != null -> activity.getString(R.string.devices_failed)
            state.loading -> activity.getString(R.string.settings_devices_loading)
            else -> null
        }
        homeStatus.setOnClickListener(if (state.problem != null) View.OnClickListener { ctx.devices.refresh() } else null)
    }

    private fun render() {
        renderHome()
        val state = ctx.account.state.value
        val sessions = state.sessions
        if (sessions != shown) {
            shown = sessions
            list.card.removeAllViews()
            sessions.orEmpty().forEach { list.add(row(it)) }
        }
        list.card.isVisible = !sessions.isNullOrEmpty()
        status.isVisible = sessions == null || state.sessionsProblem != null
        status.text = when {
            state.sessionsLoading && sessions == null -> activity.getString(R.string.settings_devices_loading)
            state.sessionsProblem != null -> activity.getString(R.string.settings_devices_failed)
            else -> null
        }
        status.setOnClickListener(if (state.sessionsProblem != null) View.OnClickListener { ctx.account.refreshSessions() } else null)
        othersSection.isVisible = sessions.orEmpty().any { !it.current }
    }

    private fun row(session: DeviceSession): SettingsRow {
        val row = SettingsRow(activity, R.drawable.ic_settings_devices, deviceName(session))
        row.tag = session.id
        row.detail(if (session.current) activity.getString(R.string.settings_devices_this_device) else lastActive(session))
        if (!session.current) {
            row.trailing(activity.text(Level.SMALL, R.color.token_text_error_primary, DesignFonts.medium).apply {
                text = activity.getString(R.string.settings_devices_remove)
                gravity = Gravity.CENTER
                setPadding(activity.dp(12), activity.dp(8), activity.dp(4), activity.dp(8))
                contentDescription = activity.getString(R.string.settings_devices_remove_named, deviceName(session))
                setOnClickListener {
                    ConfirmDialog(activity, activity.getString(R.string.settings_devices_remove_title),
                        activity.getString(R.string.settings_devices_remove_message, deviceName(session)),
                        activity.getString(R.string.settings_devices_remove), destructive = true) {
                        ctx.account.removeSession(session.id)
                    }.show()
                }
            })
        }
        return row
    }

    private fun deviceName(session: DeviceSession): String =
        session.label?.takeIf { it.isNotBlank() } ?: activity.getString(R.string.settings_devices_unknown)

    private fun lastActive(session: DeviceSession): String? {
        val seconds = session.lastSeenAt ?: session.authenticatedAt ?: return null
        val relative = DateUtils.getRelativeTimeSpanString(seconds * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
        return activity.getString(R.string.settings_devices_last_active, relative)
    }

    companion object {
        const val KEY = "devices"
    }
}

/** The member's Workspaces. Choosing one switches to it and returns to Settings, like a navigation picker. */
internal class WorkspacePage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_workspace)) { ctx.back() }
    override val view: View = layout
    private val auth = surf.comma.android.auth.AuthGraph.get(activity)
    private val section = SettingsSection(activity, null)
    private var shown: List<surf.comma.android.auth.Workspace>? = null

    init {
        layout.section(section, top = 0)
        ctx.onRender(this, ::render)
    }

    private fun render() {
        val workspaces = ctx.workspaces
        val current = (ctx.auth as? AuthState.Connected)?.selection?.workspace?.id
        if (workspaces != shown) {
            shown = workspaces
            section.card.removeAllViews()
            workspaces.forEach { workspace ->
                section.add(SettingsRow(activity, null, workspace.name).trailing(checkmark()).onClick { choose(workspace) }
                    .apply { tag = workspace.id })
            }
        }
        for (index in 0 until section.card.childCount) {
            val row = section.card.getChildAt(index) as? SettingsRow ?: continue
            val chosen = row.tag == current
            row.isSelected = chosen
            (row.findViewWithTag<View>(CHECK))?.alpha = if (chosen) 1f else 0f
        }
    }

    private fun checkmark() = android.widget.ImageView(activity).apply {
        tag = CHECK
        setImageResource(R.drawable.ic_action_check)
        imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_bg_brand_solid))
        layoutParams = android.widget.FrameLayout.LayoutParams(activity.dp(24), activity.dp(24))
    }

    private fun choose(workspace: surf.comma.android.auth.Workspace) {
        val current = (ctx.auth as? AuthState.Connected)?.selection?.workspace?.id
        if (workspace.id != current) {
            val failed = activity.getString(R.string.settings_workspace_switch_failed)
            // The switch outlives the page, which closes now; only its failure comes back, on the main thread.
            surf.comma.android.auth.AuthGraph.scope.launch {
                if (!auth.switchWorkspace(workspace.id)) activity.runOnUiThread {
                    if (!activity.isDestroyed) ctx.toast(failed, true)
                }
            }
        }
        ctx.back()
    }

    companion object {
        const val KEY = "workspace"
        private const val CHECK = "check"
    }
}

/**
 * How Comma reaches the member outside the app: the message notifications switch for Comma's replies and Task
 * updates, and what the system does with them.
 */
internal class NotificationsPage(private val ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.settings_notifications)) { ctx.back() }
    override val view: View = layout
    private val switch = SettingsSwitch(activity)
    private val toggle = SettingsRow(activity, R.drawable.ic_settings_bell, activity.getString(R.string.settings_message_notifications))
        .trailing(switch)
    private val blocked = SettingsRow(activity, R.drawable.ic_settings_bell_off, activity.getString(R.string.settings_reply_notifications_blocked))
    private val section = SettingsSection(activity, null).add(toggle).add(blocked)
        .footer(activity.getString(R.string.settings_notifications_footer))

    init {
        toggle.id = R.id.settings_notifications_toggle
        toggle.onClick { ctx.replyNotifications.set(!switch.checked) }
        blocked.title.setTextColor(activity.color(R.color.token_text_tertiary))
        blocked.onClick { ctx.replyNotifications.set(true) }
        layout.section(section, top = 0)
        var first = true
        ctx.onRender(this) {
            val state = ctx.replyNotifications.state
            switch.set(state != ReplyNotificationState.OFF, animate = !first)
            first = false
            blocked.isVisible = state == ReplyNotificationState.BLOCKED
        }
    }

    companion object { const val KEY = "notifications" }
}
