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

    /** Opens a page from the Settings list; in columns it replaces the page shown beside the list. */
    fun openFromList(page: SettingsPage) = open(page)
    /** The key of the page shown beside the list, while Settings shows columns. */
    val shownBesideList: String? get() = null

    /** A new page's view of the signed-in account and Workspace; null while there is none. */
    fun workspaceScope(): surf.comma.android.settings.desktop.WorkspaceScope? = null
    /** The API's host, which names the environment to channel connections. */
    val apiHost: String get() = ""
    /** Opens a Task over the app, as a Task card does. */
    fun openTask(id: String) {}
    /** Shows the Router chat. */
    fun openRouter() {}
    /** Adds a file to the Router chat's draft; false when it took none. */
    suspend fun attachToRouter(name: String, bytes: ByteArray): Boolean = false
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
 * Workspace, then the desktop's groups (Comma, Preferences, Work, System, Archived, Shared, Advanced), other
 * accounts, sign-out and account deletion. The Android app adds its own appearance and text size, the open-source
 * licenses and, in debug builds, the developer settings.
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
    private val glass = SettingsRow(activity, R.drawable.ic_settings_sparkles, activity.getString(R.string.settings_glass))
    private var developer: (() -> Unit)? = null
    /** Rows that need a Workspace, hidden without one; a section left empty hides too. */
    private val workspaceRows = mutableListOf<SettingsRow>()
    private val commaSection = SettingsSection(activity, activity.getString(R.string.settings_section_comma))
    private val workSection = SettingsSection(activity, activity.getString(R.string.ds_group_work))
    private val archivedSection = SettingsSection(activity, activity.getString(R.string.ds_group_archived))
    private val sharedSection = SettingsSection(activity, activity.getString(R.string.ds_group_shared))

    /** Each row's page, which the row marks while that page is shown beside the list. */
    private val pageRows = mutableMapOf<String, View>()

    private fun link(icon: Int, title: Int, action: (SettingsRow) -> Unit) =
        SettingsRow(activity, icon, activity.getString(title)).value(null, chevron = true).onClick(action)

    private fun <T : View> T.opens(key: String): T = also { pageRows[key] = it }

    /** Marks the row of the page shown beside the list. */
    fun markShown() {
        val shown = ctx.shownBesideList
        pageRows.forEach { (key, row) ->
            val selected = key == shown
            row.isSelected = selected
            row.foreground = if (selected) android.graphics.drawable.ColorDrawable(activity.color(R.color.token_surface_ink)) else null
        }
    }
    /** The other accounts signed in on this device (switch to one, or sign it out), and adding another. */
    private val accounts = SettingsSection(activity, activity.getString(R.string.settings_section_accounts))
    private var shownAccounts: List<surf.comma.android.auth.Account>? = null

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
            setOnClickListener { ctx.openFromList(ProfilePage(ctx)) }
            opens(ProfilePage.KEY)
        }
        layout.section(SettingsSection(activity, null).add(account), top = 0)

        workspace.id = R.id.settings_workspace
        workspace.opens(WorkspacePage.KEY)
        layout.section(workspaceSection)

        // The desktop's groups. Comma holds Drive and Plugins, which are primary navigation entries on the desktop.
        val open = { page: () -> SettingsPage -> { _: SettingsRow -> ctx.openFromList(page()) } }
        val drive = link(R.drawable.ic_settings_file, R.string.ds_drive_and_files, open { surf.comma.android.settings.desktop.DrivePage(ctx) }).opens(surf.comma.android.settings.desktop.DrivePage.KEY)
        val plugins = link(R.drawable.ic_routine_puzzle, R.string.ds_plugins, open { surf.comma.android.settings.desktop.PluginsPage(ctx) }).opens(surf.comma.android.settings.desktop.PluginsPage.KEY)
        workspaceRows += listOf(drive, plugins)
        layout.section(commaSection.add(drive).add(plugins))

        val router = link(R.drawable.ic_settings_sparkles, R.string.ds_router_settings, open { surf.comma.android.settings.desktop.RouterSettingsPage(ctx) }).opens(surf.comma.android.settings.desktop.RouterSettingsPage.KEY)
        notifications.id = R.id.settings_reply_notifications
        notifications.value(null, chevron = true).onClick { ctx.openFromList(NotificationsPage(ctx)) }
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
        glass.id = R.id.settings_glass
        glass.onClick { row ->
            val options = listOf(true, false)
            ChoiceMenu.show(row, options.map(::glassLabel), options.indexOf(ctx.local.state.value.glass)) {
                ctx.local.setGlass(options[it])
            }
        }
        val usage = link(R.drawable.ic_settings_info, R.string.ds_usage, open { surf.comma.android.settings.desktop.UsagePage(ctx) }).opens(surf.comma.android.settings.desktop.UsagePage.KEY)
        workspaceRows += listOf(router, usage)
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_group_preferences))
            .add(router).add(notifications).add(language).add(theme).add(textSize).add(glass).add(usage))

        val routines = link(R.drawable.ic_settings_sparkles, R.string.ds_routines, open { surf.comma.android.settings.desktop.RoutinesSettingsPage(ctx) }).opens(surf.comma.android.settings.desktop.RoutinesSettingsPage.KEY)
        val channels = link(R.drawable.ic_settings_link, R.string.ds_channels, open { surf.comma.android.settings.desktop.ChannelsPage(ctx) }).opens(surf.comma.android.settings.desktop.ChannelsPage.KEY)
        labels.opens(surf.comma.android.labels.TaskLabelsPage.KEY)
        notifications.opens(NotificationsPage.KEY)
        labels.id = R.id.settings_label_changes
        labels.value(null, chevron = true).onClick { ctx.openFromList(surf.comma.android.labels.TaskLabelsPage(ctx)) }
        val models = link(R.drawable.ic_history_thinking, R.string.ds_models, open { surf.comma.android.settings.desktop.ModelsPage(ctx) }).opens(surf.comma.android.settings.desktop.ModelsPage.KEY)
        workspaceRows += listOf(routines, channels, labels, models)
        workSection.add(routines).add(channels).add(labels).add(models)
        layout.section(workSection)

        val voice = link(R.drawable.ic_settings_info, R.string.ds_voice, open { surf.comma.android.settings.desktop.VoiceSettingsPage(ctx) }).opens(surf.comma.android.settings.desktop.VoiceSettingsPage.KEY)
        workspaceRows += voice
        val version = SettingsRow(activity, R.drawable.ic_settings_info, activity.getString(R.string.settings_version))
            .value(activity.getString(R.string.settings_version_value, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        version.id = R.id.settings_version
        val licenses = SettingsRow(activity, R.drawable.ic_settings_licenses, activity.getString(R.string.settings_licenses))
            .value(null, chevron = true).onClick { ctx.openFromList(LicensesPage(ctx)) }
        licenses.id = R.id.settings_licenses
        licenses.opens(LicensesPage.KEY)
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_group_system)).add(voice).add(version).add(licenses))

        val archived = SettingsRow(activity, R.drawable.ic_list_archive, activity.getString(R.string.ds_archived_tasks)).value(null, chevron = true)
            .onClick {
                val store = surf.comma.android.workspace.WorkspaceGraph.get(activity)
                surf.comma.android.tasks.list.ArchivedTasksSheet(activity, store, surf.comma.android.tasks.list.TaskActions(activity, store)).show()
            }
        workspaceRows += archived
        archivedSection.add(archived)
        layout.section(archivedSection)

        val shares = link(R.drawable.ic_settings_link, R.string.ds_shared_tasks, open { surf.comma.android.settings.desktop.SharedTasksPage(ctx) }).opens(surf.comma.android.settings.desktop.SharedTasksPage.KEY)
        val requests = link(R.drawable.ic_share_os, R.string.ds_requests, open { surf.comma.android.settings.desktop.TaskRequestsPage(ctx) }).opens(surf.comma.android.settings.desktop.TaskRequestsPage.KEY)
        workspaceRows += listOf(shares, requests)
        sharedSection.add(shares).add(requests)
        layout.section(sharedSection)

        val routerKeys = link(R.drawable.ic_settings_info, R.string.ds_router_keys, open { surf.comma.android.settings.desktop.RouterKeysPage(ctx) }).opens(surf.comma.android.settings.desktop.RouterKeysPage.KEY)
        workspaceRows += routerKeys
        val devices = SettingsRow(activity, R.drawable.ic_settings_signed_in, activity.getString(R.string.settings_devices))
            .value(null, chevron = true).onClick { ctx.openFromList(DevicesPage(ctx)) }
        devices.id = R.id.settings_devices
        devices.opens(DevicesPage.KEY)
        val compute = link(R.drawable.ic_settings_devices, R.string.ds_compute, open { surf.comma.android.settings.desktop.ComputePage(ctx) })
            .opens(surf.comma.android.settings.desktop.ComputePage.KEY)
        workspaceRows += compute
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_group_advanced)).add(routerKeys).add(devices).add(compute))

        developer = DeveloperSettings.section(ctx)?.also { layout.section(it.first) }?.second

        layout.section(accounts)

        val signOut = SettingsRow(activity, R.drawable.ic_settings_arrow_box_left, activity.getString(R.string.settings_sign_out),
            tint = R.color.token_text_error_primary).onClick { confirmSignOut() }
        signOut.id = R.id.settings_sign_out
        signOut.icon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_error_primary))
        val deleteAccount = SettingsRow(activity, R.drawable.ic_settings_trash, activity.getString(R.string.settings_delete_account),
            tint = R.color.token_text_error_primary).onClick { confirmDeleteAccount() }
        deleteAccount.id = R.id.settings_delete_account
        deleteAccount.icon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_error_primary))
        layout.section(SettingsSection(activity, null).add(signOut))
        // Kept apart, last: what cannot be undone.
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_danger_zone)).add(deleteAccount))

        ctx.onRender(this, ::render)
        if (ctx.account.state.value.profile == null) ctx.account.refreshProfile()
    }

    private fun confirmSignOut() {
        ConfirmDialog(activity, activity.getString(R.string.settings_sign_out_confirm), activity.getString(R.string.settings_sign_out_message),
            activity.getString(R.string.settings_sign_out), destructive = true) { ctx.signOut() }.show()
    }

    /** One row per other account signed in here (a tap offers switching to it or signing it out), then "add account". */
    private fun renderAccounts(connected: AuthState.Connected?) {
        accounts.isVisible = connected != null
        val others = connected?.otherAccounts ?: return
        if (others == shownAccounts) return
        shownAccounts = others
        accounts.card.removeAllViews()
        for (other in others) {
            val row = SettingsRow(activity, null, other.email).value(activity.getString(R.string.settings_switch_account), chevron = true)
            row.onClick { anchor ->
                ChoiceMenu.show(anchor, listOf(activity.getString(R.string.settings_switch_account),
                    activity.getString(R.string.settings_sign_out_account)), -1) { choice ->
                    surf.comma.android.auth.AuthGraph.scope.launch {
                        val done = if (choice == 0) auth.switchAccount(other.id) else auth.signOutAccount(other.id)
                        if (!done) activity.runOnUiThread {
                            ctx.toast(activity.getString(if (choice == 0) R.string.settings_switch_account_failed
                                else R.string.settings_sign_out_account_failed), failure = true)
                        }
                    }
                }
            }
            accounts.add(row)
        }
        val add = SettingsRow(activity, R.drawable.ic_plus_small, activity.getString(R.string.settings_add_account))
            .onClick {
                surf.comma.android.auth.AuthGraph.scope.launch {
                    if (!auth.addAccount()) activity.runOnUiThread {
                        ctx.toast(activity.getString(R.string.settings_add_account_failed), failure = true)
                    }
                }
            }
        add.id = R.id.settings_add_account
        accounts.add(add)
    }

    /** Explains what deletion takes away, then mails the code that confirms it. */
    private fun confirmDeleteAccount() {
        ConfirmDialog(activity, activity.getString(R.string.settings_delete_account),
            activity.getString(R.string.settings_delete_account_message, ctx.email()),
            activity.getString(R.string.settings_delete_account_continue), destructive = true) {
            askDeletionEmail()
        }.show()
    }

    /** The account email, typed to confirm, before the code is mailed. */
    private fun askDeletionEmail() {
        val email = ctx.email()
        FieldDialog(
            activity,
            title = activity.getString(R.string.settings_delete_account),
            hint = activity.getString(R.string.settings_delete_account_type_email),
            current = "",
            saveLabel = activity.getString(R.string.settings_delete_account_send_code),
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            maxLength = 320,
            onSave = { activity.lifecycleScope.launch { deletionStep(ctx.account.requestAccountDeletion()) } },
            description = activity.getString(R.string.settings_delete_account_type_email_message, email),
            inputId = R.id.settings_delete_account_email_input,
            keyboard = true,
            refused = { !it.trim().equals(email, ignoreCase = true) },
            destructive = true,
        ).show()
    }

    private fun askDeletionCode(challengeId: String) {
        FieldDialog(
            activity,
            title = activity.getString(R.string.settings_delete_account),
            hint = activity.getString(R.string.settings_delete_account_code),
            current = "",
            saveLabel = activity.getString(R.string.settings_delete_account_confirm),
            inputType = android.text.InputType.TYPE_CLASS_NUMBER,
            maxLength = 6,
            onSave = { code -> activity.lifecycleScope.launch { deletionStep(ctx.account.deleteAccount(challengeId, code), challengeId) } },
            description = activity.getString(R.string.settings_delete_account_code_message, ctx.email()),
            inputId = R.id.settings_delete_account_code_input,
            keyboard = true,
            refused = { !it.matches(Regex("\\d{6}")) },
            destructive = true,
        ).show()
    }

    private fun deletionStep(outcome: AccountDeletion, challengeId: String? = null) {
        when (outcome) {
            is AccountDeletion.CodeSent -> askDeletionCode(outcome.challengeId)
            AccountDeletion.Deleted -> Unit
            AccountDeletion.SubscriptionActive -> ConfirmDialog(activity,
                activity.getString(R.string.settings_delete_account_subscription_title),
                activity.getString(R.string.settings_delete_account_subscription_message),
                activity.getString(R.string.settings_ok), destructive = false) {}.show()
            AccountDeletion.InvalidCode -> {
                ctx.toast(activity.getString(R.string.settings_delete_account_invalid_code), failure = true)
                challengeId?.let(::askDeletionCode)
            }
            AccountDeletion.RateLimited ->
                ctx.toast(activity.getString(R.string.settings_delete_account_rate_limited), failure = true)
            AccountDeletion.Failed -> ctx.toast(activity.getString(R.string.settings_delete_account_failed), failure = true)
        }
    }

    private fun render() {
        val state = ctx.account.state.value
        val shownName = ctx.displayName()
        name.text = shownName
        email.text = ctx.email()
        email.isVisible = email.text.isNotEmpty() && email.text != shownName
        avatar.show(state.avatar, shownName, state.generation)
        val connected = ctx.auth as? AuthState.Connected
        renderAccounts(connected)
        val workspaces = ctx.workspaces
        workspace.value(connected?.selection?.workspace?.name ?: activity.getString(R.string.settings_choose_workspace),
            chevron = workspaces.size > 1)
        workspace.onClick(if (workspaces.size > 1) { _ -> ctx.openFromList(WorkspacePage(ctx)) } else null)
        workspaceSection.isVisible = connected != null
        notifications.value(activity.getString(when (ctx.replyNotifications.state) {
            ReplyNotificationState.ON -> R.string.settings_reply_notifications_on
            ReplyNotificationState.OFF -> R.string.settings_reply_notifications_off
            ReplyNotificationState.BLOCKED -> R.string.settings_reply_notifications_blocked
        }), chevron = true)
        val hasWorkspace = connected?.selection != null
        workspaceRows.forEach { it.isVisible = hasWorkspace }
        listOf(commaSection, workSection, archivedSection, sharedSection).forEach { it.isVisible = hasWorkspace }
        val local = ctx.local.state.value
        language.value(languageLabel(local.language))
        theme.value(themeLabel(local.theme))
        textSize.value(textSizeLabel(local.textSize))
        glass.value(glassLabel(local.glass))
        developer?.invoke()
        markShown()
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

    private fun glassLabel(on: Boolean) = activity.getString(if (on) R.string.settings_glass_on else R.string.settings_glass_off)

    private fun textSizeLabel(value: TextSize) = activity.getString(when (value) {
        TextSize.DEFAULT -> R.string.settings_font_size_default
        TextSize.LARGE -> R.string.settings_font_size_large
    })

    companion object { const val KEY = "root" }
}

/** Picture, name and email; the email row starts changing it, with a code from each mailbox. */
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
        email.id = R.id.settings_email
        email.onClick { confirmEmailChange() }
        layout.section(SettingsSection(activity, activity.getString(R.string.settings_account)).add(name).add(email))
        ctx.onRender(this, ::render)
    }

    /** Says what changes and what stays, then mails a code to the current email. */
    private fun confirmEmailChange() {
        ConfirmDialog(activity, activity.getString(R.string.settings_change_email),
            activity.getString(R.string.settings_change_email_message, ctx.email()),
            activity.getString(R.string.settings_change_email_send_code), destructive = false) {
            activity.lifecycleScope.launch { emailChangeStep(ctx.account.requestEmailChange()) }
        }.show()
    }

    private fun askCurrentCode(challengeId: String) {
        codeDialog(activity.getString(R.string.settings_change_email_current_code_message, ctx.email()),
            activity.getString(R.string.settings_change_email_continue)) { code -> askNewEmail(challengeId, code) }
    }

    private fun askNewEmail(challengeId: String, code: String) {
        FieldDialog(
            activity,
            title = activity.getString(R.string.settings_change_email),
            hint = activity.getString(R.string.settings_change_email_new_email),
            current = "",
            saveLabel = activity.getString(R.string.settings_change_email_send_code),
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
            maxLength = 320,
            onSave = { email ->
                activity.lifecycleScope.launch {
                    emailChangeStep(ctx.account.requestNewEmailCode(challengeId, code, email.trim()), challengeId)
                }
            },
            description = activity.getString(R.string.settings_change_email_new_email_message),
            inputId = R.id.settings_change_email_input,
            keyboard = true,
        ).show()
    }

    private fun askNewCode(challengeId: String, email: String) {
        codeDialog(activity.getString(R.string.settings_change_email_new_code_message, email),
            activity.getString(R.string.settings_change_email)) { code ->
            activity.lifecycleScope.launch {
                emailChangeStep(ctx.account.confirmEmailChange(challengeId, code), challengeId, email)
            }
        }
    }

    private fun codeDialog(description: String, saveLabel: String, onSave: (String) -> Unit) {
        FieldDialog(
            activity,
            title = activity.getString(R.string.settings_change_email),
            hint = activity.getString(R.string.settings_change_email_code),
            current = "",
            saveLabel = saveLabel,
            inputType = android.text.InputType.TYPE_CLASS_NUMBER,
            maxLength = 6,
            onSave = onSave,
            description = description,
            inputId = R.id.settings_change_email_code_input,
            keyboard = true,
            refused = { !it.matches(Regex("\\d{6}")) },
        ).show()
    }

    /**
     * Goes on from what a step came to. [challengeId] is the step's own challenge; [email] is set while the new
     * email's code is asked for.
     */
    private fun emailChangeStep(outcome: EmailChange, challengeId: String? = null, email: String? = null) {
        if (outcome is EmailChange.PendingDeletion) {
            val date = DateUtils.formatDateTime(activity, outcome.until,
                DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_YEAR)
            ctx.toast(activity.getString(R.string.settings_change_email_pending_deletion, date), failure = true)
            return
        }
        val failure = when (outcome) {
            is EmailChange.PendingDeletion -> return
            is EmailChange.CodeSent -> {
                if (outcome.email == null) askCurrentCode(outcome.challengeId)
                else askNewCode(outcome.challengeId, outcome.email)
                return
            }
            EmailChange.Changed -> return
            EmailChange.InvalidCode -> R.string.settings_change_email_invalid_code
            EmailChange.InvalidEmail -> R.string.settings_change_email_invalid_email
            EmailChange.SameEmail -> R.string.settings_change_email_same_email
            EmailChange.Taken -> R.string.settings_change_email_taken
            EmailChange.Stale -> R.string.settings_change_email_changed
            EmailChange.RateLimited -> R.string.settings_change_email_rate_limited
            EmailChange.Failed -> R.string.settings_change_email_failed
        }
        ctx.toast(activity.getString(failure), failure = true)
        // A wrong code is typed again where it was asked for.
        if (outcome == EmailChange.InvalidCode && challengeId != null) {
            if (email != null) askNewCode(challengeId, email) else askCurrentCode(challengeId)
        }
    }

    private fun render() {
        val state = ctx.account.state.value
        val shown = ctx.displayName()
        avatar.show(state.avatar, shown, state.generation)
        name.value(shown, chevron = true)
        name.isEnabled = state.profile != null
        email.value(ctx.email(), chevron = true)
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
