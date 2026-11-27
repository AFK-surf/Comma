package surf.comma.android.conversation

import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope

/**
 * What a request asks the person to fill in before anything else: a [SECRET] value, which ends the request, or the
 * Workspace's own app, after which it waits on the provider's page as any other.
 */
data class AgentRequestInput(
    val kind: Kind,
    /** Where the person finds it (always https). */
    val helpUrl: String?,
    /** The address an app has to allow. */
    val redirectUri: String?,
    /** A CLI login's device code, to confirm on the page. */
    val code: String? = null,
    /** The values a [SECRET] asks for by name; empty for one value. */
    val fields: List<Field> = emptyList(),
) {
    /** One value a secret asks for: shown as typed unless [secret], and may be left empty when [optional]. */
    data class Field(val name: String, val label: String, val secret: Boolean, val optional: Boolean)

    enum class Kind(val wire: String) { SECRET("secret"), APP("app"), DEVICE("device"), OPEN("open"), PASTE("paste") }

    fun json(): JSONObject = JSONObject().put("kind", kind.wire).apply {
        helpUrl?.let { put("helpUrl", it) }
        redirectUri?.let { put("redirectUri", it) }
        code?.let { put("code", it) }
        if (fields.isNotEmpty()) put("fields", JSONArray(fields.map {
            JSONObject().put("name", it.name).put("label", it.label).put("secret", it.secret).put("optional", it.optional)
        }))
    }

    companion object {
        fun parse(json: JSONObject?): AgentRequestInput? {
            json ?: return null
            val kind = Kind.entries.firstOrNull { it.wire == json.optString("kind") } ?: return null
            return AgentRequestInput(
                kind = kind,
                helpUrl = json.string("helpUrl")?.takeIf { it.startsWith("https://") },
                redirectUri = json.string("redirectUri"),
                code = json.string("code"),
                fields = json.optJSONArray("fields")?.let { array ->
                    (0 until array.length()).mapNotNull { index ->
                        val field = array.optJSONObject(index) ?: return@mapNotNull null
                        val name = field.string("name") ?: return@mapNotNull null
                        Field(name, field.string("label") ?: name, field.optBoolean("secret", true), field.optBoolean("optional", false))
                    }
                }.orEmpty(),
            )
        }
    }
}

/**
 * An Agent's request to the person in a conversation, as the client core's `agentRequests` topic reads it (a
 * Capability Request). The server owns its status and outcome: the first ending wins, and every device shows it.
 * Connecting an account (`oauth_authorization`) succeeds on the provider's verified callback, so the person here opens
 * the provider's page or declines. A location request (`location`) ends when the person shares this device's position
 * once or declines; its [provider] is [LOCATION_PROVIDER], since no account stands behind it. A plugin install
 * (`plugin_install`) ends when the [plugin] is installed in its Workspace, by its card or anywhere else, or the person
 * declines; its [provider] is the plugin's id.
 */
data class AgentRequest(
    val id: String,
    val status: AgentRequestStatus,
    /** How a completed request ended. */
    val outcome: AgentRequestOutcome?,
    /** Unix milliseconds; null for no deadline. */
    val expiresAt: Long?,
    val createdAt: Long?,
    /** The person's message the Agent's turn served: the card sits under the reply to it. */
    val sourceMessageId: String?,
    val provider: String,
    /** Why the Agent asks, in its words. */
    val reason: String,
    /** The page to authorize on, while the request waits (always https). */
    val authorizationUrl: String?,
    /** The account it connected. */
    val account: String?,
    /** The name the Agent gave the account. */
    val alias: String? = null,
    /** What a secret is called, in the Agent's words. */
    val label: String? = null,
    /** What the person fills in first, while the request waits. */
    val input: AgentRequestInput? = null,
    /** The plugin a Router asks to install. */
    val plugin: AgentPluginInstall? = null,
) {
    /** The core's own JSON of the request, read back by [parse]. */
    fun json(): JSONObject = JSONObject().put("id", id)
        .put("type", when { plugin != null -> PLUGIN_TYPE; isLocation -> LOCATION_TYPE; else -> TYPE }).put("status", status.wire)
        .apply {
            outcome?.let { put("outcome", it.wire) }
            expiresAt?.let { put("expiresAt", it) }
            createdAt?.let { put("createdAt", it) }
            sourceMessageId?.let { put("sourceMessageId", it) }
        }
        .apply {
            if (plugin != null) put("plugin", plugin.json(reason))
            else put(if (isLocation) "location" else "oauth", JSONObject().put("reason", reason).apply {
                if (!isLocation) put("provider", provider)
                authorizationUrl?.let { put("authorizationUrl", it) }
                account?.let { put("account", it) }
                alias?.let { put("alias", it) }
                label?.let { put("label", it) }
                input?.let { put("input", it.json()) }
            })
        }

    /** This device's position is asked for, not an account. */
    val isLocation: Boolean get() = provider == LOCATION_PROVIDER

    companion object {
        private const val TYPE = "oauth_authorization"
        private const val LOCATION_TYPE = "location"
        private const val PLUGIN_TYPE = "plugin_install"
        const val LOCATION_PROVIDER = "location"

        /** Null for a request the app draws no card for. */
        fun parse(json: JSONObject?): AgentRequest? {
            json ?: return null
            if (json.optString("type") == LOCATION_TYPE) return parseLocation(json)
            if (json.optString("type") == PLUGIN_TYPE) return parsePlugin(json)
            if (json.optString("type") != TYPE) return null
            val oauth = json.optJSONObject("oauth") ?: return null
            return AgentRequest(
                id = json.string("id") ?: return null,
                status = AgentRequestStatus.entries.firstOrNull { it.wire == json.optString("status") } ?: return null,
                outcome = AgentRequestOutcome.entries.firstOrNull { it.wire == json.optString("outcome") },
                expiresAt = json.optLongOrNull("expiresAt"),
                createdAt = json.optLongOrNull("createdAt"),
                sourceMessageId = json.string("sourceMessageId"),
                provider = oauth.string("provider") ?: return null,
                reason = oauth.optString("reason"),
                // It opens in the browser: only an https page.
                authorizationUrl = oauth.string("authorizationUrl")?.takeIf { it.startsWith("https://") },
                account = oauth.string("account"),
                alias = oauth.string("alias"),
                label = oauth.string("label"),
                input = AgentRequestInput.parse(oauth.optJSONObject("input")),
            )
        }

        private fun parseLocation(json: JSONObject): AgentRequest? {
            val location = json.optJSONObject("location") ?: return null
            return AgentRequest(
                id = json.string("id") ?: return null,
                status = AgentRequestStatus.entries.firstOrNull { it.wire == json.optString("status") } ?: return null,
                outcome = AgentRequestOutcome.entries.firstOrNull { it.wire == json.optString("outcome") },
                expiresAt = json.optLongOrNull("expiresAt"),
                createdAt = json.optLongOrNull("createdAt"),
                sourceMessageId = json.string("sourceMessageId"),
                provider = LOCATION_PROVIDER,
                reason = location.optString("reason"),
                authorizationUrl = null,
                account = null,
            )
        }

        private fun parsePlugin(json: JSONObject): AgentRequest? {
            val plugin = json.optJSONObject("plugin") ?: return null
            val id = plugin.string("id") ?: return null
            return AgentRequest(
                id = json.string("id") ?: return null,
                status = AgentRequestStatus.entries.firstOrNull { it.wire == json.optString("status") } ?: return null,
                outcome = AgentRequestOutcome.entries.firstOrNull { it.wire == json.optString("outcome") },
                expiresAt = json.optLongOrNull("expiresAt"),
                createdAt = json.optLongOrNull("createdAt"),
                sourceMessageId = json.string("sourceMessageId"),
                provider = id,
                reason = plugin.optString("reason"),
                authorizationUrl = null,
                account = null,
                plugin = AgentPluginInstall(id, plugin.string("name") ?: id, plugin.string("brand"),
                    plugin.string("workspace") ?: return null),
            )
        }

        /** The requests of the core's `agentRequests` value, newest first as it gives them. */
        fun list(value: Any?): List<AgentRequest> {
            val requests = (value as? JSONObject)?.optJSONArray("requests") ?: return emptyList()
            return (0 until requests.length()).mapNotNull { parse(requests.optJSONObject(it)) }
        }
    }
}

/** A plugin a Router asks to install: adding it is the Plugins page's install, in the [workspace] it names. */
data class AgentPluginInstall(
    val id: String,
    val name: String,
    /** Whose mark the card shows; the plugin's id when null. */
    val brand: String?,
    /** The Workspace it goes into. */
    val workspace: String,
) {
    fun json(reason: String): JSONObject = JSONObject().put("id", id).put("name", name).put("reason", reason)
        .put("workspace", workspace).apply { brand?.let { put("brand", it) } }
}

/** The requests of one conversation, tied to the scope they were read for like [ConversationState]. */
data class AgentRequests(
    internal val scope: ConversationScope? = null,
    val conversationId: String? = null,
    val requests: List<AgentRequest> = emptyList(),
)

enum class AgentRequestStatus(val wire: String) {
    PENDING("pending"),
    COMPLETED("completed"),
    /** Its deadline passed with no decision. */
    EXPIRED("expired"),
    /** The Agent withdrew it. */
    CANCELLED("cancelled"),
    FAILED("failed"),
}

enum class AgentRequestOutcome(val wire: String) {
    CONNECTED("connected"), SHARED("shared"), DECLINED("declined"),
    /** A plugin install's: the plugin is in its Workspace. */
    INSTALLED("installed"),
}
