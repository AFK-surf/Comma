package surf.comma.android.media

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.net.Uri
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import surf.comma.android.ui.Background

/** Ownership of the private temporary file transfers to the caller; close after the attempt. */
data class PreparedImage(val file: File, val name: String, val format: UploadImageFormat, val dimensions: ImageDimensions) : AutoCloseable {
    val size: Long get() = file.length()
    override fun close() { file.delete() }
}

fun interface ImagePreprocessor {
    suspend fun prepare(uri: Uri): PreparedImage
}

class AndroidImagePreprocessor(
    private val resolver: ContentResolver,
    private val directory: File,
    private val dispatcher: CoroutineDispatcher = Background.files,
    private val targetBytes: Long = MediaLimits.TARGET_BYTES,
) : ImagePreprocessor {
    // Serial decode bounds peak bitmap memory even when three uploads run concurrently.
    private val decodePermit = Semaphore(1)
    init { require(targetBytes in 1..MediaLimits.MAX_UPLOAD_BYTES) }

    override suspend fun prepare(uri: Uri): PreparedImage {
        var completed: PreparedImage? = null
        try {
            return withContext(dispatcher) {
                decodePermit.withPermit {
                    currentCoroutineContext().ensureActive()
                    check(directory.isDirectory || directory.mkdirs())
                    val header = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    (resolver.openInputStream(uri) ?: throw IOException("Cannot read image")).use {
                        BitmapFactory.decodeStream(it, null, header)
                    }
                    val mime = header.outMimeType ?: throw IOException("Unknown image format")
                    val original = ImageDimensions(header.outWidth, header.outHeight)
                    if (mime == "image/gif") return@withPermit copyGif(uri, original).also { completed = it }
                    UploadImageFormat.choose(mime, false) // Reject unsupported decoders before allocation.
                    var bitmap: Bitmap? = null
                    var output: File? = null
                    try {
                        val job = currentCoroutineContext()
                        bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                            job.ensureActive()
                            // ImageDecoder reports and applies EXIF orientation, including mirrored images.
                            val size = ImageSizing.fit(ImageDimensions(info.size.width, info.size.height))
                            decoder.setTargetSize(size.width, size.height)
                            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                            decoder.setOnPartialImageListener { false }
                        }
                        // Gainmaps can carry auxiliary metadata in JPEG containers; export SDR pixels only.
                        bitmap.setGainmap(null)
                        val format = UploadImageFormat.choose(mime, hasTransparency(bitmap))
                        output = File.createTempFile("image-", ".${format.extension}", directory)
                        var quality = 90
                        while (true) {
                            job.ensureActive()
                            val encoding = if (format == UploadImageFormat.PNG) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
                            output.outputStream().use {
                                if (!bitmap!!.compress(encoding, quality, it)) throw IOException("Cannot encode image")
                            }
                            // Only pixel data is encoded. No source EXIF/XMP/GPS metadata is copied.
                            if (output.length() <= targetBytes) break
                            if (format == UploadImageFormat.JPEG && quality > 60) {
                                quality -= 10
                                continue
                            }
                            val old = bitmap!!
                            val before = ImageDimensions(old.width, old.height)
                            val next = ImageSizing.forByteBudget(before, output.length(), targetBytes)
                            if (next == before) throw IOException("Cannot meet image byte budget")
                            bitmap = Bitmap.createScaledBitmap(old, next.width, next.height, true)
                            if (bitmap !== old) old.recycle()
                            quality = 90
                        }
                        job.ensureActive()
                        check(output.length() in 1..MediaLimits.MAX_UPLOAD_BYTES)
                        PreparedImage(output, "image.${format.extension}", format, ImageDimensions(bitmap!!.width, bitmap.height)).also { completed = it }
                    } catch (failure: Throwable) {
                        output?.delete()
                        throw failure
                    } finally {
                        bitmap?.recycle()
                    }
                }
            }
        } catch (failure: Throwable) {
            // withContext may discard a resource at its dispatch-back cancellation boundary.
            completed?.close()
            throw failure
        }
    }

    private suspend fun hasTransparency(bitmap: Bitmap): Boolean {
        if (!bitmap.hasAlpha()) return false
        val row = IntArray(bitmap.width)
        for (y in 0 until bitmap.height) {
            currentCoroutineContext().ensureActive()
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            if (row.any { (it ushr 24) != 255 }) return true
        }
        return false
    }

    private suspend fun copyGif(uri: Uri, size: ImageDimensions): PreparedImage {
        // Preserve animation byte-for-byte; reject rather than silently flatten/resize a GIF.
        require(size.width <= MediaLimits.MAX_EDGE && size.height <= MediaLimits.MAX_EDGE && size.pixels <= MediaLimits.MAX_PIXELS) {
            "GIF dimensions exceed upload limits"
        }
        val output = File.createTempFile("image-", ".gif", directory)
        try {
            resolver.openInputStream(uri)?.use { input ->
                output.outputStream().use { sink ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MediaLimits.MAX_UPLOAD_BYTES) throw IOException("GIF exceeds upload limit")
                        sink.write(buffer, 0, count)
                    }
                    if (total == 0L) throw IOException("Empty image")
                }
            } ?: throw IOException("Cannot read image")
            return PreparedImage(output, "image.gif", UploadImageFormat.GIF, size)
        } catch (failure: Throwable) {
            output.delete()
            throw failure
        }
    }
}
