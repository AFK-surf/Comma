package surf.comma.android.tasks.pages

import android.content.Context
import android.content.Intent
import androidx.annotation.MainThread
import androidx.annotation.StringRes
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskArchiveResult

/** How the chat reaches the task pages. */
object TaskPages {
    const val EXTRA_TASK_ID = "surf.comma.android.task_id"

    fun listIntent(context: Context): Intent = Intent(context, TaskListActivity::class.java)

    fun detailIntent(context: Context, taskId: String): Intent =
        Intent(context, TaskDetailActivity::class.java).putExtra(EXTRA_TASK_ID, taskId)

    fun openList(context: Context) = context.startActivity(listIntent(context))

    fun openDetail(context: Context, taskId: String) = context.startActivity(detailIntent(context, taskId))
}

/**
 * A task page belongs to the session it was opened in. Signing out, another account, or a new
 * session generation all publish a different scope, and the page closes: task data from one
 * account is never shown under another.
 */
class TaskPageGuard(private val opened: ConversationScope?) {
    fun shouldClose(current: ConversationScope?): Boolean = opened == null || current !== opened
}

/**
 * Only one task's messages are read at a time, and the page on top owns that read. A page
 * claims it when it starts; one that is finishing lets go only if nobody has claimed it since,
 * so closing a detail page never cancels the page it returns to.
 */
@MainThread
internal object TaskDetailOwner {
    private var owner: Any? = null

    /** Returns the read that opens [taskId], or null when it is already open. */
    fun claim(token: Any, taskId: String, repository: ServerTaskRepository): Job? {
        owner = token
        if (repository.detail.value.taskId == taskId && repository.detail.value.problem == null) return null
        return processScope().launch { repository.openDetail(taskId) }
    }

    fun release(token: Any, repository: ServerTaskRepository) {
        if (owner !== token) return
        owner = null
        processScope().launch { repository.closeDetail() }
    }

    private fun processScope() = ProcessLifecycleOwner.get().lifecycleScope
}

/** The note shown after swiping a task away, or null when the archive went through. */
@StringRes
fun archiveNotice(result: TaskArchiveResult): Int? = when (result) {
    TaskArchiveResult.ARCHIVED -> null
    TaskArchiveResult.NOT_ALLOWED -> R.string.task_archive_not_allowed
    TaskArchiveResult.CONFLICT -> R.string.task_archive_conflict
    TaskArchiveResult.UNAVAILABLE -> R.string.task_archive_unavailable
}

/** The list's line before its first successful read or when loading failed. */
@StringRes
fun taskListNotice(problem: ConversationProblem?, connection: Connection, listLoaded: Boolean): Int? = when {
    problem == null -> if (listLoaded) null else R.string.task_list_loading
    problem == ConversationProblem.NETWORK || connection == Connection.RECONNECTING -> R.string.task_list_offline
    else -> R.string.task_list_problem
}

/** The line over a list that is still shown when the last read failed. */
@StringRes
fun taskListProblem(problem: ConversationProblem, connection: Connection): Int =
    if (problem == ConversationProblem.NETWORK || connection == Connection.RECONNECTING) R.string.task_list_offline
    else R.string.task_list_refresh_failed

/** The detail's message area when it has nothing to show. */
@StringRes
fun taskDetailNotice(problem: ConversationProblem?, loading: Boolean, empty: Boolean): Int? = when {
    !empty -> null
    problem == ConversationProblem.NOT_FOUND || problem == ConversationProblem.FORBIDDEN -> R.string.task_detail_not_found
    problem != null -> R.string.task_detail_problem
    loading -> R.string.task_detail_loading
    else -> R.string.task_detail_empty
}
