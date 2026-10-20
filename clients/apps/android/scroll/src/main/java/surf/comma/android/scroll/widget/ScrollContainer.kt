package surf.comma.android.scroll.widget

import android.content.Context
import android.graphics.Rect
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.FrameLayout
import kotlin.math.abs
import surf.comma.android.scroll.R

/**
 * A single content view, scrolled by the same RecyclerView/LinearLayoutManager as lists.
 * Use [orientation] (or android:orientation in XML) and add one child with addView.
 * Insets belong to the caller: viewport resizing or padding keeps the focused editor visible.
 */
class ScrollContainer @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {
    companion object {
        const val HORIZONTAL = RecyclerView.HORIZONTAL
        const val VERTICAL = RecyclerView.VERTICAL
    }

    var orientation: Int = VERTICAL
        set(value) {
            require(value == HORIZONTAL || value == VERTICAL)
            if (field == value) return
            field = value
            manager.orientation = value
            updateContentLayoutParams()
            requestLayout()
        }

    var isFillViewport: Boolean = false
        set(value) {
            field = value
            requestLayout()
        }

    /**
     * When the content fits the viewport, decline the whole gesture at ACTION_DOWN so the parent
     * handles it as if this container were not there (taps, long presses, page and drawer drags).
     * Off by default: strips that always own their row keep their sideways drags.
     */
    var yieldsWhenContentFits: Boolean = false

    /**
     * How far the content is scrolled along [orientation], in px from its start edge: 0 shows the
     * content's start, which is its right edge in a right-to-left horizontal container, and the
     * offset grows toward its end in both directions. Overscroll stretch is drawn, not counted.
     * Setting it jumps without animation and is clamped to the content at the next layout, so it
     * can be restored before the content has been measured.
     */
    var scrollOffset: Int
        get() = when {
            contentHost.parent !== scrollingView -> pendingOffset ?: 0
            scrollingView.isLayoutRequested && pendingOffset != null -> pendingOffset!!
            orientation == VERTICAL -> scrollingView.paddingTop - contentHost.top
            // A horizontal LinearLayoutManager lays out from the right in RTL, and so does
            // scrollToPositionWithOffset: measure from that same edge.
            scrollingView.layoutDirection == LAYOUT_DIRECTION_RTL ->
                contentHost.right - (scrollingView.width - scrollingView.paddingRight)
            else -> scrollingView.paddingLeft - contentHost.left
        }
        set(value) {
            scrollingView.stopScroll()
            pendingOffset = value.coerceAtLeast(0)
            manager.scrollToPositionWithOffset(0, -value.coerceAtLeast(0))
        }

    /** Whether the content is wider (or taller) than the viewport along [orientation]. */
    val canScroll: Boolean
        get() = if (orientation == HORIZONTAL) {
            scrollingView.canScrollHorizontally(-1) || scrollingView.canScrollHorizontally(1)
        } else {
            scrollingView.canScrollVertically(-1) || scrollingView.canScrollVertically(1)
        }

    /** Called with [scrollOffset] whenever the content moves: drags, flings and layout clamps. */
    var onScrollOffsetChanged: ((Int) -> Unit)? = null

    /** Stops a running fling or spring-back where it is. */
    fun stopScroll() = scrollingView.stopScroll()

    private var pendingOffset: Int? = null
    private var reportedOffset = 0

    /** Tells [onScrollOffsetChanged] where the content now rests, once per change. */
    private fun reportOffset() {
        if (contentHost.parent !== scrollingView || scrollingView.isComputingLayout) return
        pendingOffset = null
        val offset = scrollOffset
        if (offset == reportedOffset) return
        reportedOffset = offset
        onScrollOffsetChanged?.invoke(offset)
    }

    private var viewportWidth = 0
    private var viewportHeight = 0
    private var pendingFocus: View? = null
    private val lastViewport = Rect()
    private val viewportRect = Rect()
    private val focusRect = Rect()
    private val manager = LinearLayoutManager(context)
    private val contentHost = object : FrameLayout(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            val child = getChildAt(0) ?: return
            if (!isFillViewport || child.visibility == GONE) return
            val lp = child.layoutParams as LayoutParams
            if (orientation == VERTICAL && measuredHeight < viewportHeight) {
                child.measure(
                    MeasureSpec.makeMeasureSpec(child.measuredWidth, MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec((viewportHeight - lp.topMargin - lp.bottomMargin).coerceAtLeast(0), MeasureSpec.EXACTLY),
                )
                setMeasuredDimension(measuredWidth, viewportHeight)
            } else if (orientation == HORIZONTAL && measuredWidth < viewportWidth) {
                child.measure(
                    MeasureSpec.makeMeasureSpec((viewportWidth - lp.leftMargin - lp.rightMargin).coerceAtLeast(0), MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec(child.measuredHeight, MeasureSpec.EXACTLY),
                )
                setMeasuredDimension(viewportWidth, measuredHeight)
            }
        }
    }
    // Module-internal for integration tests; callers configure the container, not its adapter.
    internal val scrollingView = object : RecyclerView(context) {
        override fun requestChildFocus(child: View, focused: View?) {
            super.requestChildFocus(child, focused)
            pendingFocus = focused
            if (!isComputingLayout) revealFocus()
        }
    }

    init {
        context.obtainStyledAttributes(attrs, R.styleable.ScrollContainer, defStyleAttr, 0).let {
            orientation = it.getInt(R.styleable.ScrollContainer_android_orientation, VERTICAL)
            isFillViewport = it.getBoolean(R.styleable.ScrollContainer_android_fillViewport, false)
            it.recycle()
        }
        descendantFocusability = FOCUS_AFTER_DESCENDANTS
        scrollingView.layoutManager = manager
        scrollingView.itemAnimator = null
        scrollingView.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) = reportOffset()
        })
        updateContentLayoutParams()
        // Keep XML descendants discoverable (findViewById) before the first adapter layout.
        // The host moves into the RecyclerView exactly once, when its holder is created.
        super.addView(contentHost, -1, contentHost.layoutParams)
        super.addView(scrollingView, -1, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        scrollingView.adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun getItemCount() = 1
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
                pendingFocus = contentHost.findFocus()
                detachContentHost()
                return object : RecyclerView.ViewHolder(contentHost) {}
            }
            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) = Unit
        }
    }

    private fun detachContentHost() = super.removeView(contentHost)

    private fun updateContentLayoutParams() {
        contentHost.layoutParams = if (orientation == VERTICAL) {
            RecyclerView.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        } else {
            RecyclerView.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT)
        }
    }

    override fun generateDefaultLayoutParams() = if (orientation == VERTICAL) {
        LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    } else {
        LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    }

    override fun addView(child: View, index: Int, params: ViewGroup.LayoutParams) {
        check(contentHost.childCount == 0) { "ScrollContainer accepts one direct content view" }
        contentHost.addView(child, index, if (params is LayoutParams) params else LayoutParams(params))
    }

    override fun removeView(view: View) {
        pendingFocus = null
        contentHost.removeView(view)
    }

    override fun removeAllViews() {
        pendingFocus = null
        contentHost.removeAllViews()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        scrollingView.setPadding(paddingLeft, paddingTop, paddingRight, paddingBottom)
        scrollingView.clipToPadding = clipToPadding
        scrollingView.clipChildren = clipChildren
        contentHost.clipChildren = clipChildren
        scrollingView.isHorizontalScrollBarEnabled = isHorizontalScrollBarEnabled
        scrollingView.isVerticalScrollBarEnabled = isVerticalScrollBarEnabled
        scrollingView.overScrollMode = overScrollMode
        viewportWidth = if (MeasureSpec.getMode(widthMeasureSpec) != MeasureSpec.EXACTLY) 0
            else (MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight).coerceAtLeast(0)
        viewportHeight = if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.EXACTLY) 0
            else (MeasureSpec.getSize(heightMeasureSpec) - paddingTop - paddingBottom).coerceAtLeast(0)
        // Padding is applied inside the RecyclerView, so clipToPadding=false exposes the gutter.
        scrollingView.measure(widthMeasureSpec, heightMeasureSpec)
        setMeasuredDimension(scrollingView.measuredWidthAndState, scrollingView.measuredHeightAndState)
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        scrollingView.layout(0, 0, right - left, bottom - top)
        // A layout may move the content without a scroll: a restored offset, or one clamped
        // because the content became narrower.
        reportOffset()
        pendingFocus?.let { if (!it.isFocused) it.requestFocus() }
        viewportRect.set(paddingLeft, paddingTop, width - paddingRight, height - paddingBottom)
        if (pendingFocus != null || viewportRect != lastViewport) revealFocus()
        lastViewport.set(viewportRect)
    }

    private fun revealFocus() {
        val focused = pendingFocus ?: contentHost.findFocus() ?: return
        if (contentHost.parent !== scrollingView || focused.width == 0 || scrollingView.isComputingLayout) return
        focusRect.set(0, 0, focused.width, focused.height)
        contentHost.offsetDescendantRectToMyCoords(focused, focusRect)
        scrollingView.stopScroll()
        manager.requestChildRectangleOnScreen(scrollingView, contentHost, focusRect, true)
        pendingFocus = null
    }

    /** Jump to a physical edge, e.g. show the newest thumbnail with fullScroll(FOCUS_RIGHT). */
    fun fullScroll(direction: Int): Boolean {
        val rect = when (direction) {
            FOCUS_LEFT -> Rect(0, 0, 1, 1)
            FOCUS_RIGHT -> Rect((contentHost.width - 1).coerceAtLeast(0), 0, contentHost.width, 1)
            FOCUS_UP -> Rect(0, 0, 1, 1)
            FOCUS_DOWN -> Rect(0, (contentHost.height - 1).coerceAtLeast(0), 1, contentHost.height)
            else -> return false
        }
        scrollingView.stopScroll()
        return manager.requestChildRectangleOnScreen(scrollingView, contentHost, rect, true)
    }

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var axisDecided = false

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // Declining DOWN keeps the rest of the gesture away from this container.
        if (event.actionMasked == MotionEvent.ACTION_DOWN && yieldsWhenContentFits && !canScroll) return false
        if (orientation == HORIZONTAL) {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.x
                    downY = event.y
                    axisDecided = false
                    // Let this strip decide the axis before a vertical ancestor intercepts.
                    parent?.requestDisallowInterceptTouchEvent(true)
                }
                MotionEvent.ACTION_MOVE -> if (!axisDecided) {
                    val dx = abs(event.x - downX)
                    val dy = abs(event.y - downY)
                    if (maxOf(dx, dy) > touchSlop) {
                        axisDecided = true
                        if (dy > dx) {
                            parent?.requestDisallowInterceptTouchEvent(false)
                            // Cancel the strip's gesture; the ancestor can take the next move.
                            val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                            super.dispatchTouchEvent(cancel)
                            cancel.recycle()
                            return false
                        }
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> parent?.requestDisallowInterceptTouchEvent(false)
            }
        }
        return super.dispatchTouchEvent(event)
    }
}
