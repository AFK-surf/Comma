package surf.comma.android.inbox

import android.content.res.ColorStateList
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.shell.Shell
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.Checkbox
import surf.comma.android.tasks.list.FilterChoices
import surf.comma.android.tasks.list.FilterSheet
import surf.comma.android.tasks.list.SwipeAction
import surf.comma.android.tasks.list.SwipeRow
import surf.comma.android.tasks.list.TaskListFilter
import surf.comma.android.tasks.list.TaskRowView
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CapsuleButton
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.Row
import surf.comma.android.ui.kit.RowsAdapter
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.pressedFill
import surf.comma.android.ui.kit.selectionTick
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.wireMillis
import java.util.Calendar

/**
 * The Inbox tab: Tasks that finished or need the member's review, newest first by day. Read, unread and cleared
 * are this device's marks, as on the desktop. A row opens its Task, swipes read, clear or mark it done, and the
 * toolbar filters the list or acts on every row it shows. Tapping the tab again scrolls to the top.
 */
class InboxPage(private val shell: Shell) : LinearLayout(shell.activity) {
    private val activity = shell.activity
    private val store = shell.store
    private val adapter = RowsAdapter()
    private val list = RecyclerView(activity).apply {
        id = R.id.inbox_list
        layoutManager = LinearLayoutManager(activity)
        adapter = this@InboxPage.adapter
        clipToPadding = false
        itemAnimator = surf.comma.android.scroll.widget.DefaultItemAnimator()
    }
    private val empty = EmptyStateView(activity).apply { isVisible = false }
    private val filterCount: TextView = activity.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply { fontFeatureSettings = "tnum" }
    private val bar = FrameLayout(activity)
    private var filter = InboxProjection.DEFAULT_FILTER
        set(value) {
            if (field != value) fillPages = 0
            field = value
        }
    private var unreadOnly = false
        set(value) {
            if (field != value) fillPages = 0
            field = value
        }
    private var filterSheet: FilterSheet? = null
    private var workspaceId: String? = null
    private var fillPages = 0

    init {
        orientation = VERTICAL
        setBackgroundColor(activity.getColor(R.color.token_bg_primary))
        bar.addView(activity.label(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply {
            setText(R.string.inbox_title)
            isAccessibilityHeading = true
        }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        val tools = LinearLayout(activity).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            glass(elevated = false)
            addView(LinearLayout(activity).apply {
                orientation = HORIZONTAL
                gravity = Gravity.CENTER
                minimumWidth = activity.dp(44)
                setPadding(activity.dp(12), 0, activity.dp(6), 0)
                addView(icon(R.drawable.ic_list_filter))
                addView(filterCount, LayoutParams(-2, -2).apply { marginStart = activity.dp(4) })
                contentDescription = activity.getString(R.string.home_filters)
                tactile(0.92f)
                setOnClickListener { openFilters() }
            }, LayoutParams(-2, activity.dp(44)))
            addView(FrameLayout(activity).apply {
                setPadding(activity.dp(6), 0, activity.dp(12), 0)
                minimumWidth = activity.dp(44)
                addView(icon(R.drawable.ic_inbox_actions), FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
                contentDescription = activity.getString(R.string.inbox_actions)
                tactile(0.92f)
                setOnClickListener { bulkMenu(it) }
            }, LayoutParams(-2, activity.dp(44)))
        }
        bar.addView(tools, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, activity.dp(44), Gravity.CENTER_VERTICAL or Gravity.END).apply {
            marginEnd = activity.dp(16)
        })
        addView(bar, LayoutParams(LayoutParams.MATCH_PARENT, activity.dp(56)))
        addView(FrameLayout(activity).apply {
            addView(list)
            addView(empty)
        }, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) { if (!list.canScrollVertically(1)) loadMore() }
        })
        bind()
    }

    private fun icon(res: Int) = ImageView(activity).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_primary))
        layoutParams = LayoutParams(activity.dp(20), activity.dp(20))
    }

    private fun bind() {
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch { combine(store.tasks.state, store.pinned, store.inboxMarks) { _, _, _ -> }.collect { render() } }
                // The compact ages move on by the minute.
                launch { while (true) { delay(60_000); render(force = true) } }
                launch {
                    // Collecting again on each return to the foreground re-reads the same workspace, which keeps its filter.
                    store.auth.state.collect { state ->
                        val id = (state as? AuthState.Connected)?.selection?.workspace?.id
                        if (id != workspaceId) {
                            workspaceId = id
                            // A new workspace opens on the default filter again.
                            filter = InboxProjection.DEFAULT_FILTER
                            unreadOnly = false
                            render()
                        }
                    }
                }
            }
        }
    }

    fun setInsets(top: Int, bottom: Int) {
        (bar.layoutParams as LayoutParams).topMargin = top
        list.setPadding(0, 0, 0, bottom + activity.dp(12))
        empty.setPadding(0, 0, 0, bottom)
        requestLayout()
    }

    fun reselected() = list.smoothScrollToPosition(0)

    private val marks get() = store.inboxMarks.value
    private val tasks get() = store.tasks.state.value.snapshot.tasks

    private val appliedCount get() = listOf(filter.statuses != InboxProjection.DEFAULT_FILTER.statuses, filter.origins != null, unreadOnly).count { it }

    private var minute = 0L

    private fun render(force: Boolean = false) {
        if (force) minute = System.currentTimeMillis() / 60_000
        val state = store.tasks.state.value
        val rows = InboxProjection.rows(tasks, marks, filter, unreadOnly)
        val now = System.currentTimeMillis()
        val out = mutableListOf<Row>()
        var day: Long? = null
        rows.forEach { task ->
            val start = startOfDay(wireMillis(task.changedAt))
            if (start != day) {
                day = start
                out += Row("day:$start", TYPE_DAY, start, create = {
                    activity.label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
                        isAccessibilityHeading = true
                        setPadding(activity.dp(20), activity.dp(16), activity.dp(20), activity.dp(8))
                    }
                }) { view -> (view as TextView).text = dayTitle(start) }
            }
            val unread = marks.isUnread(task)
            val pinned = task.id in store.pinned.value
            val age = TaskRowView.age(activity, wireMillis(task.changedAt), now)
            out += Row("task:${task.id}", TYPE_TASK, listOf(task, unread, pinned, age), create = ::taskRow) { view ->
                bindRow(view as SwipeRow, task, unread, pinned, age)
            }
        }
        val filling = state.hasMore && (state.loading || needsMore(rows.size))
        val loading = filling || !(state.listLoaded || state.problem != null)
        if (loading) out += Row("footer", TYPE_FOOTER, minute, create = {
            FrameLayout(activity).apply {
                minimumHeight = activity.dp(56)
                addView(android.widget.ProgressBar(activity), FrameLayout.LayoutParams(activity.dp(24), activity.dp(24), Gravity.CENTER))
            }
        }) else if (state.hasMore) out += Row("more", TYPE_MORE, null, create = {
            // Past the pages read by themselves, older Tasks are read when the member asks.
            FrameLayout(activity).apply {
                minimumHeight = activity.dp(60)
                addView(CapsuleButton(activity, activity.getString(R.string.home_load_more)).apply {
                    setOnClickListener { activity.lifecycleScope.launch { store.tasks.loadMore() } }
                }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
            }
        })
        adapter.show(out) { list.post { if (!list.canScrollVertically(1)) loadMore() } }
        filterCount.isVisible = appliedCount > 0
        filterCount.text = appliedCount.toString()
        empty.isVisible = rows.isEmpty() && !loading && !state.hasMore
        if (empty.isVisible) bindEmpty()
    }

    /** A full list reads on at its end; a short one reads at most [FILL_LIMIT] pages per filter by itself, as on Home. */
    private fun needsMore(visible: Int): Boolean = store.tasks.state.value.hasMore && (visible >= FILL_TARGET || fillPages < FILL_LIMIT)

    private fun loadMore() {
        val state = store.tasks.state.value
        val visible = InboxProjection.rows(tasks, marks, filter, unreadOnly).size
        if (state.loading || !needsMore(visible)) return
        if (visible < FILL_TARGET) fillPages++
        activity.lifecycleScope.launch { store.tasks.loadMore() }
    }

    private fun bindEmpty() {
        val state = store.tasks.state.value
        if (state.problem != null && tasks.isEmpty()) {
            empty.show(R.drawable.ic_warning_triangle, activity.getString(R.string.home_tasks_failed),
                activity.getString(R.string.home_tasks_failed_detail), activity.getString(R.string.shell_try_again) to { store.refresh(); Unit })
            return
        }
        val clear = activity.getString(R.string.home_clear_filters) to { filter = InboxProjection.DEFAULT_FILTER; unreadOnly = false; render() }
        val hidesRead = unreadOnly && InboxProjection.rows(tasks, marks, filter).isNotEmpty()
        when (val reason = InboxProjection.emptyState(tasks, marks, filter)) {
            InboxEmptyState.NothingYet -> empty.show(R.drawable.ic_tab_inbox, activity.getString(R.string.inbox_empty_nothing),
                activity.getString(R.string.inbox_empty_nothing_detail),
                *listOfNotNull(shell.notificationsOff()?.let { turnOn -> activity.getString(R.string.inbox_turn_on_notifications) to turnOn }).toTypedArray())
            InboxEmptyState.CaughtUp -> empty.show(R.drawable.ic_tab_inbox, activity.getString(R.string.inbox_empty_caught_up),
                activity.getString(if (hidesRead) R.string.inbox_empty_hides_read else R.string.inbox_empty_caught_up_detail),
                *listOfNotNull(if (hidesRead) clear else null).toTypedArray())
            is InboxEmptyState.Filtered -> empty.show(R.drawable.ic_list_filter, activity.getString(R.string.inbox_empty_filtered, reason.hidden), null, clear)
        }
    }

    private fun taskRow(parent: ViewGroup): View = SwipeRow(parent.context, TaskRowView(parent.context)).apply {
        layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT).apply {
            marginStart = activity.dp(10); marginEnd = activity.dp(10); topMargin = activity.dp(1); bottomMargin = activity.dp(1)
        }
    }

    private fun bindRow(swipe: SwipeRow, task: TaskSummary, unread: Boolean, pinned: Boolean, age: String) {
        val row = swipe.row as TaskRowView
        row.bind(task, pinned, unread = unread, age = age)
        row.setOnClickListener {
            store.changeMarks { it.markRead(listOf(task)) }
            store.openTask(task.id)
        }
        row.setOnLongClickListener {
            shell.actions.menu(task, leading = {
                item(activity.getString(if (unread) R.string.inbox_mark_read else R.string.inbox_mark_unread), R.drawable.ic_inbox_mark_unread) { toggleRead(task) }
                item(activity.getString(R.string.inbox_clear), R.drawable.ic_inbox_clear) { clear(listOf(task)) }
            }, archiveChanged = ::archived).show(it, haptic = true)
            true
        }
        val read = SwipeAction(activity.getString(if (unread) R.string.inbox_read else R.string.inbox_unread), R.drawable.ic_inbox_mark_unread,
            activity.getColor(R.color.token_bg_brand_solid), android.graphics.Color.WHITE) { toggleRead(task) }
        val clear = SwipeAction(activity.getString(R.string.inbox_clear), R.drawable.ic_inbox_clear,
            activity.getColor(R.color.token_border_primary), activity.getColor(R.color.token_text_primary)) { clear(listOf(task)) }
        swipe.setActions(listOf(read), listOfNotNull(clear, shell.actions.doneSwipe(task)), fullLeading = true, fullTrailing = true)
    }

    private fun toggleRead(task: TaskSummary) =
        store.changeMarks { if (it.isUnread(task)) it.markRead(listOf(task)) else it.markUnread(listOf(task)) }

    /** Hides rows until their Tasks update again, with Undo; nothing on the server changes. */
    private fun clear(rows: List<TaskSummary>) {
        if (rows.isEmpty()) return
        store.changeMarks { it.clear(rows) }
        store.showToast(if (rows.size > 1) activity.getString(R.string.inbox_cleared_many, rows.size) else activity.getString(R.string.inbox_cleared),
            undo = { store.changeMarks { it.undoClear(rows) } })
    }

    /** An archive from the menu, with Undo. */
    private fun archived(task: TaskSummary) {
        store.showToast(activity.getString(R.string.task_archived_toast), undo = { store.setArchived(task, false) })
    }

    private fun bulkMenu(anchor: View) {
        val rows = InboxProjection.rows(tasks, marks, filter, unreadOnly)
        val read = rows.filterNot(marks::isUnread)
        ActionMenu(activity)
            .item(activity.getString(R.string.inbox_mark_all_read), R.drawable.ic_inbox_mark_unread, enabled = read.size != rows.size) {
                store.changeMarks { it.markRead(rows) }
            }
            .item(activity.getString(R.string.inbox_clear_read), R.drawable.ic_inbox_clear, enabled = read.isNotEmpty()) { clear(read) }
            .item(activity.getString(R.string.inbox_clear_all), R.drawable.ic_inbox_clear, destructive = true, enabled = rows.isNotEmpty()) {
                ConfirmDialog(activity, activity.getString(R.string.inbox_clear_all_confirm), activity.getString(R.string.inbox_clear_all_detail),
                    activity.getString(R.string.inbox_clear_all), destructive = true) { clear(rows) }.show()
            }
            .show(anchor)
    }

    /** Status and Platform, with Unread only above them. Changes apply to the list behind as they are made. */
    private fun openFilters() {
        val state = store.tasks.state.value
        filterSheet = FilterSheet(activity, filter, listOf(TaskListFilter.Field.STATUS, TaskListFilter.Field.PLATFORM),
            FilterChoices(activity, InboxProjection.listed(tasks, marks), state.snapshot.labels), onChange = { filter = it; render() },
            leading = { sheet ->
                listOf(LinearLayout(activity).apply {
                    orientation = HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    minimumHeight = activity.dp(50)
                    setPadding(activity.dp(14), activity.dp(6), activity.dp(14), activity.dp(6))
                    addView(Checkbox(activity, unreadOnly), LayoutParams(activity.dp(20), activity.dp(20)))
                    addView(ImageView(activity).apply {
                        setImageResource(R.drawable.ic_inbox_mark_unread)
                        imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_secondary))
                    }, LayoutParams(activity.dp(18), activity.dp(18)).apply { marginStart = activity.dp(12) })
                    addView(activity.label(Level.REGULAR, R.color.token_text_primary).apply { setText(R.string.filter_unread_only) },
                        LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(10) })
                    isSelected = unreadOnly
                    pressedFill()
                    setOnClickListener {
                        it.selectionTick()
                        unreadOnly = !unreadOnly
                        render()
                        sheet.refresh()
                    }
                })
            }).apply {
            onDismissed = { filterSheet = null }
            show()
        }
    }

    /** Today, Yesterday, then the date; the year only when it is not this year's. */
    private fun dayTitle(start: Long): String {
        val today = startOfDay(System.currentTimeMillis())
        return when (start) {
            today -> activity.getString(R.string.inbox_today)
            today - DAY -> activity.getString(R.string.inbox_yesterday)
            else -> DateUtils.formatDateTime(activity, start, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH)
        }
    }

    private fun startOfDay(millis: Long): Long = Calendar.getInstance().apply {
        timeInMillis = millis
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private companion object {
        const val DAY = 24 * 60 * 60 * 1000L
        const val TYPE_DAY = 1
        const val TYPE_TASK = 2
        const val TYPE_FOOTER = 3
        const val TYPE_MORE = 4
        const val FILL_TARGET = 20
        const val FILL_LIMIT = 5
    }
}
