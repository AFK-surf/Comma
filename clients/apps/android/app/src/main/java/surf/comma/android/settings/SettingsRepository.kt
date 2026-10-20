package surf.comma.android.settings

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ConversationSessions
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import java.io.File

/**
 * Account settings for the signed-in session, as the client core keeps them: its `profile` topic (the name and avatar),
 * the Group's `taskLabels` (the label policy) and `accountSessions` (the signed-in devices). This class shows those
 * topics and forwards what the person does to the core's calls.
 *
 * The core shows a change at once and the saved value again if the server refuses it (it also sends the changes one at
 * a time); a refusal is said here with a [SettingsNotice]. Work belongs to one session generation: when the account
 * signs out or changes, its subscriptions and calls end.
 */
class SettingsRepository internal constructor(
    private val sessions: ConversationSessions,
    private val core: CoreApi?,
    private val owner: CoroutineScope,
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(SettingsState())
    val state: StateFlow<SettingsState> = mutableState.asStateFlow()
    private val mutableNotices = MutableSharedFlow<SettingsNotice>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val notices: SharedFlow<SettingsNotice> = mutableNotices.asSharedFlow()

    private var scope: ConversationScope? = null
    private var work: CoroutineScope? = null
    private var started = false

    // Everything below belongs to the current generation and is reset with it.
    /** What the core says. */
    private var said = Said()
    private var labelsShown = false
    private var sessionsShown = false

    private data class Said(
        val profile: Profile? = null,
        val profileLoading: Boolean = true,
        val profileFailed: Boolean = false,
        val policy: LabelPolicy? = null,
        val policyLoading: Boolean = false,
        val sessions: List<DeviceSession>? = null,
        val sessionsLoading: Boolean = false,
        val sessionsFailed: Boolean = false,
    )

    fun start() {
        synchronized(lock) { if (started) return; started = true }
        owner.launch { sessions.scopes.collect(::bind) }
    }

    private fun bind(next: ConversationScope?) {
        val previous: CoroutineScope?
        synchronized(lock) {
            if (next === scope) return
            previous = work
            scope = next
            work = next?.let { CoroutineScope(owner.coroutineContext + SupervisorJob(owner.coroutineContext[Job])) }
            said = Said()
            labelsShown = false
            sessionsShown = false
            publish(next?.generation)
        }
        previous?.cancel()
        // The label policy and the devices are read when the settings open; the chat only needs the profile.
        if (next != null) show(next, JSONObject().put("topic", "profile"), ::readProfile)
    }

    /** Follows [topic] for the generation of [scope]: each value changes what the core says, by [merge]. */
    private fun show(scope: ConversationScope, topic: JSONObject, merge: (Said, Any?) -> Said) {
        val running = core ?: return
        launch { current ->
            if (current !== scope) return@launch
            running.subscribe(topic) { it }.collect { value ->
                if (value is TopicValue.Value) edit(scope) { said = merge(said, value.value) }
            }
        }
    }

    private fun readProfile(said: Said, value: Any?): Said {
        val json = value as? JSONObject
        val profile = json?.optJSONObject("profile")?.let { row ->
            val id = row.optString("id").takeIf { it.isNotEmpty() } ?: return@let null
            Profile(id, row.optString("email"), row.string("name"), row.string("avatar_id"))
        }
        val status = json?.optString("status")
        return said.copy(profile = profile, profileLoading = status == "loading", profileFailed = status == "error")
    }

    private fun readPolicy(said: Said, value: Any?): Said {
        val json = value as? JSONObject
        return said.copy(policy = LabelPolicy.parse(json?.optJSONObject("catalog")?.optString("approval_policy")),
            policyLoading = json?.optBoolean("loading") == true)
    }

    private fun readSessions(said: Said, value: Any?): Said {
        val json = value as? JSONObject
        val rows = json?.optJSONArray("sessions") ?: JSONArray()
        val list = (0 until rows.length()).mapNotNull { index ->
            val row = rows.optJSONObject(index) ?: return@mapNotNull null
            DeviceSession(row.optString("id").takeIf { it.isNotEmpty() } ?: return@mapNotNull null,
                row.string("deviceLabel"), row.string("clientKind"), row.string("clientPlatform"),
                row.long("authenticatedAt"), row.long("lastSeenAt"), row.optBoolean("current"))
        }
        val status = json?.optString("status")
        // A list that cannot be read is said once, when it fails.
        if (status == "error" && !said.sessionsFailed) notice(SettingsAction.LOAD_DEVICES, SettingsProblem.SERVER)
        return said.copy(sessions = list.takeIf { status == "ready" } ?: said.sessions.takeIf { status != "loading" },
            sessionsLoading = status == "loading", sessionsFailed = status == "error")
    }

    fun refreshProfile() = launch { scope ->
        try {
            core?.call("profile.refresh")
        } catch (e: Exception) {
            rethrowCancellation(e)
            if (isCurrent(scope)) notice(SettingsAction.LOAD_PROFILE, e)
        }
    }

    /** Asks the core for [name], which shows it at once. */
    fun rename(name: String) {
        val trimmed = name.trim()
        ProfileRules.problem(trimmed)?.let { mutableNotices.tryEmit(SettingsNotice(SettingsAction.RENAME, it)); return }
        change(SettingsAction.RENAME) { core?.call("profile.update", JSONObject().put("name", trimmed)) }
    }

    /**
     * Hands the prepared image at [file] to the core, which shows it at once and uploads it. The file is deleted
     * afterwards. [mime] must be one of [AVATAR_TYPES] and the file at most [AVATAR_MAX_BYTES].
     */
    fun changeAvatar(file: File, mime: String) {
        val problem = when {
            mime !in AVATAR_TYPES -> SettingsProblem.AVATAR_TYPE
            file.length() !in 1..AVATAR_MAX_BYTES -> SettingsProblem.AVATAR_TOO_LARGE
            else -> null
        }
        if (problem != null) {
            file.delete()
            mutableNotices.tryEmit(SettingsNotice(SettingsAction.CHANGE_AVATAR, problem))
            return
        }
        change(SettingsAction.CHANGE_AVATAR, always = { file.delete() }) {
            core?.call("profile.uploadAvatar", JSONObject().put("bytes", CoreBytes.json(file.readBytes()))
                .put("type", mime).put("name", file.name))
        }
    }

    fun removeAvatar() = change(SettingsAction.REMOVE_AVATAR) { core?.call("profile.removeAvatar") }

    fun refreshLabelPolicy() {
        val scope = synchronized(lock) { scope } ?: return
        val first = synchronized(lock) { !labelsShown.also { labelsShown = true } }
        if (first) {
            edit(scope) { said = said.copy(policyLoading = true) }
            show(scope, JSONObject().put("topic", "taskLabels").put("group", scope.groupId), ::readPolicy)
        } else launch { attempt { core?.call("taskLabels.refresh", JSONObject().put("group", scope.groupId)) } }
    }

    fun setLabelPolicy(value: LabelPolicy) {
        val group = synchronized(lock) { scope?.groupId } ?: return
        change(SettingsAction.LABEL_POLICY) {
            core?.call("taskLabels.setPolicy", JSONObject().put("group", group).put("policy", value.wire))
        }
    }

    fun refreshSessions() {
        val scope = synchronized(lock) { scope } ?: return
        val first = synchronized(lock) { !sessionsShown.also { sessionsShown = true } }
        if (first) show(scope, JSONObject().put("topic", "accountSessions"), ::readSessions)
        else launch { attempt { core?.call("accountSessions.refresh") } }
    }

    /** Signs out one other device. This device is signed out with the account's own logout. */
    fun removeSession(id: String) = launch { scope ->
        if (state.value.sessions?.none { it.id == id && !it.current } != false) return@launch
        attempt { core?.call("accountSessions.revoke", JSONObject().put("id", id)) }
            ?.let { if (isCurrent(scope)) notice(SettingsAction.REMOVE_DEVICE, it) }
    }

    /** Signs out every device except this one. */
    fun removeOtherSessions() = launch { scope ->
        if (state.value.sessions == null) return@launch
        attempt { core?.call("accountSessions.revokeOthers") }
            ?.let { if (isCurrent(scope)) notice(SettingsAction.REMOVE_OTHER_DEVICES, it) }
    }

    /** The current account's avatar image; null once the account has changed. */
    suspend fun avatarBytes(avatarId: String): ByteArray? {
        val scope = synchronized(lock) { scope } ?: return null
        val answer = core?.call("files.read", JSONObject().put("source", "avatar").put("revision", avatarId)) as? JSONObject
        return CoreBytes.read(answer?.opt("bytes"))?.takeIf { isCurrent(scope) }
    }

    /** Asks the core for a change in the current generation, and says why when it is refused. */
    private fun change(action: SettingsAction, always: () -> Unit = {}, ask: suspend () -> Unit) = launch(always) { scope ->
        attempt(ask)?.let { if (isCurrent(scope)) notice(action, it) }
    }

    /** What the screens show: what the core says. Call under [lock]. */
    private fun publish(generation: Long? = scope?.generation) {
        if (generation == null) {
            mutableState.value = SettingsState()
            return
        }
        val s = said
        mutableState.value = SettingsState(
            generation = generation,
            profile = s.profile,
            avatar = s.profile?.avatarId?.let(AvatarSource::Remote) ?: AvatarSource.None,
            profileLoading = s.profileLoading && s.profile == null,
            profileProblem = SettingsProblem.SERVER.takeIf { s.profileFailed && s.profile == null },
            labelPolicy = s.policy,
            labelPolicyLoading = s.policyLoading,
            sessions = s.sessions,
            sessionsLoading = s.sessionsLoading,
            sessionsProblem = SettingsProblem.SERVER.takeIf { s.sessionsFailed },
        )
    }

    /** Applies [change] and publishes only while [scope] is still the current generation. */
    private fun edit(scope: ConversationScope, change: () -> Unit): Boolean = synchronized(lock) {
        if (!isCurrent(scope)) return false
        change()
        publish()
        true
    }

    private fun isCurrent(scope: ConversationScope): Boolean = synchronized(lock) {
        this.scope === scope && sessions.isCurrent(scope)
    }

    /** Runs [block] in the current generation. [always] runs once when it ends, or at once if there is none. */
    private fun launch(always: () -> Unit = {}, block: suspend (ConversationScope) -> Unit) {
        val (current, work) = synchronized(lock) { scope to work }
        if (current == null || work == null) { always(); return }
        work.launch { block(current) }.invokeOnCompletion { always() }
    }

    /** Runs [block]: null when it went through, else why not. */
    private suspend fun attempt(block: suspend () -> Unit): Exception? = try {
        block()
        null
    } catch (e: Exception) {
        rethrowCancellation(e)
        e
    }

    private fun notice(action: SettingsAction, e: Exception) = notice(action, problem(e))

    private fun notice(action: SettingsAction, problem: SettingsProblem) {
        mutableNotices.tryEmit(SettingsNotice(action, problem))
    }

    private fun rethrowCancellation(e: Exception) { if (e is CancellationException) throw e }

    internal companion object {
        /** The server rejects larger avatars with `avatar_too_large`. */
        const val AVATAR_MAX_BYTES = 102_400L
        val AVATAR_TYPES = setOf("image/jpeg", "image/png", "image/webp")

        fun problem(e: Exception): SettingsProblem = when {
            e !is CoreError -> SettingsProblem.NETWORK
            e.code == "name_required" -> SettingsProblem.NAME_EMPTY
            e.code == "name_too_long" -> SettingsProblem.NAME_TOO_LONG
            e.code == "avatar_too_large" || e.status == 413 -> SettingsProblem.AVATAR_TOO_LARGE
            e.code == "unsupported_avatar_type" -> SettingsProblem.AVATAR_TYPE
            e.status == 403 -> SettingsProblem.FORBIDDEN
            e.status != null -> SettingsProblem.SERVER
            else -> SettingsProblem.NETWORK
        }
    }
}

private fun JSONObject.string(key: String): String? =
    if (isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

private fun JSONObject.long(key: String): Long? =
    if (isNull(key) || !has(key)) null else optLong(key).takeIf { it > 0 }
