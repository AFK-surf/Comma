package surf.comma.android.tasks.ui

import android.view.View
import androidx.annotation.MainThread
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.MessagePart
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.TaskDataState

/**
 * Keeps one request standing with the shared task data layer across session changes.
 *
 * [send] returns false when the data layer did not take the request (it had not switched to the
 * new session yet, or the read failed). The request is sent again for each new value, each new
 * session in [sessions], and, until it is taken, whenever the data layer publishes a new state.
 */
@MainThread
internal class TaskDemand<T : Any>(
    private val sessions: StateFlow<Any?>,
    private val states: StateFlow<TaskDataState>,
    private val send: suspend (T) -> Boolean,
) {
    private val value = MutableStateFlow<T?>(null)
    private var taken: Pair<T, Any>? = null

    /** Called with each value the data layer took, under the session it was taken for. */
    var onTaken: ((T) -> Unit)? = null

    fun update(next: T) {
        value.value = next
    }

    suspend fun run(onSession: (Any?) -> Unit = {}, onState: (TaskDataState) -> Unit = {}) = coroutineScope {
        val pokes = Channel<Unit>(Channel.CONFLATED)
        launch { value.collect { pokes.send(Unit) } }
        launch {
            var previous: Any? = Unset
            sessions.collect { session ->
                if (session !== previous) {
                    // The first session seen is the page's own; only later ones are changes.
                    if (previous !== Unset) onSession(session)
                    previous = session
                    pokes.send(Unit)
                }
            }
        }
        launch {
            states.collect { state ->
                onState(state)
                if (!isTaken()) pokes.send(Unit)
            }
        }
        for (ignored in pokes) {
            val next = value.value ?: continue
            val session = sessions.value ?: continue
            if (isTaken()) continue
            if (send(next) && sessions.value === session) {
                taken = next to session
                onTaken?.invoke(next)
            }
        }
    }

    private fun isTaken(): Boolean {
        val current = taken ?: return false
        return current.first == value.value && current.second === sessions.value
    }

    private object Unset
}

/**
 * Canonical summaries for the task references one page shows.
 *
 * The page reports the IDs its messages reference ([track]); the shared task data layer reads
 * them in batches and keeps them current from the group's single invalidation stream. Cards
 * never poll a task themselves: they look their task up here and are told when anything changes.
 * Cards find the directory through the view tree ([install], [find]).
 *
 * [sessions] is the signed-in session; a new one (another account, or signing in again) forgets
 * everything learned under the previous one.
 */
@MainThread
class TaskRefDirectory(
    sessions: StateFlow<Any?>,
    states: StateFlow<TaskDataState>,
    demand: suspend (List<String>) -> Boolean,
) {
    private val requests = TaskDemand(sessions, states, demand)
    private val listeners = LinkedHashSet<() -> Unit>()
    /** IDs the server has answered for in this session; absent ones are not tasks. */
    private val confirmed = HashSet<String>()
    private var summaries: Map<String, TaskSummary> = emptyMap()

    /** A card was tapped. */
    var onOpenTask: ((String) -> Unit)? = null

    init {
        requests.onTaken = { ids ->
            confirmed += ids
            notifyListeners()
        }
    }

    fun summary(taskId: String): TaskSummary? = summaries[taskId]

    /** The server answered and has no such task (or it is not a task). */
    fun isMissing(taskId: String): Boolean = taskId in confirmed && taskId !in summaries

    /** The IDs referenced by what the page shows now. Order and duplicates do not matter. */
    fun track(taskIds: List<String>) = requests.update(taskIds.distinct())

    fun open(taskId: String) {
        onOpenTask?.invoke(taskId)
    }

    fun addListener(listener: () -> Unit) {
        listeners += listener
    }

    fun removeListener(listener: () -> Unit) {
        listeners -= listener
    }

    /** Follows the data layer until cancelled; run it while the page is started. */
    suspend fun run() = requests.run(
        onSession = {
            confirmed.clear()
            summaries = emptyMap()
            notifyListeners()
        },
        onState = { state ->
            if (state.summaries != summaries) {
                summaries = state.summaries
                notifyListeners()
            }
        },
    )

    private fun notifyListeners() {
        listeners.toList().forEach { it() }
    }

    fun install(view: View) = view.setTag(R.id.task_ref_directory, this)

    companion object {
        /** The directory installed on [view] or its nearest ancestor that has one. */
        fun find(view: View): TaskRefDirectory? {
            var current: Any? = view
            while (current is View) {
                (current.getTag(R.id.task_ref_directory) as? TaskRefDirectory)?.let { return it }
                current = current.parent
            }
            return null
        }
    }
}

/**
 * Every task a transcript shows a card for, in order of appearance: inline task chips that can be
 * opened, then block references, message by message. Unlike the conversation's own task panel,
 * this includes references in user messages, since those are shown as cards too.
 */
fun referencedTaskIds(messages: List<ChatMessage>): List<String> = messages.flatMap { message ->
    message.parts.mapNotNull { (it as? MessagePart.TaskChip)?.takeUnless { chip -> chip.unavailable }?.conversationId } +
        message.refs.map { it.conversationId }
}.filter { it.isNotBlank() }.distinct()
