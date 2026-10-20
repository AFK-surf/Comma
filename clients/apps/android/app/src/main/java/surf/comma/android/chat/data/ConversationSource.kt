package surf.comma.android.chat.data

import kotlinx.coroutines.flow.Flow
import surf.comma.android.chat.model.ChatMessage

/** P1 UI boundary. No network transport, authentication or Cue projection is installed yet. */
interface ConversationSource {
    val canReplay: Boolean
    suspend fun load(): List<ChatMessage>
    fun replay(): Flow<List<ChatMessage>>
    /** [replay], preceded by a stretch of waiting for the reply to start. */
    fun replayAfterWaiting(): Flow<List<ChatMessage>> = replay()
}
