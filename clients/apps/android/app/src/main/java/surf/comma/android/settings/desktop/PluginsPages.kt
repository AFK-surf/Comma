package surf.comma.android.settings.desktop

import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.Job
import surf.comma.android.R
import surf.comma.android.routines.ProviderMarks
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

private const val LEVEL_CHECK = "level_check"

/** A plugin's mark on a rounded tile: its provider artwork, or the puzzle piece. */
private fun SettingsContext.pluginMark(brand: String): ImageView = ImageView(activity).apply {
    setImageDrawable(ProviderMarks.drawable(activity, brand))
    scaleType = ImageView.ScaleType.FIT_CENTER
    val inset = activity.dp(8)
    setPadding(inset, inset, inset, inset)
    background = roundRect(activity.color(R.color.token_bg_primary), activity.dp(8).toFloat())
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    layoutParams = LinearLayout.LayoutParams(activity.dp(44), activity.dp(44))
}

/**
 * Settings > Plugins: connected and available plugins with search. The list follows one catalog topic and the
 * notices the core lets this client claim; returning to the app checks a pending browser authorization.
 */
internal class PluginsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_plugins, KEY) {
    private val model = scope?.let(::PluginsModel)
    private var query = ""
    private val search = activity.fieldRow(activity.getString(R.string.ds_plugins_search)) { query = it.trim(); render() }
    private val connected = SettingsSection(activity, activity.getString(R.string.ds_plugins_connected))
    private val available = SettingsSection(activity, activity.getString(R.string.ds_plugins_available))
    private val empty = SettingsSection(activity, null).add(activity.infoRow(activity.getString(R.string.ds_plugins_none)))
    private val resume = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) { launch { model?.checkAuthorization() } }
    }

    init {
        layout.section(SettingsSection(activity, null).add(search), top = 0)
        layout.section(connected)
        layout.section(available)
        layout.section(empty)
        model?.follow()
        model?.followNotices()
        activity.lifecycle.addObserver(resume)
        start { model?.refresh() }
    }

    override fun onClose() = activity.lifecycle.removeObserver(resume)

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.loaded
        val filtered = model.plugins.filter { query.isEmpty() || "${it.name} ${it.summary}".contains(query, ignoreCase = true) }
        connected.fill(filtered.filter { it.installed }.map(::row))
        available.fill(filtered.filter { !it.installed }.map(::row))
        empty.isVisible = model.loaded && filtered.isEmpty()
    }

    private fun row(plugin: Plugin): View = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = activity.dp(64)
        setPadding(activity.dp(14), activity.dp(10), activity.dp(10), activity.dp(10))
        tag = plugin.id
        addView(ctx.pluginMark(plugin.brand))
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(activity.text(Level.REGULAR, R.color.token_text_primary).apply { text = plugin.name })
            addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply { text = plugin.summary; maxLines = 2 })
        }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(8) })
        addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_fg_quaternary))
        }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
        PressFeedback(this, R.color.token_surface_ink, scale = false)
        setOnClickListener { model?.let { ctx.open(PluginDetailPage(ctx, it, plugin.id)) } }
    }

    companion object { const val KEY = "plugins" }
}

/** One plugin: its description, connection, Monoid workspaces/notifications, connected accounts, tool groups and skills. */
internal class PluginDetailPage(ctx: SettingsContext, private val model: PluginsModel, private val pluginId: String) :
    WorkspacePage(ctx, R.string.ds_plugin, "plugins.detail", model.scope,
        titleText = model.plugins.firstOrNull { it.id == pluginId }?.name) {
    private val sources = PluginSourcesModel(model.scope, pluginId)
    private val stations = PluginStationsModel(model.scope, pluginId)
    private val plugin get() = model.plugins.firstOrNull { it.id == pluginId }
    private val header = SettingsSection(activity, null)
    private val connection = SettingsSection(activity, activity.getString(R.string.ds_plugins_connection))
    private val workspacesSection = SettingsSection(activity, activity.getString(R.string.ds_plugins_stations))
    private val notificationsSection = SettingsSection(activity, activity.getString(R.string.ds_plugins_stillfail_notifications))
    /** One checkmark row per level, each with what it means, as the iOS page. */
    private val levelRows = StillfailNotificationLevel.entries.associateWith { level ->
        SettingsRow(activity, null, notificationTitle(level)).detail(notificationDescription(level))
            .trailing(ImageView(activity).apply {
                setImageResource(R.drawable.ic_action_check)
                imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_bg_brand_solid))
                layoutParams = android.widget.FrameLayout.LayoutParams(activity.dp(24), activity.dp(24))
                tag = LEVEL_CHECK
            })
            // The model shows the pick at once, ignores one while a save is on its way, and puts it back if that fails.
            .onClick { launch { stations.setNotificationLevel(level) } }
            .apply { tag = "stillfail_notifications:${level.wire}" }
    }
    /** Removing is the page's last, destructive step, in its own group at the bottom. */
    private val removal = SettingsSection(activity, null)
    private val accounts = SettingsSection(activity, activity.getString(R.string.ds_plugins_accounts))
        .footer(activity.getString(R.string.ds_plugins_accounts_footer))
    private val tools = SettingsSection(activity, activity.getString(R.string.ds_plugins_tools))
    private val skills = SettingsSection(activity, activity.getString(R.string.ds_plugins_skills))
    private val removeRow = activity.actionRow(activity.getString(R.string.ds_plugins_remove), destructive = true) {
        val plugin = plugin ?: return@actionRow
        ConfirmDialog(activity, activity.getString(R.string.ds_plugins_remove_title), activity.getString(
            if (plugin.id == Plugin.COLAB) R.string.ds_plugins_remove_message_colab else R.string.ds_plugins_remove_message),
            activity.getString(R.string.ds_plugins_remove), destructive = true) { launch { model.remove(plugin) } }.show()
    }
    private var credential = ""
    private val credentialField = activity.fieldRow(activity.getString(R.string.ds_api_key),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD) { credential = it; render() }
    /** A Google sign-in's code (or the whole address the page went to), pasted back. */
    private var code = ""
    private val codeField = activity.fieldRow(activity.getString(R.string.ds_plugins_authorization_code),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS) { code = it.trim(); render() }
    /** The last connect line copied, so the Copy button shows "Copied" until a new line arrives. */
    private var copiedConnectLine: String? = null
    private var sourcesJob: Job? = null
    private var groupsJob: Job? = null
    private var stationsJob: Job? = null
    private var confirming: String? = null

    init {
        layout.section(header, top = 0)
        layout.section(connection)
        layout.section(workspacesSection)
        layout.section(notificationsSection)
        layout.section(accounts)
        layout.section(tools)
        layout.section(skills)
        layout.section(removal)
        loading.isVisible = false
        start()
    }

    override fun onClose() {
        credentialField.setText("")
        codeField.setText("")
        sourcesJob?.cancel()
        groupsJob?.cancel()
        stationsJob?.cancel()
    }

    /** Only the open detail follows its accounts, tools and stations, and only while the plugin is connected. */
    private fun follow(plugin: Plugin) {
        if (plugin.installed && sourcesJob == null) sourcesJob = sources.followSources()
        if (!plugin.installed) { sourcesJob?.cancel(); sourcesJob = null }
        val groups = plugin.installed && plugin.toolGroups
        if (groups && groupsJob == null) groupsJob = sources.followGroups()
        if (!groups) { groupsJob?.cancel(); groupsJob = null }
        val watchStations = plugin.installed && plugin.isStillfail
        if (watchStations && stationsJob == null) stationsJob = stations.follow()
        if (!watchStations) { stationsJob?.cancel(); stationsJob = null }
    }

    override fun render() {
        super.render()
        val plugin = plugin
        listOf(header, connection, workspacesSection, notificationsSection, accounts, tools, skills, removal)
            .forEach { it.isVisible = plugin != null }
        if (plugin == null) return
        follow(plugin)
        header.fill(listOf(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
            addView(ctx.pluginMark(plugin.brand))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                addView(activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply { text = plugin.name })
                addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply {
                    text = activity.getString(if (plugin.installed) R.string.ds_connected else R.string.ds_not_connected)
                })
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(8) })
        }, activity.textBlock(plugin.description, colorRes = R.color.token_text_secondary)))
        connection.fill(connectionRows(plugin))
        val showStations = plugin.installed && plugin.isStillfail
        connection.footer(if (!showStations && model.configuration(plugin)?.showValue == true) activity.getString(R.string.ds_plugins_show_once) else null)
        // A connected Monoid's connect line shows where another workspace is asked for: under its workspaces.
        val line = model.configuration(plugin)?.takeIf { showStations && it.showValue }
        workspacesSection.fill(when {
            line != null -> connectLineRows(line)
            showStations -> stationRows(plugin)
            else -> emptyList()
        })
        workspacesSection.footer(when {
            line != null -> activity.getString(R.string.ds_plugins_show_once)
            showStations && stations.hasOfflineStation -> activity.getString(R.string.ds_plugins_station_offline_notice)
            else -> null
        })
        notificationsSection.fill(if (showStations) bindNotificationRows() else emptyList())
        notificationsSection.footer(if (showStations && stations.error == "notification_save_failed") {
            activity.getString(R.string.ds_plugins_stillfail_notifications_save_failed)
        } else null)
        val sourceRows = sources.sources.flatMap { sourceRows(plugin, it) }
        accounts.fill(if (sourceRows.isEmpty()) emptyList() else sourceRows +
            activity.actionRow(activity.getString(R.string.ds_plugins_refresh_accounts)) { launch { sources.run("plugin.sources.refresh") } })
        tools.fill(when {
            sources.groups.isNotEmpty() -> sources.groups.mapNotNull { group ->
                val id = group.string("id") ?: return@mapNotNull null
                SwitchRow(activity, group.string("name") ?: id) { on -> launch { sources.run("plugin.toolGroup.set", json("group" to id, "enabled" to on)) } }
                    .apply { set(group.optBoolean("enabled")) }.row
            }
            plugin.installed -> plugin.tools.map { activity.infoRow(it) }
            else -> emptyList()
        })
        skills.fill(plugin.skills.map { activity.infoRow(it, icon = R.drawable.ic_routine_puzzle) })
        removal.fill(if (plugin.installed && !plugin.locked) listOf(removeRow.apply {
            isEnabled = !plugin.working && !plugin.authorizing
        }) else emptyList())
        confirmAccount()
    }

    private fun connectionRows(plugin: Plugin): List<View> {
        val rows = mutableListOf<View>()
        val config = model.configuration(plugin)
        when {
            plugin.authorizing || (model.authorizationPlugin == plugin.id && model.authorizationUrl != null) -> {
                rows += activity.noteRow(activity.getString(R.string.ds_plugins_authorizing))
                model.authorizationUrl?.takeIf { model.authorizationPlugin == plugin.id }?.let { url ->
                    rows += activity.actionRow(activity.getString(R.string.ds_continue_in_browser)) { activity.openLink(url) }
                }
                rows += activity.infoRow(activity.getString(R.string.ds_cancel_connection)).onClick { launch { sources.run("plugin.cancel") } }
            }
            // A connected Monoid's line and progress show under its workspaces.
            plugin.installed && plugin.isStillfail -> Unit
            plugin.working -> rows += activity.noteRow(activity.getString(R.string.ds_plugins_updating))
            config?.oauthCode == true -> rows += codeRows(plugin, config)
            config?.showValue == true -> rows += connectLineRows(config)
            !plugin.installed || model.configurationPlugin == plugin.id -> {
                // A form that only shows a value (`show`) never asks for a secret input.
                val form = config?.takeIf { !it.showValue }
                val asks = form != null || plugin.asksCredential
                if (asks) {
                    credentialField.hint = form?.label ?: plugin.credentialLabel ?: activity.getString(R.string.ds_api_key)
                    rows += credentialField
                    (form?.helpUrl ?: plugin.helpUrl)?.let { url ->
                        rows += activity.actionRow(activity.getString(R.string.ds_plugins_setup_help)) { activity.openLink(url) }
                    }
                }
                model.formError?.let { rows += activity.noteRow(activity.describe(it), R.color.token_text_error_primary) }
                rows += activity.actionRow(activity.getString(R.string.ds_plugins_connect)) {
                    launch {
                        val url = model.install(plugin, credential.ifEmpty { null })
                        credentialField.setText("")
                        url?.let(activity::openLink)
                    }
                }.apply { isEnabled = !plugin.locked && !(asks && credential.isEmpty()) }
            }
            // Connected and idle, the header already says so: the group leaves nothing behind.
            else -> Unit
        }
        return rows
    }

    /**
     * A one-time connect line (`format == "show"`): what to do with it, the line, Copy and Send. Done before any copy
     * asks first, since the line is not shown again.
     */
    private fun connectLineRows(config: PluginConfiguration): List<View> {
        val line = config.value.orEmpty()
        val rows = mutableListOf<View>()
        rows += activity.noteRow(activity.getString(R.string.ds_plugins_show_description))
        if (line.isNotEmpty()) {
            rows += activity.textBlock(line, level = Level.SMALL, mono = true, colorRes = R.color.token_text_secondary)
            val copied = copiedConnectLine == line
            rows += activity.actionRow(activity.getString(if (copied) R.string.ds_plugins_show_copied else R.string.ds_plugins_show_copy)) {
                // The system confirms a copy itself (Android 13 and later); it is marked sensitive so its preview hides it.
                activity.copySensitive(line)
                copiedConnectLine = line
                render()
            }.apply { tag = "connect_line_copy" }
            rows += SettingsRow(activity, R.drawable.ic_share_os, activity.getString(R.string.ds_plugins_show_send), tint = R.color.token_bg_brand_solid)
                .onClick { activity.shareText(line) }
        }
        rows += activity.infoRow(activity.getString(R.string.ds_done)).onClick {
            if (copiedConnectLine == line || line.isEmpty()) closeConnectLine()
            else ConfirmDialog(activity, activity.getString(R.string.ds_plugins_show_discard_title),
                activity.getString(R.string.ds_plugins_show_discard_message),
                activity.getString(R.string.ds_plugins_show_discard_close), destructive = true) { closeConnectLine() }.show()
        }.apply { tag = "connect_line_done" }
        return rows
    }

    private fun closeConnectLine() {
        copiedConnectLine = null
        model.dismissConfiguration()
    }

    /** Connected Monoid workspaces, single-station disconnect menu, and connect another workspace. */
    private fun stationRows(plugin: Plugin): List<View> {
        val rows = mutableListOf<View>()
        val list = stations.stations
        when {
            stations.error == "load_failed" && list == null -> {
                rows += activity.noteRow(activity.getString(R.string.ds_plugins_stations_load_failed), R.color.token_text_error_primary)
                rows += activity.actionRow(activity.getString(R.string.ds_plugins_stations_retry)) {
                    stationsJob?.cancel()
                    stationsJob = stations.follow()
                }
            }
            list == null -> {
                rows += activity.noteRow(activity.getString(R.string.ds_loading))
            }
            list.isEmpty() -> {
                rows += activity.noteRow(activity.getString(R.string.ds_plugins_stations_none))
            }
            else -> {
                list.forEach { station -> rows += stationRow(station) }
            }
        }
        if (stations.error == "disconnect_failed") {
            rows += activity.noteRow(activity.getString(R.string.ds_plugins_station_disconnect_failed_generic), R.color.token_text_error_primary)
        }
        val another = !list.isNullOrEmpty()
        rows += SettingsRow(activity, R.drawable.ic_plus_small, activity.getString(
            if (another) R.string.ds_plugins_station_connect_another else R.string.ds_plugins_station_connect_first),
            tint = R.color.token_bg_brand_solid).onClick { launch { model.install(plugin) } }.apply {
            isEnabled = !plugin.working && !plugin.locked
            // While the line is being made, the row says so where the member tapped.
            value(if (plugin.working) activity.getString(R.string.ds_loading) else null)
        }
        return rows
    }

    /** A workspace: its emoji or initial, its name, where Comma reaches it and whether that is online. */
    private fun stationRow(station: PluginStation): View {
        val name = station.workspace ?: activity.getString(R.string.ds_plugins_station_unnamed)
        val detail = SpannableStringBuilder()
        if (station.waiting) {
            detail.append(activity.getString(R.string.ds_plugins_station_waiting))
        } else {
            // The dot repeats the status word in colour; the word alone carries it for TalkBack.
            detail.append("\u25CF ", ForegroundColorSpan(activity.color(
                if (station.connected) R.color.token_fg_success else R.color.token_fg_quaternary)), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val status = when {
                !station.connected -> activity.getString(R.string.ds_plugins_station_offline)
                station.stationCount != null && station.stationCount > 1 -> activity.getString(R.string.ds_plugins_station_count, station.stationCount)
                else -> activity.getString(R.string.ds_plugins_station_online)
            }
            detail.append(listOfNotNull(station.station?.let { activity.getString(R.string.ds_plugins_station_via, it) }, status).joinToString(" · "))
        }
        val menu = { anchor: View ->
            ActionMenu(activity)
                .item(activity.getString(R.string.ds_plugins_station_disconnect), destructive = true) {
                    ConfirmDialog(
                        activity,
                        station.workspace?.let { activity.getString(R.string.ds_plugins_station_disconnect_title, it) }
                            ?: activity.getString(R.string.ds_plugins_station_disconnect_title_generic),
                        activity.getString(R.string.ds_plugins_station_disconnect_description),
                        activity.getString(R.string.ds_plugins_station_disconnect),
                        destructive = true,
                    ) { launch { stations.disconnect(station.id) } }.show()
                }
                .show(anchor)
        }
        val more = activity.moreButton(activity.getString(R.string.ds_plugins_station_more, name)) { menu(it) }.apply {
            tag = "station_more:${station.id}"
            isEnabled = stations.pending == null
            alpha = if (isEnabled) 1f else 0.4f
        }
        return SettingsRow(activity, null, name).detail(detail).trailing(more).apply {
            tag = "station:${station.id}"
            title.maxLines = 1
            addView(stationBadge(station), 0, LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)).apply {
                marginEnd = activity.dp(10)
            })
            // A long press opens the same menu, as a list item's does.
            setOnLongClickListener { if (stations.pending == null) menu(more); true }
        }
    }

    /** The workspace's emoji or initial on a quiet tile; one not connected yet shows a link. */
    private fun stationBadge(station: PluginStation): View {
        val initial = station.workspace?.trim()?.firstOrNull()?.uppercase()
        val tile = roundRect(activity.color(R.color.token_surface_ink), activity.dp(8).toFloat())
        return if (station.emoji.isNullOrBlank() && initial == null) ImageView(activity).apply {
            setImageResource(R.drawable.ic_settings_link)
            imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_tertiary))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(activity.dp(8), activity.dp(8), activity.dp(8), activity.dp(8))
            background = tile
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        } else activity.text(Level.REGULAR, R.color.token_text_secondary, DesignFonts.semibold).apply {
            text = station.emoji?.takeIf { it.isNotBlank() } ?: initial
            gravity = Gravity.CENTER
            background = tile
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
    }

    /** The four levels, the chosen one checked; a pick shows at once and saves (the model puts it back on failure). */
    private fun bindNotificationRows(): List<View> = levelRows.map { (level, row) ->
        val chosen = stations.notificationLevel == level
        row.isSelected = chosen
        row.findViewWithTag<View>(LEVEL_CHECK)?.alpha = if (chosen) 1f else 0f
        row
    }

    private fun notificationTitle(level: StillfailNotificationLevel): String = activity.getString(when (level) {
        StillfailNotificationLevel.OFF -> R.string.ds_plugins_stillfail_notifications_off
        StillfailNotificationLevel.ACTION_NEEDED -> R.string.ds_plugins_stillfail_notifications_action_needed
        StillfailNotificationLevel.ISSUES -> R.string.ds_plugins_stillfail_notifications_issues
        StillfailNotificationLevel.ALL -> R.string.ds_plugins_stillfail_notifications_all
    })

    private fun notificationDescription(level: StillfailNotificationLevel): String = activity.getString(when (level) {
        StillfailNotificationLevel.OFF -> R.string.ds_plugins_stillfail_notifications_off_description
        StillfailNotificationLevel.ACTION_NEEDED -> R.string.ds_plugins_stillfail_notifications_action_needed_description
        StillfailNotificationLevel.ISSUES -> R.string.ds_plugins_stillfail_notifications_issues_description
        StillfailNotificationLevel.ALL -> R.string.ds_plugins_stillfail_notifications_all_description
    })

    /**
     * A Google sign-in: the page opens in the browser, which shows a code; the code pasted here connects the account. A
     * rejected code stays, to correct; a fresh sign-in link replaces the old one in place.
     */
    private fun codeRows(plugin: Plugin, form: PluginConfiguration): List<View> {
        val rows = mutableListOf<View>(activity.noteRow(activity.getString(R.string.ds_plugins_code_hint)))
        form.helpUrl?.let { url -> rows += activity.actionRow(activity.getString(R.string.ds_plugins_sign_in_google)) { activity.openLink(url) } }
        codeField.hint = form.label ?: activity.getString(R.string.ds_plugins_authorization_code)
        rows += codeField
        (model.formError?.let(activity::describe) ?: form.error)?.let { rows += activity.noteRow(it, R.color.token_text_error_primary) }
        rows += activity.actionRow(activity.getString(R.string.ds_plugins_code_connect)) {
            val value = code
            launch {
                model.install(plugin, value)?.let(activity::openLink)
                if (model.formError == null && model.scope.error == null) codeField.setText("")
            }
        }.apply { isEnabled = !plugin.locked && code.isNotEmpty() }
        rows += activity.infoRow(activity.getString(R.string.settings_cancel)).onClick {
            model.dismissConfiguration()
            codeField.setText("")
        }
        return rows
    }

    private fun sourceRows(plugin: Plugin, source: org.json.JSONObject): List<View> {
        val rows = mutableListOf<View>()
        val oauth = source.string("kind") == "native_mcp_oauth"
        val detail = listOfNotNull(source.string("selectedAccountId"), colabUsage(source),
            activity.getString(R.string.ds_plugins_tool_authorization).takeIf { oauth }).joinToString("\n")
        rows += activity.describedRow(sourceName(source.string("toolkit"), plugin.name), detail,
            status = activity.getString(R.string.ds_plugins_needs_reconnect).takeIf { source.string("state") == "needs_reauthorization" },
            statusColor = R.color.token_text_error_primary)
        if (source.string("state") != "ready" && !oauth) {
            source.objects("candidates").mapNotNull { it.string("id") }.forEach { account ->
                rows += activity.actionRow(account) {
                    launch { sources.run("plugin.sources.prepare", json("toolkit" to source.string("toolkit").orEmpty(), "account" to account)) }
                }.apply { isEnabled = !sources.pending }
            }
        }
        source.string("connectionId")?.let { connection ->
            rows += activity.actionRow(activity.getString(R.string.ds_reconnect_account)) {
                launch { model.install(plugin, connection = connection, binding = source.string("bindingId"))?.let(activity::openLink) }
            }.apply { isEnabled = !sources.pending }
        }
        return rows
    }

    /** The core asks to confirm an account before it is connected. */
    private fun confirmAccount() {
        val identity = sources.confirmation?.string("identity").orEmpty()
        val key = sources.confirmation?.toString()
        if (key == null || key == confirming) { confirming = key; return }
        confirming = key
        ConfirmDialog(activity, activity.getString(R.string.ds_plugins_confirm_account), identity,
            activity.getString(R.string.ds_confirm), destructive = false,
            onCancel = { launch { sources.run("plugin.sources.cancel") } }) { launch { sources.run("plugin.sources.confirm") } }.show()
    }

    /** A Google Colab account's compute units left and the Colab VMs running on it, as the server last read them. */
    private fun colabUsage(source: org.json.JSONObject): String? {
        if (source.string("kind") != "oauth_code_paste") return null
        val metadata = source.optJSONObject("metadata") ?: return null
        val balance = metadata.opt("ccuBalance").let { it as? Number }?.toDouble()?.let {
            activity.getString(R.string.ds_plugins_colab_units, java.text.NumberFormat.getNumberInstance().apply { maximumFractionDigits = 1 }.format(it))
        }
        val vms = metadata.opt("activeVmCount").let { it as? Number }?.toInt()?.let { activity.getString(R.string.ds_plugins_colab_vms, it) }
        return listOfNotNull(balance, vms).joinToString(" · ").ifEmpty { null }
    }

    private fun sourceName(toolkit: String?, fallback: String) = when (toolkit?.lowercase()) {
        "google-colab" -> "Google Colab"
        "gmail" -> "Gmail"
        "googlecalendar" -> "Google Calendar"
        "googledrive" -> "Google Drive"
        "slack" -> "Slack"
        else -> fallback
    }
}
