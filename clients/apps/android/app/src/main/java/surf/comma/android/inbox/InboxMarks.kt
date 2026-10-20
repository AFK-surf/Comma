package surf.comma.android.inbox

import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.TaskListFilter

/**
 * The Inbox's read, unread and cleared state. The server keeps no per-member notification state, so these
 * are facts about this device: the client core's marks (`taskReviewSeen`, `inboxUnread`, `inboxDeleted`), kept
 * with the account. Each mark records the Task's `updatedAt` when it was made, as the desktop's revision marks do:
 * - `seen`: the member viewed the Task. A Needs review Task that updates afterwards reads as unread again.
 * - `unread`: the member marked the row unread. It stays until the row is read.
 * - `cleared`: the row is hidden until the Task updates past the mark, so new activity brings it back.
 */
data class InboxMarks(
    val seen: Map<String, Long> = emptyMap(),
    val unread: Map<String, Long> = emptyMap(),
    val cleared: Map<String, Long> = emptyMap(),
) {
    /** Hidden until the Task updates past the revision it was cleared at. */
    fun isCleared(task: TaskSummary): Boolean = cleared[task.id]?.let { task.updatedAt <= it } ?: false

    /** Marked unread by the member, or a Needs review Task not viewed since it last updated. */
    fun isUnread(task: TaskSummary): Boolean {
        if (unread.containsKey(task.id)) return true
        if (task.bucket != TaskStatusBucket.NEEDS_REVIEW) return false
        return seen[task.id]?.let { task.updatedAt > it } ?: true
    }

    fun markSeen(task: TaskSummary) = copy(seen = mark(seen, listOf(task)))

    /** Clears the dot without opening the rows: drops their unread marks and records them as seen. */
    fun markRead(tasks: List<TaskSummary>) = copy(unread = unread - tasks.map { it.id }.toSet(), seen = mark(seen, tasks))

    fun markUnread(tasks: List<TaskSummary>) = copy(unread = mark(unread, tasks))

    /** Hides these rows until their Tasks update again. Nothing on the server changes. */
    fun clear(tasks: List<TaskSummary>) = copy(cleared = mark(cleared, tasks))

    fun undoClear(tasks: List<TaskSummary>) = copy(cleared = cleared - tasks.map { it.id }.toSet())

    companion object {
        /** Records each Task's revision; a mark never moves backwards. */
        private fun mark(marks: Map<String, Long>, tasks: List<TaskSummary>): Map<String, Long> {
            val next = marks.toMutableMap()
            for (task in tasks) if ((next[task.id] ?: Long.MIN_VALUE) < task.updatedAt) next[task.id] = task.updatedAt
            return next
        }
    }
}

/** Why the Inbox shows no rows. */
sealed interface InboxEmptyState {
    /** Nothing has finished or needed review yet. */
    data object NothingYet : InboxEmptyState
    /** Every notification was cleared, or read while showing unread only. */
    data object CaughtUp : InboxEmptyState
    /** The filter hides this many rows that the default Inbox shows. */
    data class Filtered(val hidden: Int) : InboxEmptyState
}

/**
 * The Inbox as a projection of the loaded Task list, like the desktop's Inbox rail: the Tasks that finished
 * or wait on the member, newest first, never archived Tasks or rows the member cleared.
 */
object InboxProjection {
    /** Needs review, Done, and Cancelled (which includes Failed). In progress and Backlog stay one filter away. */
    val DEFAULT_FILTER = TaskListFilter(statuses = setOf(TaskStatusBucket.NEEDS_REVIEW, TaskStatusBucket.DONE, TaskStatusBucket.CANCELLED))

    fun listed(tasks: List<TaskSummary>, marks: InboxMarks): List<TaskSummary> =
        tasks.filter { !it.isArchived && !marks.isCleared(it) }

    fun rows(tasks: List<TaskSummary>, marks: InboxMarks, filter: TaskListFilter, unreadOnly: Boolean = false): List<TaskSummary> =
        listed(tasks, marks).filter { filter.matches(it) && (!unreadOnly || marks.isUnread(it)) }
            .sortedByDescending { it.changedAt }

    fun hasUnread(tasks: List<TaskSummary>, marks: InboxMarks): Boolean = listed(tasks, marks).any(marks::isUnread)

    fun emptyState(tasks: List<TaskSummary>, marks: InboxMarks, filter: TaskListFilter): InboxEmptyState {
        if (filter != DEFAULT_FILTER) {
            val hidden = rows(tasks, marks, DEFAULT_FILTER).size
            if (hidden > 0) return InboxEmptyState.Filtered(hidden)
        }
        val arrived = tasks.any { !it.isArchived && DEFAULT_FILTER.matches(it) }
        return if (arrived) InboxEmptyState.CaughtUp else InboxEmptyState.NothingYet
    }
}
