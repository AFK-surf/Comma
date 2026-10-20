package surf.comma.android.auth

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.withContext
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.GoogleIdTokens
import surf.comma.android.core.SessionLease
import surf.comma.android.core.TopicValue
import surf.comma.android.voice.VoiceKeyStore
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

/**
 * The client core's session, as far as the app's own code reads it, for tests of that code. [store] stands for the
 * credential the app keeps: with a session in it the core says signed in, otherwise signed out. The sign-in and
 * sign-out calls change it as the core's lifecycle would, and the account's workspace resolves to `w-<user>`,
 * `g-<user>` and `chat-<user>`. The session lifecycle itself is the core's and is tested there.
 */
internal class TestSessionCore(
    private val store: MemorySessions,
    private val nowMillis: () -> Long = { 1_800_000_000_000L },
) : CoreApi, SessionBearers {
    val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
    /** Answers a call before the default does; null lets the default answer. */
    @Volatile var answer: suspend (name: String, params: JSONObject) -> Any? = { _, _ -> null }
    /** The lifecycle phase said instead of the one [store] implies (e.g. `initializing`, `indeterminate`). */
    @Volatile var phase: String? = null
    @Volatile var problem: String = "session_probe_unavailable"
    /** The account whose kept data the core shows before the session is confirmed. */
    @Volatile var kept: String? = null
    @Volatile var google: GoogleIdTokens? = null
    /**
     * The core's `workspaceChat` instead of the signed-in (or [kept]) account's ready chat: `w-<user>`, `g-<user>`,
     * `chat-<user>`.
     */
    @Volatile var workspaceChat: ((user: String?) -> JSONObject)? = null
    /** Who a sign-in through the core signs in. */
    @Volatile var user: String = USER
    private val host = Executors.newSingleThreadExecutor { Thread(it, "test-core-host").apply { isDaemon = true } }
        .asCoroutineDispatcher()
    private val ticks = MutableStateFlow(0)
    @Volatile private var generation = 1L
    @Volatile private var attempt: JSONObject? = null

    /** Says the session again: after [store], [phase] or [kept] changed outside a call. */
    fun changed() {
        generation++
        ticks.value++
    }

    private fun header() = JSONObject()
        .put("authority", JSONObject().put("authorityInstanceId", AUTHORITY).put("kind", "android_keystore"))
        .put("cleanup", JSONObject().put("revocation", "idle")).put("contractVersion", 1)
        .put("generation", generation).put("revision", ticks.value)

    private fun value(): JSONObject {
        val saved = store.value
        val said = phase ?: if (saved != null) "signed_in" else "signed_out"
        val lifecycle = header().put("phase", said)
        val out = JSONObject().put("lifecycle", lifecycle).put("attempt", attempt ?: JSONObject.NULL)
        when (said) {
            "signed_in" -> {
                saved!!
                lifecycle.put("principal", JSONObject().put("userId", saved.user.id).put("email", saved.user.email))
                    .put("session", JSONObject().put("audience", AUDIENCE).put("sessionId", saved.sessionId)
                        .put("expiresAtEpochSeconds", saved.expiresAt))
                out.put("phase", "signed_in").put("userId", saved.user.id).put("audience", AUDIENCE).put("sessionId", saved.sessionId)
            }
            "signed_out" -> {
                lifecycle.put("principal", JSONObject.NULL).put("session", JSONObject.NULL).put("reason", "no_session")
                out.put("phase", "signed_out")
            }
            else -> {
                lifecycle.put("principal", JSONObject.NULL).put("session", JSONObject.NULL)
                if (said == "indeterminate") lifecycle.put("problem", JSONObject().put("code", problem))
                val shown = kept
                if (shown != null) out.put("phase", "signed_in").put("userId", shown) else out.put("phase", "unknown")
            }
        }
        return out
    }

    private fun ok(value: JSONObject = JSONObject()) = JSONObject().put("ok", true).put("value", value)
    fun failure(code: String, retryAfterMs: Long? = null): JSONObject = JSONObject().put("ok", false)
        .put("error", JSONObject().put("code", code).apply { retryAfterMs?.let { put("retryAfterMs", it) } })

    /**
     * The answer of a Google sign-in whose account exists without a Google link: an emailed code confirms it. The
     * session then shows the attempt with its `google_link` challenge.
     */
    fun linkChallenge(email: String, challengeId: String, expected: JSONObject): JSONObject {
        val ref = JSONObject().put("attemptId", "attempt-google").put("expected", expected)
        attempt = JSONObject().put("ref", ref).put("method", "google").put("challenge", JSONObject()
            .put("challengeId", challengeId).put("purpose", "google_link").put("email", email))
        ticks.value++
        return ok(JSONObject().put("status", "otp_required").put("attempt", ref).put("challengeId", challengeId).put("email", email))
    }

    private fun signIn(user: String) {
        store.value = Session(SessionToken("secret-$user"), nowMillis() / 1000 + 3600, "session-$user",
            Account(user, "$user@example.test", null, "active"))
        attempt = null
        phase = null
        changed()
    }

    override suspend fun call(name: String, params: JSONObject): Any? {
        calls += name to params
        answer(name, params)?.let { return it }
        return when (name) {
            "session.email.request" -> {
                val ref = JSONObject().put("attemptId", "attempt-1").put("expected", params.getJSONObject("expected"))
                attempt = JSONObject().put("ref", ref).put("method", "email").put("challenge", JSONObject()
                    .put("challengeId", "challenge-1").put("purpose", "email_login").put("email", params.getString("email")))
                ticks.value++
                ok(JSONObject().put("attempt", ref).put("challengeId", "challenge-1"))
            }
            "session.email.verify", "session.google.linkVerify" -> {
                signIn(user)
                ok()
            }
            "session.google.desktop" -> {
                // The core asks the host for the token on one of the host's threads, which waits for the chooser.
                val token = withContext(host) { google?.request("client-id", "nonce") }
                if (token == null) failure("unknown") else {
                    signIn(user)
                    ok(JSONObject().put("status", "signed_in"))
                }
            }
            "session.cancelAuth" -> {
                attempt = null
                ticks.value++
                ok()
            }
            "session.signOut" -> {
                store.value = null
                kept = null
                phase = null
                attempt = null
                changed()
                ok()
            }
            "workspaceChat.retry" -> {
                ticks.value++
                null
            }
            else -> null
        }
    }

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = when (topic.getString("topic")) {
        "session" -> ticks.map { TopicValue.Value(read(value())) }
        "workspaceChat" -> ticks.map { TopicValue.Value(read(chatValue())) }
        "workspace" -> flowOf(TopicValue.Value(read(JSONObject().put("status", "ready").put("workspace", JSONObject()
            .put("id", topic.optString("prefer")).put("groupId", "g").put("name", "W")))))
        else -> emptyFlow()
    }

    override fun savedAccount(): Account? = store.value?.user

    private fun chatValue(): JSONObject {
        val user = store.value?.user?.id?.takeIf { phase == null } ?: kept
        workspaceChat?.let { return it(user) }
        if (user == null) return JSONObject().put("status", "loading").put("chat", JSONObject.NULL).put("kept", false)
        return JSONObject().put("status", "ready").put("kept", phase != null).put("chat", JSONObject()
            .put("workspaceId", "w-$user").put("groupId", "g-$user").put("conversationId", "chat-$user"))
    }

    override fun lease(): SessionLease? {
        val saved = store.value?.takeIf { phase == null } ?: return null
        return SessionLease(AUDIENCE, AUTHORITY, generation, saved.sessionId)
    }

    companion object {
        const val USER = "alice"
        const val AUDIENCE = "https://comma.test"
        const val AUTHORITY = "authority-1"
    }
}

/**
 * An [AuthRepository] on a [TestSessionCore] over [store]. [core] gives the test the core it runs on.
 */
internal fun TestAuthRepository(
    store: MemorySessions,
    nowMillis: () -> Long = { 1_800_000_000_000L },
    io: CoroutineDispatcher = Dispatchers.Unconfined,
    voiceKeyStore: VoiceKeyStore? = null,
    core: TestSessionCore = TestSessionCore(store, nowMillis),
): AuthRepository {
    val google = GoogleChooser()
    core.google = google
    return AuthRepository(core, core, google, CoroutineScope(SupervisorJob() + io), nowMillis, io,
        voiceKeyStore = voiceKeyStore)
}

/** Waits for the state the repository reaches once the core's session and the workspace's chat settled. */
internal suspend inline fun <reified T : AuthState> AuthRepository.awaitState(crossinline matches: (T) -> Boolean = { true }): T =
    state.first { it is T && matches(it) } as T
