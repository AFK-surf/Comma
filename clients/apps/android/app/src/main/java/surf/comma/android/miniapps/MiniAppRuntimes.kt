package surf.comma.android.miniapps

import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.ConversationScope
import surf.comma.android.core.CoreError

/**
 * The process's Mini App executions: at most one retained session per Workspace app, which Back suspends and the run
 * screen continues. A changed account or Workspace closes them all and forgets every presented target, so an old page
 * cannot send more commands. Memory pressure releases the suspended ones.
 */
object MiniAppRuntimes {
    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val sessions = LinkedHashMap<String, MiniAppSession>()
    private val presented = HashMap<String, MiniAppTarget>()
    private var nextHandle = 0L
    private var started = false
    private var scope: ConversationScope? = null
    private var auth: surf.comma.android.auth.AuthRepository? = null
    private val mutableChanges = MutableStateFlow(0)
    /** Advances whenever a retained session starts, suspends or closes, for the Run and Continue buttons. */
    val changes: StateFlow<Int> = mutableChanges.asStateFlow()

    private val memory = object : ComponentCallbacks2 {
        @Deprecated("Deprecated in Java")
        override fun onLowMemory() = releaseSuspended()
        override fun onTrimMemory(level: Int) {
            if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) releaseSuspended()
        }
        override fun onConfigurationChanged(newConfig: Configuration) = Unit
    }

    /** Adds text to the signed-in app's chat draft, for `chat.draft`; null while no app screen can take it. */
    var draftTarget: ((String) -> Unit)? = null

    fun releaseDraftTarget(target: (String) -> Unit) {
        if (draftTarget == target) draftTarget = null
    }

    /** Follows the account scope from now on. Called on the main thread when the signed-in app starts. */
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        app.registerComponentCallbacks(memory)
        val auth = AuthGraph.get(app).also { this.auth = it }
        scope = auth.conversationScope.value
        main.launch {
            auth.conversationScope.collect { next ->
                if (next === scope) return@collect
                scope = next
                closeAll()
            }
        }
    }

    /** The scope a page opens under, as the session has it now; [isCurrent] says whether it still is. */
    fun currentScope(): ConversationScope? = auth?.conversationScope?.value

    fun isCurrent(opened: ConversationScope?, context: Context): Boolean {
        val auth = AuthGraph.get(context)
        return opened != null && opened === auth.conversationScope.value && auth.isCurrentGeneration(opened.generation)
    }

    /** Opens the run screen for [target]. The target, its link token included, stays in this process. */
    fun run(context: Context, target: MiniAppTarget) {
        val handle = "run-${++nextHandle}"
        presented[handle] = target
        context.startActivity(Intent(context, MiniAppActivity::class.java).putExtra(MiniAppActivity.EXTRA_HANDLE, handle))
    }

    internal fun presented(handle: String?): MiniAppTarget? = handle?.let(presented::get)

    internal fun forget(handle: String?) {
        handle?.let(presented::remove)
    }

    /** The retained execution for [target], when it can continue as that same run. */
    fun retained(target: MiniAppTarget): MiniAppSession? {
        val session = sessions[target.runtimeKey] ?: return null
        if (!session.canContinue || session.target.shareToken != target.shareToken) return null
        if (target.version != null && target.version != session.state.value.version) return null
        return session
    }

    /** Whether the Workspace app has a suspended run that Run would continue. */
    fun canContinue(workspaceId: String, appId: String): Boolean {
        val session = sessions["$workspaceId/$appId"] ?: return false
        return session.target.shareToken == null && session.isSuspended && session.canContinue
    }

    fun retain(session: MiniAppSession) {
        val key = session.target.runtimeKey
        sessions[key]?.takeIf { it !== session }?.stop()
        sessions[key] = session
        mutableChanges.value++
    }

    fun close(session: MiniAppSession) {
        if (sessions[session.target.runtimeKey] === session) sessions.remove(session.target.runtimeKey)
        session.stop()
        mutableChanges.value++
    }

    /** Closes the Workspace app's run, as uninstalling, disabling or deleting it does. */
    fun close(workspaceId: String, appId: String) {
        sessions["$workspaceId/$appId"]?.let(::close)
    }

    fun suspended() {
        mutableChanges.value++
    }

    private fun closeAll() {
        val all = sessions.values.toList()
        sessions.clear()
        presented.clear()
        all.forEach(MiniAppSession::stop)
        mutableChanges.value++
    }

    private fun releaseSuspended() {
        val released = sessions.filterValues { it.isSuspended }
        for ((key, session) in released) {
            sessions.remove(key)
            session.failed(CoreError("unavailable", "This app was released to free memory. Reload it to continue."))
        }
        if (released.isNotEmpty()) mutableChanges.value++
    }
}
