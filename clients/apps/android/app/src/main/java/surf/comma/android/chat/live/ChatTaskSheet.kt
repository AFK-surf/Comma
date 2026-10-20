package surf.comma.android.chat.live

import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskGraph
import surf.comma.android.tasks.pages.TaskDetailPane
import surf.comma.android.tasks.pages.TaskPages
import surf.comma.android.tasks.ui.TaskSheetLayout
import surf.comma.android.tasks.ui.TaskTheme

/**
 * A task opened from a card in the chat: the task's page in a sheet over the dimmed chat. It
 * opens at [OPEN_FRACTION] of the screen; dragging up takes it to full height, where it reads
 * like the full page, and dragging down, a tap on the dim or back closes it.
 *
 * The body is the task page's own [TaskDetailPane]. Inside it the list scrolls first; once the
 * list is at its top, pulling down moves the sheet (see [TaskSheetLayout]). The pane is built when
 * a card is tapped and let go when the sheet has closed, so the chat pays nothing for it until then.
 */
internal class ChatTaskSheet(
    private val activity: ComponentActivity,
    host: FrameLayout,
    private val sessions: StateFlow<Any?> = AuthGraph.get(activity).conversationScope,
    private val repository: ServerTaskRepository = TaskGraph.get(activity, AuthGraph.get(activity)),
) {
    val layout = TaskSheetLayout(activity, TaskTheme(activity), OPEN_FRACTION)
    private var pane: TaskDetailPane? = null
    private var following: Job? = null
    private val back = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = close()
    }

    /** The open task, or null. */
    val taskId: String? get() = pane?.taskId

    val isOpen: Boolean get() = layout.isOpen

    /** The pane on show; for tests. */
    internal val shown: TaskDetailPane? get() = pane

    init {
        host.addView(layout, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        layout.onClosed = ::dispose
        activity.onBackPressedDispatcher.addCallback(activity, back)
        activity.lifecycle.addObserver(LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_DESTROY) dispose()
        })
    }

    /** Opens [taskId], showing what the card already knows ([known]) until the task's read lands. */
    fun open(taskId: String, known: TaskSummary?) {
        val current = pane?.takeIf { it.taskId == taskId } ?: run {
            dispose()
            TaskDetailPane(activity, taskId, repository, sessions, sheet = true).also { next ->
                next.onOpenTask = { other -> TaskPages.openDetail(activity, other) }
                layout.setSheet(next.view, next.view.gripHeightPx)
                pane = next
                following = activity.lifecycleScope.launch {
                    activity.repeatOnLifecycle(Lifecycle.State.STARTED) { next.run() }
                }
            }
        }
        current.preview(known?.title)
        back.isEnabled = true
        layout.open()
    }

    fun close() = layout.close()

    /** The sheet has left the screen: stop following the task and let its read go. */
    private fun dispose() {
        back.isEnabled = false
        following?.cancel()
        following = null
        pane?.let { closing ->
            closing.release()
            layout.removeView(closing.view)
        }
        pane = null
    }

    private companion object {
        /** About 60% of the screen, with the chat still showing above. */
        const val OPEN_FRACTION = 0.6f
    }
}
