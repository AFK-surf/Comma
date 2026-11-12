package surf.comma.android.chat.live

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import surf.comma.android.notify.agentEntry
import surf.comma.android.notify.draftEntry
import surf.comma.android.notify.pendingEntry
import surf.comma.android.notify.state
import surf.comma.android.notify.userEntry
import java.util.Locale

/** Which turn the chat asks the core to suggest replies for, and which suggestions it shows. */
class ChatSuggestionTest {
    @Test
    fun asksOnlyForTheLastAgentMessageOfASettledLoadedTurn() {
        val settled = state(userEntry(1), agentEntry(2), userEntry(3), agentEntry(4)).copy(draft = "")
        assertEquals("msg_test_4", ChatSuggestion.settledMessage(settled))
        // Before the conversation loaded, while a send or a reply is in flight, and in an archived conversation: none.
        assertNull(ChatSuggestion.settledMessage(settled.copy(draft = null)))
        assertNull(ChatSuggestion.settledMessage(state(userEntry(1), agentEntry(2), pendingEntry()).copy(draft = "")))
        assertNull(ChatSuggestion.settledMessage(state(userEntry(1), agentEntry(2), draftEntry()).copy(draft = "")))
        assertNull(ChatSuggestion.settledMessage(state(userEntry(1), agentEntry(2), participant = "active").copy(draft = "")))
        assertNull(ChatSuggestion.settledMessage(settled.copy(status = "archived")))
        assertNull(ChatSuggestion.settledMessage(state(userEntry(1)).copy(draft = "")))
        // A member's message that no reply followed (the agent stopped with an error) closes the earlier suggestions.
        assertNull(ChatSuggestion.settledMessage(state(userEntry(1), agentEntry(2), userEntry(3)).copy(draft = "")))
    }

    @Test
    fun showsAtMostFourValidShortSuggestions() {
        fun item(id: String, prompt: String?) = JSONObject().put("id", id).put("label", "Label $id").put("prompt", prompt ?: JSONObject.NULL)
        val value = JSONArray(listOf(item("a", "Yes"), item("b", null), item("c", "A much longer instruction"),
            item("d", "Why?"), item("e", "More"), item("f", "Next"), item("g", "Stop")))
        assertEquals(listOf("a", "d", "e", "f"), ChatSuggestion.list(value).map { it.id })
        assertEquals(emptyList<ChatSuggestion>(), ChatSuggestion.list(null))
        // The row's payload carries them unchanged.
        val shown = ChatSuggestion.list(value)
        assertEquals(shown, ChatSuggestion.decode(ChatSuggestion.encode(shown)))
    }

    @Test
    fun asksInChineseOnlyForAChineseInterface() {
        assertEquals("zh-CN", ChatSuggestion.language(Locale.SIMPLIFIED_CHINESE))
        assertEquals("zh-CN", ChatSuggestion.language(Locale.forLanguageTag("zh-Hant-TW")))
        assertEquals("en", ChatSuggestion.language(Locale.JAPANESE))
    }
}
