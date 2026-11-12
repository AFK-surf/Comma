package surf.comma.android.media

import java.io.ByteArrayOutputStream
import java.io.IOException

/**
 * Joins still WebP frames (as Android's Bitmap.compress writes them) into one animated WebP that loops. Android
 * encodes a still WebP but has no animated encoder, and libwebp built for the app would add a native library for this
 * alone; only the container of the WebP RIFF format is written here
 * (https://developers.google.com/speed/webp/docs/riff_container). Each frame is whole, drawn over nothing.
 */
internal object AnimatedWebP {
    class Frame(val webp: ByteArray, val durationMs: Int)

    fun of(frames: List<Frame>, side: Int): ByteArray {
        val pictures = frames.map { bitstream(it.webp) }
        val alpha = pictures.any { chunks -> chunks.any { it.first == "ALPH" || it.first == "VP8L" } }
        val body = ByteArrayOutputStream()
        body.chunk("VP8X", byteArrayOf((if (alpha) 0x12 else 0x02).toByte(), 0, 0, 0) + u24(side - 1) + u24(side - 1))
        // Clear background, loop for ever.
        body.chunk("ANIM", ByteArray(6))
        frames.forEachIndexed { index, frame ->
            val anmf = ByteArrayOutputStream()
            anmf.write(u24(0) + u24(0) + u24(side - 1) + u24(side - 1) + u24(frame.durationMs.coerceIn(0, 0xFFFFFF)))
            anmf.write(0x02) // replace the canvas, do not blend; keep it after
            pictures[index].forEach { (fourcc, payload) -> anmf.chunk(fourcc, payload) }
            body.chunk("ANMF", anmf.toByteArray())
        }
        val content = body.toByteArray()
        return "RIFF".toByteArray(Charsets.US_ASCII) + u32(4 + content.size) + "WEBP".toByteArray(Charsets.US_ASCII) + content
    }

    /** Whether [bytes] is a WebP that moves (its VP8X chunk says so). */
    fun isAnimated(bytes: ByteArray) = bytes.size >= 21 && text(bytes, 0) == "RIFF" && text(bytes, 8) == "WEBP" &&
        text(bytes, 12) == "VP8X" && bytes[20].toInt() and 0x02 != 0

    /** The chunks of a still WebP that carry its picture: ALPH and VP8, or VP8L. */
    private fun bitstream(webp: ByteArray): List<Pair<String, ByteArray>> {
        if (webp.size < 12 || text(webp, 0) != "RIFF" || text(webp, 8) != "WEBP") throw IOException("Not a WebP image")
        val chunks = mutableListOf<Pair<String, ByteArray>>()
        var at = 12
        while (at + 8 <= webp.size) {
            val fourcc = text(webp, at)
            val size = (webp[at + 4].toInt() and 0xFF) or ((webp[at + 5].toInt() and 0xFF) shl 8) or
                ((webp[at + 6].toInt() and 0xFF) shl 16) or ((webp[at + 7].toInt() and 0xFF) shl 24)
            if (size < 0 || at + 8 + size > webp.size) throw IOException("Broken WebP image")
            if (fourcc == "ALPH" || fourcc == "VP8 " || fourcc == "VP8L") chunks += fourcc to webp.copyOfRange(at + 8, at + 8 + size)
            at += 8 + size + (size and 1)
        }
        if (chunks.none { it.first != "ALPH" }) throw IOException("WebP has no picture")
        return chunks
    }

    private fun ByteArrayOutputStream.chunk(fourcc: String, payload: ByteArray) {
        write(fourcc.toByteArray(Charsets.US_ASCII))
        write(u32(payload.size))
        write(payload)
        if (payload.size and 1 != 0) write(0)
    }

    private fun u24(value: Int) = byteArrayOf(value.toByte(), (value shr 8).toByte(), (value shr 16).toByte())
    private fun u32(value: Int) = u24(value) + byteArrayOf((value ushr 24).toByte())
    private fun text(bytes: ByteArray, at: Int) = String(bytes, at, 4, Charsets.US_ASCII)
}
