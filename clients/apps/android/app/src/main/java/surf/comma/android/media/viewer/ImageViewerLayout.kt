package surf.comma.android.media.viewer

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
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
 * picture, swiping between pictures, and dragging in 2D to close. Positions follow the finger
 * exactly and settle with spatial springs, handing over the finger's 2D velocity.
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
        /** Called when a drag-to-close is released short of closing and springs back to full screen. */
        fun onDismissSpringBack() {}
        fun onDismissed() {}
        fun onTap() {}
        /**
         * A drag released far enough to close. True when the binder closes the viewer itself (by
         * returning the picture to its chat tile with the gesture's velocity); false lets the
         * picture fly off the screen.
         */
        fun onDismissRequested(release: DismissRelease): Boolean = false
    }

    /** True while a touch gesture or spring-back animation is active in this pager. */
    val isGestureActive: Boolean
        get() = mode != Mode.NONE || pageSpring.isRunning || dismissSpringsRunning

    /** Live drag-to-dismiss pose when the page is displaced or springing back; null at rest. */
    internal fun currentDismissPose(): DismissRelease? {
        if (dismissOffsetX == 0f && dismissOffsetY == 0f && dismissScale == 1f) return null
        return DismissRelease(dismissOffsetX, dismissOffsetY, dismissScale, 0f, 0f, 0f)
    }

    /** Ignores gestures from now on: the viewer is closing. */
    fun freeze() {
        dismissing = true
        trackingGesture = false
        mode = Mode.NONE
        velocity?.recycle()
        velocity = null
        pageSpring.cancel()
        cancelDismissSprings()
    }

    /**
     * Hands ownership of the current page's transform and clip to the activity's shared-element
     * transition, hiding neighbour pages so overshoot or diagonal travel never exposes them.
     */
    fun setTransitionActive(active: Boolean) {
        if (transitionActive == active) return
        transitionActive = active
        if (active) {
            trackingGesture = false
            mode = Mode.NONE
            velocity?.recycle()
            velocity = null
            pageSpring.cancel()
            cancelDismissSprings()
            dismissOffsetX = 0f
            dismissOffsetY = 0f
            dismissScale = 1f
            pageOffset = 0f
            pages.forEach { (index, page) ->
                page.visibility = if (index == current) VISIBLE else INVISIBLE
            }
        } else {
            pages[current]?.clearTransitionFrame()
            position()
        }
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
    private val maxFling = ViewConfiguration.get(context).scaledMaximumFlingVelocity.toFloat()
    private val flingVelocity = 700 * resources.displayMetrics.density

    private var pageOffset = 0f
    private var dismissOffsetX = 0f
    private var dismissOffsetY = 0f
    private var dismissScale = 1f
    private var dismissing = false
    private var transitionActive = false

    private val pageSpring = DesignSpring(this, PageOffset, DesignMotion.springSpatial, minimumVisibleChange = 0.5f)
    private val dismissXSpring = DesignSpring(this, DismissOffsetX, DesignMotion.zoomSpringBack, minimumVisibleChange = 0.5f).also {
        it.animation.addEndListener { _, canceled, _, _ -> if (!canceled) onDismissSpringSettled() }
    }
    private val dismissYSpring = DesignSpring(this, DismissOffsetY, DesignMotion.zoomSpringBack, minimumVisibleChange = 0.5f).also {
        it.animation.addEndListener { _, canceled, _, _ -> if (!canceled) onDismissSpringSettled() }
    }
    private val dismissScaleSpring = DesignSpring(this, DismissScale, DesignMotion.zoomSpringBack, minimumVisibleChange = 0.001f).also {
        it.animation.addEndListener { _, canceled, _, _ -> if (!canceled) onDismissSpringSettled() }
    }

    private val dismissSpringsRunning: Boolean
        get() = dismissXSpring.isRunning || dismissYSpring.isRunning || dismissScaleSpring.isRunning

    private enum class Mode { NONE, PAN, PAGE, DISMISS, ZOOM }
    private var mode = Mode.NONE
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var velocity: VelocityTracker? = null
    private var zoomedThisGesture = false
    private var trackingGesture = false

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
            if (dismissing || transitionActive || mode == Mode.DISMISS || mode == Mode.PAGE) return false
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
            if (!transitionActive && !dismissing) binder?.onTap()
            return true
        }

        override fun onDoubleTap(e: MotionEvent): Boolean {
            if (transitionActive || dismissing) return false
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
        page.clearTransitionFrame()
        page.visibility = VISIBLE
        page.zoom.reset()
        removeView(page)
        if (recycled.size < 3) recycled.addLast(page)
    }

    private fun position() {
        if (transitionActive) {
            pages.forEach { (index, page) ->
                page.visibility = if (index == current) VISIBLE else INVISIBLE
            }
            return
        }
        val stride = width + gap
        val dismissMoved = mode == Mode.DISMISS || dismissing ||
            dismissOffsetX != 0f || dismissOffsetY != 0f || dismissScale != 1f || dismissSpringsRunning
        pages.forEach { (index, page) ->
            page.translationX = (index - current) * stride + pageOffset
            page.translationY = 0f
            if (index == current) {
                page.visibility = VISIBLE
                if (dismissMoved && width > 0 && height > 0) {
                    page.setTransitionFrame(
                        centerX = width / 2f + dismissOffsetX,
                        centerY = height / 2f + dismissOffsetY,
                        scale = dismissScale,
                        aperture = null,
                        cornerRadius = 0f,
                    )
                } else {
                    page.clearTransitionFrame()
                }
            } else {
                page.clearTransitionFrame()
                page.visibility = if (dismissMoved) INVISIBLE else VISIBLE
            }
            page.zoom.startAnimation(index == current && pageOffset == 0f && !dismissMoved)
        }
        val fraction = if (height > 0) min(1f, abs(dismissOffsetY) / (height * 0.5f)) else 0f
        binder?.onDismissProgress(fraction)
    }

    private fun cancelDismissSprings() {
        dismissXSpring.cancel()
        dismissYSpring.cancel()
        dismissScaleSpring.cancel()
    }

    private fun onDismissSpringSettled() {
        if (dismissSpringsRunning) return
        if (dismissing) {
            binder?.onDismissed()
        } else if (!transitionActive && mode != Mode.DISMISS) {
            position()
        }
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        position()
    }

    override fun onDetachedFromWindow() {
        pageSpring.cancel()
        cancelDismissSprings()
        velocity?.recycle()
        velocity = null
        super.onDetachedFromWindow()
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = true

    @SuppressLint("ClickableViewAccessibility") // Taps close chrome through PageBinder.onTap.
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (dismissing || transitionActive) {
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                trackingGesture = false
                mode = Mode.NONE
            }
            return true
        }
        val action = event.actionMasked
        if (action == MotionEvent.ACTION_DOWN) {
            trackingGesture = true
            mode = Mode.NONE
            zoomedThisGesture = false
            downX = event.x; downY = event.y; lastX = event.x; lastY = event.y
            // Catch a settling page or picture mid-flight rather than letting it finish.
            if (pageSpring.isRunning) { pageSpring.cancel(); mode = Mode.PAGE }
            if (dismissSpringsRunning) { cancelDismissSprings(); mode = Mode.DISMISS }
        } else if (!trackingGesture) {
            // ACTION_DOWN arrived while opening transition was still settling: rebase cleanly on
            // the first live MOVE instead of computing a bogus delta against stale/zero lastX/lastY.
            if (action == MotionEvent.ACTION_MOVE) {
                trackingGesture = true
                mode = Mode.NONE
                zoomedThisGesture = false
                val x = focusX(event)
                val y = focusY(event)
                downX = x; downY = y; lastX = x; lastY = y
                velocity?.clear()
                if (velocity == null) velocity = VelocityTracker.obtain()
                velocity!!.addMovement(event)
            }
            return true
        }
        if (velocity == null) velocity = VelocityTracker.obtain()
        velocity!!.addMovement(event)
        scaleDetector.onTouchEvent(event)
        gestures.onTouchEvent(event)
        when (action) {
            MotionEvent.ACTION_POINTER_DOWN -> { lastX = focusX(event); lastY = focusY(event) }
            MotionEvent.ACTION_POINTER_UP -> {
                // Rebase on the remaining fingers so the picture does not jump.
                lastX = focusX(event, excludeUp = true); lastY = focusY(event, excludeUp = true)
            }
            MotionEvent.ACTION_MOVE -> move(event)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val tracker = velocity
                velocity = null
                val vx = if (tracker != null) {
                    tracker.computeCurrentVelocity(1000, maxFling)
                    tracker.xVelocity
                } else 0f
                val vy = tracker?.yVelocity ?: 0f
                tracker?.recycle()
                release(vx, vy, action == MotionEvent.ACTION_CANCEL)
                mode = Mode.NONE
                trackingGesture = false
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
                dismissOffsetX += dx
                dismissOffsetY += dy
                dismissScale = ViewerTransitionGeometry.dragScale(dismissOffsetY, height.toFloat())
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
            Mode.DISMISS -> settleDismiss(if (cancelled) 0f else vx, if (cancelled) 0f else vy)
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

    private fun settleDismiss(vx: Float, vy: Float) {
        val ds = ViewerTransitionGeometry.dragScaleVelocity(dismissOffsetY, vy, height.toFloat())
        val threshold = height * 0.15f
        val away = (abs(dismissOffsetY) > threshold && vy * dismissOffsetY >= 0f) ||
            (abs(vy) > flingVelocity && vy * dismissOffsetY > 0f)
        if (away) {
            val release = DismissRelease(
                offsetX = dismissOffsetX,
                offsetY = dismissOffsetY,
                scale = dismissScale,
                velocityX = vx,
                velocityY = vy,
                scaleVelocity = ds,
            )
            if (binder?.onDismissRequested(release) == true) {
                dismissing = true
                return
            }
            dismissing = true
            val direction = if (dismissOffsetY != 0f) sign(dismissOffsetY) else sign(vy).takeIf { it != 0f } ?: 1f
            dismissXSpring.use(DesignMotion.zoomReleaseMove)
            dismissYSpring.use(DesignMotion.zoomReleaseMove)
            dismissScaleSpring.use(DesignMotion.zoomReleaseScale)
            dismissXSpring.animateTo(dismissOffsetX + vx * 0.2f, vx)
            dismissYSpring.animateTo(direction * height, vy)
            dismissScaleSpring.animateTo(ViewerTransitionGeometry.MIN_DRAG_SCALE, ds)
            if (!dismissSpringsRunning) binder?.onDismissed()
        } else {
            binder?.onDismissSpringBack()
            dismissXSpring.use(DesignMotion.zoomSpringBack)
            dismissYSpring.use(DesignMotion.zoomSpringBack)
            dismissScaleSpring.use(DesignMotion.zoomSpringBack)
            dismissXSpring.animateTo(0f, vx)
            dismissYSpring.animateTo(0f, vy)
            dismissScaleSpring.animateTo(1f, ds)
            if (!dismissSpringsRunning) position()
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

    private object DismissOffsetX : FloatPropertyCompat<ImageViewerLayout>("dismissOffsetX") {
        override fun getValue(view: ImageViewerLayout) = view.dismissOffsetX
        override fun setValue(view: ImageViewerLayout, value: Float) { view.dismissOffsetX = value; view.position() }
    }

    private object DismissOffsetY : FloatPropertyCompat<ImageViewerLayout>("dismissOffsetY") {
        override fun getValue(view: ImageViewerLayout) = view.dismissOffsetY
        override fun setValue(view: ImageViewerLayout, value: Float) { view.dismissOffsetY = value; view.position() }
    }

    private object DismissScale : FloatPropertyCompat<ImageViewerLayout>("dismissScale") {
        override fun getValue(view: ImageViewerLayout) = view.dismissScale
        override fun setValue(view: ImageViewerLayout, value: Float) { view.dismissScale = value; view.position() }
    }

    private companion object { const val EDGE_RESISTANCE = 0.35f }
}

/** One page: the picture, plus a message when it cannot be shown, and an optional rounded clip aperture. */
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

    private val clipRect = RectF()
    private val clipPath = Path()
    private var clipActive = false
    private var clipRadius = 0f

    init {
        addView(zoom, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(message, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, android.view.Gravity.CENTER))
    }

    /** Page-bound work (decodes) is tagged here so an unbound page can cancel it. */
    var job: kotlinx.coroutines.Job? = null

    /**
     * Positions the page's content uniformly scaled about the page centre at ([centerX], [centerY])
     * and optionally clips it to [aperture] with [cornerRadius].
     */
    internal fun setTransitionFrame(
        centerX: Float,
        centerY: Float,
        scale: Float,
        aperture: RectF?,
        cornerRadius: Float,
    ) {
        val w = width.toFloat()
        val h = height.toFloat()
        val s = scale.coerceAtLeast(0.01f)
        val tx = centerX - w / 2f
        val ty = centerY - h / 2f
        applyChildTransform(zoom, w, h, tx, ty, s)
        findViewWithTag<View>(VIDEO_TAG)?.let { applyChildTransform(it, w, h, tx, ty, s) }
        if (aperture != null) {
            clipActive = true
            clipRect.set(aperture)
            clipRadius = cornerRadius.coerceAtLeast(0f)
        } else {
            clipActive = false
            clipRadius = 0f
        }
        invalidate()
    }

    internal fun clearTransitionFrame() {
        resetChildTransform(zoom)
        findViewWithTag<View>(VIDEO_TAG)?.let(::resetChildTransform)
        if (clipActive) {
            clipActive = false
            clipRadius = 0f
            invalidate()
        }
    }

    private fun applyChildTransform(child: View, w: Float, h: Float, tx: Float, ty: Float, s: Float) {
        child.pivotX = w / 2f
        child.pivotY = h / 2f
        child.scaleX = s
        child.scaleY = s
        child.translationX = tx
        child.translationY = ty
    }

    private fun resetChildTransform(child: View) {
        child.scaleX = 1f
        child.scaleY = 1f
        child.translationX = 0f
        child.translationY = 0f
    }

    override fun dispatchDraw(canvas: Canvas) {
        if (!clipActive) {
            super.dispatchDraw(canvas)
            return
        }
        val saved = canvas.save()
        clipPath.reset()
        if (clipRadius > 0f) {
            clipPath.addRoundRect(clipRect, clipRadius, clipRadius, Path.Direction.CW)
        } else {
            clipPath.addRect(clipRect, Path.Direction.CW)
        }
        canvas.clipPath(clipPath)
        super.dispatchDraw(canvas)
        canvas.restoreToCount(saved)
    }
}
