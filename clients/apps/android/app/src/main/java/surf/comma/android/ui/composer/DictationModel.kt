package surf.comma.android.ui.composer

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import surf.comma.android.R
import kotlin.math.log10

internal enum class DictationPhase { IDLE, RECORDING, TRANSCRIBING }

/** Why a dictation ended with no words. Each is a toast; the draft stays as it was. */
internal enum class DictationFailure {
    MICROPHONE_DENIED, MICROPHONE_UNAVAILABLE, VOICE_CALL, NOTHING_RECORDED, NO_SPEECH, TRANSCRIPTION_FAILED,
}

/** What the composer's toast says of this failure. */
internal val DictationFailure.message: Int
    get() = when (this) {
        DictationFailure.MICROPHONE_DENIED -> R.string.composer_dictation_denied
        DictationFailure.MICROPHONE_UNAVAILABLE -> R.string.composer_dictation_unavailable
        DictationFailure.VOICE_CALL -> R.string.composer_dictation_in_call
        DictationFailure.NOTHING_RECORDED -> R.string.composer_dictation_nothing
        DictationFailure.NO_SPEECH -> R.string.composer_dictation_no_speech
        DictationFailure.TRANSCRIPTION_FAILED -> R.string.composer_dictation_failed
    }

/** The microphone did not start, and which [failure] says why. */
internal class DictationRefused(val failure: DictationFailure) : Exception()

/** The recording under way. Exactly one of [stop] and [discard] ends it. */
internal interface DictationCapture {
    /** The microphone's level now, 0..1. Reading it costs nothing. */
    val level: Float

    /** Ends the recording and answers its bytes, or null when nothing was recorded. */
    suspend fun stop(): ByteArray?

    /** Ends the recording and deletes it, without waiting. */
    fun discard()
}

internal interface DictationMicrophone {
    /**
     * Starts a recording, off the main thread and after any earlier one has ended, or throws [DictationRefused].
     * [ended] runs when it ends by itself: the system took the microphone.
     */
    suspend fun start(ended: () -> Unit): DictationCapture
}

/**
 * The composer's microphone: it records what the member says and has the server's ASR write it out. The words go to
 * [start]'s `insert`; a failure goes to [failed] and leaves the draft as it was.
 *
 * Bounds: one recording at a time, at most [MAX_RECORDING_MS] long (it stops and transcribes then), and one
 * transcription in flight. The core gives a dictation up after 10 s, so the recording stays short.
 *
 * Main thread only.
 */
internal class DictationModel(
    private val scope: CoroutineScope,
    private val microphone: DictationMicrophone,
    private val allowed: suspend () -> Boolean,
    private val transcribe: suspend (ByteArray) -> String,
    private val failed: (DictationFailure) -> Unit,
    private val phaseChanged: (DictationPhase) -> Unit,
) {
    var phase = DictationPhase.IDLE
        private set
    private var capture: DictationCapture? = null
    private var work: Job? = null
    /** Where the words go. */
    private var insert: ((String) -> Unit)? = null
    /** Which recording an `ended` belongs to; a later one's is not this one's. */
    private var attempts = 0

    val busy: Boolean get() = phase != DictationPhase.IDLE
    /** The recorder is running. While the permission is asked for or the microphone starts, the phase is RECORDING. */
    val capturing: Boolean get() = capture != null
    /** The permission prompt is up: the finger on the button has left for it, and its lift says nothing. */
    var asking = false
        private set
    /** The microphone's level now, 0..1; 0 when not recording. */
    val level: Float get() = capture?.level ?: 0f

    /** The microphone button: starts a recording, or ends one and transcribes it into [insert]. */
    fun toggle(insert: (String) -> Unit) {
        when (phase) {
            DictationPhase.IDLE -> start(insert)
            DictationPhase.RECORDING -> finish()
            DictationPhase.TRANSCRIBING -> Unit
        }
    }

    /** The member cancelled, or the composer went to another conversation or away: no words will arrive. */
    fun cancel() {
        work?.cancel()
        settle()
    }

    /** The app went to the background, where it may not record: transcribe what there is. */
    fun leftApp() {
        if (phase != DictationPhase.RECORDING) return
        if (capturing) finish() else cancel()
    }

    private fun start(insert: (String) -> Unit) {
        this.insert = insert
        val attempt = ++attempts
        set(DictationPhase.RECORDING)
        work = scope.launch {
            asking = true
            val granted = allowed()
            asking = false
            if (!granted) return@launch fail(DictationFailure.MICROPHONE_DENIED)
            // Not cancelled partway: a recording that does start is owned here, and let go below.
            val started = withContext(NonCancellable) {
                runCatching { microphone.start { scope.launch { if (attempt == attempts) finish() } } }
            }
            val recording = started.getOrElse { problem ->
                if (isActive) fail((problem as? DictationRefused)?.failure ?: DictationFailure.MICROPHONE_UNAVAILABLE)
                return@launch
            }
            // Ended or dropped while the microphone started: nothing of it is kept.
            if (!isActive) return@launch recording.discard()
            capture = recording
            delay(MAX_RECORDING_MS)
            finish()
        }
    }

    private fun finish() {
        if (phase != DictationPhase.RECORDING) return
        val recording = capture
        capture = null
        attempts++
        work?.cancel()
        set(DictationPhase.TRANSCRIBING)
        work = scope.launch {
            val audio = withContext(NonCancellable) { recording?.stop() }
            if (!isActive) return@launch
            if (audio == null || audio.isEmpty()) return@launch fail(DictationFailure.NOTHING_RECORDED)
            val words = try {
                transcribe(audio).trim()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                return@launch fail(DictationFailure.TRANSCRIPTION_FAILED)
            }
            if (words.isEmpty()) return@launch fail(DictationFailure.NO_SPEECH)
            insert?.invoke(words)
            settle()
        }
    }

    private fun fail(failure: DictationFailure) {
        settle()
        failed(failure)
    }

    private fun settle() {
        capture?.discard()
        capture = null
        asking = false
        attempts++
        work = null
        insert = null
        set(DictationPhase.IDLE)
    }

    private fun set(next: DictationPhase) {
        if (phase == next) return
        phase = next
        phaseChanged(next)
    }

    companion object {
        const val MAX_RECORDING_MS = 60_000L
    }
}

/**
 * A press on the microphone or the capsule. A tap starts a recording that a later tap ends; holding the press that
 * started it records until the finger lifts. Times are the touches' own, so a stalled main thread does not make a tap
 * read as a hold.
 */
internal class DictationPress(
    private val phase: () -> DictationPhase,
    private val asking: () -> Boolean,
    private val toggle: () -> Unit,
) {
    private var startedAt: Long? = null
    /** This press started the recording, so lifting it after a hold ends it. */
    private var started = false

    fun down(at: Long) {
        if (phase() == DictationPhase.TRANSCRIBING) return
        startedAt = at
        started = phase() == DictationPhase.IDLE
        if (started) toggle()
    }

    fun up(at: Long, cancelled: Boolean) {
        val start = startedAt ?: return
        startedAt = null
        if (started) {
            // A hold that lifts under the permission prompt, or after its start failed, has no recording to end. One
            // that lifts while the microphone starts does: the member has stopped talking.
            if (at - start >= HOLD_MS && phase() == DictationPhase.RECORDING && !asking()) toggle()
        } else if (!cancelled && phase() == DictationPhase.RECORDING) {
            toggle()
        }
        started = false
    }

    private companion object {
        /** A press held at least this long ends the recording when it lifts; a shorter one is a tap. */
        const val HOLD_MS = 350L
    }
}

/** The edit that puts dictated words in a draft: [inserted] replaces [start] until [end], and the caret follows it. */
internal data class DictationEdit(val start: Int, val end: Int, val inserted: String)

/**
 * Dictated [words] replace the selection, or go at the end when the field has no caret. A space keeps them apart from
 * a word they would otherwise run into; text in a script written without spaces (Chinese, Japanese) joins as it is, and
 * so does punctuation that holds on to its neighbour.
 */
internal fun dictationEdit(text: CharSequence, selectionStart: Int, selectionEnd: Int, words: String): DictationEdit {
    val valid = selectionStart in 0..text.length && selectionEnd in 0..text.length
    val start = if (valid) minOf(selectionStart, selectionEnd) else text.length
    val end = if (valid) maxOf(selectionStart, selectionEnd) else text.length
    fun spaced(a: Char?, b: Char?): Boolean {
        if (a == null || b == null || a.isWhitespace() || b.isWhitespace()) return false
        if (a.category in OPENING_PUNCTUATION || b.category in CLOSING_PUNCTUATION || b in TRAILING_MARKS) return false
        return a.spacedScript && b.spacedScript
    }
    val before = if (spaced(text.getOrNull(start - 1), words.firstOrNull())) " " else ""
    val after = if (spaced(words.lastOrNull(), text.getOrNull(end))) " " else ""
    return DictationEdit(start, end, before + words + after)
}

/**
 * A peak amplitude (0..32767, as `MediaRecorder` reports it) as 0..1: the bottom [FLOOR_DB] of the range is silence
 * and reads as nothing.
 */
internal fun dictationLevel(amplitude: Int): Float {
    if (amplitude <= 0) return 0f
    val decibels = 20f * log10(amplitude.coerceAtMost(MAX_AMPLITUDE) / MAX_AMPLITUDE.toFloat())
    return ((decibels - FLOOR_DB) / -FLOOR_DB).coerceIn(0f, 1f)
}

/** Latin and the like, and Korean, which is written with spaces though it comes after [FIRST_CJK]. */
private val Char.spacedScript: Boolean get() = code < FIRST_CJK || code in HANGUL_SYLLABLES

private const val FIRST_CJK = 0x2E80
private val HANGUL_SYLLABLES = 0xAC00..0xD7A3
private val OPENING_PUNCTUATION = setOf(CharCategory.START_PUNCTUATION, CharCategory.INITIAL_QUOTE_PUNCTUATION)
private val CLOSING_PUNCTUATION = setOf(CharCategory.END_PUNCTUATION, CharCategory.FINAL_QUOTE_PUNCTUATION)
private const val TRAILING_MARKS = ".,;:!?…"
private const val MAX_AMPLITUDE = 32767
private const val FLOOR_DB = -50f
