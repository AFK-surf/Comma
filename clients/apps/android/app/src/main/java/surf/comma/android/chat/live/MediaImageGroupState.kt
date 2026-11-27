package surf.comma.android.chat.live

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Pure state machine and geometry engine for the chat image group fan-stack card deck.
 * Mirrors Web `ChatPanelImageGroup` 1:1 so layout precomputation, runtime rendering,
 * and unit tests share one deterministic source of truth.
 */
object MediaImageGroupGeometry {
    /** Groups with more images than this collapse into the stacked fan deck. */
    const val STACK_THRESHOLD = 3

    /** Fan depths visible on each side of the front card. */
    const val VISIBLE_SIDE_DEPTH = 2

    /** Collapsed 3:4 card dimensions in dp (165 x 220dp). */
    const val CARD_WIDTH_DP = 165f
    const val CARD_ASPECT_RATIO = 3f / 4f
    const val CARD_HEIGHT_DP = CARD_WIDTH_DP / CARD_ASPECT_RATIO // 220f

    const val CARD_RADIUS_DP = 12f
    const val CARD_GAP_DP = 8f
    const val BORDER_WIDTH_DP = 0.5f

    /** Single-image bounding box caps in dp. */
    const val SINGLE_MAX_WIDTH_DP = 320f
    const val SINGLE_MAX_HEIGHT_DP = 320f
    const val DEFAULT_SINGLE_ASPECT_RATIO = 4f / 3f

    /** Fan-stack per-depth transform steps. */
    const val STACK_ROTATION_STEP_DEG = 3.5f
    const val STACK_SHIFT_STEP_DP = 3f
    const val STACK_SCALE_STEP = 0.03f

    /** Room reserved around the collapsed stack so rotated corners never clip or overlap. */
    const val FAN_ALLOWANCE_HORIZONTAL_DP = 26f
    const val FAN_ALLOWANCE_VERTICAL_DP = 8f

    /** Toggle pill ("N Images" / "Hide") and advance chevron dimensions. */
    const val TOGGLE_PILL_HEIGHT_DP = 26f
    const val TOGGLE_PILL_GAP_DP = 4f
    const val ADVANCE_BUTTON_SIZE_DP = 32f

    /** Breakpoint above which expanded cards keep the desktop 165dp width. */
    const val WIDE_SCREEN_BREAKPOINT_DP = 520f

    /** Throw-arc flight timing and apex geometry (matches Web 60fps reference capture). */
    const val FLIGHT_DURATION_MS = 320L
    const val FLIGHT_APEX_OFFSET = 0.4f
    const val FLIGHT_APEX_WIDTH_FACTOR = 0.7f
    const val FLIGHT_APEX_ROTATION_DEG = 9f
    const val FLIGHT_APEX_SCALE = 0.96f
    const val FLIGHT_LAYER_SWAP_AT = 0.6f

    /** Expand/collapse FLIP timing and depth-ordered cascade stagger. */
    const val FLIP_DURATION_MS = 240L
    const val EXPAND_STAGGER_MS = 12L
    const val COLLAPSE_STAGGER_MS = 8L

    /** Non-flying slot settle transition duration during deck rotation. */
    const val SLOT_SETTLE_DURATION_MS = 200L

    fun isStackable(count: Int): Boolean = count > STACK_THRESHOLD

    fun singleMaxWidthDp(columnWidthDp: Float): Float =
        min(SINGLE_MAX_WIDTH_DP, floor(columnWidthDp.coerceAtLeast(1f) * 0.75f)).coerceAtLeast(1f)

    /**
     * Exact single-image size in dp preserving original aspect ratio inside
     * [singleMaxWidthDp] x [SINGLE_MAX_HEIGHT_DP]. Falls back to 4:3 when
     * dimensions are unknown.
     */
    fun singleImageSizeDp(
        columnWidthDp: Float,
        sourceWidthPx: Int?,
        sourceHeightPx: Int?,
    ): SizeDp {
        val maxWidth = singleMaxWidthDp(columnWidthDp)
        val ratio = if (sourceWidthPx != null && sourceHeightPx != null && sourceWidthPx > 0 && sourceHeightPx > 0) {
            sourceWidthPx.toFloat() / sourceHeightPx.toFloat()
        } else {
            DEFAULT_SINGLE_ASPECT_RATIO
        }
        val width = min(maxWidth, SINGLE_MAX_HEIGHT_DP * ratio).coerceAtLeast(1f)
        val height = (width / ratio).coerceAtLeast(1f)
        return SizeDp(width, height)
    }

    /**
     * Card width in dp when laid out in expanded rows (2-3 images, or 4+ expanded).
     * Wide screens (>= 520dp) keep 165dp; phones size 2 cards to 2 columns and 3+ cards to 3 columns.
     */
    fun expandedCardWidthDp(columnWidthDp: Float, count: Int): Float {
        val safeColumn = columnWidthDp.coerceAtLeast(1f)
        if (safeColumn >= WIDE_SCREEN_BREAKPOINT_DP) return CARD_WIDTH_DP
        return when {
            count <= 1 -> singleMaxWidthDp(safeColumn)
            count == 2 -> min(CARD_WIDTH_DP, floor((safeColumn - CARD_GAP_DP) / 2f)).coerceAtLeast(1f)
            else -> min(CARD_WIDTH_DP, floor((safeColumn - CARD_GAP_DP * 2f) / 3f)).coerceAtLeast(1f)
        }
    }

    fun expandedCardHeightDp(cardWidthDp: Float): Float = cardWidthDp / CARD_ASPECT_RATIO

    fun expandedColumnCount(columnWidthDp: Float, count: Int): Int {
        if (count <= 0) return 0
        val cardWidth = expandedCardWidthDp(columnWidthDp, count)
        val cols = floor((columnWidthDp.coerceAtLeast(cardWidth) + CARD_GAP_DP) / (cardWidth + CARD_GAP_DP))
            .toInt()
            .coerceAtLeast(1)
        return min(cols, count)
    }

    fun collapsedDeckSizeDp(): SizeDp = SizeDp(
        widthDp = CARD_WIDTH_DP + FAN_ALLOWANCE_HORIZONTAL_DP * 2f,
        heightDp = CARD_HEIGHT_DP + FAN_ALLOWANCE_VERTICAL_DP * 2f,
    )

    fun expandedGridSizeDp(columnWidthDp: Float, count: Int): SizeDp {
        if (count <= 0) return SizeDp(0f, 0f)
        val cardWidth = expandedCardWidthDp(columnWidthDp, count)
        val cardHeight = expandedCardHeightDp(cardWidth)
        val cols = expandedColumnCount(columnWidthDp, count)
        val rows = ceil(count.toFloat() / cols.toFloat()).toInt().coerceAtLeast(1)
        val gridWidth = cols * cardWidth + (cols - 1) * CARD_GAP_DP
        val gridHeight = rows * cardHeight + (rows - 1) * CARD_GAP_DP
        return SizeDp(gridWidth, gridHeight)
    }

    /**
     * Total body height of the image group view in dp (toggle pill + cards area),
     * matching [MediaImageGroupView.onMeasure] identically.
     */
    fun totalHeightDp(
        columnWidthDp: Float,
        count: Int,
        expanded: Boolean,
        singleWidthPx: Int? = null,
        singleHeightPx: Int? = null,
    ): Float {
        if (count <= 0) return 0f
        if (count == 1) return singleImageSizeDp(columnWidthDp, singleWidthPx, singleHeightPx).heightDp
        val stackable = isStackable(count)
        val header = if (stackable) TOGGLE_PILL_HEIGHT_DP + TOGGLE_PILL_GAP_DP else 0f
        val cardsHeight = if (stackable && !expanded) {
            collapsedDeckSizeDp().heightDp
        } else {
            expandedGridSizeDp(columnWidthDp, count).heightDp
        }
        return header + cardsHeight
    }

    /**
     * Exact throw-arc pose of the outgoing front card at normalized progress [t] in [0, 1].
     * Uses Web's two-segment easing: [drawer] from 0..0.4 to the apex, [softInOut] from 0.4..1.0 to the settled slot.
     */
    fun flightPose(
        t: Float,
        step: Int,
        cardWidthPx: Float,
        fromX: Float,
        fromRotation: Float,
        fromScale: Float,
        fromAlpha: Float,
        toSlot: ImageGroupStackSlot,
        density: Float,
        drawer: (Float) -> Float,
        softInOut: (Float) -> Float,
    ): CardFlightPose {
        val progress = t.coerceIn(0f, 1f)
        val side = if (step == 1) -1f else 1f
        val apexX = (cardWidthPx * FLIGHT_APEX_WIDTH_FACTOR * side).roundToInt().toFloat()
        val apexRotation = FLIGHT_APEX_ROTATION_DEG * side
        val apexScale = FLIGHT_APEX_SCALE
        val toX = toSlot.translationXDp * density
        val toRotation = toSlot.rotationDeg
        val toScale = toSlot.scale
        val toAlpha = toSlot.alpha

        val tx: Float
        val rot: Float
        val scale: Float
        val alpha: Float
        if (progress <= FLIGHT_APEX_OFFSET) {
            val u = drawer((progress / FLIGHT_APEX_OFFSET).coerceIn(0f, 1f))
            tx = lerp(fromX, apexX, u)
            rot = lerp(fromRotation, apexRotation, u)
            scale = lerp(fromScale, apexScale, u)
            alpha = lerp(fromAlpha, 1f, u)
        } else {
            val u = softInOut(((progress - FLIGHT_APEX_OFFSET) / (1f - FLIGHT_APEX_OFFSET)).coerceIn(0f, 1f))
            tx = lerp(apexX, toX, u)
            rot = lerp(apexRotation, toRotation, u)
            scale = lerp(apexScale, toScale, u)
            alpha = lerp(1f, toAlpha, u)
        }
        val zIndex = if (progress < FLIGHT_LAYER_SWAP_AT) 6 else toSlot.zIndex
        val dimAlpha = lerp(0f, toSlot.dimAlpha, progress)
        return CardFlightPose(tx, rot, scale, alpha, dimAlpha, zIndex)
    }

    /** Stagger delay in milliseconds for a card with [depth] during expand/collapse FLIP. */
    fun flipStaggerDelayMs(depth: Int, expanding: Boolean): Long {
        val maxOrder = ImageGroupStackSlot.FRONT.depth
        val order = (maxOrder - depth).coerceIn(0, maxOrder)
        return if (expanding) order * EXPAND_STAGGER_MS else (maxOrder - order) * COLLAPSE_STAGGER_MS
    }

    private fun lerp(start: Float, end: Float, t: Float): Float = start + (end - start) * t
}

data class SizeDp(val widthDp: Float, val heightDp: Float)

data class CardFlightPose(
    val translationXPx: Float,
    val rotationDeg: Float,
    val scale: Float,
    val alpha: Float,
    val dimAlpha: Float,
    val zIndex: Int,
)

/**
 * Stack slot of a card in the cyclic two-pile fan deck.
 * Exact 1:1 mirror of Web `ChatPanelImageGroupStackSlot` and its CSS custom property rules.
 */
enum class ImageGroupStackSlot(
    val slotName: String,
    val zIndex: Int,
    val shiftSteps: Int,
    val rotationSteps: Int,
    val scaleSteps: Int,
    val dimAlpha: Float,
    val alpha: Float,
) {
    FRONT("0", zIndex = 5, shiftSteps = 0, rotationSteps = 0, scaleSteps = 0, dimAlpha = 0f, alpha = 1f),
    R1("r1", zIndex = 4, shiftSteps = 1, rotationSteps = 1, scaleSteps = 1, dimAlpha = 0.08f, alpha = 1f),
    R2("r2", zIndex = 3, shiftSteps = 2, rotationSteps = 2, scaleSteps = 2, dimAlpha = 0.16f, alpha = 1f),
    L1("l1", zIndex = 4, shiftSteps = -1, rotationSteps = -1, scaleSteps = 1, dimAlpha = 0.08f, alpha = 1f),
    L2("l2", zIndex = 3, shiftSteps = -2, rotationSteps = -2, scaleSteps = 2, dimAlpha = 0.16f, alpha = 1f),
    HIDDEN_RIGHT("hidden-right", zIndex = 0, shiftSteps = 2, rotationSteps = 2, scaleSteps = 2, dimAlpha = 0.16f, alpha = 0f),
    HIDDEN_LEFT("hidden-left", zIndex = 0, shiftSteps = -2, rotationSteps = -2, scaleSteps = 2, dimAlpha = 0.16f, alpha = 0f);

    val depth: Int
        get() = when (this) {
            FRONT -> 3
            R1, L1 -> 2
            R2, L2 -> 1
            HIDDEN_RIGHT, HIDDEN_LEFT -> 0
        }

    val translationXDp: Float get() = shiftSteps * MediaImageGroupGeometry.STACK_SHIFT_STEP_DP
    val rotationDeg: Float get() = rotationSteps * MediaImageGroupGeometry.STACK_ROTATION_STEP_DEG
    val scale: Float get() = 1f - scaleSteps * MediaImageGroupGeometry.STACK_SCALE_STEP
    val paintsImage: Boolean get() = this != HIDDEN_RIGHT && this != HIDDEN_LEFT
}

fun normalizedImageIndex(index: Int, count: Int): Int =
    if (count > 0) ((index % count) + count) % count else 0

/**
 * Exact 1:1 port of Web `stackSlotForDistance`:
 * `leftCount` cards already flipped past sit fanned on the LEFT of the front card;
 * the remaining cards wait fanned on the RIGHT. Each side shows up to [MediaImageGroupGeometry.VISIBLE_SIDE_DEPTH]
 * depths; deeper cards park hidden at that side's deepest angle.
 */
fun stackSlotForDistance(
    index: Int,
    frontIndex: Int,
    count: Int,
    leftCount: Int = 0,
): ImageGroupStackSlot {
    if (count <= 0) return ImageGroupStackSlot.HIDDEN_RIGHT
    val distance = (((index - frontIndex) % count) + count) % count
    if (distance == 0) return ImageGroupStackSlot.FRONT
    val rightSpan = count - 1 - leftCount.coerceIn(0, count - 1)
    if (distance <= rightSpan) {
        return when (distance) {
            1 -> ImageGroupStackSlot.R1
            2 -> ImageGroupStackSlot.R2
            else -> ImageGroupStackSlot.HIDDEN_RIGHT
        }
    }
    val leftDepth = count - distance
    return when (leftDepth) {
        1 -> ImageGroupStackSlot.L1
        2 -> ImageGroupStackSlot.L2
        else -> ImageGroupStackSlot.HIDDEN_LEFT
    }
}

/**
 * Exact 1:1 port of Web `imageGroupBrowseReducer`.
 */
data class MediaImageGroupBrowseState(
    val frontIndex: Int = 0,
    val leftCount: Int = 0,
) {
    fun normalizedFront(count: Int): Int = normalizedImageIndex(frontIndex, count)

    fun clampedLeftCount(count: Int): Int =
        if (count > 0) leftCount.coerceIn(0, count - 1) else 0

    fun rotate(count: Int, step: Int): MediaImageGroupBrowseState {
        require(step == 1 || step == -1) { "step must be 1 or -1, got $step" }
        if (count <= 0) return MediaImageGroupBrowseState(0, 0)
        val clamped = clampedLeftCount(count)
        return MediaImageGroupBrowseState(
            frontIndex = normalizedImageIndex(frontIndex + step, count),
            leftCount = if (step == 1) (clamped + 1).coerceAtMost(count - 1) else (clamped - 1).coerceAtLeast(0),
        )
    }

    fun alignPreview(count: Int, index: Int): MediaImageGroupBrowseState {
        if (count <= 0) return MediaImageGroupBrowseState(0, 0)
        val clamped = index.coerceIn(0, count - 1)
        if (normalizedImageIndex(frontIndex, count) == clamped) {
            return MediaImageGroupBrowseState(
                frontIndex = clamped,
                leftCount = clampedLeftCount(count),
            )
        }
        return MediaImageGroupBrowseState(frontIndex = clamped, leftCount = clamped)
    }

    fun navigatePreview(count: Int, step: Int): MediaImageGroupBrowseState {
        require(step == 1 || step == -1) { "step must be 1 or -1, got $step" }
        if (count <= 0) return MediaImageGroupBrowseState(0, 0)
        val current = normalizedImageIndex(frontIndex, count)
        val next = (current + step).coerceIn(0, count - 1)
        return MediaImageGroupBrowseState(frontIndex = next, leftCount = next)
    }

    fun slotFor(index: Int, count: Int): ImageGroupStackSlot =
        stackSlotForDistance(index, normalizedFront(count), count, clampedLeftCount(count))
}
