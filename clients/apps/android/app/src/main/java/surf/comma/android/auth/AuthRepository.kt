package surf.comma.android.auth

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.SessionLease
import surf.comma.android.core.TopicValue
import surf.comma.android.ui.Background
import surf.comma.android.voice.VoiceAccess
import surf.comma.android.voice.VoiceCredentials
import surf.comma.android.voice.VoiceKeyCredentials
import surf.comma.android.voice.VoiceKeyStore

/**
 * What the session needs of the app's credential custody (the core module's `SessionCustody`): who the kept credential
 * belongs to, and the lease open now, which the core's calls that make credentials name.
 */
internal interface SessionBearers {
    /** Whose credential is kept, known before the server confirms its session and offline. */
    fun savedAccount(): Account?
    /** The lease open now, or null while the core gives none. */
    fun lease(): SessionLease?
}

/**
 * The account's session as the app's screens see it. The client core runs the session lifecycle (sign-in, the check
 * of a kept credential, sign-out, revocation) and is its authority: this class turns the core's `session` topic into
 * [state] and forwards what the person does to the core's `session.*` calls. The account's chat with Comma is the
 * core's `workspaceChat` topic, as on the desktop: the core resolves it, waits out a workspace being made and shows the
 * chat it found before until the server confirms it.
 *
 * The bearer stays in the app's custody, and only the core's requests carry it: nothing here sees it.
 */
class AuthRepository internal constructor(
    private val core: CoreApi?,
    private val bearers: SessionBearers,
    private val google: GoogleChooser,
    private val scope: CoroutineScope,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Background.files,
    private val voiceKeyStore: VoiceKeyStore? = null,
) {
    /** A sign-in under way in the core: its ref fences every call that continues it. */
    private data class Attempt(
        val ref: String,
        val challengeId: String?,
        val linkingGoogle: Boolean,
        val email: String?,
        val resendInSeconds: Long?,
    )

    /** The core's `session` topic, as much of it as the app reads. */
    private data class CoreSession(
        val phase: String,
        val authority: String,
        val generation: Long,
        val user: Account?,
        val sessionId: String?,
        val audience: String?,
        val expiresAt: Long,
        /** The account whose kept data the core shows: the confirmed one, or the stored credential's. */
        val shownUserId: String?,
        val problem: String?,
        val attempt: Attempt?,
        val cooldownEmail: String?,
        val cooldownSeconds: Long,
    )

    /** The core's `workspaceChat` topic: the account's chat with Comma, the one kept on the device until confirmed. */
    private data class MainChat(
        val status: String,
        val workspaceId: String?,
        val groupId: String?,
        val conversationId: String?,
        /** Provisioning: when the core asks again. */
        val retryAtMillis: Long,
    ) {
        /** The chat to show: resolved, or kept and not refused. */
        val shown: Boolean get() = conversationId != null && (status == "ready" || status == "error")
    }

    /** What the sign-in page holds besides the core's attempt. */
    private data class Form(
        val email: String = "",
        val busy: Boolean = false,
        val problem: AuthProblem? = null,
        val googleBusy: Boolean = false,
        val googleProblem: AuthProblem? = null,
        val resendAtMillis: Long = 0,
        val verifyAtMillis: Long = 0,
    )

    private val lock = Any()
    private var session: CoreSession? = null
    private var form = Form()
    private var mainChat: MainChat? = null
    /** Workspace names by id, as the core's `workspace` topic says them. */
    private val workspaceNames = HashMap<String, String>()
    private var naming: Job? = null
    private var started = false
    private var scopeGeneration = 0L
    private val mutableState = MutableStateFlow<AuthState>(AuthState.Starting)
    val state = mutableState.asStateFlow()

    /**
     * Who the kept credential belongs to, known before (and while) the session is checked, so the account can be
     * shown by name while offline. Null once signed out.
     */
    val savedAccount: Account? get() = synchronized(lock) { session?.user } ?: runCatching { bearers.savedAccount() }.getOrNull()

    private val mutableScope = MutableStateFlow<ConversationScope?>(null)
    /**
     * The main chat of the account in view, or null. Set as soon as a kept credential with a cached workspace is
     * found, so the chat can show its local copy while the session is checked; confirmed (or replaced) once
     * connected; null as soon as the account goes.
     */
    val conversationScope: StateFlow<ConversationScope?> = mutableScope.asStateFlow()

    private val voiceProvider = lazy {
        VoiceKeyCredentials(checkNotNull(core) { "No client core" }, checkNotNull(voiceKeyStore) { "Voice storage unavailable" },
            access = { synchronized(lock) {
                val current = session?.takeIf { it.phase == "signed_in" }
                val workspace = mainChat?.takeIf { it.shown }?.workspaceId
                if (current?.user == null || current.sessionId == null || workspace == null) null
                else VoiceAccess(current.user.id, current.sessionId, workspace)
            } }, nowMillis = nowMillis)
    }
    val voiceCredentials: VoiceCredentials get() = voiceProvider.value

    /**
     * Whether the current workspace can take voice calls, from its voice integration status (the core's `voice`
     * topic), or null when that is not known (signed out, offline, or the read failed). It never touches a voice
     * credential: the voice service's own readiness address may come to spend a one-time call ticket.
     */
    suspend fun voiceReady(): Boolean? = withContext(io) {
        val running = core ?: return@withContext null
        val workspace = synchronized(lock) { mainChat?.takeIf { it.shown }?.workspaceId } ?: return@withContext null
        withTimeoutOrNull(VOICE_READY_MILLIS) {
            running.subscribe(JSONObject().put("topic", "voice").put("prefer", workspace)) { it as? JSONObject }.first { value ->
                value is TopicValue.Failed || (value as TopicValue.Value).value?.let { json ->
                    json.optString("workspace") == workspace && (json.optBoolean("integrationError") || !json.isNull("integration"))
                } == true
            }
        }?.let { value -> (value as? TopicValue.Value)?.value?.optJSONObject("integration")?.let(::voiceReadiness) }
    }

    /** The lease of the session open now, for the core's calls that name it; null while none is. */
    fun productLease(): JSONObject? = bearers.lease()?.toJson()

    fun isCurrentGeneration(generation: Long): Boolean = mutableScope.value?.generation == generation

    /** Starts following the core's session. Safe to call again. */
    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun start() = withContext(io) {
        synchronized(lock) {
            if (started) return@withContext
            started = true
            if (core == null) {
                mutableState.value = AuthState.Unconfigured
                return@withContext
            }
            render()
        }
        val running = core ?: return@withContext
        scope.launch {
            running.subscribe(JSONObject().put("topic", "session"), ::readSession).collect { value ->
                if (value is TopicValue.Value) observe(value.value)
            }
        }
        // While the app shows the connection's recovery, the core finds the session out again by itself.
        scope.launch { running.subscribe(JSONObject().put("topic", "sessionRecovery")) { }.collect { } }
        scope.launch {
            // The chat of the workspace chosen with [switchWorkspace]; with none chosen, the account's default one.
            running.subscribe(JSONObject().put("topic", "workspace")) { value ->
                val json = value as? JSONObject
                val status = json?.optString("status")
                // A failed list read (offline at cold start) names no workspace even when one is chosen: like loading,
                // it keeps the chat last read rather than falling back to the default workspace's. With none chosen
                // the default one is right either way.
                if (json == null || status == "loading" || (status == "error" && json.optBoolean("selected"))) null
                else json.optJSONObject("workspace")?.takeIf { json.optBoolean("selected") }?.optString("id").orEmpty()
            }.mapNotNull { (it as? TopicValue.Value)?.value }.distinctUntilChanged().flatMapLatest { selected ->
                val topic = JSONObject().put("topic", "workspaceChat")
                if (selected.isNotEmpty()) topic.put("workspace", selected)
                running.subscribe(topic, ::readMainChat)
            }.collect { value ->
                if (value is TopicValue.Value) synchronized(lock) {
                    mainChat = value.value
                    session?.let(::showScope)
                    render()
                }
            }
        }
    }

    private fun readSession(value: Any?): CoreSession {
        val json = value as? JSONObject ?: JSONObject()
        val lifecycle = json.optJSONObject("lifecycle")
        val principal = lifecycle?.optJSONObject("principal")
        val descriptor = lifecycle?.optJSONObject("session")
        val attempt = json.optJSONObject("attempt")
        val challenge = attempt?.optJSONObject("challenge")?.takeUnless { it.optBoolean("expired") }
        val cooldown = json.optJSONObject("emailCooldown")
        return CoreSession(
            phase = lifecycle?.optString("phase")?.takeIf { it.isNotEmpty() } ?: "initializing",
            authority = lifecycle?.optJSONObject("authority")?.optString("authorityInstanceId").orEmpty(),
            generation = lifecycle?.optLong("generation") ?: 0,
            user = principal?.let {
                Account(it.optString("userId"), it.optString("email"), it.optString("displayName").takeIf(String::isNotEmpty), "active")
            },
            sessionId = descriptor?.optString("sessionId")?.takeIf { it.isNotEmpty() },
            audience = descriptor?.optString("audience")?.takeIf { it.isNotEmpty() },
            expiresAt = descriptor?.optLong("expiresAtEpochSeconds") ?: 0,
            shownUserId = json.optString("userId").takeIf { json.optString("phase") == "signed_in" && it.isNotEmpty() },
            problem = lifecycle?.optJSONObject("problem")?.optString("code"),
            attempt = attempt?.optJSONObject("ref")?.let { ref ->
                Attempt(ref.toString(), challenge?.optString("challengeId")?.takeIf { it.isNotEmpty() },
                    challenge?.optString("purpose") == "google_link", challenge?.optString("email")?.takeIf { it.isNotEmpty() },
                    challenge?.takeIf { it.has("resendInSeconds") }?.optLong("resendInSeconds"))
            },
            cooldownEmail = cooldown?.optString("email"),
            cooldownSeconds = cooldown?.optLong("seconds") ?: 0,
        )
    }

    private fun readMainChat(value: Any?): MainChat? {
        val json = value as? JSONObject ?: return null
        val chat = json.optJSONObject("chat")
        val provisioning = json.optJSONObject("provisioning")
        return MainChat(
            status = json.optString("status"),
            workspaceId = chat?.optString("workspaceId")?.takeIf { it.isNotEmpty() },
            groupId = chat?.optString("groupId")?.takeIf { it.isNotEmpty() },
            conversationId = chat?.optString("conversationId")?.takeIf { it.isNotEmpty() },
            retryAtMillis = provisioning?.let { deadline(it.optLong("retryAfterSeconds", 1)) } ?: 0,
        )
    }

    private fun observe(next: CoreSession) {
        synchronized(lock) {
            val previous = session
            session = next
            // Seconds the core counts down become a deadline here once, when they first show.
            if (next.attempt?.resendInSeconds != null && next.attempt != previous?.attempt)
                form = form.copy(resendAtMillis = deadline(next.attempt.resendInSeconds))
            if (next.cooldownSeconds > 0 && next.cooldownSeconds != previous?.cooldownSeconds)
                form = form.copy(resendAtMillis = maxOf(form.resendAtMillis, deadline(next.cooldownSeconds)))
            if (next.phase == "signed_out" && previous?.phase != "signed_out" && previous?.phase != "authenticating") {
                // The account went, or there is none: nothing of an account stays on this device.
                signedOutLocked()
            }
            // A new sign-in starts with a clean sign-in page for the next time.
            if (next.phase == "signed_in" && previous?.phase != "signed_in") form = Form()
            showScope(next)
            render()
        }
    }

    /** The main chat to show for [current]: the one the core shows, kept or confirmed. */
    private fun showScope(current: CoreSession) {
        val userId = current.shownUserId ?: current.user?.id
        val chat = mainChat?.takeIf { it.shown }
        if (userId == null || chat == null) {
            if (mutableScope.value != null) scopeGeneration++
            mutableScope.value = null
            return
        }
        val shown = mutableScope.value
        // Keep the early scope when the server confirms it, so the chat is not rebuilt.
        if (shown == null || shown.accountId != userId || shown.groupId != chat.groupId ||
            shown.conversationId != chat.conversationId) {
            mutableScope.value = ConversationScope(++scopeGeneration, userId, chat.groupId!!, chat.conversationId!!, chat.workspaceId!!)
        }
        name(chat.workspaceId!!)
    }

    /** Learns the name of the workspace shown, once. */
    private fun name(workspaceId: String) {
        val running = core ?: return
        if (workspaceId in workspaceNames || naming?.isActive == true) return
        naming = scope.launch {
            val name = workspaceName(running, workspaceId)
            synchronized(lock) {
                workspaceNames[workspaceId] = name
                render()
            }
        }
    }

    private fun signedOutLocked() {
        naming?.cancel()
        workspaceNames.clear()
        form = Form(resendAtMillis = form.resendAtMillis)
        runCatching { voiceKeyStore?.clear() }
    }

    private fun render() {
        val current = session
        val saved = current?.user ?: runCatching { bearers.savedAccount() }.getOrNull()
        mutableState.value = when {
            current == null || current.phase == "initializing" ->
                if (saved != null) AuthState.Connecting(ConnectionStep.SESSION) else AuthState.Starting
            current.phase == "signed_in" -> {
                val chat = mainChat
                when {
                    chat != null && chat.shown -> AuthState.Connected(current.user ?: saved!!, WorkspaceSelection(
                        Workspace(chat.workspaceId!!, chat.groupId!!, workspaceNames[chat.workspaceId].orEmpty()),
                        chat.conversationId!!))
                    chat?.status == "provisioning" -> AuthState.Connecting(ConnectionStep.PROVISIONING, chat.retryAtMillis)
                    chat?.status == "hidden" -> AuthState.Retry(AuthProblem.NO_WORKSPACE)
                    chat?.status == "error" -> AuthState.Retry(AuthProblem.NETWORK)
                    else -> AuthState.Connecting(ConnectionStep.WORKSPACE)
                }
            }
            current.phase == "indeterminate" -> AuthState.Retry(when (current.problem) {
                "session_probe_unavailable" -> AuthProblem.NETWORK
                "credential_store_unavailable", "credential_store_unreadable", "credential_mutation_uncertain" -> AuthProblem.STORAGE
                else -> AuthProblem.SERVER
            })
            current.phase == "signing_out" || current.phase == "invalidating" -> AuthState.Login(busy = true)
            else -> AuthState.Login(
                email = current.attempt?.email ?: form.email,
                challengeId = current.attempt?.challengeId,
                resendAtMillis = form.resendAtMillis,
                verifyAtMillis = form.verifyAtMillis,
                busy = form.busy,
                problem = form.problem,
                googleBusy = form.googleBusy,
                googleProblem = form.googleProblem,
                linkingGoogle = current.attempt?.linkingGoogle == true,
            )
        }
    }

    // --- The workspace's name ---------------------------------------------------------------------------------

    private suspend fun workspaceName(running: CoreApi, workspaceId: String): String = withTimeoutOrNull(WORKSPACE_NAME_MILLIS) {
        running.subscribe(JSONObject().put("topic", "workspace").put("prefer", workspaceId)) { value ->
            val json = value as? JSONObject
            json?.optJSONObject("workspace")?.takeIf { it.optString("id") == workspaceId }?.optString("name")
                ?: "".takeIf { json?.optString("status") == "error" }
        }.first { it is TopicValue.Failed || (it as TopicValue.Value).value != null }
            .let { (it as? TopicValue.Value)?.value }
    }.orEmpty()

    // --- What the person does --------------------------------------------------------------------------------

    /**
     * Makes [workspaceId] the workspace the app works in, on this device until sign-out. The main chat and
     * everything that follows the conversation scope move to that workspace's chat once the core resolves it.
     * False when the core refused or could not be reached, so the caller can say the switch did not happen.
     */
    suspend fun switchWorkspace(workspaceId: String): Boolean = withContext(io) {
        val running = core ?: return@withContext false
        runCatching { running.call("workspace.select", JSONObject().put("workspace", workspaceId)) }
            .onFailure { if (it is CancellationException) throw it }
            .isSuccess
    }

    suspend fun retry() = withContext(io) {
        val chat = synchronized(lock) {
            if (mutableState.value !is AuthState.Retry) return@withContext
            val signedIn = session?.phase == "signed_in"
            mutableState.value = AuthState.Connecting(if (signedIn) ConnectionStep.WORKSPACE else ConnectionStep.SESSION)
            signedIn
        }
        runCatching { core?.call(if (chat) "workspaceChat.retry" else "session.recover") }
        synchronized(lock) { render() }
    }

    suspend fun sendCode(email: String) = withContext(io) {
        val expected = synchronized(lock) {
            val login = mutableState.value as? AuthState.Login ?: return@withContext
            // A Google link code cannot be resent; the person starts the Google sign-in again instead.
            if (login.busy || login.googleBusy || login.linkingGoogle || nowMillis() < login.resendAtMillis) return@withContext
            form = form.copy(email = email.trim(), busy = true, problem = null)
            render()
            absence() ?: return@withContext idle(AuthProblem.SERVER)
        }
        val result = operation("session.email.request", JSONObject().put("email", email.trim()).put("expected", expected))
        synchronized(lock) {
            val error = result.error
            form = when {
                error == null -> form.copy(busy = false, problem = null,
                    resendAtMillis = deadline(result.value?.takeIf { it.has("resendAfterSeconds") }?.optLong("resendAfterSeconds") ?: 60))
                else -> form.copy(busy = false, problem = problem(error),
                    resendAtMillis = if (error.code == "rate_limited" || error.code == "provider_unavailable")
                        deadline(error.retryAfterSeconds ?: 60) else form.resendAtMillis)
            }
            render()
        }
    }

    suspend fun verify(code: String) = withContext(io) {
        val attempt = synchronized(lock) {
            val login = mutableState.value as? AuthState.Login ?: return@withContext
            val attempt = session?.attempt
            if (login.busy || attempt?.challengeId == null || code.length != 6 || code.any { it !in '0'..'9' } ||
                nowMillis() < login.verifyAtMillis) return@withContext
            form = form.copy(busy = true, problem = null)
            render()
            attempt
        }
        val result = operation(
            if (attempt.linkingGoogle) "session.google.linkVerify" else "session.email.verify",
            JSONObject().put("attempt", JSONObject(attempt.ref)).put("challengeId", attempt.challengeId).put("code", code))
        synchronized(lock) {
            val error = result.error
            form = if (error == null) form.copy(busy = false, problem = null) else form.copy(busy = false,
                problem = when {
                    error.code == "invalid_challenge" || error.code == "challenge_expired" -> AuthProblem.INVALID_CODE
                    attempt.linkingGoogle && error.code == "conflict" -> AuthProblem.GOOGLE_CONFLICT
                    else -> problem(error)
                },
                verifyAtMillis = if (error.code == "rate_limited") deadline(error.retryAfterSeconds ?: 60) else 0)
            render()
        }
    }

    /**
     * Signs in with a Google ID token from [source]. The core starts a one-time attempt, asks the app for a token
     * bound to its nonce (the account chooser), and exchanges it; the attempt id, nonce and token live only in that
     * call. An existing account that has not linked Google yet gets an email code first
     * ([AuthState.Login.linkingGoogle]).
     */
    suspend fun signInWithGoogle(source: GoogleCredentialSource) = withContext(io) {
        val expected = synchronized(lock) {
            val login = mutableState.value as? AuthState.Login ?: return@withContext
            if (login.busy || login.googleBusy || login.challengeId != null) return@withContext
            form = form.copy(googleBusy = true, googleProblem = null, problem = null)
            render()
            absence() ?: return@withContext synchronized(lock) {
                form = form.copy(googleBusy = false, googleProblem = AuthProblem.SERVER)
                render()
            }
        }
        val chosen = google.during(source) {
            operation("session.google.desktop", JSONObject().put("expected", expected))
        }
        synchronized(lock) {
            val error = chosen.result.error
            form = form.copy(googleBusy = false, googleProblem = when {
                error == null -> null
                // Closing the chooser is not an error: back to the sign-in page as it was.
                chosen.outcome == GoogleCredential.Cancelled -> null
                chosen.outcome == GoogleCredential.NoAccount -> AuthProblem.GOOGLE_NO_ACCOUNT
                chosen.outcome == GoogleCredential.Unavailable -> AuthProblem.GOOGLE_UNAVAILABLE
                chosen.outcome == GoogleCredential.Failed -> AuthProblem.GOOGLE_REJECTED
                else -> when (error.code) {
                    // The backend has no Google sign-in for Android (it names no time to try again), or it is down.
                    "unsupported" -> AuthProblem.GOOGLE_NOT_CONFIGURED
                    "provider_unavailable" -> if (error.retryAfterSeconds == null) AuthProblem.GOOGLE_NOT_CONFIGURED
                        else AuthProblem.EMAIL_UNAVAILABLE
                    "invalid_challenge", "challenge_expired", "unknown" -> AuthProblem.GOOGLE_REJECTED
                    "account_disabled" -> AuthProblem.ACCOUNT_DISABLED
                    "conflict" -> AuthProblem.GOOGLE_CONFLICT
                    // The Google button has no countdown of its own, so a rate limit reads as "try again later".
                    "rate_limited" -> AuthProblem.EMAIL_UNAVAILABLE
                    else -> problem(error)
                }
            })
            render()
        }
    }

    suspend fun changeEmail() = withContext(io) {
        val attempt = synchronized(lock) {
            if (mutableState.value !is AuthState.Login) return@withContext
            // Preserve the server's cooldown even when abandoning a challenge.
            form = Form(resendAtMillis = form.resendAtMillis)
            render()
            session?.attempt
        }
        if (attempt != null) operation("session.cancelAuth", JSONObject().put("attempt", JSONObject(attempt.ref)))
    }

    suspend fun logout() = withContext(io) {
        val expected = synchronized(lock) {
            val current = session ?: return@withContext
            when (current.phase) {
                "signed_in" -> JSONObject().put("authorityInstanceId", current.authority).put("generation", current.generation)
                    .put("expectedAudience", current.audience).put("expectedSessionId", current.sessionId)
                else -> JSONObject().put("authorityInstanceId", current.authority).put("generation", current.generation)
                    .put("expectedSessionId", JSONObject.NULL)
            }
        }
        // The person asked: the app's own requests stop carrying the credential now, before the core answers.
        synchronized(lock) {
            if (mutableScope.value != null) scopeGeneration++
            mutableScope.value = null
        }
        // This phone's voice key goes with the session that made it, while that session can still delete it.
        if (core != null && voiceKeyStore != null) withTimeoutOrNull(VOICE_RETIRE_MILLIS) { voiceProvider.value.retire() }
        val result = operation("session.signOut", JSONObject().put("expected", expected))
        if (result.error != null) synchronized(lock) {
            // The core kept the session: the chat comes back.
            session?.let(::showScope)
            render()
        }
    }

    /** The app came back to the front: the core checks the session again. */
    suspend fun checkExpiry() = withContext(io) {
        val signedIn = synchronized(lock) { session?.phase == "signed_in" }
        if (signedIn) runCatching { core?.call("session.reconcile", JSONObject().put("reason", "focus")) }
    }

    // --- Helpers ---------------------------------------------------------------------------------------------

    private class OperationError(val code: String, val retryAfterSeconds: Long?)
    private class OperationResult(val value: JSONObject?, val error: OperationError?)

    /** One of the core's session operations: its value, or the session contract's error. */
    private suspend fun operation(name: String, params: JSONObject): OperationResult = try {
        val answer = core?.call(name, params) as? JSONObject
        when {
            answer == null -> OperationResult(null, null)
            answer.optBoolean("ok") -> OperationResult(answer.optJSONObject("value"), null)
            else -> answer.optJSONObject("error").let { error ->
                OperationResult(null, OperationError(error?.optString("code") ?: "unknown",
                    error?.takeIf { it.has("retryAfterMs") }?.let { (it.optLong("retryAfterMs") + 999) / 1000 }))
            }
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: CoreError) {
        OperationResult(null, OperationError(if (e.code == "core_restarted") "network_unavailable" else "unknown", null))
    }

    /** What a sign-in expects of the session: nobody signed in, at this authority's generation. */
    private fun absence(): JSONObject? = session?.takeIf { it.authority.isNotEmpty() }?.let {
        JSONObject().put("authorityInstanceId", it.authority).put("generation", it.generation).put("expectedSessionId", JSONObject.NULL)
    }

    private fun idle(problem: AuthProblem) = synchronized(lock) {
        form = form.copy(busy = false, problem = problem)
        render()
    }

    private fun deadline(seconds: Long) = nowMillis() + seconds * 1000

    private fun problem(error: OperationError): AuthProblem = when (error.code) {
        "rate_limited" -> AuthProblem.RATE_LIMITED
        "provider_unavailable" -> AuthProblem.EMAIL_UNAVAILABLE
        "network_unavailable", "session_probe_unavailable" -> AuthProblem.NETWORK
        "account_disabled" -> AuthProblem.ACCOUNT_DISABLED
        "credential_store_unavailable", "credential_store_unreadable", "credential_mutation_uncertain" -> AuthProblem.STORAGE
        else -> AuthProblem.SERVER
    }

    private companion object {
        const val WORKSPACE_NAME_MILLIS = 5_000L
        const val VOICE_READY_MILLIS = 10_000L
        const val VOICE_RETIRE_MILLIS = 10_000L
    }
}

/**
 * In-app calls from the integration status. Its readiness also covers calling in by phone, so it
 * is false while the platform has no phone lines (or no telephony account) even though the voice
 * service itself is up: those two reasons do not stand in the way of a call from the app.
 */
internal fun voiceReadiness(status: JSONObject): Boolean {
    val readiness = status.optJSONObject("readiness") ?: return false
    if (readiness.optBoolean("ready", false)) return true
    return readiness.optString("reason") in PHONE_ONLY_REASONS
}

private val PHONE_ONLY_REASONS = setOf("twilio_not_configured", "no_platform_lines")
