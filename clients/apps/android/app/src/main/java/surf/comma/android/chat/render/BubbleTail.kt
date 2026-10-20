package surf.comma.android.chat.render

import android.graphics.Path
import android.graphics.RectF

/**
 * The curved tail under the last bubble of a run. The bubble keeps all four rounded corners;
 * the tail hangs under the bottom outer one. It leaves the corner's curve with a small inward
 * turn, narrows as it drops, flares out to a fine point and sweeps back along its lower edge
 * into the flat bottom of the bubble. The user's sits under the bottom-right corner, the
 * agent's mirrors it under the bottom-left.
 *
 * The tail never reaches past the bubble's sides and hangs at most [DEPTH_DP] below it; the row
 * reserves that space, so the tail is never clipped and never covers the next row. The bubble
 * and its tail are one path, so there is no seam where they meet, even when the bubble is drawn
 * translucent.
 */
internal object BubbleTail {
    /** How far under the bubble the row reserves for the tail. */
    const val DEPTH_DP = 7f

    /** The bubble's corner radius the tail is shaped around. */
    const val RADIUS_DP = 20f

    /**
     * The outline in dp, from the bubble's bottom outer corner: x grows inward (away from the
     * tail's side), y grows downward. Start, then cubic segments of three points each.
     */
    private val OUTLINE = floatArrayOf(
        24f, -4f,
        // Down to the flat bottom edge, inside the bubble.
        24f, -2.5f, 24f, -1f, 24f, 0f,
        // The lower edge: leaves the bottom flat, then sweeps down and out towards the point.
        20f, 0.1f, 14f, 4.2f, 10f, 6.3f,
        // The fine point.
        9.2f, 6.5f, 8.9f, 6.2f, 9.1f, 5.7f,
        // The outer edge: in from the point to just inside the corner, where it narrows...
        9.6f, 4.4f, 11.2f, 3f, 11.2f, 1.4f,
        // ...then straight up into the bubble, meeting the corner's curve with an inward turn.
        11.2f, 0f, 11.2f, -2f, 11.2f, -4f,
    )

    /**
     * Writes into [out] the bubble [body] with rounded corners of [radiusPx] and, on the [right]
     * or left, its tail. [scratch] is reused for the tail on its own.
     */
    fun outline(out: Path, scratch: Path, body: RectF, radiusPx: Float, right: Boolean, density: Float) {
        out.reset()
        out.addRoundRect(body, radiusPx, radiusPx, Path.Direction.CW)
        scratch.reset()
        val cornerX = if (right) body.right else body.left
        val inward = if (right) -density else density
        fun x(at: Int) = cornerX + OUTLINE[at] * inward
        fun y(at: Int) = body.bottom + OUTLINE[at + 1] * density
        scratch.moveTo(x(0), y(0))
        var at = 2
        while (at < OUTLINE.size) {
            scratch.cubicTo(x(at), y(at), x(at + 2), y(at + 2), x(at + 4), y(at + 4))
            at += 6
        }
        scratch.close()
        out.op(scratch, Path.Op.UNION)
    }

    /** The lowest point of the tail under the bubble, in dp. */
    val lowestDp: Float = OUTLINE.filterIndexed { index, _ -> index % 2 == 1 }.max()
}
