package surf.comma.android.performance

/** Build-specific observation hook. Release uses a no-op implementation without measurement code. */
interface ConversationTelemetry : AutoCloseable {
    fun scenario(value: String)
    fun beginReply()
    fun endReply(): String
}
