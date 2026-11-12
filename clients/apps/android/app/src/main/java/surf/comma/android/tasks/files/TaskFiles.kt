package surf.comma.android.tasks.files

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.workspace.WorkspaceCalls

/** A file an Agent attached to a message of the Task, as Comma's index lists it (`taskFiles.list`). */
data class TaskFile(
    val conversation: String,
    val message: String,
    val index: Int,
    val name: String,
    val size: Long,
    val mediaType: String?,
    val createdAt: Double,
) {
    val id: String get() = "$conversation/$message/$index"
    val isImage: Boolean get() = mediaType?.startsWith("image/") == true

    /** The draft's reference to it for `chatView.attachConversationFiles`: no bytes pass through the phone. */
    fun reference(): JSONObject = JSONObject().put("conversationId", conversation).put("messageId", message)
        .put("index", index).put("name", name).put("size", size)

    companion object {
        fun parse(json: JSONObject): TaskFile? {
            val conversation = json.optString("conversation_id").takeIf(String::isNotEmpty) ?: return null
            val message = json.optString("message_id").takeIf(String::isNotEmpty) ?: return null
            if (!json.has("index") || json.isNull("index")) return null
            val index = json.optInt("index", -1).takeIf { it >= 0 } ?: return null
            val name = json.optString("file_name").takeIf(String::isNotEmpty) ?: return null
            return TaskFile(conversation, message, index, name, json.optLong("size"),
                json.optString("mime_type").takeIf { json.has("mime_type") && !json.isNull("mime_type") && it.isNotEmpty() },
                json.optDouble("created_at", 0.0))
        }
    }
}

/**
 * The Task files page's state: the Task's files read a page at a time (the core reads at most 200 per page), whether
 * Comma still indexes older ones, and what fails. Nothing is kept beyond the page. [attach] stages one file in the
 * Task's draft by reference and sends nothing.
 */
class TaskFilesModel(
    private val calls: WorkspaceCalls,
    private val conversation: String,
    private val attach: suspend (JSONArray) -> Unit,
) {
    data class State(
        val files: List<TaskFile> = emptyList(),
        val loaded: Boolean = false,
        val loading: Boolean = false,
        val indexing: Boolean = false,
        val cursor: String? = null,
        /** The file being downloaded for a preview or share; one at a time. */
        val preparing: String? = null,
        val attaching: Boolean = false,
        val failed: Failure? = null,
    )

    sealed interface Failure {
        /** The index answered with an error. */
        data object Unavailable : Failure
        data class Said(val message: String?) : Failure
    }

    private val mutable = MutableStateFlow(State())
    val state: StateFlow<State> = mutable.asStateFlow()
    private var generation = 0

    val current: Boolean get() = calls.current

    /** The first page again, or with [more] the page after the last one read. */
    suspend fun load(more: Boolean = false) {
        val before = mutable.value
        if (!current || (more && (before.loading || before.cursor.isNullOrEmpty()))) return
        val mine = ++generation
        mutable.update { it.copy(loading = true, failed = null) }
        val params = JSONObject().put("group", calls.groupId).put("conversation", conversation)
        if (more) params.put("cursor", before.cursor)
        try {
            val json = calls.call("taskFiles.list", params) as? JSONObject ?: return
            if (mine != generation) return
            val status = json.optString("status")
            if (status != "ready") {
                mutable.update {
                    it.copy(loaded = true, indexing = status == "indexing", failed = if (status == "indexing") null else Failure.Unavailable)
                }
                return
            }
            val rows = json.optJSONArray("files") ?: JSONArray()
            val next = (0 until rows.length()).mapNotNull { rows.optJSONObject(it)?.let(TaskFile::parse) }
                // The index answers by the Task asked for; a file of another conversation is not this Task's.
                .filter { it.conversation == conversation }
            mutable.update { state ->
                val merged = ((if (more) state.files else emptyList()) + next).distinctBy { it.id }
                state.copy(files = merged, loaded = true, indexing = false,
                    cursor = json.optString("nextCursor").takeIf { json.has("nextCursor") && !json.isNull("nextCursor") && it.isNotEmpty() })
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            if (mine == generation && current) mutable.update { it.copy(loaded = true, failed = Failure.Said(WorkspaceCalls.message(error))) }
        } finally {
            if (mine == generation) mutable.update { it.copy(loading = false) }
        }
    }

    /** Marks [file] as being prepared; false while another one is. */
    fun beginPreparing(file: TaskFile): Boolean {
        if (!current || mutable.value.preparing != null) return false
        mutable.update { it.copy(preparing = file.id, failed = null) }
        return true
    }

    fun endPreparing(failure: String? = null) {
        mutable.update { it.copy(preparing = null, failed = failure?.let { message -> Failure.Said(message) } ?: it.failed) }
    }

    /** Adds [file] to the Task's draft; true once it is there and the page is still current. */
    suspend fun attach(file: TaskFile): Boolean {
        if (!current || mutable.value.attaching) return false
        mutable.update { it.copy(attaching = true, failed = null) }
        return try {
            attach(JSONArray().put(file.reference()))
            current
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (error: Exception) {
            if (current) mutable.update { it.copy(failed = Failure.Said(WorkspaceCalls.message(error))) }
            false
        } finally {
            mutable.update { it.copy(attaching = false) }
        }
    }

    companion object {
        /** Loaded files whose name contains [query], case-insensitively; all of them for an empty one. */
        fun filter(files: List<TaskFile>, query: String): List<TaskFile> {
            val needle = query.trim()
            return if (needle.isEmpty()) files else files.filter { it.name.contains(needle, ignoreCase = true) }
        }
    }
}
