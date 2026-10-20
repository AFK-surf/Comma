package surf.comma.android.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import surf.comma.android.platform.logging.AppLog

/** Owns focus, communication mode and routing. Start off the UI thread; close after the audio I/O. */
class CallAudioSession(context: Context) : AutoCloseable {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var started = false
    private var previousMode = AudioManager.MODE_NORMAL
    private var focusRequest: AudioFocusRequest? = null
    private var focusLoss: (() -> Unit)? = null
    private var deviceIds = emptySet<Int>()
    private var manual: CallAudioOutput? = null
    private val mutableAvailable = MutableStateFlow<List<CallAudioOutput>>(emptyList())
    val available = mutableAvailable.asStateFlow()
    private val mutableSelected = MutableStateFlow<CallAudioOutput?>(null)
    val selected = mutableSelected.asStateFlow()

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        AppLog.info(TAG, "Call audio focus change=$change")
        // Do not call the owner while holding our monitor: its teardown may call close().
        val callback = synchronized(this) {
            if (started && change == AudioManager.AUDIOFOCUS_LOSS) focusLoss else null
        }
        callback?.invoke()
    }
    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = refreshDevices()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = refreshDevices()
    }
    // Reporting only; reselecting here would respond to our own route change indefinitely.
    private val routeListener = AudioManager.OnCommunicationDeviceChangedListener {
        synchronized(this) { if (started) emitSelected() }
    }

    @Synchronized
    fun start(onPermanentFocusLoss: () -> Unit) {
        if (started) return
        previousMode = manager.mode
        started = true
        focusLoss = onPermanentFocusLoss
        try {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(callAudioAttributes())
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener(focusListener, handler)
                .build()
            focusRequest = request
            check(manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                "Could not acquire call audio focus"
            }
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            val deadline = SystemClock.uptimeMillis() + 300L
            while (manager.mode != AudioManager.MODE_IN_COMMUNICATION && SystemClock.uptimeMillis() < deadline) {
                Thread.sleep(20)
            }
            check(manager.mode == AudioManager.MODE_IN_COMMUNICATION) { "Call audio mode was rejected" }
            manager.registerAudioDeviceCallback(deviceCallback, handler)
            manager.addOnCommunicationDeviceChangedListener({ handler.post(it) }, routeListener)
            refreshDevices()
        } catch (failure: Exception) {
            close()
            throw failure
        }
    }

    /** A routing request never pauses the recorder or player. Selection reports the actual route. */
    @Synchronized
    fun select(output: CallAudioOutput): Boolean {
        if (!started) return false
        val devices = devices() ?: return false
        val target = CallAudioRoute.preferredType(devices.map { it.type }, output)
            ?.let { type -> devices.first { it.type == type } } ?: return false
        val accepted = applyRoute(target)
        if (accepted) manual = output
        emitSelected()
        return accepted
    }

    @Synchronized
    private fun refreshDevices() {
        if (!started) return
        val devices = devices() ?: return
        val ids = devices.map { it.id }.toSet()
        // A real plug/unplug event returns to automatic selection. Duplicate notifications
        // (including the initial callback) must not undo an explicit choice.
        if (ids != deviceIds) manual = null
        deviceIds = ids
        mutableAvailable.value = CallAudioRoute.available(devices.map { it.type })
        val type = CallAudioRoute.preferredType(devices.map { it.type }, manual)
        devices.firstOrNull { it.type == type }?.let(::applyRoute)
        emitSelected()
    }

    private fun devices(): List<AudioDeviceInfo>? = try { manager.availableCommunicationDevices }
    catch (_: RuntimeException) {
        AppLog.warn(TAG, "Could not enumerate call audio outputs")
        null
    }

    private fun applyRoute(device: AudioDeviceInfo): Boolean {
        val applied = runCatching { manager.setCommunicationDevice(device) }.getOrDefault(false)
        if (!applied) AppLog.warn(TAG, "Call audio output selection was rejected")
        return applied
    }

    private fun emitSelected() {
        mutableSelected.value = runCatching { manager.communicationDevice?.type?.let(CallAudioRoute::output) }.getOrNull()
    }

    @Synchronized
    override fun close() {
        if (!started) return
        started = false
        focusLoss = null
        runCatching { manager.unregisterAudioDeviceCallback(deviceCallback) }
        runCatching { manager.removeOnCommunicationDeviceChangedListener(routeListener) }
        runCatching { manager.clearCommunicationDevice() }
        focusRequest?.let { runCatching { manager.abandonAudioFocusRequest(it) } }
        focusRequest = null
        runCatching { manager.mode = previousMode }
        manual = null
        deviceIds = emptySet()
        mutableAvailable.value = emptyList()
        mutableSelected.value = null
    }

    private companion object { const val TAG = "CallAudio" }
}

internal fun callAudioAttributes(): AudioAttributes = AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
    .build()
