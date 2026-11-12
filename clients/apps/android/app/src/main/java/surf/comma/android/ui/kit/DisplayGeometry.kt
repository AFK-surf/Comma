package surf.comma.android.ui.kit

import android.graphics.Outline
import android.graphics.Path
import android.graphics.RectF
import android.view.RoundedCorner
import android.view.View
import android.view.WindowInsets

/**
 * The display's own corner radii, each corner on its own: a foldable's outer screen can have small corners along one
 * edge only. A corner the system does not describe has no limit ([Float.POSITIVE_INFINITY]). Panels that reach a
 * display corner use the smaller of their own radius and that corner's ([cap]), so they follow the glass.
 */
data class DisplayCorners(
    val topLeft: Float = Float.POSITIVE_INFINITY,
    val topRight: Float = Float.POSITIVE_INFINITY,
    val bottomLeft: Float = Float.POSITIVE_INFINITY,
    val bottomRight: Float = Float.POSITIVE_INFINITY,
) {
    companion object {
        val UNKNOWN = DisplayCorners()

        fun of(insets: WindowInsets?): DisplayCorners {
            insets ?: return UNKNOWN
            fun radius(position: Int) = insets.getRoundedCorner(position)?.radius?.toFloat() ?: Float.POSITIVE_INFINITY
            return DisplayCorners(radius(RoundedCorner.POSITION_TOP_LEFT), radius(RoundedCorner.POSITION_TOP_RIGHT),
                radius(RoundedCorner.POSITION_BOTTOM_LEFT), radius(RoundedCorner.POSITION_BOTTOM_RIGHT))
        }

        /** [radius] near a display corner of [corner]: never rounder than the display there. */
        fun cap(radius: Float, corner: Float): Float = minOf(radius, corner).coerceAtLeast(0f)
    }
}

/** Corner radii in the order top-left, top-right, bottom-right, bottom-left, as [Path.addRoundRect] reads them. */
data class CornerRadii(val topLeft: Float, val topRight: Float, val bottomRight: Float, val bottomLeft: Float) {
    fun array() = floatArrayOf(topLeft, topLeft, topRight, topRight, bottomRight, bottomRight, bottomLeft, bottomLeft)

    /** An outline with these corners; a view clips to it (API 33+ clips any path). */
    fun outline(view: View, outline: Outline, bounds: RectF = RectF(0f, 0f, view.width.toFloat(), view.height.toFloat())) {
        if (topLeft == topRight && topRight == bottomRight && bottomRight == bottomLeft) {
            outline.setRoundRect(bounds.left.toInt(), bounds.top.toInt(), bounds.right.toInt(), bounds.bottom.toInt(), topLeft)
            return
        }
        outline.setPath(Path().apply { addRoundRect(bounds, array(), Path.Direction.CW) })
    }
}

/** A rectangle in window pixels, as a cutout's bounding rectangle or a row of controls. */
data class Band(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    fun intersects(other: Band) = left < other.right && other.left < right && top < other.bottom && other.top < bottom
}

/**
 * How far a row of controls ([band]) keeps in from its leading and trailing edges so that no cutout that crosses it
 * (a camera in a landscape edge, a hinge's sensor housing) covers a control: past the cutout's inner edge by
 * [spacing], less the row's own [margin], which already keeps it in that far. 0 when nothing crosses the row.
 */
fun cutoutClearance(band: Band, cutouts: List<Band>, margin: Int, spacing: Int): Pair<Int, Int> {
    var start = 0
    var end = 0
    val middle = (band.left + band.right) / 2
    for (cutout in cutouts) {
        if (!cutout.intersects(band)) continue
        if ((cutout.left + cutout.right) / 2 >= middle) end = maxOf(end, band.right - cutout.left - margin + spacing)
        else start = maxOf(start, cutout.right - band.left - margin + spacing)
    }
    return start.coerceAtLeast(0) to end.coerceAtLeast(0)
}
