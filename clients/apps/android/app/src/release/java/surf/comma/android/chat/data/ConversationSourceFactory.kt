package surf.comma.android.chat.data

import android.content.Intent
import kotlinx.coroutines.flow.emptyFlow
import surf.comma.android.chat.model.ChatMessage

object ConversationSourceFactory {
    fun useFixtures(@Suppress("UNUSED_PARAMETER") intent: Intent): Boolean = false
    fun create(): ConversationSource = object : ConversationSource {
        override val canReplay = false
        override suspend fun load(): List<ChatMessage> = emptyList()
        override fun replay() = emptyFlow<List<ChatMessage>>()
    }
}
