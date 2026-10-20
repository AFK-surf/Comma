package surf.comma.android.tasks.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import surf.comma.android.scroll.widget.DiffUtil
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.ListAdapter
import surf.comma.android.scroll.widget.RecyclerView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.tasks.TaskPanelCounts
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.conversationPanelCounts
import surf.comma.android.tasks.conversationPanelOrder
import surf.comma.android.tasks.isEnded
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

/** One laid-out row of the conversation's task panel. */
class PreparedPanelRow(
    val key: String,
    val task: TaskSummary,
    val bucket: TaskStatusBucket,
    val title: TextBlock,
    val status: TextBlock,
    /** Present for ended tasks, which can be hidden from the panel. */
    val hide: TextBlock?,
    val heightPx: Int,
    val contentDescription: String,
)

private class PanelMetrics(theme: TaskTheme) {
    val gutter = theme.dpInt(16f)
    val icon = theme.dpInt(16f)
    val gap = theme.dpInt(8f)
    val hidePad = theme.dpInt(8f)
    val rowHeight = theme.dpInt(44f)
    val radius = theme.dp(10f)
}

/** Background-thread safe, memoised on exact inputs like [TaskRowPreparer]. */
private class PanelRowPreparer(private val theme: TaskTheme, private val strings: TaskStrings) {
    val metrics = PanelMetrics(theme)
    private val cache = LruMap<Any, PreparedPanelRow>(MAX_CACHED_ROWS)

    fun prepare(tasks: List<TaskSummary>, widthPx: Int): List<PreparedPanelRow> =
        tasks.map { task -> cache.getOrPut(task to widthPx) { row(task, widthPx) } }

    private fun row(task: TaskSummary, widthPx: Int): PreparedPanelRow {
        val m = metrics
        val bucket = task.bucket
        val running = bucket == TaskStatusBucket.IN_PROGRESS
        val statusText = theme.statusLabel(bucket)
        val status = theme.line(statusText, TaskType.meta, if (running) theme.textSecondary else theme.textQuaternary, widthPx / 3)
        val hide = if (bucket.isEnded) theme.line(strings.hide, TaskType.metaMedium, theme.textSecondary, widthPx / 4) else null
        val trailing = status.contentWidthPx + (hide?.let { m.gap + it.contentWidthPx + m.hidePad * 2 } ?: 0)
        val titleWidth = widthPx - m.gutter * 2 - m.icon - m.gap * 2 - trailing
        val titleText = strings.title(task)
        val title = theme.line(titleText, TaskType.body, theme.textPrimary, titleWidth.coerceAtLeast(1))
        return PreparedPanelRow(
            key = "task:${task.id}",
            task = task,
            bucket = bucket,
            title = title,
            status = status,
            hide = hide,
            heightPx = m.rowHeight,
            contentDescription = "$titleText, $statusText",
        )
    }

    private companion object {
        const val MAX_CACHED_ROWS = 200
    }
}

/** A panel row: glyph, title, status, and for ended tasks a trailing "Hide". */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility") // Built in code only, never inflated from XML;
// the trailing Hide target is also exposed as an accessibility action.
private class PanelRowView(
    context: Context,
    private val theme: TaskTheme,
    private val metrics: PanelMetrics,
) : ViewGroup(context) {
    private val icon = TaskStatusIconView(context)
    private val pressedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.bgTertiary }
    private val bounds = RectF()
    private var hideLeft = Int.MAX_VALUE
    private var downOnHide = false
    var row: PreparedPanelRow? = null
        private set
    var onOpen: ((String) -> Unit)? = null
    var onHide: ((String) -> Unit)? = null

    init {
        setWillNotDraw(false)
        isClickable = true
        isFocusable = true
        addView(icon)
        setOnClickListener { row?.let { onOpen?.invoke(it.task.id) } }
    }

    fun bind(next: PreparedPanelRow) {
        row = next
        icon.setStatus(next.bucket, theme.statusTint(next.bucket))
        contentDescription = next.contentDescription
        val hide = next.hide
        // The hide action is exposed to accessibility services as a custom action.
        ViewCompat.removeAccessibilityAction(this, HIDE_ACTION_ID)
        if (hide != null) {
            ViewCompat.replaceAccessibilityAction(
                this,
                androidx.core.view.accessibility.AccessibilityNodeInfoCompat.AccessibilityActionCompat(
                    HIDE_ACTION_ID,
                    hide.layout.text,
                ),
                hide.layout.text,
            ) { _, _ ->
                onHide?.invoke(next.task.id)
                true
            }
        }
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val size = MeasureSpec.makeMeasureSpec(metrics.icon, MeasureSpec.EXACTLY)
        icon.measure(size, size)
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), metrics.rowHeight)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val top = (measuredHeight - metrics.icon) / 2
        icon.layout(metrics.gutter, top, metrics.gutter + metrics.icon, top + metrics.icon)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            downOnHide = row?.hide != null && event.x >= hideLeft
        }
        if (downOnHide) {
            if (event.actionMasked == MotionEvent.ACTION_UP && event.x >= hideLeft) {
                row?.let { onHide?.invoke(it.task.id) }
            }
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                downOnHide = false
            }
            return true
        }
        return super.onTouchEvent(event)
    }

    override fun drawableStateChanged() {
        super.drawableStateChanged()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val current = row ?: return
        val m = metrics
        if (isPressed) {
            bounds.set(m.gutter / 2f, 0f, width - m.gutter / 2f, height.toFloat())
            canvas.drawRoundRect(bounds, m.radius, m.radius, pressedPaint)
        }
        var right = width - m.gutter
        val hide = current.hide
        hideLeft = if (hide != null) {
            val left = right - hide.contentWidthPx
            hide.draw(canvas, left.toFloat(), (height - hide.heightPx) / 2f)
            right = left - m.hidePad - m.gap
            left - m.hidePad
        } else {
            Int.MAX_VALUE
        }
        val statusLeft = right - current.status.contentWidthPx
        current.status.draw(canvas, statusLeft.toFloat(), (height - current.status.heightPx) / 2f)
        val titleLeft = m.gutter + m.icon + m.gap
        current.title.draw(canvas, titleLeft.toFloat(), (height - current.title.heightPx) / 2f)
    }

    private companion object {
        val HIDE_ACTION_ID = R.id.task_action_hide
    }
}

private class PanelAdapter(
    private val theme: TaskTheme,
    private val metrics: PanelMetrics,
    private val onOpen: (String) -> Unit,
    private val onHide: (String) -> Unit,
) : ListAdapter<PreparedPanelRow, PanelAdapter.Holder>(DIFF) {
    private val stableIds = StableIds()

    init {
        setHasStableIds(true)
    }

    override fun getItemId(position: Int): Long = stableIds.idFor(getItem(position).key)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder =
        Holder(
            PanelRowView(parent.context, theme, metrics).also {
                it.onOpen = onOpen
                it.onHide = onHide
            },
        )

    override fun onBindViewHolder(holder: Holder, position: Int) = holder.view.bind(getItem(position))

    class Holder(val view: PanelRowView) : RecyclerView.ViewHolder(view)

    private companion object {
        val DIFF = object : DiffUtil.ItemCallback<PreparedPanelRow>() {
            override fun areItemsTheSame(oldItem: PreparedPanelRow, newItem: PreparedPanelRow) = oldItem.key == newItem.key
            override fun areContentsTheSame(oldItem: PreparedPanelRow, newItem: PreparedPanelRow) = oldItem === newItem
        }
    }
}

/**
 * The pill above the composer: "3 tasks · 1 running". Hidden when the panel would be empty.
 */
@SuppressLint("ViewConstructor") // Built in code only, never inflated from XML.
class TaskPanelPillView(context: Context, private val theme: TaskTheme) : LinearLayout(context) {
    private val icon = TaskStatusIconView(context)
    private val label = TextView(context).apply {
        theme.applyTo(this, TaskType.metaMedium, theme.textSecondary)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = resources.getDimensionPixelSize(R.dimen.task_pill_height)
        setPadding(theme.dpInt(12f), 0, theme.dpInt(14f), 0)
        isClickable = true
        isFocusable = true
        background = GradientDrawable().apply {
            cornerRadius = resources.getDimension(R.dimen.task_pill_height) / 2f
            setColor(theme.bgSecondary)
            setStroke(1, theme.borderPrimary)
        }
        val size = theme.dpInt(16f)
        addView(icon, LayoutParams(size, size).apply { marginEnd = theme.dpInt(6f) })
        addView(label)
        isVisible = false
    }

    fun bind(counts: TaskPanelCounts, text: String) {
        isVisible = !counts.isEmpty
        label.text = text
        contentDescription = text
        val running = counts.running > 0
        icon.isVisible = running
        if (running) icon.setStatus(TaskStatusBucket.IN_PROGRESS, theme.statusTint(TaskStatusBucket.IN_PROGRESS))
    }
}

/**
 * The conversation's task surfaces: [pill] goes above the composer, [sheet] is a full-window
 * overlay added last to the host's root. Hidden tasks are view state of this panel: they stay
 * hidden while the panel lives, unless they run again, and are reported through [onHideTask].
 */
class TaskConversationPanel(context: Context) {
    private val theme = TaskTheme(context)
    private val strings = TaskStrings(context)
    private val preparer = PanelRowPreparer(theme, strings)
    private val metrics = preparer.metrics

    val pill = TaskPanelPillView(context, theme)
    val sheet = TaskSheetLayout(context, theme)

    var onOpenTask: ((String) -> Unit)? = null
    var onHideTask: ((String) -> Unit)? = null
    /** The heading's link on to every task, not only this conversation's. */
    var onOpenAll: (() -> Unit)? = null

    private val adapter = PanelAdapter(
        theme,
        metrics,
        onOpen = { id -> onOpenTask?.invoke(id) },
        onHide = { id -> hide(id) },
    )
    private val list = RecyclerView(context).apply {
        layoutManager = LinearLayoutManager(context)
        adapter = this@TaskConversationPanel.adapter
        itemAnimator = null
        overScrollMode = View.OVER_SCROLL_ALWAYS
        isVerticalScrollBarEnabled = false
        clipToPadding = false
    }
    private val title = TextView(context).apply {
        theme.applyTo(this, TaskTextStyle(DesignTypography.Level.REGULAR, DesignFonts.semibold), theme.textPrimary)
        text = context.getString(R.string.task_panel_title)
        isAccessibilityHeading = true
    }
    private val subtitle = TextView(context).apply {
        theme.applyTo(this, TaskType.meta, theme.textQuaternary)
    }

    private var tasks: List<TaskSummary> = emptyList()
    private val hidden = LinkedHashSet<String>()
    private var scope: CoroutineScope? = null
    private var job: Job? = null

    init {
        val gripHeight = theme.dpInt(GRIP_HEIGHT_DP)
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val radius = context.resources.getDimension(R.dimen.radius_2xl)
            background = GradientDrawable().apply {
                setColor(theme.bgPrimary)
                cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
            }
            clipToOutline = true
        }
        val grip = FrameLayout(context).apply {
            val handle = View(context).apply {
                background = GradientDrawable().apply {
                    cornerRadius = theme.dp(2f)
                    setColor(theme.borderPrimary)
                }
            }
            addView(
                handle,
                FrameLayout.LayoutParams(theme.dpInt(36f), theme.dpInt(4f), Gravity.CENTER_HORIZONTAL or Gravity.TOP)
                    .apply { topMargin = theme.dpInt(8f) },
            )
            val heading = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(metrics.gutter, 0, theme.dpInt(4f), 0)
                val titles = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(title)
                    addView(subtitle)
                }
                addView(titles, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(TextView(context).apply {
                    theme.applyTo(this, TaskType.metaMedium, theme.textSecondary)
                    text = context.getString(R.string.task_panel_all)
                    gravity = Gravity.CENTER
                    minHeight = theme.dpInt(48f)
                    setPadding(theme.dpInt(12f), 0, theme.dpInt(12f), 0)
                    setOnClickListener { onOpenAll?.invoke() }
                })
            }
            addView(
                heading,
                FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM)
                    .apply { bottomMargin = theme.dpInt(8f) },
            )
        }
        body.addView(grip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, gripHeight))
        body.addView(list, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        sheet.setSheet(body, gripHeight)
        ViewCompat.setOnApplyWindowInsetsListener(list) { view, insets ->
            val bottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            view.setPadding(0, 0, 0, bottom + metrics.gap)
            insets
        }
        pill.setOnClickListener { sheet.open() }
        list.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) prepare()
        }
        sheet.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) {
                scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                prepare()
            }

            override fun onViewDetachedFromWindow(v: View) {
                scope?.cancel()
                scope = null
            }
        })
    }

    /** Tasks created from this conversation, in creation order. */
    fun submit(tasks: List<TaskSummary>) {
        this.tasks = tasks
        // Hiding only lasts while a task stays stopped: one that runs again is shown again.
        tasks.forEach { if (it.bucket == TaskStatusBucket.IN_PROGRESS) hidden.remove(it.id) }
        render()
    }

    /** Forgets what was hidden and closes the sheet, e.g. when another account signs in. */
    fun reset() {
        hidden.clear()
        tasks = emptyList()
        sheet.close()
        render()
    }

    /** The rows' counts as the pill shows them. */
    val counts: TaskPanelCounts get() = conversationPanelCounts(tasks, hidden)

    /** Returns true when a back press was used to close the sheet. */
    fun handleBack(): Boolean {
        if (!sheet.isOpen) return false
        sheet.close()
        return true
    }

    private fun hide(taskId: String) {
        if (!hidden.add(taskId)) return
        onHideTask?.invoke(taskId)
        render()
    }

    private fun render() {
        val counts = conversationPanelCounts(tasks, hidden)
        val text = strings.panelCounts(counts)
        pill.bind(counts, text)
        subtitle.text = text
        if (counts.isEmpty) sheet.close()
        prepare()
    }

    private fun prepare() {
        val launchScope = scope ?: return
        // Before the sheet's first layout its list has no width yet; it spans the window, so lay
        // rows out for the window width and let the layout listener correct it if that differs.
        val width = list.width.takeIf { it > 0 } ?: sheet.rootView.width.takeIf { it > 0 } ?: return
        val ordered = conversationPanelOrder(tasks, hidden)
        job?.cancel()
        job = launchScope.launch {
            val rows = withContext(Background.compute) { preparer.prepare(ordered, width) }
            adapter.submitList(rows)
        }
    }

    private companion object {
        /** Handle plus the heading; drags that start here move the sheet directly. */
        const val GRIP_HEIGHT_DP = 76f
    }
}
