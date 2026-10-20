package surf.comma.android.conversation

import android.net.TrafficStats
import android.os.Process
import android.os.SystemClock
import android.util.Log
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import okio.utf8Size
import surf.comma.android.BuildConfig

/**
 * Traffic counters of the client core's requests (the app makes them), written to logcat under [TAG] in diagnostic builds (debug and internal)
 * and compiled out of release. A line names an endpoint by its fixed path words only; every id
 * segment becomes `*`, and query values, headers and bodies are never logged.
 */
internal object SyncDiagnostics {
    const val TAG = "CommaSync"

    /** Counts the bytes each authenticated response delivered on the wire (before decompression). */
    fun interceptor(): Interceptor? = if (BuildConfig.SYNC_DIAGNOSTICS) Interceptor(::countBody) else null

    private fun countBody(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val started = SystemClock.elapsedRealtime()
        val response = chain.proceed(request)
        val body = response.body ?: return response
        val label = "${request.method} ${endpoint(request.url.pathSegments)}" +
            request.url.queryParameterNames.sorted().joinToString(",", prefix = " q=").takeIf { request.url.querySize > 0 }.orEmpty()
        val encoding = response.header("Content-Encoding") ?: "identity"
        return response.newBuilder().body(CountingBody(body) { bytes, complete ->
            log("http $label status=${response.code} enc=$encoding wire=${bytes}B " +
                "ms=${SystemClock.elapsedRealtime() - started} end=${if (complete) "eof" else "closed"} ${uidTotals()}")
        }).build()
    }

    /** Fixed path words survive; anything else (group, conversation, task or media ids) becomes `*`. */
    internal fun endpoint(segments: List<String>): String =
        segments.filter { it.isNotEmpty() }.joinToString("/") { if (it in PATH_WORDS) it else "*" }

    private fun uidTotals(): String {
        val uid = Process.myUid()
        return "uidRx=${TrafficStats.getUidRxBytes(uid)} uidTx=${TrafficStats.getUidTxBytes(uid)}"
    }

    private fun log(line: String) {
        Log.i(TAG, line)
    }

    private val PATH_WORDS = setOf(
        "v1", "comma", "auth", "session", "sessions", "revoke-all", "logout", "me", "profile", "avatar", "workspaces",
        "groups", "assistant-chat", "conversations", "events", "messages", "attachments", "preview", "cancel",
        "archive", "participants", "history", "task-summaries", "task-order", "task-labels", "policy", "files",
        "agents", "resources", "uploads", "integrations", "voice",
    )

    private class CountingBody(private val delegate: ResponseBody, private val done: (Long, Boolean) -> Unit) : ResponseBody() {
        private var bytes = 0L
        private var reported = false
        private val counted: BufferedSource = object : ForwardingSource(delegate.source()) {
            override fun read(sink: Buffer, byteCount: Long): Long {
                val read = super.read(sink, byteCount)
                if (read < 0) report(true) else bytes += read
                return read
            }
            override fun close() {
                report(false)
                super.close()
            }
        }.buffer()

        override fun contentType(): MediaType? = delegate.contentType()
        override fun contentLength(): Long = delegate.contentLength()
        override fun source(): BufferedSource = counted

        @Synchronized private fun report(complete: Boolean) {
            if (reported) return
            reported = true
            done(bytes, complete)
        }
    }
}
