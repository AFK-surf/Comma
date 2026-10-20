package surf.comma.android.media

import android.graphics.BitmapFactory
import android.media.ExifInterface
import coil3.ImageLoader
import coil3.decode.DataSource
import coil3.decode.ImageSource
import coil3.fetch.Fetcher
import coil3.fetch.SourceFetchResult
import coil3.request.Options
import kotlinx.coroutines.withContext
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import java.io.File
import java.io.IOException
import surf.comma.android.ui.Background

internal data class AuthorizedImage(val session: AuthorizedSession, val image: MediaImage) {
    val key: String = mediaCacheKey(session, image.source)
}

/**
 * A remote picture for Coil: the original the client core downloaded to the device ([MediaFileStore]), checked to be
 * the image its message says before any decoder sees it, and its size remembered for the rows' layout.
 */
internal class MediaImageFetcherFactory(
    private val authorizedHttp: AuthorizedHttp,
    private val files: MediaFileStore,
    private val ratios: AspectRatioCache,
) : Fetcher.Factory<AuthorizedImage> {
    override fun create(data: AuthorizedImage, options: Options, imageLoader: ImageLoader): Fetcher = Fetcher {
        val (file, inspected) = original(data)
        SourceFetchResult(ImageSource(file.toOkioPath(), FileSystem.SYSTEM), inspected.mime, DataSource.DISK)
    }

    /** The verified original on the device, downloading it first if needed. */
    suspend fun original(data: AuthorizedImage): Pair<File, InspectedImage> {
        authorizedHttp.requireCurrent(data.session)
        val image = data.image
        val download = files.download(MediaAttachment(image.fileName, image.mimeType, null, image.source))
            ?: throw IOException("No media session")
        val file = download.awaitFile() ?: throw IOException("The image is not available")
        authorizedHttp.requireCurrent(data.session)
        val inspected = withContext(Background.files) { inspectImage(file, image.declaredImageMime) }
        ratios.put(data.key, inspected.dimensions)
        return file to inspected
    }
}

/** An extension admits an image candidate; only a concrete MIME declaration constrains its bytes. */
private val MediaImage.declaredImageMime: String?
    get() = InlineMediaPolicy.normalize(mimeType).takeUnless { it.isEmpty() || it == "application/octet-stream" }

internal data class InspectedImage(val mime: String, val dimensions: ImageDimensions)

/** Header-only validation before allowing any Coil decoder to see the file. */
internal fun inspectImage(file: File, expectedMime: String?): InspectedImage {
    if (file.length() <= 0) throw IOException("Invalid image length")
    val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, options)
    val actualMime = options.outMimeType
    if (actualMime !in setOf("image/jpeg", "image/png", "image/gif", "image/webp") ||
        (expectedMime != null && actualMime != expectedMime) || options.outWidth <= 0 || options.outHeight <= 0
    ) throw IOException("Image signature mismatch")
    val orientation = if (actualMime == "image/gif") 1 else runCatching {
        ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)
    }.getOrDefault(1)
    val dimensions = if (orientation in 5..8) ImageDimensions(options.outHeight, options.outWidth)
    else ImageDimensions(options.outWidth, options.outHeight)
    return InspectedImage(actualMime, dimensions)
}
