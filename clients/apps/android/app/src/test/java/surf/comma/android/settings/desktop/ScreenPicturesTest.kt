package surf.comma.android.settings.desktop

import org.junit.Assert.assertEquals
import org.junit.Test

// A view's pictures in the order they came (ScreenPictures.kt): the config before the frames it describes, frames that
// wait for a decoder, and a config that changes as the stream goes. The work runs where it is posted.
class ScreenPicturesTest {
    private val said = mutableListOf<String>()
    private var decoders = 0
    private var breakLast: () -> Unit = {}

    private fun pictures() = ScreenPictures<String>(
        post = { it() },
        make = { config, surface, broke ->
            val n = ++decoders
            breakLast = broke
            said += "make $n $config on $surface"
            object : PictureDecoder {
                override fun decode(avcc: ByteArray, ts: Long) {
                    said += "decode $n $ts"
                }
                override fun close() {
                    said += "close $n"
                }
            }
        },
        ack = { said += "ack $it" },
        askKey = { said += "key?" },
    )

    private fun frame(ts: Long) = byteArrayOf(0, 0, 0, 1, ts.toByte())

    @Test
    fun aKeyFrameRightAfterItsConfigIsDecodedByThatConfigsDecoder() {
        val p = pictures()
        p.surface("s1")
        // (made for a config: the station's key frame comes right after it, none is asked)
        p.config("a")
        p.frame(frame(1), 1, key = true)
        p.frame(frame(2), 2, key = false)
        assertEquals(listOf("make 1 a on s1", "decode 1 1", "decode 1 2"), said)
    }

    @Test
    fun framesBeforeASurfaceWaitFromTheLastKeyFrameAndGoInOrder() {
        val p = pictures()
        p.config("a")
        // A frame with no key frame before it is acknowledged: no decoder can use it.
        p.frame(frame(1), 1, key = false)
        p.frame(frame(2), 2, key = true)
        p.frame(frame(3), 3, key = false)
        // A newer key frame: those before it are acknowledged and let go.
        p.frame(frame(4), 4, key = true)
        p.frame(frame(5), 5, key = false)
        p.surface("s1")
        assertEquals(listOf("ack 1", "ack 3", "make 1 a on s1", "decode 1 4", "decode 1 5"), said)
    }

    @Test
    fun aConfigThatChangesMidStreamGetsADecoderOfItsOwnBeforeItsFrames() {
        val p = pictures()
        p.surface("s1")
        p.config("a")
        p.frame(frame(1), 1, key = true)
        said.clear()
        // A turn: the new size's config, then its key frame, which the new decoder takes, never the old.
        p.config("b")
        p.frame(frame(2), 2, key = true)
        p.frame(frame(3), 3, key = false)
        assertEquals(listOf("close 1", "make 2 b on s1", "decode 2 2", "decode 2 3"), said)
    }

    @Test
    fun aDecoderThatBrokeIsMadeAgainAndAsksAKeyFrame() {
        val p = pictures()
        p.surface("s1")
        p.config("a")
        said.clear()
        // Broken: made again, with no key frame of its own.
        breakLast()
        assertEquals(listOf("close 1", "make 2 a on s1", "key?"), said)
        // A new surface: a decoder on it, the old one closed; none once closed.
        said.clear()
        p.surface("s2")
        p.close()
        p.frame(frame(9), 9, key = true)
        assertEquals(listOf("close 2", "make 3 a on s2", "key?", "close 3"), said)
    }
}
