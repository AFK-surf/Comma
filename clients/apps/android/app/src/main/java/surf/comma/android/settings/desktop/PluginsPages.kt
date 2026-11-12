package surf.comma.android.settings.desktop

import android.text.InputType
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
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

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

/** One plugin: its description, connection, connected accounts, tool groups and skills. */
internal class PluginDetailPage(ctx: SettingsContext, private val model: PluginsModel, private val pluginId: String) :
    WorkspacePage(ctx, R.string.ds_plugin, "plugins.detail", model.scope,
        titleText = model.plugins.firstOrNull { it.id == pluginId }?.name) {
    private val sources = PluginSourcesModel(model.scope, pluginId)
    private val plugin get() = model.plugins.firstOrNull { it.id == pluginId }
    private val header = SettingsSection(activity, null)
    private val connection = SettingsSection(activity, activity.getString(R.string.ds_plugins_connection))
    private val accounts = SettingsSection(activity, activity.getString(R.string.ds_plugins_accounts))
        .footer(activity.getString(R.string.ds_plugins_accounts_footer))
    private val tools = SettingsSection(activity, activity.getString(R.string.ds_plugins_tools))
    private val skills = SettingsSection(activity, activity.getString(R.string.ds_plugins_skills))
    private var credential = ""
    private val credentialField = activity.fieldRow(activity.getString(R.string.ds_api_key),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD) { credential = it; render() }
    private var sourcesJob: Job? = null
    private var groupsJob: Job? = null
    private var confirming: String? = null

    init {
        layout.section(header, top = 0)
        layout.section(connection)
        layout.section(accounts)
        layout.section(tools)
        layout.section(skills)
        loading.isVisible = false
        start()
    }

    override fun onClose() {
        credentialField.setText("")
        sourcesJob?.cancel()
        groupsJob?.cancel()
    }

    /** Only the open detail follows its accounts and tools, and only while the plugin is connected. */
    private fun follow(plugin: Plugin) {
        if (plugin.installed && sourcesJob == null) sourcesJob = sources.followSources()
        if (!plugin.installed) { sourcesJob?.cancel(); sourcesJob = null }
        val groups = plugin.installed && plugin.toolGroups
        if (groups && groupsJob == null) groupsJob = sources.followGroups()
        if (!groups) { groupsJob?.cancel(); groupsJob = null }
    }

    override fun render() {
        super.render()
        val plugin = plugin
        listOf(header, connection, accounts, tools, skills).forEach { it.isVisible = plugin != null }
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
        confirmAccount()
    }

    private fun connectionRows(plugin: Plugin): List<View> {
        val rows = mutableListOf<View>()
        when {
            plugin.authorizing || (model.authorizationPlugin == plugin.id && model.authorizationUrl != null) -> {
                rows += activity.noteRow(activity.getString(R.string.ds_plugins_authorizing))
                model.authorizationUrl?.takeIf { model.authorizationPlugin == plugin.id }?.let { url ->
                    rows += activity.actionRow(activity.getString(R.string.ds_continue_in_browser)) { activity.openLink(url) }
                }
                rows += activity.infoRow(activity.getString(R.string.ds_cancel_connection)).onClick { launch { sources.run("plugin.cancel") } }
            }
            plugin.working -> rows += activity.noteRow(activity.getString(R.string.ds_plugins_updating))
            !plugin.installed || model.configurationPlugin == plugin.id -> {
                if (plugin.credentialKey != null) {
                    credentialField.hint = plugin.credentialLabel ?: activity.getString(R.string.ds_api_key)
                    rows += credentialField
                    plugin.helpUrl?.let { url -> rows += activity.actionRow(activity.getString(R.string.ds_plugins_setup_help)) { activity.openLink(url) } }
                }
                rows += activity.actionRow(activity.getString(R.string.ds_plugins_connect)) {
                    launch {
                        val url = model.install(plugin, credential.ifEmpty { null })
                        credentialField.setText("")
                        url?.let(activity::openLink)
                    }
                }.apply { isEnabled = !plugin.locked && !(plugin.credentialKey != null && credential.isEmpty()) }
            }
            else -> {
                rows += activity.infoRow(activity.getString(R.string.ds_status), activity.getString(R.string.ds_connected))
                if (!plugin.locked) rows += activity.actionRow(activity.getString(R.string.ds_plugins_remove), destructive = true) {
                    ConfirmDialog(activity, activity.getString(R.string.ds_plugins_remove_title), activity.getString(R.string.ds_plugins_remove_message),
                        activity.getString(R.string.ds_plugins_remove), destructive = true) { launch { model.remove(plugin) } }.show()
                }
            }
        }
        return rows
    }

    private fun sourceRows(plugin: Plugin, source: org.json.JSONObject): List<View> {
        val rows = mutableListOf<View>()
        val oauth = source.string("kind") == "native_mcp_oauth"
        val detail = listOfNotNull(source.string("selectedAccountId"),
            activity.getString(R.string.ds_plugins_tool_authorization).takeIf { oauth }).joinToString("\n")
        rows += activity.describedRow(sourceName(source.string("toolkit"), plugin.name), detail)
        if (source.string("state") != "ready" && !oauth) {
            source.objects("candidates").mapNotNull { it.string("id") }.forEach { account ->
                rows += activity.actionRow(account) {
                    launch { sources.run("plugin.sources.prepare", json("toolkit" to source.string("toolkit").orEmpty(), "account" to account)) }
                }.apply { isEnabled = !sources.pending }
            }
        }
        source.string("connectionId")?.let { connection ->
            rows += activity.actionRow(activity.getString(R.string.ds_reconnect_account)) {
                launch { model.install(plugin, connection = connection)?.let(activity::openLink) }
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

    private fun sourceName(toolkit: String?, fallback: String) = when (toolkit?.lowercase()) {
        "gmail" -> "Gmail"
        "googlecalendar" -> "Google Calendar"
        "googledrive" -> "Google Drive"
        "slack" -> "Slack"
        else -> fallback
    }
}
