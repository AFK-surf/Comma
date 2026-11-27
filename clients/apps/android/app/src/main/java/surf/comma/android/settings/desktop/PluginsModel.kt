package surf.comma.android.settings.desktop

import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.TopicValue

/** A catalog plugin as the `plugins` topic says. */
internal data class Plugin(
    val id: String,
    val name: String,
    val summary: String,
    val description: String,
    val brand: String,
    val installed: Boolean,
    val locked: Boolean,
    val activity: String,
    val credentialKey: String?,
    val credentialLabel: String?,
    val helpUrl: String?,
    val toolGroups: Boolean,
    val tools: List<String>,
    val skills: List<String>,
    val credentialFormat: String? = null,
    val stations: Boolean = false,
) {
    val working get() = activity in setOf("installing", "verifying", "reauthorizing", "uninstalling")
    val authorizing get() = activity == "authorizing"
    /** `format == "show"`: the server returns a one-time connect line to copy instead of asking for a secret. */
    val showsConnectLine get() = credentialFormat == "show"
    /** True when installing asks the person to type a credential rather than copying a server-generated line. */
    val asksCredential get() = credentialKey != null && !showsConnectLine
    /** True for the Monoid (`stillfail`) plugin or any plugin that connects stations (`pluginStations`). */
    val isStillfail get() = id == STILLFAIL || stations

    companion object {
        /** Google Colab: its accounts run Colab VMs, which removing the plugin stops first. */
        const val COLAB = "google-colab"
        /** Monoid (`stillfail`): connects workspaces through stations and offers proactive notification levels. */
        const val STILLFAIL = "stillfail"

        fun parse(json: JSONObject): Plugin? {
            val id = json.string("id") ?: return null
            val name = json.string("name") ?: return null
            val summary = json.string("summary").orEmpty()
            val setup = json.optJSONObject("credentialSetup")
            return Plugin(
                id = id,
                name = name,
                summary = summary,
                description = json.string("description") ?: summary,
                brand = json.string("brand") ?: id,
                installed = json.optBoolean("installed"),
                locked = json.optBoolean("locked"),
                activity = json.string("activity") ?: "idle",
                credentialKey = setup?.string("key"),
                credentialLabel = setup?.string("label"),
                helpUrl = setup?.string("helpUrl")?.takeIf { it.startsWith("https://") },
                toolGroups = json.optBoolean("toolGroups"),
                tools = json.objects("mcps").mapNotNull { it.string("name") },
                skills = json.objects("skills").mapNotNull { it.string("name") },
                credentialFormat = setup?.string("format"),
                stations = json.optBoolean("stations"),
            )
        }
    }
}

/**
 * The credential form an install or reconnect asks for, as the core's `configure` notice says it: the value to fill
 * in, where to get it, and the attempt and connection it completes. A Google sign-in ([oauthCode]) gives a code to
 * paste back; a [showValue] notice gives a one-time connect line to copy; a new notice for the same plugin replaces
 * the form (a fresh sign-in link, or why the last code failed).
 */
internal data class PluginConfiguration(
    val plugin: String,
    val reauthorize: Boolean,
    val connectionId: String?,
    /** The connected account a reconnect is for; the connection alone names it when null. */
    val bindingId: String?,
    val key: String,
    val label: String?,
    /** Where the value comes from: the sign-in page for [oauthCode] (always https). */
    val helpUrl: String?,
    val format: String?,
    /** The sign-in attempt the pasted code belongs to. */
    val attemptId: String?,
    /** Why the last code did not connect, in the server's words. */
    val error: String?,
    /** The one-time connect line to show and copy when [showValue] is true. */
    val value: String? = null,
) {
    /** The person signs in with Google and pastes the code the page shows. */
    val oauthCode get() = format == "oauth_code"
    /** Nothing is asked; [value] is shown for the person to copy into their station. */
    val showValue get() = format == "show"

    companion object {
        /** The form of a `configure` notice; null when it carries none (a core that only names the plugin). */
        fun parse(notice: JSONObject): PluginConfiguration? {
            val plugin = notice.string("plugin") ?: return null
            val configuration = notice.optJSONObject("configuration") ?: return null
            val setup = configuration.optJSONObject("setup") ?: return null
            return PluginConfiguration(
                plugin = plugin,
                reauthorize = configuration.string("operation") == "reauthorize",
                connectionId = configuration.string("connectionId"),
                bindingId = configuration.string("bindingId"),
                key = setup.string("key") ?: return null,
                label = setup.string("label"),
                helpUrl = setup.string("helpUrl")?.takeIf { it.startsWith("https://") },
                format = setup.string("format"),
                attemptId = setup.string("attemptId"),
                error = setup.string("error"),
                value = setup.string("value"),
            )
        }
    }
}

/**
 * Settings > Plugins: the catalog of this Workspace, browser authorization and the notices the core lets one client
 * claim. A notice for another Workspace is ignored, including an authorization link for the same plugin. With [only],
 * the model takes the notices of that one plugin (an install started from a chat's card) and leaves the rest.
 */
internal class PluginsModel(val scope: WorkspaceScope, private val only: String? = null) {
    var plugins: List<Plugin> = emptyList()
        private set
    var loaded = false
        private set
    var authorizationUrl: String? = null
        private set
    var authorizationPlugin: String? = null
        private set
    var configurationPlugin: String? = null
        private set
    /** The form the core asked for last, while it waits to be filled in. */
    var configuration: PluginConfiguration? = null
        private set
    /** Why the value just sent did not connect; the form stays as it was, to correct it in place. */
    var formError: PageError? = null
        private set

    fun follow(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "plugins", "prefer" to scope.workspaceId)) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> receive(update.value as? JSONObject ?: return@collect)
                is TopicValue.Failed -> { loaded = true; scope.error = WorkspaceScope.describe(update.error) }
            }
        }
    }

    private fun receive(json: JSONObject) {
        val status = json.string("status")
        when {
            status == "ready" && json.string("workspace") == scope.workspaceId -> {
                plugins = json.objects("plugins").mapNotNull(Plugin::parse)
                loaded = true
                val pending = authorizationPlugin?.let { id -> plugins.firstOrNull { it.id == id } }
                if (pending != null && !pending.authorizing && !pending.working) {
                    authorizationUrl = null
                    authorizationPlugin = null
                }
                scope.changed()
            }
            status == "ready" -> { loaded = true; scope.error = PageError.Text(R.string.ds_plugins_unavailable) }
            status == "error" || status == "empty" -> {
                loaded = true
                scope.error = json.optJSONObject("error")?.string("message")?.let(PageError::Message)
                    ?: PageError.Text(R.string.ds_plugins_load_failed)
            }
        }
    }

    fun followNotices(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "pluginNotices")) { it }.collect { update ->
            if (!scope.current || update !is TopicValue.Value) return@collect
            val notices = (update.value as? JSONArray)?.objects() ?: (update.value as? JSONObject)?.objects("notices").orEmpty()
            notices.forEach { receiveNotice(it) }
        }
    }

    suspend fun receiveNotice(notice: JSONObject) {
        if (!scope.current || notice.string("workspace") != scope.workspaceId) return
        if (only != null && notice.string("plugin") != only) return
        val id = notice.int("id") ?: return
        val claimed = runCatching { scope.call("plugin.notice.claim", json("id" to id), workspaceParameter = false) }.getOrNull()
        if (claimed != true || !scope.current) return
        when (notice.string("kind")) {
            "authorize" -> notice.string("url")?.takeIf { it.startsWith("https://") }?.let {
                authorizationUrl = it
                authorizationPlugin = notice.string("plugin")
            }
            "configure" -> {
                configurationPlugin = notice.string("plugin")
                configuration = PluginConfiguration.parse(notice)
                formError = null
            }
            else -> {
                scope.error = notice.string("message")?.let(PageError::Message) ?: PageError.Text(R.string.ds_plugins_connection_failed)
                return
            }
        }
        scope.changed()
    }

    /** The form shown for [plugin], if the core asked for one. */
    fun configuration(plugin: Plugin): PluginConfiguration? = configuration?.takeIf { it.plugin == plugin.id }

    /**
     * Starts connecting [plugin] (or reconnecting its [connection] and [binding]), or sends the [credential] its form
     * asked for. Sent, the value goes to the attempt and operation of the form the core asked for last. Returns the
     * browser authorization link when there is one.
     */
    suspend fun install(plugin: Plugin, credential: String? = null, connection: String? = null, binding: String? = null): String? {
        if (!scope.current) return null
        val form = if (credential == null) null else configuration(plugin)
        val reauthorize = form?.reauthorize ?: (connection != null || binding != null)
        val params = json("plugin" to plugin.id, "origin" to "plugins")
        val key = form?.key ?: plugin.credentialKey
        if (key != null && credential != null) params.put("configValues", json(key to credential))
        form?.attemptId?.let { params.put("attemptId", it) }
        if (reauthorize) {
            (form?.connectionId ?: connection)?.let { params.put("connection", it) }
            (form?.bindingId ?: binding)?.let { params.put("bindingId", it) }
        }
        // A new start replaces the form; its own `configure` notice may come before this call answers.
        if (credential == null) {
            configuration = null
            configurationPlugin = null
        }
        formError = null
        val answer = scope.perform(if (reauthorize) "plugin.reauthorize" else "plugin.install", params) ?: return null
        val failure = answer.json?.string("failure")
        if (failure != null) {
            if (form != null) {
                // The server's own words (a code for another Google account, say) say what to do instead.
                val message = answer.json?.string("message")?.takeIf { it.isNotBlank() }
                formError = message?.let { PageError.Message(it) }
                    ?: PageError.Text(if (form.oauthCode && failure == "credential_rejected") R.string.ds_plugins_code_rejected
                        else R.string.ds_plugins_connect_failed)
                scope.changed()
            } else {
                scope.error = PageError.Text(R.string.ds_plugins_connect_failed)
            }
            return null
        }
        val url = answer.json?.string("authorizationUrl")?.takeIf { it.startsWith("https://") }
        // A form the core replaced while the value was on its way (a fresh sign-in) stays.
        if (credential != null && configuration == form) {
            configuration = null
            configurationPlugin = null
        }
        authorizationUrl = url
        authorizationPlugin = if (url == null) null else plugin.id
        scope.changed()
        return url
    }

    /** Puts the form away without sending anything. */
    fun dismissConfiguration() {
        configuration = null
        configurationPlugin = null
        formError = null
        scope.changed()
    }

    suspend fun refresh() {
        scope.perform("plugins.refresh")
        checkAuthorization()
    }

    suspend fun checkAuthorization() {
        runCatching { scope.call("plugin.authorization.check", workspaceParameter = false) }
    }

    suspend fun remove(plugin: Plugin) { scope.perform("plugin.uninstall", json("plugin" to plugin.id)) }
}

/** An open plugin's connected accounts and tool groups; followed only while its page is open. */
internal class PluginSourcesModel(val scope: WorkspaceScope, val plugin: String) {
    var sources: List<JSONObject> = emptyList()
        private set
    var groups: List<JSONObject> = emptyList()
        private set
    var confirmation: JSONObject? = null
        private set
    var pending = false
        private set

    fun followSources(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "pluginSources", "workspace" to scope.workspaceId, "plugin" to plugin)) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> {
                    val json = update.value as? JSONObject ?: return@collect
                    sources = json.objects("sources")
                    confirmation = json.optJSONObject("confirmation")
                    pending = json.optJSONObject("pending") != null
                    if (json.string("error") != null) scope.error = PageError.Text(R.string.ds_plugins_accounts_failed) else scope.changed()
                }
                is TopicValue.Failed -> scope.error = WorkspaceScope.describe(update.error)
            }
        }
    }

    fun followGroups(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "pluginToolGroups", "workspace" to scope.workspaceId, "plugin" to plugin)) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> {
                    val json = update.value as? JSONObject ?: return@collect
                    groups = json.objects("groups")
                    if (json.string("error") != null) scope.error = PageError.Text(R.string.ds_plugins_tools_failed) else scope.changed()
                }
                is TopicValue.Failed -> scope.error = WorkspaceScope.describe(update.error)
            }
        }
    }

    suspend fun run(name: String, params: JSONObject = JSONObject()) {
        scope.perform(name, params.put("plugin", plugin))
    }
}

/** One Monoid workspace connected through a station, as the core's `pluginStations` topic says. */
internal data class PluginStation(
    val id: String,
    val name: String?,
    val workspace: String?,
    val emoji: String?,
    val station: String?,
    val stationCount: Int?,
    val connected: Boolean,
    val connectedAt: String?,
) {
    val waiting: Boolean get() = connectedAt == null
    val offline: Boolean get() = connectedAt != null && !connected

    companion object {
        fun parse(json: JSONObject): PluginStation? {
            val id = json.string("id") ?: return null
            return PluginStation(
                id = id,
                name = json.string("name"),
                workspace = json.string("workspace"),
                emoji = json.string("emoji"),
                station = json.string("station"),
                stationCount = json.int("stationCount")?.toInt(),
                connected = json.optBoolean("connected", false),
                connectedAt = json.string("connectedAt"),
            )
        }
    }
}

/** The owner's proactive notification level for connected Monoid chats. */
internal enum class StillfailNotificationLevel(val wire: String) {
    OFF("off"),
    ACTION_NEEDED("action_needed"),
    ISSUES("issues"),
    ALL("all");

    companion object {
        fun parse(wire: String?): StillfailNotificationLevel =
            entries.firstOrNull { it.wire == wire } ?: ACTION_NEEDED
    }
}

/**
 * Connected Monoid workspaces (`pluginStations`), single-station disconnect, and 4-tier proactive notification level.
 * Followed only while the installed Monoid plugin detail page is open.
 */
internal class PluginStationsModel(val scope: WorkspaceScope, val plugin: String) {
    /** Null until the first read completes. */
    var stations: List<PluginStation>? = null
        private set
    var notificationLevel: StillfailNotificationLevel = StillfailNotificationLevel.ACTION_NEEDED
        private set
    /** Station id currently being disconnected, or null. */
    var pending: String? = null
        private set
    /** True while a notification level change is in flight. */
    var notificationPending: Boolean = false
        private set
    /** Last error code from the topic or local call: `load_failed`, `disconnect_failed`, `notification_save_failed`. */
    var error: String? = null
        private set

    val hasOfflineStation: Boolean get() = stations?.any { it.offline } == true

    fun follow(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "pluginStations", "workspace" to scope.workspaceId, "plugin" to plugin)) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> {
                    val json = update.value as? JSONObject ?: return@collect
                    stations = if (!json.has("stations") || json.isNull("stations")) null
                        else json.objects("stations").mapNotNull(PluginStation::parse)
                    notificationLevel = StillfailNotificationLevel.parse(json.string("notificationLevel"))
                    pending = json.string("pending")
                    notificationPending = json.optBoolean("notificationPending", false)
                    error = json.string("error")
                    scope.changed()
                }
                is TopicValue.Failed -> {
                    error = "load_failed"
                    scope.changed()
                }
            }
        }
    }

    /** Disconnects one Monoid workspace/station; returns true if the call succeeded. */
    suspend fun disconnect(stationId: String): Boolean {
        if (!scope.current || pending != null) return false
        pending = stationId
        error = null
        scope.changed()
        return try {
            scope.call("plugin.station.disconnect", json("plugin" to plugin, "station" to stationId))
            if (scope.current && pending == stationId) {
                pending = null
                scope.changed()
            }
            true
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            if (scope.current) {
                if (pending == stationId) pending = null
                error = "disconnect_failed"
                scope.changed()
            }
            false
        }
    }

    /** Saves the owner's proactive notification level; disabled while another save is in flight. */
    suspend fun setNotificationLevel(level: StillfailNotificationLevel): Boolean {
        if (!scope.current || notificationPending || level == notificationLevel) return false
        val previous = notificationLevel
        notificationLevel = level
        notificationPending = true
        error = null
        scope.changed()
        return try {
            scope.call("plugin.station.notificationLevel.set", json("plugin" to plugin, "level" to level.wire))
            if (scope.current) {
                notificationPending = false
                scope.changed()
            }
            true
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            if (scope.current) {
                notificationLevel = previous
                notificationPending = false
                error = "notification_save_failed"
                scope.changed()
            }
            false
        }
    }
}
