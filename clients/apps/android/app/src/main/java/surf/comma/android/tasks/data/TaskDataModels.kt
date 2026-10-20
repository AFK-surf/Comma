package surf.comma.android.tasks.data

import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.TaskSection
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskSummary

/** Passed through to the server, including on subsequent cursor pages. */
enum class TaskArchiveFilter(val wireName: String) { EXCLUDE("exclude"), ONLY("only"), INCLUDE("include") }

/** The loaded list window plus canonical summaries needed by references outside that window. */
data class TaskDataState(
    val groupId: String? = null,
    val snapshot: TaskSnapshot = TaskSnapshot.EMPTY,
    val summaries: Map<String, TaskSummary> = emptyMap(),
    val conversationTaskIds: Map<String, List<String>> = emptyMap(),
    /** The list's sections as the core orders them. */
    val sections: List<TaskSection> = emptyList(),
    val archiveFilter: TaskArchiveFilter = TaskArchiveFilter.INCLUDE,
    val hasMore: Boolean = false,
    val loading: Boolean = false,
    val cacheLoaded: Boolean = false,
    /** A successful list read (possibly restored from disk), including a confirmed empty list. */
    val listLoaded: Boolean = false,
    /** Successful list reads in this session, so a surface can tell one apart from a retry starting. */
    val listReads: Int = 0,
    /**
     * Which count [listReads] belongs to: new for every session the repository opens, so also
     * for every process. Counts are only comparable under the same epoch.
     */
    val listReadsEpoch: String = "",
    val connection: Connection = Connection.IDLE,
    val problem: ConversationProblem? = null,
    /** The account's workspaces, as the list's read names them. */
    val workspaces: List<surf.comma.android.auth.Workspace> = emptyList(),
)

/** Only the currently opened task reads message pages; there are no sends or per-task streams. */
data class TaskDetailState(
    val taskId: String? = null,
    val timeline: List<TimelineEntry.Message> = emptyList(),
    val hasOlder: Boolean = false,
    val loading: Boolean = false,
    val problem: ConversationProblem? = null,
)

enum class TaskArchiveResult { ARCHIVED, NOT_ALLOWED, CONFLICT, UNAVAILABLE }
