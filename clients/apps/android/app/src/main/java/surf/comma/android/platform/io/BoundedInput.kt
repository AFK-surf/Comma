package surf.comma.android.platform.io

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Reads at most [maxBytes] plus one sentinel byte; an oversized source returns null. */
internal fun InputStream.readBytesCapped(maxBytes: Int): ByteArray? {
    require(maxBytes >= 0) { "maxBytes must be non-negative" }
    val output = ByteArrayOutputStream(minOf(maxBytes, DEFAULT_BUFFER_SIZE))
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    var remaining = maxBytes.toLong()
    while (true) {
        val read = read(buffer, 0, minOf(buffer.size.toLong(), remaining + 1).toInt())
        if (read < 0) return output.toByteArray()
        if (read == 0) continue
        if (read.toLong() > remaining) return null
        output.write(buffer, 0, read)
        remaining -= read.toLong()
    }
}
