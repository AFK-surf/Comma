package surf.comma.android.notify

import android.content.Context
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConversationScope
import surf.comma.android.chat.live.ChatGraph
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue

/** What the controller needs from Android's notification service. */
internal interface ReplyPoster {
    fun canPost(): Boolean
    fun permissionGranted(): Boolean
    fun post(notice: ReplyNotice)
    fun cancel(accountTag: String, conversationId: String)
    fun cancelReplies(keepAccountTag: String? = null)
}

/** The device-level switch and the one-time permission request, kept in preferences. */
internal interface ReplyPrefs {
    var enabled: Boolean
    /** The system permission dialog has been shown once. */
    var asked: Boolean
    /** The user once left the chat while a reply was on its way: the moment to ask. */
    var leftWhileWaiting: Boolean
}

/**
 * Local reply notifications for the main chat, owned by the process.
 *
 * The chat reports when it is shown and hidden; [ReplyWatch] decides whether the hidden chat keeps
 * receiving. While a hold lasts and no screen of the app is visible, [ReplyReceiverService] keeps
 * the process running. Each notice the core words for a message the Router sends in the hidden chat
 * ([notices]) is posted as it comes, the same event Electron's Main shows a banner for. When the
 * reply has landed, everything stops.
 * Signing out or switching accounts ends the hold and removes the notifications.
 */
class ReplyNotifications internal constructor(
    private val chat: ChatStream,
    /** The core's notices for messages conversations gain, each once ([appendedNotices]). */
    notices: Flow<AppendedNotice>,
    private val scopes: StateFlow<ConversationScope?>,
    signedOut: Flow<Boolean>,
    private val appVisible: StateFlow<Boolean>,
    private val poster: ReplyPoster,
    private val prefs: ReplyPrefs,
    private val startService: () -> Unit,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    windowMillis: Long = ReplyWatch.WINDOW_MILLIS,
) {
    /** The conversation layer as seen from here. */
    internal interface ChatStream {
        val state: StateFlow<ConversationState>
        fun setBackgroundHold(hold: Boolean)
    }

    private val watch = ReplyWatch(windowMillis)
    private var appliedHold = false
    private var expiry: Job? = null
    private var lastScope: ConversationScope? = null
    /** The chat whose notification was removed since the chat was last shown. */
    private var seenScope: ConversationScope? = null
    private val mutableEnabled = MutableStateFlow(prefs.enabled)
    val enabled: StateFlow<Boolean> = mutableEnabled.asStateFlow()
    private val mutableService = MutableStateFlow(false)
    /** True while a hold lasts with no screen of the app visible: the service's reason to run. */
    val serviceWanted: StateFlow<Boolean> = mutableService.asStateFlow()

    init {
        scope.launch { chat.state.collect(::onState) }
        scope.launch { notices.collect(::onNotice) }
        scope.launch { scopes.collect(::onScope) }
        scope.launch { signedOut.collect { if (it) endAll() } }
        scope.launch { appVisible.collect { syncService() } }
    }

    /** The chat is on screen. Call after the chat's own stream is resumed. */
    fun chatShown() {
        watch.chatShown()
        applyHold()
        seenScope = null
        clearShown(chat.state.value)
    }

    /** Opening the chat removes its notification, also when the chat's data loads after it is shown. */
    private fun clearShown(state: ConversationState) {
        val shown = state.scope ?: return
        if (!watch.chatVisible || shown === seenScope) return
        seenScope = shown
        poster.cancel(accountTag(shown.accountId), shown.conversationId)
    }

    /** The chat is leaving the screen. Call before the chat's own stream is paused. */
    fun chatHidden() {
        val allowed = mutableEnabled.value && (poster.canPost() || (!poster.permissionGranted() && !prefs.asked))
        if (!watch.chatHidden(chat.state.value, clock(), allowed)) return
        if (!poster.permissionGranted()) prefs.leftWhileWaiting = true
        applyHold()
        scheduleExpiry()
    }

    private var scheduledDeadline: Long? = null

    private fun scheduleExpiry() {
        val deadline = watch.deadline ?: return
        if (deadline == scheduledDeadline) return
        scheduledDeadline = deadline
        expiry?.cancel()
        expiry = scope.launch {
            delay((deadline - clock()).coerceAtLeast(0))
            if (watch.expire(clock())) applyHold()
        }
    }

    /** The service was stopped by the system (its daily limit), so the hold cannot last. */
    fun serviceTimedOut() {
        watch.cancel()
        applyHold()
    }

    fun setEnabled(value: Boolean) {
        prefs.enabled = value
        mutableEnabled.value = value
        if (!value) {
            watch.cancel()
            applyHold()
        }
    }

    /** Ask for the notification permission now: once, after the user first left a reply waiting. */
    fun shouldAskPermission(): Boolean =
        mutableEnabled.value && prefs.leftWhileWaiting && !prefs.asked && !poster.permissionGranted()

    fun permissionAsked() {
        prefs.asked = true
    }

    fun permissionAskedBefore(): Boolean = prefs.asked

    fun permissionGranted(): Boolean = poster.permissionGranted()

    /** Whether a reply notification would reach the user now. */
    fun canPost(): Boolean = poster.canPost()

    /**
     * The entry a notification tap should scroll to, once the session is known; null for anything
     * that is not a reply link of the signed-in account's chat.
     */
    internal suspend fun target(link: ReplyLink): String? {
        val current = withTimeoutOrNull(SESSION_WAIT_MILLIS) { scopes.filterNotNull().first() } ?: return null
        return link.targetFor(current)?.also { poster.cancel(link.accountTag, link.conversationId) }
    }

    private fun onState(state: ConversationState) {
        watch.update(state, clock())
        if (watch.holding) scheduleExpiry() else applyHold()
        clearShown(state)
    }

    /** A notice the core worded: posted at once when it is for the signed-in account's chat and that chat is hidden. */
    private fun onNotice(notice: AppendedNotice) {
        val current = scopes.value ?: return
        if (!mutableEnabled.value || watch.chatVisible) return
        if (notice.groupId != current.groupId || notice.conversationId != current.conversationId) return
        val row = chat.state.value.takeIf { it.scope === current }?.timeline
            ?.firstOrNull { it is TimelineEntry.Message && it.message.messageId == notice.messageId }
        poster.post(ReplyNotice(current.accountId, current.conversationId, notice.title, notice.body,
            row?.key ?: "m:${notice.messageId}"))
    }

    private fun onScope(next: ConversationScope?) {
        val previous = lastScope
        lastScope = next
        if (previous != null && next !== previous) {
            watch.cancel()
            applyHold()
        }
        when {
            next != null -> poster.cancelReplies(keepAccountTag = accountTag(next.accountId))
            previous != null -> poster.cancelReplies()
        }
    }

    private fun endAll() {
        watch.cancel()
        applyHold()
        poster.cancelReplies()
    }

    private fun applyHold() {
        val hold = watch.holding
        if (!hold) {
            expiry?.cancel()
            expiry = null
            scheduledDeadline = null
        }
        if (hold != appliedHold) {
            appliedHold = hold
            chat.setBackgroundHold(hold)
        }
        syncService()
    }

    private fun syncService() {
        val wanted = watch.holding && !appVisible.value
        if (wanted == mutableService.value) return
        mutableService.value = wanted
        if (wanted) startService()
    }

    companion object {
        private const val SESSION_WAIT_MILLIS = 10_000L
        @Volatile private var instance: ReplyNotifications? = null

        /** The process's controller, if the chat has created it. */
        internal val current: ReplyNotifications? get() = instance

        /** Call on the main thread. */
        fun get(context: Context): ReplyNotifications = instance ?: synchronized(this) {
            instance ?: create(context.applicationContext).also { instance = it }
        }

        private fun create(app: Context): ReplyNotifications {
            val auth = AuthGraph.get(app)
            val repository = ChatGraph.conversations(app)
            val notifier = ReplyNotifier(app).also { it.createChannels() }
            val visible = MutableStateFlow(true)
            val process = ProcessLifecycleOwner.get().lifecycle
            visible.value = process.currentState.isAtLeast(Lifecycle.State.STARTED)
            process.addObserver(androidx.lifecycle.LifecycleEventObserver { _, _ ->
                visible.value = process.currentState.isAtLeast(Lifecycle.State.STARTED)
            })
            return ReplyNotifications(
                chat = object : ChatStream {
                    override val state get() = repository.state
                    override fun setBackgroundHold(hold: Boolean) = repository.setBackgroundHold(hold)
                },
                notices = AuthGraph.core(app)?.let(::appendedNotices) ?: emptyFlow(),
                scopes = auth.conversationScope,
                signedOut = auth.state.map { it is AuthState.Login || it == AuthState.Unconfigured },
                appVisible = visible,
                poster = notifier,
                prefs = SharedReplyPrefs(app),
                startService = { ReplyReceiverService.start(app) },
                scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
            )
        }
    }
}

/**
 * The core's notices for the messages conversations gain (`chatAppended`, the topic Electron's Main shows banners
 * from), each once: what the core kept before this started following is old news, and a core that started again
 * counts from 0.
 */
internal fun appendedNotices(core: CoreApi): Flow<AppendedNotice> = flow {
    var last: Long? = null
    core.subscribe(JSONObject().put("topic", "chatAppended")) { it as? JSONObject }.collect { value ->
        val appended = ((value as? TopicValue.Value)?.value)?.optJSONArray("appended") ?: return@collect
        val newest = appended.optJSONObject(appended.length() - 1)?.optLong("seq") ?: 0L
        val after = last
        last = newest
        if (after == null || newest < after) return@collect
        for (index in 0 until appended.length()) {
            val entry = appended.optJSONObject(index) ?: continue
            if (entry.optLong("seq") <= after) continue
            val target = entry.optJSONObject("target") ?: continue
            val notices = entry.optJSONArray("notices") ?: continue
            for (at in 0 until notices.length()) {
                val notice = notices.optJSONObject(at) ?: continue
                emit(AppendedNotice(target.optString("groupId"), target.optString("conversationId"),
                    notice.optString("messageId"), notice.optString("title"), notice.optString("body")))
            }
        }
    }
}

private class SharedReplyPrefs(context: Context) : ReplyPrefs {
    private val prefs = context.getSharedPreferences("reply_notifications", Context.MODE_PRIVATE)
    override var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        set(value) { prefs.edit().putBoolean("enabled", value).apply() }
    override var asked: Boolean
        get() = prefs.getBoolean("asked", false)
        set(value) { prefs.edit().putBoolean("asked", value).apply() }
    override var leftWhileWaiting: Boolean
        get() = prefs.getBoolean("left_while_waiting", false)
        set(value) { prefs.edit().putBoolean("left_while_waiting", value).apply() }
}
