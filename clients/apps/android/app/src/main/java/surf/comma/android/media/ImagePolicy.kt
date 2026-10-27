package surf.comma.android.media

import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

object MediaLimits {
    /** The upload API budget; received media has no fixed byte-size ceiling. */
    const val MAX_UPLOAD_BYTES = 10_000_000L
    /** A file sent as it is: uploaded from where it is as it is read, so far larger (the server's bound). */
    const val MAX_FILE_UPLOAD_BYTES = 512L * 1024 * 1024
    const val TARGET_BYTES = 2_000_000L
    const val MAX_EDGE = 4096
    const val MAX_PIXELS = 16_000_000L
}

data class ImageDimensions(val width: Int, val height: Int) {
    init { require(width > 0 && height > 0) }
    val ratio: Double get() = width.toDouble() / height
    val pixels: Long get() = width.toLong() * height
}

object ImageSizing {
    fun fit(
        original: ImageDimensions,
        maxEdge: Int = MediaLimits.MAX_EDGE,
        maxPixels: Long = MediaLimits.MAX_PIXELS,
    ): ImageDimensions {
        require(maxEdge > 0 && maxPixels > 0)
        val scale = min(1.0, min(maxEdge.toDouble() / maxOf(original.width, original.height),
            sqrt(maxPixels.toDouble() / original.pixels)))
        return scaled(original, scale)
    }

    /** A conservative next encode size; encoded byte count is measured again after every pass. */
    fun forByteBudget(size: ImageDimensions, actualBytes: Long, targetBytes: Long): ImageDimensions {
        require(actualBytes > 0 && targetBytes > 0)
        if (actualBytes <= targetBytes) return size
        return scaled(size, min(0.9, sqrt(targetBytes.toDouble() / actualBytes) * 0.95))
    }

    private fun scaled(size: ImageDimensions, scale: Double) = ImageDimensions(
        floor(size.width * scale).toInt().coerceAtLeast(1),
        floor(size.height * scale).toInt().coerceAtLeast(1),
    )
}

enum class UploadImageFormat(val mime: String, val extension: String) {
    JPEG("image/jpeg", "jpg"), PNG("image/png", "png"), GIF("image/gif", "gif");

    companion object {
        fun choose(sourceMime: String, hasTransparency: Boolean): UploadImageFormat = when (sourceMime) {
            "image/gif" -> GIF
            "image/png", "image/webp" -> if (hasTransparency) PNG else JPEG
            "image/jpeg", "image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence" -> JPEG
            else -> throw IllegalArgumentException("Unsupported image format")
        }
    }
}

/** These are routing decisions only. Actual bytes must also pass signature validation. */
enum class InlineMediaKind { IMAGE, VIDEO, FILE }

object InlineMediaPolicy {
    private val images = setOf("image/png", "image/jpeg", "image/gif", "image/webp")
    private val videos = setOf("video/mp4", "video/webm")
    private val extensions = mapOf("png" to "image/png", "jpg" to "image/jpeg", "jpeg" to "image/jpeg",
        "gif" to "image/gif", "webp" to "image/webp", "mp4" to "video/mp4", "m4v" to "video/mp4",
        "webm" to "video/webm")

    fun normalize(mime: String?): String = when (val value = mime.orEmpty().trim().lowercase()) {
        "image/jpg" -> "image/jpeg"
        "video/x-m4v" -> "video/mp4"
        else -> value
    }

    fun mime(fileName: String?, declaredMime: String?): String? {
        val name = fileName.orEmpty().substringAfterLast('/')
        val extension = name.substringAfterLast('.', "").lowercase()
        val inferred = extensions[extension]
        val declared = normalize(declaredMime)
        if (declared.isEmpty() || declared == "application/octet-stream") return inferred
        if (declared !in images && declared !in videos) return null
        if (extension.isNotEmpty() && inferred != declared) return null
        return declared
    }

    fun classify(fileName: String?, declaredMime: String?): InlineMediaKind = when (mime(fileName, declaredMime)) {
        in images -> InlineMediaKind.IMAGE
        in videos -> InlineMediaKind.VIDEO
        else -> InlineMediaKind.FILE
    }
}
