package surf.comma.android.ui.widget

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.graphics.drawable.Drawable
import androidx.annotation.ColorInt
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.annotation.ColorRes
import androidx.core.graphics.withTranslation
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sign

/**
 * The experimental glass material: what the iOS system glass does, drawn by our own shader. [BackdropBlurLayout]
 * records what lies under a piece of chrome, as it does to frost it; here that recording is blurred less and then
 * passed through [GlassLens], so the chrome bends, splits and lights what really is behind it.
 *
 * Its reach ends at the window and at what is drawn through a render node: a Dialog does not see the page under it
 * and nothing sees a SurfaceView's video. Those surfaces stay as they are. See docs/DESIGN.md §9.
 */
object LiquidGlass {
    /** Heavier glass, for chrome that floats over a list: what passes under it is blurred and pale, as under iOS's. */
    const val FROSTED_BLUR_DP = 1f

    /** The member's choice, loaded before the first screen binds; a change recreates the screens. */
    @Volatile var enabled = false

    /** How far past a shape the backdrop is recorded: what is about to pass under its edge reaches the blur, and its shadow fits. */
    const val SOURCE_PAD_DP = 46f
    /** How far two shapes of a group reach for each other: no further than the gap they keep at rest. */
    const val BLEND_DP = 8f
    /** Barely any on clear glass: under the iOS composer, text stays sharp enough to read as it bends. */
    const val BLUR_DP = 0.5f
}

/** One glass shape in a [BackdropBlurLayout]'s coordinates. */
data class GlassShape(val bounds: Rect, val radius: Float)

/** The rectangle a glass node records: all of [shapes], and [padPx] round them. */
internal fun glassSource(shapes: List<GlassShape>, padPx: Int): Rect {
    val source = Rect(shapes.first().bounds)
    shapes.forEach { source.union(it.bounds) }
    source.inset(-padPx, -padPx)
    return source
}

/** How far in from the outline the glass bends what it shows, for a shape [thickness] across: as the iOS rim does. */
internal fun glassBand(thickness: Float, maxPx: Float): Float = min(thickness * 0.3f, maxPx)

/** How far inward the outline itself shows, the most the band reaches. */
internal fun glassDepth(thickness: Float, maxPx: Float): Float = min(thickness * 0.375f, maxPx)

/**
 * The compiled shader with its look, for one node. Every change to it takes a new [effect]: a [RenderEffect] keeps
 * the uniforms it was made with. Shapes are given in the node's own coordinates.
 */
internal class GlassLens(
    context: Context,
    @ColorRes tint: Int = R.color.token_glass_tint,
    blurDp: Float = LiquidGlass.BLUR_DP,
    shadow: Float = SHADOW_ALPHA,
    dispersion: Float = DISPERSION,
    falls: Boolean = true,
    private val blurs: Boolean = true,
    private val highlightDp: Float = HIGHLIGHT_DP,
    /** A band with a solid part, for a large clear shape: a soft tail would haze what it magnifies. */
    clearEdge: Boolean = false,
    private val depthShare: Float = 1f,
    private val sideShare: Float = 0f,
    private val ringShare: Float = 0f,
    private val bandShare: Float = 1f,
    flare: Float = 0f,
    private val paleFringe: Float = 0f,
    lineShare: Float = 1f,
    rimShare: Float = 1f,
    iridescence: Float = 0f,
    dims: Boolean = true,
    innerShadow: Float = 0f,
    inset: Float = INSET,
    shadowReachDp: Float = SHADOW_REACH_DP,
    shadowDropDp: Float = SHADOW_DROP_DP,
) {
    private val shader = RuntimeShader(SHADER)
    private val density = context.resources.displayMetrics.density
    private val blurPx = blurDp * density

    init {
        shader.setColorUniform("tint", context.getColor(tint))
        shader.setFloatUniform("rim", channels(context.getColor(R.color.token_glass_rim)).also { it[3] *= rimShare })
        shader.setFloatUniform("line", channels(context.getColor(R.color.token_glass_line)).also { it[3] *= lineShare })
        shader.setFloatUniform("fall", if (falls) channels(context.getColor(R.color.token_glass_fall)) else FloatArray(4))
        shader.setFloatUniform("lineWidth", LINE_WIDTH_DP * density)
        shader.setFloatUniform("clearEdge", if (clearEdge) 1f else 0f)
        shader.setFloatUniform("dispersion", dispersion)
        shader.setFloatUniform("iridescence", iridescence)
        shader.setFloatUniform("paleFringe", paleFringe)
        shader.setFloatUniform("flare", flare)
        val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        shader.setFloatUniform("ceiling", if (night && dims) DARK_CEILING else 1f)
        shader.setFloatUniform("glow", GLOW_RADIUS_DP * density)
        shader.setFloatUniform("shadow", shadow)
        shader.setFloatUniform("shadowReach", shadowReachDp * density)
        shader.setFloatUniform("shadowDrop", shadowDropDp * density)
        shader.setFloatUniform("innerShadow", innerShadow)
        shader.setFloatUniform("inset", inset)
        setPress(0f, 0f, 0f)
        setZoom(1f, 0f, 0f)
        setPressVeil(0f)
        shader.setFloatUniform("glowAmount", GLOW_AMOUNT)
        shader.setFloatUniform("pressDim", 0f)
        shader.setFloatUniform("arcAmount", 0f)
        setEnds(0f, 0f)
    }

    /** How far, from 0 to 1, the lens's left and right ends hang past the ends of what it lies on. */
    fun setEnds(left: Float, right: Float) {
        shader.setFloatUniform("endLeft", left)
        shader.setFloatUniform("endRight", right)
    }

    /** Shows what lies under the glass [zoom] times larger, about ([x], [y]). */
    fun setZoom(zoom: Float, x: Float, y: Float) {
        shader.setFloatUniform("zoom", zoom)
        shader.setFloatUniform("zoomCenter", x, y)
    }

    /**
     * Makes a press a light that follows the finger. The surface whitens, as on iOS. Page white is as bright as the glass
     * can go, so the light shows along the outline, against a rim that sinks a little away from the finger.
     */
    /** With [whole] false only the glass near the finger answers, for a group where the finger is on one member. */
    fun followFinger(context: Context, whole: Boolean = true) {
        val night = context.resources.configuration.isNightModeActive
        val density = context.resources.displayMetrics.density
        shader.setFloatUniform("glow", FINGER_GLOW_DP * density)
        shader.setFloatUniform("glowAmount", if (night) FINGER_LIGHT_NIGHT else 1f)
        shader.setFloatUniform("pressDim", if (night || !whole) 0f else FINGER_DIM)
        if (!night && whole) setPressVeil(FINGER_VEIL)
        shader.setFloatUniform("arcAmount", if (night) FINGER_ARC_NIGHT else 1f)
    }

    fun setShadow(alpha: Float) = shader.setFloatUniform("shadow", alpha)

    /** Colours the glass, for a tint that changes with the state of its control. */
    fun setTint(@ColorInt color: Int) = shader.setColorUniform("tint", color)

    /** How much whiter the whole glass goes under a press, as the iOS tab bar does while its indicator is lifted. */
    fun setPressVeil(amount: Float) = shader.setFloatUniform("pressVeil", amount)

    /** At most two shapes: a pair the shader melts together across [blendPx]. */
    fun setShapes(first: GlassShape, second: GlassShape?, originX: Int, originY: Int, blendPx: Float) {
        fun box(shape: GlassShape) = shape.bounds.run {
            floatArrayOf((left - originX).toFloat(), (top - originY).toFloat(), (right - originX).toFloat(), (bottom - originY).toFloat())
        }
        shader.setFloatUniform("shapeA", box(first))
        shader.setFloatUniform("radiusA", first.radius)
        shader.setFloatUniform("shapeB", box(second ?: first))
        shader.setFloatUniform("radiusB", (second ?: first).radius)
        shader.setFloatUniform("blend", if (second == null) 0f else blendPx)
        val thickness = min(first.bounds.height(), second?.bounds?.height() ?: first.bounds.height()).toFloat()
        shader.setFloatUniform("highlight", min(thickness * HIGHLIGHT_SHARE, highlightDp * density))
        val insetReach = min(thickness * INSET_SHARE, INSET_REACH_DP * density)
        shader.setFloatUniform("insetReach", insetReach)
        shader.setFloatUniform("insetDrop", insetReach * INSET_DROP)
        shader.setFloatUniform("band", glassBand(thickness, MAX_BAND_DP * density) * bandShare)
        val depth = glassDepth(thickness, MAX_DEPTH_DP * density)
        shader.setFloatUniform("depth", depth * depthShare)
        shader.setFloatUniform("sideDepth", depth * sideShare)
        shader.setFloatUniform("ring", depth * ringShare)
    }

    /** [amount] from 0 to 1 of a press at ([x], [y]). */
    fun setPress(amount: Float, x: Float, y: Float) {
        shader.setFloatUniform("press", amount)
        shader.setFloatUniform("touch", x, y)
    }

    fun effect(): RenderEffect {
        val glass = RenderEffect.createRuntimeShaderEffect(shader, "content")
        // Clamp, not decal: the recording's edge must not blur into transparency.
        return if (blurs) RenderEffect.createChainEffect(glass, RenderEffect.createBlurEffect(blurPx, blurPx, Shader.TileMode.CLAMP)) else glass
    }

    private fun channels(color: Int) = floatArrayOf(Color.red(color) / 255f, Color.green(color) / 255f, Color.blue(color) / 255f, Color.alpha(color) / 255f)

    private companion object {
        const val MAX_BAND_DP = 18f
        const val MAX_DEPTH_DP = 22f
        /**
         * The dark line round the shape, and how fast the light inside it falls away. Read off the HDR recording: a screenshot
         * clips the peak to white and makes it look about six pixels wide, where it peaks in one and its tail runs on 20.
         */
        const val HIGHLIGHT_DP = 3.6f
        /** Measured from the iOS 27 tab bar: 2.4 % darker at most, 17 dp deep, cast from 7.5 dp above. */
        const val INSET = 0.024f
        const val INSET_SHARE = 0.27f
        const val INSET_REACH_DP = 17f
        const val INSET_DROP = 0.45f
        /** A small control's band stays in proportion, or it covers what the control shows. */
        const val HIGHLIGHT_SHARE = 0.22f
        const val LINE_WIDTH_DP = 0.7f
        const val GLOW_RADIUS_DP = 56f
        const val GLOW_AMOUNT = 0.22f
        const val FINGER_GLOW_DP = 30f
        const val FINGER_DIM = 0.08f
        const val FINGER_VEIL = 0.75f
        const val FINGER_LIGHT_NIGHT = 0.16f
        const val FINGER_ARC_NIGHT = 0.6f
        /**
         * The chrome's shadow, drawn here because an elevation shadow would fall on the clear chrome itself. It is wide and
         * soft: darkening the page round the glass is what makes the glass read brighter than the page and stand out.
         */
        private const val SHADOW_ALPHA = 0.022f
        private const val SHADOW_REACH_DP = 32f
        private const val SHADOW_DROP_DP = 10f
        /** How much further red reaches than green, and blue less, as a share of the reach. */
        private const val DISPERSION = 0.04f
        /** The brightest the dark glass lets a backdrop through, so white text sinks into it as it does on iOS. */
        const val DARK_CEILING = 0.5f

        /**
         * Measured against the iOS system glass on the same content. In a band along the outline each point shows
         * what lies further in along the outline's normal, reaching furthest at the outline, so what lies under the
         * rim stretches and folds; past the band the glass is flat. Red reaches a little further than green and blue
         * a little less. The veil is a plain mix that leaves greys grey and turns blue a little towards cyan, as the system's does, and
         * over it the glass falls off from its top edge. The outline is lit
         * along its top and bottom and shaded along its sides. Outside the shapes only the shadow is drawn.
         */
        val SHADER = """
            uniform shader content;
            uniform float4 shapeA;
            uniform float4 shapeB;
            uniform float radiusA;
            uniform float radiusB;
            uniform float blend;
            uniform float band;
            uniform float depth;
            uniform float sideDepth;
            uniform float ring;
            uniform float endLeft;
            uniform float endRight;
            uniform float dispersion;
            uniform float iridescence;
            uniform float paleFringe;
            uniform float glowAmount;
            uniform float arcAmount;
            const float ARC_REACH = 1.9;
            const float RIM_SHADE = 10.0;
            uniform float pressDim;
            const float FLARE_SPLIT = 0.1;
            uniform float flare;
            uniform float innerShadow;
            uniform float inset;
            uniform float insetReach;
            uniform float insetDrop;
            uniform float zoom;
            uniform float2 zoomCenter;
            uniform float pressVeil;
            uniform float ceiling;
            layout(color) uniform half4 tint;
            uniform float4 rim;
            uniform float4 line;
            uniform float4 fall;
            uniform float lineWidth;
            uniform float clearEdge;
            const float HIGHLIGHT_TAIL = 0.8;
            const float CLEAR_SOLID = 2.857;
            uniform float highlight;
            uniform float press;
            uniform float2 touch;
            uniform float glow;
            uniform float shadow;
            uniform float shadowReach;
            uniform float shadowDrop;

            float rounded(float2 p, float4 box, float radius) {
                float2 center = (box.xy + box.zw) * 0.5;
                float2 half_size = (box.zw - box.xy) * 0.5;
                float2 q = abs(p - center) - half_size + radius;
                return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
            }

            float field(float2 p) {
                float a = rounded(p, shapeA, radiusA);
                if (blend <= 0.0) return a;
                float b = rounded(p, shapeB, radiusB);
                float h = max(blend - abs(a - b), 0.0) / blend;
                return min(a, b) - h * h * blend * 0.25;
            }

            half4 main(float2 p) {
                float d = field(p);
                float cover = clamp(0.5 - d, 0.0, 1.0);
                if (cover <= 0.0) {
                    float fall = 1.0 - smoothstep(0.0, shadowReach, field(p - float2(0.0, shadowDrop)));
                    return half4(0.0, 0.0, 0.0, half(shadow * fall * fall));
                }

                float reach = depth * (1.0 + 0.3 * press);
                float t = clamp(1.0 + d / band, 0.0, 1.0);
                float2 zoomed = zoomCenter + (p - zoomCenter) / zoom;
                float3 color;
                float2 outward = float2(0.0, -1.0);
                float over = 0.0;
                if (t <= 0.0) {
                    color = content.eval(zoomed).rgb;
                } else {
                    float2 gradient = float2(field(p + float2(1.0, 0.0)) - field(p - float2(1.0, 0.0)),
                                             field(p + float2(0.0, 1.0)) - field(p - float2(0.0, 1.0)));
                    float size = length(gradient);
                    if (size > 0.0001) outward = gradient / size;
                    // A rim that looks outward does so along the top and bottom only, over the shape's straight run. Its
                    // round ends look inward, so what passes under them stretches and splits as it reaches the outline.
                    float top = smoothstep(0.5, 0.99, outward.y * outward.y);
                    float shift = (reach < 0.0 ? mix(sideDepth, reach, top) : reach) * t * t;
                    // One lens, read off the iOS bar. Its middle magnifies. Where its outline lies over the bar's edge, or runs along
                    // it, it looks outward, so the bar's own outline comes in as one unbroken ring with the page and the bar's
                    // shadow outside it. Elsewhere its round ends look further in along the normal, so what passes under them
                    // is stretched and fans out along the outline. Nothing in it ever shrinks.
                    float2 q = ring > 0.0 ? zoomed : mix(zoomed, p, t);
                    if (ring > 0.0) {
                        over = max(top, outward.x < 0.0 ? endLeft : endRight);
                        shift = mix(sideDepth * t * t * (2.0 - t), -ring * sin(2.356 * t), over);
                        q = mix(q, p, over * smoothstep(0.0, 0.5, t));
                    }
                    // Lines running into a round end flare apart towards the outline, each colour by its own measure.
                    float squeeze = flare * t * t * (1.0 - top);
                    float2 middle = float2(0.0, zoomCenter.y);
                    float2 way = outward * shift;
                    color = float3(
                        content.eval(q - (q - middle) * float2(0.0, squeeze * (1.0 + FLARE_SPLIT)) - way * (1.0 + dispersion)).r,
                        content.eval(q - (q - middle) * float2(0.0, squeeze) - way).g,
                        content.eval(q - (q - middle) * float2(0.0, squeeze * (1.0 - FLARE_SPLIT)) - way * (1.0 - dispersion)).b);
                    color = mix(color, float3((color.r + color.g + color.b) / 3.0), paleFringe * t);
                }

                float level = dot(color, float3(0.2126, 0.7152, 0.0722));
                if (level > ceiling) color *= (ceiling + (level - ceiling) * 0.15) / level;
                color = mix(color, float3(tint.rgb), float(tint.a));
                // A press lifts the glass towards the light, whatever tone its tint gives it at rest.
                color = mix(color, rim.rgb, pressVeil * press);
                // Clear glass only: on a solid tint this would shift the colour it was asked for.
                if (tint.a < 1.0) color.g = clamp(color.g + 0.12 * max(color.b - color.r, 0.0), 0.0, 1.0);
                float top = min(shapeA.y, shapeB.y);
                float down = clamp((p.y - top) / (max(shapeA.w, shapeB.w) - top), 0.0, 1.0);
                color = mix(color, fall.rgb, fall.a * (1.0 - down));

                if (iridescence > 0.0 && t > 0.0) {
                    // Thin lines of colour that run along the ring, the way a soap film bands. They add to the colour under
                    // them rather than replace it, and stay off the straight top and bottom runs.
                    float bands = t * 22.0 + atan(outward.y, outward.x) * 1.5;
                    float3 film = cos(bands + float3(0.0, 2.1, 4.2));
                    float ringZone = over * smoothstep(0.35, 0.55, t) * smoothstep(0.15, 0.5, abs(outward.x));
                    color = clamp(color + film * iridescence * max(ringZone, smoothstep(0.82, 0.95, t) * abs(outward.x)), 0.0, 1.0);
                }

                color *= 1.0 - innerShadow * t * t;
                if (inset > 0.0) {
                    // The glass's body: a shadow cast in from above, which runs down the sides and is gone by the bottom edge.
                    // It is what the lit edge stands against, so the edge reads brighter than the glass and the glass reads thick.
                    float below = -field(p - float2(0.0, insetDrop));
                    float high = (p.y - min(shapeA.y, shapeB.y)) / (max(shapeA.w, shapeB.w) - min(shapeA.y, shapeB.y));
                    color *= 1.0 - inset * (1.0 - smoothstep(0.0, insetReach, below)) * (1.0 - smoothstep(0.55, 1.0, high));
                }
                
                float inner = -d;
                // Measured normal by normal against the iOS 27 glass. A thin crescent of light hugs the dark line, widest on the
                // edges that face up or down and running out only as the edge turns fully sideways; a soft glow falls away
                // under it on the straight runs, shorter along the bottom. The line stays light until past the diagonal and
                // then darkens quickly.
                float side = abs(outward.x);
                float up = abs(outward.y);
                float lineEnd = lineWidth * 1.4;
                float crescent = lineWidth * (clearEdge > 0.0 ? 0.9 + 1.6 * up * up : 0.4 + 0.5 * up * up);
                // The light falls off as a curve with no knee: a thin peak, then a faint tail that runs on into the glass. A band
                // with a solid part and an end reads as a hard edge however narrow it is.
                float past = max(inner - lineEnd, 0.0);
                float thin = (1.0 - smoothstep(0.0, crescent, past)) * smoothstep(0.05, 0.4, up);
                float tail = HIGHLIGHT_TAIL * exp(-past / (outward.y > 0.0 ? highlight * 0.75 : highlight)) * smoothstep(0.45, 0.95, up);
                if (clearEdge > 0.0) {
                    thin = (1.0 - smoothstep(crescent * 0.7, crescent, past)) * smoothstep(0.05, 0.4, up);
                    tail = 1.0 - smoothstep(CLEAR_SOLID * lineWidth, outward.y > 0.0 ? highlight * 0.6 : highlight, inner);
                    tail = tail * tail * tail * smoothstep(0.8, 0.97, up);
                }
                float lit = max(thin, tail);
                color = mix(color, rim.rgb, rim.a * lit);
                color = mix(color, line.rgb, line.a * (0.33 + 0.67 * smoothstep(0.5, 0.95, side))
                    * (1.0 - smoothstep(lineWidth * 0.7, lineEnd, inner)));

                if (press > 0.0) {
                    float away = length(p - touch) / glow;
                    float light = exp(-away * away);
                    // The surface only ever brightens. The far rim sinks a little instead, so the near rim reads as lit.
                    color *= 1.0 - pressDim * press * (1.0 - light) * (1.0 - smoothstep(0.0, lineWidth * RIM_SHADE, inner));
                    color = mix(color, float3(1.0), glowAmount * press * light);
                    // A fingertip hides the light under it, so the outline carries it out past the finger.
                    float arc = away / ARC_REACH;
                    color = mix(color, float3(1.0), arcAmount * press * exp(-arc * arc)
                        * (1.0 - smoothstep(lineWidth * 1.5, lineWidth * 5.0, inner)));
                }
                return half4(half3(color * cover), half(cover));
            }
        """.trimIndent()
    }
}

/**
 * The glass of a menu that floats over its window, in the card's own bounds so it scales and fades with the card.
 * [bounds] is the card in [root]'s coordinates. Everything in [root] but [above] is recorded once; the recording
 * refers to their render nodes, so what plays under the menu keeps playing.
 */
internal class GlassBackdrop(
    context: Context,
    private val root: ViewGroup,
    private val above: View,
    private val bounds: RectF,
    private val radius: Float,
    shadow: Float = 0f,
) : Drawable() {
    private val density = context.resources.displayMetrics.density
    private val pad = (LiquidGlass.SOURCE_PAD_DP * density).toInt()
    private val page = context.getColor(R.color.token_bg_primary)
    private val node = RenderNode("glass-menu")
    private var recorded = false
    private val lens = GlassLens(context, R.color.token_glass_tint_menu, shadow = shadow, inset = 0f, shadowReachDp = CARD_SHADOW_REACH_DP, shadowDropDp = CARD_SHADOW_DROP_DP).apply {
        val width = bounds.width().toInt()
        val height = bounds.height().toInt()
        setShapes(GlassShape(Rect(pad, pad, pad + width, pad + height), radius), null, 0, 0, 0f)
    }

    init {
        node.setPosition(0, 0, bounds.width().toInt() + pad * 2, bounds.height().toInt() + pad * 2)
        node.setRenderEffect(lens.effect())
    }

    /** How dark the glass's own shadow is, for a card that grows out of a control and takes its shadow up on the way. */
    fun setShadow(alpha: Float) = lens.setShadow(alpha)

    /** Moves the glass to [shape], in the card's coordinates, melted into [other] across [blendPx] when there is one. */
    fun setShape(shape: RectF, radius: Float, other: GlassShape? = null, blendPx: Float = 0f) {
        val moved = Rect(shape.left.roundToInt() + pad, shape.top.roundToInt() + pad, shape.right.roundToInt() + pad, shape.bottom.roundToInt() + pad)
        val also = other?.let { GlassShape(Rect(it.bounds).apply { offset(pad, pad) }, it.radius) }
        lens.setShapes(GlassShape(moved, radius), also, 0, 0, blendPx)
        node.setRenderEffect(lens.effect())
        invalidateSelf()
    }

    override fun draw(canvas: Canvas) {
        if (!canvas.isHardwareAccelerated) return
        if (!recorded) {
            val recording = node.beginRecording()
            try {
                recording.drawColor(page)
                recording.translate(pad - bounds.left, pad - bounds.top)
                for (index in 0 until root.childCount) {
                    val child = root.getChildAt(index)
                    if (child === above || child.visibility != View.VISIBLE) continue
                    recording.withTranslation(child.x, child.y) { child.draw(this) }
                }
            } finally { node.endRecording() }
            recorded = true
        }
        canvas.withTranslation(-pad.toFloat(), -pad.toFloat()) { drawRenderNode(node) }
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.TRANSLUCENT

    companion object {
        const val REST_SHADOW = 0.022f

        /** Read off an iOS menu on white: about 3.5% at the edge, gone in 30 pt, and nearly even all round. */
        const val CARD_SHADOW = 0.04f
        private const val CARD_SHADOW_REACH_DP = 30f
        private const val CARD_SHADOW_DROP_DP = 2f
    }
}

/**
 * A menu in its anchor's own window: a PopupWindow is a window of its own and sees nothing of the page, so with the
 * experimental glass a menu goes here instead. Like the popup it covers the window, so a tap off the menu closes it,
 * and the back gesture closes it first.
 */
internal class GlassMenuLayer private constructor(private val root: ViewGroup) : FrameLayout(root.context) {
    private val back = OnBackInvokedCallback { dismiss() }
    private var dispatcher: OnBackInvokedDispatcher? = null

    init {
        setOnClickListener { dismiss() }
        isFocusable = false
        clipChildren = false
    }

    /** Takes the menu back into its control when it closes, in place of it just going. */
    var morph: GlassMenuMorph? = null

    private var closing = false

    // A closing menu's rows are on their way out, and the page under it is not back yet.
    override fun dispatchTouchEvent(event: MotionEvent) = closing || super.dispatchTouchEvent(event)

    /** Puts [frame] with its top left at ([x], [y]) in the window, over everything in it. */
    fun show(frame: View, x: Int, y: Int) {
        addView(frame, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            leftMargin = x
            topMargin = y
        })
        root.addView(this, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        dispatcher = findOnBackInvokedDispatcher()?.also { it.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_OVERLAY, back) }
    }

    fun dismiss() {
        if (closing) return
        dispatcher?.unregisterOnBackInvokedCallback(back)
        dispatcher = null
        val shape = morph
        if (shape == null) {
            root.removeView(this)
        } else {
            closing = true
            shape.close { root.removeView(this) }
        }
    }

    /** A glass [card] of [radius] at [bounds] in the window. */
    fun backdrop(bounds: RectF, radius: Float, shadow: Float = 0f) = GlassBackdrop(context, root, this, bounds, radius, shadow)

    companion object {
        /** The layer for a menu at [bounds] in [anchor]'s window; null while the glass is off or the window is too small for it. */
        fun over(anchor: View, bounds: RectF): GlassMenuLayer? {
            val root = anchor.rootView as? ViewGroup ?: return null
            if (!LiquidGlass.enabled || !anchor.isHardwareAccelerated || !RectF(0f, 0f, root.width.toFloat(), root.height.toFloat()).contains(bounds)) return null
            return GlassMenuLayer(root)
        }
    }
}

/** How much larger a pressed control goes: a circle by half as much again, as on iOS, and a long capsule far less. */
internal fun glassPressScale(width: Float, height: Float): Float {
    if (width <= 0f || height <= 0f) return 1f
    return 1f + GlassPress.GROWTH * min(1f, min(width, height) / max(width, height))
}

/** How far a pressed control follows a finger [drag] away: a little at first, and then no further than [reachPx]. */
internal fun glassDragPull(drag: Float, reachPx: Float): Float =
    sign(drag) * reachPx * (1f - exp(-abs(drag) / (reachPx * GlassPress.PULL_EASE)))

/** How far a drag of [distance] stretches a control along itself, as a share. It squeezes the same share across. */
internal fun glassDragStretch(distance: Float, reachPx: Float): Float =
    GlassPress.MAX_STRETCH * (1f - exp(-distance / (reachPx * GlassPress.STRETCH_EASE)))

/**
 * The press of interactive glass, measured frame by frame from iOS. It swells over about 150 ms; a drag barely moves it
 * and stretches it a few percent along the way; let go, it is back in about 85 ms and rebounds. [changed] runs on every
 * step with how far it is pressed and the finger's place on the screen. [content] fades while it is pressed.
 */
internal class GlassPress(
    private val view: View,
    private val content: View? = null,
    private val changed: (amount: Float, rawX: Float, rawY: Float) -> Unit,
) {
    private val density = view.resources.displayMetrics.density
    private val reach = REACH_DP * density
    private var amount = 0f
    private var rawX = 0f
    private var rawY = 0f
    private var downX = 0f
    private var downY = 0f
    private val rise = DesignSpring(this, AMOUNT, RISE, 0.002f)
    private val rebound = DesignSpring(this, AMOUNT, REBOUND, 0.002f)

    init {
        // Its shadow and its press reach past what lays it out.
        view.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = unclip()
            override fun onViewDetachedFromWindow(v: View) = Unit
        })
    }

    fun track(event: MotionEvent) {
        rawX = event.rawX
        rawY = event.rawY
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = rawX
                downY = rawY
                rebound.cancel()
                rise.animateTo(1f)
            }
            MotionEvent.ACTION_MOVE -> apply()
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                rise.cancel()
                rebound.animateTo(0f)
            }
        }
    }

    private fun unclip() {
        var parent = view.parent as? ViewGroup
        repeat(CLIP_LEVELS) {
            parent?.clipChildren = false
            parent?.clipToPadding = false
            parent = parent?.parent as? ViewGroup
        }
    }

    private fun setAmount(value: Float) {
        amount = value
        apply()
    }

    private fun apply() {
        val dx = rawX - downX
        val dy = rawY - downY
        val distance = hypot(dx, dy)
        val stretch = if (distance > 0f) glassDragStretch(distance, reach) else 0f
        val along = if (distance > 0f) dx * dx / (distance * distance) else 0f
        val up = amount.coerceAtLeast(0f)
        val scale = 1f + (glassPressScale(view.width.toFloat(), view.height.toFloat()) - 1f) * amount
        view.scaleX = scale * (1f + stretch * (2f * along - 1f) * up)
        view.scaleY = scale * (1f - stretch * (2f * along - 1f) * up)
        view.translationX = glassDragPull(dx, reach) * up
        view.translationY = glassDragPull(dy, reach) * up
        content?.alpha = 1f - CONTENT_FADE * amount.coerceIn(0f, 1f)
        changed(amount.coerceIn(0f, 1f), rawX, rawY)
    }

    companion object {
        const val GROWTH = 0.47f
        const val REACH_DP = 2f
        const val MAX_STRETCH = 0.03f
        const val PULL_EASE = 6f
        const val STRETCH_EASE = 16f
        private const val CONTENT_FADE = 0.7f
        private const val CLIP_LEVELS = 3
        private val RISE = DesignMotion.SpringToken(500f, 0.9f)
        private val REBOUND = DesignMotion.SpringToken(900f, 0.4f)
        private val AMOUNT = object : FloatPropertyCompat<GlassPress>("glassPress") {
            override fun getValue(press: GlassPress) = press.amount
            override fun setValue(press: GlassPress, value: Float) = press.setAmount(value)
        }
    }
}

/**
 * Glass for a control that lies on a plain surface, where nothing passes under it: the same edge, inner shadow and shadow
 * as sampled glass, over a [backdrop] colour, with no host to record the page. [radius] below 0 makes a capsule.
 */
internal class GlassSurface(
    context: Context,
    @ColorRes backdrop: Int,
    private val radius: Float = -1f,
    @ColorRes tint: Int = R.color.token_glass_tint,
) : Drawable() {
    private val density = context.resources.displayMetrics.density
    private val pad = (LiquidGlass.SOURCE_PAD_DP * density).toInt()
    private val color = context.getColor(backdrop)
    private val node = RenderNode("glass-surface")
    private val lens = (if (tint == R.color.token_glass_tint) {
        GlassLens(context, blurs = false, falls = false).apply { followFinger(context) }
    } else {
        // Solid colour shows every shade the clear glass hides: measured on iOS, only a fine light edge stays.
        GlassLens(context, tint, blurs = false, falls = false, highlightDp = TINTED_HIGHLIGHT_DP, lineShare = TINTED_EDGE, rimShare = TINTED_EDGE, inset = 0f)
            .apply { setPressVeil(TINTED_VEIL) }
    })

    /** Colours this glass, as for a control that turns off and on. */
    fun setGlassTint(@ColorInt color: Int) {
        lens.setTint(color)
        node.setRenderEffect(lens.effect())
        invalidateSelf()
    }

    fun setPress(amount: Float, x: Float, y: Float) {
        // A finger that has left the glass leaves its light at the nearest edge.
        lens.setPress(amount, x.coerceIn(0f, bounds.width().toFloat()) + pad, y.coerceIn(0f, bounds.height().toFloat()) + pad)
        node.setRenderEffect(lens.effect())
        invalidateSelf()
    }

    override fun onBoundsChange(bounds: Rect) {
        if (bounds.isEmpty) return
        val width = bounds.width()
        val height = bounds.height()
        node.setPosition(0, 0, width + pad * 2, height + pad * 2)
        val recording = node.beginRecording()
        try { recording.drawColor(color) } finally { node.endRecording() }
        lens.setShapes(GlassShape(Rect(pad, pad, pad + width, pad + height), if (radius < 0f) min(width, height) / 2f else radius), null, 0, 0, 0f)
        node.setRenderEffect(lens.effect())
    }

    override fun draw(canvas: Canvas) {
        if (!canvas.isHardwareAccelerated || bounds.isEmpty) return
        canvas.withTranslation(bounds.left - pad.toFloat(), bounds.top - pad.toFloat()) { drawRenderNode(node) }
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: ColorFilter?) = Unit
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.TRANSLUCENT

    private companion object {
        /** Set so a pressed button reads as an iOS prominent one on screen, about a third of the way to white. */
        const val TINTED_VEIL = 0.25f
        const val TINTED_HIGHLIGHT_DP = 1.2f
        const val TINTED_EDGE = 0.4f
    }
}

/** A row of glass buttons that presses as one, whichever of them the finger is on. */
class GlassCapsule(context: Context) : LinearLayout(context) {
    private var press: GlassPress? = null

    /** Makes this glass over [backdrop] while the experimental glass is on; otherwise it runs [plain]. */
    fun glassOver(@ColorRes backdrop: Int, plain: GlassCapsule.() -> Unit) {
        press = glassControl(backdrop) ?: run { plain(); null }
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        press?.track(event)
        return super.dispatchTouchEvent(event)
    }
}

/** Gives this view glass over [backdrop] and returns its press, or null while the experimental glass is off. */
internal fun View.glassControl(
    @ColorRes backdrop: Int,
    content: View? = null,
    @ColorRes tint: Int = R.color.token_glass_tint,
): GlassPress? {
    if (!LiquidGlass.enabled) return null
    val surface = GlassSurface(context, backdrop, tint = tint)
    background = surface
    val origin = IntArray(2)
    return GlassPress(this, content) { amount, rawX, rawY ->
        getLocationOnScreen(origin)
        surface.setPress(amount, rawX - origin[0], rawY - origin[1])
    }
}
