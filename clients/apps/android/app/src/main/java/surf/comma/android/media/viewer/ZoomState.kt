package surf.comma.android.media.viewer

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Where a picture sits in the viewer. [scale] is relative to "fit inside the view" (1 = fitted);
 * [offsetX]/[offsetY] move the picture's centre away from the view's centre, in view pixels.
 * Independent of the bitmap's resolution, so a sharper decode can replace the current one in place.
 */
data class ZoomState(val scale: Float = 1f, val offsetX: Float = 0f, val offsetY: Float = 0f) {
    val zoomed: Boolean get() = scale > 1.01f

    fun lerp(to: ZoomState, fraction: Float) = ZoomState(
        scale + (to.scale - scale) * fraction,
        offsetX + (to.offsetX - offsetX) * fraction,
        offsetY + (to.offsetY - offsetY) * fraction,
    )
}

/** Geometry for one page: a [contentWidth]×[contentHeight] picture in a [viewWidth]×[viewHeight] view. */
class ZoomGeometry(
    val viewWidth: Float,
    val viewHeight: Float,
    val contentWidth: Float,
    val contentHeight: Float,
) {
    init { require(viewWidth > 0 && viewHeight > 0 && contentWidth > 0 && contentHeight > 0) }

    /** Pixels per content unit at scale 1. */
    val fitScale: Float = min(viewWidth / contentWidth, viewHeight / contentHeight)

    /** The zoom at which the picture fills the view in both directions. */
    val fillScale: Float = max(viewWidth / contentWidth, viewHeight / contentHeight) / fitScale

    /** A long screenshot can be zoomed until it is twice as wide as the view. */
    val maxScale: Float = max(MAX_ZOOM, fillScale * 2f)

    fun displayedWidth(state: ZoomState) = contentWidth * fitScale * state.scale
    fun displayedHeight(state: ZoomState) = contentHeight * fitScale * state.scale

    /** Keep the picture covering the view where it is larger than it, centred where it is not. */
    fun clamp(state: ZoomState): ZoomState {
        val scale = state.scale.coerceIn(1f, maxScale)
        val sized = state.copy(scale = scale)
        return sized.copy(offsetX = clampAxis(sized.offsetX, displayedWidth(sized), viewWidth),
            offsetY = clampAxis(sized.offsetY, displayedHeight(sized), viewHeight))
    }

    /** Zoom by [factor] about a point in view coordinates. Pinching may briefly pass the limits. */
    fun zoomBy(state: ZoomState, factor: Float, focusX: Float, focusY: Float, slack: Boolean = true): ZoomState {
        val low = if (slack) MIN_GESTURE_SCALE else 1f
        val high = if (slack) maxScale * 1.25f else maxScale
        return zoomTo(state, (state.scale * factor).coerceIn(low, high), focusX, focusY)
    }

    /** The content point under ([focusX], [focusY]) stays under it. */
    fun zoomTo(state: ZoomState, scale: Float, focusX: Float, focusY: Float): ZoomState {
        val ratio = scale / state.scale
        val fx = focusX - viewWidth / 2f
        val fy = focusY - viewHeight / 2f
        return ZoomState(scale, fx - (fx - state.offsetX) * ratio, fy - (fy - state.offsetY) * ratio)
    }

    /**
     * Moves by as much of ([dx], [dy]) as the picture can travel. Returns the new state and the
     * horizontal part it could not use, which the pager turns into a page swipe.
     */
    fun panBy(state: ZoomState, dx: Float, dy: Float): Pair<ZoomState, Float> {
        val moved = clamp(state.copy(offsetX = state.offsetX + dx, offsetY = state.offsetY + dy))
        return moved to (dx - (moved.offsetX - state.offsetX))
    }

    /** Whether a horizontal drag of [dx] would move the picture rather than the page. */
    fun canPan(state: ZoomState, dx: Float): Boolean = abs(panBy(state, dx, 0f).second) < abs(dx) - 0.5f

    /** Double tap: back to fitted when zoomed in, otherwise into the tapped point. */
    fun doubleTapTarget(state: ZoomState, focusX: Float, focusY: Float): ZoomState =
        if (state.scale > 1.05f) ZoomState()
        else clamp(zoomTo(state, max(DOUBLE_TAP_ZOOM, fillScale).coerceAtMost(maxScale), focusX, focusY))

    private fun clampAxis(offset: Float, displayed: Float, view: Float): Float {
        if (displayed <= view) return 0f
        val limit = (displayed - view) / 2f
        return offset.coerceIn(-limit, limit)
    }

    companion object {
        const val MAX_ZOOM = 4f
        const val DOUBLE_TAP_ZOOM = 2.5f
        const val MIN_GESTURE_SCALE = 0.7f
    }
}

/**
 * Which decode a page needs. The first decode fits the screen; zooming asks for the 2× and then
 * 4× box, never above the source's own size or [maxPixels], so the original is never decoded
 * whole just because it exists.
 */
object ZoomResolution {
    data class Box(val width: Int, val height: Int)

    fun level(scale: Float): Int = when {
        scale <= 1.25f -> 1
        scale <= 2.5f -> 2
        else -> 4
    }

    fun box(viewWidth: Int, viewHeight: Int, level: Int, maxPixels: Long): Box {
        require(viewWidth > 0 && viewHeight > 0 && level >= 1 && maxPixels > 0)
        var width = viewWidth.toLong() * level
        var height = viewHeight.toLong() * level
        if (width * height > maxPixels) {
            val shrink = kotlin.math.sqrt(maxPixels.toDouble() / (width * height))
            width = (width * shrink).toLong().coerceAtLeast(1)
            height = (height * shrink).toLong().coerceAtLeast(1)
        }
        return Box(width.toInt(), height.toInt())
    }

    /**
     * A fitted decode that came back smaller than its box on both sides was limited by the source
     * itself: it already holds every pixel, and zooming further needs no sharper decode.
     */
    fun reachedSource(decodedWidth: Int, decodedHeight: Int, requested: Box): Boolean =
        decodedWidth < requested.width && decodedHeight < requested.height
}
