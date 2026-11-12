package surf.comma.android.workspace

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import org.json.JSONObject
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

/**
 * The client core's calls for one account scope and Workspace, as a Task tool page makes them (task files, code
 * review, the remote browser, Task creation). [current] goes false for good once the member signs out or picks another
 * account or Workspace: a call made then is not sent, and an answer that comes after is dropped, so a late result never
 * updates another Workspace's page.
 */
class WorkspaceCalls(
    private val api: CommaApi,
    val workspaceId: String,
    val groupId: String,
    private val isCurrent: () -> Boolean,
) {
    val current: Boolean get() = isCurrent()

    /** The call's answer; throws [CancellationException] when the scope ended before or while it ran. */
    suspend fun call(name: String, params: JSONObject = JSONObject()): Any? {
        if (!current) throw CancellationException("Scope changed")
        val answer = api.call(name, params)
        if (!current) throw CancellationException("Scope changed")
        return answer
    }

    fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = api.subscribe(topic, read)

    companion object {
        /** What a page shows for a failed call: the core's message, or nothing to say. */
        fun message(error: Throwable): String? = (error as? CoreError)?.message?.takeIf(String::isNotBlank) ?: error.message
    }
}
