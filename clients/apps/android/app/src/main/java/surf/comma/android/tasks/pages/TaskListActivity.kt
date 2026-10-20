package surf.comma.android.tasks.pages

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskDataState
import surf.comma.android.tasks.data.TaskGraph
import surf.comma.android.tasks.ui.TaskListView

/**
 * Every task in the workspace, from the shared task data layer: grouped by status in the group's
 * shared order, filtered by label, refreshed by pulling down, paged as the end comes near, and
 * archived by swiping where the server allows it. Closes when the session changes.
 *
 * The filter and reading position survive the page being recreated, but only into the group they
 * were saved from.
 */
class TaskListActivity : ComponentActivity() {
    private lateinit var repository: ServerTaskRepository
    private lateinit var list: TaskListView
    private var loadingMore = false
    private var refreshing = false
    /** Saved filter and position, with the group they belong to, until the list can take them. */
    private var pendingRestore: Pair<String, Bundle>? = null
    /** The failure the list reports, held until a later read succeeds (see [renderProblem]). */
    private var problem: ConversationProblem? = null
    private var problemReads = 0
    private var problemEpoch = ""
    /** A failure line saved with the page, until the first state that names a group. */
    private var pendingProblem: SavedProblem? = null

    private class SavedProblem(val group: String, val problem: ConversationProblem, val epoch: String, val reads: Int)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val auth = AuthGraph.get(this)
        val guard = TaskPageGuard(auth.conversationScope.value)
        if (guard.shouldClose(auth.conversationScope.value)) {
            finish()
            return
        }
        repository = TaskGraph.get(this, auth)
        list = TaskListView(this).apply {
            onBack = ::finish
            onOpenTask = { TaskPages.openDetail(this@TaskListActivity, it) }
            onArchiveTask = ::archive
            onRefresh = ::refresh
            onRetry = ::retry
            onNearEnd = ::loadMore
        }
        setContentView(list)
        savedInstanceState?.let(::restoreFrom)
        // For the page's whole life, not only while it is shown: a page left behind must not
        // come back showing another account's tasks.
        lifecycleScope.launch { auth.conversationScope.collect { if (guard.shouldClose(it)) finish() } }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { repository.state.collect(::render) }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (::list.isInitialized && ::repository.isInitialized) saveInto(outState, repository.state.value)
    }

    /**
     * The filter, position and an unanswered failure, tagged with the group they belong to.
     * The failure is kept because the stream clears the repository's problem between attempts:
     * a recreated page could not tell that no read has succeeded since.
     */
    internal fun saveInto(outState: Bundle, state: TaskDataState) {
        val group = state.groupId ?: return
        outState.putString(STATE_GROUP, group)
        outState.putBundle(STATE_LIST, list.saveState())
        problem?.let {
            outState.putString(STATE_PROBLEM, it.name)
            outState.putInt(STATE_PROBLEM_READS, problemReads)
            outState.putString(STATE_PROBLEM_EPOCH, problemEpoch)
        }
    }

    internal fun restoreFrom(saved: Bundle) {
        val group = saved.getString(STATE_GROUP) ?: return
        saved.getBundle(STATE_LIST)?.let { pendingRestore = group to it }
        val failure = saved.getString(STATE_PROBLEM)
            ?.let { name -> ConversationProblem.entries.firstOrNull { it.name == name } }
        if (failure != null) {
            pendingProblem = SavedProblem(group, failure, saved.getString(STATE_PROBLEM_EPOCH).orEmpty(),
                saved.getInt(STATE_PROBLEM_READS))
        }
    }

    private fun render(state: TaskDataState) {
        pendingProblem?.let { saved ->
            if (state.groupId == null) return@let
            pendingProblem = null
            if (state.groupId != saved.group || problem != null) return@let
            problem = saved.problem
            problemEpoch = saved.epoch
            problemReads = saved.reads
        }
        pendingRestore?.let { (group, saved) ->
            when {
                state.groupId != null && state.groupId != group -> pendingRestore = null
                state.groupId == group && state.snapshot.tasks.isNotEmpty() -> {
                    list.restoreState(saved)
                    pendingRestore = null
                }
                state.listLoaded -> pendingRestore = null
            }
        }
        list.submit(state.snapshot, state.sections)
        val notice = taskListNotice(state.problem, state.connection, state.listLoaded)
        list.setNotice(notice?.let(::getString), retry = state.problem != null)
        renderProblem(state)
    }

    /**
     * A failed read over a list that is still shown. The stream retries on its own and clears the
     * problem each time it tries, so the line stays up until a read actually succeeds rather than
     * blinking with every attempt. A manual refresh in progress shows its own spinner instead.
     */
    private fun renderProblem(state: TaskDataState) {
        val failure = state.problem?.takeIf { it != ConversationProblem.STORAGE }
        if (failure != null) {
            problem = failure
            problemEpoch = state.listReadsEpoch
            problemReads = state.listReads
        } else if (problem != null && readSinceProblem(state)) {
            problem = null
        }
        val text = problem?.takeIf { !refreshing }?.let { taskListProblem(it, state.connection) }
        list.setProblem(text?.let(::getString))
    }

    /**
     * A list read has succeeded since the failure. Counts compare only within one epoch: after a
     * new session or a new process, the count starts again, so any read under it is newer.
     */
    private fun readSinceProblem(state: TaskDataState): Boolean =
        if (state.listReadsEpoch == problemEpoch) state.listReads > problemReads else state.listReads > 0

    private fun retry() {
        if (refreshing) return
        list.setRefreshing(true)
        refresh()
    }

    /** One refresh at a time, whether pulled or retried. */
    private fun refresh() {
        if (refreshing) return
        refreshing = true
        renderProblem(repository.state.value)
        lifecycleScope.launch {
            try {
                repository.refresh()
                // A stream stopped by a permanent error resumes only when asked.
                if (repository.state.value.connection == Connection.PAUSED) repository.reconnect()
            } finally {
                refreshing = false
                list.setRefreshing(false)
                renderProblem(repository.state.value)
            }
        }
    }

    private fun loadMore() {
        val state = repository.state.value
        if (!state.hasMore || state.loading || loadingMore) return
        loadingMore = true
        lifecycleScope.launch {
            try { repository.loadMore() } finally { loadingMore = false }
        }
    }

    /**
     * The server decides; the card only offered the swipe because it said the task may go. The
     * card stays hidden until the answer: an archived task has left the snapshot by then, and
     * any other answer brings it back with a note saying why.
     */
    private fun archive(taskId: String) {
        lifecycleScope.launch {
            val result = repository.archive(taskId)
            // The repository has published the outcome; show it before un-hiding the card, so an
            // archived card does not flash back while the state flow catches up.
            render(repository.state.value)
            list.archiveFinished(taskId)
            archiveNotice(result)?.let { Toast.makeText(this@TaskListActivity, it, Toast.LENGTH_SHORT).show() }
        }
    }

    private companion object {
        const val STATE_GROUP = "tasks.group"
        const val STATE_LIST = "tasks.list"
        const val STATE_PROBLEM = "tasks.problem"
        const val STATE_PROBLEM_READS = "tasks.problemReads"
        const val STATE_PROBLEM_EPOCH = "tasks.problemEpoch"
    }
}
