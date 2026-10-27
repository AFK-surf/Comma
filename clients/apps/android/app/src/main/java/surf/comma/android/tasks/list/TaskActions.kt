package surf.comma.android.tasks.list

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.text.InputType
import android.text.format.DateUtils
import android.view.View
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.FieldDialog
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.canArchive
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.Row
import surf.comma.android.ui.kit.RowsAdapter
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.TaskShare
import surf.comma.android.tasks.data.taskSummaryOf
import surf.comma.android.workspace.WorkspaceStore
import surf.comma.android.workspace.wireMillis
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView

/**
 * The Task actions every list and the open Task offer, with the desktop's glyphs: Mark as done for a Task in
 * review, Rename, Pin or Unpin, Share, then Archive or Restore. Rows also swipe to Archive and Mark as done. One the
 * core says a Task cannot take (`TaskSummary.unsupported`) is not offered.
 */
class TaskActions(private val activity: ComponentActivity, private val store: WorkspaceStore) {

    /** The menu for [task]. [leading] adds items above (the Inbox's read and clear); [archive] overrides Archive. */
    fun menu(task: TaskSummary, leading: ActionMenu.() -> Unit = {}, archiveChanged: (TaskSummary) -> Unit = {},
             archive: (() -> Unit)? = null): ActionMenu = ActionMenu(activity).apply {
        leading()
        divider()
        if (task.canAcceptReview) {
            item(activity.getString(R.string.task_action_done), R.drawable.ic_action_done) { store.acceptReview(task) }
            divider()
        }
        item(activity.getString(R.string.task_action_rename), R.drawable.ic_action_rename) { rename(task) }
        if (!task.isArchived && "pin" !in task.unsupported) {
            val pinned = task.id in store.pinned.value
            item(activity.getString(if (pinned) R.string.task_action_unpin else R.string.task_action_pin),
                if (pinned) R.drawable.ic_action_unpin else R.drawable.ic_action_pin) { store.setPinned(task.id, !pinned) }
        }
        if ("share" !in task.unsupported)
            item(activity.getString(R.string.task_action_share), R.drawable.ic_action_link) { ShareSheet(activity, store, task).show() }
        if ("archive" in task.unsupported) return@apply
        divider()
        if (task.isArchived) {
            item(activity.getString(R.string.task_action_restore), R.drawable.ic_action_restore) {
                store.setArchived(task, false, archiveChanged)
            }
        } else {
            item(archiveTitle(task), R.drawable.ic_list_archive, enabled = task.canArchive) {
                if (archive != null) archive() else store.setArchived(task, true, archiveChanged)
            }
        }
    }

    /** Archive, or why it is not available yet. */
    private fun archiveTitle(task: TaskSummary): String = when {
        task.canArchive -> activity.getString(R.string.task_action_archive)
        else -> activity.getString(R.string.task_archive_not_finished)
    }

    fun archiveSwipe(task: TaskSummary, done: (TaskSummary) -> Unit = {}): SwipeAction? = if ("archive" in task.unsupported) null else SwipeAction(
        activity.getString(R.string.task_action_archive), R.drawable.ic_list_archive,
        activity.getColor(R.color.token_bg_brand_solid), android.graphics.Color.WHITE, enabled = task.canArchive,
    ) { store.setArchived(task, true, done) }

    fun doneSwipe(task: TaskSummary): SwipeAction? = if (!task.canAcceptReview) null else SwipeAction(
        activity.getString(R.string.task_action_done), R.drawable.ic_action_done,
        activity.getColor(R.color.token_fg_success), android.graphics.Color.WHITE,
    ) { store.acceptReview(task) }

    fun rename(task: TaskSummary) {
        FieldDialog(activity, activity.getString(R.string.task_rename_title), activity.getString(R.string.task_rename_hint),
            task.title, activity.getString(R.string.shell_save),
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, maxLength = 200,
            onSave = { store.rename(task, it) }, keyboard = true).show()
    }
}

/**
 * Archived Tasks, read on demand. Rows match the Home list and show the status each Task was archived from;
 * swiping or the menu restores one to the task list. Choosing a row closes the sheet and opens the Task.
 */
internal class ArchivedTasksSheet(
    activity: ComponentActivity,
    private val store: WorkspaceStore,
    private val actions: TaskActions,
) : CommaSheet(activity, activity.getString(R.string.home_archived_tasks), Detent.LARGE) {
    private val adapter = RowsAdapter()
    private val list = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity)
        adapter = this@ArchivedTasksSheet.adapter
        clipToPadding = false
        setPadding(0, 0, 0, activity.dp(24))
    }
    private val empty = EmptyStateView(activity).apply { isVisible = false }
    private var tasks = emptyList<TaskSummary>()
    private var hasMore = false
    private var loaded = false
    private var loading = false
    private var failed = false
    private val workspace = store.workspace?.id
    private var following: kotlinx.coroutines.Job? = null
    /** Restored here: hidden before the core's list drops them. */
    private val restored = mutableSetOf<String>()

    init {
        val frame = android.widget.FrameLayout(activity).apply {
            addView(list)
            addView(empty)
        }
        setContent(frame)
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (!list.canScrollVertically(1)) more()
            }
        })
        follow()
    }

    private fun params() = org.json.JSONObject().apply { workspace?.let { put("workspace", it) } }

    /** Shows the archived list to the core, 50 at a time; restored Tasks leave it as the core reads it again. */
    private fun follow() {
        following = activity.lifecycleScope.launch {
            store.call { subscribe(params().put("topic", "archivedTasks")) { it as? org.json.JSONObject } }.collect { value ->
                val json = (value as? surf.comma.android.core.TopicValue.Value)?.value ?: return@collect
                val rows = json.optJSONArray("tasks")
                tasks = if (rows == null) emptyList() else (0 until rows.length()).mapNotNull { index ->
                    rows.optJSONObject(index)?.let(::taskSummaryOf)
                }.distinctBy { it.id }.filterNot { it.id in restored }
                hasMore = json.optBoolean("hasMore")
                loading = json.optBoolean("loading")
                failed = !json.isNull("error") && json.has("error")
                loaded = loaded || !loading
                render()
                // A page can come back with too few rows to scroll while more remain.
                if (hasMore && !loading && !list.canScrollVertically(1)) list.post { more() }
            }
        }
    }

    private fun more() {
        if (loading || !hasMore) return
        loading = true
        render()
        activity.lifecycleScope.launch {
            try {
                store.call { call("archivedTasks.more", params()) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // The topic never says loading for a page the core did not take: scrolling again asks again.
                loading = false
                render()
            }
        }
    }

    private fun retry() {
        activity.lifecycleScope.launch { runCatching { store.call { call("archivedTasks.refresh", params()) } } }
    }

    override fun onRemoved() {
        following?.cancel()
    }

    private fun render() {
        val rows = tasks.map { task ->
            Row("task:${task.id}", TYPE_TASK, task, create = { parent -> SwipeRow(parent.context, TaskRowView(parent.context)) }) { view ->
                val swipe = view as SwipeRow
                val row = swipe.row as TaskRowView
                row.bind(task, pinned = false)
                row.setOnClickListener { dismiss(); store.openTask(task.id) }
                row.setOnLongClickListener {
                    actions.menu(task, archiveChanged = ::remove).show(it, haptic = true); true
                }
                swipe.setActions(emptyList(), listOf(SwipeAction(activity.getString(R.string.task_action_restore), R.drawable.ic_action_restore,
                    activity.getColor(R.color.token_bg_brand_solid), android.graphics.Color.WHITE) {
                    store.setArchived(task, false, ::remove)
                }))
            }
        } + if (!loaded || hasMore) listOf(Row("footer", TYPE_FOOTER, loading, create = { parent ->
            android.widget.ProgressBar(parent.context).apply { setPadding(0, parent.dp(12), 0, parent.dp(12)) }
        })) else emptyList()
        adapter.show(rows)
        empty.isVisible = loaded && !hasMore && tasks.isEmpty()
        if (failed && tasks.isEmpty()) {
            empty.show(R.drawable.ic_warning_triangle, activity.getString(R.string.home_tasks_failed),
                activity.getString(R.string.home_tasks_failed_detail), activity.getString(R.string.shell_try_again) to { retry() })
            empty.isVisible = true
        } else {
            empty.show(R.drawable.ic_list_archive, activity.getString(R.string.task_no_archived), activity.getString(R.string.task_no_archived_detail))
        }
    }

    private fun remove(task: TaskSummary) {
        restored += task.id
        tasks = tasks.filterNot { it.id == task.id }
        render()
    }

    private companion object {
        const val TYPE_TASK = 1
        const val TYPE_FOOTER = 2
    }
}

/**
 * The owner's controls for a Task's public link: create, copy or send, include newer messages, replace, and
 * stop sharing. Anyone with the link can read the shared messages.
 */
internal class ShareSheet(
    activity: ComponentActivity,
    private val store: WorkspaceStore,
    private val task: TaskSummary,
) : CommaSheet(activity, activity.getString(R.string.share_title)) {
    private val page = SettingsPageLayout(activity, "", showBack = false) {}.apply {
        bar.isVisible = false
        setBackgroundColor(activity.getColor(R.color.token_card_primary))
    }
    private val loading = activity.label(Level.SMALL, R.color.token_text_quaternary).apply {
        text = activity.getString(R.string.settings_devices_loading)
        gravity = android.view.Gravity.CENTER
    }
    private val error = activity.label(Level.SMALL, R.color.token_text_error_primary, lines = 0).apply { isVisible = false }
    private val link = SettingsSection(activity, activity.getString(R.string.share_link))
    private val details = SettingsSection(activity, null)
    private val manage = SettingsSection(activity, null).footer(activity.getString(R.string.share_replace_footer))
    private val create = SettingsSection(activity, null)
    private var share: TaskShare? = null
    private var loaded = false
    private var busy = false
    private var copied = false

    init {
        page.section(SettingsSection(activity, null).add(activity.label(Level.REGULAR, R.color.token_text_primary, lines = 2).apply {
            text = task.title
            setPadding(activity.dp(14), activity.dp(14), activity.dp(14), activity.dp(14))
        }).footer(activity.getString(R.string.share_footer)), top = 0)
        page.section(loading)
        page.section(link)
        page.section(details)
        page.section(manage)
        page.section(create, top = 8)
        page.section(error)
        setContent(page)
        activity.lifecycleScope.launch {
            try { share = store.call { share(it, task.id) } } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) {
                error.text = activity.getString(R.string.app_failure_generic); error.isVisible = true
            }
            loaded = true
            render()
        }
        render()
    }

    private fun render() {
        val share = share
        loading.isVisible = !loaded
        link.isVisible = share != null
        details.isVisible = share != null
        manage.isVisible = share != null
        create.isVisible = loaded && share == null
        link.card.removeAllViews(); details.card.removeAllViews(); manage.card.removeAllViews(); create.card.removeAllViews()
        if (share == null) {
            create.add(SettingsRow(activity, R.drawable.ic_action_link, activity.getString(R.string.share_create), tint = R.color.token_bg_brand_solid)
                .onClick { perform { publishShare(it, task.id) } })
            return
        }
        link.add(activity.label(Level.SMALL, R.color.token_text_secondary, lines = 3).apply {
            text = share.url
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
            setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
        })
        link.add(SettingsRow(activity, R.drawable.ic_share_os, activity.getString(R.string.share_send)).onClick {
            activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, share.url), null))
        })
        link.add(SettingsRow(activity, if (copied) R.drawable.ic_action_check else R.drawable.ic_action_link,
            activity.getString(if (copied) R.string.share_copied else R.string.share_copy)).onClick {
            activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(task.title, share.url))
            copied = true
            it.performHapticFeedback(android.view.HapticFeedbackConstants.CONFIRM)
            render()
        })
        details.add(SettingsRow(activity, null, activity.getString(R.string.share_messages)).value(share.messageCount.toString()))
        if (share.artifactCount > 0) details.add(SettingsRow(activity, null, activity.getString(R.string.share_files)).value(share.artifactCount.toString()))
        details.add(SettingsRow(activity, null, activity.getString(R.string.share_shared)).value(
            DateUtils.getRelativeTimeSpanString(wireMillis(share.sharedAt), System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)))
        if (share.hasNewerMessages) {
            details.add(SettingsRow(activity, R.drawable.ic_arrow_rotate_cw, activity.getString(R.string.share_include_newer))
                .onClick { perform { publishShare(it, task.id) } })
        }
        details.footer(if (share.hasNewerMessages) activity.getString(R.string.share_newer_footer) else null)
        manage.add(SettingsRow(activity, R.drawable.ic_arrow_rotate_ccw, activity.getString(R.string.share_replace)).onClick {
            ConfirmDialog(activity, activity.getString(R.string.share_replace_confirm), activity.getString(R.string.share_replace_detail),
                activity.getString(R.string.share_replace), destructive = true) { perform { resetShare(it, task.id) } }.show()
        })
        manage.add(SettingsRow(activity, R.drawable.ic_circle_x, activity.getString(R.string.share_stop), tint = R.color.token_text_error_primary)
            .onClick { perform { revokeShare(it, task.id); null } })
        listOf(link, details, manage, create).forEach { section ->
            for (i in 0 until section.card.childCount) section.card.getChildAt(i).isEnabled = !busy
        }
    }

    private fun perform(block: suspend surf.comma.android.workspace.CommaApi.(surf.comma.android.auth.ConversationScope) -> TaskShare?) {
        if (busy) return
        busy = true
        copied = false
        error.isVisible = false
        render()
        activity.lifecycleScope.launch {
            try {
                share = store.call(block)
                store.refresh()
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (_: Exception) {
                error.text = activity.getString(R.string.app_failure_generic)
                error.isVisible = true
            } finally {
                busy = false
                render()
            }
        }
    }
}
