package surf.comma.android.voice

import android.content.Context
import android.media.MediaPlayer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import surf.comma.android.R
import surf.comma.android.platform.logging.AppLog

/** Commands are serialized on Main; the MediaPlayer never shares a thread with the PCM writer. */
class Ringback(context: Context, onToneStarted: () -> Unit = {}, onStopped: () -> Unit = {}) : AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val gate = RingbackGate()
    private var loggedFailure = false
    private val loop = RingbackLoop(scope, {
        AndroidRingbackTone.create(context.applicationContext, onToneStarted, onStopped)
    }, {
        if (!loggedFailure) {
            loggedFailure = true
            AppLog.warn("Ringback", "Call ringing playback failed")
        }
    })

    fun update(state: CallState) { scope.launch { if (gate.update(state)) loop.start() else loop.stop() } }
    fun playbackStarted(generation: Long) { scope.launch { if (gate.playbackStarted(generation)) loop.stop() } }
    override fun close() { scope.cancel() }
}

private class AndroidRingbackTone(
    private val player: MediaPlayer,
    private val failure: CompletableDeferred<Unit>,
    private val onStarted: () -> Unit,
    private val onStopped: () -> Unit,
) : RingbackTone {
    override suspend fun playOnce() {
        player.start()
        onStarted()
        // Measured asset duration, followed by the loop's separate three-second silent gap.
        withTimeoutOrNull(player.duration.toLong().coerceAtLeast(1)) { failure.await() }
    }
    override fun close() { player.release(); onStopped() }

    companion object {
        suspend fun create(context: Context, onStarted: () -> Unit, onStopped: () -> Unit): AndroidRingbackTone {
            val player = MediaPlayer()
            val prepared = CompletableDeferred<Unit>()
            val failure = CompletableDeferred<Unit>()
            try {
                player.setAudioAttributes(callAudioAttributes())
                player.setOnPreparedListener { prepared.complete(Unit) }
                player.setOnErrorListener { _, _, _ ->
                    val error = IllegalStateException("Call ringing playback failed")
                    prepared.completeExceptionally(error)
                    failure.completeExceptionally(error)
                    true
                }
                context.resources.openRawResourceFd(R.raw.ringback).use {
                    player.setDataSource(it.fileDescriptor, it.startOffset, it.length)
                }
                player.prepareAsync()
                prepared.await()
                return AndroidRingbackTone(player, failure, onStarted, onStopped)
            } catch (error: Exception) { player.release(); throw error }
        }
    }
}
