package surf.comma.android.ui.theme

import android.animation.ValueAnimator
import androidx.annotation.MainThread
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.dynamicanimation.animation.SpringAnimation

/** Keep one controller per target property so retargeting retains the current motion. */
class DesignSpring<T : Any> internal constructor(
    private val target: T,
    private val property: FloatPropertyCompat<T>,
    token: DesignMotion.SpringToken,
    minimumVisibleChange: Float? = null,
    private val animationsEnabled: () -> Boolean,
) {
    constructor(
        target: T,
        property: FloatPropertyCompat<T>,
        token: DesignMotion.SpringToken = DesignMotion.springSpatial,
        minimumVisibleChange: Float? = null,
    ) : this(target, property, token, minimumVisibleChange, ValueAnimator::areAnimatorsEnabled)

    internal val animation = SpringAnimation(target, property).apply {
        spring = token.createForce(property.getValue(target))
        minimumVisibleChange?.let {
            require(it.isFinite() && it > 0f)
            setMinimumVisibleChange(it)
        }
    }

    val isRunning: Boolean get() = animation.isRunning

    /**
     * Velocity is in property units per second (px/s for translation). Omit it on ordinary
     * retargets to preserve velocity; supply it when handing off a gesture, even during motion.
     * Progress is not clamped, allowing spring overshoot.
     */
    @MainThread
    fun animateTo(finalPosition: Float, initialVelocity: Float? = null) {
        require(finalPosition.isFinite())
        require(initialVelocity == null || initialVelocity.isFinite())
        if (!animationsEnabled()) {
            // skipToEnd waits for another frame; accessibility requires an immediate update.
            cancel()
            animation.spring!!.finalPosition = finalPosition
            property.setValue(target, finalPosition)
            return
        }
        initialVelocity?.let(animation::setStartVelocity)
        animation.animateToFinalPosition(finalPosition)
    }

    /**
     * Moves the current value by [delta] and keeps velocity and target. For a value measured
     * against a reference that just jumped: shifting by the jump keeps what is drawn in place.
     */
    @MainThread
    fun shiftBy(delta: Float) {
        require(delta.isFinite())
        if (delta == 0f) return
        val value = property.getValue(target) + delta
        property.setValue(target, value)
        // The integrator keeps its own copy of the value while it runs.
        if (animation.isRunning) animation.setStartValue(value)
    }

    /** Stop at the current value, for example before a gesture or when the view detaches. */
    @MainThread
    fun cancel() {
        animation.cancel()
        animation.setStartVelocity(0f)
    }
}
