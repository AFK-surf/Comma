package surf.comma.android.media

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import surf.comma.android.ui.Background

/** A downloaded video's first frame, stored next to it, and the video's displayed size. */
data class VideoCover(val file: File, val dimensions: ImageDimensions)

/** Writes the first frame of [video], at most [maxEdge] on its long side, as a JPEG to [output]. */
fun interface VideoFrameReader {
    /** Returns the frame's size as displayed (rotation applied), or null if there is no frame. */
    fun write(video: File, maxEdge: Int, output: File): ImageDimensions?
}

/**
 * Covers are extracted once per video and their sizes remembered in [sizes] (keyed like the
 * download, see [MediaDownload.key]), so a list can reserve the right height before the file or
 * cover is loaded again.
 */
class VideoCovers(
    private val sizes: AspectRatioCache,
    private val reader: VideoFrameReader = AndroidVideoFrameReader,
    private val maxEdge: Int = 1280,
    private val dispatcher: CoroutineDispatcher = Background.files,
) {
    private val extraction = Mutex() // One retriever at a time bounds decoder memory.

    /** Known size, for placeholders. Main-thread safe. */
    fun dimensions(key: String): ImageDimensions? = sizes.get(key)

    suspend fun cover(key: String, video: File): VideoCover? = withContext(dispatcher) {
        val output = File(video.parentFile?.parentFile ?: throw IOException("No cover directory"), COVER)
        sizes.get(key)?.let { known -> if (output.isFile && output.length() > 0) return@withContext VideoCover(output, known) }
        extraction.withLock {
            val temporary = File(output.path + ".tmp")
            try {
                val size = reader.write(video, maxEdge, temporary) ?: return@withLock null
                if (!temporary.renameTo(output)) throw IOException("Cannot store cover")
                sizes.put(key, size)
                VideoCover(output, size)
            } finally {
                temporary.delete()
            }
        }
    }

    suspend fun clear() { sizes.clear() }

    private companion object { const val COVER = "cover.jpg" }
}

object AndroidVideoFrameReader : VideoFrameReader {
    override fun write(video: File, maxEdge: Int, output: File): ImageDimensions? {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        try {
            retriever.setDataSource(video.path)
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            if (width <= 0 || height <= 0) return null
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val displayed = if (rotation % 180 != 0) ImageDimensions(height, width) else ImageDimensions(width, height)
            // Scaled in the decoder to fit a square box, which keeps the frame's own proportions
            // whether or not it comes back rotated: a 4K first frame never becomes a full bitmap.
            val box = minOf(maxEdge, maxOf(width, height))
            frame = retriever.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, box, box) ?: return null
            output.outputStream().use { if (!frame.compress(Bitmap.CompressFormat.JPEG, 85, it)) throw IOException("Cannot encode cover") }
            return displayed
        } catch (_: RuntimeException) {
            return null // Not a video the platform can read; the card falls back to its placeholder.
        } finally {
            frame?.recycle()
            retriever.release()
        }
    }
}
