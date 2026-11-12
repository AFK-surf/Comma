package surf.comma.android.miniapps

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import android.widget.ImageView
import androidx.core.view.doOnAttach
import androidx.core.view.doOnDetach
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import java.util.Base64

/** Where an image is read from: a Workspace that owns or installed the app, or a link. */
sealed interface MiniAppVia {
    data class Workspace(val id: String) : MiniAppVia
    data class Link(val token: String) : MiniAppVia
}

/**
 * Host artwork: icons, covers and screenshots, read by the core with the account's session and access path (topic
 * `miniAppImage`). It grants no capability to an app. Decoded images are kept for the process, bounded.
 */
object MiniAppArtwork {
    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val cache = object : LruCache<String, Bitmap>(CACHE_BYTES) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }

    /**
     * Shows [url] in [view] once read; [placeholder] until then and when there is none. A later call on the same view
     * replaces this one. [loaded] hears whether an image was shown.
     */
    fun show(view: ImageView, core: CoreApi?, url: String?, via: MiniAppVia, placeholder: () -> Unit, loaded: (Boolean) -> Unit = {}) {
        (view.getTag(TAG) as? Job)?.cancel()
        val key = "${MiniAppRuntimes.currentScope()?.generation}/$via/$url"
        cache.get(key)?.let {
            view.setImageBitmap(it)
            loaded(true)
            return
        }
        placeholder()
        loaded(false)
        if (url == null || core == null) return
        val job = main.launch {
            val topic = JSONObject().put("topic", "miniAppImage").put("url", url)
            when (via) {
                is MiniAppVia.Workspace -> topic.put("workspace", via.id)
                is MiniAppVia.Link -> topic.put("link", via.token)
            }
            val src = core.subscribe(topic) { value ->
                (value as? JSONObject)?.takeIf { it.optString("status") != "loading" }?.let { it.text("src") ?: "" }
            }.first { it is TopicValue.Failed || (it as TopicValue.Value).value != null }
            val data = (src as? TopicValue.Value)?.value?.takeIf(String::isNotEmpty) ?: return@launch
            val bitmap = withContext(Dispatchers.Default) {
                runCatching {
                    val bytes = Base64.getDecoder().decode(data.substringAfter(','))
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }.getOrNull()
            } ?: return@launch
            cache.put(key, bitmap)
            view.setImageBitmap(bitmap)
            loaded(true)
        }
        view.setTag(TAG, job)
        if (view.isAttachedToWindow) view.doOnDetach { job.cancel() } else view.doOnAttach { it.doOnDetach { job.cancel() } }
    }

    private val TAG = surf.comma.android.R.id.mini_app_artwork_job
    private const val CACHE_BYTES = 24 * 1024 * 1024
}
