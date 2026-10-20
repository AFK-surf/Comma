package surf.comma.android.ui

/**
 * Where the empty home page's two groups go in a viewport of a given height.
 *
 * The headline and the suggestion row are placed independently -- the row belongs to the
 * composer, the headline to the page -- which means nothing stops them from meeting when
 * the viewport is short (a small screen, a large font scale, or an IME that has taken half
 * the window). So the arithmetic lives here, apart from the views, where the short-viewport
 * cases can be stated as tests instead of discovered on a device.
 *
 * When the page cannot hold everything, it gives up decoration before content: the dot
 * field goes first, then the headline as a whole. The suggestion row is never dropped --
 * it is the only part you can act on, and it is anchored to the composer regardless.
 */
internal object EmptyStateLayout {

    data class Placement(
        /** False when even the text will not fit; the row is still placed. */
        val showHeadline: Boolean,
        /** False when the headline only fits without its dot field. */
        val showGlyph: Boolean,
        val headlineTranslationY: Float,
        val rowTranslationY: Float,
    )

    /**
     * The height the headline would have if its dot field were showing, which is what
     * [place] wants. Hiding the field is [place]'s own decision, so feeding back the
     * measured height as-is would let one frame's answer decide the next one's and the two
     * would alternate.
     *
     * This assumes hiding the field removes exactly [glyphBlockHeight] from the group,
     * which is only true while the gap below the field is the field's own margin -- a
     * LinearLayout drops a GONE child's margins with it, but not a sibling's. The layout
     * says so where it sets it.
     */
    fun naturalHeadlineHeight(measuredHeight: Int, glyphVisible: Boolean, glyphBlockHeight: Int): Int =
        measuredHeight + if (glyphVisible) 0 else glyphBlockHeight

    /**
     * @param hostHeight the timeline host, which does not change with the IME.
     * @param dockHeight the floating composer, which does.
     * @param rowHeight the suggestion row at its measured height.
     * @param headlineHeight from [naturalHeadlineHeight].
     * @param glyphBlockHeight the dot field plus the gap below it.
     * @param gap the breathing room the row keeps from the composer, and the headline from
     *   the row.
     * @param anchor fraction of [hostHeight] the headline's centre aims for.
     */
    fun place(
        hostHeight: Int,
        dockHeight: Int,
        rowHeight: Int,
        headlineHeight: Int,
        glyphBlockHeight: Int,
        gap: Int,
        anchor: Float,
    ): Placement {
        // Keeping the row is only worth something if the row is readable, and the host
        // clips. So when the composer leaves it less than its own height, it stops tracking
        // the composer and sits on it: covering the top of the input beats being cut in half.
        val lift = (dockHeight + gap).coerceAtMost((hostHeight - rowHeight).coerceAtLeast(0))
        val rowTranslationY = -lift.toFloat()
        // What is left above the row, already minus the gap the headline owes it.
        val room = hostHeight - rowHeight - lift - gap
        if (room <= 0) {
            return Placement(showHeadline = false, showGlyph = false, 0f, rowTranslationY)
        }
        val showGlyph = headlineHeight <= room
        val height = if (showGlyph) headlineHeight else headlineHeight - glyphBlockHeight
        if (height <= 0 || height > room) {
            return Placement(showHeadline = false, showGlyph = false, 0f, rowTranslationY)
        }
        val wanted = hostHeight * anchor - height / 2f
        return Placement(
            showHeadline = true,
            showGlyph = showGlyph,
            headlineTranslationY = wanted.coerceIn(0f, (room - height).toFloat()),
            rowTranslationY = rowTranslationY,
        )
    }
}
