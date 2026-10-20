package surf.comma.android.routines

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import android.widget.ImageView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Public HTTPS pictures the Routines briefing names: an app's icon or a media item's thumbnail. They carry no
 * credential and are read without one; until one arrives, and when it cannot, the view keeps what it shows.
 * Small and few, so a memory cache is enough.
 */
object RemoteImages {
    private val client = OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val cache = object : LruCache<String, Bitmap>(4 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }

    fun load(view: ImageView, url: String?, sizePx: Int) {
        cancel(view)
        if (url == null || !url.startsWith("https://")) return
        cache.get(url)?.let { view.setImageBitmap(it); view.imageTintList = null; return }
        view.setTag(TAG, scope.launch {
            val bitmap = runCatching {
                withContext(Dispatchers.IO) {
                    client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                        val body = response.body ?: return@use null
                        if (!response.isSuccessful || body.contentLength() > MAX_BYTES) return@use null
                        val bytes = body.source().readByteArray(MAX_BYTES).takeIf { it.isNotEmpty() } ?: return@use null
                        decode(bytes, sizePx)
                    }
                }
            }.getOrNull() ?: return@launch
            cache.put(url, bitmap)
            view.setImageBitmap(bitmap)
            view.imageTintList = null
        })
    }

    /** Drops the view's pending download, so a recycled view shown something else is not overwritten later. */
    fun cancel(view: ImageView) {
        (view.getTag(TAG) as? Job)?.cancel()
        view.setTag(TAG, null)
    }

    private fun okio.BufferedSource.readByteArray(limit: Long): ByteArray {
        request(limit + 1)
        return if (buffer.size > limit) ByteArray(0) else readByteArray()
    }

    private fun decode(bytes: ByteArray, size: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    private val TAG = surf.comma.android.R.id.remote_image_job
    private const val MAX_BYTES = 2L * 1024 * 1024
}
