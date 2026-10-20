package surf.comma.android.media.viewer

import android.annotation.SuppressLint
import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.sign

/**
 * The viewer's pages and every gesture on them: pinch and double-tap zoom, panning a zoomed
 * picture, swiping between pictures, and dragging down (or up) to close. Positions follow the
 * finger exactly and settle with the spatial spring, handing over the finger's velocity.
 *
 * Only the current page and its neighbours exist; [PageBinder] fills them in.
 */
class ImageViewerLayout(context: Context) : FrameLayout(context) {
    interface PageBinder {
        val count: Int
        fun bind(page: ViewerPage, index: Int)
        fun unbind(page: ViewerPage, index: Int)
        fun onPageSelected(index: Int) {}
        /** 0 while shown, rising to 1 as a drag-to-close carries the picture away. */
        fun onDismissProgress(fraction: Float) {}
        fun onDismissed() {}
        fun onTap() {}
    }

    var binder: PageBinder? = null
        set(value) {
            field = value
            rebuild()
        }

    var current = 0
        private set

    private val pages = HashMap<Int, ViewerPage>()
    private val recycled = ArrayDeque<ViewerPage>()
    private val gap = 16 * resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val flingVelocity = 700 * resources.displayMetrics.density

    private var pageOffset = 0f
    private var dismissOffset = 0f
    private var dismissing = false
    private val pageSpring = DesignSpring(this, PageOffset, DesignMotion.springSpatial, minimumVisibleChange = 0.5f)
    private val dismissSpring = DesignSpring(this, DismissOffset, DesignMotion.springSpatial, minimumVisibleChange = 0.5f).also {
        it.animation.addEndListener { _, canceled, _, _ -> if (!canceled && dismissing) binder?.onDismissed() }
    }

    private enum class Mode { NONE, PAN, PAGE, DISMISS, ZOOM }
    private var mode = Mode.NONE
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var velocity: VelocityTracker? = null
    private var zoomedThisGesture = false

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            if (dismissing || mode == Mode.DISMISS || mode == Mode.PAGE) return false
            val page = pages[current] ?: return false
            if (page.zoom.geometry == null) return false
            mode = Mode.ZOOM
            zoomedThisGesture = true
            pageSpring.cancel()
            return true
        }

        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val view = pages[current]?.zoom ?: return false
            val geometry = view.geometry ?: return false
            view.jumpTo(geometry.zoomBy(view.state, detector.scaleFactor, detector.focusX - view.left, detector.focusY - view.top))
            return true
        }
    }).apply { isQuickScaleEnabled = false }

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true

        override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
            binder?.onTap()
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            val view = pages[current]?.zoom ?: return false
            val geometry = view.geometry ?: return false
            view.animateTo(geometry.doubleTapTarget(view.state, e.x - view.left, e.y - view.top))
            return true
        }
    })

    private fun rebuild() {
        pages.forEach { (index, page) ->
            binder?.unbind(page, index)
            detachPage(page)
        }
        pages.clear()
        pageOffset = 0f
        layoutPages()
    }

    fun select(index: Int) {
        val count = binder?.count ?: return
        current = index.coerceIn(0, (count - 1).coerceAtLeast(0))
        rebuild()
        binder?.onPageSelected(current)
    }

    fun page(index: Int): ViewerPage? = pages[index]

    private fun layoutPages() {
        val binder = binder ?: return
        val wanted = (current - 1..current + 1).filter { it in 0 until binder.count }.toSet()
        pages.keys.filter { it !in wanted }.forEach { index -> pages.remove(index)?.let { binder.unbind(it, index); detachPage(it) } }
        wanted.forEach { index ->
            if (index !in pages) {
                val page = recycled.removeFirstOrNull() ?: ViewerPage(context)
                addView(page, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                pages[index] = page
                binder.bind(page, index)
            }
        }
        position()
    }

    private fun detachPage(page: ViewerPage) {
        page.zoom.reset()
        removeView(page)
        if (recycled.size < 3) recycled.addLast(page)
    }

    private fun position() {
        val stride = width + gap
        pages.forEach { (index, page) ->
            page.translationX = (index - current) * stride + pageOffset
            page.translationY = if (index == current) dismissOffset else 0f
            page.zoom.startAnimation(index == current && pageOffset == 0f)
        }
        val fraction = if (height > 0) min(1f, abs(dismissOffset) / (height * 0.5f)) else 0f
        binder?.onDismissProgress(fraction)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        position()
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = true

    @SuppressLint("ClickableViewAccessibility") // Taps close chrome through PageBinder.onTap.
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (dismissing) return true
        if (velocity == null) velocity = VelocityTracker.obtain()
        velocity!!.addMovement(event)
        scaleDetector.onTouchEvent(event)
        gestures.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = Mode.NONE
                zoomedThisGesture = false
                downX = event.x; downY = event.y; lastX = event.x; lastY = event.y
                // Catch a settling page or picture mid-flight rather than letting it finish.
                if (pageSpring.isRunning) { pageSpring.cancel(); mode = Mode.PAGE }
                if (dismissSpring.isRunning) { dismissSpring.cancel(); mode = Mode.DISMISS }
            }
            MotionEvent.ACTION_POINTER_DOWN -> { lastX = focusX(event); lastY = focusY(event) }
            MotionEvent.ACTION_POINTER_UP -> {
                // Rebase on the remaining fingers so the picture does not jump.
                lastX = focusX(event, excludeUp = true); lastY = focusY(event, excludeUp = true)
            }
            MotionEvent.ACTION_MOVE -> move(event)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                velocity!!.computeCurrentVelocity(1000)
                release(velocity!!.xVelocity, velocity!!.yVelocity, event.actionMasked == MotionEvent.ACTION_CANCEL)
                velocity!!.recycle()
                velocity = null
                mode = Mode.NONE
            }
        }
        return true
    }

    private fun move(event: MotionEvent) {
        val x = focusX(event)
        val y = focusY(event)
        val dx = x - lastX
        val dy = y - lastY
        lastX = x; lastY = y
        if (mode == Mode.ZOOM || scaleDetector.isInProgress) return
        val view = pages[current]?.zoom
        val geometry = view?.geometry
        if (mode == Mode.NONE) {
            val totalX = x - downX
            val totalY = y - downY
            if (abs(totalX) < touchSlop && abs(totalY) < touchSlop) return
            mode = when {
                event.pointerCount > 1 || zoomedThisGesture -> return
                view != null && geometry != null && view.state.zoomed -> Mode.PAN
                abs(totalX) > abs(totalY) -> Mode.PAGE
                else -> Mode.DISMISS
            }
        }
        when (mode) {
            Mode.PAN -> {
                if (view == null || geometry == null) return
                val (moved, leftover) = geometry.panBy(view.state, dx, dy)
                view.jumpTo(moved)
                // At the picture's edge the rest of the drag turns the page.
                if (abs(leftover) > 0.5f && abs(dx) > abs(dy)) {
                    mode = Mode.PAGE
                    dragPage(leftover)
                }
            }
            Mode.PAGE -> dragPage(dx)
            Mode.DISMISS -> {
                dismissOffset += dy
                position()
            }
            else -> Unit
        }
    }

    private fun dragPage(dx: Float) {
        val count = binder?.count ?: return
        val atEdge = (current == 0 && pageOffset + dx > 0) || (current == count - 1 && pageOffset + dx < 0)
        pageOffset += if (atEdge) dx * EDGE_RESISTANCE else dx
        position()
    }

    private fun release(vx: Float, vy: Float, cancelled: Boolean) {
        val view = pages[current]?.zoom
        val geometry = view?.geometry
        when (mode) {
            Mode.ZOOM, Mode.PAN -> if (view != null && geometry != null) {
                val settled = geometry.clamp(view.state)
                if (settled != view.state) view.animateTo(settled) else view.onSettled?.invoke(settled)
            }
            Mode.PAGE -> settlePage(if (cancelled) 0f else vx)
            Mode.DISMISS -> settleDismiss(if (cancelled) 0f else vy)
            Mode.NONE -> Unit
        }
        if (mode != Mode.PAGE && pageOffset != 0f) settlePage(0f)
    }

    private fun settlePage(vx: Float) {
        val count = binder?.count ?: return
        val stride = width + gap
        var target = current
        if ((pageOffset < -stride * 0.35f || vx < -flingVelocity) && vx <= flingVelocity) target = current + 1
        if ((pageOffset > stride * 0.35f || vx > flingVelocity) && vx >= -flingVelocity) target = current - 1
        target = target.coerceIn(0, count - 1)
        if (target != current) {
            // Re-express the same on-screen position relative to the new current page.
            pageOffset += (target - current) * stride
            pages[current]?.zoom?.let { it.animateTo(ZoomState()) }
            current = target
            layoutPages()
            binder?.onPageSelected(current)
        }
        pageSpring.animateTo(0f, vx)
    }

    private fun settleDismiss(vy: Float) {
        val threshold = height * 0.15f
        val away = (abs(dismissOffset) > threshold && vy * dismissOffset >= 0) || (abs(vy) > flingVelocity && vy * dismissOffset > 0)
        if (away) {
            dismissing = true
            val direction = if (dismissOffset != 0f) sign(dismissOffset) else sign(vy)
            dismissSpring.animateTo(direction * height, vy)
            if (!dismissSpring.isRunning) binder?.onDismissed()
        } else {
            dismissSpring.animateTo(0f, vy)
        }
    }

    private fun focusX(event: MotionEvent, excludeUp: Boolean = false) = focus(event, excludeUp) { event.getX(it) }
    private fun focusY(event: MotionEvent, excludeUp: Boolean = false) = focus(event, excludeUp) { event.getY(it) }
    private inline fun focus(event: MotionEvent, excludeUp: Boolean, value: (Int) -> Float): Float {
        var sum = 0f
        var count = 0
        for (i in 0 until event.pointerCount) {
            if (excludeUp && i == event.actionIndex) continue
            sum += value(i); count++
        }
        return if (count == 0) value(0) else sum / count
    }

    private object PageOffset : FloatPropertyCompat<ImageViewerLayout>("pageOffset") {
        override fun getValue(view: ImageViewerLayout) = view.pageOffset
        override fun setValue(view: ImageViewerLayout, value: Float) { view.pageOffset = value; view.position() }
    }

    private object DismissOffset : FloatPropertyCompat<ImageViewerLayout>("dismissOffset") {
        override fun getValue(view: ImageViewerLayout) = view.dismissOffset
        override fun setValue(view: ImageViewerLayout, value: Float) { view.dismissOffset = value; view.position() }
    }

    private companion object { const val EDGE_RESISTANCE = 0.35f }
}

/** One page: the picture, plus a message when it cannot be shown. */
class ViewerPage(context: Context) : FrameLayout(context) {
    val zoom = ZoomImageView(context)
    val message = android.widget.TextView(context).apply {
        visibility = View.GONE
        gravity = android.view.Gravity.CENTER
        surf.comma.android.ui.theme.DesignTypography.applyTo(this, surf.comma.android.ui.theme.DesignTypography.Level.SMALL)
        setTextColor(context.getColor(android.R.color.white))
        val padding = (24 * resources.displayMetrics.density).toInt()
        setPadding(padding, 0, padding, 0)
    }

    init {
        addView(zoom, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(message, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER))
    }

    /** Page-bound work (decodes) is tagged here so an unbound page can cancel it. */
    var job: kotlinx.coroutines.Job? = null
}
