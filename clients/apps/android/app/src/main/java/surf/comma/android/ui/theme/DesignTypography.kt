package surf.comma.android.ui.theme

import android.util.TypedValue
import android.widget.TextView

/** Sizes and line heights are sp; letter spacing is em. System font scaling still applies. */
object DesignTypography {
    data class Size(val sp: Float, val lineHeightSp: Float, val letterSpacingEm: Float = 0f)
    enum class Level { MICRO, MINI, SMALL, REGULAR, LARGE, TITLE3, TITLE2, TITLE1 }

    private val scale = listOf(
        Size(11f, 16f), Size(12f, 18f), Size(13f, 20f), Size(15f, 24f),
        Size(18f, 28f, -0.01f), Size(20f, 30f, -0.01f),
        Size(24f, 32f, -0.02f), Size(36f, 44f, -0.02f),
    )
    val micro get() = size(Level.MICRO)
    val mini get() = size(Level.MINI)
    val small get() = size(Level.SMALL)
    val regular get() = size(Level.REGULAR)
    val large get() = size(Level.LARGE)
    val title3 get() = size(Level.TITLE3)
    val title2 get() = size(Level.TITLE2)
    val title1 get() = size(Level.TITLE1)

    /** Configure before binding views. Reapply typography if this changes while a page is visible. */
    @Volatile var promoteOneStep: Boolean = false

    /** The largest level stays at title1 when promotion is enabled. */
    fun size(level: Level, promote: Boolean = promoteOneStep): Size =
        scale[(level.ordinal + if (promote) 1 else 0).coerceAtMost(scale.lastIndex)]

    /**
     * How much larger chat text is drawn when the scale is promoted: the same ratio as regular
     * text gains (15 → 18 sp). Chat content keeps its own sizes and multiplies them by this.
     */
    fun chatScale(promote: Boolean = promoteOneStep): Float =
        size(Level.REGULAR, promote).sp / size(Level.REGULAR, promote = false).sp

    fun applyTo(
        view: TextView,
        level: Level = Level.REGULAR,
        weight: Int = DesignFonts.regular,
        promote: Boolean = promoteOneStep,
    ) {
        val size = size(level, promote)
        view.typeface = DesignFonts.inter(view.context, weight)
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, size.sp)
        view.setLineHeight(TypedValue.COMPLEX_UNIT_SP, size.lineHeightSp)
        view.letterSpacing = size.letterSpacingEm
    }
}
