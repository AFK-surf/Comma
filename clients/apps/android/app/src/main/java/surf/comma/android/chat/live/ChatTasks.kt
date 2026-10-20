package surf.comma.android.chat.live

import android.view.View
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskGraph
import surf.comma.android.tasks.pages.TaskPages
import surf.comma.android.tasks.ui.TaskDemand
import surf.comma.android.tasks.ui.TaskRefDirectory
import surf.comma.android.tasks.ui.referencedTaskIds

/**
 * The main chat's task surface, fed by the shared task data layer: task cards in the transcript,
 * through a [TaskRefDirectory] installed on the timeline.
 *
 * The full list lives in the sidebar. Nothing here reads a task on a timer: the data layer's one
 * group stream keeps it all current.
 */
internal class ChatTasks(
    private val activity: ComponentActivity,
    private val owner: androidx.lifecycle.LifecycleOwner = activity,
    /** Reference key for the cards on this chat page, apart from the conversation's own task list. */
    private val cardRefs: String = "chat#cards",
    private val sessions: StateFlow<Any?> = AuthGraph.get(activity).conversationScope,
    private val repository: ServerTaskRepository = TaskGraph.get(activity, AuthGraph.get(activity)),
) {
    private val refs = TaskRefDirectory(sessions, repository.state) { ids -> repository.setConversationTaskIds(cardRefs, ids) }
    /** The conversation shown and its canonical messages; streaming drafts do not count. */
    private val transcript = MutableStateFlow<Pair<String, List<ChatMessage>>?>(null)
    /** Hands the transcript to the data layer, again for each new session. */
    private val created = TaskDemand<Pair<String, List<ChatMessage>>>(sessions, repository.state) { (id, messages) ->
        repository.setConversationMessages(id, messages)
    }

    /**
     * A task card in the transcript was tapped, with what the card shows about it. Unset, the
     * task opens as a full page.
     */
    var onOpenCard: ((taskId: String, known: TaskSummary?) -> Unit)? = null

    init {
        refs.onOpenTask = { id -> onOpenCard?.invoke(id, refs.summary(id)) ?: openTask(id) }
    }

    fun openTask(taskId: String) = TaskPages.openDetail(activity, taskId)

    /** [timeline] gets the directory its task cards look up. */
    fun attach(timeline: View) {
        refs.install(timeline)
    }

    /** Each state the chat renders. Only a change in canonical messages reaches the data layer. */
    fun onConversation(state: ConversationState) {
        val conversationId = state.conversationId ?: return
        val messages = state.timeline.mapNotNull { (it as? TimelineEntry.Message)?.message }
        val next = conversationId to messages
        // Streaming updates leave the canonical messages alone; those do not reach the data layer.
        if (transcript.value == next) return
        transcript.value = next
        created.update(next)
        refs.track(referencedTaskIds(messages))
    }

    fun bind() {
        owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { refs.run() }
                launch { created.run() }
            }
        }
    }

    /** The chat page is gone: its references no longer need their tasks kept current. */
    fun release() {
        val conversationId = transcript.value?.first
        val repository = repository
        ProcessLifecycleOwner.get().lifecycleScope.launch {
            repository.setConversationTaskIds(cardRefs, emptyList())
            conversationId?.let { repository.setConversationTaskIds(it, emptyList()) }
        }
    }
}
