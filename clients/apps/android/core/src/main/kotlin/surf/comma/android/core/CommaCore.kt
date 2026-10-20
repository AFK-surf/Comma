package surf.comma.android.core

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * A call or topic that failed. [code] is the core's (a server's codes pass through), [status] the HTTP status when it
 * came from a server, [detail] what else the server said.
 */
class CoreError(val code: String, message: String, val status: Int? = null, val detail: Any? = null) :
    Exception(message)

/** Bytes as they cross to and from the core, in a call's params or answer and in a topic: `{"$bytes": base64}`. */
object CoreBytes {
    private const val KEY = "\$bytes"

    fun json(bytes: ByteArray): JSONObject = JSONObject().put(KEY, java.util.Base64.getEncoder().encodeToString(bytes))

    /** The bytes [value] carries, or null when it carries none. */
    fun read(value: Any?): ByteArray? =
        (value as? JSONObject)?.opt(KEY)?.let { it as? String }?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }
}

/** A topic's value as the app reads it, or why there is none now. */
sealed interface TopicValue<out T> {
    data class Value<T>(val value: T) : TopicValue<T>
    data class Failed(val error: CoreError) : TopicValue<Nothing>
}

/** The core as the app's features use it: named calls and topics. Tests put a fake in its place. */
interface CoreApi {
    /**
     * A named call: its answer (a [JSONObject], [JSONArray], string, number or boolean; null for none), or a
     * [CoreError]. Cancelled, the core is told to stop it.
     */
    suspend fun call(name: String, params: JSONObject = JSONObject()): Any?

    /**
     * A topic's values, each the whole current value read by [read] on the client's thread. The JSON it is given is
     * never changed afterwards, and a part of it the topic did not change is the same object as in the value before:
     * [read] can keep what it made of that part. The topic is let go when collection ends.
     */
    fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>>
}

/**
 * What the core needs of the app besides its UI (CoreHost.kt is the app's): requests, the credential store, SQLite.
 * Each [call] is answered once through [reply], on any thread; `abort` names one given up and is never answered.
 */
interface CoreHostOps {
    /** The JSON the core starts with (`MobileStart` in the core's phone host). */
    fun startConfig(): JSONObject
    fun call(op: String, id: Long, input: JSONObject, bytes: ByteArray?, reply: Reply)
    /** Answers at once: the value, or throws [HostFailure]. */
    fun callSync(op: String, input: JSONObject): Any?
    /** A core started: the app tells it of requests the server refused through [engine]. Null: it stopped. */
    fun attached(engine: Engine?)

    interface Reply {
        fun ok(json: JSONObject = JSONObject(), bytes: ByteArray? = null)
        fun fail(message: String)
    }
}

/** Why a host operation failed; [kind] is SQLite's (`full`, `busy`) when it said so. */
class HostFailure(message: String, val kind: String? = null) : Exception(message)

/**
 * The app's side of the client core: one core at a time, calls with request ids, and subscriptions that survive the
 * core starting again. Everything here runs on one thread of its own, apart from the core's.
 *
 * A core that fails ([EngineHost.fatal]) is closed and another started, after 0, 1, 2, 5, 10 then 30 s for one that
 * keeps failing. Calls under way then fail with `core_restarted` (whether they ran is unknown: the caller decides);
 * subscriptions are made again by themselves.
 */
class CommaCore(
    private val engines: EngineFactory,
    private val host: CoreHostOps,
    private val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "comma-core-client") },
    private val onFault: (String) -> Unit = {},
) : CoreApi {
    private class Subscription(val topic: JSONObject, val onValue: (Any?) -> Unit, val onError: (CoreError) -> Unit) {
        /** The whole current value, which deltas apply to; null until the first value and after an error. */
        var value: Any? = null
        var has = false
    }

    private var engine: Engine? = null
    private var nextId = 1L
    private val calls = HashMap<Long, (Result<Any?>) -> Unit>()
    private val subscriptions = LinkedHashMap<Long, Subscription>()
    private var failures = 0
    private var startedAt = 0L
    private var closed = false

    init { worker.execute(::start) }

    private fun start() {
        if (closed) return
        lateinit var mine: Engine
        val engineHost = object : EngineHost {
            override fun call(id: Long, op: String, json: ByteArray, bytes: ByteArray?) {
                val reply = object : CoreHostOps.Reply {
                    override fun ok(json: JSONObject, bytes: ByteArray?) = mine.complete(id, json.toString(), null, bytes)
                    override fun fail(message: String) = mine.complete(id, null, message, null)
                }
                try {
                    host.call(op, id, JSONObject(String(json, Charsets.UTF_8)), bytes, reply)
                } catch (e: Exception) {
                    if (op != "abort") reply.fail(e.message ?: e.javaClass.simpleName)
                }
            }

            override fun callSync(op: String, json: ByteArray): ByteArray = try {
                val value = host.callSync(op, JSONObject(String(json, Charsets.UTF_8)))
                JSONObject().put("value", value ?: JSONObject.NULL)
            } catch (e: HostFailure) {
                JSONObject().put("error", e.message ?: "failed").apply { e.kind?.let { put("kind", it) } }
            } catch (e: Exception) {
                JSONObject().put("error", e.message ?: e.javaClass.simpleName)
            }.toString().toByteArray()

            override fun emit(json: ByteArray) {
                val text = String(json, Charsets.UTF_8)
                worker.execute { if (engine === mine) receive(text) }
            }

            override fun fatal(reason: ByteArray) {
                val text = String(reason, Charsets.UTF_8)
                worker.execute { if (engine === mine) restart(text) }
            }
        }
        mine = try {
            engines.start(host.startConfig().toString(), engineHost)
        } catch (e: Throwable) {
            onFault("the core did not start: ${e.message}")
            retry()
            return
        }
        engine = mine
        startedAt = System.nanoTime()
        host.attached(mine)
        for ((id, subscription) in subscriptions) post(JSONObject().put("id", id).put("subscribe", subscription.topic).put("keyed", true))
    }

    private fun restart(reason: String) {
        onFault(reason)
        // A core that ran a while failed for a new reason: the pauses start over.
        if (System.nanoTime() - startedAt > STEADY_NANOS) failures = 0
        val old = engine
        engine = null
        // The core's thread has ended before the app lets go of what it was using (its databases, its requests).
        old?.close()
        host.attached(null)
        rejectCalls("core_restarted", "The core started again.")
        for (subscription in subscriptions.values) subscription.has = false
        retry()
    }

    private fun retry() {
        val delay = RETRY_MS[minOf(failures, RETRY_MS.size - 1)]
        failures++
        worker.schedule(::start, delay, TimeUnit.MILLISECONDS)
    }

    private fun rejectCalls(code: String, message: String) {
        val waiting = calls.values.toList()
        calls.clear()
        for (call in waiting) call(Result.failure(CoreError(code, message)))
    }

    private fun post(message: JSONObject) {
        engine?.receive(message.toString())
    }

    private fun receive(text: String) {
        val message = try { JSONObject(text) } catch (_: Exception) { return }
        val id = message.optLong("id", -1)
        if (id < 0) return
        val subscription = subscriptions[id]
        if (subscription != null) {
            when {
                message.has("value") -> {
                    subscription.value = message.get("value")
                    subscription.has = true
                }
                message.has("delta") -> {
                    if (!subscription.has) return
                    subscription.value = applyDelta(subscription.value, message.optJSONArray("delta") ?: JSONArray())
                }
                message.has("error") -> {
                    subscription.has = false
                    subscription.value = null
                    deliver { subscription.onError(error(message.optJSONObject("error"))) }
                    return
                }
                else -> return
            }
            deliver { subscription.onValue(subscription.value) }
            return
        }
        val call = calls[id] ?: return
        when {
            message.has("ok") -> {
                calls.remove(id)
                call(Result.success(message.get("ok").takeUnless { it === JSONObject.NULL }))
            }
            message.has("error") -> {
                calls.remove(id)
                call(Result.failure(error(message.optJSONObject("error"))))
            }
        }
    }

    /** A listener that throws must not take the client's thread down with it. */
    private inline fun deliver(block: () -> Unit) {
        try { block() } catch (e: Exception) { onFault("a topic listener failed: ${e.message}") }
    }

    private fun error(body: JSONObject?) = CoreError(
        body?.optString("code")?.takeIf { it.isNotEmpty() } ?: "internal",
        body?.optString("message").orEmpty(),
        body?.takeIf { it.has("status") && !it.isNull("status") }?.optInt("status"),
        body?.opt("detail")?.takeUnless { it === JSONObject.NULL },
    )

    override suspend fun call(name: String, params: JSONObject): Any? =
        suspendCancellableCoroutine { continuation ->
            var id = 0L
            worker.execute {
                when {
                    closed -> continuation.resumeWithException(CoreError("closed", "The core is closed."))
                    engine == null ->
                        continuation.resumeWithException(CoreError("core_restarted", "The core started again."))
                    else -> {
                        id = nextId++
                        calls[id] = { answer ->
                            answer.fold(continuation::resume, continuation::resumeWithException)
                        }
                        post(JSONObject().put("id", id).put("call", name).put("params", params))
                    }
                }
            }
            continuation.invokeOnCancellation {
                worker.execute {
                    if (calls.remove(id) != null) post(JSONObject().put("id", id).put("cancel", true))
                }
            }
        }

    override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> = callbackFlow {
        var id = 0L
        worker.execute {
            if (closed) {
                close()
                return@execute
            }
            id = nextId++
            subscriptions[id] = Subscription(
                topic,
                onValue = { trySend(TopicValue.Value(read(it))) },
                onError = { trySend(TopicValue.Failed(it)) },
            )
            post(JSONObject().put("id", id).put("subscribe", topic).put("keyed", true))
        }
        awaitClose {
            worker.execute {
                if (subscriptions.remove(id) != null) post(JSONObject().put("id", id).put("unsubscribe", true))
            }
        }
    }.buffer(Channel.CONFLATED)

    /** Stops the core for good. */
    fun close() {
        worker.execute {
            closed = true
            rejectCalls("closed", "The core is closed.")
            subscriptions.clear()
            val old = engine
            engine = null
            old?.close()
            host.attached(null)
        }
    }

    private companion object {
        val RETRY_MS = longArrayOf(0, 1000, 2000, 5000, 10_000, 30_000)
        const val STEADY_NANOS = 60_000_000_000L
    }
}
