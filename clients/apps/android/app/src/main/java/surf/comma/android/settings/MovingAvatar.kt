package surf.comma.android.settings

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import java.io.ByteArrayOutputStream
import surf.comma.android.media.AnimatedWebP
import surf.comma.android.media.GifFrames

/**
 * A picked GIF made an avatar the server keeps: its middle square as a WebP, which moves when the GIF does. Each frame
 * is drawn and encoded again, smaller, at lower quality and then with fewer frames, until it fits [maxBytes]; the
 * smallest try when nothing fits, which the account then refuses as too large.
 */
internal object MovingAvatar {
    /** Sides a moving avatar is drawn at, largest first. */
    private val sides = listOf(256, 192, 128, 96)
    private val qualities = listOf(80, 60)
    /** Frames read at most; a longer GIF keeps its first ones. */
    private const val MAX_FRAMES = 300

    fun webp(gif: ByteArray, maxBytes: Long): ByteArray {
        val frames = GifFrames(gif)
        val square = minOf(frames.width, frames.height)
        val left = (frames.width - square) / 2
        val top = (frames.height - square) / 2
        val crop = Rect(left, top, left + square, top + square)
        val source = Bitmap.createBitmap(frames.width, frames.height, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        var smallest: ByteArray? = null
        try {
            for (side in sides.filterIndexed { index, side -> index == sides.lastIndex || side <= square }) {
                val output = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(output)
                val target = Rect(0, 0, side, side)
                try {
                    for (quality in qualities) {
                        val encoded = mutableListOf<AnimatedWebP.Frame>()
                        frames.forEach(MAX_FRAMES) { pixels, delay ->
                            source.setPixels(pixels, 0, frames.width, 0, 0, frames.width, frames.height)
                            output.eraseColor(0)
                            canvas.drawBitmap(source, crop, target, paint)
                            val webp = ByteArrayOutputStream().also { output.compress(Bitmap.CompressFormat.WEBP_LOSSY, quality, it) }
                            // Under 20 ms shows as 100 ms, as browsers show a GIF.
                            encoded += AnimatedWebP.Frame(webp.toByteArray(), if (delay < 20) 100 else delay)
                        }
                        val tries = if (encoded.size <= 1) listOf(encoded.single().webp)
                        else (1..3).map { step -> AnimatedWebP.of(everyNth(encoded, step), side) }
                        for (webp in tries) {
                            if (webp.size <= maxBytes) return webp
                            if (smallest == null || webp.size < smallest.size) smallest = webp
                        }
                    }
                } finally {
                    output.recycle()
                }
            }
        } finally {
            source.recycle()
        }
        return smallest!!
    }

    /** Every [step]th frame, each shown as long as the frames it stands for. */
    internal fun everyNth(frames: List<AnimatedWebP.Frame>, step: Int): List<AnimatedWebP.Frame> {
        val kept = mutableListOf<AnimatedWebP.Frame>()
        frames.forEachIndexed { index, frame ->
            val last = kept.lastOrNull()
            if (index % step == 0 || last == null) kept += frame
            else kept[kept.lastIndex] = AnimatedWebP.Frame(last.webp, last.durationMs + frame.durationMs)
        }
        return kept
    }
}
