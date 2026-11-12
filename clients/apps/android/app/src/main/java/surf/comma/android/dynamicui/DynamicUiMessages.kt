package surf.comma.android.dynamicui

import org.json.JSONArray
import org.json.JSONObject

/** One chat message's generated UI: attachment [index] of [messageId] in [conversationId], read by its content [id]. */
data class DynamicUiTarget(
    val id: String,
    val conversationId: String,
    val messageId: String,
    val index: Int,
    val summary: String,
) {
    fun json(): JSONObject = JSONObject().put("contentId", id).put("conversationId", conversationId)
        .put("messageId", messageId).put("attachmentIndex", index).put("summary", summary)

    companion object {
        /** The core's `dynamic-ui` part, or a row payload [json] wrote; null without an identity to read it by. */
        fun parse(json: JSONObject?, fallbackSummary: String = ""): DynamicUiTarget? {
            json ?: return null
            fun field(name: String) = json.optString(name).takeIf { json.has(name) && !json.isNull(name) && it.isNotEmpty() }
            val index = json.opt("attachmentIndex") as? Int ?: return null
            if (index < 0) return null
            return DynamicUiTarget(field("contentId") ?: return null, field("conversationId") ?: return null,
                field("messageId") ?: return null, index, field("summary") ?: fallbackSummary)
        }

        fun decode(payload: String?): DynamicUiTarget? =
            payload?.let { runCatching { parse(JSONObject(it)) }.getOrNull() }
    }
}

/** What the runtime frame said, after the host page's checks and these. Anything else is dropped. */
sealed interface DynamicUiEvent {
    data object Ready : DynamicUiEvent
    /** Text the widget proposes for the draft; the member adds it, and sends it later. */
    data class Request(val text: String) : DynamicUiEvent
    /** An HTTPS link without credentials; the member confirms it first. */
    data class OpenLink(val url: String) : DynamicUiEvent
    data class Error(val reason: String?) : DynamicUiEvent
    /** The widget's own state (`state`) or its cards' progress (`cards`), as JSON text. */
    data class Save(val kind: String, val text: String) : DynamicUiEvent

    companion object {
        const val MAX_WIRE_BYTES = 40_000
        const val MAX_TEXT = 4000
        const val MAX_REASON = 200
        const val MAX_SAVED_BYTES = 32_768

        /** One runtime message's JSON text, as the iOS app reads it. */
        fun parse(wire: String): DynamicUiEvent? {
            if (wire.toByteArray(Charsets.UTF_8).size > MAX_WIRE_BYTES) return null
            val json = runCatching { JSONObject(wire) }.getOrNull() ?: return null
            fun text(name: String) = json.opt(name) as? String
            return when (json.opt("type")) {
                "ready" -> Ready
                "request" -> text("value")?.takeIf { it.length <= MAX_TEXT }?.let(::Request)
                "open-link" -> text("url")?.takeIf { it.length <= MAX_TEXT && isOpenableLink(it) }?.let(::OpenLink)
                "error" -> Error(text("reason")?.take(MAX_REASON))
                "save", "card-state" -> {
                    if (!json.has("value")) return null
                    val saved = jsonText(json.get("value")) ?: return null
                    if (saved.toByteArray(Charsets.UTF_8).size > MAX_SAVED_BYTES) return null
                    Save(if (json.opt("type") == "save") "state" else "cards", saved)
                }
                else -> null
            }
        }

        fun isOpenableLink(url: String): Boolean = runCatching {
            val uri = java.net.URI(url)
            uri.scheme == "https" && uri.rawUserInfo == null && !uri.host.isNullOrEmpty()
        }.getOrDefault(false)

        private fun jsonText(value: Any): String? = when (value) {
            JSONObject.NULL -> "null"
            is JSONObject, is JSONArray -> value.toString()
            is String -> JSONObject.quote(value)
            is Boolean -> value.toString()
            is Number -> JSONObject.numberToString(value)
            else -> null
        }
    }
}

/** What the host page sends on the app's port. */
sealed interface DynamicUiFrame {
    data object Connected : DynamicUiFrame
    data object Started : DynamicUiFrame
    data class Failed(val reason: String) : DynamicUiFrame
    data class Event(val event: DynamicUiEvent) : DynamicUiFrame

    companion object {
        fun parse(data: String?): DynamicUiFrame? {
            if (data == null || data.length > DynamicUiEvent.MAX_WIRE_BYTES * 2) return null
            val json = runCatching { JSONObject(data) }.getOrNull() ?: return null
            return when (json.opt("kind")) {
                "connected" -> Connected
                "started" -> Started
                "failed" -> Failed((json.opt("reason") as? String).orEmpty().take(DynamicUiEvent.MAX_REASON))
                "event" -> (json.opt("wire") as? String)?.let(DynamicUiEvent::parse)?.let(::Event)
                else -> null
            }
        }
    }
}
