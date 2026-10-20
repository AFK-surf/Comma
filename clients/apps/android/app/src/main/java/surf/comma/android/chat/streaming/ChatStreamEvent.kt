package surf.comma.android.chat.streaming

/** Local rendering events, independent of any server protocol. */
sealed interface ChatStreamEvent {
    data class Delta(val text: String) : ChatStreamEvent
    data class Status(val stage: String, val message: String = "") : ChatStreamEvent
    data object Completed : ChatStreamEvent
}
