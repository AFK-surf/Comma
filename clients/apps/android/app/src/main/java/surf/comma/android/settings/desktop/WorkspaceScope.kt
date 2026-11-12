package surf.comma.android.settings.desktop

import androidx.annotation.StringRes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ConversationSessions
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

/** What a page says went wrong: the core's own message, or one of the app's. */
internal sealed interface PageError {
    data class Message(val text: String) : PageError
    data class Text(@StringRes val id: Int) : PageError
}

/** The answer of a call that went through; its [value] may be null. */
internal class Done(val value: Any?) {
    val json: JSONObject? get() = value as? JSONObject
}

/**
 * One Settings page's account and Workspace, as the iOS app's `WorkspaceSettingsScope`: the session scope it was
 * opened in names both. Once the account or Workspace changes the scope retires: it sends no more commands and drops
 * late answers. Everything runs on [work]'s thread (the main thread in the app); [onChange] redraws the page.
 */
internal class WorkspaceScope(
    val core: CoreApi,
    private val sessions: ConversationSessions,
    val session: ConversationScope,
    parent: CoroutineScope,
) {
    val work = CoroutineScope(parent.coroutineContext + SupervisorJob(parent.coroutineContext[Job]))
    val workspaceId: String get() = session.workspaceId
    val groupId: String get() = session.groupId
    var busy = false
        private set
    var error: PageError? = null
        set(value) {
            field = value
            changed()
        }
    private val listeners = mutableListOf<() -> Unit>()

    val current: Boolean get() = sessions.isCurrent(session)

    fun onChange(listener: () -> Unit) { listeners += listener }
    fun changed() = listeners.toList().forEach { it() }

    /** A scope of its own (its own busy state and error) for one part of this page; it closes with this one. */
    fun child(): WorkspaceScope = WorkspaceScope(core, sessions, session, work)

    /** Ends the page's subscriptions and calls. */
    fun close() {
        listeners.clear()
        work.cancel()
    }

    /** A call for this page's Workspace; throws [CancellationException] once the page retired. */
    suspend fun call(name: String, params: JSONObject = JSONObject(), workspaceParameter: Boolean = true): Any? {
        if (!current) throw CancellationException("retired")
        if (workspaceParameter) params.put("workspace", workspaceId)
        val value = core.call(name, params)
        if (!current) throw CancellationException("retired")
        return value
    }

    /** One command at a time, its failure said as the page's error. Null when it did not go through. */
    suspend fun perform(name: String, params: JSONObject = JSONObject(), workspaceParameter: Boolean = true): Done? {
        if (!current || busy) return null
        busy = true
        error = null
        try {
            return Done(call(name, params, workspaceParameter))
        } catch (e: CancellationException) {
            return null
        } catch (e: Exception) {
            if (current) error = describe(e)
            return null
        } finally {
            busy = false
            changed()
        }
    }

    /** [perform] started from a tap. */
    fun launch(name: String, params: JSONObject = JSONObject(), workspaceParameter: Boolean = true, then: (Done) -> Unit = {}) {
        work.launch { perform(name, params, workspaceParameter)?.let(then) }
    }

    companion object {
        fun describe(e: Exception): PageError =
            (e as? CoreError)?.message?.takeIf { it.isNotBlank() }?.let(PageError::Message) ?: PageError.Text(R.string.ds_error_generic)
    }
}

/**
 * A shared-core topic that one page follows, as the iOS app's `WorkspaceTopic`. With [workspaceField] a value for
 * another Workspace is not shown; the page says it is unavailable instead.
 */
internal class WorkspaceTopic(
    val scope: WorkspaceScope,
    private val topic: String,
    private val parameters: JSONObject = JSONObject(),
    private val workspaceField: Boolean = false,
) {
    var value: JSONObject? = null
        private set
    var loaded = false
        private set

    fun follow(onValue: ((JSONObject) -> Unit)? = null): Job = scope.work.launch {
        val query = JSONObject(parameters.toString()).put("topic", topic)
        scope.core.subscribe(query) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> receive(update.value as? JSONObject ?: JSONObject(), onValue)
                is TopicValue.Failed -> {
                    loaded = true
                    scope.error = WorkspaceScope.describe(update.error)
                }
            }
        }
    }

    private fun receive(next: JSONObject, onValue: ((JSONObject) -> Unit)?) {
        if (workspaceField) {
            val id = next.string("workspace") ?: next.optJSONObject("workspace")?.string("id")
            if (id != scope.workspaceId) {
                if (id != null || next.optBoolean("error")) {
                    loaded = true
                    scope.error = PageError.Text(R.string.ds_error_other_workspace)
                }
                return
            }
        }
        value = next
        loaded = true
        onValue?.invoke(next)
        val failed = next.optBoolean("error") || next.string("status") in setOf("failed", "error")
        scope.error = if (failed) PageError.Text(R.string.ds_error_load_page) else null
    }
}

internal fun JSONObject.string(key: String): String? =
    if (!has(key) || isNull(key)) null else (opt(key) as? String)?.takeIf { it.isNotEmpty() }

internal fun JSONObject.int(key: String): Long? =
    if (!has(key) || isNull(key)) null else (opt(key) as? Number)?.toLong()

internal fun JSONObject.objects(key: String): List<JSONObject> = optJSONArray(key).objects()

internal fun JSONArray?.objects(): List<JSONObject> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

internal fun JSONObject.strings(key: String): List<String> {
    val array = optJSONArray(key) ?: return emptyList()
    return (0 until array.length()).mapNotNull { (array.opt(it) as? String)?.takeIf(String::isNotEmpty) }
}

internal fun json(vararg pairs: Pair<String, Any?>): JSONObject =
    JSONObject().apply { pairs.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) } }
