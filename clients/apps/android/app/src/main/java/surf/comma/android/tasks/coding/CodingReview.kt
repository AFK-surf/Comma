package surf.comma.android.tasks.coding

import kotlinx.coroutines.CancellationException
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.workspace.WorkspaceCalls

internal fun JSONObject.text(name: String): String? = if (has(name) && !isNull(name)) optString(name).takeIf(String::isNotEmpty) else null
internal fun JSONObject.objects(name: String): List<JSONObject> = optJSONArray(name).objects()
internal fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull(::optJSONObject)
internal fun JSONObject.intOrNull(name: String): Int? = if (has(name) && !isNull(name)) optInt(name) else null

/**
 * A coding Task's review (Task details > Code review), as the iOS app's: where its session stands (`coding.session`),
 * the branch's changes against a chosen commit (`coding.changes`), its execution history read on request
 * (`coding.history`), and its pull request (`coding.pullRequest`, `coding.updatePullRequest`,
 * `coding.mergePullRequest`). Each read is one call made when the page asks; nothing polls. [onChange] runs after
 * every change of what the page shows.
 */
class CodingReview(private val calls: WorkspaceCalls, private val task: String) {
    var onChange: () -> Unit = {}
    var session: JSONObject? = null; private set
    var changes: JSONObject? = null; private set
    var history: JSONObject? = null; private set
    var historyItems: List<JSONObject> = emptyList(); private set
    var commits: List<JSONObject> = emptyList(); private set
    var hasUncommitted = false; private set
    var pullRequest: JSONObject? = null; private set
    var loaded = false; private set
    var loading = false; private set
    var busy = false; private set
    var error: String? = null
        private set(value) { field = value; onChange() }

    /** "" for every change of the branch, "uncommitted", or a commit's sha. */
    var selection = ""
        private set
    var prTitle = ""
    var prBody = ""
    var prDraft = true

    val current: Boolean get() = calls.current
    val files: List<JSONObject> get() = changes?.objects("files").orEmpty()

    private fun params() = JSONObject().put("workspaceId", calls.workspaceId).put("taskId", task)

    suspend fun load() {
        if (loading) return
        loading = true
        onChange()
        try {
            session = calls.call("coding.session", params()) as? JSONObject
            loadChanges()
            loaded = true
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (current) { loaded = true; error = WorkspaceCalls.message(failure) }
        } finally {
            loading = false
            onChange()
        }
    }

    suspend fun select(next: String) {
        if (next == selection) return
        selection = next
        onChange()
        if (loaded) loadChanges()
    }

    /** Counts the reads of changes; only the latest one's answer is shown. */
    private var changesRead = 0

    suspend fun loadChanges() {
        val mine = ++changesRead
        val params = params()
        when (selection) {
            "" -> Unit
            "uncommitted" -> params.put("uncommitted", true)
            else -> params.put("commit", selection)
        }
        try {
            val answer = calls.call("coding.changes", params) as? JSONObject
            // A read for an earlier choice that answers late must not show its changes under the current one.
            if (mine != changesRead) return
            changes = answer
            // Only the whole branch says which commits, local changes and pull request there are.
            if (selection.isEmpty()) {
                commits = answer?.objects("commits").orEmpty()
                hasUncommitted = answer?.optBoolean("uncommitted") == true
                pullRequest = answer?.optJSONObject("pullRequest")
                prTitle = pullRequest?.text("title").orEmpty()
                prBody = pullRequest?.text("body").orEmpty()
            }
            error = null
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (mine != changesRead) return
            if (current) error = WorkspaceCalls.message(failure)
        }
        onChange()
    }

    suspend fun loadHistory(more: Boolean = false) {
        val params = params()
        val start = history?.intOrNull("start")
        if (more && start != null && start > 0) params.put("before", start)
        try {
            val answer = calls.call("coding.history", params) as? JSONObject
            val next = answer?.objects("items").orEmpty()
            historyItems = if (more) historyItems + next else next
            history = answer
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (failure: Exception) {
            if (current) error = WorkspaceCalls.message(failure)
        }
        onChange()
    }

    /** A pull request is made anew when there is none or the branch moved on since it was merged or closed. */
    val createsPullRequest: Boolean get() = pullRequest == null || pullRequest?.optBoolean("newCommits") == true

    suspend fun savePullRequest(): Boolean {
        val params = params().put("title", prTitle).put("body", prBody)
        if (createsPullRequest) params.put("draft", prDraft)
        val done = perform(if (createsPullRequest) "coding.pullRequest" else "coding.updatePullRequest", params) ?: return false
        selection = ""
        loadChanges()
        return done
    }

    suspend fun markReady() {
        if (perform("coding.updatePullRequest", params().put("ready", true)) != null) { selection = ""; loadChanges() }
    }

    /** Merges exactly the pull request and head the member confirmed; the service refuses a head that moved since. */
    suspend fun merge(number: Int, head: String) {
        if (perform("coding.mergePullRequest", params().put("number", number).put("headSha", head)) != null) { selection = ""; loadChanges() }
    }

    /** The sandbox's web terminal; only an https link is opened. */
    suspend fun terminal(): String? {
        val answer = perform("coding.terminal", params()) ?: return null
        return terminalLink(answer)
    }

    private suspend fun perform(name: String, params: JSONObject): Boolean? {
        if (!current || busy) return null
        busy = true
        error = null
        try {
            calls.call(name, params)
            return true
        } catch (cancel: CancellationException) {
            return null
        } catch (failure: Exception) {
            if (current) error = WorkspaceCalls.message(failure)
            return null
        } finally {
            busy = false
            onChange()
        }
    }

    companion object {
        fun terminalLink(answer: Any?): String? {
            val url = (answer as? JSONObject)?.text("url") ?: return null
            return url.takeIf { runCatching { java.net.URI(it).scheme == "https" }.getOrDefault(false) }
        }
    }
}
