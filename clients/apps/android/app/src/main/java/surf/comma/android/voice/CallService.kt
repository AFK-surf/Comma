package surf.comma.android.voice

import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import surf.comma.android.BuildConfig
import surf.comma.android.auth.AuthGraph
import surf.comma.android.platform.logging.AppLog

/** The sole owner of call transport and audio. Activity/task lifetime never owns these resources. */
class CallService : Service() {
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val destroyed = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private lateinit var controller: CallController
    private lateinit var notifier: CallNotifier
    private var active: OwnedCall? = null
    @Volatile private var starting: Job? = null
    private var pendingMute = false
    private var pendingOutput: CallAudioOutput? = null
    private var currentId = 0L
    private var foreground = false
    private val stopTimer = CallStopTimer(work) { id ->
        work.launch { mutex.withLock {
            controller.stopIfIdle(id) {
                event(id, "service_stop")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        } }
    }

    private class OwnedCall(
        val id: Long,
        val audio: CallAudioSession,
        val ringback: Ringback,
        val player: CallPlayer,
        val session: VoiceSession,
        val recorder: CallRecorder,
        val wakeLock: PowerManager.WakeLock,
    ) : AutoCloseable {
        val observers = mutableListOf<Job>()
        override fun close() {
            observers.forEach { it.cancel() }
            session.close()
            ringback.close()
            recorder.close()
            player.close()
            audio.close()
            if (wakeLock.isHeld) wakeLock.release()
        }
    }

    override fun onCreate() {
        super.onCreate()
        controller = CallController.get(this)
        notifier = CallNotifier(this).also { it.createChannel() }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getLongExtra(EXTRA_ID, 0L) ?: 0L
        val snapshot = controller.state.value
        if (intent?.action == ACTION_HANG_UP) {
            if (id == snapshot.id && snapshot.busy) controller.hangUp()
            else if (!snapshot.busy) stopSelf(startId)
            return START_NOT_STICKY
        }
        // Neither null restarts nor an old PendingIntent may revive a dead process's call.
        if (intent?.action != ACTION_START || id != snapshot.id || !snapshot.busy) {
            if (!snapshot.busy) stopSelf(startId)
            return START_NOT_STICKY
        }
        currentId = id
        if (!CallController.hasMicrophonePermission(this)) {
            startupFailed(id, MICROPHONE_ACCESS_MESSAGE)
            return START_NOT_STICKY
        }
        try {
            startForeground(CallNotifier.ID, notifier.build(snapshot), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            foreground = true
        } catch (_: RuntimeException) {
            startupFailed(id, if (!CallController.hasMicrophonePermission(this)) MICROPHONE_ACCESS_MESSAGE else "Call interrupted")
            return START_NOT_STICKY
        }
        if (starting == null) {
            starting = work.launch {
                try {
                    // Network-backed credential restoration must not hold the command/teardown lock.
                    AuthGraph.get(this@CallService).start()
                    mutex.withLock { begin(id) }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { mutex.withLock {
                    if (controller.state.value.id == id && controller.state.value.busy) {
                        terminal(id, CallState(phase = CallPhase.Failed, result = CallResult.Interrupted), null)
                    }
                } }
            }
            controller.attach(id) { command -> work.launch { mutex.withLock { command(id, command) } } }
        }
        return START_NOT_STICKY
    }

    /** Stop in this callback if foreground promotion fails, before Android's startup watchdog. */
    private fun startupFailed(id: Long, message: String) {
        controller.finish(id, CallState(phase = CallPhase.Failed, result = CallResult.Interrupted), message)
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun begin(id: Long) {
        if (destroyed.get() || active != null || controller.state.value.id != id || !controller.state.value.busy) return
        stopTimer.cancel()
        val audio = CallAudioSession(this)
        val ringback = Ringback(this, { event(id, "ringback_start") }, { event(id, "ringback_stopped") })
        var player: CallPlayer? = null
        var session: VoiceSession? = null
        var recorder: CallRecorder? = null
        var wakeLock: PowerManager.WakeLock? = null
        try {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                throw SecurityException("Microphone permission unavailable")
            }
            val auth = AuthGraph.get(this)
            event(id, "begin")
            audio.start { fail(id, "permanent_focus_loss") }
            player = CallPlayer(onPlaybackStarted = {
                work.launch { mutex.withLock {
                    active?.takeIf { it.id == id }?.let { call ->
                        event(id, "pcm_started")
                        call.ringback.playbackStarted(call.session.state.value.generation)
                    }
                } }
            }, onFailure = { fail(id, "playback_failure") })
            session = VoiceSession(auth.voiceCredentials, player, BuildConfig.VERSION_NAME, scope = work)
            recorder = CallRecorder(session) { fail(id, "recording_failure") }
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "comma:voice-call").apply {
                    setReferenceCounted(false)
                    acquire(WAKE_MILLIS)
                }
            val call = OwnedCall(id, audio, ringback, player, session, recorder, wakeLock)
            active = call
            if (BuildConfig.DEBUG) call.observers += work.launch(start = CoroutineStart.UNDISPATCHED) {
                call.session.diagnostics.collect { value ->
                    event(id, "protocol=${value.kind} code=${value.code} failure=${value.transportFailure} reason=${value.reason}")
                }
            }
            // Permission checked immediately above; the recorder also handles revocation races.
            recorder.start()
            session.start()
            session.setMuted(pendingMute)
            pendingOutput?.let(audio::select)
            ringback.update(session.state.value)
            call.observers += work.launch {
                combine(call.session.state, audio.available, audio.selected) { value, outputs, selected ->
                    Triple(value, outputs, selected)
                }.collect { (value, outputs, selected) -> mutex.withLock {
                    if (active !== call) return@withLock
                    event(id, "phase=${value.phase} result=${value.result} route=$selected")
                    controller.update(id) { old -> old.copy(call = value, outputs = outputs, selected = selected,
                        connectedAtElapsedRealtime = old.connectedAtElapsedRealtime ?:
                            if (value.phase == CallPhase.Connected) SystemClock.elapsedRealtime() else null) }
                    ringback.update(value)
                    if (value.phase in setOf(CallPhase.Ended, CallPhase.Failed)) finish(call, value)
                    else notifier.post(controller.state.value)
                } }
            }
            call.observers += work.launch {
                // Samples the hardware position only; the writer, marks and receipts are untouched.
                val speech = SpeakingDetector(SpeakingDetector.WINDOW_MILLIS)
                while (isActive) {
                    delay(SpeakingDetector.SAMPLE_MILLIS)
                    val progress = call.player.progress()
                    val speaking = speech.sample(progress.epoch, progress.played, SystemClock.elapsedRealtime())
                    if (speaking != controller.state.value.agentSpeaking) {
                        controller.update(id) { it.copy(agentSpeaking = speaking) }
                    }
                }
            }
            call.observers += work.launch {
                var renewedAt = SystemClock.elapsedRealtime()
                while (isActive) {
                    delay(1_000)
                    mutex.withLock {
                        if (active !== call) return@withLock
                        checkPermission()
                        if (active !== call) return@withLock
                        if (SystemClock.elapsedRealtime() - renewedAt >= WAKE_MILLIS / 2) {
                            call.wakeLock.acquire(WAKE_MILLIS)
                            renewedAt = SystemClock.elapsedRealtime()
                        }
                        if (BuildConfig.DEBUG) {
                            val progress = call.player.progress()
                            val receipts = call.session.playbackReceipts()
                            val uplink = call.session.uplink()
                            event(id, "progress epoch=${progress.epoch} queued=${progress.queued} written=${progress.written} played=${progress.played} underruns=${progress.underruns} muted=${controller.state.value.muted} marks_in=${receipts.received} marks_ack=${receipts.acknowledged} marks_pending=${receipts.pending} socket_queued=${receipts.socketQueuedBytes} up_sent=${uplink.sent} up_stalled=${uplink.stalled} mic_dropped=${uplink.droppedMic}")
                        }
                    }
                }
            }
        } catch (_: Exception) {
            val owned = active?.takeIf { it.id == id }
            if (owned != null) owned.close() else {
                session?.close(); ringback.close(); recorder?.close(); player?.close(); audio.close()
                wakeLock?.let { if (it.isHeld) it.release() }
            }
            active = null
            terminal(id, CallState(phase = CallPhase.Failed, result = CallResult.Interrupted),
                if (!CallController.hasMicrophonePermission(this)) MICROPHONE_ACCESS_MESSAGE else null)
        }
    }

    private fun command(id: Long, command: CallController.Command) {
        if (controller.state.value.id != id || !controller.state.value.busy || destroyed.get()) return
        val call = active?.takeIf { it.id == id }
        if (call == null) {
            when (command) {
                CallController.Command.HangUp -> {
                    starting?.cancel()
                    terminal(id, CallState(phase = CallPhase.Ended, result = CallResult.Ended), null)
                }
                is CallController.Command.Mute -> {
                    pendingMute = command.value
                    controller.update(id) { it.copy(muted = command.value) }
                }
                is CallController.Command.Select -> pendingOutput = command.output
            }
            return
        }
        when (command) {
            CallController.Command.HangUp -> {
                event(id, "hang_up")
                call.session.hangUp()
            }
            is CallController.Command.Mute -> {
                call.session.setMuted(command.value)
                controller.update(id) { it.copy(muted = command.value) }
                event(id, "muted=${command.value}")
            }
            is CallController.Command.Select -> {
                if (!call.audio.select(command.output)) controller.update(id) { it.copy(notice = "Could not change audio output.") }
            }
        }
    }

    private fun fail(id: Long, reason: String) { work.launch { mutex.withLock {
        val call = active?.takeIf { it.id == id } ?: return@withLock
        event(id, reason)
        val state = call.session.state.value
        finish(call, if (state.phase in setOf(CallPhase.Ended, CallPhase.Failed)) state
            else state.copy(phase = CallPhase.Failed, result = CallResult.Interrupted),
            if (!CallController.hasMicrophonePermission(this@CallService)) MICROPHONE_ACCESS_MESSAGE else null)
    } } }

    private fun checkPermission() {
        if (CallController.hasMicrophonePermission(this)) return
        active?.let { call -> finish(call,
            call.session.state.value.copy(phase = CallPhase.Failed, result = CallResult.Interrupted), MICROPHONE_ACCESS_MESSAGE) }
    }

    private fun finish(call: OwnedCall, state: CallState, notice: String? = null) {
        if (active !== call) return
        call.session.diagnostics.replayCache.lastOrNull()?.let {
            event(call.id, "terminal_protocol=${it.kind} code=${it.code} failure=${it.transportFailure} reason=${it.reason}")
        }
        // Show the terminal result and start its deadline before potentially slow hardware teardown.
        if (!destroyed.get()) {
            notifier.post(controller.state.value.copy(call = state, notice = notice))
            stopTimer.schedule(call.id, state.phase == CallPhase.Failed)
        }
        call.close()
        active = null
        terminal(call.id, state, notice, published = true)
    }

    private fun terminal(id: Long, state: CallState, notice: String?, published: Boolean = false) {
        starting = null
        pendingMute = false
        pendingOutput = null
        controller.finish(id, state, notice)
        event(id, "released phase=${state.phase} result=${state.result}")
        if (destroyed.get()) return
        if (!published) {
            notifier.post(controller.state.value)
            stopTimer.schedule(id, state.phase == CallPhase.Failed)
        }
        if (notice != null) main.post { Toast.makeText(this, notice, Toast.LENGTH_LONG).show() }
    }

    override fun onDestroy() {
        destroyed.set(true)
        if (foreground) stopForeground(STOP_FOREGROUND_REMOVE)
        work.launch { mutex.withLock {
            starting?.cancel()
            stopTimer.cancel()
            active?.let { call -> finish(call,
                call.session.state.value.copy(phase = CallPhase.Failed, result = CallResult.Interrupted)) }
            controller.finish(currentId, CallState(phase = CallPhase.Failed, result = CallResult.Interrupted))
            work.cancel()
        } }
        super.onDestroy()
    }

    private fun event(id: Long, message: String) {
        if (BuildConfig.DEBUG) AppLog.info("VoiceCallService", "call=$id elapsed_ms=${SystemClock.elapsedRealtime()} $message")
    }

    internal companion object {
        const val ACTION_START = "surf.comma.android.voice.START"
        const val ACTION_HANG_UP = "surf.comma.android.voice.HANG_UP"
        const val EXTRA_ID = "call_id"
        private const val WAKE_MILLIS = 10 * 60_000L
    }
}
