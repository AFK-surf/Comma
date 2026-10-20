package surf.comma.android.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * What the app makes of the client core's session and its `workspaceChat`: the sign-in page's state, the account's
 * main chat, and the chat shown for a kept credential before the core confirmed it. The session lifecycle and the
 * chat's resolution (waiting out a workspace being made, the chat kept on the device) are the core's and are tested
 * there.
 */
class AuthRepositoryTest {
    private val store = MemorySessions()
    private var now = 1_800_000_000_000L
    private val core = TestSessionCore(store) { now }
    private fun session(user: String = "alice", expires: Long = now / 1000 + 3600) =
        Session(SessionToken("secret-$user"), expires, "session-$user", Account(user, "$user@example.test", null, "active"))
    private fun repository() = TestAuthRepository(store, { now }, Dispatchers.Unconfined, core = core)

    private suspend inline fun <reified T : AuthState> AuthRepository.await(crossinline matches: (T) -> Boolean = { true }): T =
        state.first { it is T && matches(it) } as T

    @Test fun nobodySignedInShowsTheSignInPage() = runBlocking {
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Login(), repository.await<AuthState.Login>())
        assertNull(repository.conversationScope.value)
    }

    @Test fun aCodeIsRequestedThenVerifiedAndTheWorkspaceChatFound() = runBlocking {
        val repository = repository()
        repository.start()
        repository.await<AuthState.Login>()
        repository.sendCode(" alice@example.test ")
        val asked = repository.await<AuthState.Login> { it.challengeId != null }
        assertEquals("challenge-1", asked.challengeId)
        assertEquals("alice@example.test", asked.email)
        assertEquals("alice@example.test", core.calls.first { it.first == "session.email.request" }.second.getString("email"))

        repository.verify("123456")
        val connected = repository.await<AuthState.Connected>()
        assertEquals(WorkspaceSelection(Workspace("w-alice", "g-alice", "W"), "chat-alice"), connected.selection)
        assertEquals("alice", connected.account.id)
        val scope = requireNotNull(repository.conversationScope.value)
        assertEquals(listOf("alice", "g-alice", "chat-alice"), listOf(scope.accountId, scope.groupId, scope.conversationId))
        val verify = core.calls.first { it.first == "session.email.verify" }.second
        assertEquals("challenge-1", verify.getString("challengeId"))
        assertEquals("attempt-1", verify.getJSONObject("attempt").getString("attemptId"))
    }

    @Test fun aWrongCodeKeepsTheChallengeAndCanBeTriedAgain() = runBlocking {
        val refused = AtomicInteger()
        core.answer = { name, _ ->
            if (name == "session.email.verify" && refused.getAndIncrement() == 0) core.failure("invalid_challenge") else null
        }
        val repository = repository()
        repository.start()
        repository.await<AuthState.Login>()
        repository.sendCode("alice@example.test")
        repository.await<AuthState.Login> { it.challengeId != null }
        repository.verify("000000")
        val wrong = repository.await<AuthState.Login> { it.problem != null }
        assertEquals(AuthProblem.INVALID_CODE, wrong.problem)
        assertEquals("challenge-1", wrong.challengeId)
        assertFalse(wrong.busy)
        repository.verify("123456")
        repository.await<AuthState.Connected>()
        Unit
    }

    @Test fun aRateLimitedAddressWaitsAsLongAsTheServerSaid() = runBlocking {
        core.answer = { name, _ -> if (name == "session.email.request") core.failure("rate_limited", 30_000) else null }
        val repository = repository()
        repository.start()
        repository.await<AuthState.Login>()
        repository.sendCode("alice@example.test")
        val limited = repository.await<AuthState.Login> { it.problem != null }
        assertEquals(AuthProblem.RATE_LIMITED, limited.problem)
        assertEquals(now + 30_000, limited.resendAtMillis)
        // Another address does not shorten the wait, and nothing is asked before it is over.
        repository.changeEmail()
        assertEquals(now + 30_000, repository.await<AuthState.Login> { it.problem == null }.resendAtMillis)
        repository.sendCode("bob@example.test")
        assertEquals(1, core.calls.count { it.first == "session.email.request" })
    }

    @Test fun aSixDigitCodeIsTheOnlyOneSent() = runBlocking {
        val repository = repository()
        repository.start()
        repository.await<AuthState.Login>()
        repository.sendCode("alice@example.test")
        repository.await<AuthState.Login> { it.challengeId != null }
        repository.verify("12345")
        repository.verify("12345a")
        assertEquals(0, core.calls.count { it.first == "session.email.verify" })
    }

    @Test fun aKeptCredentialShowsTheKeptChatBeforeTheCoreConfirmsItAndKeepsThatChatAfter() = runBlocking {
        store.value = session()
        core.phase = "initializing"
        core.kept = "alice"
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Connecting(ConnectionStep.SESSION), repository.await<AuthState.Connecting>())
        val early = repository.conversationScope.first { it != null }!!
        assertEquals("chat-alice", early.conversationId)
        assertEquals("alice", repository.savedAccount?.id)

        core.phase = null
        core.changed()
        repository.await<AuthState.Connected>()
        // The chat on screen is not rebuilt when the server confirms what was shown.
        assertSame(early, repository.conversationScope.value)
        assertTrue(repository.isCurrentGeneration(early.generation))
    }

    @Test fun aKeptAccountStaysOnScreenWhileTheServerCannotBeReachedAndRetryAsksTheCoreAgain() = runBlocking {
        store.value = session()
        core.phase = "indeterminate"
        core.kept = "alice"
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Retry(AuthProblem.NETWORK), repository.await<AuthState.Retry>())
        assertNotNull(repository.conversationScope.first { it != null })

        core.answer = { name, _ ->
            if (name == "session.recover") {
                core.phase = null
                core.changed()
            }
            null
        }
        repository.retry()
        repository.await<AuthState.Connected>()
        assertEquals(1, core.calls.count { it.first == "session.recover" })
    }

    @Test fun aSessionTheCoreEndsRemovesTheChat() = runBlocking {
        store.value = session()
        val repository = repository()
        repository.start()
        repository.await<AuthState.Connected>()
        val scope = repository.conversationScope.value!!

        store.value = null
        core.changed()
        repository.await<AuthState.Login>()
        assertNull(repository.conversationScope.value)
        assertFalse(repository.isCurrentGeneration(scope.generation))
    }

    @Test fun signingOutAsksTheCoreForTheSessionOnScreen() = runBlocking {
        store.value = session()
        val repository = repository()
        repository.start()
        repository.await<AuthState.Connected>()
        repository.logout()
        repository.await<AuthState.Login>()
        val expected = core.calls.single { it.first == "session.signOut" }.second.getJSONObject("expected")
        assertEquals("session-alice", expected.getString("expectedSessionId"))
        assertEquals(TestSessionCore.AUTHORITY, expected.getString("authorityInstanceId"))
    }

    @Test fun aWorkspaceStillBeingMadeSaysWhenTheCoreAsksAgainThenOpensItsChat() = runBlocking {
        store.value = session()
        core.workspaceChat = {
            JSONObject().put("status", "provisioning").put("chat", JSONObject.NULL).put("kept", false)
                .put("provisioning", JSONObject().put("workspaceId", "w-alice").put("groupId", "g-alice").put("retryAfterSeconds", 7))
        }
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Connecting(ConnectionStep.PROVISIONING, now + 7_000),
            repository.await<AuthState.Connecting> { it.step == ConnectionStep.PROVISIONING })
        assertNull(repository.conversationScope.value)
        core.workspaceChat = null
        core.changed()
        repository.await<AuthState.Connected>()
        assertEquals("chat-alice", repository.conversationScope.value?.conversationId)
    }

    @Test fun aFailedResolutionAsksTheCoreToResolveAgain() = runBlocking {
        store.value = session()
        core.workspaceChat = { JSONObject().put("status", "error").put("chat", JSONObject.NULL).put("kept", false) }
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Retry(AuthProblem.NETWORK), repository.await<AuthState.Retry>())
        core.workspaceChat = null
        repository.retry()
        repository.await<AuthState.Connected>()
        assertEquals(1, core.calls.count { it.first == "workspaceChat.retry" })
    }

    @Test fun anAccountWithoutAWorkspaceSaysSoAndCanSignOut() = runBlocking {
        store.value = session()
        core.workspaceChat = { JSONObject().put("status", "hidden").put("chat", JSONObject.NULL).put("kept", false) }
        val repository = repository()
        repository.start()
        assertEquals(AuthState.Retry(AuthProblem.NO_WORKSPACE), repository.await<AuthState.Retry>())
        repository.logout()
        repository.await<AuthState.Login>()
        Unit
    }

    @Test fun aBuildWithoutABackendAddressStartsNoSession() = runBlocking {
        val repository = AuthRepository(null, core, GoogleChooser(), kotlinx.coroutines.CoroutineScope(Dispatchers.Unconfined), { now })
        repository.start()
        assertEquals(AuthState.Unconfigured, repository.state.value)
        assertTrue(core.calls.isEmpty())
    }

    @Test fun credentialObjectsNeverPrintTokens() {
        assertFalse(session().toString().contains("secret-alice"))
        assertFalse(core.lease().toString().contains("secret-alice"))
    }
}

internal class MemorySessions : SessionStore {
    @Volatile var value: Session? = null
    override fun read() = value
    override fun write(session: Session) { value = session }
    override fun clear() { value = null }
}
