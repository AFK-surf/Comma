package surf.comma.android.workspace

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.filter
import org.json.JSONObject
import surf.comma.android.auth.ConversationScope
import surf.comma.android.core.CoreApi
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary

/**
 * The client core's calls and topics for what the tabs show beyond the conversations: Task management (review,
 * title, labels, archive, pins, share links), search and the label catalog. The core makes the requests; failures
 * are [CoreError]s, with the server's status when one answered.
 */
class CommaApi(private val core: CoreApi?) {
    private fun running(): CoreApi = core ?: throw CoreError("unavailable", "No client core")

    suspend fun call(name: String, params: JSONObject): Any? = running().call(name, params)

    /** A topic's values read by [read]; the topic is let go when collection ends. */
    fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = running().subscribe(topic, read)

    /** The topic's first value that [read] makes something of; a failed topic throws its error. */
    suspend fun <T : Any> first(topic: JSONObject, read: (Any?) -> T?): T {
        val value = subscribe(topic, read).filter { it is TopicValue.Failed || (it as TopicValue.Value).value != null }.first()
        return when (value) {
            is TopicValue.Failed -> throw value.error
            is TopicValue.Value -> value.value!!
        }
    }

    private fun task(scope: ConversationScope, taskId: String) =
        JSONObject().put("group", scope.groupId).put("conversation", taskId)

    // MARK: Tasks

    suspend fun search(scope: ConversationScope, query: String, known: Map<String, TaskSummary>): List<TaskSummary> {
        val answer = call("search.tasks", JSONObject().put("query", query).put("group", scope.groupId)
            .put("prefer", scope.workspaceId)) as? JSONObject ?: return emptyList()
        if (answer.optString("status") == "error") throw CoreError("unavailable", "Search failed")
        val rows = answer.optJSONArray("results") ?: return emptyList()
        return (0 until rows.length()).mapNotNull { index ->
            val row = rows.optJSONObject(index) ?: return@mapNotNull null
            val id = row.optString("conversation_id").takeIf(String::isNotEmpty) ?: return@mapNotNull null
            known[id] ?: TaskSummary(id, row.optString("title"), TaskStatusBucket.IN_PROGRESS,
                changedAt = wireMillis(row.optLong("updated_at")))
        }.distinctBy { it.id }
    }

    suspend fun accept(scope: ConversationScope, taskId: String, reviewVersion: Long) {
        call("tasks.accept", task(scope, taskId).put("reviewVersion", reviewVersion))
    }

    suspend fun rename(scope: ConversationScope, taskId: String, title: String) {
        call("tasks.rename", task(scope, taskId).put("title", title))
    }

    suspend fun setLabels(scope: ConversationScope, taskId: String, labelIds: List<String>) {
        call("taskLabels.assign", task(scope, taskId).put("labels", org.json.JSONArray(labelIds)))
    }

    /** False when another change of the Task's archive is under way. */
    suspend fun setArchived(scope: ConversationScope, taskId: String, archived: Boolean, version: Long): Boolean =
        call("tasks.archive", task(scope, taskId).put("action", if (archived) "archive" else "unarchive")
            .put("version", version)) != false

    suspend fun setPinned(scope: ConversationScope, taskId: String, pinned: Boolean) {
        call("tasks.pin", task(scope, taskId).put("pinned", pinned))
    }

    // MARK: Share links

    /** The Task's link; null when it is not shared. */
    suspend fun share(scope: ConversationScope, taskId: String): TaskShare? = first(
        task(scope, taskId).put("topic", "taskShare").put("visit", System.nanoTime().toString())) { value ->
        val json = value as? JSONObject
        when (json?.optString("status")) {
            "ready" -> Result.success(json.optJSONObject("share")?.let(TaskShare::parse))
            "failed" -> Result.failure(CoreError("unavailable", "Share failed"))
            else -> null
        }
    }.getOrThrow()

    suspend fun publishShare(scope: ConversationScope, taskId: String): TaskShare? =
        (call("taskShare.publish", task(scope, taskId)) as? JSONObject)?.let(TaskShare::parse)

    suspend fun resetShare(scope: ConversationScope, taskId: String): TaskShare? =
        (call("taskShare.reset", task(scope, taskId)) as? JSONObject)?.let(TaskShare::parse)

    suspend fun revokeShare(scope: ConversationScope, taskId: String) {
        call("taskShare.revoke", task(scope, taskId))
    }

    // MARK: Labels

    fun labelTopic(scope: ConversationScope) = JSONObject().put("topic", "taskLabels").put("group", scope.groupId)

    /** The catalog as the core keeps it, once read; a failed first read throws. */
    suspend fun labelCatalog(scope: ConversationScope): LabelCatalog = first(labelTopic(scope)) { value ->
        val json = value as? JSONObject
        json?.optJSONObject("catalog")?.let { Result.success(LabelCatalog.parse(it)) }
            ?: if (json?.optBoolean("error") == true) Result.failure(CoreError("unavailable", "Labels failed")) else null
    }.getOrThrow()

    private fun label(name: String, color: String, description: String?) = JSONObject().put("name", name).put("color", color)
        .put("description", description.orEmpty())

    suspend fun createLabel(scope: ConversationScope, name: String, color: String, description: String?): LabelCatalog {
        call("taskLabels.create", label(name, color, description).put("group", scope.groupId))
        return labelCatalog(scope)
    }

    suspend fun updateLabel(scope: ConversationScope, id: String, name: String, color: String, description: String?): LabelCatalog {
        call("taskLabels.update", label(name, color, description).put("group", scope.groupId).put("label", id))
        return labelCatalog(scope)
    }

    suspend fun deleteLabel(scope: ConversationScope, id: String): LabelCatalog {
        call("taskLabels.delete", JSONObject().put("group", scope.groupId).put("label", id))
        return labelCatalog(scope)
    }

    suspend fun resolveProposal(scope: ConversationScope, id: String, approve: Boolean): LabelCatalog {
        call("taskLabels.resolve", JSONObject().put("group", scope.groupId).put("proposal", id)
            .put("decision", if (approve) "approve" else "reject"))
        return labelCatalog(scope)
    }

    suspend fun setLabelPolicy(scope: ConversationScope, policy: String): LabelCatalog {
        call("taskLabels.setPolicy", JSONObject().put("group", scope.groupId).put("policy", policy))
        return labelCatalog(scope)
    }
}
