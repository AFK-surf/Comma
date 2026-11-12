package surf.comma.android.shell

import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.RenderNode
import android.view.View
import androidx.core.graphics.withTranslation
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.widget.GlassLens
import surf.comma.android.ui.widget.GlassShape
import kotlin.math.abs
import kotlin.math.roundToInt

/** The tab under [x], in a bar of [count] tabs each [itemWidth] wide. */
internal fun tabAt(x: Float, itemWidth: Int, count: Int): Int =
    if (itemWidth <= 0) 0 else (x / itemWidth).toInt().coerceIn(0, count - 1)

/** The lens grows from the [rest] size to the [lifted] size as [lift] goes from 0 to 1, and lands where it starts. */
internal fun lensSize(rest: Float, lifted: Float, lift: Float): Float = rest + (lifted - rest) * lift

/** Where a finger that has stopped at [x] lets the lens rest: on a tab close by, otherwise right where it is. */
internal fun lensRest(x: Float, itemWidth: Int, count: Int): Float {
    val center = (tabAt(x, itemWidth, count) + 0.5f) * itemWidth
    val away = center - x
    return if (abs(away) < itemWidth * TabBarLens.SNAP_REACH) center else x
}

/** How long after a release on its own tab the lens starts to land: at once, unless a tap has barely shown it lifted. */
internal fun lensLandDelay(upMs: Long): Long = (TabBarLens.MIN_UP_MS - upMs).coerceAtLeast(0L)

/** The lifted lens's width: as on iOS for its height, but no wider against a tab than iOS's, so it clears the screen edge. */
internal fun lensLiftedWidth(height: Float, itemWidth: Float): Float =
    minOf(height * TabBarLens.LIFTED_ASPECT, itemWidth * TabBarLens.LIFTED_TAB_SHARE)

/** The lens's width as a share of its own for a [stretch] along the drag. */
internal fun lensWidthShare(stretch: Float): Float = 1f + stretch

/** Height gives way more than width gains, and a lens that has rebounded narrow only swells a little. */
internal fun lensHeightShare(stretch: Float): Float = if (stretch > 0f) 1f - 1.4f * stretch else 1f - 0.5f * stretch

/**
 * The clear glass the tab bar's indicator lifts into under a finger, with its motion measured frame by frame from the
 * iOS tab bar. It lifts out of the indicator in about 100 ms, follows the finger with no snapping, stretches along its
 * way while it moves and rebounds narrow and tall as it arrives, and rests on a tab only once the finger stops. A finger
 * that lets go does not land it: it flies on to its tab still lifted, overshooting a little, and lands there, shrinking
 * into the indicator as the indicator fades in. [record] draws what lies under it, in this view's coordinates.
 */
internal class TabBarLens(context: Context, private val record: (Canvas) -> Unit) : View(context) {
    private val density = resources.displayMetrics.density
    private val pad = (PAD_DP * density).roundToInt()
    private val page = context.getColor(R.color.token_bg_primary)
    private val node = RenderNode("tab-bar-lens")
    private val lens = GlassLens(context, R.color.token_glass_tint_lens, shadow = SHADOW, dispersion = DISPERSION, falls = false, highlightDp = 4f, clearEdge = true,
        blurs = false, depthShare = RIM_REACH, sideShare = SIDE_REACH, ringShare = RING, bandShare = 1.2f, flare = FLARE, paleFringe = 0.55f, iridescence = 0.018f, dims = false, innerShadow = INNER_SHADOW, inset = 0f,
        shadowReachDp = 20f, shadowDropDp = 7f)
    private var center = 0f
    private var lift = 0f
    private var liftTarget = 0f
    private var stretch = 0f
    private var lastMoveNanos = 0L
    private var peakStretch = 0f
    /** It has braked and is piling up: nothing moves it until that has run. */
    private var rebounding = false
    private val rebound = Runnable {
        rebounding = false
        jelly.animateTo(0f)
    }
    private var restWidth = 0f
    private var restHeight = 0f
    private var liftedWidth = 0f
    private var liftedHeight = 0f
    private val move = DesignSpring(this, CENTER, FOLLOW)
    private val rise = DesignSpring(this, LIFT, RISE, 0.002f)
    private val jelly = DesignSpring(this, STRETCH, JELLY, 0.001f)

    private var liftNanos = 0L
    /** Where it is flying to after a release, if it has not got there yet. */
    private var flyingTo = Float.NaN
    private val land = Runnable {
        flyingTo = Float.NaN
        liftTarget = 0f
        rise.animateTo(0f)
        onLanding?.invoke()
    }

    /** Runs as the lens lifts or lands, with how far up it is; and once it has landed. */
    var onLift: ((Float) -> Unit)? = null
    /** Runs with the lens's centre as it moves, so the indicator can ride inside it. */
    var onMoved: ((Float) -> Unit)? = null
    /** Runs as the lens starts to come down. */
    var onLanding: (() -> Unit)? = null
    var onLanded: (() -> Unit)? = null

    /** The bar under the lens, in this view's coordinates. */
    var barLeft = 0f
    var barRight = 0f

    init {
        visibility = GONE
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        isClickable = false
    }

    fun setSizes(restWidthPx: Float, restHeightPx: Float, liftedWidthPx: Float, liftedHeightPx: Float) {
        restWidth = restWidthPx
        restHeight = restHeightPx
        liftedWidth = liftedWidthPx
        liftedHeight = liftedHeightPx
    }

    /** Lifts at [from], where the indicator rests. */
    fun lift(from: Float) {
        removeCallbacks(land)
        flyingTo = Float.NaN
        // A press while it is still coming down picks it up where it is.
        if (visibility != VISIBLE) {
            move.cancel()
            center = from
            onMoved?.invoke(from)
        }
        lastMoveNanos = 0L
        liftNanos = System.nanoTime()
        visibility = VISIBLE
        liftTarget = 1f
        rise.animateTo(1f)
    }

    fun moveTo(x: Float) = move.animateTo(x)

    /** Lands at [x], where the indicator will rest, once it has got there. */
    fun drop(x: Float) {
        move.animateTo(x)
        removeCallbacks(land)
        val distance = abs(x - center) / density
        if (distance > ARRIVED_DP) {
            flyingTo = x
            // It lands on arrival; this only covers a flight that never reports getting there.
            postDelayed(land, MAX_FLIGHT_MS)
        } else {
            flyingTo = Float.NaN
            postDelayed(land, lensLandDelay((System.nanoTime() - liftNanos) / 1_000_000))
        }
    }

    private fun setCenter(value: Float) {
        val now = System.nanoTime()
        val elapsed = (now - lastMoveNanos) / 1e9f
        if (lastMoveNanos != 0L && elapsed in 0.001f..0.1f) {
            val speed = abs(value - center) / elapsed
            val target = (speed / (FULL_STRETCH_SPEED_DP * density)).coerceAtMost(1f) * MAX_STRETCH
            if (target > peakStretch) peakStretch = target
            if (rebounding) {
                if (target > MIN_REBOUND) { removeCallbacks(rebound); rebound.run() }
            } else if (peakStretch > MIN_REBOUND && target < peakStretch * BRAKING) {
                // It has come in fast and is braking: it piles up narrow and tall before it settles.
                jelly.animateTo(-peakStretch * REBOUND)
                peakStretch = 0f
                rebounding = true
                removeCallbacks(rebound)
                postDelayed(rebound, REBOUND_MS)
            } else if (peakStretch > 0f) {
                jelly.animateTo(target)
            }
        }
        lastMoveNanos = now
        center = value
        onMoved?.invoke(value)
        if (!flyingTo.isNaN() && abs(value - flyingTo) / density <= ARRIVED_DP) {
            removeCallbacks(land)
            land.run()
        }
        invalidate()
    }

    private fun setLift(value: Float) {
        lift = value
        // The spring runs on a little after the lens has gone: the indicator is on its own by then.
        if (visibility != VISIBLE) return
        // On the node, not the view: a view fading through a layer would clip the lens and its shadow to its bounds.
        node.alpha = (value / FADE_SHARE).coerceIn(0f, 1f)
        onLift?.invoke(value.coerceIn(0f, 1f))
        if (liftTarget == 0f && value <= LANDED) {
            visibility = GONE
            stretch = 0f
            peakStretch = 0f
            rebounding = false
            removeCallbacks(rebound)
            onLanded?.invoke()
        }
        invalidate()
    }

    private fun setStretch(value: Float) {
        stretch = value
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (!canvas.isHardwareAccelerated || width == 0) return
        val up = lift.coerceIn(0f, 1f)
        val shapeWidth = lensSize(restWidth, liftedWidth, lift) * (1f + (lensWidthShare(stretch) - 1f) * up)
        val shapeHeight = lensSize(restHeight, liftedHeight, lift) * (1f + (lensHeightShare(stretch) - 1f) * up)
        val middle = height / 2f
        val shape = Rect(
            (center - shapeWidth / 2f).roundToInt(), (middle - shapeHeight / 2f).roundToInt(),
            (center + shapeWidth / 2f).roundToInt(), (middle + shapeHeight / 2f).roundToInt(),
        )
        // Recorded larger by as much as the lens magnifies, so what it magnifies stays sharp.
        node.setPosition(0, 0, ((width + pad * 2) * ZOOM).roundToInt(), ((height + pad * 2) * ZOOM).roundToInt())
        val recording = node.beginRecording()
        try {
            // The page first: the rim reaches past what is recorded otherwise, and splits transparency into colour.
            recording.drawColor(page)
            recording.scale(ZOOM, ZOOM)
            recording.translate(pad.toFloat(), pad.toFloat())
            record(recording)
        } finally { node.endRecording() }
        val recorded = Rect(((shape.left + pad) * ZOOM).roundToInt(), ((shape.top + pad) * ZOOM).roundToInt(),
            ((shape.right + pad) * ZOOM).roundToInt(), ((shape.bottom + pad) * ZOOM).roundToInt())
        lens.setShapes(GlassShape(recorded, recorded.height() / 2f), null, 0, 0, 0f)
        val reach = END_REACH_DP * density
        lens.setEnds(((barLeft - shape.left) / reach).coerceIn(0f, 1f), ((shape.right - barRight) / reach).coerceIn(0f, 1f))
        lens.setZoom(1f + (ZOOM - 1f) * up, (center + pad) * ZOOM, (middle + pad) * ZOOM)
        node.setRenderEffect(lens.effect())
        canvas.withTranslation(-pad.toFloat(), -pad.toFloat()) {
            scale(1f / ZOOM, 1f / ZOOM)
            drawRenderNode(node)
        }
    }

    companion object {
        /** Taller than the bar, wider than a tab, as on iOS. */
        const val LIFTED_HEIGHT_RATIO = 1.17f
        const val LIFTED_ASPECT = 1.45f
        const val LIFTED_TAB_SHARE = 1.45f
        /** What lies in the lens's flat middle shows this much larger. */
        const val ZOOM = 1.13f
        /** How close a stopped finger must be to a tab, as a share of the tab, for the lens to rest on it. */
        const val SNAP_REACH = 0.15f
        /** How far from its tab counts as there, the longest a flight may take, and the least a tap shows it lifted. */
        const val ARRIVED_DP = 8f
        const val MAX_FLIGHT_MS = 320L
        const val MIN_UP_MS = 120L
        const val MAX_STRETCH = 0.15f
        /** How far past the bar's end the lens must hang for that end to show the bar's edge in full. */
        private const val END_REACH_DP = 2f
        /** The lens fades over the last of its landing, as the indicator fades in under it. */
        const val FADE_SHARE = 0.5f
        private const val FULL_STRETCH_SPEED_DP = 800f
        private const val MIN_REBOUND = 0.04f
        private const val BRAKING = 0.35f
        private const val REBOUND = 0.7f
        private const val REBOUND_MS = 130L
        private const val SHADOW = 0.045f
        /** A clear ball, not a clear disc: it darkens towards its rim. */
        private const val INNER_SHADOW = 0.05f
        /**
         * How far past the flat middle the rim looks: the bar's own outline comes inside the lens as a ring, about 88 % of
         * its height, as on iOS.
         */
        private const val RIM_REACH = -0.32f
        private const val RING = 0.25f
        /** How far in the round ends look at the rim, on top of the magnification: with it, about 20 dp. */
        private const val SIDE_REACH = 0.5f
        private const val FLARE = 0f
        private const val DISPERSION = 0.09f
        private const val LANDED = 0.02f
        private const val PAD_DP = 32f
        /** Reaches a jump in about 240 ms and only just overshoots, as the iOS lens does. */
        private val FOLLOW = DesignMotion.SpringToken(400f, 0.86f)
        /** Halfway down in about 80 ms, as the iOS lens is. */
        private val RISE = DesignMotion.SpringToken(520f, 0.9f)
        private val JELLY = DesignMotion.SpringToken(500f, 0.7f)

        private val CENTER = object : FloatPropertyCompat<TabBarLens>("lensCenter") {
            override fun getValue(lens: TabBarLens) = lens.center
            override fun setValue(lens: TabBarLens, value: Float) = lens.setCenter(value)
        }
        private val LIFT = object : FloatPropertyCompat<TabBarLens>("lensLift") {
            override fun getValue(lens: TabBarLens) = lens.lift
            override fun setValue(lens: TabBarLens, value: Float) = lens.setLift(value)
        }
        private val STRETCH = object : FloatPropertyCompat<TabBarLens>("lensStretch") {
            override fun getValue(lens: TabBarLens) = lens.stretch
            override fun setValue(lens: TabBarLens, value: Float) = lens.setStretch(value)
        }
    }
}
