package surf.comma.android.tasks.pages

import android.content.res.Configuration
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.core.view.doOnLayout
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.chat.live.LiveLabels
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageBriefLabels
import surf.comma.android.chat.render.codeLabels
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.codeSyntaxTheme
import surf.comma.android.conversation.ConversationState
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskDetailState
import surf.comma.android.tasks.ui.TaskDetailView
import surf.comma.android.tasks.ui.TaskRefCardLayout
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.UiSansTypeface
import surf.comma.android.tasks.ui.TaskRefDirectory
import surf.comma.android.tasks.ui.TaskStrings
import surf.comma.android.tasks.ui.referencedTaskIds
import surf.comma.android.ui.MessageActionsPopup
import kotlin.coroutines.resume

/**
 * One task, read only: its title in the bar, then one list drawn by the chat's own renderer: the
 * task's status line, its brief folded into a card, and its conversation. Messages come from the
 * shared data layer's paged reads of this one task; older pages load when the top comes near.
 * There is no composer and no per-task stream.
 *
 * The same pane is the full task page and the body of the chat's task sheet ([sheet]).
 */
internal class TaskDetailPane(
    private val activity: ComponentActivity,
    val taskId: String,
    private val repository: ServerTaskRepository,
    sessions: StateFlow<Any?>,
    sheet: Boolean = false,
) {
    val view = TaskDetailView(activity, sheet)
    val timeline = ChatTimelineView(activity).apply { clipToPadding = false }
    private val strings = TaskStrings(activity)
    private val precomputer = MessageLayoutPrecomputer(
        sideMarginDp = PAGE_GUTTER_DP,
        briefLabels = MessageBriefLabels(
            title = activity.getString(R.string.task_brief_title),
            showAll = activity.getString(R.string.task_brief_show_all),
            showLess = activity.getString(R.string.task_brief_show_less),
        ),
        // Read only: an Agent's question shows as its receipt here.
        cardHeights = TaskRefCardLayout(TaskTheme(activity), activity.getString(R.string.chat_task_ref), UiSansTypeface)
            .then(surf.comma.android.chat.live.QuestionCardLayout(activity, interactive = false)),
    )
    private val refs = TaskRefDirectory(sessions, repository.state) { ids -> repository.setConversationTaskIds(refsKey(), ids) }
    private val labels = LiveLabels(
        interactiveUnavailable = activity.getString(R.string.chat_interactive_unavailable),
        file = activity.getString(R.string.chat_file),
        replyErrorTitle = activity.getString(R.string.chat_reply_error_title),
        replyErrorDetail = activity.getString(R.string.chat_reply_error_detail),
    )
    /** Briefs the reader has opened, by row id. */
    private val expandedBriefs = MutableStateFlow<Set<Long>>(emptySet())
    private var prepared: List<PreparedChatMessage> = emptyList()
    /** A read of this task has finished, so an empty list really means no messages. */
    private var synced = false
    /** The status line is always a row, so emptiness is about the messages. */
    private var hasMessages = false
    private var shown: TaskDetailState? = null
    private var released = false

    /** A task card in this task's messages was tapped. */
    var onOpenTask: ((String) -> Unit)? = null

    /** Rows as last handed to the list, for tests. */
    internal val rows: List<PreparedChatMessage> get() = prepared

    init {
        refs.onOpenTask = { other -> if (other != taskId) onOpenTask?.invoke(other) }
        refs.install(timeline)
        view.messageArea.addView(timeline, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        view.onRetry = ::claim
        timeline.onLongPressMessage = MessageActionsPopup::show
        timeline.onCopyCode = { MessageActionsPopup.copyCode(activity, it) }
        timeline.onLoadOlderHistory = { activity.lifecycleScope.launch { repository.loadOlderDetail() } }
        timeline.onToggleBrief = { id ->
            expandedBriefs.value = expandedBriefs.value.let { if (id in it) it - id else it + id }
        }
        timeline.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) = updateScrolled()
        })
        timeline.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> updateScrolled() }
        view.setNotice(activity.getString(R.string.task_detail_loading))
    }

    /** What is already known about the task, e.g. from the card that opened it; shown at once. */
    fun preview(title: String?) {
        if (view.title.text.isNullOrEmpty()) view.setTitle(title)
    }

    /** Reads the task and follows it until cancelled. Run it while the host is started. */
    suspend fun run() = coroutineScope {
        claim()
        launch { refs.run() }
        awaitLaidOut()
        combine(
            repository.detail.filter { it.taskId == taskId }
                // Until this task's read lands, its status line and title show on their own.
                .onStart { if (repository.detail.value.taskId != taskId) emit(TaskDetailState(taskId)) },
            repository.observeTask(taskId).onEach { task -> task?.let { view.setTitle(strings.title(it)) } },
            repository.state.map { it.snapshot.labels }.distinctUntilChanged(),
            expandedBriefs,
        ) { detail, task, labels, expanded -> Shown(detail, task, labels, expanded) }
            .collect(::render)
    }

    /** The host is going away: let go of the read and of this pane's card references. */
    fun release() {
        if (released) return
        released = true
        TaskDetailOwner.release(this, repository)
        val repository = repository
        val key = refsKey()
        ProcessLifecycleOwner.get().lifecycleScope.launch { repository.setConversationTaskIds(key, emptyList()) }
        timeline.release()
    }

    /** Takes the read of this task, reading it again after a failure. */
    private fun claim() {
        val opening = TaskDetailOwner.claim(this, taskId, repository)
        if (opening == null) {
            synced = true
            updateNotice()
            return
        }
        synced = false
        updateNotice()
        activity.lifecycleScope.launch {
            opening.join()
            synced = true
            updateNotice()
        }
    }

    private class Shown(val detail: TaskDetailState, val task: TaskSummary?, val labels: List<TaskLabel>, val expanded: Set<Long>)

    private suspend fun render(shown: Shown) {
        val detail = shown.detail
        val state = ConversationState(conversationId = taskId, timeline = detail.timeline, hasOlder = detail.hasOlder)
        val rows = withContext(Background.compute) {
            taskDetailRows(mapConversation(state, labels), detail.timeline, shown.task, shown.labels, strings, shown.expanded)
        }
        refs.track(referencedTaskIds(detail.timeline.map { it.message }))
        val next = precomputer.prepareChanged(
            previous = prepared, messages = rows, viewportWidthPx = timeline.width,
            density = activity.resources.displayMetrics.density, fontScale = activity.resources.configuration.fontScale,
            darkTheme = isDark(), syntaxTheme = codeSyntaxTheme(activity), palette = ChatPalette.from(activity),
            codeLabels = codeLabels(activity),
        )
        prepared = next
        timeline.hasMoreHistory = detail.hasOlder && !detail.loading
        suspendCancellableCoroutine { continuation ->
            timeline.submitPrepared(next) { if (continuation.isActive) continuation.resume(Unit) }
        }
        this.shown = detail
        hasMessages = detail.timeline.isNotEmpty()
        // With nothing but the status line, it belongs under the title, not at the list's foot.
        timeline.stacksFromEnd = hasMessages
        updateNotice()
    }

    private fun updateNotice() {
        val detail = shown
        val notice = taskDetailNotice(detail?.problem, loading = !synced || detail == null, empty = !hasMessages)
        view.setNotice(notice?.let(activity::getString), retry = notice != null && taskDetailRetryable(detail?.problem))
    }

    private fun updateScrolled() = view.setScrolled(timeline.canScrollVertically(-1))

    private fun refsKey() = "task-detail:$taskId#refs:${System.identityHashCode(this)}"

    private suspend fun awaitLaidOut() {
        if (timeline.isLaidOut && timeline.width > 0) return
        suspendCancellableCoroutine { continuation ->
            timeline.doOnLayout { if (continuation.isActive) continuation.resume(Unit) }
        }
    }

    private fun isDark() = activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
        Configuration.UI_MODE_NIGHT_YES

    private companion object {
        /** DESIGN §4's page gutter, shared with the bar and the status line. */
        const val PAGE_GUTTER_DP = 16f
    }
}
