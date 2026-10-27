package surf.comma.android.tasks

/**
 * Where a task stands: the section the client core folds the server's free-form status into, the same on every client.
 * The order of the constants carries no meaning; the core orders the list ([TaskSection]).
 */
enum class TaskStatusBucket(val wireName: String) {
    IN_PROGRESS("in_progress"),
    NEEDS_REVIEW("needs_review"),
    DONE("done"),
    CANCELLED("cancelled"),
    ARCHIVED("archived"),
    ;

    companion object {
        /** The bucket the core names; in progress for one it does not, since every new task starts there. */
        fun of(wireName: String?): TaskStatusBucket = entries.firstOrNull { it.wireName == wireName } ?: IN_PROGRESS
    }
}

/** A label from the group's task-label catalog. [color] is a preset name or `#rrggbb`. */
data class TaskLabel(
    val id: String,
    val name: String,
    val color: String,
)

/**
 * Where a Task a station hosts runs, as the client core lists it: its station's chat ([station], [thread]) in
 * [workspace], and what this device knows of the machine.
 */
data class TaskHost(
    val workspace: String,
    val station: String,
    val thread: Long,
    /** The machine's name; null where this device knows none. */
    val machine: String? = null,
    /** Whether the machine is online; null where this device knows none. */
    val online: Boolean? = null,
)

/** One task as the list surfaces show it, as the client core says it. */
data class TaskSummary(
    val id: String,
    val title: String,
    /** The section its status folds into. */
    val bucket: TaskStatusBucket,
    /** Latest progress line while the task runs; null when there is nothing to report. */
    val progress: String? = null,
    val labelIds: List<String> = emptyList(),
    /** Milliseconds since the epoch; 0 when unknown. */
    val updatedAt: Long = 0L,
    val createdAt: Long = 0L,
    /** The server's `archive_availability.allowed`; null when the source did not say. */
    val archiveAllowed: Boolean? = null,
    /** It stopped because it failed: in the cancelled section, but said so. */
    val failed: Boolean = false,
    /** The server's free-form status, e.g. `active`, `ready_for_review`; empty when the source did not say. */
    val status: String = "",
    /** The review the member accepts with Mark as done; 0 when there is none. */
    val reviewVersion: Long = 0L,
    /** Where the Task was asked for: `slack`, `telegram`, `comma`…; null when unknown. */
    val origin: String? = null,
    /** The device a Task asked for in Comma came from: `ios`, `android`, `macos`…; null when unknown. */
    val clientPlatform: String? = null,
    /** The Task runs on a schedule; scheduled Tasks cannot be accepted or ended by hand. */
    val scheduled: Boolean = false,
    /** Milliseconds since the epoch while archived; 0 otherwise. */
    val archivedAt: Long = 0L,
    /** The section the Task was archived from. */
    val archivedFrom: TaskStatusBucket? = null,
    /** When the Task last changed, in milliseconds since the epoch; 0 when unknown. */
    val changedAt: Long = 0L,
    /** Where a Task a station hosts runs. Null for any other. */
    val host: TaskHost? = null,
    /** What the core says this Task cannot take (`archive`, `pin`, `share`): not offered. */
    val unsupported: Set<String> = emptySet(),
) {
    val isArchived: Boolean get() = bucket == TaskStatusBucket.ARCHIVED || archivedAt > 0

    /** The section a list shows: an archived Task keeps the one it was archived from, else In progress. */
    val listBucket: TaskStatusBucket
        get() = if (isArchived) archivedFrom ?: TaskStatusBucket.IN_PROGRESS else bucket

    /** The desktop's Done: accepting the result of a Task in review. */
    val canAcceptReview: Boolean get() = bucket == TaskStatusBucket.NEEDS_REVIEW && reviewVersion > 0 && !scheduled

    /** A member can end the Task by hand. The server also refuses Workflow and Triage Tasks. */
    val canSetStatus: Boolean
        get() = !isArchived && (bucket == TaskStatusBucket.IN_PROGRESS || bucket == TaskStatusBucket.NEEDS_REVIEW) &&
            updatedAt > 0 && !scheduled

}

/** Everything the full task list needs from one read. */
data class TaskSnapshot(
    val tasks: List<TaskSummary>,
    /** The group's label catalog, in catalog order. */
    val labels: List<TaskLabel>,
) {
    companion object {
        val EMPTY = TaskSnapshot(emptyList(), emptyList())
    }
}
