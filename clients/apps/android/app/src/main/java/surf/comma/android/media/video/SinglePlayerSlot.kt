package surf.comma.android.media.video

import androidx.annotation.MainThread
import androidx.media3.exoplayer.ExoPlayer

/**
 * At most one player exists at a time. A new owner acquiring the slot releases the previous
 * owner's player first and tells that owner, which must stop using it. Main thread only.
 */
class SinglePlayerSlot<P : Any>(private val dispose: (P) -> Unit) {
    private var owner: Any? = null
    private var player: P? = null
    private var revoked: (() -> Unit)? = null

    val active: Boolean @MainThread get() = player != null

    @MainThread
    fun acquire(owner: Any, create: () -> P, onRevoked: () -> Unit = {}): P {
        if (this.owner === owner) player?.let { return it }
        releaseCurrent(notify = true)
        return create().also {
            this.owner = owner
            player = it
            revoked = onRevoked
        }
    }

    /** No-op unless [owner] still holds the slot. */
    @MainThread
    fun release(owner: Any) {
        if (this.owner === owner) releaseCurrent(notify = false)
    }

    private fun releaseCurrent(notify: Boolean) {
        val previous = player ?: return
        val callback = revoked
        player = null
        owner = null
        revoked = null
        dispose(previous)
        if (notify) callback?.invoke()
    }
}

/** The process's only video player. */
object VideoPlayers {
    val slot = SinglePlayerSlot<ExoPlayer> { it.release() }
}
