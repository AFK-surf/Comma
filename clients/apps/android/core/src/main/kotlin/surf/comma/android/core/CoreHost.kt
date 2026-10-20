package surf.comma.android.core

import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** What Google's account chooser gave: an ID token bound to the attempt's nonce, or none. */
fun interface GoogleIdTokens {
    /** Blocks until the person chose; null when there is no token (closed, no account, refused). */
    fun request(clientId: String, nonce: String): String?
}

/**
 * The app as the client core's host: what `packages/core/src/hosts/mobile.ts` asks for.
 *
 * - Product requests (`fetch`, `stream.*`) go to the Comma API with the bearer of the lease they name, taken from
 *   [custody]'s gate; one made for a lease the gate does not hold is answered 409 without reaching the server. A 401
 *   shuts the gate and tells the core. Redirects are not followed.
 * - Auth requests (`auth.fetch`) carry the credential the core names by reference; a bearer in the answer stays in
 *   [custody].
 * - The session ports (`session.*`) are [custody]'s and [google]'s.
 * - The databases (`sql.*`) are SQLite files in [dataDir], used at once on the core's thread.
 */
class CoreHost(
    client: OkHttpClient,
    val custody: SessionCustody,
    private val dataDir: File,
    private val google: GoogleIdTokens,
    /** Where the core's downloads are written. */
    val downloads: HostDownloads,
    private val streams: ExecutorService = Executors.newCachedThreadPool { Thread(it, "comma-core-stream") },
    /** Told of each request that got no answer ([Throwable]) or a server error (its status), for diagnostics. */
    private val networkFailure: (Throwable?, Int?) -> Unit = { _, _ -> },
) : CoreHostOps {
    private val http = client.newBuilder().followRedirects(false).followSslRedirects(false)
        .callTimeout(0, TimeUnit.SECONDS).build()
    // The server holds an event stream open and sends a heartbeat every 15 s.
    private val streaming = http.newBuilder().readTimeout(60, TimeUnit.SECONDS).build()
    private val sql = HostSql(dataDir)
    @Volatile private var engine: Engine? = null

    private class Stream(val call: Call, val response: Response)

    /** Requests under way, by the core's operation id (what `abort` names). */
    private val calls = ConcurrentHashMap<Long, Call>()
    private val open = ConcurrentHashMap<Long, Stream>()
    private val nextStream = AtomicLong(1)
    private val grants = ConcurrentHashMap<String, Boolean>()

    override fun startConfig(): JSONObject = JSONObject().put("platform", "android").put("apiOrigin", custody.audience)
        .put("resumed", custody.resume())

    override fun attached(engine: Engine?) {
        this.engine = engine
        if (engine == null) {
            // The core went: its databases close, its requests end, and what it had not settled is queued.
            for (call in calls.values) call.cancel()
            calls.clear()
            for (stream in open.values) stream.call.cancel()
            open.clear()
            downloads.closeAll()
            downloadLeases.clear()
            sql.closeAll()
            runCatching { custody.coreExited() }
        }
    }

    /**
     * The server answered 401 to a request the app made itself with [leased]: the gate shuts now, and the core hears
     * it as a refusal of that lease.
     */
    fun unauthorized(leased: LeasedCredential) {
        if (custody.revoke(leased)) engine?.rejected(leased.lease.toJson().toString(), 401)
    }

    override fun callSync(op: String, input: JSONObject): Any? = when (op) {
        "session.gate" -> {
            custody.gate(input.getJSONObject("snapshot"), SessionLease.from(input.optJSONObject("lease")))
            null
        }
        "sql.open" -> sql.open(input.getString("name"))
        "sql.exec" -> { sql.exec(input.getInt("id"), input.getString("sql")); null }
        "sql.run" -> sql.run(input.getInt("id"), input.getString("sql"), input.optJSONArray("params"))
        "sql.all" -> sql.all(input.getInt("id"), input.getString("sql"), input.optJSONArray("params"))
        "sql.close" -> { sql.close(input.getInt("id")); null }
        "sql.delete" -> { sql.delete(input.getString("name")); null }
        else -> throw HostFailure("unknown operation: $op")
    }

    override fun call(op: String, id: Long, input: JSONObject, bytes: ByteArray?, reply: CoreHostOps.Reply) {
        when (op) {
            "abort" -> {
                val aborted = input.optLong("id")
                calls.remove(aborted)?.cancel()
                streams.execute { runCatching { custody.dropped(aborted) } }
            }
            "fetch" -> product(id, input, bytes, reply, stream = false)
            "stream.open" -> product(id, input, bytes, reply, stream = true)
            "stream.read" -> streams.execute { read(input.optLong("id"), reply) }
            "stream.close" -> {
                open.remove(input.optLong("id"))?.let { it.call.cancel(); it.response.close() }
                reply.ok()
            }
            "auth.fetch" -> auth(id, input, bytes, reply)
            "download.open" -> download(id, input, bytes, reply)
            "download.step" -> streams.execute {
                val download = input.optLong("id")
                val leased = downloadLeases[download]
                try {
                    val step = downloads.step(download) { leased != null && custody.isCurrent(leased) }
                    if ("sha256" in step) downloadLeases.remove(download)
                    reply.ok(JSONObject(step))
                } catch (e: Exception) {
                    downloadLeases.remove(download)
                    reply.fail(e.message ?: e.javaClass.simpleName)
                }
            }
            "download.close" -> {
                downloadLeases.remove(input.optLong("id"))
                downloads.close(input.optLong("id"))
                reply.ok()
            }
            "download.remove" -> streams.execute { answering(reply) { downloads.remove(input.getString("path")); reply.ok() } }
            "download.retain" -> streams.execute {
                answering(reply) { downloads.retain(input.optString("keep").takeIf { !input.isNull("keep") }); reply.ok() }
            }
            "session.vault" -> streams.execute { answering(reply) { reply.ok(custody.vault()) } }
            "session.change" -> streams.execute {
                answering(reply) {
                    reply.ok(JSONObject().put("value", custody.change(input.getJSONObject("change")) ?: JSONObject.NULL))
                }
            }
            "session.google" -> streams.execute {
                answering(reply) {
                    val token = google.request(input.getString("clientId"), input.getString("nonce"))
                        ?: throw IOException("Google sign-in gave no credential.")
                    val grant = UUID.randomUUID().toString()
                    grants[grant] = true
                    reply.ok(JSONObject().put("idToken", token).put("grant", grant))
                }
            }
            "session.googleDone" -> {
                grants.remove(input.optString("grant"))
                reply.ok()
            }
            else -> reply.fail("unknown operation: $op")
        }
    }

    private inline fun answering(reply: CoreHostOps.Reply, block: () -> Unit) {
        try { block() } catch (e: Exception) { reply.fail(e.message ?: e.javaClass.simpleName) }
    }

    private fun request(input: JSONObject, bytes: ByteArray?): Request.Builder {
        val path = input.getString("path")
        require(path.startsWith("/")) { "The request names no path." }
        val url = (custody.audience + path).toHttpUrl()
        require(SessionCustody.canonicalAudience(url.scheme + "://" + url.host + ":" + url.port) == custody.audience) {
            "The request escaped its audience."
        }
        val method = input.getString("method").uppercase()
        val builder = Request.Builder().url(url)
        var contentType: String? = null
        val headers = input.optJSONArray("headers") ?: JSONArray()
        for (index in 0 until headers.length()) {
            val pair = headers.getJSONArray(index)
            val name = pair.getString(0).lowercase()
            if (name in WITHHELD) continue
            if (name == "content-type") contentType = pair.getString(1)
            builder.header(name, pair.getString(1))
        }
        val body = when {
            bytes != null -> bytes.toRequestBody(null)
            method == "GET" || method == "HEAD" -> null
            else -> ByteArray(0).toRequestBody(null)
        }
        builder.method(method, body)
        if (contentType != null && body != null) builder.header("content-type", contentType)
        return builder
    }

    /** The lease each download is made for: it stops when that lease is no longer the open one. */
    private val downloadLeases = ConcurrentHashMap<Long, LeasedCredential>()

    /** A download's request, as a product request is made: a 200 begins writing to the path the core named. */
    private fun download(id: Long, input: JSONObject, bytes: ByteArray?, reply: CoreHostOps.Reply) {
        val leased = SessionLease.from(input.optJSONObject("lease"))?.let(custody::acquire)
        if (leased == null) {
            reply.ok(JSONObject().put("id", 0).put("status", 409).put("total", JSONObject.NULL))
            return
        }
        val call = http.newCall(request(input, bytes).header("authorization", "Bearer ${leased.bearer()}").build())
        calls[id] = call
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                calls.remove(id, call)
                if (!call.isCanceled()) networkFailure(e, null)
                reply.fail("The request got no answer.")
            }

            override fun onResponse(call: Call, response: Response) {
                calls.remove(id, call)
                if (response.code >= 500) networkFailure(null, response.code)
                if (response.code == 401) unauthorized(leased)
                if (response.code != 200 || !custody.isCurrent(leased)) {
                    response.close()
                    reply.ok(JSONObject().put("id", 0).put("status", if (response.code == 200) 409 else response.code)
                        .put("total", JSONObject.NULL))
                    return
                }
                val download = try {
                    downloads.begin(response, input.getString("target"))
                } catch (e: Exception) {
                    response.close()
                    reply.fail(e.message ?: "The download could not begin.")
                    return
                }
                downloadLeases[download] = leased
                reply.ok(JSONObject().put("id", download).put("status", 200)
                    .put("total", response.body?.contentLength()?.takeIf { it >= 0 } ?: JSONObject.NULL))
            }
        })
    }

    /** A product request: the lease's bearer added, the answer whole (`fetch`) or opened as a stream. */
    private fun product(id: Long, input: JSONObject, bytes: ByteArray?, reply: CoreHostOps.Reply, stream: Boolean) {
        val lease = SessionLease.from(input.optJSONObject("lease"))
        val leased = lease?.let(custody::acquire)
        if (leased == null) {
            answer(reply, 409, LEASE_UNAVAILABLE, stream)
            return
        }
        val builder = request(input, bytes).header("authorization", "Bearer ${leased.bearer()}")
        // The account's own session endpoints (its list of signed-in devices) take a bearer only when told it is one.
        if (input.getString("path").startsWith("/v1/comma/auth/")) builder.header("x-comma-session-transport", "bearer")
        val call = (if (stream) streaming else http).newCall(builder.build())
        calls[id] = call
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                calls.remove(id, call)
                if (!call.isCanceled()) networkFailure(e, null)
                if (!custody.isCurrent(leased)) answer(reply, 409, LEASE_UNAVAILABLE, stream)
                else reply.fail("The request got no answer.")
            }

            override fun onResponse(call: Call, response: Response) {
                calls.remove(id, call)
                if (response.code >= 500) networkFailure(null, response.code)
                when {
                    !custody.isCurrent(leased) -> {
                        response.close()
                        answer(reply, 409, LEASE_UNAVAILABLE, stream)
                    }
                    // A 304 answers the core's own conditional read; it is no redirect.
                    response.code in 300..399 && response.code != 304 -> {
                        response.close()
                        answer(reply, 502, error("upstream_redirect_blocked"), stream)
                    }
                    response.code == 401 -> {
                        response.close()
                        // The gate shuts before anything else is told: no later request carries this bearer.
                        unauthorized(leased)
                        answer(reply, 401, error("unauthorized"), stream)
                    }
                    stream -> {
                        val streamId = nextStream.getAndIncrement()
                        open[streamId] = Stream(call, response)
                        reply.ok(head(response).put("id", streamId))
                    }
                    else -> try {
                        val body = response.use { it.body?.bytes() ?: ByteArray(0) }
                        reply.ok(head(response), body)
                    } catch (_: IOException) {
                        reply.fail("The answer broke off.")
                    }
                }
            }
        })
    }

    /** An answer the app gives itself: for a stream, one that is already at its end. */
    private fun answer(reply: CoreHostOps.Reply, status: Int, body: String, stream: Boolean) {
        val head = JSONObject().put("status", status)
            .put("headers", JSONArray().put(JSONArray().put("content-type").put("application/json")))
        if (!stream) {
            reply.ok(head, body.toByteArray())
            return
        }
        val streamId = nextStream.getAndIncrement()
        ended[streamId] = body.toByteArray()
        reply.ok(head.put("id", streamId))
    }

    /** Streams the app answered itself: their body, given once, then the end. */
    private val ended = ConcurrentHashMap<Long, ByteArray>()

    private fun read(streamId: Long, reply: CoreHostOps.Reply) {
        ended.remove(streamId)?.let {
            if (it.isNotEmpty()) {
                ended[streamId] = ByteArray(0)
                reply.ok(bytes = it)
            } else reply.ok(JSONObject().put("end", true))
            return
        }
        val stream = open[streamId]
        if (stream == null) {
            reply.ok(JSONObject().put("end", true))
            return
        }
        try {
            val source = stream.response.body?.source()
            val buffer = Buffer()
            // What has arrived, at least one byte: an event goes on as soon as the server sends it.
            val read = source?.read(buffer, CHUNK_BYTES) ?: -1
            if (read < 0) {
                open.remove(streamId)
                stream.response.close()
                reply.ok(JSONObject().put("end", true))
            } else reply.ok(bytes = buffer.readByteArray())
        } catch (_: IOException) {
            open.remove(streamId)
            stream.response.close()
            reply.fail("The stream broke off.")
        }
    }

    /** An auth request: the credential it names attached, a bearer in the answer kept in the custody. */
    private fun auth(id: Long, input: JSONObject, bytes: ByteArray?, reply: CoreHostOps.Reply) {
        val path = input.optString("path")
        if (!path.startsWith("/v1/comma/auth/")) {
            reply.fail("Only the auth endpoints are made for the session lifecycle.")
            return
        }
        val kept = JSONArray()
        val headers = input.optJSONArray("headers") ?: JSONArray()
        for (index in 0 until headers.length()) {
            val pair = headers.getJSONArray(index)
            if (pair.getString(0).lowercase() in AUTH_REQUEST_HEADERS) kept.put(pair)
        }
        val builder = try { request(JSONObject(input.toString()).put("headers", kept), bytes) } catch (e: Exception) {
            reply.fail(e.message ?: "The auth request is not one.")
            return
        }
        builder.header("x-comma-session-transport", "bearer")
        if (input.has("credential")) {
            val token = custody.tokenFor(input.getString("credential"))
            if (token == null) {
                reply.fail("The credential named is not kept.")
                return
            }
            builder.header("authorization", "Bearer $token")
        }
        val call = http.newCall(builder.build())
        calls[id] = call
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                calls.remove(id, call)
                if (!call.isCanceled()) networkFailure(e, null)
                reply.fail("The request got no answer.")
            }

            override fun onResponse(call: Call, response: Response) {
                if (response.code >= 500) networkFailure(null, response.code)
                try {
                    val body = response.use { it.body?.bytes() ?: ByteArray(0) }
                    val kept = custody.keepBearer(body, id)
                    // Given up meanwhile: the core never takes this answer, so what it carried is queued.
                    if (!calls.remove(id, call)) custody.dropped(id)
                    val head = JSONObject().put("status", response.code).put("headers", JSONArray().apply {
                        for ((name, value) in response.headers) if (name.lowercase() in AUTH_RESPONSE_HEADERS)
                            put(JSONArray().put(name.lowercase()).put(value))
                    })
                    reply.ok(head, kept)
                } catch (_: IOException) {
                    calls.remove(id, call)
                    reply.fail("The answer broke off.")
                }
            }
        })
    }

    private fun head(response: Response): JSONObject = JSONObject().put("status", response.code)
        .put("headers", JSONArray().apply {
            for ((name, value) in response.headers) put(JSONArray().put(name.lowercase()).put(value))
        })

    private fun error(code: String) = JSONObject().put("error", code).toString()

    private companion object {
        const val CHUNK_BYTES = 65_536L
        /** What the core may not set on a product request: the app adds the credential itself. */
        val WITHHELD = setOf("authorization", "cookie", "host", "content-length", "connection")
        val AUTH_REQUEST_HEADERS = setOf("accept", "content-type")
        val AUTH_RESPONSE_HEADERS = setOf("content-type", "retry-after")
        val LEASE_UNAVAILABLE: String = JSONObject().put("error", JSONObject().put("code", "session_product_lease_unavailable")).toString()
    }
}
