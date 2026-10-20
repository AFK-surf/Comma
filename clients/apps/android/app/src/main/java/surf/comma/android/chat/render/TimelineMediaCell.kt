package surf.comma.android.chat.render

/** Actual viewport plus page lifecycle, forwarded by the timeline to every media surface. */
internal interface TimelineMediaCell {
    fun setMediaVisible(visible: Boolean)
    fun releaseMedia()
}

/** A row a sent message can fly into: the rectangle its content lands in, in the row's coordinates. */
internal interface FlightTarget {
    fun flightBounds(out: android.graphics.RectF): Boolean
    val flightCornerRadius: Float
    /** How far the landed row draws below [flightBounds]: the bubble's tail. */
    val flightTailPx: Float get() = 0f
}
