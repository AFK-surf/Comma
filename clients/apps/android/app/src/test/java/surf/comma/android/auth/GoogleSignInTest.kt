package surf.comma.android.auth

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Google sign-in as the sign-in page sees it. The client core runs the sign-in (its attempt, the exchange, the link
 * code); the app lends it the account chooser and words what went wrong.
 */
class GoogleSignInTest {
    private val now = 1_800_000_000_000L
    private val store = MemorySessions()
    private val core = TestSessionCore(store) { now }
    private val asked = CopyOnWriteArrayList<Pair<String, String>>()
    private val token = GoogleCredential.Token("google-id-token")

    private fun source(result: GoogleCredential) = GoogleCredentialSource { clientId, nonce ->
        asked += clientId to nonce
        result
    }

    private suspend fun started() = TestAuthRepository(store, { now }, Dispatchers.Unconfined,
        core = core)
        .also { it.start(); it.awaitState<AuthState.Login>() }

    @Test fun theChoosersTokenSignsInAndIsKeptNowhereTheAppCanSee() = runBlocking {
        val repository = started()
        repository.signInWithGoogle(source(token))
        repository.awaitState<AuthState.Connected>()
        assertEquals("the chooser is asked with what the core's attempt named", listOf("client-id" to "nonce"), asked.toList())
        assertFalse(repository.state.value.toString().contains("google-id-token"))
        assertEquals(1, core.calls.count { it.first == "session.google.desktop" })
    }

    @Test fun anExistingAccountConfirmsTheLinkWithAnEmailCode() = runBlocking {
        core.answer = { name, params ->
            if (name == "session.google.desktop") core.linkChallenge("alice@example.test", "link-1", params.getJSONObject("expected")) else null
        }
        val repository = started()
        repository.signInWithGoogle(source(token))
        val code = repository.awaitState<AuthState.Login> { it.challengeId != null }
        assertEquals(listOf("alice@example.test", "link-1", true), listOf(code.email, code.challengeId, code.linkingGoogle))
        assertNull(store.value)
        // A link code has no resend; asking again does nothing.
        repository.sendCode("alice@example.test")
        assertEquals(0, core.calls.count { it.first == "session.email.request" })

        core.answer = { _, _ -> null }
        repository.verify("123456")
        repository.awaitState<AuthState.Connected>()
        assertEquals("link-1", core.calls.single { it.first == "session.google.linkVerify" }.second.getString("challengeId"))
    }

    @Test fun closingTheChooserReturnsQuietly() = runBlocking {
        val repository = started()
        repository.signInWithGoogle(source(GoogleCredential.Cancelled))
        assertEquals(AuthState.Login(), repository.awaitState<AuthState.Login> { !it.googleBusy })
    }

    @Test fun deviceProblemsAreExplainedByWhatTheChooserSaid() = runBlocking {
        val repository = started()
        for ((result, problem) in listOf(GoogleCredential.NoAccount to AuthProblem.GOOGLE_NO_ACCOUNT,
            GoogleCredential.Unavailable to AuthProblem.GOOGLE_UNAVAILABLE, GoogleCredential.Failed to AuthProblem.GOOGLE_REJECTED)) {
            repository.signInWithGoogle(source(result))
            assertEquals(problem, repository.awaitState<AuthState.Login> { !it.googleBusy }.googleProblem)
        }
        assertNull(store.value)
    }

    @Test fun theCoresRefusalsMapToTheirOwnMessages() = runBlocking {
        val repository = started()
        for ((failure, problem) in listOf(
            core.failure("provider_unavailable") to AuthProblem.GOOGLE_NOT_CONFIGURED,
            core.failure("provider_unavailable", 30_000) to AuthProblem.EMAIL_UNAVAILABLE,
            core.failure("conflict") to AuthProblem.GOOGLE_CONFLICT,
            core.failure("account_disabled") to AuthProblem.ACCOUNT_DISABLED,
            core.failure("rate_limited", 5_000) to AuthProblem.EMAIL_UNAVAILABLE,
            core.failure("invalid_challenge") to AuthProblem.GOOGLE_REJECTED,
            core.failure("network_unavailable") to AuthProblem.NETWORK,
        )) {
            core.answer = { name, _ -> if (name == "session.google.desktop") failure else null }
            repository.signInWithGoogle(source(token))
            val login = repository.awaitState<AuthState.Login> { !it.googleBusy }
            assertEquals(failure.toString(), problem, login.googleProblem)
            // Email sign-in stays available whatever Google said.
            assertNull(login.problem)
            assertFalse(login.busy)
        }
    }

    @Test fun whileTheChooserIsUpTheButtonIsBusyAndOtherSignInsWait() = runBlocking {
        val repository = started()
        val chosen = CompletableDeferred<GoogleCredential>()
        val signIn = launch(Dispatchers.Unconfined) { repository.signInWithGoogle { _, _ -> chosen.await() } }
        repository.awaitState<AuthState.Login> { it.googleBusy }
        repository.sendCode("alice@example.test")
        repository.signInWithGoogle(source(token))
        assertEquals(0, core.calls.count { it.first == "session.email.request" })
        assertEquals(1, core.calls.count { it.first == "session.google.desktop" })
        chosen.complete(GoogleCredential.Cancelled)
        signIn.join()
        assertTrue(!repository.awaitState<AuthState.Login> { !it.googleBusy }.googleBusy)
    }
}
