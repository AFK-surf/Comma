package surf.comma.android.chat.live

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.text.TextUtils
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.settings.AccountButton
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.data.TaskGraph
import surf.comma.android.tasks.sidebarTasks
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.tasks.ui.TaskStrings
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

/**
 * The chat's left sidebar: every task on one line each (status glyph and title), newest first,
 * so its first row is what the top capsule shows. Labels, dates, filters and archiving stay on
 * the full task page behind "View all". At the bottom is a slot for entries such as settings.
 */
internal class ChatSidebar(
    private val activity: ComponentActivity,
    private val repository: ServerTaskRepository = TaskGraph.get(activity, AuthGraph.get(activity)),
) {
    private val density = activity.resources.displayMetrics.density
    private val theme = TaskTheme(activity)
    private val strings = TaskStrings(activity)
    private var loadingMore = false

    private val title = TextView(activity).apply {
        setText(R.string.chat_brand_name)
        DesignTypography.applyTo(this, DesignTypography.Level.TITLE2, DesignFonts.semibold)
        setTextColor(activity.getColor(R.color.token_text_primary))
        isAccessibilityHeading = true
    }

    private val heading = TextView(activity).apply {
        setText(R.string.task_list_title)
        DesignTypography.applyTo(this, DesignTypography.Level.REGULAR, DesignFonts.semibold)
        setTextColor(activity.getColor(R.color.token_text_primary))
        isAccessibilityHeading = true
    }

    val viewAll = TextView(activity).apply {
        id = R.id.chat_sidebar_view_all
        setText(R.string.chat_sidebar_view_all)
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
        setTextColor(activity.getColor(R.color.token_text_tertiary))
        gravity = Gravity.CENTER
        minHeight = dp(44)
        setPadding(dp(8), 0, dp(8), 0)
        background = pressed(radius = dp(8).toFloat(), inset = 0)
    }

    private val adapter = Rows()

    val list = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity)
        adapter = this@ChatSidebar.adapter
        itemAnimator = null
        isVerticalScrollBarEnabled = false
        clipToPadding = false
        overScrollMode = RecyclerView.OVER_SCROLL_ALWAYS
    }

    private val empty = TextView(activity).apply {
        setText(R.string.task_list_empty)
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL)
        setTextColor(activity.getColor(R.color.token_text_quaternary))
        setPadding(dp(ROW_GUTTER_DP), dp(8), dp(ROW_GUTTER_DP), 0)
        isVisible = false
    }

    /** The bottom slot. The account for now; further entries go in this column. */
    val footer = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }

    private val accountName = TextView(activity).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.REGULAR, DesignFonts.medium)
        setTextColor(activity.getColor(R.color.token_text_primary))
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /** Who is signed in, avatar and name; it opens the settings. */
    val settings = LinearLayout(activity).apply {
        id = R.id.chat_sidebar_settings
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(56)
        background = pressed(radius = dp(12).toFloat(), inset = dp(12))
        // After the background, whose insets would otherwise replace this padding.
        setPadding(dp(ROW_GUTTER_DP - 8), 0, dp(ROW_GUTTER_DP), 0)
        isClickable = true
        isFocusable = true
        contentDescription = activity.getString(R.string.settings_open)
        addView(AccountButton(activity, avatarDp = 32).apply {
            // The row is the button; the avatar only shows who is signed in.
            id = FrameLayout.NO_ID
            isClickable = false
            isFocusable = false
            importantForAccessibility = FrameLayout.IMPORTANT_FOR_ACCESSIBILITY_NO
            onName = { accountName.text = it }
        }, LinearLayout.LayoutParams(dp(48), dp(48)))
        addView(accountName, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginStart = dp(4)
        })
    }

    private val header = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        addView(title, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(ROW_GUTTER_DP)
            bottomMargin = dp(16)
        })
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ROW_GUTTER_DP), 0, dp(12), 0)
            addView(heading, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(viewAll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    val view: FrameLayout = object : FrameLayout(activity) {
        private val edge = Paint().apply { color = activity.getColor(R.color.token_border_primary) }

        init { setWillNotDraw(false) }

        /** A hairline on the side facing the page, which the scrim only dims. */
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val x = if (layoutDirection == LAYOUT_DIRECTION_RTL) 0f else width - HAIRLINE_PX
            canvas.drawRect(x, 0f, x + HAIRLINE_PX, height.toFloat(), edge)
        }
    }.apply {
        id = R.id.chat_sidebar
        // A shade off the page, so the sidebar reads as its own surface beside the chat.
        setBackgroundColor(activity.getColor(R.color.token_bg_secondary))
        // Touches that reach the panel's empty parts must not fall through to the chat under it.
        isClickable = true
    }

    var onOpenTask: ((String) -> Unit)? = null
    var onViewAll: (() -> Unit)? = null
    var onOpenSettings: (() -> Unit)? = null

    init {
        viewAll.setOnClickListener { onViewAll?.invoke() }
        settings.setOnClickListener { onOpenSettings?.invoke() }
        footer.addView(settings, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        view.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(header, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(FrameLayout(activity).apply {
                addView(list, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
                addView(empty, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT))
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
            addView(footer, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        ViewCompat.setOnApplyWindowInsetsListener(view) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            header.setPadding(0, bars.top + dp(20), 0, dp(4))
            footer.setPadding(0, dp(4), 0, dp(8) + bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (dy > 0) loadMoreNearEnd()
            }
        })
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                repository.state.map { sidebarTasks(it.snapshot.tasks) }.distinctUntilChanged().collect(::submit)
            }
        }
    }

    /** The rows shown now, for tests. */
    val tasks: List<TaskSummary> get() = adapter.currentList

    private fun submit(tasks: List<TaskSummary>) {
        adapter.submitList(tasks) { loadMoreNearEnd() }
        empty.isVisible = tasks.isEmpty()
    }

    /** The data layer pages; the last rows coming close asks for the next page. */
    private fun loadMoreNearEnd() {
        val manager = list.layoutManager as? LinearLayoutManager ?: return
        if (adapter.itemCount == 0 || manager.findLastVisibleItemPosition() < adapter.itemCount - NEAR_END_ROWS) return
        val state = repository.state.value
        if (!state.hasMore || state.loading || loadingMore) return
        loadingMore = true
        activity.lifecycleScope.launch {
            try { repository.loadMore() } finally { loadingMore = false }
        }
    }

    /** A pressed state that fills a rounded rect, inset from the panel's sides. */
    private fun pressed(radius: Float, inset: Int) = RippleDrawable(
        ColorStateList.valueOf(activity.getColor(R.color.token_bg_quaternary)), null,
        InsetDrawable(GradientDrawable().apply { cornerRadius = radius; setColor(android.graphics.Color.BLACK) }, inset, 0, inset, 0),
    )

    private inner class Rows : ListAdapter<TaskSummary, Row>(object : DiffUtil.ItemCallback<TaskSummary>() {
        override fun areItemsTheSame(oldItem: TaskSummary, newItem: TaskSummary) = oldItem.id == newItem.id
        override fun areContentsTheSame(oldItem: TaskSummary, newItem: TaskSummary) = oldItem == newItem
    }) {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = Row()
        override fun onBindViewHolder(holder: Row, position: Int) = holder.bind(getItem(position))
    }

    private inner class Row : RecyclerView.ViewHolder(LinearLayout(activity)) {
        private val icon = TaskStatusIconView(activity)
        private val title = TextView(activity).apply {
            DesignTypography.applyTo(this, DesignTypography.Level.REGULAR)
            setTextColor(activity.getColor(R.color.token_text_primary))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        private var taskId: String? = null

        init {
            (itemView as LinearLayout).apply {
                layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, dp(ROW_DP))
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                // Background first: an inset drawable sets the view's padding to its insets.
                background = pressed(radius = dp(12).toFloat(), inset = dp(12))
                setPadding(dp(ROW_GUTTER_DP), 0, dp(ROW_GUTTER_DP), 0)
                isClickable = true
                isFocusable = true
                addView(icon, LinearLayout.LayoutParams(dp(16), dp(16)))
                addView(title, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(12) })
                setOnClickListener { taskId?.let { onOpenTask?.invoke(it) } }
            }
        }

        fun bind(task: TaskSummary) {
            taskId = task.id
            icon.setStatus(task.bucket, theme.statusTint(task.bucket))
            title.text = strings.title(task)
            itemView.contentDescription = "${title.text}, ${theme.statusLabel(task.bucket)}"
        }
    }

    private fun dp(value: Int) = (value * density).toInt()

    private companion object {
        const val HAIRLINE_PX = 1f
        const val ROW_DP = 48
        const val ROW_GUTTER_DP = 24
        const val NEAR_END_ROWS = 8
    }
}
