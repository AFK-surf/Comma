package surf.comma.android.voice

/** Frame accounting for one AudioTrack between flushes. Accessed under the player's monitor. */
internal class PlaybackClock {
    var queuedFrames = 0L
        private set
    var writtenFrames = 0L
        private set
    var playedFrames = 0L
        private set
    private var lastHead = 0L
    private var wraps = 0L

    fun enqueue(bytes: Int) { require(bytes >= 0 && bytes % 2 == 0); queuedFrames += bytes / 2 }
    fun written(bytes: Int) {
        require(bytes >= 0 && bytes % 2 == 0)
        writtenFrames += bytes / 2
        check(writtenFrames <= queuedFrames)
    }

    fun update(headPosition: Int) {
        val head = headPosition.toLong() and 0xffff_ffffL
        if (head < lastHead) wraps += 1L shl 32
        lastHead = head
        playedFrames = minOf(writtenFrames, wraps + head)
    }

    fun reached(frame: Long): Boolean = frame <= playedFrames
    fun reset() {
        queuedFrames = 0; writtenFrames = 0; playedFrames = 0; lastHead = 0; wraps = 0
    }
}
