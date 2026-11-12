package surf.comma.android.miniapps

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebMessage
import android.webkit.WebMessagePort
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import surf.comma.android.ui.theme.NativeWebTokens
import surf.comma.android.core.CoreBytes
import surf.comma.android.core.CoreError
import java.io.ByteArrayInputStream
import java.util.Base64

/**
 * The restricted Android container. The trusted host page (`mini-app-host.js`, the shared runtime and SDK) runs in
 * the main frame at a private origin and starts the app in a sandboxed frame with an opaque origin. The app reaches
 * the host only through that runtime; the host reaches the app through one MessagePort the main frame receives with
 * `postWebMessage`. The WebView makes no network request: every request but the host script is refused.
 */
@SuppressLint("SetJavaScriptEnabled")
class MiniAppWebHost(context: Context, private val session: MiniAppSession, private var dark: Boolean) : MiniAppRuntimeHandle {
    private val holder = MutableContextWrapper(context.applicationContext)
    val webView = WebView(holder)
    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val handler = Handler(Looper.getMainLooper())
    private var port: WebMessagePort? = null
    private val connected = CompletableDeferred<Unit>()
    private val commands = HashMap<Long, CompletableDeferred<Unit>>()
    private val calls = HashMap<Long, Job>()
    private var nextCommand = 0L
    private var loading: Job? = null
    private var stopped = false
    private var paused = false
    private val script: ByteArray by lazy { context.applicationContext.assets.open(SCRIPT).use { it.readBytes() } }
    private val tokensContext = context.applicationContext

    init {
        webView.settings.apply {
            javaScriptEnabled = true
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            domStorageEnabled = false
            databaseEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = true
            setGeolocationEnabled(false)
            cacheMode = WebSettings.LOAD_NO_CACHE
            builtInZoomControls = false
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, false)
        webView.setBackgroundColor(Color.TRANSPARENT)
        webView.isLongClickable = false
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()
    }

    /** The WebView belongs to [context] while the run screen shows it, and to the application while it is retained. */
    fun attach(context: Context) {
        holder.baseContext = context
    }

    fun detach() {
        (webView.parent as? ViewGroup)?.removeView(webView)
        holder.baseContext = holder.applicationContext
    }

    fun load() {
        webView.loadUrl("$ORIGIN/")
    }

    private fun begin() {
        if (loading != null || stopped) return
        loading = main.launch {
            try {
                val channel = webView.createWebMessageChannel()
                port = channel[0]
                channel[0].setWebMessageCallback(object : WebMessagePort.WebMessageCallback() {
                    override fun onMessage(port: WebMessagePort, message: WebMessage) = receive(message.data)
                }, handler)
                webView.postWebMessage(WebMessage("comma-native", arrayOf(channel[1])), Uri.parse(ORIGIN))
                withTimeout(STARTUP_MS) { connected.await() }
                command("install")
                command("start", JSONObject().put("init", session.initialization(dark, tokens(dark), java.util.Locale.getDefault().toLanguageTag(), java.util.TimeZone.getDefault().id)))
                val bundle = session.bundle()
                for (file in bundle.objects("files")) {
                    val path = file.text("path")
                    val mime = file.text("mime")
                    val bytes = CoreBytes.read(file.opt("data"))
                    if (path == null || mime == null || bytes == null) throw CoreError("invalid", "The app bundle is invalid.")
                    command("begin", JSONObject().put("path", path).put("mime", mime))
                    var offset = 0
                    while (offset < bytes.size) {
                        val end = minOf(offset + CHUNK_BYTES, bytes.size)
                        command("append", JSONObject().put("encoded", Base64.getEncoder().encodeToString(bytes.copyOfRange(offset, end))))
                        offset = end
                    }
                    command("end")
                }
                command("finish")
                if (!stopped) session.started()
            } catch (error: CancellationException) {
                if (!stopped) {
                    session.failed(CoreError("unavailable", "The app runtime did not start."))
                }
            } catch (error: Exception) {
                if (!stopped) session.failed(error)
            }
        }
    }

    /** Runs one host command and waits until the page did it. */
    private suspend fun command(op: String, args: JSONObject = JSONObject()) {
        if (stopped) throw CancellationException("The app closed.")
        val id = ++nextCommand
        val done = CompletableDeferred<Unit>()
        commands[id] = done
        port?.postMessage(WebMessage(JSONObject().put("kind", "command").put("id", id).put("op", op).put("args", args).toString()))
        try {
            done.await()
        } finally {
            commands.remove(id)
        }
    }

    private fun receive(data: String?) {
        if (stopped) return
        val message = runCatching { JSONObject(data ?: return) }.getOrNull() ?: return
        val id = message.optLong("id", -1)
        when (message.optString("kind")) {
            "connected" -> connected.complete(Unit)
            "done" -> {
                val done = commands[id] ?: return
                val error = message.text("error")
                if (error == null) done.complete(Unit) else done.completeExceptionally(CoreError("unavailable", error))
            }
            "invoke" -> invoke(id, message.text("wire"))
        }
    }

    private fun invoke(id: Long, wire: String?) {
        if (id < 0 || calls.containsKey(id)) return
        val request = wire?.takeIf { calls.size < MAX_CALLS && it.length <= MAX_CALL_CHARS }?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (request == null) {
            reply(id, null, "The app call was refused.")
            return
        }
        calls[id] = main.launch {
            try {
                val answer = session.invoke(request)
                if (!stopped) reply(id, answer, null)
            } catch (_: CancellationException) {
                if (!stopped) reply(id, null, "The app closed.")
            } finally {
                calls.remove(id)
            }
        }
    }

    private fun reply(id: Long, answer: JSONObject?, error: String?) {
        val message = JSONObject().put("kind", "reply").put("id", id)
        if (error != null) message.put("error", error) else message.put("answer", answer)
        port?.postMessage(WebMessage(message.toString()))
    }

    fun updateTheme(dark: Boolean) {
        this.dark = dark
        if (stopped || port == null) return
        main.launch {
            runCatching {
                command("theme", JSONObject().put("theme", if (dark) "dark" else "light").put("tokens", JSONObject(tokens(dark))))
            }
        }
    }

    /** The design tokens the shared runtime exposes as CSS variables, resolved for [dark]. */
    private fun tokens(dark: Boolean): Map<String, String> = NativeWebTokens.values(tokensContext, dark)

    override fun suspend() {
        if (stopped || paused) return
        paused = true
        webView.onPause()
    }

    override fun resume() {
        if (stopped || !paused) return
        paused = false
        webView.onResume()
    }

    override fun stop() {
        if (stopped) return
        stopped = true
        loading?.cancel()
        calls.values.forEach(Job::cancel)
        calls.clear()
        commands.values.forEach { it.cancel() }
        commands.clear()
        // The page stops the frame and rejects its calls; nothing is replayed.
        runCatching { port?.postMessage(WebMessage(JSONObject().put("kind", "command").put("id", -1).put("op", "stop").toString())) }
        runCatching { port?.close() }
        port = null
        main.cancel()
        detach()
        webView.stopLoading()
        webView.webChromeClient = null
        webView.destroy()
        session.stop()
    }

    private inner class Client : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String?) = begin()

        /** No navigation leaves the container. Only the host page may put the runtime's blob document in its frame. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            request.isForMainFrame || request.url.scheme != "blob"

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val url = request.url.toString()
            // The WebView asks for the host page itself too, so the page and its script are both answered here.
            if (request.method == "GET" && request.isForMainFrame && url == "$ORIGIN/") {
                return WebResourceResponse("text/html", "utf-8", ByteArrayInputStream(PAGE.toByteArray()))
            }
            if (request.method == "GET" && !request.isForMainFrame && url == "$ORIGIN/$SCRIPT") {
                return WebResourceResponse("text/javascript", "utf-8", ByteArrayInputStream(script))
            }
            // Apps reach their backend through the core; the container itself makes no request.
            return WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            if (!stopped) session.failed(CoreError("unavailable", "The app stopped. Close it and open it again."))
            stop()
            return true
        }
    }

    private class Chrome : WebChromeClient() {
        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams) = false
        override fun onPermissionRequest(request: PermissionRequest) = request.deny()
        override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) =
            callback.invoke(origin, false, false)
        override fun onCreateWindow(view: WebView, dialog: Boolean, gesture: Boolean, message: android.os.Message) = false
        override fun onJsAlert(view: WebView, url: String?, message: String?, result: JsResult): Boolean = true.also { result.cancel() }
        override fun onJsConfirm(view: WebView, url: String?, message: String?, result: JsResult): Boolean = true.also { result.cancel() }
        override fun onJsPrompt(view: WebView, url: String?, message: String?, default: String?, result: JsPromptResult): Boolean =
            true.also { result.cancel() }
        override fun onJsBeforeUnload(view: WebView, url: String?, message: String?, result: JsResult): Boolean = true.also { result.confirm() }
        override fun onConsoleMessage(message: ConsoleMessage) = true
    }

    companion object {
        /** The host page's private origin. Nothing is fetched from it: the WebView answers its page and script itself. */
        const val ORIGIN = "https://mini-app-host.comma.invalid"
        private const val SCRIPT = "mini-app-host.js"
        private const val PAGE = "<!doctype html><html><head><meta charset=utf-8>" +
            "<meta name=viewport content='width=device-width,initial-scale=1,viewport-fit=cover'>" +
            "<script src='/$SCRIPT'></script></head><body><script>commaMiniAppAndroid.connect()</script></body></html>"
        private const val STARTUP_MS = 10_000L
        private const val CHUNK_BYTES = 48 * 1024
        private const val MAX_CALLS = 8
        private const val MAX_CALL_CHARS = 2 * 1024 * 1024
    }
}
