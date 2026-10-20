package surf.comma.android.voice

import org.json.JSONObject

enum class CallResult {
    Ended, CredentialsExpired, Busy, Unavailable, Disabled, Interrupted;
}

sealed interface VoiceMessage {
    data class Started(val callId: String, val audioFormat: String, val maxDurationSeconds: Int) : VoiceMessage
    data object Clear : VoiceMessage
    data class Mark(val name: String) : VoiceMessage
    class Transcript(val role: String, val text: String, val final: Boolean) : VoiceMessage {
        override fun toString() = "Transcript([redacted])"
    }
    data class Ended(val reason: String, val durationSeconds: Double?) : VoiceMessage
    class Error(val code: Int, val message: String) : VoiceMessage {
        override fun toString() = "VoiceError(code=$code)"
    }
}

/** Wire codec with no Android or transport dependencies. */
object VoiceProtocol {
    const val SUBPROTOCOL = "comma.voice.v1"
    const val AUDIO_FORMAT = "pcm16_24k"
    const val MAX_FRAME_BYTES = 16 * 1024
    const val FRAME_BYTES = 960
    const val FRAME_MILLIS = 20L

    fun start(versionName: String, displayName: String? = null): String {
        val client = "comma-android/$versionName"
        require(versionName.isNotBlank() && client.toByteArray().size <= 128) { "Invalid client version" }
        require(displayName == null || displayName.toByteArray().size <= 128) { "Invalid display name" }
        return JSONObject().put("type", "session.start").put("audio_format", AUDIO_FORMAT)
            .put("client", client).apply {
                displayName?.trim()?.takeIf(String::isNotEmpty)?.let { put("display_name", it) }
            }.toString()
    }

    fun played(name: String): String = JSONObject().put("type", "output.played").put("name", name).toString()
    fun end(): String = "{\"type\":\"session.end\"}"
    fun validAudio(size: Int): Boolean = size in 0..MAX_FRAME_BYTES && size % 2 == 0

    /** Unknown types/fields and malformed messages do not become application events. */
    fun decode(text: String): VoiceMessage? {
        if (text.toByteArray().size > MAX_FRAME_BYTES) return null
        return try {
            val json = JSONObject(text)
            when (json.getString("type")) {
                "session.started" -> VoiceMessage.Started(json.getString("call_id"),
                    json.getString("audio_format"), json.getInt("max_duration_s"))
                "output.clear" -> VoiceMessage.Clear
                "output.mark" -> VoiceMessage.Mark(json.getString("name"))
                "transcript" -> VoiceMessage.Transcript(json.getString("role"), json.getString("text"), json.getBoolean("final"))
                "session.ended" -> VoiceMessage.Ended(json.getString("reason"),
                    if (json.isNull("duration_s")) null else json.getDouble("duration_s"))
                "error" -> VoiceMessage.Error(json.getInt("code"), json.getString("message"))
                else -> null
            }
        } catch (_: Exception) { null }
    }

    fun result(code: Int?, reason: String? = null): CallResult = when (code) {
        1000 -> CallResult.Ended
        401, 4401 -> CallResult.CredentialsExpired
        409, 4409 -> CallResult.Busy
        503, 4503 -> if (reason == "disabled" || reason == "voice calls are disabled") CallResult.Disabled else CallResult.Unavailable
        else -> CallResult.Interrupted
    }

    /** An `error` always precedes a refusal or limit, even when the server closes it with 1000. */
    fun errorResult(code: Int, message: String): CallResult =
        result(code, message).takeUnless { it == CallResult.Ended } ?: CallResult.Unavailable

    /** The close reason text is the server's end reason; it is more specific than the shared code. */
    fun closeResult(code: Int, reason: String): CallResult =
        if (reason in END_REASONS) endedResult(reason) else result(code, reason)

    fun endedResult(reason: String): CallResult = when (reason) {
        "revoked" -> CallResult.CredentialsExpired
        "busy" -> CallResult.Busy
        "disabled" -> CallResult.Disabled
        "draining", "model_error", "unavailable", "node_full", "not_configured",
        "attach_timeout", "billing_unavailable" -> CallResult.Unavailable
        "bad_frame", "too_fast", "start_timeout", "idle_timeout", "pong_timeout", "slow_reader", "carrier_error",
        "other" -> CallResult.Interrupted
        else -> CallResult.Ended
    }

    /** A fixed vocabulary, safe for local diagnostics; anything else is reported as unrecognized. */
    fun diagnosticReason(reason: String): String = if (reason in END_REASONS) reason else "unrecognized"

    private val END_REASONS = setOf("completed", "caller_hangup", "agent_hangup", "max_duration", "revoked", "busy",
        "disabled", "draining", "model_error", "unavailable", "node_full", "not_configured", "bad_frame", "too_fast",
        "start_timeout", "idle_timeout", "pong_timeout", "slow_reader", "carrier_error", "attach_timeout",
        "billing_unavailable", "other")
}
