package surf.comma.android.media.viewer

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.TimeInterpolator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.media.MediaComponents
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.MediaImageLoader
import surf.comma.android.media.ViewerImage
import surf.comma.android.media.ViewerImageBundles
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Full-screen pictures and videos: pinch or double-tap to zoom, drag a zoomed picture, swipe between
 * pages, drag to close with 2D velocity handoff, and save pictures to Photos. Each page first decodes
 * at screen size and decodes again, larger, only when zoomed in far enough to need it. A video page
 * plays while current.
 *
 * Opened from chat tiles ([EXTRA_ROWS]), the viewer grows uniformly out of the tapped tile's rounded
 * aperture and closes back into the current page's tile on five independent springs (center X, center
 * Y, uniform scale, aspect crop, corner radius), preserving drag or predictive-back velocity.
 */
class ImageViewerActivity : ComponentActivity() {
    private lateinit var items: List<ViewerImage>
    private var rows: LongArray? = null
    private var groupIndices: IntArray? = null
    private lateinit var videos: ViewerVideo
    private lateinit var media: MediaComponents
    private lateinit var root: FrameLayout
    internal lateinit var pager: ImageViewerLayout
        private set
    internal lateinit var backdrop: ColorDrawable
        private set
    internal lateinit var chrome: View
        private set
    private lateinit var counter: TextView
    private lateinit var save: ImageButton

    private enum class TransitionState { IDLE, OPENING, CLOSING, BACK_SPRING_BACK }
    private var transitionState = TransitionState.IDLE
    private var closing = false
    private var chromeShown = true
    private var dismissFraction = 0f
    private var backdropFraction = 1f
    private var chromeFraction = 1f
    private var saving = false
    private var hiddenTile: View? = null

    /** Live 5-DOF shared-element state in untransformed [root] coordinates: CX, CY, S, Q, C. */
    private val values = FloatArray(PARTS)
    private lateinit var springs: Array<DesignSpring<ImageViewerActivity>>
    private var endpoints: ViewerTransitionGeometry.Endpoints? = null
    private var dirty = false
    private val hostOrigin = IntArray(2)
    private val screenTileRect = Rect()
    private val tileRectF = RectF()
    private val fittedRectF = RectF()
    internal val currentAperture = RectF()
    internal var currentCornerRadius = 0f
        private set
    internal var currentScale = 1f
        private set

    private var alphaAnimator: ValueAnimator? = null
    private var fallbackFadeAnimator: ValueAnimator? = null
    private var pendingOpenPreDraw: ViewTreeObserver.OnPreDrawListener? = null
    private var pendingFinish: Runnable? = null

    private val applyBeforeDraw = ViewTreeObserver.OnPreDrawListener {
        if (dirty) applyTransition()
        true
    }

    private var maxFling = 0f
    private var backDrag: BackDrag? = null

    private class BackDrag(val startX: Float, val startY: Float, val direction: Float, startedAt: Long) {
        var lastX = startX
        var lastY = startY
        var lastAt = startedAt
        var velocityX = 0f
        var velocityY = 0f
        var offsetX = 0f
        var offsetY = 0f
        var scale = 1f
        var moved = false
    }

    /** Per page: the decode level on screen, and whether it already holds every source pixel. */
    private class PageLoad(val index: Int) {
        var level = 0
        var complete = false
        var failed = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Light system-bar icons on the dark backdrop, in either theme.
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        // Own the open/close motion in-view; system window fades would double-animate over the springs.
        overrideActivityTransition(Activity.OVERRIDE_TRANSITION_OPEN, 0, 0)
        overrideActivityTransition(Activity.OVERRIDE_TRANSITION_CLOSE, 0, 0)
        @Suppress("DEPRECATION")
        items = intent.getParcelableArrayListExtra<Bundle>(EXTRA_ITEMS).orEmpty().map { ViewerImageBundles.read(it) ?: return finish() }
        if (items.isEmpty()) return finish()
        rows = intent.getLongArrayExtra(EXTRA_ROWS)?.takeIf { it.size == items.size }
        groupIndices = intent.getIntArrayExtra(EXTRA_GROUP_INDICES)?.takeIf { it.size == items.size }
        maxFling = ViewConfiguration.get(this).scaledMaximumFlingVelocity.toFloat()
        media = MediaGraph.get(this)
        videos = ViewerVideo(this, media)

        springs = Array(PARTS) { part ->
            DesignSpring(
                target = this,
                property = Part(part),
                token = DesignMotion.zoomOpen,
                minimumVisibleChange = when (part) {
                    CX, CY -> POSITION_STEP
                    S -> SCALE_STEP
                    Q -> CROP_STEP
                    else -> CORNER_STEP
                },
            ).also { spring ->
                spring.animation.addEndListener { _, canceled, _, _ -> if (!canceled) settleIfDone() }
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackStarted(backEvent: BackEventCompat) {
                onPredictiveBackStarted(backEvent)
            }

            override fun handleOnBackProgressed(backEvent: BackEventCompat) {
                onPredictiveBackProgressed(backEvent)
            }

            override fun handleOnBackCancelled() {
                onPredictiveBackCancelled()
            }

            override fun handleOnBackPressed() {
                val release = finishPredictiveBack()
                close(release)
            }
        })

        // Pictures from the signed-in session must not outlive it.
        if (items.any { it !is ViewerImage.Local }) {
            val session = media.http.session.value ?: return finish()
            lifecycleScope.launch {
                media.http.session.drop(1).first { it != session }
                finish()
            }
        }

        root = FrameLayout(this)
        backdrop = ColorDrawable(getColor(R.color.token_bg_overlay))
        root.background = backdrop
        pager = ImageViewerLayout(this)
        root.addView(pager, FrameLayout.LayoutParams(-1, -1))
        chrome = buildChrome()
        root.addView(chrome, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        root.viewTreeObserver.addOnPreDrawListener(applyBeforeDraw)
        ViewCompat.setOnApplyWindowInsetsListener(chrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }

        val restored = savedInstanceState != null
        if (!restored) prepareOpening()
        lifecycleScope.launch {
            val loader = media.images()
            pager.binder = Binder(loader)
            pager.select(savedInstanceState?.getInt(STATE_INDEX) ?: intent.getIntExtra(EXTRA_INDEX, 0))
            if (!restored) pager.post { open() }
        }
    }

    override fun onStart() {
        super.onStart()
        if (::videos.isInitialized) videos.start()
        if (::pager.isInitialized && pager.binder != null && root.alpha >= 1f &&
            !closing && transitionState == TransitionState.IDLE && pendingOpenPreDraw == null
        ) {
            hideCurrentTile()
        }
    }

    override fun onStop() {
        if (::videos.isInitialized) videos.stop()
        if (!closing) showTile()
        super.onStop()
    }

    override fun onDestroy() {
        if (::root.isInitialized) {
            root.viewTreeObserver.removeOnPreDrawListener(applyBeforeDraw)
            clearPendingOpenPreDraw()
            pendingFinish?.let(root::removeCallbacks)
            pendingFinish = null
        }
        if (::springs.isInitialized) springs.forEach { it.cancel() }
        alphaAnimator?.cancel()
        alphaAnimator = null
        fallbackFadeAnimator?.cancel()
        fallbackFadeAnimator = null
        if (::videos.isInitialized) videos.hide()
        showTile()
        super.onDestroy()
    }

    /** Until the opening frame is positioned, keep the viewer invisible so it never flashes full screen first. */
    private fun prepareOpening() {
        if (!ValueAnimator.areAnimatorsEnabled()) return
        root.alpha = 0f
    }

    private fun groupIndexAt(index: Int): Int = groupIndices?.getOrNull(index) ?: -1

    /** Grows the picture uniformly out of the tapped tile's rounded aperture, or fades in when no tile is on screen. */
    private fun open() {
        if (isFinishing || isDestroyed || closing) return
        val row = rows?.getOrNull(pager.current)
        val groupIndex = groupIndexAt(pager.current)
        val ep = if (row != null) resolveEndpoints(row, groupIndex) else null
        if (ep == null || !ValueAnimator.areAnimatorsEnabled()) {
            fadeRootIn()
            return
        }
        endpoints = ep
        transitionState = TransitionState.OPENING
        pager.setTransitionActive(true)
        // Frame 0 sits pixel-for-pixel over the chat tile while the tile stays visible underneath.
        values[CX] = ep.tileCenterX
        values[CY] = ep.tileCenterY
        values[S] = ep.tileScale
        values[Q] = 0f
        values[C] = 0f
        setBackdropAndChrome(0f, 0f)
        root.alpha = 1f
        applyTransition()

        // Hide the underlying chat tile and start the springs right as frame 0 is about to draw.
        val listener = object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                clearPendingOpenPreDraw()
                if (isFinishing || isDestroyed || closing || transitionState != TransitionState.OPENING) return true
                hideTile(row!!, groupIndex)
                val target = floatArrayOf(ep.fitCenterX, ep.fitCenterY, 1f, 1f, 1f)
                animateAll(target, DesignMotion.zoomOpen)
                animateBackdropAndChrome(1f, if (chromeShown) 1f else 0f, DesignMotion.dialogEnter, DesignMotion.smoothOut)
                return true
            }
        }
        pendingOpenPreDraw = listener
        root.viewTreeObserver.addOnPreDrawListener(listener)
        root.invalidate()
    }

    private fun clearPendingOpenPreDraw() {
        pendingOpenPreDraw?.let { listener ->
            if (::root.isInitialized) root.viewTreeObserver.removeOnPreDrawListener(listener)
        }
        pendingOpenPreDraw = null
    }

    private fun fadeRootIn() {
        setBackdropAndChrome(1f, if (chromeShown) 1f else 0f)
        val duration = DesignMotion.durationMillis(DesignMotion.dialogEnter)
        if (duration <= 0L || root.alpha >= 1f) {
            root.alpha = 1f
            return
        }
        fallbackFadeAnimator?.cancel()
        fallbackFadeAnimator = ValueAnimator.ofFloat(root.alpha, 1f).apply {
            this.duration = duration
            interpolator = DesignMotion.smoothOut
            addUpdateListener { root.alpha = it.animatedValue as Float }
            start()
        }
    }

    private fun fadeRootOutAndFinish() {
        val duration = DesignMotion.durationMillis(DesignMotion.dialogExit)
        if (duration <= 0L) {
            finish()
            return
        }
        fallbackFadeAnimator?.cancel()
        fallbackFadeAnimator = ValueAnimator.ofFloat(root.alpha, 0f).apply {
            this.duration = duration
            interpolator = DesignMotion.smoothOut
            addUpdateListener { root.alpha = it.animatedValue as Float }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (!isFinishing && !isDestroyed) finish()
                }
            })
            start()
        }
    }

    /**
     * Closes into the current page's tile when the chat shows it, preserving any drag/back velocity
     * in [release] or live spring velocity if interrupting an open; otherwise fades out (or returns
     * false for a drag release so the pager can fling the picture off screen).
     */
    internal fun close(release: DismissRelease? = null): Boolean {
        if (closing) return true
        val wasOpening = transitionState == TransitionState.OPENING
        val wasSpringBack = transitionState == TransitionState.BACK_SPRING_BACK
        val openNotStarted = pendingOpenPreDraw != null
        clearPendingOpenPreDraw()
        backDrag = null

        val row = rows?.getOrNull(pager.current)
        val groupIndex = groupIndexAt(pager.current)
        if (row != null && groupIndex >= 0) ChatMediaLink.align(row, groupIndex)
        val page = pager.page(pager.current)
        val ep = if (row != null && page != null) resolveEndpoints(row, groupIndex) else null

        if (ep == null || !ValueAnimator.areAnimatorsEnabled()) {
            // For a drag release with no visible tile, let ImageViewerLayout fling the page off screen.
            if (release != null && ep == null && ValueAnimator.areAnimatorsEnabled()) {
                return false
            }
            closing = true
            pager.freeze()
            videos.hide()
            showTile()
            fadeRootOutAndFinish()
            return true
        }

        closing = true
        pager.freeze()
        videos.hide()

        if (wasOpening && openNotStarted) {
            // Closed before the opening frame even left the tile.
            showTile()
            finish()
            return true
        }

        endpoints = ep
        transitionState = TransitionState.CLOSING
        pager.setTransitionActive(true)
        hideTile(row!!, groupIndex)

        val closedTarget = floatArrayOf(ep.tileCenterX, ep.tileCenterY, ep.tileScale, 0f, 0f)

        val effectiveRelease = release ?: if (!wasOpening && !wasSpringBack) pager.currentDismissPose() else null

        if (wasOpening || wasSpringBack) {
            // Reversing mid-open or mid-spring-back: keep the live positions and velocities of all five springs.
            animateClose(closedTarget, velocity = null)
        } else if (effectiveRelease != null) {
            // Interactive drag/back release (or interrupting a spring-back): start from the live drag pose.
            val w = pager.width.toFloat()
            val h = pager.height.toFloat()
            springs.forEach { it.cancel() }
            values[CX] = w / 2f + effectiveRelease.offsetX
            values[CY] = h / 2f + effectiveRelease.offsetY
            values[S] = effectiveRelease.scale
            values[Q] = 1f
            values[C] = 1f
            applyTransition()
            if (release != null) {
                val clamped = FloatArray(2)
                val maxSpeed = MAX_RELEASE_SPEED_DP * resources.displayMetrics.density
                ViewerTransitionGeometry.clampVelocity(
                    effectiveRelease.velocityX,
                    effectiveRelease.velocityY,
                    maxSpeed,
                    clamped,
                )
                val clampedScaleVelocity = ViewerTransitionGeometry.clampClosingScaleVelocity(
                    currentScale = values[S],
                    targetScale = closedTarget[S],
                    rawScaleVelocity = effectiveRelease.scaleVelocity,
                    stiffness = DesignMotion.zoomOpen.stiffness,
                )
                animateClose(
                    target = closedTarget,
                    moveToken = DesignMotion.springFlight,
                    velocity = floatArrayOf(clamped[0], clamped[1], clampedScaleVelocity, 0f, 0f),
                )
            } else {
                animateClose(closedTarget, moveToken = DesignMotion.zoomClose, velocity = null)
            }
        } else {
            // Programmatic close (X button or back key): absorb any active zoom/pan so frame 0 never snaps.
            val w = pager.width.toFloat()
            val h = pager.height.toFloat()
            val zoomState = page!!.zoom.state
            page.zoom.jumpTo(ZoomState())
            springs.forEach { it.cancel() }
            values[CX] = w / 2f + zoomState.offsetX
            values[CY] = h / 2f + zoomState.offsetY
            values[S] = zoomState.scale
            values[Q] = 1f
            values[C] = 1f
            applyTransition()
            animateClose(closedTarget, moveToken = DesignMotion.zoomClose, velocity = null)
        }

        // Fade backdrop and chrome smoothly from their current alpha to 0 (never snapping back to 1).
        animateBackdropAndChrome(0f, 0f, DesignMotion.dialogExit, DesignMotion.smoothOut)
        return true
    }

    /**
     * Drives the closing transition: critically damped flight springs for interactive 2D velocity
     * handoff (or [DesignMotion.zoomClose] for programmatic close) paired with matched critically
     * damped springs for scale, crop and corners so the returning card never undershoots its tile
     * height or squash-stretches on landing.
     */
    private fun animateClose(
        target: FloatArray,
        moveToken: DesignMotion.SpringToken = DesignMotion.zoomClose,
        velocity: FloatArray?,
    ) {
        move(CX, target[CX], moveToken, velocity?.get(CX))
        move(CY, target[CY], moveToken, velocity?.get(CY))
        move(S, target[S], DesignMotion.zoomOpen, velocity?.get(S))
        move(Q, target[Q], DesignMotion.zoomOpen, velocity?.get(Q))
        move(C, target[C], DesignMotion.zoomOpen, velocity?.get(C))
        settleIfDone()
    }

    private fun animateAll(target: FloatArray, token: DesignMotion.SpringToken, velocity: FloatArray? = null) {
        for (part in 0 until PARTS) move(part, target[part], token, velocity?.get(part))
        settleIfDone()
    }

    private fun move(part: Int, target: Float, token: DesignMotion.SpringToken, velocity: Float?) {
        springs[part].use(token)
        springs[part].animateTo(target, velocity)
    }

    private fun settleIfDone() {
        if (springs.any { it.isRunning }) return
        when (transitionState) {
            TransitionState.OPENING -> {
                dirty = false
                transitionState = TransitionState.IDLE
                pager.page(pager.current)?.clearTransitionFrame()
                pager.setTransitionActive(false)
                // Keep the underlying chat tile hidden while the opaque viewer covers it so
                // dragging to dismiss or predictive back never shows two copies or blinks the tile.
            }
            TransitionState.BACK_SPRING_BACK -> {
                dirty = false
                transitionState = TransitionState.IDLE
                pager.page(pager.current)?.clearTransitionFrame()
                pager.setTransitionActive(false)
            }
            TransitionState.CLOSING -> {
                // Flush the final settled spring frame before revealing the chat tile beneath.
                applyTransition()
                dirty = false
                transitionState = TransitionState.IDLE
                alphaAnimator?.cancel()
                setBackdropAndChrome(0f, 0f)
                showTile()
                if (ValueAnimator.areAnimatorsEnabled() && root.isAttachedToWindow) {
                    // Let the revealed chat tile render one frame beneath the pixel-matched viewer before dismissing.
                    pendingFinish?.let(root::removeCallbacks)
                    pendingFinish = Runnable {
                        pendingFinish = null
                        if (!isFinishing && !isDestroyed) finish()
                    }.also(root::postOnAnimation)
                } else {
                    finish()
                }
            }
            TransitionState.IDLE -> {
                dirty = false
            }
        }
    }

    /** Applies the live 5-DOF state to the current page (once per vsync via [applyBeforeDraw]). */
    private fun applyTransition() {
        dirty = false
        val ep = endpoints ?: return
        val page = pager.page(pager.current) ?: return
        val radius = ViewerTransitionGeometry.aperture(
            endpoints = ep,
            centerX = values[CX],
            centerY = values[CY],
            scale = values[S],
            cropProgress = values[Q],
            cornerProgress = values[C],
            outRect = currentAperture,
        )
        currentCornerRadius = radius
        currentScale = values[S].coerceAtLeast(0.01f)
        val useClip = transitionState == TransitionState.OPENING || transitionState == TransitionState.CLOSING
        page.setTransitionFrame(
            centerX = values[CX],
            centerY = values[CY],
            scale = currentScale,
            aperture = if (useClip) currentAperture else null,
            cornerRadius = if (useClip) radius else 0f,
        )
    }

    /** Resolves shared-element endpoints in untransformed [root] coordinates, or null if the tile is off screen. */
    private fun resolveEndpoints(row: Long, imageIndex: Int): ViewerTransitionGeometry.Endpoints? {
        val w = pager.width.toFloat().takeIf { it > 0f } ?: return null
        val h = pager.height.toFloat().takeIf { it > 0f } ?: return null
        if (!ChatMediaLink.bounds(row, screenTileRect, imageIndex)) return null
        // Read origin from the untransformed root container, never from an animated child.
        root.getLocationOnScreen(hostOrigin)
        tileRectF.set(screenTileRect)
        ViewerTransitionGeometry.tileInHost(tileRectF, hostOrigin[0] + pager.left, hostOrigin[1] + pager.top, tileRectF)

        val item = items[pager.current]
        val zoomView = pager.page(pager.current)?.zoom
        val contentW: Float
        val contentH: Float
        val drawable = zoomView?.drawable?.takeIf { it.intrinsicWidth > 0 && it.intrinsicHeight > 0 }
        val geometry = zoomView?.geometry
        val dims = item.dimensions?.takeIf { it.width > 0 && it.height > 0 }
        when {
            drawable != null -> { contentW = drawable.intrinsicWidth.toFloat(); contentH = drawable.intrinsicHeight.toFloat() }
            geometry != null -> { contentW = geometry.contentWidth; contentH = geometry.contentHeight }
            dims != null -> { contentW = dims.width.toFloat(); contentH = dims.height.toFloat() }
            else -> { contentW = tileRectF.width(); contentH = tileRectF.height() }
        }
        ViewerTransitionGeometry.fittedRect(w, h, contentW, contentH, fittedRectF)
        val cornerRadius = ChatMediaLink.cornerRadius(row, imageIndex)
        return ViewerTransitionGeometry.endpoints(tileRectF, fittedRectF, cornerRadius)
    }

    // --- Predictive back gesture ---

    private fun onPredictiveBackStarted(event: BackEventCompat) {
        if (closing || transitionState != TransitionState.IDLE || pager.isGestureActive) return
        val page = pager.page(pager.current) ?: return
        if (page.zoom.state.zoomed) return
        val direction = if (event.swipeEdge == BackEventCompat.EDGE_RIGHT) -1f else 1f
        alphaAnimator?.cancel()
        hideCurrentTile()
        backDrag = BackDrag(event.touchX, event.touchY, direction, backEventTime(event))
        pager.setTransitionActive(true)
    }

    private fun onPredictiveBackProgressed(event: BackEventCompat) {
        val drag = backDrag ?: return
        val w = pager.width.toFloat().takeIf { it > 0f } ?: return
        val h = pager.height.toFloat().takeIf { it > 0f } ?: return
        val now = backEventTime(event)
        if (event.touchX != drag.lastX || event.touchY != drag.lastY) {
            if (now > drag.lastAt) {
                val dt = (now - drag.lastAt) / 1000f
                val stepVx = ((event.touchX - drag.lastX) / dt).coerceIn(-maxFling, maxFling)
                val stepVy = ((event.touchY - drag.lastY) / dt).coerceIn(-maxFling, maxFling)
                drag.velocityX += (stepVx - drag.velocityX) * BACK_VELOCITY_SMOOTHING
                drag.velocityY += (stepVy - drag.velocityY) * BACK_VELOCITY_SMOOTHING
            }
            drag.lastX = event.touchX
            drag.lastY = event.touchY
            drag.lastAt = now
            drag.moved = true
        }
        val travelX = (event.touchX - drag.startX) * drag.direction
        drag.offsetX = travelX.coerceAtLeast(0f) * drag.direction * BACK_FOLLOW_X
        drag.offsetY = (event.touchY - drag.startY) * BACK_FOLLOW_Y
        val travel = hypot(drag.offsetX, drag.offsetY)
        drag.scale = ViewerTransitionGeometry.dragScale(travel, h)
        val fraction = min(1f, travel / (w * 0.6f))
        setBackdropAndChrome(1f - fraction, if (chromeShown) (1f - fraction * 2f).coerceIn(0f, 1f) else 0f)
        pager.page(pager.current)?.setTransitionFrame(
            centerX = w / 2f + drag.offsetX,
            centerY = h / 2f + drag.offsetY,
            scale = drag.scale,
            aperture = null,
            cornerRadius = 0f,
        )
    }

    private fun onPredictiveBackCancelled() {
        val drag = backDrag ?: return
        backDrag = null
        val w = pager.width.toFloat().takeIf { it > 0f } ?: run {
            pager.setTransitionActive(false)
            return
        }
        val h = pager.height.toFloat().takeIf { it > 0f } ?: run {
            pager.setTransitionActive(false)
            return
        }
        val fresh = SystemClock.uptimeMillis() - drag.lastAt < BACK_VELOCITY_WINDOW_MS
        val vx = if (fresh) drag.velocityX * BACK_FOLLOW_X else 0f
        val vy = if (fresh) drag.velocityY * BACK_FOLLOW_Y else 0f
        ViewerTransitionGeometry.fittedRect(w, h, w, h, fittedRectF)
        endpoints = ViewerTransitionGeometry.endpoints(fittedRectF, fittedRectF, 0f)
        transitionState = TransitionState.BACK_SPRING_BACK
        springs.forEach { it.cancel() }
        values[CX] = w / 2f + drag.offsetX
        values[CY] = h / 2f + drag.offsetY
        values[S] = drag.scale
        values[Q] = 1f
        values[C] = 1f
        applyTransition()
        animateAll(
            target = floatArrayOf(w / 2f, h / 2f, 1f, 1f, 1f),
            token = DesignMotion.zoomSpringBack,
            velocity = floatArrayOf(vx, vy, 0f, 0f, 0f),
        )
        animateBackdropAndChrome(1f, if (chromeShown) 1f else 0f, DesignMotion.stateChange, DesignMotion.softInOut)
    }

    private fun finishPredictiveBack(): DismissRelease? {
        val drag = backDrag ?: return null
        backDrag = null
        if (!drag.moved) {
            pager.setTransitionActive(false)
            return null
        }
        val h = pager.height.toFloat().coerceAtLeast(1f)
        val fresh = SystemClock.uptimeMillis() - drag.lastAt < BACK_VELOCITY_WINDOW_MS
        val vx = if (fresh) drag.velocityX else 0f
        val vy = if (fresh) drag.velocityY else 0f
        val travel = hypot(drag.offsetX, drag.offsetY)
        val speed = if (travel > 0f) (drag.offsetX * vx + drag.offsetY * vy) / travel else 0f
        val ds = ViewerTransitionGeometry.dragScaleVelocity(travel, speed, h)
        return DismissRelease(drag.offsetX, drag.offsetY, drag.scale, vx, vy, ds)
    }

    private fun backEventTime(event: BackEventCompat): Long =
        if (event.frameTimeMillis > 0L) event.frameTimeMillis else SystemClock.uptimeMillis()

    // --- Backdrop & chrome alpha ---

    private fun setBackdropAndChrome(backdropAlpha: Float, chromeAlpha: Float) {
        backdropFraction = backdropAlpha.coerceIn(0f, 1f)
        chromeFraction = chromeAlpha.coerceIn(0f, 1f)
        backdrop.alpha = (backdropFraction * 255f).roundToInt()
        chrome.alpha = chromeFraction
        chrome.visibility = if (chromeFraction > 0.001f) View.VISIBLE else View.INVISIBLE
    }

    private fun animateBackdropAndChrome(
        targetBackdrop: Float,
        targetChrome: Float,
        durationToken: Long,
        interpolator: TimeInterpolator,
    ) {
        alphaAnimator?.cancel()
        chrome.animate().cancel()
        val startBackdrop = backdropFraction
        val startChrome = chromeFraction
        val duration = DesignMotion.durationMillis(durationToken)
        if (duration <= 0L) {
            setBackdropAndChrome(targetBackdrop, targetChrome)
            return
        }
        alphaAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            this.duration = duration
            this.interpolator = interpolator
            addUpdateListener { anim ->
                val t = anim.animatedValue as Float
                setBackdropAndChrome(
                    startBackdrop + (targetBackdrop - startBackdrop) * t,
                    startChrome + (targetChrome - startChrome) * t,
                )
            }
            start()
        }
    }

    /** Hides the current page's chat tile (or restores any previously hidden tile if this page has none). */
    private fun hideCurrentTile() {
        val row = rows?.getOrNull(pager.current)
        if (row != null) hideTile(row, groupIndexAt(pager.current)) else showTile()
    }

    /** The tile stands under the moving picture; it shows again once the picture has landed or left. */
    private fun hideTile(row: Long, imageIndex: Int) {
        val next = ChatMediaLink.tile(row, imageIndex)
        if (hiddenTile === next) {
            next?.alpha = 0f
            return
        }
        showTile()
        hiddenTile = next?.also { it.alpha = 0f }
    }

    private fun showTile() {
        hiddenTile?.alpha = 1f
        hiddenTile = null
    }

    private class Part(private val index: Int) : FloatPropertyCompat<ImageViewerActivity>("viewerTransition$index") {
        override fun getValue(activity: ImageViewerActivity) = activity.values[index]
        override fun setValue(activity: ImageViewerActivity, value: Float) {
            activity.values[index] = value
            if (activity.root.isAttachedToWindow && activity.springs[index].isRunning) {
                activity.dirty = true
                activity.root.invalidate()
            } else {
                activity.applyTransition()
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (::pager.isInitialized) outState.putInt(STATE_INDEX, pager.current)
    }

    private inner class Binder(private val loader: MediaImageLoader) : ImageViewerLayout.PageBinder {
        override val count get() = items.size

        override fun bind(page: ViewerPage, index: Int) {
            val load = PageLoad(index)
            page.tag = load
            page.message.visibility = View.GONE
            if (items[index] is ViewerImage.Video) {
                // Only the current page reads and plays its video ([onPageSelected]).
                page.zoom.onSettled = null
                if (index == pager.current) videos.show(page, items[index] as ViewerImage.Video)
                return
            }
            page.zoom.onSettled = { state -> sharpen(page, load, state.scale) }
            // The chat tile's picture stands in until the full decode replaces its pixels in place.
            rows?.getOrNull(index)?.let { row ->
                ChatMediaLink.picture(row, resources, groupIndexAt(index))?.let { page.zoom.setDrawable(it, items[index].dimensions) }
            }
            decode(page, load, level = 1)
        }

        override fun unbind(page: ViewerPage, index: Int) {
            if (items[index] is ViewerImage.Video && index == pager.current) videos.hide()
            page.job?.cancel()
            page.job = null
            page.tag = null
            page.zoom.onSettled = null
        }

        private var paged = false

        override fun onPageSelected(index: Int) {
            counter.text = getString(R.string.media_viewer_counter, index + 1, items.size)
            counter.visibility = if (items.size > 1) View.VISIBLE else View.GONE
            val item = items[index]
            save.visibility = if (item is ViewerImage.Video) View.GONE else View.VISIBLE
            val page = pager.page(index)
            if (item is ViewerImage.Video && page != null) videos.show(page, item) else videos.hide()
            // Paging brings the page's tile into the chat underneath and shifts the hidden-tile
            // mask to it while the opaque backdrop covers the swap, so dragging later never shows two copies.
            if (paged) {
                showTile()
                val row = rows?.getOrNull(index)
                if (row != null) {
                    val groupIndex = groupIndexAt(index)
                    if (groupIndex >= 0) ChatMediaLink.align(row, groupIndex)
                    ChatMediaLink.reveal?.invoke(row)
                    hideTile(row, groupIndex)
                    if (hiddenTile == null) {
                        pager.post {
                            if (!isFinishing && !isDestroyed && !closing && pager.current == index) {
                                hideTile(row, groupIndex)
                            }
                        }
                    }
                }
            }
            paged = true
        }

        override fun onDismissRequested(release: DismissRelease): Boolean = close(release)

        override fun onDismissProgress(fraction: Float) {
            // The transition owns backdrop/chrome while opening, closing, or springing back from predictive back.
            if (transitionState != TransitionState.IDLE || closing) return
            if (fraction > 0f && hiddenTile == null) hideCurrentTile()
            alphaAnimator?.cancel()
            dismissFraction = fraction
            val nextBackdrop = (1f - fraction).coerceIn(0f, 1f)
            val nextChrome = if (chromeShown) (1f - fraction * 2f).coerceIn(0f, 1f) else 0f
            setBackdropAndChrome(nextBackdrop, nextChrome)
        }

        override fun onDismissSpringBack() {
            if (transitionState != TransitionState.IDLE || closing) return
            dismissFraction = 0f
            animateBackdropAndChrome(1f, if (chromeShown) 1f else 0f, DesignMotion.stateChange, DesignMotion.softInOut)
        }

        override fun onDismissed() = finish()

        override fun onTap() {
            if (items[pager.current] is ViewerImage.Video && videos.tap()) return
            val page = pager.page(pager.current)
            val load = page?.tag as? PageLoad
            if (page != null && load?.failed == true) {
                decode(page, load, level = 1)
                return
            }
            chromeShown = !chromeShown
            val targetChrome = if (chromeShown) (1f - dismissFraction * 2f).coerceIn(0f, 1f) else 0f
            animateBackdropAndChrome(backdropFraction, targetChrome, DesignMotion.stateChange, DesignMotion.softInOut)
        }

        private fun sharpen(page: ViewerPage, load: PageLoad, scale: Float) {
            val level = ZoomResolution.level(scale)
            if (!load.complete && !load.failed && level > load.level && page.job?.isActive != true) decode(page, load, level)
        }

        private fun decode(page: ViewerPage, load: PageLoad, level: Int) {
            page.job?.cancel()
            load.failed = false
            page.message.visibility = View.GONE
            val item = items[load.index]
            page.job = lifecycleScope.launch {
                val width = pager.width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
                val height = pager.height.takeIf { it > 0 } ?: resources.displayMetrics.heightPixels
                val box = ZoomResolution.box(width, height, level, maxDecodePixels(width, height))
                try {
                    val drawable = loader.load(item, box.width, box.height)
                    if (page.tag !== load) return@launch
                    page.zoom.setDrawable(drawable, item.dimensions)
                    page.zoom.startAnimation(load.index == pager.current)
                    load.level = level
                    load.complete = ZoomResolution.reachedSource(drawable.intrinsicWidth, drawable.intrinsicHeight, box)
                    // The user may have zoomed further while this decode ran; check once it has ended.
                    page.post { if (page.tag === load) sharpen(page, load, page.zoom.state.scale) }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    if (page.tag !== load) return@launch
                    // A sharper decode failing keeps the picture already on screen.
                    if (page.zoom.drawable == null) {
                        load.failed = true
                        page.message.setText(R.string.media_viewer_load_failed)
                        page.message.visibility = View.VISIBLE
                    }
                }
            }
        }
    }

    /** Four screens' worth, and never more than the upload limit's 16 MP. */
    private fun maxDecodePixels(width: Int, height: Int) = minOf(width.toLong() * height * 4, 16_000_000L)

    private fun buildChrome(): View {
        val density = resources.displayMetrics.density
        val size = (44 * density).toInt()
        val padding = (10 * density).toInt()
        val tint = android.content.res.ColorStateList.valueOf(getColor(android.R.color.white))
        fun button(icon: Int, label: Int, gravity: Int, action: (View) -> Unit) = ImageButton(this).apply {
            setImageResource(icon)
            imageTintList = tint
            background = null
            setPadding(padding, padding, padding, padding)
            contentDescription = getString(label)
            setOnClickListener(action)
            layoutParams = FrameLayout.LayoutParams(size, size, gravity).apply {
                val margin = (8 * density).toInt()
                setMargins(margin, margin, margin, margin)
            }
        }
        counter = TextView(this).apply {
            DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
            setTextColor(getColor(android.R.color.white))
            layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, size, Gravity.TOP or Gravity.CENTER_HORIZONTAL)
                .apply { topMargin = (8 * density).toInt() }
            gravity = Gravity.CENTER
        }
        save = button(R.drawable.ic_media_save, R.string.media_viewer_save, Gravity.TOP or Gravity.END) { saveCurrent() }
        return FrameLayout(this).apply {
            addView(button(R.drawable.ic_media_close, R.string.media_viewer_close, Gravity.TOP or Gravity.START) { close() })
            addView(counter)
            addView(save)
        }
    }

    private fun saveCurrent() {
        if (saving) return
        val item = items.getOrNull(pager.current) ?: return
        saving = true
        save.isEnabled = false
        lifecycleScope.launch {
            val saved = try {
                save(item)
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                false
            } finally {
                saving = false
                save.isEnabled = true
            }
            Toast.makeText(this@ImageViewerActivity,
                if (saved) R.string.media_viewer_saved else R.string.media_viewer_save_failed, Toast.LENGTH_SHORT).show()
        }
    }

    /** The original bytes, not the on-screen decode. */
    private suspend fun save(item: ViewerImage) {
        val name = item.fileName ?: "image"
        when (item) {
            is ViewerImage.Remote -> media.images().withOriginal(item.image) { file ->
                media.gallery.saveImage(name, item.mime) { file.inputStream() }
            }
            is ViewerImage.Local -> media.gallery.saveImage(name, item.mime) {
                contentResolver.openInputStream(item.uri) ?: throw java.io.IOException("Cannot read image")
            }
            is ViewerImage.Video -> throw java.io.IOException("Videos are not saved to Photos")
        }
    }

    companion object {
        private const val CX = 0
        private const val CY = 1
        private const val S = 2
        private const val Q = 3
        private const val C = 4
        private const val PARTS = 5
        private const val POSITION_STEP = 1f
        private const val SCALE_STEP = 0.0015f
        private const val CROP_STEP = 0.003f
        private const val CORNER_STEP = 0.01f
        private const val MAX_RELEASE_SPEED_DP = 2000f

        private const val BACK_FOLLOW_X = 0.55f
        private const val BACK_FOLLOW_Y = 0.45f
        private const val BACK_VELOCITY_SMOOTHING = 0.5f
        private const val BACK_VELOCITY_WINDOW_MS = 100L

        private const val EXTRA_ITEMS = "surf.comma.android.media.viewer.ITEMS"
        private const val EXTRA_INDEX = "surf.comma.android.media.viewer.INDEX"
        private const val EXTRA_ROWS = "surf.comma.android.media.viewer.ROWS"
        private const val EXTRA_GROUP_INDICES = "surf.comma.android.media.viewer.GROUP_INDICES"
        private const val STATE_INDEX = "index"

        fun intent(context: Context, items: List<ViewerImage>, index: Int = 0): Intent {
            require(items.isNotEmpty() && index in items.indices)
            return Intent(context, ImageViewerActivity::class.java)
                .putParcelableArrayListExtra(EXTRA_ITEMS, ArrayList(items.map(ViewerImageBundles::write)))
                .putExtra(EXTRA_INDEX, index)
        }

        fun start(context: Context, items: List<ViewerImage>, index: Int = 0) =
            context.startActivity(intent(context, items, index))

        /**
         * Opens a chat's media: [rows] names each item's timeline row, whose tile ([ChatMediaLink]) the viewer zooms
         * from and back to. [groupIndices] identifies the image index inside a multi-image group row (-1 otherwise).
         */
        fun startFromChat(
            context: Context,
            items: List<ViewerImage>,
            rows: List<Long>,
            index: Int,
            groupIndices: List<Int>? = null,
        ) {
            require(rows.size == items.size)
            val launch = intent(context, items, index).putExtra(EXTRA_ROWS, rows.toLongArray())
            if (groupIndices != null) {
                require(groupIndices.size == items.size)
                launch.putExtra(EXTRA_GROUP_INDICES, groupIndices.toIntArray())
            }
            context.startActivity(launch)
        }
    }
}
