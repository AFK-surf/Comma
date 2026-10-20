package surf.comma.android.platform.photo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import surf.comma.android.platform.io.readBytesCapped
import java.io.File
import kotlin.math.max

/** Size-aware decode primitives for local photo tools. Call on a worker. */
internal object ImageDecode {
    fun decodeFile(file: File, targetWidthPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth > 0 && bounds.outHeight > 0) {
            val options = sampledOptions(bounds.outWidth, targetWidthPx)
            BitmapFactory.decodeFile(file.absolutePath, options)?.let { return it }
        }
        return runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                decoder.targetWidth(info.size.width, info.size.height, targetWidthPx)
            }
        }.getOrNull()
    }

    fun decodeUri(context: Context, uri: Uri, targetWidthPx: Int): Bitmap? {
        // Providers may report an unknown length. Read through the same hard byte boundary rather
        // than letting ImageDecoder consume an unbounded descriptor first.
        return context.contentResolver.openInputStream(uri)?.use { stream ->
            decodeBytes(
                stream.readBytesCapped(MAX_CONVERSATION_IMAGE_BYTES) ?: return null,
                targetWidthPx,
            )
        }
    }

    fun decodeBytes(bytes: ByteArray, targetWidthPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        return BitmapFactory.decodeByteArray(
            bytes,
            0,
            bytes.size,
            sampledOptions(bounds.outWidth, targetWidthPx),
        )
    }

    private fun sampledOptions(sourceWidth: Int, targetWidthPx: Int): BitmapFactory.Options {
        var sample = 1
        while (sourceWidth / (sample * 2) >= targetWidthPx) sample *= 2
        return BitmapFactory.Options().apply {
            inSampleSize = max(1, sample)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
    }

    private fun ImageDecoder.targetWidth(sourceWidth: Int, sourceHeight: Int, targetWidthPx: Int) {
        val width = sourceWidth.coerceAtLeast(1)
        if (width > targetWidthPx) {
            setTargetSize(targetWidthPx, (sourceHeight * targetWidthPx / width).coerceAtLeast(1))
        }
    }

}
