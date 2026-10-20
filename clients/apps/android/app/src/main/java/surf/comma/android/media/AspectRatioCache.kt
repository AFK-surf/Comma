package surf.comma.android.media

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import kotlin.math.roundToInt
import surf.comma.android.ui.Background

/** Small LRU metadata cache; disk IO never runs on the caller's main thread. */
class AspectRatioCache private constructor(private val file: File?, private val capacity: Int) {
    private val lock = Any()
    private val writes = Mutex()
    private val values = LinkedHashMap<String, ImageDimensions>(16, 0.75f, true)

    init { require(capacity > 0) }

    fun get(key: String): ImageDimensions? = synchronized(lock) { values[key] }

    suspend fun put(key: String, dimensions: ImageDimensions) = withContext(Background.files) {
        writes.withLock {
            synchronized(lock) {
                values[key] = dimensions
                while (values.size > capacity) values.remove(values.keys.first())
            }
            persist()
        }
    }

    suspend fun clear() = withContext(Background.files) {
        writes.withLock {
            synchronized(lock) { values.clear() }
            file?.delete()
        }
    }

    private fun persist() {
        val destination = file ?: return
        val json = synchronized(lock) {
            JSONArray().apply { values.forEach { (key, size) -> put(JSONArray().put(key).put(size.width).put(size.height)) } }
        }
        destination.parentFile?.mkdirs()
        val temporary = File(destination.path + ".tmp")
        try {
            temporary.writeText(json.toString())
            java.nio.file.Files.move(temporary.toPath(), destination.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        } finally { temporary.delete() }
    }

    companion object {
        fun memory(capacity: Int = 2048) = AspectRatioCache(null, capacity)

        suspend fun open(file: File, capacity: Int = 2048): AspectRatioCache = withContext(Background.files) {
            AspectRatioCache(file, capacity).apply {
                // Metadata is expendable; ignore corruption, truncated writes, and oversized files.
                if (file.isFile && file.length() <= capacity * 128L) runCatching {
                    val array = JSONArray(file.readText())
                    for (index in maxOf(0, array.length() - capacity) until array.length()) {
                        val row = array.getJSONArray(index)
                        val key = row.getString(0)
                        if (key.matches(Regex("[0-9a-f]{64}"))) values[key] = ImageDimensions(row.getInt(1), row.getInt(2))
                    }
                }.onFailure { values.clear() }
            }
        }
    }
}

/** Freeze at bind time. Learning a new ratio never changes the current row's reserved height. */
data class ImagePlaceholder(val width: Int, val height: Int) {
    companion object {
        fun reserve(width: Int, dimensions: ImageDimensions?, fallbackRatio: Double = 1.0): ImagePlaceholder {
            require(width > 0 && fallbackRatio.isFinite() && fallbackRatio > 0)
            val ratio = dimensions?.ratio ?: fallbackRatio
            return ImagePlaceholder(width, (width / ratio).coerceIn(1.0, Int.MAX_VALUE.toDouble()).roundToInt())
        }
    }
}
