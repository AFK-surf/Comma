package surf.comma.android.settings.desktop

/** What decodes a view's frames once it has a config and a surface (MeshScreen.kt's FrameDecoder). */
internal interface PictureDecoder {
    /** One access unit (AVCC), in order. */
    fun decode(avcc: ByteArray, ts: Long)
    fun close()
}

/**
 * One view's pictures, in the order they came: its configs and frames, and the surface they go to, each handled on
 * one thread ([post]) one after another. A config comes before the frames it describes, so a frame is never decoded
 * with a config that came after it, nor a key frame lost to a decoder not made yet: the frames wait here, from the
 * last key frame on, for a decoder (a config and a surface), and go to it in order once there is one. The station
 * waits for their acknowledgements meanwhile, so few wait; past [HELD_MOST] they are let go, and a key frame asked.
 * A decoder is made anew for each config, for each surface, and once it broke. One made for a config waits for the
 * key frame the station sends right after it; one made for a surface or after it broke, with no frame waiting for it,
 * asks a key frame (a decoder made anew has none).
 */
internal class ScreenPictures<C : Any>(
    private val post: (() -> Unit) -> Unit,
    /** A decoder for a config on a surface; it calls the function it is given once it failed. */
    private val make: (config: C, surface: Any, broke: () -> Unit) -> PictureDecoder,
    private val ack: (Long) -> Unit,
    private val askKey: () -> Unit,
    /** Once closed. */
    private val ended: () -> Unit = {},
) {
    private var config: C? = null
    private var surface: Any? = null
    private var decoder: PictureDecoder? = null
    /** Frames from the last key frame on, while there is no decoder. */
    private val held = ArrayDeque<Pair<ByteArray, Long>>()
    private var closed = false

    /** A config; null: one that cannot be decoded (a key frame is asked, as it may come with another). */
    fun config(next: C?) = post work@{
        if (closed) return@work
        drop()
        config = next
        // What came before belongs to the config before.
        acknowledgeHeld()
        if (next == null) askKey() else remake(asks = false)
    }

    fun frame(avcc: ByteArray, ts: Long, key: Boolean) = post work@{
        if (closed) return@work
        val decoding = decoder
        if (decoding != null) {
            decoding.decode(avcc, ts)
            return@work
        }
        if (key) acknowledgeHeld()
        // A frame with no key frame before it is of no use to the decoder made next: acknowledged, it is let go.
        if (!key && held.isEmpty()) {
            ack(ts)
            return@work
        }
        held.addLast(avcc to ts)
        if (held.size > HELD_MOST) {
            acknowledgeHeld()
            askKey()
        }
    }

    /** The surface the pictures go to (null: none, the page is not shown). */
    fun surface(next: Any?) = post work@{
        if (closed) return@work
        if (next === surface) return@work
        drop()
        surface = next
        remake(asks = true)
    }

    fun close() = post work@{
        if (closed) return@work
        closed = true
        drop()
        held.clear()
        ended()
    }

    /** A decoder for the config and surface there are, fed the frames that waited; with none to feed, a key frame [asks]. */
    private fun remake(asks: Boolean) {
        val config = config ?: return
        val surface = surface ?: return
        lateinit var made: PictureDecoder
        made = make(config, surface) {
            post work@{
                if (decoder !== made || closed) return@work
                drop()
                remake(asks = true)
            }
        }
        decoder = made
        if (held.isEmpty()) {
            if (asks) askKey()
            return
        }
        while (held.isNotEmpty()) {
            val (avcc, ts) = held.removeFirst()
            made.decode(avcc, ts)
        }
    }

    private fun drop() {
        decoder?.close()
        decoder = null
    }

    private fun acknowledgeHeld() {
        held.lastOrNull()?.let { ack(it.second) }
        held.clear()
    }

    companion object {
        /** The most frames that wait for a decoder: two seconds' worth. */
        const val HELD_MOST = 120
    }
}
