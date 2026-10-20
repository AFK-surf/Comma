package surf.comma.android.ui.theme

import android.animation.ValueAnimator
import android.view.animation.PathInterpolator
import androidx.dynamicanimation.animation.SpringForce

/** Springs for geometry; timings and curves for opacity, color and streaming text. */
object DesignMotion {
    data class SpringToken(val stiffness: Float, val dampingRatio: Float) {
        init {
            require(stiffness.isFinite() && stiffness > 0f)
            require(dampingRatio.isFinite() && dampingRatio >= 0f)
        }

        /** Forces are mutable, so each animation gets its own instance. */
        fun createForce(finalPosition: Float): SpringForce {
            require(finalPosition.isFinite())
            return SpringForce(finalPosition).setStiffness(stiffness).setDampingRatio(dampingRatio)
        }

        /**
         * How far a unit-mass spring released at rest from 0 has moved towards 1 after [seconds],
         * for motion driven by a shared clock rather than a [SpringForce]. May pass 1 when the
         * spring is underdamped; callers do not clamp it.
         */
        fun progressAt(seconds: Float): Float {
            if (seconds <= 0f) return 0f
            val omega = kotlin.math.sqrt(stiffness.toDouble())
            val zeta = dampingRatio.toDouble()
            val t = seconds.toDouble()
            val decay = kotlin.math.exp(-zeta * omega * t)
            val value = when {
                zeta < 1.0 -> {
                    val damped = omega * kotlin.math.sqrt(1 - zeta * zeta)
                    1 - decay * (kotlin.math.cos(damped * t) + zeta * omega / damped * kotlin.math.sin(damped * t))
                }
                zeta == 1.0 -> 1 - decay * (1 + omega * t)
                else -> {
                    val root = omega * kotlin.math.sqrt(zeta * zeta - 1)
                    val fast = -zeta * omega - root
                    val slow = -zeta * omega + root
                    1 - (fast * kotlin.math.exp(slow * t) - slow * kotlin.math.exp(fast * t)) / (fast - slow)
                }
            }
            return value.toFloat()
        }
    }

    val springSpatial = SpringToken(275f, 0.90f)
    val springSize = SpringToken(273f, 0.96f)
    val springWidth = SpringToken(341f, 0.86f)
    val springFlight = SpringToken(204f, 0.99f)
    val springEnter = SpringToken(200f, 0.80f)
    /** The call page folding into its card at the top and back, one progress for every part. */
    val springCall = SpringToken(500f, 0.85f)
    // Provisional values awaiting device tuning.
    val springScale = SpringToken(600f, 0.70f)
    val springRotation = SpringToken(400f, 0.80f)
    val springShake = SpringToken(910f, 0.30f)

    const val feedbackIn = 120L
    const val stateChange = 150L
    const val feedbackOut = 180L
    const val dialogEnter = 250L
    const val dialogExit = 200L
    const val menuEnter = 120L
    const val menuExit = 80L
    const val spatialMove = 200L
    const val revealItem = 100L
    const val revealStagger = 30L

    val smoothOut: PathInterpolator by lazy { PathInterpolator(0.16f, 1f, 0.3f, 1f) }
    val softInOut: PathInterpolator by lazy { PathInterpolator(0.4f, 0f, 0.2f, 1f) }
    val spatialMoveCurve: PathInterpolator by lazy { PathInterpolator(0.77f, 0f, 0.175f, 1f) }
    val drawer: PathInterpolator by lazy { PathInterpolator(0.32f, 0.72f, 0f, 1f) }

    const val pressed = 0.98f
    const val actionPressed = 0.94f

    /** Resolve at animation start so changes to the system animation setting take effect. */
    fun durationMillis(token: Long): Long = if (ValueAnimator.areAnimatorsEnabled()) token else 0L
    fun pressScale(action: Boolean = false): Float = when {
        !ValueAnimator.areAnimatorsEnabled() -> 1f
        action -> actionPressed
        else -> pressed
    }
}
