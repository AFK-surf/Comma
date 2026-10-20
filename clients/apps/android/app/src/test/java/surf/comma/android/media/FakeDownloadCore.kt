package surf.comma.android.media

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The client core's downloads (`downloads.start`, the `download` topic), as far as the app reads them: a file the
 * test [serve]s is written under [root] and ready, one it refuses fails as it says, one it [hold]s stays downloading
 * until released. A file named an `expect` it does not match is unavailable, as the core's check says. Which request
 * reads a file, what is kept and for how long is the core's and is tested there.
 */
internal class FakeDownloadCore(val root: File) : CoreApi {
    sealed interface Served {
        class Bytes(val bytes: ByteArray) : Served
        /** `network` or `unavailable`. */
        class Refused(val failure: String) : Served
    }

    val calls = CopyOnWriteArrayList<Pair<String, JSONObject>>()
    /** What each file source (its JSON) is served; unserved ones are refused as unavailable. */
    val served = ConcurrentHashMap<String, Served>()
    val held = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val states = ConcurrentHashMap<String, MutableStateFlow<JSONObject>>()
    private val running = ConcurrentHashMap<String, Job>()
    private val asked = ConcurrentHashMap<String, Long>()
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)

    fun serve(source: JSONObject, bytes: ByteArray) { served[source.toString()] = Served.Bytes(bytes) }
    fun refuse(source: JSONObject, failure: String) { served[source.toString()] = Served.Refused(failure) }
    fun hold(source: JSONObject): CompletableDeferred<Unit> = CompletableDeferred<Unit>().also { held[source.toString()] = it }

    private fun state(source: String) = states.getOrPut(source) { MutableStateFlow(idle(source)) }
    private fun idle(source: String) = JSONObject().put("asked", asked[source] ?: 0L).put("status", "idle").put("received", 0).put("total", JSONObject.NULL)
        .put("path", JSONObject.NULL).put("failure", JSONObject.NULL)

    override suspend fun call(name: String, params: JSONObject): Any? {
        calls += name to params
        val source = params.getJSONObject("source").toString()
        val count = (asked[source] ?: 0L) + 1
        asked[source] = count
        // As the core does: the count and the state that comes of the call change in one step.
        fun counted() { state(source).value = JSONObject(state(source).value.toString()).put("asked", count) }
        when (name) {
            "downloads.start" -> {
                val current = state(source)
                if (current.value.getString("status") in setOf("downloading", "ready")) {
                    counted()
                    return JSONObject().put("asked", count)
                }
                val expect = params.optJSONObject("expect")
                current.value = idle(source).put("status", "downloading").put("total", expect?.optLong("size") ?: JSONObject.NULL)
                running[source] = work.launch {
                    held[source]?.await()
                    current.value = when (val served = served[source]) {
                        is Served.Bytes -> {
                            val sha = MessageDigest.getInstance("SHA-256").digest(served.bytes).joinToString("") { "%02x".format(it) }
                            if (expect != null && (expect.getLong("size") != served.bytes.size.toLong() || expect.getString("sha256") != sha)) {
                                idle(source).put("status", "failed").put("failure", "unavailable")
                            } else {
                                val path = "account/${source.hashCode().toUInt()}/${params.optString("name").ifEmpty { "file" }}"
                                File(root, path).apply { parentFile!!.mkdirs(); writeBytes(served.bytes) }
                                idle(source).put("status", "ready").put("received", served.bytes.size).put("total", served.bytes.size)
                                    .put("path", path)
                            }
                        }
                        is Served.Refused -> idle(source).put("status", "failed").put("failure", served.failure)
                        null -> idle(source).put("status", "failed").put("failure", "unavailable")
                    }
                }
            }
            "downloads.cancel" -> {
                running.remove(source)?.cancel()
                state(source).value = idle(source)
            }
            else -> counted()
        }
        return JSONObject().put("asked", count)
    }

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> =
        state(topic.getString("source")).map { TopicValue.Value(read(it)) }
}
