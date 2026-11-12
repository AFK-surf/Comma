package surf.comma.android.ui.composer

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.view.Gravity
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.ui.connection.ConnectionSpinner
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * What fills the composer's capsule while it dictates: the waveform while it records, then the note and spinner while
 * it transcribes. It lies over the capsule at the same size. [ComposerView] holds the capsule collapsed to one row
 * until the dictation ends. It is laid out at all times, so showing it costs no layout.
 */
internal class DictationCapsule(context: Context, style: ComposerStyle, level: () -> Float) : FrameLayout(context) {
    private val waveform = DictationWaveformView(context, style, level)
    private val note = TextView(context).apply {
        style.applyText(this, DesignTypography.Level.SMALL)
        setTextColor(style.textTertiary)
        setText(R.string.composer_dictation_transcribing)
        gravity = Gravity.CENTER_VERTICAL
    }
    private val spinner = ConnectionSpinner(context).apply { color = style.textTertiary }

    init {
        visibility = INVISIBLE
        alpha = 0f
        isClickable = true
        clipToOutline = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, view.height / 2f)
            }
        }
        addView(waveform, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        note.alpha = 0f
        addView(note, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT, Gravity.START).apply {
            marginStart = style.dp(16)
        })
        spinner.visibility = INVISIBLE
        val ring = style.dp(SPINNER_DP)
        // Send is hidden, so the spinner takes the row's last corner.
        addView(spinner, LayoutParams(ring, ring, Gravity.END or Gravity.CENTER_VERTICAL).apply {
            marginEnd = (style.dp(ComposerRow.SLOT_DP) - ring) / 2
        })
    }

    fun show(phase: DictationPhase) {
        contentDescription = context.getString(if (phase == DictationPhase.TRANSCRIBING) R.string.composer_dictation_transcribing
            else R.string.composer_dictate_stop)
        val recording = phase == DictationPhase.RECORDING
        val transcribing = phase == DictationPhase.TRANSCRIBING
        val fade = DesignMotion.durationMillis(DesignMotion.stateChange)
        if (recording) {
            waveform.begin()
            waveform.alpha = 0f
        }
        if (phase != DictationPhase.IDLE) {
            visibility = VISIBLE
            animate().cancel()
            alpha = 1f
        }
        waveform.animate().alpha(if (recording) 1f else 0f).setDuration(fade).setInterpolator(DesignMotion.softInOut)
            .withEndAction { if (!recording) waveform.end() }.start()
        // The note goes at once: the words arrive in its place.
        note.animate().cancel()
        if (transcribing) {
            note.animate().alpha(1f).setDuration(fade).setInterpolator(DesignMotion.softInOut).start()
        } else {
            note.alpha = 0f
        }
        spinner.visibility = if (transcribing) VISIBLE else INVISIBLE
        if (phase == DictationPhase.IDLE) {
            animate().alpha(0f).setDuration(fade).setInterpolator(DesignMotion.softInOut)
                .withEndAction { visibility = INVISIBLE }.start()
        }
    }

    private companion object {
        const val SPINNER_DP = 18
    }
}

/**
 * The waveform. The row starts full of faint resting bars. Bars enter at the trailing end on a clock of their own,
 * each with the level heard since the last one, and the strip moves toward the leading end at a steady speed, so they
 * push the resting bars out. Where the bars reach the capsule's round ends,
 * [RIM_SHADER] bends them as a glass rim bends what lies under it, and splits their colours.
 *
 * Cost while recording: this view redraws each frame through one shader pass, and nothing lays out. Off screen it
 * draws nothing.
 */
@SuppressLint("ViewConstructor")
internal class DictationWaveformView(context: Context, style: ComposerStyle, private val level: () -> Float) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = style.textPrimary }
    private val bar = RectF()
    private val barWidth = style.dp(BAR_WIDTH_DP)
    private val barStep = style.dp(BAR_STEP_DP)
    private val maxHeight = style.dp(MAX_HEIGHT_DP)
    private val ink = style.textPrimary
    private val backdrop = style.composerBg
    private val strip = DictationStrip()
    private var running = false
    /** The size the rim's shader was built for. It is built at the first recording: a composer that never dictates pays nothing. */
    private var rimWidth = 0
    private var rimHeight = 0

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** Starts over; the clock starts on the first frame drawn, which is the first the member sees. */
    fun begin() {
        buildRim()
        strip.reset()
        running = true
        invalidate()
    }

    fun end() {
        running = false
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (running) buildRim()
    }

    private fun buildRim() {
        if (width == 0 || height == 0 || (width == rimWidth && height == rimHeight)) return
        rimWidth = width
        rimHeight = height
        val rim = RuntimeShader(RIM_SHADER).apply {
            setFloatUniform("size", width.toFloat(), height.toFloat())
            setFloatUniform("band", height * BAND_SHARE)
            setFloatUniform("depth", height * DEPTH_SHARE)
            setFloatUniform("dispersion", DISPERSION)
            setFloatUniform("softness", context.resources.displayMetrics.density * SOFTNESS_DP)
            setColorUniform("ink", ink)
            setColorUniform("backdrop", backdrop)
        }
        setRenderEffect(RenderEffect.createRuntimeShaderEffect(rim, "bars"))
    }

    override fun onDraw(canvas: Canvas) {
        if (!running || width == 0) return
        strip.advance(AnimationUtils.currentAnimationTimeMillis(), level())
        val moving = ComposerStyle.motionEnabled
        // With animations off, the strip steps a bar at a time and bars arrive at their height.
        val offset = if (moving) strip.travelled else strip.entered.toFloat()
        val origin = width - offset * barStep
        val first = floor(-origin / barStep).toInt()
        val middle = height / 2f
        val radius = barWidth / 2f
        for (index in first until strip.entered) {
            val x = origin + index * barStep
            if (x > width) break
            val resting = index < 0
            paint.alpha = if (resting) RESTING_ALPHA else 255
            val full = if (resting) barWidth else barWidth + strip.height(index) * (maxHeight - barWidth)
            val tall = if (moving && !resting) barWidth + (full - barWidth) * strip.growth(index) else full
            bar.set(x, middle - tall / 2f, x + barWidth, middle + tall / 2f)
            canvas.drawRoundRect(bar, radius, radius, paint)
        }
        if (!running) return
        if (moving) postInvalidateOnAnimation() else postInvalidateDelayed(DictationStrip.INTERVAL_MS)
    }

    private companion object {
        const val BAR_WIDTH_DP = 2.5f
        const val BAR_STEP_DP = 5.5f
        const val MAX_HEIGHT_DP = 26f
        /** The opacity of the bars the row starts with, as 0..255. Bars that enter later are opaque. */
        const val RESTING_ALPHA = 102
        const val BAND_SHARE = 0.3f
        const val DEPTH_SHARE = 0.375f
        const val DISPERSION = 0.04f
        const val SOFTNESS_DP = 3.5f

        /**
         * The waveform, bent per pixel. In a band along the capsule's outline each point shows what lies further in
         * along the outline's normal, reaching furthest at the outline and folding back on itself across the band. So
         * bars near a round end wrap into a crescent that follows its curve, and the bar crossing the fold swells
         * into a ring. Only the round ends bend, as the straight edges would show the bars' ends as a row of dots.
         * Red reaches a little further than green and blue a little less, which splits the bent bars' edges into
         * colour along the outline.
         */
        const val RIM_SHADER = """
            uniform shader bars;
            uniform float2 size;
            uniform float band;       // How far in from the outline the rim bends what it shows.
            uniform float depth;      // How far inward the outline itself shows: the most the band reaches.
            uniform float dispersion; // How much further red reaches than green, and blue less, as a share of the reach.
            uniform float softness;   // How far the rim blurs what it bends, at the outline.
            layout(color) uniform half4 ink;
            layout(color) uniform half4 backdrop;

            // How much of the point a bar covers, blurred over [spread] so bent bars run together into one arc.
            float coverage(float2 point, float spread) {
                float sum = bars.eval(point).a * 2;
                sum += bars.eval(point + float2(spread, 0)).a;
                sum += bars.eval(point - float2(spread, 0)).a;
                sum += bars.eval(point + float2(0, spread)).a;
                sum += bars.eval(point - float2(0, spread)).a;
                return sum / 6;
            }

            half4 main(float2 point) {
                float radius = size.y * 0.5;
                float2 spine = float2(clamp(point.x, radius, size.x - radius), radius);
                float2 away = point - spine;
                float reach = length(away);
                float2 inward = reach > 0.001 ? -away / reach : float2(0);
                // How deep into the band, 1 at the outline; and how much the outline faces left or right.
                float t = saturate(1 - (radius - reach) / band);
                float bend = t * t * smoothstep(0.0, 0.3, abs(inward.x));
                // Flat glass neither bends nor splits.
                if (bend <= 0) return bars.eval(point);
                float spread = softness * bend;
                float shift = depth * bend;
                float3 cover = float3(
                    coverage(point + inward * shift * (1 + dispersion), spread),
                    coverage(point + inward * shift, spread),
                    coverage(point + inward * shift * (1 - dispersion), spread));
                // Through the band the bars are a little fainter.
                cover *= mix(1.0, 0.7, bend);
                float alpha = max(cover.r, max(cover.g, cover.b));
                // A colour a bar covers less shows more of the surface behind it: that is the fringe.
                float3 rgb = ink.rgb * cover + backdrop.rgb * (alpha - cover);
                return half4(half3(rgb), half(alpha));
            }
        """
    }
}

/**
 * The waveform's bars and clock, apart from drawing. A bar enters every [INTERVAL_MS] with the highest level heard
 * since the one before.
 *
 * Bounds: at most [SLOTS] bars kept, more than any screen shows.
 */
internal class DictationStrip {
    private val heights = FloatArray(SLOTS)
    private var start = -1L
    private var last = 0L
    private var now = 0L
    private var peak = 0f

    /** The bars that have entered since the start. */
    var entered = 0
        private set

    /** How many bars' widths the strip has moved. */
    val travelled: Float get() = (now - start) / INTERVAL_MS.toFloat()

    fun reset() {
        start = -1
        entered = 0
        peak = 0f
        heights.fill(0f)
    }

    /** Takes a frame at [time], in milliseconds, with the microphone at [level]. */
    fun advance(time: Long, level: Float) {
        if (start < 0) {
            start = time
            last = time
        }
        // A stalled main thread skips frames: the strip resumes where it stopped instead of jumping ahead.
        if (time - last > STALL_MS) start += time - last - FRAME_MS
        last = time
        now = time
        peak = max(peak, level)
        while ((entered + 1) * INTERVAL_MS <= now - start) {
            heights[entered % SLOTS] = min(1f, peak)
            entered++
            peak = 0f
        }
    }

    /** Bar [index]'s level, 0..1. */
    fun height(index: Int): Float = heights[index % SLOTS]

    /** How far bar [index] has grown from a dot to its level, 0..1. */
    fun growth(index: Int): Float {
        val age = ((now - start - (index + 1) * INTERVAL_MS) / GROW_MS.toFloat()).coerceIn(0f, 1f)
        return age * age * (3f - 2f * age)
    }

    companion object {
        const val INTERVAL_MS = 110L
        private const val GROW_MS = 700L
        private const val STALL_MS = 100L
        private const val FRAME_MS = 16L
        private const val SLOTS = 256
    }
}
