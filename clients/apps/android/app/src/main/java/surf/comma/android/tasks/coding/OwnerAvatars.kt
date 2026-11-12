package surf.comma.android.tasks.coding

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * GitHub account and organization avatars for the repository picker, read over https without the member's
 * credentials, once per address while the process lives (at most [CACHE] kept). The picker asks only for the owners
 * on its page, so the reads stay within one page of rows.
 */
internal object OwnerAvatars {
    private const val CACHE = 64
    private const val MAX_BYTES = 1L shl 20
    private val cache = LruCache<String, Bitmap>(CACHE)
    private val client by lazy {
        OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).followRedirects(true).build()
    }

    fun cached(url: String): Bitmap? = cache.get(url)

    suspend fun load(url: String, edge: Int): Bitmap? {
        if (!url.startsWith("https://")) return null
        cache.get(url)?.let { return it }
        return withContext(Dispatchers.IO) {
            runCatching {
                client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    val body = response.body ?: return@use null
                    if (!response.isSuccessful || body.contentLength() > MAX_BYTES) return@use null
                    val bytes = body.source().apply { request(MAX_BYTES + 1) }.buffer.let { buffer ->
                        if (buffer.size > MAX_BYTES) return@use null
                        buffer.readByteArray()
                    }
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                    var sample = 1
                    while (bounds.outWidth / (sample * 2) >= edge && bounds.outHeight / (sample * 2) >= edge) sample *= 2
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
                }
            }.getOrNull()?.also { cache.put(url, it) }
        }
    }
}
