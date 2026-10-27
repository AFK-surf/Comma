package surf.comma.android.conversation

import org.json.JSONObject
import surf.comma.android.auth.ConversationScope

/**
 * An Agent's request to the person in a conversation, as the client core's `agentRequests` topic reads it (a
 * Capability Request). The server owns its status and outcome: the first ending wins, and every device shows it.
 * Only connecting an account (`oauth_authorization`) has a card so far; its success is the provider's verified
 * callback, so the person here opens the provider's page or declines.
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
) {
    /** The core's own JSON of the request, read back by [parse]. */
    fun json(): JSONObject = JSONObject().put("id", id).put("type", TYPE).put("status", status.wire)
        .apply {
            outcome?.let { put("outcome", it.wire) }
            expiresAt?.let { put("expiresAt", it) }
            createdAt?.let { put("createdAt", it) }
            sourceMessageId?.let { put("sourceMessageId", it) }
        }
        .put("oauth", JSONObject().put("provider", provider).put("reason", reason).apply {
            authorizationUrl?.let { put("authorizationUrl", it) }
            account?.let { put("account", it) }
        })

    companion object {
        private const val TYPE = "oauth_authorization"

        /** Null for a request the app draws no card for. */
        fun parse(json: JSONObject?): AgentRequest? {
            json ?: return null
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
            )
        }

        /** The requests of the core's `agentRequests` value, newest first as it gives them. */
        fun list(value: Any?): List<AgentRequest> {
            val requests = (value as? JSONObject)?.optJSONArray("requests") ?: return emptyList()
            return (0 until requests.length()).mapNotNull { parse(requests.optJSONObject(it)) }
        }
    }
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

enum class AgentRequestOutcome(val wire: String) { CONNECTED("connected"), DECLINED("declined") }
