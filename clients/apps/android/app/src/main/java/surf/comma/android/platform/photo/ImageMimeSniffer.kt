package surf.comma.android.platform.photo

import java.io.File
import java.io.IOException

/** Byte-based PNG/JPEG/WebP sniffing retained from Nothing Chat; never trusts an extension. */
object ImageMimeSniffer {
    fun sniffImageMimeType(file: File): String? {
        val head = ByteArray(12)
        val read = try {
            file.inputStream().use { it.read(head) }
        } catch (error: IOException) {
            return null
        }
        if (read < 12) return null
        return when {
            head[0] == 0x89.toByte() && head[1] == 'P'.code.toByte() && head[2] == 'N'.code.toByte() &&
                head[3] == 'G'.code.toByte() && head[4] == 0x0D.toByte() && head[5] == 0x0A.toByte() &&
                head[6] == 0x1A.toByte() && head[7] == 0x0A.toByte() -> "image/png"
            head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte() && head[2] == 0xFF.toByte() -> "image/jpeg"
            head[0] == 'R'.code.toByte() && head[1] == 'I'.code.toByte() && head[2] == 'F'.code.toByte() &&
                head[3] == 'F'.code.toByte() && head[8] == 'W'.code.toByte() && head[9] == 'E'.code.toByte() &&
                head[10] == 'B'.code.toByte() && head[11] == 'P'.code.toByte() -> "image/webp"
            else -> null
        }
    }
}
