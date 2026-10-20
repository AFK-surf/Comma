package surf.comma.android.ui.composer

import kotlin.math.abs

/**
 * The press-and-hold gesture, independent of views and clocks.
 *
 * down → (held for [longPressMs] without moving past [touchSlop]) → recording
 * While recording, sliding up more than [cancelDistance] enters the cancel zone; sliding back
 * leaves it. Release sends unless in the cancel zone. Recording longer than [maxDurationMs] ends
 * by itself, exactly as if the finger had been lifted where it is.
 */
class HoldToTalk(
    private val touchSlop: Float,
    private val cancelDistance: Float,
    val longPressMs: Long = 400L,
    val maxDurationMs: Long = 60_000L,
) {
    enum class Phase { IDLE, ARMED, RECORDING }

    sealed interface Event {
        data object None : Event
        data object Start : Event
        data class ZoneChanged(val inCancelZone: Boolean) : Event
        /** Recording ended. [autoEnded] is true when the time limit ended it. */
        data class End(val cancelled: Boolean, val autoEnded: Boolean = false) : Event
        /** Finger lifted or moved away before the hold started: a normal tap or scroll. */
        data class Abandoned(val wasTap: Boolean) : Event
    }

    var phase: Phase = Phase.IDLE
        private set
    var inCancelZone: Boolean = false
        private set
    private var downY = 0f
    private var downAt = 0L
    private var recordingSince = 0L

    fun down(y: Float, now: Long) {
        phase = Phase.ARMED
        inCancelZone = false
        downY = y
        downAt = now
    }

    fun move(y: Float): Event = when (phase) {
        Phase.ARMED -> if (abs(y - downY) > touchSlop) {
            phase = Phase.IDLE
            Event.Abandoned(wasTap = false)
        } else {
            Event.None
        }
        Phase.RECORDING -> {
            val zone = downY - y > cancelDistance
            if (zone != inCancelZone) {
                inCancelZone = zone
                Event.ZoneChanged(zone)
            } else {
                Event.None
            }
        }
        Phase.IDLE -> Event.None
    }

    /** The long-press timer fired. Returns [Event.Start] when the hold should begin recording. */
    fun longPressElapsed(now: Long): Event {
        if (phase != Phase.ARMED || now - downAt < longPressMs) return Event.None
        phase = Phase.RECORDING
        recordingSince = now
        return Event.Start
    }

    fun up(): Event = release(cancelled = false)

    /** The system took the gesture away (ACTION_CANCEL): never send in that case. */
    fun cancel(): Event = release(cancelled = true)

    /** Periodic check while recording. */
    fun tick(now: Long): Event {
        if (phase != Phase.RECORDING || now - recordingSince < maxDurationMs) return Event.None
        phase = Phase.IDLE
        return Event.End(cancelled = inCancelZone, autoEnded = true)
    }

    fun remainingMs(now: Long): Long =
        if (phase == Phase.RECORDING) (maxDurationMs - (now - recordingSince)).coerceAtLeast(0) else 0

    private fun release(cancelled: Boolean): Event {
        val previous = phase
        phase = Phase.IDLE
        return when (previous) {
            Phase.ARMED -> Event.Abandoned(wasTap = !cancelled)
            Phase.RECORDING -> Event.End(cancelled = cancelled || inCancelZone)
            Phase.IDLE -> Event.None
        }
    }
}
