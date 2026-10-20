package surf.comma.android.voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class CallControllerState(
    /** Process-local call identity, distinct from the transport's credential retry generation. */
    val id: Long = 0,
    val call: CallState = CallState(),
    val busy: Boolean = false,
    val muted: Boolean = false,
    val outputs: List<CallAudioOutput> = emptyList(),
    val selected: CallAudioOutput? = null,
    /** SystemClock.elapsedRealtime(), set once at Connected; survives UI recreation. */
    val connectedAtElapsedRealtime: Long? = null,
    val notice: String? = null,
    /** Comma's audio has been playing on the device within the last 300 ms. */
    val agentSpeaking: Boolean = false,
    /** SystemClock.elapsedRealtime() when the call finished; with [connectedAtElapsedRealtime], its length. */
    val endedAtElapsedRealtime: Long? = null,
)

/** UI entry point. Holds observable values and commands only; all call resources live in the service. */
class CallController private constructor(private val app: Context) {
    private val lock = Any()
    private val guard = CallSingleFlight(SystemClock.elapsedRealtimeNanos())
    private val prefs = app.getSharedPreferences("voice_call_lifecycle", Context.MODE_PRIVATE)
    private val mutableState = MutableStateFlow(recover())
    val state = mutableState.asStateFlow()
    private var commands: ((Command) -> Unit)? = null
    private val pending = mutableListOf<Command>()

    /** Invoke from a visible Activity after requesting RECORD_AUDIO. Repeated starts return this call. */
    fun start(): CallControllerState = synchronized(lock) {
        if (state.value.busy) return@synchronized state.value
        if (!hasMicrophonePermission(app)) {
            mutableState.value = CallControllerState(call = CallState(phase = CallPhase.Failed,
                result = CallResult.Interrupted), notice = MICROPHONE_ACCESS_MESSAGE)
            return@synchronized state.value
        }
        val claim = guard.acquire()
        if (!claim.created) return@synchronized state.value
        pending.clear()
        commands = null
        mutableState.value = CallControllerState(id = claim.id, busy = true,
            call = CallState(phase = CallPhase.Preparing))
        // A permission revocation may kill the process before any listener runs. Never restore a call.
        prefs.edit(commit = true) { putBoolean("in_call", true) }
        try {
            ContextCompat.startForegroundService(app, Intent(app, CallService::class.java)
                .setAction(CallService.ACTION_START).putExtra(CallService.EXTRA_ID, claim.id))
        } catch (_: RuntimeException) {
            finish(claim.id, CallState(phase = CallPhase.Failed, result = CallResult.Interrupted),
                if (!hasMicrophonePermission(app)) MICROPHONE_ACCESS_MESSAGE else "Call interrupted")
        }
        state.value
    }

    fun hangUp() = send(Command.HangUp)
    fun setMuted(muted: Boolean) = send(Command.Mute(muted))
    fun select(output: CallAudioOutput) = send(Command.Select(output))

    private fun send(command: Command) = synchronized(lock) {
        if (!state.value.busy) return@synchronized
        commands?.invoke(command) ?: run { pending.add(command) }
    }

    internal sealed interface Command {
        data object HangUp : Command
        data class Mute(val value: Boolean) : Command
        data class Select(val output: CallAudioOutput) : Command
    }

    internal fun attach(id: Long, handler: (Command) -> Unit): Boolean = synchronized(lock) {
        if (state.value.id != id || !state.value.busy) return false
        commands = handler
        pending.forEach(handler)
        pending.clear()
        true
    }

    internal fun update(id: Long, transform: (CallControllerState) -> CallControllerState) = synchronized(lock) {
        if (state.value.id == id && state.value.busy) mutableState.value = transform(state.value)
    }

    internal fun finish(id: Long, call: CallState, notice: String? = null) = synchronized(lock) {
        if (state.value.id != id || !state.value.busy) return@synchronized
        mutableState.value = state.value.copy(call = call, busy = false, outputs = emptyList(),
            selected = null, notice = notice, agentSpeaking = false,
            endedAtElapsedRealtime = SystemClock.elapsedRealtime())
        commands = null
        pending.clear()
        guard.release(id)
        prefs.edit(commit = true) { putBoolean("in_call", false) }
    }

    internal fun stopIfIdle(id: Long, stop: () -> Unit) = synchronized(lock) {
        if (state.value.id == id && !state.value.busy) stop()
    }

    private fun recover(): CallControllerState {
        if (!prefs.getBoolean("in_call", false)) return CallControllerState()
        prefs.edit(commit = true) { putBoolean("in_call", false) }
        app.getSystemService(NotificationManager::class.java).cancel(CallNotifier.ID)
        return CallControllerState(call = CallState(phase = CallPhase.Failed, result = CallResult.Interrupted),
            notice = if (!hasMicrophonePermission(app)) MICROPHONE_ACCESS_MESSAGE else "Call interrupted")
    }

    companion object {
        /** MainActivity consumes this boolean in the call UI integration. It never starts a call. */
        const val EXTRA_EXPAND_CALL = "surf.comma.android.voice.EXPAND_CALL"
        @SuppressLint("StaticFieldLeak") // Stores the application context only.
        @Volatile private var instance: CallController? = null
        fun get(context: Context): CallController = instance ?: synchronized(this) {
            instance ?: CallController(context.applicationContext).also { instance = it }
        }

        internal fun hasMicrophonePermission(context: Context): Boolean =
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }
}
