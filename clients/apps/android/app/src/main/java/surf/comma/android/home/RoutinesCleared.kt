package surf.comma.android.home

import android.animation.ValueAnimator
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.view.Gravity
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.dpf
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

/**
 * The Routines with every card cleared: a mark and one line, which stay until a refresh brings new cards. [pop]
 * brings the mark in from half its size as the confetti is thrown ([RoutineConfettiView]).
 */
internal class RoutinesClearedView(context: Context) : LinearLayout(context) {
    private val mark = ImageView(context).apply {
        setImageResource(R.drawable.ic_routine_cleared)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_tertiary))
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    init {
        id = R.id.routines_cleared
        orientation = VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(0, context.dp(48), 0, context.dp(48))
        addView(mark, LayoutParams(context.dp(24), context.dp(24)))
        addView(context.label(Level.SMALL, R.color.token_text_tertiary, DesignFonts.medium, lines = 0).apply {
            text = context.getString(R.string.routines_cleared)
            gravity = Gravity.CENTER
        }, LayoutParams(-2, -2).apply { topMargin = context.dp(8) })
    }

    /** The mark grows from half its size, never seen at that size: its opacity follows its scale. */
    fun pop() {
        if (!ValueAnimator.areAnimatorsEnabled()) return
        SCALE.setValue(mark, DesignMotion.unseenScale)
        DesignSpring(mark, SCALE, DesignMotion.springScale, DynamicAnimation.MIN_VISIBLE_CHANGE_SCALE).animateTo(1f)
    }

    private companion object {
        /** Both axes at once, with the opacity that goes with the scale. */
        val SCALE = object : FloatPropertyCompat<View>("routinesClearedMark") {
            override fun getValue(view: View) = view.scaleX
            override fun setValue(view: View, value: Float) {
                view.scaleX = value
                view.scaleY = value
                view.alpha = DesignMotion.seenAt(value)
            }
        }
    }
}

/**
 * The cleared Routines' motion, as `motionRoutineCleared` in the desktop's motion tokens: a party popper at each side
 * of the sheet throws paper and ribbons up and across it. A throw spends itself against the air, then the pieces
 * drift down, sway and fade. Distances are in dp, speeds per second, times in seconds.
 */
internal object RoutineClearedMotion {
    /** Pieces each popper throws. */
    const val PIECES = 22
    /** The pieces leave a popper within this long of each other. */
    val delay = 0.0..0.11
    /** A piece's time in the air, from the quickest to the slowest. */
    val flight = 1.8..2.8
    /** Share of its flight a piece stays whole before it fades out. */
    const val FADE_FROM = 0.62
    /** How fast the air spends a throw: the share of its speed lost a second. */
    const val DRAG = 4.2
    /** How far a throw carries, as a share of the sheet's width, and its limit. */
    val reach = 0.5..1.25
    const val REACH_LIMIT = 400.0
    /** The throw's angle above the horizontal, in degrees. */
    val angle = 50.0..84.0
    /** How far under the line the poppers stand, so the throw rises past it. */
    const val DROP = 48.0
    /** How fast a spent piece drifts down. */
    val fall = 70.0..135.0
    /** Side to side sway of a drifting piece: its width and its turns a second. */
    val sway = 3.0..9.0
    val swayRate = 0.6..1.1
    /** Turns a second a piece spins, and a paper flips over. */
    val spin = 0.4..1.4
    val flip = 0.9..1.7
    /** The papers' colours, the label palette's. */
    val tones = intArrayOf(
        R.color.token_label_blue, R.color.token_label_pink, R.color.token_label_warning,
        R.color.token_label_success, R.color.token_label_purple, R.color.token_label_orange,
    )
}

/** One piece a popper throws: what it is, and the flight it was given. */
internal class RoutineConfettiPiece(
    val kind: Kind,
    val tone: Int,
    /** The popper's side: -1 throws from the start edge, 1 from the end one. */
    val side: Double,
    val delay: Double, val flight: Double, val reach: Double, val angle: Double, val fall: Double,
    val sway: Double, val swayRate: Double, val swayAt: Double, val turn: Double, val spin: Double,
    val flip: Double, val flipAt: Double,
) {
    enum class Kind { PAPER, DOT, RIBBON }

    /** Where the piece is at a moment of its flight: its centre, its turn in degrees, its flip and its opacity. */
    class Pose(val x: Float, val y: Float, val rotation: Float, val flip: Float, val opacity: Float)

    /**
     * Where the piece is [seconds] into its flight across a stage [width] wide, from a popper at [originY] on its
     * side's edge: the throw loses its speed to the air (an exponential), and from then on the piece drifts down and
     * sways. Null before it leaves the popper and once its flight has ended. Lengths are in the stage's own unit,
     * [density] of them to a dp.
     */
    fun pose(seconds: Double, width: Double, originY: Double, density: Double): Pose? {
        if (seconds < 0 || seconds > flight) return null
        val turns = 2 * Math.PI
        val carry = min(reach * width, RoutineClearedMotion.REACH_LIMIT * density)
        val climb = Math.toRadians(angle)
        val spent = 1 - exp(-RoutineClearedMotion.DRAG * seconds)
        val x = (if (side < 0) 0.0 else width) - side * cos(climb) * carry * spent +
            sway * density * spent * sin(turns * (swayRate * seconds + swayAt))
        val y = originY - sin(climb) * carry * spent + fall * density * seconds
        val progress = seconds / flight
        val fade = RoutineClearedMotion.FADE_FROM
        return Pose(
            x.toFloat(), y.toFloat(), (360 * (turn + spin * seconds)).toFloat(),
            if (flip == 0.0) 1f else cos(turns * (flip * seconds + flipAt)).toFloat(),
            if (progress <= fade) 1f else ((1 - progress) / (1 - fade)).toFloat(),
        )
    }

    companion object {
        /**
         * What the two poppers throw: paper mostly, with dots and ribbons among it. The same draws every time, so
         * every burst is the same throw.
         */
        val burst: List<RoutineConfettiPiece> by lazy {
            val draws = SeededDraws(RoutineClearedMotion.PIECES.toLong())
            fun within(range: ClosedFloatingPointRange<Double>) = range.start + (range.endInclusive - range.start) * draws.next()
            listOf(-1.0, 1.0).flatMapIndexed { popper, side ->
                List(RoutineClearedMotion.PIECES) { index ->
                    val kind = when (index % 4) { 3 -> Kind.RIBBON; 1 -> Kind.DOT; else -> Kind.PAPER }
                    RoutineConfettiPiece(
                        kind = kind, tone = (index + popper) % RoutineClearedMotion.tones.size, side = side,
                        delay = within(RoutineClearedMotion.delay), flight = within(RoutineClearedMotion.flight),
                        reach = within(RoutineClearedMotion.reach), angle = within(RoutineClearedMotion.angle),
                        fall = within(RoutineClearedMotion.fall), sway = within(RoutineClearedMotion.sway),
                        swayRate = within(RoutineClearedMotion.swayRate), swayAt = draws.next(), turn = draws.next(),
                        spin = within(RoutineClearedMotion.spin) * (if (draws.next() < 0.5) -1 else 1),
                        flip = if (kind == Kind.PAPER) within(RoutineClearedMotion.flip) else 0.0, flipAt = draws.next(),
                    )
                }
            }
        }

        /** The longest any piece is in the air, from the burst's start, in seconds. */
        val duration: Double by lazy { burst.maxOf { it.delay + it.flight } }
    }
}

/** Draws from a seed (SplitMix64), each between 0 and 1. */
private class SeededDraws(private var state: Long) {
    fun next(): Double {
        state += -0x61c8864680b583ebL
        var mixed = state
        mixed = (mixed xor (mixed ushr 30)) * -0x40a7b892e31b1a47L
        mixed = (mixed xor (mixed ushr 27)) * -0x6b2fb644ecceee15L
        return ((mixed xor (mixed ushr 31)) ushr 11).toDouble() / (1L shl 53).toDouble()
    }
}

/**
 * The burst over the cleared Routines: every piece of [RoutineConfettiPiece.burst], drawn each frame until the last
 * has faded. It takes no touch and is nothing to a screen reader. With animations removed in the system, nothing is
 * thrown.
 */
internal class RoutineConfettiView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density.toDouble()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeWidth = context.dpf(2.5f)
    }
    private val tones = RoutineClearedMotion.tones.map(context::getColor)
    private val paperWidth = context.dpf(6f)
    private val paperHeight = context.dpf(12f)
    private val paperRadius = context.dpf(2f)
    private val dot = context.dpf(3f)
    /** A curl of ribbon, 32 by 12 dp, about its own middle. */
    private val ribbon = Path().apply {
        val d = context.dpf(1f)
        moveTo(-14 * d, 0f)
        cubicTo(-10.5f * d, -6 * d, -7 * d, -6 * d, -3.5f * d, 0f)
        cubicTo(0f, 6 * d, 3.5f * d, 6 * d, 7 * d, 0f)
        cubicTo(9.3f * d, -4 * d, 11.7f * d, -5.3f * d, 14 * d, -4 * d)
    }
    private var originY = 0.0
    private var elapsed = -1.0
    private var clock: ValueAnimator? = null

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        isClickable = false
    }

    /** Throws the confetti from poppers that stand [RoutineClearedMotion.DROP] under [originY], in this view. */
    fun burst(originY: Float) {
        if (!ValueAnimator.areAnimatorsEnabled()) return
        this.originY = originY + RoutineClearedMotion.DROP * density
        clock?.cancel()
        val seconds = RoutineConfettiPiece.duration.toFloat()
        clock = ValueAnimator.ofFloat(0f, seconds).apply {
            duration = (seconds * 1000).toLong()
            interpolator = LinearInterpolator()
            addUpdateListener { elapsed = (it.animatedValue as Float).toDouble(); invalidate() }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) { elapsed = -1.0; invalidate() }
            })
            start()
        }
    }

    override fun onDetachedFromWindow() {
        clock?.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        if (elapsed < 0) return
        for (piece in RoutineConfettiPiece.burst) {
            val pose = piece.pose(elapsed - piece.delay, width.toDouble(), originY, density) ?: continue
            val color = tones[piece.tone]
            val alpha = (pose.opacity * 255).toInt().coerceIn(0, 255)
            canvas.save()
            canvas.translate(pose.x, pose.y)
            canvas.rotate(pose.rotation)
            canvas.scale(1f, pose.flip)
            when (piece.kind) {
                RoutineConfettiPiece.Kind.PAPER -> {
                    fill.color = color; fill.alpha = alpha
                    canvas.drawRoundRect(-paperWidth / 2, -paperHeight / 2, paperWidth / 2, paperHeight / 2, paperRadius, paperRadius, fill)
                }
                RoutineConfettiPiece.Kind.DOT -> {
                    fill.color = color; fill.alpha = alpha
                    canvas.drawCircle(0f, 0f, dot, fill)
                }
                RoutineConfettiPiece.Kind.RIBBON -> {
                    stroke.color = color; stroke.alpha = alpha
                    canvas.drawPath(ribbon, stroke)
                }
            }
            canvas.restore()
        }
    }
}
