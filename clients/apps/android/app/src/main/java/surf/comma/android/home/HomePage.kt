package surf.comma.android.home

import android.content.res.ColorStateList
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.routines.PlatformRoutine
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.settings.SettingsGraph
import surf.comma.android.shell.Shell
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.FilterChoices
import surf.comma.android.tasks.list.FilterSheet
import surf.comma.android.tasks.list.SwipeRow
import surf.comma.android.tasks.list.TaskListFilter
import surf.comma.android.tasks.list.TaskRowView
import surf.comma.android.tasks.list.ArchivedTasksSheet
import surf.comma.android.tasks.list.placeholderTasks
import surf.comma.android.tasks.ui.TaskRefreshLayout
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.CapsuleButton
import surf.comma.android.ui.kit.Row
import surf.comma.android.ui.kit.RowsAdapter
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.util.Calendar

/**
 * The Home tab, as the iOS app's: a greeting, the connected apps as platform cards, then the member's Tasks for the
 * status chosen in the floating switcher, with filters and the archive beside the section title. Pull to refresh
 * reads the Tasks and the briefing; tapping the tab again scrolls back to the top.
 */
class HomePage(private val shell: Shell) : FrameLayout(shell.activity) {
    private val activity = shell.activity
    private val store = shell.store
    private val theme = TaskTheme(activity)
    private val adapter = RowsAdapter()
    private val list = RecyclerView(activity).apply {
        id = R.id.home_list
        layoutManager = LinearLayoutManager(activity)
        adapter = this@HomePage.adapter
        clipToPadding = false
        itemAnimator = null
    }
    private val refresh = TaskRefreshLayout(activity, theme)
    /** Frosts the rows that scroll under the floating status switcher. */
    private val frost = surf.comma.android.ui.widget.BackdropBlurLayout(activity)
    private val switcher = StatusSwitcher(activity).apply { id = R.id.home_switcher }
    private val greeting = Greeting()
    private val carousel = PlatformCarousel(activity, store) { platform -> openPlatform(platform) }
    private val header = SectionHeader()
    private val routineActions = RoutineActions(activity, usePrompt = shell::insertIntoRouter, openTask = store::openTask)

    /** What the list shows: the switcher and the filter sheet edit the same filter. Home opens on Needs review. */
    private var filter = INITIAL_FILTER
        set(value) {
            if (field != value) fillPages = 0
            field = value
        }
    private var fillPages = 0
    private var topInset = 0
    private var bottomReserve = 0
    private var filterSheet: FilterSheet? = null
    private var workspaceId: String? = null

    init {
        setBackgroundColor(activity.getColor(R.color.token_bg_primary))
        // The floating status switcher's shadow falls outside its own bounds.
        clipChildren = false
        refresh.setTarget(list)
        refresh.onRefresh = {
            store.refresh()
            activity.lifecycleScope.launch {
                store.routines.load()
                refresh.setRefreshing(false)
            }
        }
        frost.addView(refresh, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(frost, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(switcher, LayoutParams(LayoutParams.MATCH_PARENT, activity.dp(StatusSwitcher.HEIGHT_DP), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
            marginStart = activity.dp(16); marginEnd = activity.dp(16)
        })
        switcher.addOnLayoutChangeListener { v, l, t, r, b, _, _, _, _ ->
            frost.setFloatingPatch("switcher", if (v.visibility == VISIBLE) android.graphics.Rect(l, t, r, b) else null, (b - t) / 2f)
        }
        switcher.select(selectedBucket, animate = false)
        switcher.onSelect = { bucket ->
            filter = filter.copy(statuses = setOf(bucket))
            render(scrollTop = false)
            filterSheet?.refresh()
        }
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (!list.canScrollVertically(1)) loadMoreIfNeeded()
            }
        })
        bind()
    }

    private fun bind() {
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    combine(store.tasks.state, store.pinned) { _, _ -> }.collect {
                        // The cards count pre-tasks by their linked Tasks' state, which the briefing does not carry.
                        carousel.refreshCounts()
                        render()
                    }
                }
                launch {
                    combine(store.routines.feed, store.routines.failure, store.routines.requesting) { _, _, _ -> }.collect {
                        carousel.render()
                        greeting.render()
                        render()
                    }
                }
                launch { SettingsGraph.account(activity).state.collect { greeting.render() } }
                launch {
                    store.auth.state.collect { state ->
                        val id = (state as? AuthState.Connected)?.selection?.workspace?.id
                        if (id != workspaceId) {
                            workspaceId = id
                            // A new workspace opens on Needs review again.
                            filter = INITIAL_FILTER
                            switcher.select(selectedBucket, animate = false)
                            if (id != null) store.routines.reloadIfStale()
                        }
                        greeting.render()
                    }
                }
            }
        }
    }

    /** Home came on screen: a briefing a minute old is read again. */
    fun shown() = store.routines.reloadIfStale()

    /** The selected tab was tapped again: back to the top. */
    fun reselected() = list.smoothScrollToPosition(0)

    fun setInsets(top: Int, bottom: Int) {
        topInset = top
        bottomReserve = bottom
        list.setPadding(0, top, 0, bottom + activity.dp(StatusSwitcher.HEIGHT_DP + SWITCHER_GAP_DP * 2))
        (switcher.layoutParams as LayoutParams).bottomMargin = bottom + activity.dp(SWITCHER_GAP_DP)
        switcher.requestLayout()
    }

    /** The keyboard is up somewhere on Home: the switcher steps aside, as on iOS. */
    fun setKeyboardVisible(visible: Boolean) {
        switcher.isVisible = !visible
        if (visible) frost.setFloatingPatch("switcher", null, 0f)
    }

    private val selectedBucket: TaskStatusBucket?
        get() = filter.statuses?.singleOrNull()?.takeIf { it in TaskListFilter.STATUS_BUCKETS }

    private val appliedCount: Int get() = filter.narrowedFields.count { it != TaskListFilter.Field.STATUS }

    private fun title(): String {
        val statuses = filter.statuses ?: return activity.getString(R.string.home_all_tasks)
        return if (statuses.size == 1) theme.statusLabel(statuses.first()) else activity.getString(R.string.home_statuses, statuses.size)
    }

    private fun rows(): List<TaskSummary> {
        val state = store.tasks.state.value
        val labels = state.snapshot.labels.map { it.id }.toSet()
        val pinned = store.pinned.value
        val visible = state.snapshot.tasks.filter { !it.isArchived && filter.matches(it, labels) }
        return visible.filter { it.id in pinned } + visible.filterNot { it.id in pinned }
    }

    /** A full list reads on at its end; a short one reads at most [FILL_LIMIT] pages per filter by itself. */
    private fun needsMore(visible: Int): Boolean = store.tasks.state.value.hasMore && (visible >= FILL_TARGET || fillPages < FILL_LIMIT)

    private fun loadMoreIfNeeded() {
        val state = store.tasks.state.value
        val visible = rows().size
        if (state.loading || !needsMore(visible)) return
        if (visible < FILL_TARGET) fillPages++
        activity.lifecycleScope.launch { store.tasks.loadMore() }
    }

    private fun render(scrollTop: Boolean = false) {
        val state = store.tasks.state.value
        val tasks = rows()
        val pinned = store.pinned.value
        val filling = state.hasMore && (state.loading || needsMore(tasks.size))
        header.render()
        val out = mutableListOf(
            Row("greeting", TYPE_GREETING, null, create = { greeting.detach() }),
            Row("carousel", TYPE_CAROUSEL, null, create = { carousel.apply { (parent as? ViewGroup)?.removeView(this) } }),
            Row("header", TYPE_HEADER, null, create = { header.apply { (parent as? ViewGroup)?.removeView(this) } }),
        )
        val loaded = state.listLoaded || state.problem != null || state.cacheLoaded && state.snapshot.tasks.isNotEmpty()
        when {
            !loaded -> placeholderTasks(activity).forEach { task ->
                out += Row("placeholder:${task.id}", TYPE_TASK, task, create = ::taskRow) { view ->
                    val swipe = view as SwipeRow
                    (swipe.row as TaskRowView).bind(task, pinned = false, placeholder = true)
                    swipe.row.setOnClickListener(null)
                    swipe.row.setOnLongClickListener(null)
                    swipe.setActions(emptyList(), emptyList())
                }
            }
            state.problem != null && state.snapshot.tasks.isEmpty() -> out += Row("failed", TYPE_EMPTY, "failed", create = {
                EmptyStateView(activity).apply { minimumHeight = activity.dp(240) }
            }) { view ->
                (view as EmptyStateView).show(R.drawable.ic_warning_triangle, activity.getString(R.string.home_tasks_failed),
                    activity.getString(R.string.home_tasks_failed_detail), activity.getString(R.string.shell_try_again) to {
                        store.tasks.reconnect(); store.refresh(); Unit
                    })
            }
            tasks.isEmpty() && !filling -> out += Row("empty", TYPE_EMPTY, emptyKey(state.snapshot.tasks.isEmpty(), state.hasMore), create = {
                EmptyStateView(activity).apply { minimumHeight = activity.dp(240) }
            }) { view -> bindEmpty(view as EmptyStateView, state.snapshot.tasks.isEmpty(), state.hasMore) }
        }
        if (loaded) tasks.forEach { task ->
            val isPinned = task.id in pinned
            out += Row("task:${task.id}", TYPE_TASK, task to isPinned, create = ::taskRow) { view -> bindTask(view as SwipeRow, task, isPinned) }
        }
        if (loaded && state.hasMore && (filling || tasks.isNotEmpty())) {
            out += Row("footer", TYPE_FOOTER, filling, create = {
                FrameLayout(activity).apply { minimumHeight = activity.dp(60) }
            }) { view -> bindFooter(view as FrameLayout, filling) }
        }
        adapter.show(out) {
            if (scrollTop) list.scrollToPosition(0)
            list.post { if (!list.canScrollVertically(1)) loadMoreIfNeeded() }
        }
    }

    private fun emptyKey(noTasks: Boolean, more: Boolean) = Triple(noTasks, appliedCount, more to selectedBucket)

    private fun bindEmpty(view: EmptyStateView, noTasks: Boolean, more: Boolean) {
        val lookFurther = if (more) (activity.getString(R.string.home_look_further) to { activity.lifecycleScope.launch { store.tasks.loadMore() }; Unit }) else null
        when {
            noTasks -> view.show(R.drawable.ic_empty_planning, activity.getString(R.string.home_no_tasks),
                activity.getString(R.string.home_no_tasks_detail), activity.getString(R.string.home_message_comma) to { shell.openRouter(focus = true) })
            appliedCount > 0 -> view.show(R.drawable.ic_list_filter,
                activity.getString(if (more) R.string.home_no_recent_filtered_tasks else R.string.home_no_filtered_tasks), null,
                *listOfNotNull(lookFurther, activity.getString(R.string.home_clear_filters) to {
                    filter = TaskListFilter(statuses = filter.statuses); render(); header.render()
                }).toTypedArray())
            else -> view.show(null, activity.getString(if (more) R.string.home_no_recent_status_tasks else R.string.home_no_status_tasks),
                null, *listOfNotNull(lookFurther).toTypedArray())
        }
    }

    private fun bindFooter(view: FrameLayout, filling: Boolean) {
        view.removeAllViews()
        if (filling) view.addView(android.widget.ProgressBar(activity), LayoutParams(activity.dp(24), activity.dp(24), Gravity.CENTER))
        else view.addView(CapsuleButton(activity, activity.getString(R.string.home_load_more)).apply {
            setOnClickListener { activity.lifecycleScope.launch { store.tasks.loadMore() } }
        }, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    }

    private fun taskRow(parent: ViewGroup): View = SwipeRow(parent.context, TaskRowView(parent.context)).apply {
        layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT).apply {
            marginStart = activity.dp(10); marginEnd = activity.dp(10); topMargin = activity.dp(1); bottomMargin = activity.dp(1)
        }
    }

    private fun bindTask(swipe: SwipeRow, task: TaskSummary, pinned: Boolean) {
        val row = swipe.row as TaskRowView
        row.bind(task, pinned)
        row.setOnClickListener { store.openTask(task.id) }
        row.setOnLongClickListener { shell.actions.menu(task).show(it, haptic = true); true }
        swipe.setActions(emptyList(), listOfNotNull(shell.actions.archiveSwipe(task), shell.actions.doneSwipe(task)))
    }

    private fun openPlatform(platform: PlatformRoutine) = PreTaskSheet(activity, store, platform, routineActions).show()

    private fun openFilters() {
        val state = store.tasks.state.value
        filterSheet = FilterSheet(activity, filter, TaskListFilter.Field.entries, FilterChoices(activity, state.snapshot.tasks.filterNot { it.isArchived },
            state.snapshot.labels), onChange = { next ->
            filter = next
            switcher.select(selectedBucket)
            render()
        }).apply {
            onDismissed = { filterSheet = null }
            show()
        }
    }

    /**
     * Home's first row: a greeting for the time of day. Once the routine has anything to show, the greeting carries
     * a small chevron and opens the whole routine.
     */
    private inner class Greeting : LinearLayout(activity) {
        private val text = activity.label(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold, lines = 0)
        private val chevron = ImageView(activity).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_tertiary))
        }

        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(44)
            setPadding(activity.dp(20), activity.dp(8), activity.dp(20), 0)
            addView(text, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { weight = 0f })
            addView(chevron, LayoutParams(activity.dp(22), activity.dp(22)).apply { marginStart = activity.dp(2) })
            text.isAccessibilityHeading = true
            tactile(0.97f)
            setOnClickListener { RoutineSheet(activity, store, routineActions, store::openTask).show() }
            layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
        }

        fun detach(): View = apply { (parent as? ViewGroup)?.removeView(this) }

        fun render() {
            val name = firstName()
            text.alpha = if (name == null) 0f else 1f
            val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            text.text = activity.getString(when {
                hour < 12 -> R.string.home_greeting_morning
                hour < 18 -> R.string.home_greeting_afternoon
                else -> R.string.home_greeting_evening
            }, name.orEmpty())
            val feed = store.routines.feed.value
            val routine = feed != null && (feed.hasSnapshot || feed.platforms.isNotEmpty())
            chevron.isVisible = routine
            isClickable = routine
            stateDescription = if (routine) activity.getString(R.string.home_open_routine) else null
        }

        /** The first word of the member's name, else, once the profile has been read, the local part of their email. */
        private fun firstName(): String? {
            val settings = SettingsGraph.account(activity).state.value
            val account = (store.auth.state.value as? AuthState.Connected)?.account
            val name = settings.profile?.name?.takeIf { it.isNotBlank() } ?: account?.name?.takeIf { it.isNotBlank() }
            if (name != null) return name.trim().split(Regex("\\s+")).first()
            val email = settings.profile?.email ?: account?.email ?: return null
            return email.substringBefore('@')
        }
    }

    /** The section title, which names the statuses shown, and one glass capsule holding the filters and the archive. */
    private inner class SectionHeader : LinearLayout(activity) {
        private val title = activity.label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply { isAccessibilityHeading = true }
        private val count: TextView = activity.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply { fontFeatureSettings = "tnum" }

        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(20), activity.dp(12), activity.dp(16), activity.dp(4))
            addView(title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            val capsule = LinearLayout(activity).apply {
                orientation = HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                glass(elevated = false)
                addView(LinearLayout(activity).apply {
                    orientation = HORIZONTAL
                    gravity = Gravity.CENTER
                    minimumWidth = activity.dp(44)
                    setPadding(activity.dp(12), 0, activity.dp(8), 0)
                    addView(icon(R.drawable.ic_list_filter))
                    addView(count, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = activity.dp(4) })
                    contentDescription = activity.getString(R.string.home_filters)
                    tactile(0.92f)
                    setOnClickListener { openFilters() }
                }, LayoutParams(LayoutParams.WRAP_CONTENT, activity.dp(44)))
                addView(FrameLayout(activity).apply {
                    setPadding(activity.dp(8), 0, activity.dp(12), 0)
                    addView(icon(R.drawable.ic_list_archive), FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
                    minimumWidth = activity.dp(44)
                    contentDescription = activity.getString(R.string.home_archived_tasks)
                    tactile(0.92f)
                    setOnClickListener { ArchivedTasksSheet(activity, store, shell.actions).show() }
                }, LayoutParams(LayoutParams.WRAP_CONTENT, activity.dp(44)))
            }
            addView(capsule, LayoutParams(LayoutParams.WRAP_CONTENT, activity.dp(44)))
            layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
        }

        private fun icon(res: Int) = ImageView(activity).apply {
            setImageResource(res)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_primary))
            layoutParams = LayoutParams(activity.dp(20), activity.dp(20))
        }

        fun render() {
            title.text = title()
            count.isVisible = appliedCount > 0
            count.text = appliedCount.toString()
            (count.parent as View).stateDescription = if (appliedCount > 0) activity.getString(R.string.home_filters_applied, appliedCount) else null
        }
    }

    private companion object {
        val INITIAL_FILTER = TaskListFilter(statuses = setOf(TaskStatusBucket.NEEDS_REVIEW))
        const val FILL_TARGET = 20
        const val FILL_LIMIT = 5
        const val SWITCHER_GAP_DP = 12
        const val TYPE_GREETING = 1
        const val TYPE_CAROUSEL = 2
        const val TYPE_HEADER = 3
        const val TYPE_TASK = 4
        const val TYPE_EMPTY = 5
        const val TYPE_FOOTER = 6

    }
}
