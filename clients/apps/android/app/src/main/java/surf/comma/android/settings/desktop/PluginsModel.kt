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
) {
    val working get() = activity in setOf("installing", "verifying", "reauthorizing", "uninstalling")
    val authorizing get() = activity == "authorizing"

    companion object {
        fun parse(json: JSONObject): Plugin? {
            val id = json.string("id") ?: return null
            val name = json.string("name") ?: return null
            val summary = json.string("summary").orEmpty()
            val setup = json.optJSONObject("credentialSetup")
            return Plugin(id, name, summary, json.string("description") ?: summary, json.string("brand") ?: id,
                json.optBoolean("installed"), json.optBoolean("locked"), json.string("activity") ?: "idle",
                setup?.string("key"), setup?.string("label"), setup?.string("helpUrl")?.takeIf { it.startsWith("https://") },
                json.optBoolean("toolGroups"), json.objects("mcps").mapNotNull { it.string("name") },
                json.objects("skills").mapNotNull { it.string("name") })
        }
    }
}

/**
 * Settings > Plugins: the catalog of this Workspace, browser authorization and the notices the core lets one client
 * claim. A notice for another Workspace is ignored, including an authorization link for the same plugin.
 */
internal class PluginsModel(val scope: WorkspaceScope) {
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
        val id = notice.int("id") ?: return
        val claimed = runCatching { scope.call("plugin.notice.claim", json("id" to id), workspaceParameter = false) }.getOrNull()
        if (claimed != true || !scope.current) return
        when (notice.string("kind")) {
            "authorize" -> notice.string("url")?.takeIf { it.startsWith("https://") }?.let {
                authorizationUrl = it
                authorizationPlugin = notice.string("plugin")
            }
            "configure" -> configurationPlugin = notice.string("plugin")
            else -> {
                scope.error = notice.string("message")?.let(PageError::Message) ?: PageError.Text(R.string.ds_plugins_connection_failed)
                return
            }
        }
        scope.changed()
    }

    /** Connects [plugin] (or reconnects its [connection]); returns the browser authorization link when there is one. */
    suspend fun install(plugin: Plugin, credential: String? = null, connection: String? = null): String? {
        if (!scope.current) return null
        val params = json("plugin" to plugin.id, "origin" to "plugins")
        if (plugin.credentialKey != null && credential != null) params.put("configValues", json(plugin.credentialKey to credential))
        if (connection != null) params.put("connection", connection)
        val answer = scope.perform(if (connection == null) "plugin.install" else "plugin.reauthorize", params) ?: return null
        if (answer.json?.string("failure") != null) {
            scope.error = PageError.Text(R.string.ds_plugins_connect_failed)
            return null
        }
        val url = answer.json?.string("authorizationUrl")?.takeIf { it.startsWith("https://") }
        configurationPlugin = null
        authorizationUrl = url
        authorizationPlugin = if (url == null) null else plugin.id
        scope.changed()
        return url
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
