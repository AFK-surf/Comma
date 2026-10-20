package surf.comma.android.voice

/** Optional local observations. No remote text, identifiers, URLs, credentials or audio content. */
data class VoiceDiagnostic(
    val kind: Kind,
    val atNanos: Long = System.nanoTime(),
    val code: Int? = null,
    val transportFailure: TransportFailure? = null,
    /** Only a server end reason from a fixed vocabulary, never free text. */
    val reason: String? = null,
) {
    enum class TransportFailure { Timeout, EndOfStream, Io, Other }
    enum class Kind {
        Started, FirstAudio, OutputClear, ServerError, SessionEnded, SocketClose, TransportFailure, PlaybackRejected,
        // Calls the client itself ends, so a terminal result always names its cause.
        SubprotocolRejected, AudioFormatRejected, InvalidDownlink, MarkOverflow, SendFailed,
    }
}

data class VoicePlaybackReceipts(val received: Long, val acknowledged: Long, val pending: Int, val socketQueuedBytes: Long)

/** Uplink frame counts: sent, skipped while the socket was backed up, and microphone frames dropped before pacing. */
data class VoiceUplinkStats(val sent: Long, val stalled: Long, val droppedMic: Long)
