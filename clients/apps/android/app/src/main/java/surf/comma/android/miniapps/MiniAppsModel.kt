package surf.comma.android.miniapps

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.auth.ConversationScope
import surf.comma.android.auth.Workspace
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue

/**
 * One management surface for one Workspace. It follows one list or one app, and at most one selected build Task. It
 * adds no polling. Every call names the Workspace captured when the surface opened, and stops once the account
 * scope it opened under changes.
 */
class MiniAppsModel(private val context: Context, private val core: CoreApi, val workspace: Workspace, private val opened: ConversationScope?) {
    data class State(
        val apps: List<MiniAppRecord> = emptyList(),
        val app: MiniAppRecord? = null,
        val versions: List<MiniAppVersionRecord> = emptyList(),
        val linkUrl: String? = null,
        val loaded: Boolean = false,
        val missing: Boolean = false,
        val busy: Boolean = false,
        val failure: String? = null,
        /** The selected build Task's conversation, as `chatView` shows it; null when none is followed. */
        val review: JSONObject? = null,
    )

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState.asStateFlow()

    val current: Boolean get() = MiniAppRuntimes.isCurrent(opened, context)
    val owner: Boolean get() = state.value.app?.workspaceId == workspace.id

    /** Follows the Workspace's own and installed apps until the caller stops collecting. */
    suspend fun followList() {
        if (!current) return
        core.subscribe(JSONObject().put("topic", "miniApps").put("workspace", workspace.id)) { it as? JSONObject }.collect { value ->
            if (!current) return@collect
            when (value) {
                is TopicValue.Value -> {
                    val json = value.value ?: return@collect
                    val status = json.optString("status")
                    mutableState.update {
                        it.copy(apps = json.objects("apps").mapNotNull(MiniAppRecord::parse), loaded = status != "loading",
                            failure = if (status == "failed") context.getString(R.string.mini_apps_list_failed) else null)
                    }
                }
                is TopicValue.Failed -> mutableState.update { it.copy(loaded = true, failure = value.error.message) }
            }
        }
    }

    suspend fun followApp(id: String) {
        mutableState.update { State() }
        if (!current) return
        core.subscribe(JSONObject().put("topic", "miniApp").put("workspace", workspace.id).put("app", id)) { it as? JSONObject }
            .collect { value ->
                if (!current) return@collect
                when (value) {
                    is TopicValue.Value -> {
                        val json = value.value ?: return@collect
                        val status = json.optString("status")
                        mutableState.update {
                            it.copy(app = MiniAppRecord.parse(json.optJSONObject("app")), linkUrl = json.optJSONObject("link")?.text("url"),
                                versions = json.objects("versions").mapNotNull(MiniAppVersionRecord::parse),
                                loaded = status != "loading", missing = status == "missing",
                                failure = if (status == "failed") context.getString(R.string.mini_apps_app_failed) else null)
                        }
                    }
                    is TopicValue.Failed -> mutableState.update { it.copy(loaded = true, failure = value.error.message) }
                }
            }
    }

    /** Follows the build Task of the selected Version, the one review publication may accept. */
    suspend fun followReview(conversationId: String?) {
        mutableState.update { it.copy(review = null) }
        if (conversationId == null || !current || !owner) return
        val topic = JSONObject().put("topic", "chatView").put("workspace", workspace.id).put("group", workspace.groupId)
            .put("conversation", conversationId).put("surface", "android-mini-app-review")
        core.subscribe(topic) { (it as? JSONObject)?.optJSONObject("state")?.optJSONObject("conversation") }.collect { value ->
            if (!current) return@collect
            mutableState.update { it.copy(review = (value as? TopicValue.Value)?.value) }
        }
    }

    /** The publication [version] allows now: a ready, not live Version whose build Task's review still matches. */
    fun publication(version: MiniAppVersionRecord): MiniAppPublication? {
        val state = state.value
        val app = state.app ?: return null
        val task = state.review ?: return null
        val conversation = version.conversationId ?: return null
        if (!current || !owner || !app.active || app.liveVersion == version.number || version.state != "ready" || version.live) return null
        if (task.optString("id") != conversation || task.optString("kind") != "agent_task") return null
        if (task.optString("status") !in setOf("ready_for_review", "completed")) return null
        val review = task.optLong("review_version").takeIf { it > 0 } ?: return null
        return MiniAppPublication(app.id, version.number, conversation, review)
    }

    suspend fun publish(publication: MiniAppPublication, visibility: String): Boolean {
        val version = state.value.versions.firstOrNull { it.number == publication.version }
        if (version == null || publication(version) != publication) {
            mutableState.update { it.copy(failure = context.getString(R.string.mini_apps_publish_stale)) }
            return false
        }
        return perform("miniApps.publish", JSONObject().put("app", publication.appId).put("version", publication.version)
            .put("group", workspace.groupId).put("conversation", publication.conversationId)
            .put("reviewVersion", publication.reviewVersion).put("visibility", visibility))
    }

    /** One management call. A failure stays visible; nothing is retried automatically. */
    suspend fun perform(operation: String, params: JSONObject = JSONObject()): Boolean {
        if (!current || state.value.busy) return false
        mutableState.update { it.copy(busy = true, failure = null) }
        return try {
            core.call(operation, params.put("workspace", workspace.id))
            if (current && operation in CLOSING) params.optString("app").takeIf(String::isNotEmpty)?.let { MiniAppRuntimes.close(workspace.id, it) }
            current
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (current) mutableState.update { it.copy(failure = error.message?.takeIf(String::isNotBlank) ?: context.getString(R.string.mini_apps_action_failed)) }
            false
        } finally {
            mutableState.update { it.copy(busy = false) }
        }
    }

    private companion object {
        val CLOSING = setOf("miniApps.uninstall", "miniApps.disable", "miniApps.delete")
    }
}
