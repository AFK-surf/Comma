package surf.comma.android.shell

import android.content.Context
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.ConversationSessions
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.list.TaskActions
import surf.comma.android.workspace.WorkspaceStore

/** What the tabs' pages can reach in the shell around them. */
interface Shell {
    val activity: ComponentActivity
    val store: WorkspaceStore
    val actions: TaskActions

    /** Opens the router chat; [focus] raises its keyboard once it is open. */
    fun openRouter(focus: Boolean = false)

    /** Adds [text] to the router composer after a blank line, opens the router and focuses the composer. */
    fun insertIntoRouter(text: String)

    /** Turns message notifications on, when they are off and can be turned on here; null otherwise. */
    fun notificationsOff(): (() -> Unit)?
}

/**
 * A lifetime inside the activity's: it follows the activity's state until [destroy], which ends it early and
 * cancels whatever work it scoped. A Task's chat lives in one, so closing its dock stops its streams.
 */
class ChildLifecycle(parent: LifecycleOwner) : LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    private val parentLifecycle = parent.lifecycle
    private val follow = LifecycleEventObserver { _, event ->
        if (registry.currentState != Lifecycle.State.DESTROYED) registry.handleLifecycleEvent(event)
    }

    override val lifecycle: Lifecycle get() = registry

    init {
        parentLifecycle.addObserver(follow)
    }

    fun destroy() {
        parentLifecycle.removeObserver(follow)
        if (registry.currentState.isAtLeast(Lifecycle.State.INITIALIZED)) registry.currentState = Lifecycle.State.DESTROYED
    }
}

/**
 * The signed-in session as a Task's conversation sees it: the account's scope with the Task in place of the router
 * chat. One scope per account scope, so a scope that ends ends the Task's too.
 */
private class TaskConversationSessions(private val auth: AuthRepository, private val taskId: String) : ConversationSessions {
    val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val derived = mutableMapOf<ConversationScope, ConversationScope>()

    override val scopes: StateFlow<ConversationScope?> = auth.conversationScope.map { it?.let(::derive) }
        .stateIn(owner, SharingStarted.Eagerly, auth.conversationScope.value?.let(::derive))

    @Synchronized private fun derive(base: ConversationScope): ConversationScope =
        derived.getOrPut(base) { ConversationScope(base.generation, base.accountId, base.groupId, taskId, base.workspaceId) }

    override fun isCurrent(scope: ConversationScope): Boolean {
        val base = auth.conversationScope.value ?: return false
        return synchronized(this) { derived[base] } === scope && auth.isCurrentGeneration(scope.generation)
    }

    fun close() = owner.coroutineContext[kotlinx.coroutines.Job]?.cancel()
}

/**
 * The Worker bound to a Task: its participant, the avatar identity and its name; [active] while it works. [vendor] is
 * the maker of the model it runs (`comma` for Comma's own), whose logo stands for it; null when not known.
 */
data class BoundWorker(val participantId: String, val avatarId: String, val name: String, val active: Boolean, val vendor: String? = null)

/**
 * A Task's own conversation, read and sent to like the router chat: the core's `chatView` for the Task, and its
 * bound Worker from the `taskWorkers` topic. [close] lets both go.
 */
class TaskConversation private constructor(val view: ChatView, private val sessions: TaskConversationSessions) {
    private val mutableWorker = MutableStateFlow<BoundWorker?>(null)
    /** The Task's bound Worker; null before one is bound or known. */
    val worker: StateFlow<BoundWorker?> = mutableWorker.asStateFlow()

    private fun followWorker(context: Context) {
        val core = AuthGraph.core(context) ?: return
        sessions.owner.launch {
            sessions.scopes.collectLatest { scope ->
                mutableWorker.value = null
                if (scope == null) return@collectLatest
                core.subscribe(JSONObject().put("topic", "taskWorkers").put("group", scope.groupId).put("ids", scope.conversationId)) { value ->
                    (value as? JSONObject)?.optJSONObject(scope.conversationId)?.let { worker ->
                        val participant = worker.optString("participantId").takeIf(String::isNotEmpty) ?: return@let null
                        BoundWorker(participant, worker.optString("avatarId").ifEmpty { participant }, worker.optString("name"),
                            worker.optBoolean("active"), worker.optString("vendor").ifEmpty { null })
                    }
                }.collect { value -> if (value is TopicValue.Value && sessions.isCurrent(scope)) mutableWorker.value = value.value }
            }
        }
    }

    fun close() {
        view.close()
        sessions.close()
    }

    companion object {
        /** [foreground]: whether the app is on screen now; the dock follows it with [ChatView.setForeground] after. */
        fun open(context: Context, taskId: String, foreground: Boolean): TaskConversation {
            val app = context.applicationContext
            val auth = AuthGraph.get(app)
            val sessions = TaskConversationSessions(auth, taskId)
            val view = ChatView(sessions, AuthGraph.core(app))
            view.start()
            view.setForeground(foreground)
            return TaskConversation(view, sessions).also { it.followWorker(app) }
        }
    }
}
