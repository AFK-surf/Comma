package surf.comma.android.media.viewer

import android.graphics.RectF
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Snapshot of an interactive dismiss gesture (drag-to-dismiss or predictive back) at release,
 * handed into the closing shared-element springs so momentum carries smoothly into the tile.
 */
data class DismissRelease(
    val offsetX: Float,
    val offsetY: Float,
    val scale: Float,
    val velocityX: Float,
    val velocityY: Float,
    val scaleVelocity: Float,
)

/**
 * Pure geometry for the image viewer's shared-element transition and interactive drag-to-dismiss.
 *
 * All coordinates live in the untransformed viewer host's local pixel space so reading the host's
 * screen origin can never feed a child's own scale or translation back into the next frame.
 *
 * Image scaling is strictly uniform (`scaleX == scaleY`): at the chat tile the image covers the
 * tile (`max(tileW / fitW, tileH / fitH)`), matching `ImageCrop.cover` pixel-for-pixel, while the
 * rounded aperture interpolates between the tile's cropped box (with `tileCornerRadius`) and the
 * full fitted picture (with radius 0).
 */
internal object ViewerTransitionGeometry {
    /** Fitted picture rectangle centred inside a [viewportWidth] x [viewportHeight] viewer. */
    fun fittedRect(
        viewportWidth: Float,
        viewportHeight: Float,
        contentWidth: Float,
        contentHeight: Float,
        out: RectF,
    ) {
        val ratio = if (contentWidth > 0f && contentHeight > 0f) contentWidth / contentHeight else 1f
        val fitWidth = min(viewportWidth, viewportHeight * ratio).coerceAtLeast(1f)
        val fitHeight = (fitWidth / ratio).coerceAtLeast(1f)
        out.set(
            (viewportWidth - fitWidth) / 2f,
            (viewportHeight - fitHeight) / 2f,
            (viewportWidth + fitWidth) / 2f,
            (viewportHeight + fitHeight) / 2f,
        )
    }

    /** Converts a tile rectangle from screen pixels into host-local pixels using the untransformed host's origin. */
    fun tileInHost(tileOnScreen: RectF, hostOriginX: Int, hostOriginY: Int, out: RectF) {
        out.set(
            tileOnScreen.left - hostOriginX,
            tileOnScreen.top - hostOriginY,
            tileOnScreen.right - hostOriginX,
            tileOnScreen.bottom - hostOriginY,
        )
    }

    /**
     * Endpoint parameters for a shared transition between [tile] (in host coordinates) and [fitted].
     *
     * - [tileScale]: uniform image scale relative to [fitted] that covers [tile] (`ImageCrop.cover`).
     * - [tileRatioW], [tileRatioH]: fraction of the covered image visible inside [tile]'s aperture (<= 1).
     */
    data class Endpoints(
        val tileCenterX: Float,
        val tileCenterY: Float,
        val tileScale: Float,
        val tileRatioW: Float,
        val tileRatioH: Float,
        val tileCornerRadius: Float,
        val fitCenterX: Float,
        val fitCenterY: Float,
        val fitWidth: Float,
        val fitHeight: Float,
    )

    fun endpoints(tile: RectF, fitted: RectF, tileCornerRadius: Float): Endpoints {
        val fitW = fitted.width().coerceAtLeast(1f)
        val fitH = fitted.height().coerceAtLeast(1f)
        val tileW = tile.width().coerceAtLeast(1f)
        val tileH = tile.height().coerceAtLeast(1f)
        val coverScale = max(tileW / fitW, tileH / fitH).coerceAtLeast(0.01f)
        val coveredW = fitW * coverScale
        val coveredH = fitH * coverScale
        return Endpoints(
            tileCenterX = tile.centerX(),
            tileCenterY = tile.centerY(),
            tileScale = coverScale,
            tileRatioW = (tileW / coveredW).coerceIn(0.01f, 1f),
            tileRatioH = (tileH / coveredH).coerceIn(0.01f, 1f),
            tileCornerRadius = tileCornerRadius.coerceAtLeast(0f),
            fitCenterX = fitted.centerX(),
            fitCenterY = fitted.centerY(),
            fitWidth = fitW,
            fitHeight = fitH,
        )
    }

    /**
     * Computes the visible rounded aperture rectangle and corner radius for a live 5-DOF state
     * (`centerX`, `centerY`, `scale`, `cropProgress` q, `cornerProgress` c).
     *
     * - At `(tileCenterX, tileCenterY, tileScale, q=0, c=0)`: aperture == tile, radius == tileCornerRadius.
     * - At `(fitCenterX, fitCenterY, 1, q=1, c=1)`: aperture == fitted, radius == 0.
     * - Aspect ratios stay <= 1.0 so an underdamped spring overshoot never exposes letterbox bars
     *   inside the rounded clip while position and scale still overshoot freely.
     */
    fun aperture(
        endpoints: Endpoints,
        centerX: Float,
        centerY: Float,
        scale: Float,
        cropProgress: Float,
        cornerProgress: Float,
        outRect: RectF,
    ): Float {
        val s = scale.coerceAtLeast(0.01f)
        val ratioW = (endpoints.tileRatioW + (1f - endpoints.tileRatioW) * cropProgress).coerceIn(0.01f, 1f)
        val ratioH = (endpoints.tileRatioH + (1f - endpoints.tileRatioH) * cropProgress).coerceIn(0.01f, 1f)
        val width = endpoints.fitWidth * s * ratioW
        val height = endpoints.fitHeight * s * ratioH
        outRect.set(
            centerX - width / 2f,
            centerY - height / 2f,
            centerX + width / 2f,
            centerY + height / 2f,
        )
        val maxRadius = min(width, height) / 2f
        return (endpoints.tileCornerRadius * (1f - cornerProgress)).coerceIn(0f, maxRadius)
    }

    /** Smooth drag-to-dismiss scale curve `1 / (1 + DRAG_SCALE_K * u)` clamped to [MIN_DRAG_SCALE]. */
    const val DRAG_SCALE_K = 0.85f
    const val MIN_DRAG_SCALE = 0.55f

    fun dragScale(offsetY: Float, viewportHeight: Float): Float {
        if (viewportHeight <= 0f) return 1f
        val u = abs(offsetY) / viewportHeight
        return (1f / (1f + DRAG_SCALE_K * u)).coerceAtLeast(MIN_DRAG_SCALE)
    }

    /** Exact analytical derivative d(scale)/dt (in 1/s) along [dragScale] for spring velocity handoff. */
    fun dragScaleVelocity(offsetY: Float, velocityY: Float, viewportHeight: Float): Float {
        if (viewportHeight <= 0f || offsetY == 0f) return 0f
        val u = abs(offsetY) / viewportHeight
        val raw = 1f / (1f + DRAG_SCALE_K * u)
        if (raw <= MIN_DRAG_SCALE) return 0f
        val duDt = (if (offsetY > 0f) velocityY else -velocityY) / viewportHeight
        val denom = 1f + DRAG_SCALE_K * u
        return -DRAG_SCALE_K / (denom * denom) * duDt
    }

    /**
     * Radially clamps a 2D fling velocity vector to [maxSpeed] while preserving its exact direction,
     * so brisk flicks carry natural curved momentum without launching the image off screen.
     */
    fun clampVelocity(vx: Float, vy: Float, maxSpeed: Float, out: FloatArray) {
        if (maxSpeed <= 0f) {
            out[0] = 0f
            out[1] = 0f
            return
        }
        val speed = hypot(vx, vy)
        if (speed <= maxSpeed || speed <= 0f) {
            out[0] = vx
            out[1] = vy
        } else {
            val factor = maxSpeed / speed
            out[0] = vx * factor
            out[1] = vy * factor
        }
    }

    /**
     * Clamps the closing scale spring's initial velocity for a critically damped spring of [stiffness]
     * so scale converges monotonically to [targetScale] without undershooting below the tile size
     * (which would squash the returning card shorter than its tile before bouncing back).
     */
    fun clampClosingScaleVelocity(
        currentScale: Float,
        targetScale: Float,
        rawScaleVelocity: Float,
        stiffness: Float,
    ): Float {
        if (stiffness <= 0f) return 0f
        val omega = sqrt(stiffness)
        val delta = currentScale - targetScale
        return if (delta >= 0f) {
            // Critically damped spring x(t) = (x0 + (v0 + w*x0)*t)*e^(-w*t) stays >= 0 iff v0 >= -w*x0.
            rawScaleVelocity.coerceIn(-omega * 0.75f * delta, omega * 0.5f * delta)
        } else {
            val grow = -delta
            rawScaleVelocity.coerceIn(0f, omega * 0.75f * grow)
        }
    }
}
