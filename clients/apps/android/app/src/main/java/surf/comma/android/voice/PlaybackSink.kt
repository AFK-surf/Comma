package surf.comma.android.voice

/**
 * Ordered, nonblocking playback queue. Calls are serialized by VoiceSession.
 * Audio is 24 kHz mono signed PCM16 little-endian. Do not mutate the supplied bytes.
 * Invoke onPlayed only once playback has consumed all audio preceding this mark;
 * it may be invoked from any thread. Each callback identifies this exact mark,
 * even if the server reuses a name. Clear must synchronously discard queued audio.
 * VoiceSession acknowledges all pending marks on clear, so discarded callbacks
 * may be omitted (late callbacks are harmless). Hardware ownership is external.
 */
interface PlaybackSink {
    fun audio(pcm: ByteArray)
    fun mark(name: String, onPlayed: () -> Unit)
    fun clear()
}
