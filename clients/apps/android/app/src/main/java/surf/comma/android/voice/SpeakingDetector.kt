package surf.comma.android.voice

/**
 * Whether Comma is audibly speaking, from the player's hardware playback position: true while
 * the played-frame count has advanced within the last [windowMillis]. Queued or written audio does
 * not count, only frames the device reports as played. A flush (a new epoch, e.g. when the user
 * interrupts) restarts the count, so the cleared audio never reads as speech.
 */
internal class SpeakingDetector(private val windowMillis: Long) {
    private var epoch = Long.MIN_VALUE
    private var played = 0L
    private var advancedAt: Long? = null

    fun sample(epoch: Long, played: Long, nowMillis: Long): Boolean {
        if (epoch != this.epoch) {
            this.epoch = epoch
            this.played = 0L
        }
        if (played > this.played) advancedAt = nowMillis
        this.played = played
        return advancedAt?.let { nowMillis - it <= windowMillis } ?: false
    }

    companion object {
        const val WINDOW_MILLIS = 300L
        /** Three samples per window, so a gap shorter than the window never flickers the ring. */
        const val SAMPLE_MILLIS = 100L
    }
}
