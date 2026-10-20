package surf.comma.android.chat.live

import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.ui.theme.DesignMotion

/** A rectangle in window pixels. Kept free of android.graphics so the geometry is plain math. */
internal data class FlightBox(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
}

/** One thing that flies: the message text, or one attachment thumbnail, and the row it lands in. */
internal data class FlightPiece(
    /** -1 for the text; otherwise the index of the composer attachment. */
    val source: Int,
    val targetRowId: Long,
) {
    val isText: Boolean get() = source < 0
}

internal object SendFlightGeometry {
    /** The source bubble is the typed text grown by the target bubble's padding. */
    fun textSource(originX: Float, originY: Float, textWidth: Float, textHeight: Float, padH: Float, padV: Float) =
        FlightBox(originX - padH, originY - padV, originX + textWidth + padH, originY + textHeight + padV)

    /**
     * Where a piece is drawn: its target as it is this frame, plus the offset its springs are
     * taking to zero (left, top, right, bottom). Not clamped: an overshoot carries through.
     */
    fun drawn(target: FlightBox, offset: FloatArray) = FlightBox(target.left + offset[0], target.top + offset[1],
        target.right + offset[2], target.bottom + offset[3])

    /**
     * A piece that lands below another may leave once that one, drawn at [aboveBottom], has
     * passed its source: from then on the space they keep at rest, [gap], fits between them.
     */
    fun mayLeave(aboveBottom: Float, gap: Float, sourceTop: Float): Boolean = aboveBottom + gap <= sourceTop

    /** [box] with nothing above [maskTop]; empty (zero height at its bottom) once fully covered. */
    fun masked(box: FlightBox, maskTop: Float): FlightBox =
        if (box.top >= maskTop) box else box.copy(top = minOf(maskTop, box.bottom))

    /**
     * Pairs what was sent with the rows of the new turn: the text with the text bubble, each
     * attachment with the attachment rows in order. A row without a partner is left alone; a
     * source without one does not fly.
     */
    fun pair(hasText: Boolean, attachmentCount: Int, turnRows: List<PreparedChatMessage>): List<FlightPiece> {
        val rows = turnRows.filter { it.message.role == ChatRole.USER }
        val pieces = ArrayList<FlightPiece>()
        if (hasText) rows.firstOrNull { it.message.cardKind == null }?.let { pieces += FlightPiece(-1, it.message.id) }
        rows.filter { it.message.cardKind == LiveRowKinds.ATTACHMENT }.take(attachmentCount).forEachIndexed { index, row ->
            pieces += FlightPiece(index, row.message.id)
        }
        return pieces
    }

    /** The user rows of the turn [turnKey] opened, wherever it is in the list; a reply is not one. */
    fun turnRows(turnKey: String, rows: List<PreparedChatMessage>): List<PreparedChatMessage> =
        rows.filter { it.message.role == ChatRole.USER && it.message.turnId == turnKey }

    /**
     * How long a spring from 0 to 1 takes to settle within [threshold] (with its velocity under
     * [threshold] per 10 ms), by stepping the same equation of motion the animation solves.
     */
    fun settleMillis(token: DesignMotion.SpringToken, threshold: Float = 0.002f): Long {
        val omega = kotlin.math.sqrt(token.stiffness)
        var x = 0.0
        var v = 0.0
        var ms = 0L
        while (ms < 10_000L) {
            val a = token.stiffness * (1.0 - x) - 2.0 * token.dampingRatio * omega * v
            v += a * 0.001
            x += v * 0.001
            ms++
            if (kotlin.math.abs(1.0 - x) < threshold && kotlin.math.abs(v) * 0.01 < threshold) break
        }
        return ms
    }

    /** 1.5x what a flight normally takes from the moment its rows are hidden; rearmed while it still moves. */
    fun failsafeMillis(token: DesignMotion.SpringToken, targetWaitFrames: Int, frameMillis: Long = 17L): Long =
        ((settleMillis(token) + (targetWaitFrames + 2) * frameMillis) * 1.5).toLong()

}
