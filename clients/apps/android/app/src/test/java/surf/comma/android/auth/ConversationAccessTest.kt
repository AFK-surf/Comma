package surf.comma.android.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The connected account's main chat as other modules see it: its scope names the chat, never the credential. */
class ConversationAccessTest {
    private var now = 1_800_000_000_000L
    private val store = MemorySessions()
    private val repository = TestAuthRepository(store, { now }, Dispatchers.Unconfined)

    @Test fun connectedScopeNamesTheChatAndNeverTheCredential() = runBlocking<Unit> {
        store.value = Session(SessionToken("secret-alice"), now / 1000 + 3600, "session-alice",
            Account("alice", "alice@example.test", null, "active"))
        repository.start()
        repository.awaitState<AuthState.Connected>()
        val scope = repository.conversationScope.value!!
        assertEquals("alice", scope.accountId)
        assertEquals("g-alice", scope.groupId)
        assertEquals("chat-alice", scope.conversationId)
        assertFalse(scope.toString().contains("secret"))
        assertTrue(repository.isCurrentGeneration(scope.generation))
        repository.logout()
        repository.awaitState<AuthState.Login>()
        assertNull(repository.conversationScope.value)
        assertFalse(repository.isCurrentGeneration(scope.generation))
    }
}
