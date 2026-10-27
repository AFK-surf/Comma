package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.LinearGradient
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.Shader
import android.util.AttributeSet
import android.widget.FrameLayout
import androidx.core.content.ContextCompat
import androidx.core.graphics.ColorUtils
import androidx.core.graphics.withTranslation
import surf.comma.android.R
import kotlin.math.roundToInt

/**
 * Frosted edges for content that scrolls under floating chrome.
 *
 * The children are recorded into [content] each time this layout draws, which is drawn as usual and
 * then drawn again through blurs. Every extra pass references the same display list (the children's
 * own render nodes are not re-recorded, nor are the passes until their geometry changes), so the
 * extra cost is GPU blurs over small areas:
 *
 * - An edge band is a progressive blur: [BAND_LAYERS] passes of growing radius, each masked by a
 *   smoothstep ramp that reaches less far into the band. Near the screen edge all of them
 *   stack to the full radius; towards the band's inner end only the faintest is left, so the blur
 *   thins out into sharp content instead of cross-fading a blurred copy over it (which shows as
 *   a double image). A tint of the page colour on the same ramp keeps the status bar readable,
 *   and the blur is desaturated so the band stays neutral over coloured content.
 * - A patch is a rounded rect blurred at the full radius, for a piece of chrome floating below
 *   the band (a capsule, a button); the chrome paints its own translucent fill over it.
 *
 * It must be the list's parent, not a sibling laid over it: only the parent sees what the list
 * draws. The rubber-band translation the scroll module applies inside the list's own draw is part
 * of what is recorded, so the blur follows overscroll too. Something drawn in a layer above the
 * chrome reaches the blur only through [overlay].
 *
 * [Mode.FADE] draws only the tint ramp: the gradient fallback, with no blur and no extra pass.
 * Bands and top patches are skipped while nothing is scrolled under them ([setTopOverflow],
 * [setBottomOverflow]): a blurred flat background looks exactly like the flat background. The
 * last reply rests in the bottom band's ramp, so that band rises from under the chrome with the
 * content going under it instead of switching on at the first pixel.
 */
class BackdropBlurLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    enum class Mode { BLUR, FADE, OFF }

    var mode: Mode = Mode.BLUR
        set(value) {
            if (field == value) return
            field = value
            rebuild()
        }

    /** The strongest blur radius in px, at the screen edge and under patches. */
    var blurRadiusPx: Float = BLUR_RADIUS_DP * resources.displayMetrics.density
        set(value) {
            if (field == value) return
            field = value
            rebuild()
        }

    private val pageColor = ContextCompat.getColor(context, R.color.token_bg_primary)
    private val desaturate = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(BLUR_SATURATION) })
    private val top = Band(fromTop = true)
    private val bottom = Band(fromTop = false)
    private val content = RenderNode("backdrop-content")
    private val patches = LinkedHashMap<String, Patch>()
    /** Patches under chrome that floats over the content wherever it is scrolled: always frosted. */
    private val floating = LinkedHashMap<String, Patch>()
    private var drawsPatches = false
    private var drawsFloating = false

    init {
        setWillNotDraw(false)
    }

    /**
     * The top band: [heightPx] from the top edge, at full strength over the first [solidPx] (the
     * status bar) and thinning out below it. 0 turns the band off.
     */
    fun setTopBand(heightPx: Int, solidPx: Int = 0) = top.setGeometry(heightPx, solidPx)

    /** The bottom band, lifted by [insetPx] when the keyboard raises the composer. */
    fun setBottomBand(heightPx: Int, solidPx: Int = 0, insetPx: Int = 0) = bottom.setGeometry(heightPx, solidPx, insetPx)

    /**
     * Frosts [bounds] (in this layout's coordinates) with corners of [radiusPx], under the piece
     * of top chrome named [key]. It follows the top band's overflow. Null bounds remove it.
     */
    fun setTopPatch(key: String, bounds: Rect?, radiusPx: Float) {
        if (bounds == null || bounds.isEmpty) {
            if (patches.remove(key) != null) invalidate()
            return
        }
        val patch = patches.getOrPut(key) { Patch(key) }
        if (patch.bounds == bounds && patch.radius == radiusPx) return
        patch.place(bounds, radiusPx)
        invalidate()
    }

    /**
     * Frosts [bounds] with corners of [radiusPx] under a piece of floating chrome named [key], such as a tab bar or
     * a status switcher, whatever is scrolled. Null bounds remove it.
     */
    fun setFloatingPatch(key: String, bounds: Rect?, radiusPx: Float) {
        if (bounds == null || bounds.isEmpty) {
            if (floating.remove(key) != null) invalidate()
            return
        }
        val patch = floating.getOrPut(key) { Patch("floating-$key") }
        if (patch.bounds == bounds && patch.radius == radiusPx) return
        patch.place(bounds, radiusPx)
        invalidate()
    }

    /** Whether content is scrolled under the top band; the band is not drawn while it is not. */
    fun setTopOverflow(overflow: Boolean) = top.setOverflow(overflow)

    /**
     * How far content is scrolled under the bottom band, in px. The band is lowered under the chrome
     * by its ramp's height less this, so it is all the way up once that much is under it and gone at 0.
     */
    fun setBottomOverflow(overflowPx: Int) = bottom.setOverflow(overflowPx)

    /**
     * Drawn over the children as part of what is frosted: the piece of a transition in a layer above
     * the chrome (a message flying in) that is under the chrome, so it is frosted like the content.
     * Its owner records it; this layout does not need to draw again when it changes.
     */
    var overlay: RenderNode? = null
        set(value) {
            if (field === value) return
            field = value
            invalidate()
        }

    /** Whether the last frame drew a blur pass; for tests and benchmarks. */
    val isBlurring: Boolean get() = mode == Mode.BLUR && (top.drawsBlur || bottom.drawsBlur || drawsPatches || drawsFloating)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        rebuild()
    }

    override fun dispatchDraw(canvas: Canvas) {
        val blur = mode == Mode.BLUR && canvas.isHardwareAccelerated && width > 0 && height > 0
        top.drawsBlur = blur && top.active
        bottom.drawsBlur = blur && bottom.active
        drawsPatches = blur && top.overflow && patches.isNotEmpty()
        drawsFloating = blur && floating.isNotEmpty()
        if (!top.drawsBlur && !bottom.drawsBlur && !drawsPatches && !drawsFloating) {
            super.dispatchDraw(canvas)
            drawOverlay(canvas)
        } else {
            content.setPosition(0, 0, width, height)
            val recording = content.beginRecording(width, height)
            try {
                super.dispatchDraw(recording)
                drawOverlay(recording)
            } finally { content.endRecording() }
            canvas.drawRenderNode(content)
            top.drawBlur(canvas)
            bottom.drawBlur(canvas)
            if (drawsPatches) patches.values.forEach { it.draw(canvas) }
            if (drawsFloating) floating.values.forEach { it.draw(canvas) }
        }
        if (mode != Mode.OFF) {
            top.drawTint(canvas)
            bottom.drawTint(canvas)
        }
    }

    /** Only a hardware canvas draws render nodes; a software draw has no transition running over it. */
    private fun drawOverlay(canvas: Canvas) {
        if (canvas.isHardwareAccelerated) overlay?.let(canvas::drawRenderNode)
    }

    private fun rebuild() {
        top.rebuild()
        bottom.rebuild()
        patches.values.forEach { it.rebuild() }
        floating.values.forEach { it.rebuild() }
        invalidate()
    }

    /**
     * Records [content] into [node], shifted so ([left], [top]) lands at the node's origin. The node only refers to
     * [content], which is re-recorded in place, so it needs this again only when its geometry changes.
     */
    private fun recordShifted(node: RenderNode, left: Int, top: Int, width: Int, height: Int) {
        val recording = node.beginRecording(width, height)
        try {
            // The page colour first, so the blurred copy is opaque and fully hides what is under it.
            recording.drawColor(pageColor)
            recording.translate(-left.toFloat(), -top.toFloat())
            recording.drawRenderNode(content)
        } finally { node.endRecording() }
    }

    private fun blur(radius: Float): RenderEffect? =
        if (mode == Mode.BLUR && radius > 0f) {
            // Clamp, not decal: a clipped edge must not blur into transparency.
            val blurred = RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.CLAMP)
            // Most of the colour is taken out, so a coloured bubble passing under the chrome
            // leaves a neutral haze instead of tinting the bar.
            RenderEffect.createColorFilterEffect(desaturate, blurred)
        } else null

    private inner class Patch(key: String) {
        private val node = RenderNode("backdrop-patch-$key")
        val bounds = Rect()
        var radius = 0f
            private set
        private var recorded = false

        fun place(rect: Rect, radiusPx: Float) {
            recorded = false
            bounds.set(rect)
            radius = radiusPx
            node.setPosition(0, 0, rect.width(), rect.height())
            node.setOutline(Outline().apply { setRoundRect(0, 0, rect.width(), rect.height(), radiusPx) })
            node.clipToOutline = true
            rebuild()
        }

        fun rebuild() {
            node.setRenderEffect(blur(blurRadiusPx))
        }

        fun draw(canvas: Canvas) {
            if (!recorded || !node.hasDisplayList()) {
                recordShifted(node, bounds.left, bounds.top, bounds.width(), bounds.height())
                recorded = true
            }
            canvas.withTranslation(bounds.left.toFloat(), bounds.top.toFloat()) { drawRenderNode(node) }
        }
    }

    private inner class Band(private val fromTop: Boolean) {
        private val side = if (fromTop) "top" else "bottom"
        private val layers = List(BAND_LAYERS) { RenderNode("backdrop-$side-$it") }
        private val tint = Paint()
        var heightPx = 0
            private set
        private var solidPx = 0
        private var insetPx = 0
        var overflow = false
            private set
        /** How far a bottom band has come up from under its chrome; see [setBottomOverflow]. */
        private var risePx = Int.MAX_VALUE
        var drawsBlur = false
        private var recorded = false

        val active: Boolean get() = heightPx > 0 && overflow

        fun setGeometry(height: Int, solid: Int, inset: Int = 0) {
            val h = height.coerceAtLeast(0)
            val s = solid.coerceIn(0, h)
            val i = inset.coerceAtLeast(0)
            if (h == heightPx && s == solidPx && i == insetPx) return
            val resized = h != heightPx || s != solidPx
            heightPx = h
            solidPx = s
            insetPx = i
            // Moving with the IME only shifts the source window; keep the same shaders and effects.
            if (resized) rebuild() else recorded = false
            invalidate()
        }

        fun setOverflow(value: Boolean) {
            if (value == overflow) return
            overflow = value
            invalidate()
        }

        fun setOverflow(px: Int) {
            setOverflow(px > 0)
            val sunk = sinkPx
            risePx = px.coerceAtLeast(0)
            // Rising only shifts the source window, as the IME does; the shaders and effects stay.
            if (sinkPx != sunk) {
                recorded = false
                invalidate()
            }
        }

        /** How far below its place the band is drawn while it comes up; never for the top band. */
        private val sinkPx: Int get() = (heightPx - solidPx - risePx).coerceAtLeast(0)

        private val bandTop: Int get() = if (fromTop) 0 else height - insetPx - heightPx + sinkPx

        fun rebuild() {
            // Geometry and size changes all come through here; the layers' shifted copies follow them.
            recorded = false
            if (heightPx <= 0 || width <= 0) {
                tint.shader = null
                layers.forEach { it.setRenderEffect(null) }
                return
            }
            val solid = solidPx.toFloat() / heightPx
            // The fallback has no blur to hide text, so its ramp is close to the page colour.
            tint.shader = ramp(pageColor, if (mode == Mode.FADE) FADE_ALPHA else TINT_ALPHA, solid, 1f)
            layers.forEachIndexed { index, node ->
                node.setPosition(0, 0, width, heightPx)
                val blurred = blur(blurRadiusPx * bandLayerRadius(index))
                node.setRenderEffect(blurred?.let {
                    val mask = RenderEffect.createShaderEffect(ramp(Color.BLACK, 1f, solid, bandLayerReach(index)))
                    RenderEffect.createBlendModeEffect(it, mask, BlendMode.DST_IN)
                })
            }
        }

        /**
         * A smoothstep ramp in the band's own coordinates: [peak] alpha of [base] from the screen
         * edge through the solid part, down to clear at [reach] of the rest of the band.
         */
        private fun ramp(base: Int, peak: Float, solid: Float, reach: Float): Shader {
            val end = solid + (1f - solid) * reach
            val stops = FloatArray(RAMP_STOPS + 2)
            val colors = IntArray(RAMP_STOPS + 2)
            stops[0] = 0f
            colors[0] = ColorUtils.setAlphaComponent(base, (peak * 255f).roundToInt())
            for (index in 0..RAMP_STOPS) {
                val fraction = index / RAMP_STOPS.toFloat()
                stops[index + 1] = solid + (end - solid) * fraction
                colors[index + 1] = ColorUtils.setAlphaComponent(base, (peak * backdropAlphaAt(fraction) * 255f).roundToInt())
            }
            val (y0, y1) = if (fromTop) 0f to heightPx.toFloat() else heightPx.toFloat() to 0f
            return LinearGradient(0f, y0, 0f, y1, colors, stops, Shader.TileMode.CLAMP)
        }

        fun drawBlur(canvas: Canvas) {
            if (!drawsBlur) return
            // Faintest first: each stronger layer stops sooner, so strength builds towards the edge.
            val record = !recorded || layers.any { !it.hasDisplayList() }
            layers.forEach { node ->
                if (record) recordShifted(node, 0, bandTop, width, heightPx)
                canvas.withTranslation(0f, bandTop.toFloat()) { drawRenderNode(node) }
            }
            recorded = true
        }

        fun drawTint(canvas: Canvas) {
            if (!overflow || heightPx <= 0 || tint.shader == null) return
            canvas.withTranslation(0f, bandTop.toFloat()) {
                drawRect(0f, 0f, width.toFloat(), heightPx.toFloat(), tint)
            }
        }
    }

    companion object {
        /** A common frosted-material radius (about 24 dp), trimmed for a phone-sized band. */
        const val BLUR_RADIUS_DP = 20f
        /**
         * How much of the content's colour survives the blur. At a half the blue bubbles left a
         * visible blue glow under the chrome (#E9ECF6 on white); this keeps it a grey haze.
         */
        const val BLUR_SATURATION = 0.15f
        /** Page colour over the frosted band at its strongest. */
        const val TINT_ALPHA = 0.85f
        /** Page colour at the edge in the gradient fallback. */
        const val FADE_ALPHA = 0.94f
        /** Passes in a band's progressive blur. */
        const val BAND_LAYERS = 3
        private const val RAMP_STOPS = 16
    }
}

/** Strength across a band's ramp: 1 where the ramp starts, 0 at its inner end, no visible seams. */
internal fun backdropAlphaAt(fraction: Float): Float = 1f - featherAlphaAt(fraction)

/** A band layer's share of the full radius, faintest first: 1/4, 1/2, 1. */
internal fun bandLayerRadius(layer: Int): Float = 1f / (1 shl (BackdropBlurLayout.BAND_LAYERS - 1 - layer))

/** How far into the band a layer reaches before it is gone: the faintest all the way, the strongest a third. */
internal fun bandLayerReach(layer: Int): Float =
    (BackdropBlurLayout.BAND_LAYERS - layer).toFloat() / BackdropBlurLayout.BAND_LAYERS
