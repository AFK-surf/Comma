package surf.comma.android.media

import java.io.IOException

/**
 * Reads a GIF frame by frame, each frame whole: composed over the ones before it as the GIF's disposal says, as ARGB
 * pixels of the GIF's full size. Android has no public API that hands out a GIF's frames (ImageDecoder and
 * AnimatedImageDrawable only play it; the deprecated Movie drops frames that have no delay), so this follows the
 * GIF89a specification (https://www.w3.org/Graphics/GIF/spec-gif89a.txt).
 */
internal class GifFrames(private val bytes: ByteArray) {
    val width: Int
    val height: Int
    private val globalColors: IntArray?
    private val start: Int

    init {
        if (bytes.size < 13 || String(bytes, 0, 6, Charsets.US_ASCII).let { it != "GIF87a" && it != "GIF89a" }) {
            throw IOException("Not a GIF")
        }
        width = u16(6)
        height = u16(8)
        if (width <= 0 || height <= 0) throw IOException("GIF has no size")
        val packed = u8(10)
        var at = 13
        globalColors = if (packed and 0x80 != 0) colors(at, 2 shl (packed and 7)).also { at += it.size * 3 } else null
        start = at
    }

    /**
     * Calls [frame] with each frame's pixels (the same array each time, valid during the call) and how long it shows,
     * in ms as the GIF says; stops after [limit] frames.
     */
    fun forEach(limit: Int, frame: (pixels: IntArray, delayMs: Int) -> Unit) {
        val canvas = IntArray(width * height)
        var at = start
        var delay = 0
        var disposal = 0
        var transparent = -1
        var count = 0
        while (at < bytes.size && count < limit) {
            when (u8(at++)) {
                0x21 -> {
                    val label = u8(at++)
                    if (label == 0xF9 && u8(at) >= 4) {
                        val packed = u8(at + 1)
                        disposal = (packed shr 2) and 7
                        delay = u16(at + 2) * 10
                        transparent = if (packed and 1 != 0) u8(at + 4) else -1
                    }
                    at = skipBlocks(at)
                }
                0x2C -> {
                    val left = u16(at)
                    val top = u16(at + 2)
                    val w = u16(at + 4)
                    val h = u16(at + 6)
                    val packed = u8(at + 8)
                    at += 9
                    val palette = if (packed and 0x80 != 0) {
                        colors(at, 2 shl (packed and 7)).also { at += it.size * 3 }
                    } else globalColors ?: throw IOException("GIF frame has no colours")
                    val minCodeSize = u8(at++)
                    val end = skipBlocks(at)
                    val indices = lzw(at, minCodeSize, w * h)
                    at = end
                    val saved = if (disposal == 3) canvas.copyOf() else null
                    draw(canvas, indices, palette, transparent, left, top, w, h, packed and 0x40 != 0)
                    frame(canvas, delay)
                    count++
                    when (disposal) {
                        2 -> clear(canvas, left, top, w, h)
                        3 -> saved!!.copyInto(canvas)
                    }
                    delay = 0
                    disposal = 0
                    transparent = -1
                }
                0x3B -> return
                else -> throw IOException("Broken GIF")
            }
        }
    }

    private fun draw(
        canvas: IntArray, indices: ByteArray, palette: IntArray, transparent: Int,
        left: Int, top: Int, w: Int, h: Int, interlaced: Boolean,
    ) {
        val rows = if (interlaced) interlacedRows(h) else IntArray(h) { it }
        for (row in 0 until h) {
            val y = top + rows[row]
            if (y >= height) continue
            for (column in 0 until w) {
                val x = left + column
                if (x >= width) continue
                val index = indices[row * w + column].toInt() and 0xFF
                if (index == transparent || index >= palette.size) continue
                canvas[y * width + x] = palette[index]
            }
        }
    }

    private fun clear(canvas: IntArray, left: Int, top: Int, w: Int, h: Int) {
        for (y in top until minOf(top + h, height)) {
            canvas.fill(0, y * width + left.coerceAtMost(width), y * width + minOf(left + w, width))
        }
    }

    /** The picture row each stored row of an interlaced frame goes to. */
    private fun interlacedRows(h: Int): IntArray {
        val rows = IntArray(h)
        var stored = 0
        for ((first, step) in listOf(0 to 8, 4 to 8, 2 to 4, 1 to 2)) {
            var y = first
            while (y < h) { rows[stored++] = y; y += step }
        }
        return rows
    }

    /** The colour indices of a frame's LZW data, which starts at [from] in sub-blocks. */
    private fun lzw(from: Int, minCodeSize: Int, pixels: Int): ByteArray {
        if (minCodeSize !in 1..11) throw IOException("Broken GIF")
        val out = ByteArray(pixels)
        val clear = 1 shl minCodeSize
        val prefix = IntArray(4096)
        val suffix = ByteArray(4096)
        val firstOf = ByteArray(4096)
        for (code in 0 until clear) { suffix[code] = code.toByte(); firstOf[code] = code.toByte() }
        val stack = ByteArray(4097)
        var codeSize = minCodeSize + 1
        var next = clear + 2
        var previous = -1
        var written = 0
        var bits = 0
        var bitCount = 0
        var block = from
        var blockEnd = from
        while (written < pixels) {
            while (bitCount < codeSize) {
                if (block >= blockEnd) {
                    val size = if (blockEnd < bytes.size) u8(blockEnd) else 0
                    if (size == 0) return out
                    block = blockEnd + 1
                    blockEnd = block + size
                    if (blockEnd > bytes.size) return out
                }
                bits = bits or (u8(block++) shl bitCount)
                bitCount += 8
            }
            var code = bits and ((1 shl codeSize) - 1)
            bits = bits ushr codeSize
            bitCount -= codeSize
            if (code == clear) {
                codeSize = minCodeSize + 1
                next = clear + 2
                previous = -1
                continue
            }
            if (code == clear + 1) break
            if (previous == -1) {
                if (code >= clear) throw IOException("Broken GIF")
                out[written++] = suffix[code]
                previous = code
                continue
            }
            val current = code
            var depth = 0
            if (code >= next) {
                stack[depth++] = firstOf[previous]
                code = previous
            }
            while (code >= clear) {
                stack[depth++] = suffix[code]
                code = prefix[code]
            }
            stack[depth++] = suffix[code]
            while (depth > 0 && written < pixels) out[written++] = stack[--depth]
            if (next < 4096) {
                prefix[next] = previous
                suffix[next] = suffix[code]
                firstOf[next] = firstOf[previous]
                next++
                if (next == 1 shl codeSize && codeSize < 12) codeSize++
            }
            previous = current
        }
        return out
    }

    /** Where the sub-blocks starting at [from] end. */
    private fun skipBlocks(from: Int): Int {
        var at = from
        while (at < bytes.size) {
            val size = u8(at)
            at += 1 + size
            if (size == 0) return at
        }
        throw IOException("Broken GIF")
    }

    private fun colors(from: Int, count: Int): IntArray {
        if (from + count * 3 > bytes.size) throw IOException("Broken GIF")
        return IntArray(count) { index ->
            val at = from + index * 3
            (0xFF shl 24) or (u8(at) shl 16) or (u8(at + 1) shl 8) or u8(at + 2)
        }
    }

    private fun u8(at: Int): Int = if (at < bytes.size) bytes[at].toInt() and 0xFF else throw IOException("Broken GIF")
    private fun u16(at: Int): Int = u8(at) or (u8(at + 1) shl 8)
}
