package surf.comma.android.chat.render

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.animation.PathInterpolator
import androidx.core.view.doOnNextLayout
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.findViewTreeLifecycleOwner
import kotlinx.coroutines.*
import surf.comma.android.R
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.MediaImageLoader
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.live.ReplyAction
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt

class ChatTimelineView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : RecyclerView(context, attrs, defStyleAttr) {
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            // Handle drags use their own windows; a new touch on the transcript resumes scrolling.
            for (index in 0 until childCount) (getChildAt(index) as? ChatMessageCell)?.clearTextSelection()
        }
        return super.dispatchTouchEvent(event)
    }

    private var mediaScope: CoroutineScope? = null
    private var images: MediaImageLoader? = null
    private var lifecycle: Lifecycle? = null
    private var mediaStarted = false
    private val mediaObserver = object : DefaultLifecycleObserver {
        override fun onStart(owner: LifecycleOwner) { mediaStarted = true; updateVisibleParts() }
        override fun onStop(owner: LifecycleOwner) { mediaStarted = false; updateVisibleParts() }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        lifecycle = findViewTreeLifecycleOwner()?.lifecycle
        mediaStarted = lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true
        lifecycle?.addObserver(mediaObserver)
        mediaScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope ->
            scope.launch { images = MediaGraph.get(context).images(); updateVisibleParts() }
        }
    }

    override fun onDetachedFromWindow() {
        tailSpring.cancel()
        settleGlide(completely = true)
        reveals.finishAll()
        mediaStarted = false
        updateVisibleParts()
        images?.setFastScrolling(false)
        lifecycle?.removeObserver(mediaObserver)
        lifecycle = null
        mediaScope?.cancel(); mediaScope = null
        images = null
        super.onDetachedFromWindow()
    }

    private val reveals = TextRevealBook(resources.displayMetrics.density)
    private val timelineAdapter = ChatTimelineAdapter().also { it.reveals = reveals }
    private var composerInsetPx: Int? = null
    private val composerGapPx = resources.getDimensionPixelSize(R.dimen.spacing_3xl)
    private var hiddenTailPx = 0f
    private val tailSpring = DesignSpring(this, HIDDEN_TAIL, DesignMotion.springSize)
    private val viewportWindow = IntArray(2)

    /**
     * How far the rows are drawn below where they are laid out. A commit that moves the end lays
     * the rows out at rest at once and draws them where they were; this spring then takes them
     * there. It is the only thing that moves the list while a send settles, and later commits are
     * folded into it, so the rows (and the flights aimed at them) never jump or restart.
     *
     * It is every row's translationY, not a canvas offset: touches, long presses and
     * accessibility bounds all land on the rows where they are drawn.
     */
    private var glidePx = 0f
    private val glideSpring = DesignSpring(this, GLIDE, DesignMotion.springFlight, minimumVisibleChange = 0.5f).also { spring ->
        spring.animation.addUpdateListener { _, _, velocity -> glideVelocity = velocity }
        spring.animation.addEndListener { _, _, _, _ ->
            glideVelocity = 0f
            // Rows kept laid out for the glide alone can go now.
            requestLayout()
        }
    }
    private var glideVelocity = 0f

    /** The rows' visual offset from their layout; add it to a row's position to find it on screen. */
    internal val glideOffsetPx: Float get() = glidePx

    /** How fast the glide is moving the rows on screen, in px/s, as of its latest frame. */
    internal val glideVelocityPxPerSecond: Float get() = glideVelocity

    /**
     * A row and its laid-out top before a commit. A short list stacked from the end moves its old
     * rows up in the layout itself, with no scroll; a glide must take that up too.
     */
    private var commitAnchor: Pair<Long, Int>? = null

    /** Resting content end and the send flight's boundary, both in this view's coordinates. */
    internal val contentBottomPx: Int get() = height - (composerInsetPx?.plus(composerGapPx) ?: paddingBottom)
    internal val chatBottomPx: Int get() = height - (composerInsetPx ?: paddingBottom)

    /** Distance from this view's bottom to the actual input capsule's top (including IME lift). */
    fun setComposerInset(insetPx: Int) {
        if (composerInsetPx == insetPx) return
        composerInsetPx = insetPx
        updateBottomPadding()
    }

    /** A frosted host needs the scrolled rows behind the composer; other surfaces keep the hard clip. */
    var drawsBehindComposer: Boolean = false
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    /** The flight stays above the input even when the list draws behind its frosted backdrop. */
    internal fun chatBoundsInWindow(out: RectF) {
        getLocationInWindow(viewportWindow)
        out.set(viewportWindow[0].toFloat(), (viewportWindow[1] + paddingTop).toFloat(),
            (viewportWindow[0] + width).toFloat(), (viewportWindow[1] + chatBottomPx).toFloat())
    }

    override fun draw(canvas: Canvas) {
        val save = canvas.save()
        // The host draws the composer above this content and frosts the rows underneath it.
        if (!drawsBehindComposer) canvas.clipRect(0, 0, width, chatBottomPx.coerceAtLeast(0))
        super.draw(canvas)
        canvas.restoreToCount(save)
    }

    /**
     * [fromCommit]: the change came with a list commit (a reservation appeared or went), not from
     * the composer moving, so while a glide runs it is folded in rather than followed 1:1.
     */
    private fun updateBottomPadding(fromCommit: Boolean = false) {
        val inset = composerInsetPx ?: return
        // Keep the reservation in the layout, below the visible end. It never becomes a gutter.
        val bottom = (inset + composerGapPx - hiddenTailPx.roundToInt()).coerceAtLeast(0)
        if (paddingBottom == bottom) return
        val anchor = if (followMode == FollowMode.READING_HISTORY) visibleAnchor() else null
        setPadding(paddingLeft, paddingTop, paddingRight, bottom)
        if (anchor != null) {
            val child = viewForRow(anchor.messageId)
            if (child != null) timelineLayoutManager.scrollToPositionWithOffset(positionOf(anchor.messageId), child.top - paddingTop)
        } else if (followMode != FollowMode.READING_HISTORY) pinWhenReady(smooth = false, streaming = fromCommit)
    }

    private fun updateHiddenTail(previous: List<PreparedChatMessage>, messages: List<PreparedChatMessage>) {
        val tail = messages.asReversed().takeWhile { it.message.cardKind == LiveRowKinds.REPLY_ACTIONS_RESERVED }
            .sumOf { it.cellHeightPx }.toFloat()
        val revealingActions = tail < hiddenTailPx && previous.lastOrNull()?.message?.cardKind == LiveRowKinds.REPLY_ACTIONS_RESERVED &&
            messages.lastOrNull()?.message?.cardKind == LiveRowKinds.REPLY_ACTIONS
        if (revealingActions && followMode != FollowMode.READING_HISTORY) {
            // The retained reservation becomes visible without a one-frame displacement.
            tailSpring.animateTo(tail)
        } else if (!tailSpring.isRunning || tail != 0f) {
            tailSpring.cancel()
            hiddenTailPx = tail
            updateBottomPadding(fromCommit = true)
        }
    }

    var onImageClick: ((String) -> Unit)?
        get() = timelineAdapter.onImageClick
        set(value) {
            timelineAdapter.onImageClick = value
        }
    var onRetry: ((Long) -> Unit)?
        get() = timelineAdapter.onRetry
        set(value) {
            timelineAdapter.onRetry = value
        }
    var onDiscard: ((Long) -> Unit)?
        get() = timelineAdapter.onDiscard
        set(value) {
            timelineAdapter.onDiscard = value
        }
    /** The failure mark or note of an unsent user message, by row id. */
    var onSendFailed: ((Long) -> Unit)?
        get() = timelineAdapter.onSendFailed
        set(value) {
            timelineAdapter.onSendFailed = value
        }
    var onLongPressMessage: ((View, PreparedChatMessage) -> Unit)?
        get() = timelineAdapter.onLongPress
        set(value) {
            timelineAdapter.onLongPress = value
        }
    var onCopyCode: ((String) -> Unit)?
        get() = timelineAdapter.onCopyCode
        set(value) {
            timelineAdapter.onCopyCode = value
        }
    /** A button under a finished reply; returns whether the action happened. */
    internal var onReplyAction: ((ReplyAction, PreparedChatMessage) -> Boolean)?
        get() = timelineAdapter.onReplyAction
        set(value) {
            timelineAdapter.onReplyAction = value
        }
    var onReadingHistoryChanged: ((Boolean) -> Unit)? = null

    /** What question cards do on this page: answer, add images. Unset, each card shows as its receipt. */
    internal var questionHost: surf.comma.android.chat.live.QuestionCardHost?
        get() = timelineAdapter.questionHost
        set(value) {
            timelineAdapter.questionHost = value
        }

    /** A task brief row was tapped open or closed. */
    var onToggleBrief: ((Long) -> Unit)?
        get() = timelineAdapter.onToggleBrief
        set(value) {
            timelineAdapter.onToggleBrief = value
        }

    /**
     * 底部还有多少内容会滑到 composer 底下去。0 表示已经到底，底边不再是一条边界。
     * 视图只报这个距离，渐隐画多深由 EdgeFeatherView 决定。
     */
    var onBottomOverflowChanged: ((Int) -> Unit)? = null

    /** 滑到窗口顶部附近时请求更早的一页。由 UI 层转给仓库，视图自己不碰数据。 */
    var onLoadOlderHistory: (() -> Unit)? = null

    /** 上面还有历史。false 时连滚动监听都不问，省掉到顶后的空转。 */
    var hasMoreHistory: Boolean = false
    // Short conversations share the same bottom boundary as overflowing ones.
    private val timelineLayoutManager = object : LinearLayoutManager(context) {
        // Rows a glide still draws inside the viewport stay laid out (and attached) until it ends.
        override fun calculateExtraLayoutSpace(state: State, extraLayoutSpace: IntArray) {
            super.calculateExtraLayoutSpace(state, extraLayoutSpace)
            val glide = glidePx
            if (glide > 0f) extraLayoutSpace[0] = maxOf(extraLayoutSpace[0], ceil(glide).toInt())
            else if (glide < 0f) extraLayoutSpace[1] = maxOf(extraLayoutSpace[1], ceil(-glide).toInt())
        }
    }.apply {
        stackFromEnd = true
        initialPrefetchItemCount = 12
    }

    /**
     * Rows that do not fill the list rest on its bottom, as a chat's do. Off, they start at the
     * top: a task page with no messages keeps its status line under the title.
     */
    var stacksFromEnd: Boolean
        get() = timelineLayoutManager.stackFromEnd
        set(value) {
            if (timelineLayoutManager.stackFromEnd != value) timelineLayoutManager.stackFromEnd = value
        }

    private var preparedMessages: List<PreparedChatMessage> = emptyList()
    private var requestedMessages: List<PreparedChatMessage> = emptyList()
    private var followMode = FollowMode.FOLLOWING_LATEST
    /** 翻页时记住的锚：视口里第一条可见消息的 id 和它当时的 top。 */
    private var restoreAnchorId: Long? = null
    private var restoreAnchorTop = 0
    private var lastBottomOverflow = -1
    /** Every pixel the list has scrolled, so a programmatic scroll can read what it moved. */
    private var scrolledPx = 0L

    init {
        // Keyboard focus may rest on the list (after a hardware key, once the composer lets go);
        // the system's focus highlight would then grey the whole list until the next touch.
        defaultFocusHighlightEnabled = false
        reveals.visibleBottom = ::visibleBottomOf
        reveals.onFrame = ::redrawRevealing
        layoutManager = timelineLayoutManager
        adapter = timelineAdapter
        itemAnimator = null
        setHasFixedSize(false)
        setItemViewCacheSize(18)
        recycledViewPool.setMaxRecycledViews(ChatTimelineAdapter.VIEW_TYPE_MESSAGE, 24)
        recycledViewPool.setMaxRecycledViews(ChatTimelineAdapter.VIEW_TYPE_PHOTO, 6)
        overScrollMode = OVER_SCROLL_ALWAYS
        addOnScrollListener(object : OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                scrolledPx += dy
                updateVisibleParts()
                dispatchBottomOverflow()
                if (dy < 0) requestOlderHistoryIfNearTop()
            }

            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                images?.setFastScrolling(newState == SCROLL_STATE_SETTLING)
                updateVisibleParts()
                when {
                    newState == SCROLL_STATE_DRAGGING -> {
                        // A deliberate finger drag always wins over streaming auto-follow.
                        setFollowMode(FollowMode.READING_HISTORY)
                    }
                    newState == SCROLL_STATE_IDLE &&
                        followMode == FollowMode.READING_HISTORY &&
                        !canScrollVertically(1) -> {
                        setFollowMode(FollowMode.FOLLOWING_LATEST)
                    }
                }
            }
        })
    }

    /**
     * The composer grows and the keyboard opens under a conversation that was sitting at the
     * bottom; without this the last reply ends up hidden behind the input bar.
     */
    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        if (height == oldHeight) return
        if (followMode != FollowMode.READING_HISTORY) pinWhenReady(smooth = false)
    }

    /**
     * A changed inset or a committed page moves the bottom without ever scrolling, so the
     * overflow has to be re-read on layout rather than only in [onScrolled].
     */
    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        applyGlide()
        dispatchBottomOverflow()
        updateVisibleParts()
    }

    /** Feed every attached cell the slice of itself that is on screen . */
    fun updateVisibleParts() {
        val glide = glidePx.roundToInt()
        for (index in 0 until childCount) {
            val child = getChildAt(index)
            (child as? ChatMessageCell)?.setVisiblePart(-(child.top + glide), height)
            (child as? TimelineMediaCell)?.setMediaVisible(mediaStarted && child.bottom + glide > paddingTop &&
                child.top + glide < contentBottomPx)
        }
    }

    /**
     * 距离用的是最后可见内容的底边，不包含隐藏的操作栏占位。内容停在这条线上时
     * 下面没有东西会被遮，渐隐就该是 0；最后一个 item 还没进屏幕就按一屏算，满强度。
     */
    internal fun bottomOverflowPx(): Int {
        if (height <= 0 || (!canScrollVertically(1) && glidePx <= 0f)) return 0
        val lastPosition = lastVisibleContentIndex()
        if (lastPosition < 0) return 0
        val last = timelineLayoutManager.findViewByPosition(lastPosition) ?: return height
        return (last.bottom + glidePx.roundToInt() - contentBottomPx).coerceAtLeast(0)
    }

    private fun dispatchBottomOverflow() {
        val overflow = bottomOverflowPx()
        if (overflow == lastBottomOverflow) return
        lastBottomOverflow = overflow
        onBottomOverflowChanged?.invoke(overflow)
    }

    fun submitPrepared(messages: List<PreparedChatMessage>, onCommitted: () -> Unit = {}) {
        if (messages.isEmpty()) {
            setFollowMode(FollowMode.FOLLOWING_LATEST)
        }
        val previousTurnId = latestUserTurnId(requestedMessages)
        val nextTurnId = latestUserTurnId(messages)
        val newTurn = nextTurnId != null && nextTurnId != previousTurnId
        val growth = if (!newTurn && nextTurnId != null) {
            lastTurnHeight(messages) - lastTurnHeight(requestedMessages)
        } else 0
        val sameTurnGrowth = growth > 0
        // A row came or went in the followed turn (the typing row, a reply replacing it): a
        // discrete step that glides. Rows that only grow (streamed text) keep the 1:1 follow.
        val restructured = !newTurn && nextTurnId != null && requestedMessages.isNotEmpty() &&
            lastTurnRowIds(messages) != lastTurnRowIds(requestedMessages)
        val prepended = isHeadPrepend(messages, requestedMessages)
        if (prepended) captureRestoreAnchor()
        // New text is revealed only while the reader follows a reply that is on its way; the
        // first list, a page of history and anything found while reading history appear whole.
        val live = requestedMessages.isNotEmpty() && !prepended && followMode != FollowMode.READING_HISTORY &&
            (awaitingReply(requestedMessages) || reveals.isRunning)
        requestedMessages = messages
        // The lowest row on screen that the commit keeps (a typing row being replaced is not one).
        val kept = messages.mapTo(HashSet()) { it.message.id }
        val anchorBefore = (childCount - 1 downTo 0).asSequence().map(::getChildAt)
            .mapNotNull { child -> preparedMessages.getOrNull(getChildAdapterPosition(child))?.message?.id?.let { it to child.top } }
            .firstOrNull { it.first in kept }
        timelineAdapter.submitList(messages) {
            // Boundary compensation belongs to the committed rows, never to a pending diff.
            val previous = preparedMessages
            preparedMessages = messages
            rowIndex = null
            reveals.onSubmit(previous, messages, live)
            onCommitted()
            updateHiddenTail(previous, messages)
            if (prepended) {
                // 历史接在了前面：把锚点行按原来的位置钉回去，屏幕上的内容一动不动。
                restoreScrollAnchor(messages)
                updateVisibleParts()
                return@submitList
            }
            if (followMode != FollowMode.READING_HISTORY && messages.isNotEmpty()) {
                commitAnchor = anchorBefore
                // 流式增长不再每个 delta 重启一段 180-420ms 的 smoothScroll——那会顿挫；
                // 改成无动画逐帧跟随，只有单帧落差大到一屏才值得一段动画。
                pinWhenReady(
                    smooth = (newTurn && previousTurnId != null) || restructured,
                    streaming = sameTurnGrowth,
                )
            }
            updateVisibleParts()
        }
    }

    /** Stable message identity + physical screen coordinates for the P1 displacement probe. */
    data class VisibleAnchor(val messageId: Long, val topPx: Int)

    fun visibleAnchor(): VisibleAnchor? {
        val position = timelineLayoutManager.findFirstVisibleItemPosition()
        val message = preparedMessages.getOrNull(position) ?: return null
        return messageTopOnScreen(message.message.id)?.let { VisibleAnchor(message.message.id, it) }
    }

    fun messageTopOnScreen(messageId: Long): Int? {
        val position = preparedMessages.indexOfFirst { it.message.id == messageId }
        if (position < 0) return null
        val child = timelineLayoutManager.findViewByPosition(position) ?: return null
        // RecyclerView also attaches offscreen cached/prefetched rows. They are NOT visible anchors.
        if (child.bottom <= paddingTop || child.top >= contentBottomPx) return null
        val location = IntArray(2)
        child.getLocationOnScreen(location)
        return location[1]
    }

    /** Signed distance from the last visible content's bottom, as drawn, to its resting boundary. */
    fun bottomOffsetPx(): Int? {
        val position = lastVisibleContentIndex()
        if (position < 0) return null
        val child = timelineLayoutManager.findViewByPosition(position) ?: return null
        val glide = glidePx.roundToInt()
        if (child.bottom + glide <= paddingTop || child.top + glide >= contentBottomPx) return null
        return child.bottom + glide - contentBottomPx
    }

    fun isPinnedToEnd(): Boolean = followMode != FollowMode.READING_HISTORY

    /**
     * The header over the list changed height and [paddingTop] with it. Following the end, the
     * pin is recomputed for the new viewport; reading history, the content under the header's
     * edge moves with it, so nothing that was visible slides beneath the bar.
     */
    fun shiftForTopInset(deltaPx: Int) {
        if (deltaPx == 0) return
        settleGlide()
        if (followMode != FollowMode.READING_HISTORY) {
            pinWhenReady(smooth = false)
        } else {
            scrollBy(0, -deltaPx)
        }
    }

    /**
     * Back to the latest message from anywhere in the history, in about [JUMP_TO_LATEST_MS].
     *
     * A smooth scroller that has to find its target seeks through the rows in between and then
     * decelerates over the last screen, which took seconds from deep history and still ~0.5 s
     * from close by. Instead the list lands on the exact resting place (from far away, one
     * layout pass brings the end rows in first), steps back at most a screen and glides that
     * last stretch with one fixed-duration smooth scroll. Following resumes, so a reply that
     * is still streaming is followed as it grows.
     */
    fun jumpToLatest() {
        val end = timelineAdapter.itemCount - 1
        if (end < 0) return
        stopScroll()
        settleGlide()
        setFollowMode(FollowMode.FOLLOWING_LATEST)
        val far = timelineLayoutManager.findViewByPosition(end) == null
        if (far) timelineLayoutManager.scrollToPositionWithOffset(end, 0)
        whenLaidOut {
            val beforePin = scrolledPx
            pinLatestTurn(smooth = false)
            if (!ValueAnimator.areAnimatorsEnabled()) return@whenLaidOut
            val viewport = (height - paddingTop - paddingBottom).coerceAtLeast(0)
            val glide = if (far) viewport else (scrolledPx - beforePin).toInt().coerceIn(0, viewport)
            if (glide == 0) return@whenLaidOut
            val beforeStep = scrolledPx
            scrollBy(0, -glide)
            val back = (beforeStep - scrolledPx).toInt()
            if (back > 0) smoothScrollBy(0, back, PROGRAMMATIC_SCROLL_CURVE, JUMP_TO_LATEST_MS)
        }
    }

    private fun whenLaidOut(action: () -> Unit) {
        if (isLayoutRequested || !isLaidOut) doOnNextLayout { action() } else action()
    }

    /**
     * Shows row [rowId] for someone who came to read it: a row in the latest turn that fits on
     * screen is shown the usual way, with its turn; otherwise the row's top goes to the top of
     * the viewport and the list stops following, so the reader starts at its beginning.
     */
    fun revealRow(rowId: Long) {
        val position = positionOf(rowId)
        if (position < 0) return
        whenLaidOut {
            // After the layout: the pin of the update that brought the row may have started a
            // smooth scroll to the end in it. A reply opened to be read appears whole.
            stopScroll()
            settleGlide()
            reveals.finishAll()
            val viewport = (height - paddingTop - paddingBottom).coerceAtLeast(0)
            if (position >= lastTurnStartIndex(preparedMessages) && lastTurnHeight(preparedMessages) <= viewport) {
                setFollowMode(FollowMode.FOLLOWING_LATEST)
                pinLatestTurn(smooth = false)
            } else {
                setFollowMode(FollowMode.READING_HISTORY)
                timelineLayoutManager.scrollToPositionWithOffset(position, 0)
                doOnNextLayout { updateVisibleParts() }
            }
        }
    }

    fun followLatest() {
        setFollowMode(FollowMode.FOLLOWING_LATEST)
        pinWhenReady(smooth = true)
    }

    fun release() {
        reveals.clear()
        timelineAdapter.releaseCards()
    }

    private var rowIndex: HashMap<Long, Int>? = null

    /** The committed list position of a row, or -1. */
    fun positionOf(rowId: Long): Int {
        val index = rowIndex ?: HashMap<Long, Int>(preparedMessages.size).also { map ->
            preparedMessages.forEachIndexed { position, item -> map[item.message.id] = position }
            rowIndex = map
        }
        return index[rowId] ?: -1
    }

    /** The view showing a row, if it is laid out. */
    fun viewForRow(rowId: Long): View? = positionOf(rowId).takeIf { it >= 0 }?.let(timelineLayoutManager::findViewByPosition)

    private fun visibleBottomOf(rowId: Long): Float? {
        val child = viewForRow(rowId) ?: return null
        val top = child.top + glidePx
        if (!child.isLaidOut || child.bottom + glidePx <= paddingTop || top >= contentBottomPx) return null
        return contentBottomPx - top
    }

    private fun redrawRevealing(rowIds: List<Long>) {
        rowIds.forEach { id ->
            val view = viewForRow(id) ?: return@forEach
            if (id !in timelineAdapter.hiddenRows) view.alpha = reveals.cardAlpha(id)
            view.invalidate()
        }
    }

    internal val hiddenRows: Set<Long> get() = timelineAdapter.hiddenRows

    /** Rows the send flight draws itself. They stay invisible, even when rebound, until released. */
    fun setHiddenRows(rowIds: Set<Long>) {
        val previous = timelineAdapter.hiddenRows
        timelineAdapter.hiddenRows = rowIds
        (previous + rowIds).forEach { id ->
            val view = viewForRow(id) ?: return@forEach
            view.alpha = if (id in rowIds) 0f else reveals.cardAlpha(id)
        }
    }

    /**
     * 上滑到窗口顶部附近就预约下一页。阈值取 3 行：等真正见底再请求，用户会看到
     * 一次可见的停顿；提前一屏装载，翻页在观感上就不存在。
     */
    private fun requestOlderHistoryIfNearTop() {
        if (!hasMoreHistory) return
        val first = timelineLayoutManager.findFirstVisibleItemPosition()
        if (first != NO_POSITION && first <= LOAD_OLDER_THRESHOLD) onLoadOlderHistory?.invoke()
    }

    private fun isHeadPrepend(
        next: List<PreparedChatMessage>,
        previous: List<PreparedChatMessage>,
    ): Boolean {
        // Row ids are opaque; a prepend is the old first row reappearing further down.
        val previousHead = previous.firstOrNull()?.message?.id ?: return false
        if (next.size <= previous.size) return false
        return next.indexOfFirst { it.message.id == previousHead } > 0
    }

    private fun captureRestoreAnchor() {
        val position = timelineLayoutManager.findFirstVisibleItemPosition()
        val anchor = requestedMessages.getOrNull(position) ?: requestedMessages.firstOrNull()
        restoreAnchorId = anchor?.message?.id
        restoreAnchorTop = timelineLayoutManager.findViewByPosition(position)?.top ?: paddingTop
    }

    private fun restoreScrollAnchor(messages: List<PreparedChatMessage>) {
        val anchorId = restoreAnchorId ?: return
        restoreAnchorId = null
        val index = messages.indexOfFirst { it.message.id == anchorId }
        if (index < 0) return
        timelineLayoutManager.scrollToPositionWithOffset(index, restoreAnchorTop - paddingTop)
    }

    private var pendingPin: PinKind? = null

    /**
     * Pin after the committed rows and their compensated bottom padding are laid out. Requests
     * made before that layout are one pin, of the gentlest kind asked for: a commit that also
     * changes the padding must not jump first and glide nowhere after.
     */
    private fun pinWhenReady(smooth: Boolean, streaming: Boolean = false) {
        val kind = when {
            smooth -> PinKind.SMOOTH
            streaming -> PinKind.STREAMING
            else -> PinKind.INSTANT
        }
        if (isLayoutRequested || !isLaidOut) {
            val pending = pendingPin
            pendingPin = if (pending == null || kind > pending) kind else pending
            if (pending != null) return
            doOnNextLayout {
                val pin = pendingPin ?: return@doOnNextLayout
                pendingPin = null
                // Reading started meanwhile (a drag, or a reply opened from its notification): keep it.
                if (followMode != FollowMode.READING_HISTORY) pinLatestTurn(pin == PinKind.SMOOTH, pin == PinKind.STREAMING)
            }
        } else {
            pinLatestTurn(smooth, streaming)
        }
    }

    private enum class PinKind { INSTANT, STREAMING, SMOOTH }

    /** Every followed turn rests on its visible end, even when its images exceed the viewport. */
    private fun pinLatestTurn(smooth: Boolean, streaming: Boolean = false) {
        if (preparedMessages.isEmpty() || height <= 0) return
        pinContentEnd(smooth, streaming)
    }

    private fun lastVisibleContentIndex(): Int = preparedMessages.indexOfLast {
        it.message.cardKind != LiveRowKinds.REPLY_ACTIONS_RESERVED
    }

    private fun pinContentEnd(smooth: Boolean, streaming: Boolean = false) {
        val anchor = commitAnchor
        commitAnchor = null
        if (anchor != null && glides(smooth, streaming)) {
            // Rows the layout already moved are drawn where they were; the glide takes them on.
            val shift = viewForRow(anchor.first)?.let { it.top - anchor.second } ?: 0
            if (shift != 0) {
                glideSpring.shiftBy(-shift.toFloat())
                glideSpring.animateTo(0f)
            }
        }
        val endIndex = (timelineAdapter.itemCount - 1).coerceAtLeast(0)
        val targetBottom = height - paddingBottom
        val child = timelineLayoutManager.findViewByPosition(endIndex)
        if (child != null && child.height > 0) {
            applyScroll(child.bottom - targetBottom, smooth, streaming)
            return
        }
        val endHeight = preparedMessages.lastOrNull()?.cellHeightPx ?: 1
        val offset = targetBottom - paddingTop - endHeight
        if (!scrollRowTo(endIndex, offset, smooth, streaming)) timelineLayoutManager.scrollToPositionWithOffset(endIndex, offset)
    }

    /**
     * Puts the top of row [index] [offsetPx] below the top padding by scrolling from a row that is
     * laid out, measuring the rows in between by their prepared heights. Pins mostly run from a
     * layout listener, where a jump by position would request a layout that is dropped until some
     * later update moves the list. Returns false when no row is laid out to measure from.
     */
    private fun scrollRowTo(index: Int, offsetPx: Int, smooth: Boolean = false, streaming: Boolean = false): Boolean {
        val anchor = (0 until childCount).map(::getChildAt)
            .firstOrNull { getChildAdapterPosition(it) in preparedMessages.indices } ?: return false
        val from = getChildAdapterPosition(anchor)
        var top = anchor.top
        if (index > from) for (row in from until index) top += preparedMessages[row].cellHeightPx
        else for (row in index until from) top -= preparedMessages[row].cellHeightPx
        applyScroll(top - paddingTop - offsetPx, smooth, streaming)
        return true
    }

    private fun applyScroll(delta: Int, smooth: Boolean, streaming: Boolean = false) {
        if (delta == 0) return
        // A new turn glides; so does anything a commit moves while a glide or a send flight is
        // under way. Composer and keyboard motion (neither smooth nor streaming) stays 1:1.
        val glide = glides(smooth, streaming)
        if (!ValueAnimator.areAnimatorsEnabled()) {
            // Animations are off: every move lands at once, never through a scroller.
            stopScroll()
            scrollBy(0, delta)
            return
        }
        if (glide) return glideBy(delta)
        // 流式跟随：不重启动画曲线，直接逐帧跟。只有一帧内落差超过一个视口
        // （极端情况，如整块内容瞬间落地）才退回动画，避免瞬移的撕裂感。
        if (streaming && abs(delta) <= height) {
            stopScroll()
            scrollBy(0, delta)
            return
        }
        stopScroll()
        if (smooth || streaming) {
            val duration = (180 + abs(delta) / 7).coerceIn(180, 420)
            smoothScrollBy(0, delta, PROGRAMMATIC_SCROLL_CURVE, duration)
        } else {
            scrollBy(0, delta)
        }
    }

    private fun glides(smooth: Boolean, streaming: Boolean) = ValueAnimator.areAnimatorsEnabled() &&
        (smooth || (streaming && (glideSpring.isRunning || timelineAdapter.hiddenRows.isNotEmpty())))

    /**
     * Lays the rows out [delta] further along at once and draws them where they were; the glide
     * spring, retargeted rather than restarted, carries them the rest of the way.
     */
    private fun glideBy(distance: Int) {
        stopScroll()
        // Everything a glide shows stays laid out, so a catch-up of many screens (a long sync)
        // jumps its excess and glides only the last stretch.
        val limit = (height * MAX_GLIDE_SCREENS - abs(glidePx)).toInt().coerceAtLeast(0)
        val delta = distance.coerceIn(-limit, limit)
        if (delta != distance) scrollBy(0, distance - delta)
        if (delta == 0) return
        val before = scrolledPx
        // First, so the layout keeps the rows the glide still shows above the viewport.
        glideSpring.shiftBy(delta.toFloat())
        scrollBy(0, delta)
        val moved = (scrolledPx - before).toInt()
        if (moved != delta) glideSpring.shiftBy((moved - delta).toFloat())
        glideSpring.animateTo(0f)
    }

    /**
     * Ends a glide where the rows are drawn now: what remains of it becomes a real scroll. A list
     * that cannot scroll that far (shorter than the screen) keeps gliding the rest, so nothing
     * jumps under a finger. [completely] drops any rest, for a view leaving the window.
     */
    private fun settleGlide(completely: Boolean = false) {
        if (glidePx == 0f && !glideSpring.isRunning) return
        val remaining = glidePx.roundToInt()
        val before = scrolledPx
        if (remaining != 0 && isAttachedToWindow) scrollBy(0, -remaining)
        val converted = (before - scrolledPx).toFloat()
        if (completely || abs(glidePx - converted) < 0.5f) {
            glideSpring.cancel()
            glideVelocity = 0f
            glidePx = 0f
        } else {
            glideSpring.shiftBy(-converted)
        }
        onGlide()
    }

    override fun onChildAttachedToWindow(child: View) {
        super.onChildAttachedToWindow(child)
        child.translationY = glidePx
    }

    override fun onChildDetachedFromWindow(child: View) {
        super.onChildDetachedFromWindow(child)
        // A recycled row is bound again somewhere else; it starts from its layout.
        child.translationY = 0f
    }

    private fun applyGlide() {
        for (index in 0 until childCount) getChildAt(index).translationY = glidePx
    }

    private fun onGlide() {
        applyGlide()
        invalidate()
        updateVisibleParts()
        dispatchBottomOverflow()
    }

    private fun setFollowMode(next: FollowMode) {
        if (followMode == next) return
        if (next == FollowMode.READING_HISTORY) settleGlide()
        followMode = next
        onReadingHistoryChanged?.invoke(next == FollowMode.READING_HISTORY)
    }

    private enum class FollowMode {
        FOLLOWING_LATEST,
        READING_HISTORY,
    }

    private companion object {
        val GLIDE = object : FloatPropertyCompat<ChatTimelineView>("glide") {
            override fun getValue(view: ChatTimelineView) = view.glidePx
            override fun setValue(view: ChatTimelineView, value: Float) {
                view.glidePx = value
                view.onGlide()
            }
        }

        val HIDDEN_TAIL = object : FloatPropertyCompat<ChatTimelineView>("hiddenReplyTail") {
            override fun getValue(view: ChatTimelineView) = view.hiddenTailPx
            override fun setValue(view: ChatTimelineView, value: Float) {
                view.hiddenTailPx = value
                view.updateBottomPadding()
            }
        }

        val PROGRAMMATIC_SCROLL_CURVE = PathInterpolator(0.2f, 0f, 0f, 1f)
        const val JUMP_TO_LATEST_MS = 300
        const val MAX_GLIDE_SCREENS = 2
        const val LOAD_OLDER_THRESHOLD = 3
    }
}

/**
 * Whether a reply is on its way: the list ends with the user's message, the agent's status line
 * or a reply still streaming. Only then does new agent text count as arriving live.
 */
internal fun awaitingReply(messages: List<PreparedChatMessage>): Boolean {
    // The space reserved for the reply's buttons is not the reply.
    val last = messages.lastOrNull { it.message.cardKind != LiveRowKinds.REPLY_ACTIONS_RESERVED }?.message ?: return false
    return last.role == ChatRole.USER || last.cardKind == TimelineBlockKinds.LIVE_STATUS ||
        last.status == MessageStatus.STREAMING
}

internal fun latestUserTurnId(messages: List<PreparedChatMessage>): String? =
    messages.lastOrNull { it.message.role == ChatRole.USER }?.let(::stableTurnId)

private fun stableTurnId(message: PreparedChatMessage): String =
    message.message.turnId.ifBlank { "legacy-${message.message.id}" }

/** The first row of the last user turn; a turn may open with several user rows (text, files). */
internal fun lastTurnStartIndex(messages: List<PreparedChatMessage>): Int {
    if (messages.isEmpty()) return 0
    for (index in messages.indices.reversed()) {
        if (messages[index].message.role != ChatRole.USER) continue
        val turn = stableTurnId(messages[index])
        var start = index
        while (start > 0 && messages[start - 1].message.role == ChatRole.USER &&
            stableTurnId(messages[start - 1]) == turn) start--
        return start
    }
    return messages.lastIndex
}

/** The rows of the last turn that show content; the reply-action rows have their own transition. */
internal fun lastTurnRowIds(messages: List<PreparedChatMessage>): List<Long> {
    if (messages.isEmpty()) return emptyList()
    return messages.subList(lastTurnStartIndex(messages), messages.size)
        .filter { it.message.cardKind != LiveRowKinds.REPLY_ACTIONS_RESERVED && it.message.cardKind != LiveRowKinds.REPLY_ACTIONS }
        .map { it.message.id }
}

/** Height of the last user message plus the assistant replies that follow it. */
internal fun lastTurnHeight(messages: List<PreparedChatMessage>): Int {
    if (messages.isEmpty()) return 0
    val start = lastTurnStartIndex(messages)
    var height = 0
    for (index in start until messages.size) {
        height += messages[index].cellHeightPx
    }
    return height
}
