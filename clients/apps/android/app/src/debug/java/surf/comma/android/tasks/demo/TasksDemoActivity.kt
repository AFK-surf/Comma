package surf.comma.android.tasks.demo

import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import surf.comma.android.scroll.widget.ScrollContainer
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.tasks.TASK_RECENCY_ORDER
import surf.comma.android.tasks.TaskSection
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.TaskConversationPanel
import surf.comma.android.tasks.ui.TaskDetailView
import surf.comma.android.tasks.ui.TaskListView
import surf.comma.android.tasks.ui.TaskRefChipView
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.tasks.ui.TaskType

/**
 * Debug-only showcase of the four task surfaces on fixture data.
 *
 * adb shell am start -n surf.comma.android.dev/surf.comma.android.tasks.demo.TasksDemoActivity \
 *     --es screen list        # chat | panel | list | detail
 *     --es task task-01       # detail only: which task to open
 *     --ez sheet true         # panel only: open the sheet right away
 *     --es problem refresh    # list only: refresh | empty, a failed read over / instead of the list
 */
class TasksDemoActivity : ComponentActivity() {
    private val repository = FixtureTaskRepository()
    private lateinit var theme: TaskTheme
    private lateinit var pages: Map<Screen, View>
    private lateinit var tabs: Map<Screen, TextView>
    private lateinit var panel: TaskConversationPanel
    private lateinit var detail: TaskDetailView
    private var current = Screen.CHAT
    private var beforeDetail = Screen.LIST
    private var detailJob: Job? = null

    private enum class Screen(val extra: String, val title: Int) {
        CHAT("chat", R.string.tasks_demo_tab_chat),
        PANEL("panel", R.string.tasks_demo_tab_panel),
        LIST("list", R.string.tasks_demo_tab_list),
        DETAIL("detail", R.string.tasks_demo_tab_detail),
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        theme = TaskTheme(this)

        val problem = intent.getStringExtra(EXTRA_PROBLEM)
        val list = TaskListView(this).apply {
            onOpenTask = ::openTask
            onArchiveTask = { id ->
                repository.archiveLocally(id)
                submit(repository.current, demoSections(repository.current))
                archiveFinished(id)
            }
            onRefresh = {
                lifecycleScope.launch {
                    repository.refresh()
                    setRefreshing(false)
                }
            }
        }
        detail = TaskDetailView(this).apply {
            onBack = { show(beforeDetail) }
            setNotice(getString(R.string.task_detail_messages_placeholder))
        }
        panel = TaskConversationPanel(this).apply { onOpenTask = ::openTask }
        val chat = ChatPage()
        pages = mapOf(
            Screen.CHAT to chat.root,
            Screen.PANEL to panelPage(),
            Screen.LIST to list,
            Screen.DETAIL to detail,
        )

        val tabBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(theme.bgPrimary)
            val pad = theme.dpInt(8f)
            setPadding(pad, 0, pad, 0)
        }
        tabs = Screen.entries.associateWith { screen ->
            TextView(this).apply {
                text = getString(screen.title)
                gravity = Gravity.CENTER
                theme.applyTo(this, TaskType.metaMedium, theme.textQuaternary)
                minHeight = theme.dpInt(44f)
                setOnClickListener { if (screen == Screen.DETAIL) openTask(defaultTaskId()) else show(screen) }
                tabBar.addView(this, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
        }
        val pageArea = FrameLayout(this)
        pages.values.forEach { pageArea.addView(it, FrameLayout.LayoutParams(-1, -1)) }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgPrimary)
            addView(tabBar, LinearLayout.LayoutParams(-1, -2))
            addView(pageArea, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        // The tab bar takes the status bar inset; pages below it only see the bottom inset.
        ViewCompat.setOnApplyWindowInsetsListener(tabBar) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(view.paddingLeft, bars.top, view.paddingRight, 0)
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(pageArea) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            WindowInsetsCompat.Builder(insets)
                .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.NONE)
                .setInsets(WindowInsetsCompat.Type.systemBars(), Insets.of(bars.left, 0, bars.right, bars.bottom))
                .build()
        }
        val root = FrameLayout(this).apply {
            addView(column, FrameLayout.LayoutParams(-1, -1))
            // The sheet overlays everything, tab bar included.
            addView(panel.sheet, FrameLayout.LayoutParams(-1, -1))
        }
        setContentView(root)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    panel.handleBack() -> Unit
                    current == Screen.DETAIL -> show(beforeDetail)
                    else -> finish()
                }
            }
        })

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    if (problem == PROBLEM_EMPTY) {
                        list.submit(TaskSnapshot.EMPTY, emptyList())
                        list.setNotice(getString(R.string.task_list_problem), retry = true)
                    } else {
                        repository.observeTasks().collectLatest { list.submit(it, demoSections(it)) }
                    }
                }
                launch {
                    repository.observeConversationTasks(FixtureTaskRepository.DEMO_CONVERSATION).collectLatest {
                        panel.submit(it)
                        chat.bind(it)
                    }
                }
            }
        }

        val requested = Screen.entries.firstOrNull { it.extra == intent.getStringExtra(EXTRA_SCREEN) }
        when (requested) {
            Screen.DETAIL -> openTask(intent.getStringExtra(EXTRA_TASK) ?: defaultTaskId())
            null -> show(Screen.CHAT)
            else -> show(requested)
        }
        if (requested == Screen.PANEL && intent.getBooleanExtra(EXTRA_SHEET, false)) panel.sheet.open()
        if (problem == PROBLEM_REFRESH) list.setProblem(getString(R.string.task_list_refresh_failed))
        list.onRetry = {
            list.setProblem(null)
            list.setRefreshing(true)
            list.onRefresh?.invoke()
        }
    }

    private fun show(screen: Screen) {
        if (screen == Screen.DETAIL && current != Screen.DETAIL) beforeDetail = current
        current = screen
        pages.forEach { (key, page) -> page.isVisible = key == screen }
        tabs.forEach { (key, tab) ->
            tab.setTextColor(if (key == screen) theme.textPrimary else theme.textQuaternary)
        }
    }

    private fun openTask(taskId: String) {
        panel.sheet.close()
        detailJob?.cancel()
        detailJob = lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                repository.observeTask(taskId).collectLatest { detail.setTitle(it?.title) }
            }
        }
        show(Screen.DETAIL)
    }

    private fun defaultTaskId(): String = repository.current.tasks
        .firstOrNull { it.bucket == TaskStatusBucket.IN_PROGRESS }?.id ?: "task-01"

    /** A fake transcript with the conversation's tasks embedded as chips. */
    private inner class ChatPage {
        private val column = LinearLayout(this@TasksDemoActivity).apply {
            orientation = LinearLayout.VERTICAL
            val gutter = theme.dpInt(16f)
            setPadding(gutter, theme.dpInt(12f), gutter, theme.dpInt(24f))
        }
        val root = ScrollContainer(this@TasksDemoActivity).apply {
            clipToPadding = false
            addView(column)
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                view.setPadding(0, 0, 0, insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom)
                insets
            }
        }
        private val chips = LinkedHashMap<String, TaskRefChipView>()

        fun bind(tasks: List<TaskSummary>) {
            if (chips.keys.toList() != tasks.map { it.id }) rebuild(tasks)
            tasks.forEach { chips[it.id]?.bind(it) }
        }

        private fun rebuild(tasks: List<TaskSummary>) {
            column.removeAllViews()
            chips.clear()
            tasks.forEachIndexed { index, task ->
                if (index % 2 == 0) column.addView(message(getString(R.string.tasks_demo_user_message), user = true))
                column.addView(message(getString(R.string.tasks_demo_agent_message), user = false))
                val chip = TaskRefChipView(this@TasksDemoActivity).apply { onOpenTask = ::openTask }
                chips[task.id] = chip
                column.addView(
                    chip,
                    LinearLayout.LayoutParams(-2, -2).apply {
                        topMargin = theme.dpInt(6f)
                        bottomMargin = theme.dpInt(20f)
                    },
                )
            }
        }

        private fun message(text: String, user: Boolean) = TextView(this@TasksDemoActivity).apply {
            this.text = text
            theme.applyTo(this, TaskType.body, theme.textPrimary)
            layoutParams = LinearLayout.LayoutParams(-2, -2).apply {
                gravity = if (user) Gravity.END else Gravity.START
                topMargin = theme.dpInt(6f)
            }
            if (user) {
                setTextColor(getColor(android.R.color.white))
                val pad = theme.dpInt(12f)
                setPadding(pad, theme.dpInt(8f), pad, theme.dpInt(8f))
                background = GradientDrawable().apply {
                    cornerRadius = theme.dp(20f)
                    setColor(getColor(R.color.token_bg_brand_solid))
                }
            }
        }
    }

    /** A fake transcript with the task pill docked above a fake composer. */
    private fun panelPage(): View {
        val gutter = theme.dpInt(16f)
        val transcript = TextView(this).apply {
            text = getString(R.string.tasks_demo_panel_hint)
            theme.applyTo(this, TaskType.body, theme.textTertiary)
            setPadding(gutter, gutter, gutter, gutter)
        }
        val composer = TextView(this).apply {
            text = getString(R.string.tasks_demo_composer_placeholder)
            theme.applyTo(this, TaskType.body, theme.textQuaternary)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = theme.dpInt(48f)
            setPadding(gutter, 0, gutter, 0)
            background = GradientDrawable().apply {
                cornerRadius = theme.dp(24f)
                setColor(theme.bgQuaternary)
            }
        }
        val dock = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(gutter, 0, gutter, gutter)
            addView(panel.pill, LinearLayout.LayoutParams(-2, -2).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = theme.dpInt(8f)
            })
            addView(composer, LinearLayout.LayoutParams(-1, -2))
            ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
                view.setPadding(gutter, 0, gutter, gutter + insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom)
                insets
            }
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(transcript, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(dock, LinearLayout.LayoutParams(-1, -2))
        }
    }

    private companion object {
        const val EXTRA_SCREEN = "screen"
        const val EXTRA_TASK = "task"
        const val EXTRA_SHEET = "sheet"
        const val EXTRA_PROBLEM = "problem"
        const val PROBLEM_REFRESH = "refresh"
        const val PROBLEM_EMPTY = "empty"
    }
}

/** The sections the core would give the fixture's tasks: the shown statuses in their order, newest first in each. */
private fun demoSections(snapshot: TaskSnapshot): List<TaskSection> =
    listOf(TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.NEEDS_REVIEW, TaskStatusBucket.DONE,
        TaskStatusBucket.CANCELLED).map { bucket ->
        TaskSection(bucket, snapshot.tasks.filter { it.bucket == bucket }.sortedWith(TASK_RECENCY_ORDER).map { it.id })
    }
