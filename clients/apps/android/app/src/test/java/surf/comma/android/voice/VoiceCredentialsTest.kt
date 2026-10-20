package surf.comma.android.voice

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import surf.comma.android.auth.*
import surf.comma.android.core.CoreError
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.KeyGenerator

/**
 * This phone's voice key: made and deleted through the client core (`voice.createKey`, `voice.deleteKey`), kept
 * encrypted here, and used against the voice service the server names ([voice], a local server).
 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class VoiceCredentialsTest {
    @get:Rule val temporary = TemporaryFolder()
    private val voice = MemoryVoiceServer()
    private val scheduler = TestCoroutineScheduler()
    private var now = 1_800_000_000_000L
    private val aes = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private lateinit var keyFile: File
    private lateinit var keys: EncryptedVoiceKeyStore
    private val sessions = MemorySessions()
    private val core = TestSessionCore(sessions) { now }
    private val saved = Session(SessionToken("private-login-credential"), now / 1000 + 90 * 86_400,
        "login-session", Account("alice", "alice@example.test", null, "active"))

    /** What `voice.createKey` was asked, and the keys `voice.deleteKey` deleted. */
    private val created = CopyOnWriteArrayList<JSONObject>()
    private val deleted = CopyOnWriteArrayList<String>()
    /** The next keys made, in order; none left: the server refuses. */
    private val minted = ArrayDeque<JSONObject>()
    /** Holds the next key being made until the test completes it. */
    @Volatile private var mintGate: CompletableDeferred<Unit>? = null
    @Volatile private var deleteRefused = false

    private fun repository() =
        TestAuthRepository(sessions, nowMillis = { now }, io = Dispatchers.Unconfined, voiceKeyStore = keys, core = core)

    /** A call against [voice] on [scheduler]'s clock. */
    private fun call(credentials: VoiceCredentials) = VoiceSession(credentials, object : PlaybackSink {
        override fun audio(pcm: ByteArray) = Unit
        override fun mark(name: String, onPlayed: () -> Unit) = Unit
        override fun clear() = Unit
    }, "1", null, OkHttpClient(), CoroutineScope(StandardTestDispatcher(scheduler)), voice.calls, voice.sockets,
        { scheduler.currentTime * 1_000_000 })

    /** Runs what is due and what the network has for the call, until neither has more. */
    private fun settle() {
        do scheduler.runCurrent() while (voice.deliver())
    }

    @Before fun before() {
        keyFile = File(temporary.root, "voice.bin")
        keys = EncryptedVoiceKeyStore(keyFile, SessionCipher("comma.voice-key.v1") { aes })
        core.answer = { name, params ->
            when (name) {
                "voice.createKey" -> {
                    created += params
                    mintGate?.await()
                    synchronized(minted) { minted.removeFirstOrNull() } ?: throw CoreError("voice_unavailable", "refused", 503)
                }
                "voice.deleteKey" -> {
                    if (deleteRefused) throw CoreError("network", "offline")
                    deleted += params.getString("key")
                    JSONObject()
                }
                else -> null
            }
        }
    }


    private suspend fun signIn(): AuthRepository {
        sessions.value = saved
        return repository().also { it.start(); it.awaitState<AuthState.Connected>() }
    }

    private fun issued(id: String = "key-one", key: String = "private-voice-key", expiry: Long = now / 1000 + VoiceKeyCredentials.LIFETIME_SECONDS) =
        JSONObject().put("key_id", id).put("key", key).put("expires_at", expiry)
            .put("sessions_url", "wss://voice.test/server-selected/socket")
            .put("readiness_url", "https://voice.test/server-selected/ready")

    private fun mint(vararg answers: JSONObject) = synchronized(minted) { minted.addAll(answers) }

    @Test fun makesAThirtyDayKeyForTheWorkspaceAndReusesItEncryptedAcrossInstances() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued())
        val endpoint = repository.voiceCredentials.endpoint()
        val asked = created.single()
        assertEquals("w-alice", asked.getString("workspace"))
        assertTrue(asked.getString("name").isNotBlank())
        assertEquals(now / 1000 + 30 * 86_400, asked.getLong("expiresAt"))
        assertEquals("wss://voice.test/server-selected/socket", endpoint.sessionsUrl)
        assertEquals("https://voice.test/server-selected/ready", endpoint.readinessUrl)
        assertEquals("private-voice-key", endpoint.bearer)
        assertFalse(endpoint.toString().contains(endpoint.bearer))
        assertFalse(keys.read().toString().contains(endpoint.bearer))
        assertFalse(keyFile.readBytes().toString(Charsets.UTF_8).contains(endpoint.bearer))
        assertEquals(endpoint.bearer, repository.voiceCredentials.endpoint().bearer)
        val restarted = signIn()
        assertEquals(endpoint.bearer, restarted.voiceCredentials.endpoint().bearer)
        assertEquals(1, created.size)
    }

    @Test fun replacesTheKeyThreeDaysBeforeItEndsAndDeletesTheOldOne() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued())
        repository.voiceCredentials.endpoint()
        now += 27 * 86_400_000L - 1_000
        assertEquals("private-voice-key", repository.voiceCredentials.endpoint().bearer)
        assertEquals(1, created.size)
        now += 1_000
        mint(issued("key-two", "replacement-private-key"))
        assertEquals("replacement-private-key", repository.voiceCredentials.endpoint().bearer)
        assertEquals(listOf("key-one"), deleted)
        assertTrue(repository.state.value is AuthState.Connected)
        assertEquals("key-two", keys.read()!!.keyId)
    }

    @Test fun invalidationDeletesTheKeyAndTheNextCallMakesExactlyOneNew() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued(), issued("key-two", "private-two"))
        repository.voiceCredentials.endpoint()
        repository.voiceCredentials.invalidate()
        assertFalse(keyFile.exists())
        assertEquals(listOf("key-one"), deleted)
        assertEquals("private-two", repository.voiceCredentials.endpoint().bearer)
        assertEquals("private-two", repository.voiceCredentials.endpoint().bearer)
        assertEquals(2, created.size)
    }

    @Test fun signingOutDeletesTheKeyBeforeTheSessionEnds() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued())
        repository.voiceCredentials.endpoint()
        repository.logout()
        repository.awaitState<AuthState.Login>()
        assertEquals(listOf("key-one"), deleted)
        val order = core.calls.map { it.first }.filter { it == "voice.deleteKey" || it == "session.signOut" }
        assertEquals(listOf("voice.deleteKey", "session.signOut"), order)
        assertNull(sessions.value)
        assertNull(keys.read())
    }

    @Test fun offlineTheKeyIsForgottenHereAndTheSessionStillEnds() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued())
        repository.voiceCredentials.endpoint()
        deleteRefused = true
        repository.logout()
        repository.awaitState<AuthState.Login>()
        assertNull(sessions.value)
        assertNull(keys.read())
        assertFalse(keyFile.exists())
    }

    @Test fun malformedKeysAreNotKeptAndAreDeletedWithoutLeakingTheirSecret() = runBlocking<Unit> {
        val repository = signIn()
        mint(JSONObject().put("key", "private-secret-echo"))
        var failure = runCatching { repository.voiceCredentials.endpoint() }.exceptionOrNull()
        assertTrue(failure is VoiceFailure)
        assertFalse(failure.toString().contains("private-secret-echo"))
        assertNull(keys.read())
        mint(issued().put("key_id", "k").put("key", "private-secret-echo").put("expires_at", now / 1000 + 60)
            .put("sessions_url", "wss://invalid.example/socket?key=private-secret-echo"))
        failure = runCatching { repository.voiceCredentials.endpoint() }.exceptionOrNull()
        assertTrue(failure is VoiceFailure)
        assertFalse(failure.toString().contains("private-secret-echo"))
        assertNull(failure!!.cause)
        assertNull(keys.read())
        assertEquals(listOf("k"), deleted)
    }

    @Test fun concurrentRequestsMakeOnlyOneKey() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued(), issued("key-two", "private-two"))
        val release = CompletableDeferred<Unit>()
        mintGate = release
        // The first request is making the key when the second asks.
        val a = async(start = CoroutineStart.UNDISPATCHED) { repository.voiceCredentials.endpoint() }
        assertEquals(1, created.size)
        val b = async(start = CoroutineStart.UNDISPATCHED) { repository.voiceCredentials.endpoint() }
        release.complete(Unit)
        assertEquals(a.await().bearer, b.await().bearer)
        assertEquals(1, created.size)
    }

    @Test fun aRefusedKeyAtTheVoiceServiceIsReplacedOnce() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued(), issued("key-two", "private-two"))
        voice.reply(401, "{}")
        val peer = voice.upgrade()
        call(repository.voiceCredentials).use { call ->
            call.start()
            settle()
            assertEquals("session.start", peer.nextText().getString("type"))
            peer.send("""{"type":"session.started","call_id":"c","audio_format":"pcm16_24k","max_duration_s":3600}""")
            peer.pcm()
            settle()
            assertEquals(CallPhase.Connected, call.state.value.phase)
            assertEquals(listOf("Bearer private-voice-key", "Bearer private-two", "Bearer private-two"),
                voice.requests.map { it.header("Authorization") })
            assertEquals("key-two", keys.read()!!.keyId)
            assertEquals(2, created.size)
            assertEquals(listOf("key-one"), deleted)
            assertTrue(repository.state.value is AuthState.Connected)
        }
    }

    @Test fun aLateInvalidationAfterSigningOutCannotClearANewSessionsKey() = runBlocking<Unit> {
        val first = signIn()
        mint(issued())
        first.voiceCredentials.endpoint()
        first.logout()
        first.awaitState<AuthState.Login>()
        // A different sign-in owns the store now; the old provider no longer holds a key.
        val replacement = VoiceKeyRecord("bob", "another-session", "w-bob", "new-key", now / 1000 + 3600,
            VoiceEndpoint("wss://voice.test/socket", "https://voice.test/ready", "new-private"))
        keys.write(replacement)
        first.voiceCredentials.invalidate()
        assertEquals("new-key", keys.read()!!.keyId)
    }

    @Test fun theVoiceHostAndPathsTheServerNamesAreUsedUnchanged() = runBlocking<Unit> {
        val repository = signIn()
        val readinessUrl = "https://voice-2.test/different/voice-ready"
        val sessionsUrl = "wss://voice-2.test/different/voice-socket"
        mint(issued("returned-key-id", "private-issued").put("sessions_url", sessionsUrl).put("readiness_url", readinessUrl))
        voice.ready()
        voice.reply(409, "{}")
        val endpoint = repository.voiceCredentials.endpoint()
        assertEquals(sessionsUrl, endpoint.sessionsUrl)
        assertEquals(readinessUrl, endpoint.readinessUrl)
        call(repository.voiceCredentials).use { call ->
            call.start()
            settle()
            assertEquals(CallPhase.Failed, call.state.value.phase)
            assertEquals(CallResult.Busy, call.state.value.result)
            assertEquals(listOf("https://voice-2.test/different/voice-ready", "https://voice-2.test/different/voice-socket"),
                voice.requests.map { it.url.toString() })
            assertEquals(1, created.size)
        }
    }

    @Test fun aKeyBeingMadeWhenSigningOutIsDeletedBeforeTheSessionEnds() = runBlocking<Unit> {
        val repository = signIn()
        val release = CompletableDeferred<Unit>()
        mintGate = release
        mint(issued())
        val made = async(start = CoroutineStart.UNDISPATCHED) { runCatching { repository.voiceCredentials.endpoint() } }
        try {
            assertEquals(1, created.size)
            // Signing out waits for the key under way, then deletes it with the session that made it.
            val signingOut = async(start = CoroutineStart.UNDISPATCHED) { repository.logout() }
            assertTrue(signingOut.isActive)
            release.complete(Unit)
            signingOut.await()
            repository.awaitState<AuthState.Login>()
            made.await()
            assertNull(keys.read())
            assertEquals(listOf("key-one"), deleted)
            assertEquals(listOf("voice.deleteKey", "session.signOut"),
                core.calls.map { it.first }.filter { it == "voice.deleteKey" || it == "session.signOut" })
        } finally { release.complete(Unit) }
    }

    @Test fun aCorruptedKeyFileCannotRevealTheKeyOrBeReused() = runBlocking<Unit> {
        val repository = signIn()
        mint(issued())
        repository.voiceCredentials.endpoint()
        val bytes = keyFile.readBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        keyFile.writeBytes(bytes)
        val failure = runCatching { repository.voiceCredentials.endpoint() }.exceptionOrNull()
        assertTrue(failure is VoiceFailure)
        assertFalse(failure.toString().contains("private-voice-key"))
        repository.logout()
        repository.awaitState<AuthState.Login>()
        assertNull(sessions.value)
        assertFalse(keyFile.exists())
    }
}
