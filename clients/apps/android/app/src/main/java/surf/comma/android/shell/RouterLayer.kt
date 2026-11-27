package surf.comma.android.shell

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.os.SystemClock
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.ui.kit.CornerRadii
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The router chat as one shape that grows out of the tab bar's circle and goes back into it, as the iOS app's zoom
 * transition draws it. A pull down that starts on the chat's top bar, or the system back gesture, holds the shape
 * under the finger and closes it or lets it spring back.
 *
 * Six numbers describe the shape, each with its own spring:
 * - [X], [Y]: its centre's offset from this layer's centre, in px.
 * - [S]: its scale; the circle's width over this layer's width at the circle, 1 open.
 * - [Q]: how far its proportions have gone from a square (0) to this layer's (1).
 * - [C]: how far its corners have rounded to their full radii ([corners]).
 * - [F]: how far the chat has crossfaded in over the circle's picture.
 *
 * The shape is this layer's width W by `W + (H - W) * q`, scaled by s about its centre; its corners are `s * c` of
 * their full radii. The chat is scaled by s and hangs from the shape's top edge, clipped by it. Whatever comes in
 * draws over what goes out.
 *
 * The shape is the circle's glass grown: its fill, and the circle's shadow whenever it is smaller than the layer.
 * While the circle still shows, the shape is the circle too: its corners are at least half its width, it keeps the
 * circle's edge and Comma's mark stands at its top.
 */
@SuppressLint("ViewConstructor")
internal class RouterLayer(
    context: Context,
    private val chat: LiveChatScreen,
    /** The tab bar's circle in this layer's coordinates, or null before it is laid out. */
    private val circle: () -> RectF?,
    /** Each corner's radius at full size. */
    private val corners: () -> CornerRadii,
) : FrameLayout(context) {
    /**
     * How a gesture let the shape go to close. [x] and [y] are the finger's velocity in px/s, which the shape's centre
     * starts at, as in the iOS zoom: not the centre's own velocity along the drag curves. [scale] is the scale's rate
     * per second.
     */
    class Release(val x: Float, val y: Float, val scale: Float)

    /** The layer came on screen (true) or settled closed and went (false). */
    var onShown: ((Boolean) -> Unit)? = null
    /** A pull let go to close. The owner closes the chat and hands [Release] back to [close]. */
    var onPullClose: ((Release) -> Unit)? = null
    /** Each frame the shape is as good as open while it is meant to be open. */
    var onNearlyOpen: (() -> Unit)? = null

    /** Whether the chat is meant to be open; it may still be on its way. */
    var isOpen = false
        private set

    private val values = OPEN.copyOf()
    private val springs = Array(PARTS) { part ->
        DesignSpring(this, Part(part), DesignMotion.zoomOpen, if (part < S) null else FRACTION_STEP).also { spring ->
            spring.animation.addEndListener { _, canceled, _, _ -> if (!canceled) settleIfDone() }
        }
    }
    private val snapshot = Mark(context)
    private var snapshotOnTop = false
    /** The order asked for; it changes only once the chat or the circle shows alone, so nothing pops on a reversal. */
    private var wantSnapshotOnTop = false
    /** The springs moved the numbers since the shape was last drawn from them ([apply] once per frame). */
    private var dirty = false
    private val applyBeforeDraw = android.view.ViewTreeObserver.OnPreDrawListener {
        if (dirty) apply()
        true
    }
    private val shape = RectF()
    private var radii = CornerRadii(0f, 0f, 0f, 0f)
    private val radiiArray = FloatArray(8)
    /** [corners] at full size, read when the shape comes on screen or this layer is laid out. */
    private var fullCorners: CornerRadii? = null
    private val glass = context.getColor(R.color.token_glass_frosted)
    /** The circle's glass under the chat and the mark, solid: nothing under the shape shows through it on its way. */
    private val fill = ColorDrawable(glass or 0xFF000000.toInt())
    /** How strong the shadow under the shape is, as an outline alpha; the circle's glass shadow takes its fill's. */
    private var shadow = 0f
    private val glassAlpha = android.graphics.Color.alpha(glass) / 255f
    /** The circle's hairline edge, drawn inside the shape's outline while the circle still shows. */
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = maxOf(1, (context.resources.displayMetrics.density * 0.5f).toInt()).toFloat()
        color = context.getColor(R.color.token_glass_border)
    }
    private val edgeColor = edge.color
    private val edgePath = android.graphics.Path()
    private val edgeBounds = RectF()
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val maxFling = ViewConfiguration.get(context).scaledMaximumFlingVelocity.toFloat()
    private var pull: Pull? = null
    private var back: Back? = null

    init {
        background = fill
        addView(chat.root, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(snapshot, LayoutParams(0, 0))
        isChildrenDrawingOrderEnabled = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                radii.outline(view, outline, shape)
                outline.alpha = shadow
            }
        }
        // The circle's glass shadow (Kit's glass()), cast by the shape while it is on its way.
        outlineAmbientShadowColor = context.getColor(R.color.token_composer_shadow_ambient)
        outlineSpotShadowColor = context.getColor(R.color.token_composer_shadow_spot)
    }

    // MARK: Program motion

    /** Opens the chat out of the circle, or from wherever the shape is; without [animate] it is open at once. */
    fun open(animate: Boolean) {
        isOpen = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
        endGestures()
        setSnapshotOnTop(false)
        // From the circle; on its way back into it, from where it is, keeping its motion.
        val start = if (visibility == VISIBLE) null else closedState()
        if (!animate || (visibility != VISIBLE && start == null)) {
            jump(OPEN)
            begin()
            settleIfDone()
            return
        }
        // On screen and casting its shadow before the first frame is drawn.
        begin()
        start?.let(::jump)
        animate(OPEN, DesignMotion.zoomOpen)
    }

    /**
     * Takes the chat back into the circle from wherever the shape is. A [release] from a gesture moves the centre,
     * the scale and the rest on their own springs, the centre and the scale starting at its velocity.
     */
    fun close(release: Release? = null) {
        isOpen = false
        // Closing, it is on its way out: what it covers takes touches and accessibility focus.
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        endGestures()
        if (visibility != VISIBLE) return
        val end = closedState() ?: return jumpClosed()
        setSnapshotOnTop(true)
        begin()
        if (release == null) {
            animate(end, DesignMotion.zoomClose)
        } else {
            move(X, end[X], DesignMotion.zoomReleaseMove, release.x)
            move(Y, end[Y], DesignMotion.zoomReleaseMove, release.y)
            move(S, end[S], DesignMotion.zoomReleaseScale, release.scale)
            for (part in Q..F) move(part, end[part], DesignMotion.zoomReleaseShape, 0f)
        }
        settleIfDone()
    }

    /** Closed now, with no motion, as after the activity is recreated on a tab. */
    fun jumpClosed() {
        isOpen = false
        endGestures()
        springs.forEach { it.cancel() }
        settleIfDone()
    }

    /** The circle or this layer moved while closing: the shape goes on to where the circle is now. */
    fun circleMoved() {
        if (isOpen || visibility != VISIBLE || springs.none { it.isRunning }) return
        val end = closedState() ?: return
        for (part in X..S) springs[part].animateTo(end[part])
    }

    private fun animate(target: FloatArray, token: DesignMotion.SpringToken, velocity: FloatArray? = null) {
        for (part in 0 until PARTS) move(part, target[part], token, velocity?.get(part))
        settleIfDone()
    }

    private fun move(part: Int, target: Float, token: DesignMotion.SpringToken, velocity: Float?) {
        springs[part].use(token)
        springs[part].animateTo(target, velocity)
    }

    private fun jump(state: FloatArray) {
        springs.forEach { it.cancel() }
        state.copyInto(values)
        apply()
    }

    /** On screen and clipped to the shape for as long as it is not resting open. */
    private fun begin() {
        if (visibility != VISIBLE) {
            visibility = VISIBLE
            onShown?.invoke(true)
        }
        clipToOutline = true
        fill.alpha = 255
        fullCorners = corners()
    }

    private fun settleIfDone() {
        if (springs.any { it.isRunning } || pull?.dragging == true || back != null) return
        if (isOpen) {
            // Resting open, the chat covers the layer: no clip, shadow or fill under it while it scrolls.
            clipToOutline = false
            elevation = 0f
            fill.alpha = 0
        } else if (visibility == VISIBLE) {
            visibility = GONE
            onShown?.invoke(false)
        }
    }

    private fun setSnapshotOnTop(onTop: Boolean) {
        wantSnapshotOnTop = onTop
        updateDrawingOrder(((1f - values[F]) / FADE_SHARE).coerceIn(0f, 1f))
    }

    /**
     * Takes the asked-for order while only one of the chat and the circle shows. With both part shown, swapping which
     * is on top would change how they blend at once.
     */
    private fun updateDrawingOrder(circleShows: Float) {
        if (wantSnapshotOnTop == snapshotOnTop || (circleShows > 0f && circleShows < 1f)) return
        snapshotOnTop = wantSnapshotOnTop
        invalidate()
    }

    /** [chat] then [snapshot]: whichever comes in draws over the one going out. */
    override fun getChildDrawingOrder(childCount: Int, drawingPosition: Int): Int =
        if (snapshotOnTop) drawingPosition else childCount - 1 - drawingPosition

    private fun size(): Pair<Float, Float>? {
        // Gone, or just come back and not laid out again, this layer keeps the size it had: the card it fills may have
        // changed since (a docked Task, a new window size).
        val laidOut = visibility == VISIBLE && !isLayoutRequested && width > 0
        val source = if (laidOut) this else parent as? View ?: return null
        if (source.width <= 0 || source.height <= 0) return null
        return source.width.toFloat() to source.height.toFloat()
    }

    /** The shape at the circle: a square of the circle's size on its centre, square-cornered, the circle showing. */
    private fun closedState(): FloatArray? {
        val (w, h) = size() ?: return null
        val at = circle() ?: return null
        if (at.width() <= 0f) return null
        return floatArrayOf(at.centerX() - w / 2f, at.centerY() - h / 2f, at.width() / w, 0f, 0f, 0f)
    }

    private fun closedScale(): Float {
        val w = size()?.first ?: return 0f
        return (circle()?.width() ?: 0f) / w
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        if (visibility == VISIBLE) fullCorners = corners()
        apply()
        if (changed) circleMoved()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        viewTreeObserver.addOnPreDrawListener(applyBeforeDraw)
    }

    override fun onDetachedFromWindow() {
        viewTreeObserver.removeOnPreDrawListener(applyBeforeDraw)
        // Springs and the velocity tracker would outlive the view; it rests where it was going.
        endGestures()
        springs.forEach { it.cancel() }
        if (isOpen) jump(OPEN)
        settleIfDone()
        super.onDetachedFromWindow()
    }

    /** Draws the six numbers. */
    private fun apply() {
        dirty = false
        val (w, h) = size() ?: return
        // An underdamped spring or a sharp flick may carry the scale past 0; the shape stays the right way up.
        val s = values[S].coerceAtLeast(0f)
        val shapeWidth = s * w
        val shapeHeight = s * (w + (h - w) * values[Q])
        val left = w / 2f + values[X] - shapeWidth / 2f
        val top = h / 2f + values[Y] - shapeHeight / 2f
        shape.set(left, top, left + shapeWidth, top + shapeHeight)
        // How much the circle still shows: fully until the chat is a third of its way in, gone when it is all in. The
        // chat's content shows for the rest, so near the circle the shape is the circle's solid glass, with no trace
        // of the page in it.
        val circleShows = ((1f - values[F]) / FADE_SHARE).coerceIn(0f, 1f)
        val full = fullCorners ?: corners().also { fullCorners = it }
        val round = s * values[C]
        val most = (minOf(shapeWidth, shapeHeight) / 2f).coerceAtLeast(0f)
        val circular = circleShows * shapeWidth / 2f
        fun corner(radius: Float) = maxOf(radius * round, circular).coerceIn(0f, most)
        radii = CornerRadii(corner(full.topLeft), corner(full.topRight), corner(full.bottomRight), corner(full.bottomLeft))
        // A page on its way casts a clear shadow, which becomes the circle's own as the shape becomes the circle. It
        // comes up over the first tenth of the shrinking, off the screen's edges.
        shadow = (1f + (glassAlpha - 1f) * circleShows) * ((1f - s) / SHADOW_RAMP).coerceIn(0f, 1f)
        if (clipToOutline) elevation = context.dp(PAGE_SHADOW_DP) + (context.dp(SHADOW_DP) - context.dp(PAGE_SHADOW_DP)) * circleShows
        edge.alpha = (android.graphics.Color.alpha(edgeColor) * circleShows).roundToInt()
        invalidateOutline()
        invalidate()
        val page = chat.root
        page.pivotX = 0f
        page.pivotY = 0f
        page.scaleX = s
        page.scaleY = s
        page.translationX = left
        page.translationY = top
        // The crossfade follows the shape, not a clock.
        page.alpha = 1f - circleShows
        snapshot.alpha = circleShows
        updateDrawingOrder(circleShows)
        // The mark stands in a square at the shape's top, the shape's width or its height where that is less.
        val markSide = minOf(shapeWidth, shapeHeight)
        val markLeft = left + (shapeWidth - markSide) / 2f
        snapshot.layout(markLeft.roundToInt(), top.roundToInt(), (markLeft + markSide).roundToInt(), (top + markSide).roundToInt())
        if (isOpen && s >= NEARLY_OPEN && values[Q] >= NEARLY_OPEN) onNearlyOpen?.invoke()
    }

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (edge.alpha == 0 || !clipToOutline) return
        // Inside the outline, which clips everything drawn here.
        val inset = edge.strokeWidth / 2f
        edgeBounds.set(shape.left + inset, shape.top + inset, shape.right - inset, shape.bottom - inset)
        edgePath.reset()
        radiiArray[0] = (radii.topLeft - inset).coerceAtLeast(0f)
        radiiArray[2] = (radii.topRight - inset).coerceAtLeast(0f)
        radiiArray[4] = (radii.bottomRight - inset).coerceAtLeast(0f)
        radiiArray[6] = (radii.bottomLeft - inset).coerceAtLeast(0f)
        for (corner in 0 until 8 step 2) radiiArray[corner + 1] = radiiArray[corner]
        edgePath.addRoundRect(edgeBounds, radiiArray, android.graphics.Path.Direction.CW)
        canvas.drawPath(edgePath, edge)
    }

    // MARK: Pulling down on the top bar

    private class Pull(val pointer: Int, val x: Float, val y: Float) {
        val tracker: VelocityTracker = VelocityTracker.obtain()
        var dragging = false
        var u = 0f
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            // Once it is closing, the chat takes no new touch: what is under it does, the circle included.
            if (!isOpen) return false
            endPull()
            if (springs.none { it.isRunning } && back == null && chat.isOnTopBar(event.y)) {
                pull = Pull(event.getPointerId(0), event.x, event.y)
            }
        }
        val pull = pull ?: return super.dispatchTouchEvent(event)
        pull.tracker.addMovement(event)
        if (!pull.dragging) {
            if (event.actionMasked == MotionEvent.ACTION_MOVE && startsPull(pull, event)) {
                val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
                super.dispatchTouchEvent(cancel)
                cancel.recycle()
            } else {
                if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) endPull()
                return super.dispatchTouchEvent(event)
            }
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> drag(pull, event)
            MotionEvent.ACTION_UP -> letGo(pull, cancelled = false)
            MotionEvent.ACTION_CANCEL -> letGo(pull, cancelled = true)
        }
        return true
    }

    /** A pull starts once the finger has gone down past the touch slop, more down than across. */
    private fun startsPull(pull: Pull, event: MotionEvent): Boolean {
        val index = event.findPointerIndex(pull.pointer)
        if (index < 0) return false
        val dx = event.getX(index) - pull.x
        val dy = event.getY(index) - pull.y
        if (dy > slop && dy > abs(dx)) {
            pull.dragging = true
            parent?.requestDisallowInterceptTouchEvent(true)
            chat.dismissInput()
            springs.forEach { it.cancel() }
            begin()
            return true
        }
        if (abs(dx) > slop || dy < -slop) endPull()
        return false
    }

    private fun drag(pull: Pull, event: MotionEvent) {
        val index = event.findPointerIndex(pull.pointer)
        if (index < 0) return
        val (w, h) = size() ?: return
        pull.u = ((event.getY(index) - pull.y) / h).coerceAtLeast(0f)
        val floor = closedScale()
        val s = PULL_SCALE.value(pull.u).coerceAtLeast(floor)
        val q = PULL_SHAPE.value(pull.u).coerceAtLeast(0f)
        values[X] = PULL_FOLLOW_X * (event.getX(index) - pull.x)
        values[Y] = PULL_TOP.value(pull.u) * h + s * (w + (h - w) * q) / 2f - h / 2f
        values[S] = s
        values[Q] = q
        values[C] = 1f
        values[F] = 1f
        apply()
    }

    private fun letGo(pull: Pull, cancelled: Boolean) {
        pull.tracker.computeCurrentVelocity(1000, maxFling)
        val vx = pull.tracker.getXVelocity(pull.pointer)
        val vy = pull.tracker.getYVelocity(pull.pointer)
        endPull()
        val (w, h) = size() ?: return springBack(null)
        if (cancelled) return springBack(null)
        // How rate of change of each number follows from the finger's, along the measured curves.
        val u = pull.u
        val du = if (u > 0f) vy / h else 0f
        val floor = closedScale()
        val q = values[Q]
        val ds = if (PULL_SCALE.value(u) > floor) PULL_SCALE.slope(u) * du else 0f
        val dq = if (PULL_SHAPE.value(u) > 0f) PULL_SHAPE.slope(u) * du else 0f
        val dy = PULL_TOP.slope(u) * du * h + (ds * (w + (h - w) * q) + values[S] * (h - w) * dq) / 2f
        val done = ((1f - values[S]) / FULL_DISMISS).coerceAtMost(1f)
        val fling = context.dp(FLING_DP)
        val closes = if (abs(vy) > fling) vy > 0f else done >= CLOSE_AT
        if (!closes) return springBack(floatArrayOf(PULL_FOLLOW_X * vx, dy, ds, dq, 0f, 0f))
        val release = Release(vx, vy, ds)
        onPullClose?.invoke(release) ?: close(release)
    }

    private fun endPull() {
        pull?.tracker?.recycle()
        pull = null
    }

    private fun endGestures() {
        endPull()
        back = null
    }

    /** Back to open on one spring, each number starting at its own [velocity] if the gesture gave one. */
    private fun springBack(velocity: FloatArray?) {
        animate(OPEN, DesignMotion.zoomSpringBack, velocity)
    }

    // MARK: The system back gesture

    private class Back(val startX: Float, val direction: Float, startedAt: Long) {
        var lastX = startX
        /** When the finger last moved, in uptime ms. */
        var lastAt = startedAt
        /** The progress the system reported when the finger last moved. */
        var reference = 0f
        var velocity = 0f
        var u = 0f
        /** The touch has moved since the gesture started. Some systems report a back gesture without its touch. */
        var moved = false
        /** Springing back ahead of the system's word that the gesture was cancelled. */
        var returning = false
    }

    fun backStarted(event: BackEventCompat) {
        // Still on its way open, the shape is not held: a back that goes through closes it from where it is
        // ([backReleased] gives null), and one that is cancelled lets it go on opening.
        if (!isOpen || pull?.dragging == true || springs.any { it.isRunning }) return
        endPull()
        springs.forEach { it.cancel() }
        begin()
        back = Back(event.touchX, if (event.swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f, eventTime(event))
    }

    fun backProgressed(event: BackEventCompat) {
        val back = back ?: return
        val (w, h) = size() ?: return
        val now = eventTime(event)
        if (event.touchX != back.lastX) {
            if (now > back.lastAt) {
                // Smoothed and capped: two events close together would otherwise read as a flick of any speed.
                val step = ((event.touchX - back.lastX) * 1000f / (now - back.lastAt)).coerceIn(-maxFling, maxFling)
                back.velocity += (step - back.velocity) * VELOCITY_SMOOTHING
            }
            back.lastX = event.touchX
            back.lastAt = now
            back.reference = event.progress
            back.moved = true
            if (back.returning) {
                // The finger was still down after all: it holds the shape again.
                back.returning = false
                springs.forEach { it.cancel() }
            }
        } else if (!back.returning && back.reference > 0f && event.progress < back.reference * BACK_WINDING) {
            // A cancelled gesture: the system winds its progress back to 0, the touch where it was let go, before it
            // says so. The chat springs back now rather than wait still.
            back.returning = true
            springBack(backVelocity(back, w, h))
            return
        }
        if (back.returning) return
        back.u = ((event.touchX - back.startX) * back.direction / w).coerceAtLeast(0f)
        values[X] = BACK_X.value(back.u) * w * back.direction
        values[Y] = BACK_Y.value(back.u) * h
        values[S] = BACK_SCALE.value(back.u).coerceAtLeast(closedScale())
        values[Q] = 1f
        values[C] = 1f
        values[F] = 1f
        apply()
    }

    /**
     * The gesture closed the chat: how the shape was moving, or null if no gesture was holding it. A back key, or a
     * system that reports the gesture without its touch, closes it as a button does.
     */
    fun backReleased(): Release? {
        val back = back ?: return null
        this.back = null
        if (!back.moved) return null
        val (w, h) = size() ?: return null
        val rates = backVelocity(back, w, h)
        return Release(if (fresh(back)) back.velocity else 0f, 0f, rates[S])
    }

    fun backCancelled() {
        val back = back ?: return
        this.back = null
        if (back.returning) settleIfDone() else size()?.let { (w, h) -> springBack(backVelocity(back, w, h)) } ?: springBack(null)
    }

    private fun fresh(back: Back) = SystemClock.uptimeMillis() - back.lastAt < VELOCITY_WINDOW_MS

    /** When the system drew the gesture's frame, where it says (API 36+); else when it reached the app. */
    private fun eventTime(event: BackEventCompat) =
        if (event.frameTimeMillis > 0L) event.frameTimeMillis else SystemClock.uptimeMillis()

    /** Each number's rate of change along the measured curves, from the finger's last velocity. */
    private fun backVelocity(back: Back, w: Float, h: Float): FloatArray {
        val du = if (back.u > 0f && fresh(back)) back.velocity * back.direction / w else 0f
        val ds = if (BACK_SCALE.value(back.u) > closedScale()) BACK_SCALE.slope(back.u) * du else 0f
        return floatArrayOf(BACK_X.slope(back.u) * du * w * back.direction, BACK_Y.slope(back.u) * du * h, ds, 0f, 0f, 0f)
    }

    // MARK: Parts

    private class Part(private val index: Int) : FloatPropertyCompat<RouterLayer>("router$index") {
        override fun getValue(layer: RouterLayer) = layer.values[index]
        override fun setValue(layer: RouterLayer, value: Float) {
            layer.values[index] = value
            // Each running spring sets its number in turn on a frame: the shape is drawn from all six once, before the
            // frame is drawn. Without a frame to wait for (springs off, or no window) it is drawn now.
            if (layer.isAttachedToWindow && layer.springs[index].isRunning) {
                layer.dirty = true
                layer.invalidate()
            } else {
                layer.apply()
            }
        }
    }

    /** Values measured at increasing inputs, read on straight lines between them and past the last on the last line. */
    private class Curve(private val at: FloatArray, private val values: FloatArray) {
        private fun segment(u: Float): Int {
            var index = 0
            while (index < at.size - 2 && u > at[index + 1]) index++
            return index
        }

        fun slope(u: Float): Float {
            val i = segment(u)
            return (values[i + 1] - values[i]) / (at[i + 1] - at[i])
        }

        fun value(u: Float): Float {
            val i = segment(u)
            return values[i] + slope(u) * (u - at[i])
        }
    }

    /** Comma's mark from the tab bar's circle, at the size of the circle the shape stands for, sharp at any size. */
    private class Mark(context: Context) : View(context) {
        private val mark = context.getDrawable(R.drawable.ic_cue_mark)!!.mutate().apply {
            setTint(context.getColor(R.color.token_text_primary))
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        override fun onDraw(canvas: Canvas) {
            if (width <= 0) return
            val half = (width * ShellTabBar.MARK_DP / ShellTabBar.HEIGHT_DP.toFloat() / 2f).roundToInt()
            val centre = (width / 2f).roundToInt()
            mark.setBounds(centre - half, centre - half, centre + half, centre + half)
            mark.draw(canvas)
        }
    }

    companion object {
        private const val X = 0
        private const val Y = 1
        private const val S = 2
        private const val Q = 3
        private const val C = 4
        private const val F = 5
        private const val PARTS = 6
        private val OPEN = floatArrayOf(0f, 0f, 1f, 1f, 1f, 1f)

        private const val FRACTION_STEP = 0.001f
        /** The circle's glass shadow's elevation. */
        private const val SHADOW_DP = 12
        /** The elevation of the page's shadow while it shrinks; to be tuned on a device. */
        private const val PAGE_SHADOW_DP = 24
        private const val SHADOW_RAMP = 0.1f
        /** The circle shows fully until the chat has come this share short of all the way in. */
        private const val FADE_SHARE = 0.65f
        private const val NEARLY_OPEN = 0.98f
        /** How far the shape has shrunk when a gesture counts as all the way: completion is `(1 - s) / this`. */
        private const val FULL_DISMISS = 0.4f
        private const val CLOSE_AT = 0.5f
        /** A flick down this fast closes whatever the completion; to be tuned on a device. */
        private const val FLING_DP = 1000
        /** The shape's centre follows this share of the finger's sideways travel in a pull. */
        private const val PULL_FOLLOW_X = 0.46f
        /** Progress this far below where it was when the finger last moved, with no move since, means a cancel. */
        private const val BACK_WINDING = 0.85f
        private const val VELOCITY_WINDOW_MS = 100L
        /** How much of each new reading the back gesture's velocity takes. */
        private const val VELOCITY_SMOOTHING = 0.5f

        /** A pull down on the top bar, by its travel over the layer's height: the scale, proportions and top edge. */
        private val PULL_AT = floatArrayOf(0f, 0.025f, 0.05f, 0.10f, 0.15f, 0.20f, 0.25f, 0.30f, 0.35f, 0.40f, 0.45f, 0.50f, 0.55f, 0.60f, 0.65f)
        private val PULL_SCALE = Curve(PULL_AT, floatArrayOf(1f, 0.9997f, 0.9773f, 0.9466f, 0.9085f, 0.8780f, 0.8476f, 0.8093f,
            0.7788f, 0.7483f, 0.7101f, 0.6796f, 0.6415f, 0.6110f, 0.5896f))
        private val PULL_SHAPE = Curve(PULL_AT, floatArrayOf(1f, 1.000f, 0.972f, 0.931f, 0.877f, 0.830f, 0.781f, 0.712f,
            0.653f, 0.589f, 0.501f, 0.424f, 0.318f, 0.222f, 0.149f))
        /** The shape's top edge over the layer's height. */
        private val PULL_TOP = Curve(PULL_AT, floatArrayOf(0f, 0.0005f, 0.0375f, 0.0876f, 0.1487f, 0.1968f, 0.2436f, 0.3016f,
            0.3464f, 0.3899f, 0.4420f, 0.4820f, 0.5288f, 0.5639f, 0.5870f))

        /**
         * The back gesture, by the finger's travel from its start over the layer's width: the scale, and the centre's
         * offset towards the finger over the width and down over the height. The proportions stay the layer's.
         */
        private val BACK_AT = floatArrayOf(0f, 0.05f, 0.10f, 0.15f, 0.20f, 0.25f, 0.30f, 0.35f, 0.40f, 0.45f, 0.50f, 0.55f,
            0.60f, 0.65f, 0.70f, 0.75f, 0.80f, 0.85f)
        private val BACK_SCALE = Curve(BACK_AT, floatArrayOf(1f, 1.0000f, 0.9501f, 0.9171f, 0.8836f, 0.8504f, 0.8176f, 0.7844f,
            0.7507f, 0.7175f, 0.6849f, 0.6510f, 0.6178f, 0.5916f, 0.5742f, 0.5578f, 0.5426f, 0.5278f))
        private val BACK_X = Curve(BACK_AT, floatArrayOf(0f, 0f, 0.0526f, 0.0877f, 0.1228f, 0.1578f, 0.1926f, 0.2275f, 0.2630f,
            0.2980f, 0.3324f, 0.3682f, 0.4032f, 0.4308f, 0.4490f, 0.4664f, 0.4824f, 0.4981f))
        private val BACK_Y = Curve(BACK_AT, floatArrayOf(0f, 0f, 0.0007f, 0.0012f, 0.0017f, 0.0023f, 0.0027f, 0.0032f, 0.0037f,
            0.0042f, 0.0047f, 0.0052f, 0.0056f, 0.0061f, 0.0064f, 0.0066f, 0.0068f, 0.0070f))
    }
}
