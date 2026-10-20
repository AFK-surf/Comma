package surf.comma.android.tasks.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.widget.FrameLayout
import surf.comma.android.scroll.widget.ScrollContainer
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isNotEmpty
import androidx.core.view.isVisible
import surf.comma.android.scroll.widget.ItemTouchHelper
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.clipToRoundedBackground
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.effectiveLabelFilter
import surf.comma.android.tasks.filterableLabels
import surf.comma.android.tasks.TaskSection
import surf.comma.android.tasks.taskListRows
import surf.comma.android.ui.Background

/**
 * The full task list: title, label filter, and the grouped cards. Rows are grouped, filtered
 * and laid out on a background dispatcher; the main thread only diffs and binds.
 * Archiving is reported through [onArchiveTask]; the row stays hidden until the host calls
 * [archiveFinished]. Within a status group, cards follow the group's shared manual order.
 *
 * New data never moves the reader: the row at the top of the screen stays where it was, even
 * when rows above it change or the row that was at the top moves to another group.
 */
class TaskListView(context: Context) : LinearLayout(context) {
    private val theme = TaskTheme(context)
    private val strings = TaskStrings(context)
    private val preparer = TaskRowPreparer(theme, strings)
    private val metrics = preparer.metrics

    private val header = LinearLayout(context).apply {
        orientation = VERTICAL
    }
    private val back = ImageButton(context).apply {
        setImageDrawable(ContextCompat.getDrawable(context, R.drawable.ic_task_back)?.mutate()?.apply { setTint(theme.textPrimary) })
        background = null
        contentDescription = context.getString(R.string.task_action_back)
        setOnClickListener { onBack?.invoke() }
        isVisible = false
    }
    private val title = TextView(context).apply {
        text = context.getString(R.string.task_list_title)
        applyStyle(TaskType.pageTitle, theme.textPrimary)
        isAccessibilityHeading = true
        val gutter = metrics.gutter
        setPadding(gutter, theme.dpInt(12f), gutter, theme.dpInt(8f))
    }
    private val chipRow = LinearLayout(context).apply {
        orientation = HORIZONTAL
        setPadding(metrics.gutter, 0, metrics.gutter, 0)
    }
    private val chipScroller = ScrollContainer(context).apply {
        orientation = ScrollContainer.HORIZONTAL
        isHorizontalScrollBarEnabled = false
        overScrollMode = OVER_SCROLL_NEVER
        addView(chipRow)
        setPadding(0, theme.dpInt(4f), 0, theme.dpInt(8f))
        clipToPadding = false
    }
    private val adapter = TaskListAdapter(theme, metrics, onOpenTask = { onOpenTask?.invoke(it) }, onArchive = ::archive)
    private val list = RecyclerView(context).apply {
        layoutManager = LinearLayoutManager(context)
        adapter = this@TaskListView.adapter
        itemAnimator = null
        overScrollMode = OVER_SCROLL_ALWAYS
        isVerticalScrollBarEnabled = false
        clipToPadding = false
        setItemViewCacheSize(ITEM_VIEW_CACHE)
    }
    private val refresh = TaskRefreshLayout(context, theme).apply { setTarget(list) }
    private val empty = TextView(context).apply {
        applyStyle(TaskType.meta, theme.textQuaternary)
        gravity = Gravity.CENTER
        maxLines = 3
    }
    private val emptyRetry = retryButton()
    private val emptyColumn = LinearLayout(context).apply {
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        addView(empty, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(emptyRetry, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { topMargin = theme.dpInt(12f) })
        isVisible = false
    }

    /** Over a list that is still shown: the last read failed. One line and a retry. */
    private val problemText = TextView(context).apply {
        applyStyle(TaskType.meta, theme.textSecondary)
        // Announced when it appears, without moving focus.
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE
    }
    private val problemRetry = retryButton().apply { isVisible = true }
    private val problemBar = LinearLayout(context).apply {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(metrics.gutter, 0, metrics.gutter - theme.dpInt(12f), 0)
        addView(problemText, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        addView(problemRetry, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        isVisible = false
    }

    private var scope: CoroutineScope? = null
    private var prepareJob: Job? = null
    private var snapshot: TaskSnapshot? = null
    private var sections: List<TaskSection> = emptyList()
    private var notice: String? = null
    private var noticeRetry = false
    private var problem: String? = null
    /** Rows are on screen, as opposed to the empty notice. */
    private var hasRows = false
    /** The next commit goes to the top: the reader picked another filter. */
    private var scrollToTop = false
    /** A position restored from saved state, applied once its row is listed. */
    private var pendingAnchor: Anchor? = null
    /** Counts the reader's scrolls, so a commit can tell whether its anchor is still current. */
    private var readerMoves = 0

    /** Runs as a submitted list is committed, before the position is kept; for tests. */
    internal var beforeCommit: (() -> Unit)? = null
    /** The differ drops a submission that a newer one overtakes, so count by generation. */
    private var submitted = 0
    private var committed = 0

    /** No rows are being prepared or diffed; for tests, which otherwise race the background work. */
    internal val isIdle: Boolean get() = prepareJob?.isActive != true && committed == submitted
    private var offeredLabels: List<TaskLabel> = emptyList()
    private var selectedLabel: String? = null
    /** Swiped away and reported, not yet answered by the host. Hidden meanwhile. */
    private val archiving = HashSet<String>()

    var onOpenTask: ((String) -> Unit)? = null
    var onArchiveTask: ((String) -> Unit)? = null
    var onRefresh: (() -> Unit)? = null
        set(value) {
            field = value
            refresh.onRefresh = value
        }

    /** The retry under a failed read. The host shows its progress with [setRefreshing]. */
    var onRetry: (() -> Unit)? = null

    /** Shows a back button before the title when set. */
    var onBack: (() -> Unit)? = null
        set(value) {
            field = value
            back.isVisible = value != null
        }

    /** The last rows are close to the screen; the host may load the next page. */
    var onNearEnd: (() -> Unit)? = null

    init {
        orientation = VERTICAL
        setBackgroundColor(theme.bgPrimary)
        val titleRow = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val size = theme.dpInt(44f)
            addView(back, LayoutParams(size, size).apply { marginStart = theme.dpInt(4f) })
            addView(title, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        }
        header.addView(titleRow)
        header.addView(chipScroller)
        header.addView(problemBar)
        addView(header, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        val body = FrameLayout(context)
        body.addView(refresh, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        body.addView(
            emptyColumn,
            FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
                .apply { setMargins(metrics.gutter, 0, metrics.gutter, 0) },
        )
        addView(body, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        list.addItemDecoration(ArchiveBackdrop())
        ItemTouchHelper(SwipeToArchive()).attachToRecyclerView(list)
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                // Layout passes report (0, 0); only real movement is the reader's.
                if (dy != 0) readerMoves++
                if (dy > 0) checkNearEnd()
            }

            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                if (newState != RecyclerView.SCROLL_STATE_IDLE) readerMoves++
            }
        })
        list.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
            if (right - left != oldRight - oldLeft) prepare()
        }
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            header.setPadding(0, bars.top, 0, 0)
            list.setPadding(0, 0, 0, bars.bottom + metrics.gutter)
            insets
        }
    }

    fun submit(snapshot: TaskSnapshot, sections: List<TaskSection>) {
        this.snapshot = snapshot
        this.sections = sections
        // Once the host has dropped or archived a swiped task, it no longer needs hiding here.
        val listed = snapshot.tasks.filter { it.bucket != TaskStatusBucket.ARCHIVED }.mapTo(HashSet()) { it.id }
        archiving.retainAll(listed)
        val offered = filterableLabels(snapshot.tasks, snapshot.labels)
        selectedLabel = effectiveLabelFilter(selectedLabel, offered)
        if (offered != offeredLabels) {
            offeredLabels = offered
            renderChips()
        }
        prepare()
    }

    fun setRefreshing(refreshing: Boolean) = refresh.setRefreshing(refreshing)

    /**
     * A line shown in place of an empty list, e.g. when loading failed; null for the default.
     * [retry] offers [onRetry] under it.
     */
    fun setNotice(text: String?, retry: Boolean = false) {
        if (notice == text && noticeRetry == retry) return
        notice = text
        noticeRetry = retry
        prepare()
    }

    /** The last read failed while rows are shown; null once a read succeeds. */
    fun setProblem(text: String?) {
        if (problem == text) return
        problem = text
        updateProblem()
    }

    /**
     * The host has the archive's answer. A task that was archived has already left the
     * snapshot; any other answer brings its card back.
     */
    fun archiveFinished(taskId: String) {
        if (archiving.remove(taskId)) prepare()
    }

    /** The filter and the reading position, for the host to save. */
    fun saveState(): Bundle = Bundle().apply {
        putString(STATE_LABEL, selectedLabel)
        // The whole screenful, with each card's group, so a restore can hand over as a live
        // update would when the top task has moved on.
        currentAnchor(whileMoving = true)?.let { anchor ->
            val rows = listOf(anchor) + anchor.next
            putStringArray(STATE_ANCHOR_KEYS, rows.map { it.key }.toTypedArray())
            putIntArray(STATE_ANCHOR_OFFSETS, rows.map { it.offset }.toIntArray())
            putStringArray(STATE_ANCHOR_BUCKETS, rows.map { it.bucket?.wireName.orEmpty() }.toTypedArray())
        }
    }

    /**
     * Brings back [saveState]'s filter and position. The host restores only into the session
     * and group it saved from; the filter and the row are dropped if they no longer exist.
     */
    fun restoreState(state: Bundle) {
        selectedLabel = state.getString(STATE_LABEL)
        val keys = state.getStringArray(STATE_ANCHOR_KEYS).orEmpty()
        val offsets = state.getIntArray(STATE_ANCHOR_OFFSETS) ?: IntArray(0)
        val buckets = state.getStringArray(STATE_ANCHOR_BUCKETS).orEmpty()
        val rows = keys.indices.filter { it < offsets.size }.map { index ->
            val bucket = buckets.getOrNull(index)?.let { wire -> TaskStatusBucket.entries.firstOrNull { it.wireName == wire } }
            Anchor(keys[index], offsets[index], bucket)
        }
        pendingAnchor = rows.firstOrNull()?.let { Anchor(it.key, it.offset, it.bucket, rows.drop(1)) }
            ?: Anchor(TOP_KEY, 0, null)
        offeredLabels = emptyList()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        prepare()
    }

    override fun onDetachedFromWindow() {
        scope?.cancel()
        scope = null
        super.onDetachedFromWindow()
    }

    private fun prepare() {
        val current = snapshot ?: return
        val width = list.width
        val launchScope = scope ?: return
        if (width <= 0) return
        val label = selectedLabel
        val hidden = archiving.toSet()
        val order = sections
        prepareJob?.cancel()
        prepareJob = launchScope.launch {
            val rows = withContext(Background.compute) {
                val tasks = if (hidden.isEmpty()) current.tasks else current.tasks.filter { it.id !in hidden }
                preparer.prepare(taskListRows(tasks, label, order), current.labels, width)
            }
            val toTop = scrollToTop
            val restoring = pendingAnchor
            val anchor = when {
                toTop -> Anchor(TOP_KEY, 0, null)
                restoring != null -> restoring
                else -> currentAnchor()
            }
            val moves = readerMoves
            val generation = ++submitted
            adapter.submitList(rows) {
                committed = generation
                // Only a list that commits has used them: one replaced before its commit leaves them to the next.
                if (toTop) scrollToTop = false
                if (restoring != null && pendingAnchor === restoring) pendingAnchor = null
                beforeCommit?.invoke()
                // The diff runs off the main thread; a reader who scrolled meanwhile has chosen a
                // new place, and the anchor taken before it would pull them back.
                if (readerMoves == moves) anchor?.let { keep(it, rows) }
                checkNearEnd()
            }
            empty.text = notice ?: context.getString(
                if (label == null) R.string.task_list_empty else R.string.task_list_empty_filtered,
            )
            emptyRetry.isVisible = notice != null && noticeRetry
            hasRows = rows.isNotEmpty()
            emptyColumn.isVisible = !hasRows
            updateProblem()
        }
    }

    /** Only over rows: an empty list says what went wrong in its own notice. */
    private fun updateProblem() {
        val text = problem?.takeIf { hasRows }
        problemText.text = text
        problemBar.isVisible = text != null
    }

    /**
     * Where the reader is: the rows on screen from the top down, each with its offset. The first
     * is the one to keep in place; the others stand in if it leaves.
     */
    private class Anchor(val key: String, val offset: Int, val bucket: TaskStatusBucket?, val next: List<Anchor> = emptyList())

    private fun currentAnchor(whileMoving: Boolean = false): Anchor? {
        val manager = list.layoutManager as? LinearLayoutManager ?: return null
        // Mid-gesture or mid-fling, the finger owns the position.
        if ((!whileMoving && list.scrollState != RecyclerView.SCROLL_STATE_IDLE) || list.childCount == 0) return null
        if (!list.canScrollVertically(-1)) return Anchor(TOP_KEY, 0, null)
        val shown = (0 until list.childCount).mapNotNull { index ->
            val child = list.getChildAt(index)
            // Rows laid out beyond the edges are not what the reader sees.
            if (manager.getDecoratedBottom(child) <= list.paddingTop || child.top >= list.height) return@mapNotNull null
            val row = adapter.currentList.getOrNull(list.getChildAdapterPosition(child)) ?: return@mapNotNull null
            Anchor(row.key, manager.getDecoratedTop(child) - list.paddingTop, (row as? PreparedTaskRow.Card)?.bucket)
        }.sortedBy { it.offset }
        val first = shown.firstOrNull() ?: return null
        return Anchor(first.key, first.offset, first.bucket, shown.drop(1))
    }

    /**
     * Puts [anchor]'s row back where it was. A row that left, or moved to another status group,
     * hands over to the next row that was on screen, so the reader keeps their place in the list
     * rather than following one task elsewhere.
     */
    private fun keep(anchor: Anchor, rows: List<PreparedTaskRow>) {
        val manager = list.layoutManager as? LinearLayoutManager ?: return
        if (anchor.key == TOP_KEY) {
            manager.scrollToPositionWithOffset(0, 0)
            return
        }
        val positions = rows.withIndex().associate { it.value.key to it.index }
        for (candidate in listOf(anchor) + anchor.next) {
            val position = positions[candidate.key] ?: continue
            val row = rows[position]
            if (candidate.bucket != null && (row as? PreparedTaskRow.Card)?.bucket != candidate.bucket) continue
            manager.scrollToPositionWithOffset(position, candidate.offset)
            return
        }
    }

    private fun checkNearEnd() {
        val manager = list.layoutManager as? LinearLayoutManager ?: return
        if (manager.findLastVisibleItemPosition() >= adapter.itemCount - NEAR_END_ROWS) onNearEnd?.invoke()
    }

    private fun renderChips() {
        chipRow.removeAllViews()
        chipScroller.isVisible = offeredLabels.isNotEmpty()
        addChip(null, context.getString(R.string.task_filter_all), null)
        offeredLabels.forEach { addChip(it.id, it.name, theme.labelColor(it.color)) }
        updateChipSelection()
    }

    private fun addChip(labelId: String?, name: String, dotColor: Int?) {
        val chip = TextView(context).apply {
            text = name
            tag = labelId ?: ALL_TAG
            applyStyle(TaskType.metaMedium, theme.textTertiary)
            gravity = Gravity.CENTER_VERTICAL
            minHeight = resources.getDimensionPixelSize(R.dimen.task_pill_height)
            setPadding(theme.dpInt(12f), 0, theme.dpInt(12f), 0)
            dotColor?.let { color ->
                val size = metrics.dot
                setCompoundDrawablesRelative(
                    GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(color)
                        setSize(size, size)
                        setBounds(0, 0, size, size)
                    },
                    null,
                    null,
                    null,
                )
                compoundDrawablePadding = theme.dpInt(6f)
            }
            setOnClickListener {
                if (selectedLabel == labelId) return@setOnClickListener
                selectedLabel = labelId
                updateChipSelection()
                scrollToTop = true
                prepare()
            }
        }
        val params = LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
        if (chipRow.isNotEmpty()) params.marginStart = theme.dpInt(6f)
        chipRow.addView(chip, params)
    }

    private fun updateChipSelection() {
        val radius = resources.getDimension(R.dimen.task_pill_height) / 2f
        for (index in 0 until chipRow.childCount) {
            val chip = chipRow.getChildAt(index) as TextView
            val selected = chip.tag == (selectedLabel ?: ALL_TAG)
            chip.isSelected = selected
            chip.setTextColor(if (selected) theme.textPrimary else theme.textTertiary)
            chip.background = GradientDrawable().apply {
                cornerRadius = radius
                if (selected) setColor(theme.bgQuaternary)
                else setStroke(theme.hairlinePx.toInt().coerceAtLeast(1), theme.borderPrimary)
            }
        }
    }

    private fun retryButton() = TextView(context).apply {
        theme.applyTo(this, TaskType.metaMedium, theme.textPrimary)
        text = context.getString(R.string.task_detail_retry)
        gravity = Gravity.CENTER
        val padH = theme.dpInt(12f)
        setPadding(padH, 0, padH, 0)
        minHeight = theme.dpInt(40f)
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        clipToRoundedBackground(theme.dp(20f))
        isVisible = false
        setOnClickListener { onRetry?.invoke() }
    }

    /**
     * Hides the card and asks the host to archive it, once; the swipe and the accessibility
     * action both come here.
     */
    private fun archive(id: String) {
        if (!archiving.add(id)) return
        prepare()
        onArchiveTask?.invoke(id)
    }

    private fun TextView.applyStyle(style: TaskTextStyle, color: Int) {
        theme.applyTo(this, style, color)
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }

    /**
     * The "Archive" backdrop behind any card that is moved left, by the finger or by its
     * spring. Drawn by the list rather than the swipe callback so it stays in place for the
     * whole spring, including after the swipe gesture itself has been cleaned up.
     */
    private inner class ArchiveBackdrop : RecyclerView.ItemDecoration() {
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = theme.bgQuaternary }
        private val labelPaint = theme.paint(TaskType.metaMedium, theme.textSecondary).apply {
            textAlign = Paint.Align.RIGHT
        }
        private val bounds = RectF()

        override fun onDraw(c: Canvas, parent: RecyclerView, state: RecyclerView.State) {
            for (index in 0 until parent.childCount) {
                val view = parent.getChildAt(index) as? TaskCardView ?: continue
                val card = view.card ?: continue
                if (view.translationX >= 0f) continue
                bounds.set(
                    (view.left + metrics.gutter).toFloat(),
                    view.top.toFloat(),
                    (view.right - metrics.gutter).toFloat(),
                    (view.top + card.cardHeightPx).toFloat(),
                )
                c.drawRoundRect(bounds, metrics.radius, metrics.radius, fill)
                val baseline = bounds.centerY() - (labelPaint.descent() + labelPaint.ascent()) / 2f
                c.drawText(strings.archive, bounds.right - metrics.pad * 1.5f, baseline, labelPaint)
            }
        }
    }

    /**
     * Left swipe on an archivable card. The finger moves the row; on release a spring carries it
     * off screen or back. Once it has left, the row is hidden until the host has an answer.
     */
    private inner class SwipeToArchive : ItemTouchHelper.SimpleCallback(0, ItemTouchHelper.LEFT) {

        override fun getSwipeDirs(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder): Int {
            val card = adapter.cardAt(viewHolder.bindingAdapterPosition) ?: return 0
            return if (card.archivable) ItemTouchHelper.LEFT else 0
        }

        override fun onMove(
            recyclerView: RecyclerView,
            viewHolder: RecyclerView.ViewHolder,
            target: RecyclerView.ViewHolder,
        ): Boolean = false

        override fun getSwipeThreshold(viewHolder: RecyclerView.ViewHolder): Float = SWIPE_THRESHOLD

        override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
            val card = adapter.cardAt(viewHolder.bindingAdapterPosition) ?: return
            val view = viewHolder.itemView as? TaskCardView ?: return
            val id = card.task.id
            view.whenSwipedOut { archive(id) }
        }

        /** The release motion is a spring driven by the card itself, not a timed animation. */
        override fun getAnimationDuration(
            recyclerView: RecyclerView,
            animationType: Int,
            animateDx: Float,
            animateDy: Float,
        ): Long = 0L

        override fun clearView(recyclerView: RecyclerView, viewHolder: RecyclerView.ViewHolder) {
            // The default resets translationX, which would cut the spring back short.
            if (viewHolder.itemView !is TaskCardView) super.clearView(recyclerView, viewHolder)
        }

        override fun onChildDraw(
            c: Canvas,
            recyclerView: RecyclerView,
            viewHolder: RecyclerView.ViewHolder,
            dX: Float,
            dY: Float,
            actionState: Int,
            isCurrentlyActive: Boolean,
        ) {
            val view = viewHolder.itemView as? TaskCardView
            if (view == null) {
                super.onChildDraw(c, recyclerView, viewHolder, dX, dY, actionState, isCurrentlyActive)
                return
            }
            // While the finger is down it moves the row; after release dX is the destination.
            if (isCurrentlyActive) view.dragTo(dX) else view.releaseTo(dX)
        }
    }

    private companion object {
        const val ALL_TAG = "\u0000all"
        const val ITEM_VIEW_CACHE = 12
        const val SWIPE_THRESHOLD = 0.4f
        const val TOP_KEY = "\u0000top"
        const val STATE_LABEL = "label"
        const val STATE_ANCHOR_KEYS = "anchorKeys"
        const val STATE_ANCHOR_OFFSETS = "anchorOffsets"
        const val STATE_ANCHOR_BUCKETS = "anchorBuckets"
        const val NEAR_END_ROWS = 6
    }
}
