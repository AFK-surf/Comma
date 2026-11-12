package surf.comma.android.dynamicui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
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
import org.json.JSONObject
import java.io.ByteArrayInputStream

/**
 * The Android Dynamic UI container. The trusted host page (`dynamic-ui-host.js`: the shared runtime and the host
 * iOS uses) runs in the main frame at a private origin and starts the widget in a sandboxed frame with an opaque
 * origin, under the runtime's CSP. Android's WebView has no isolated script world, so the app reaches the page only
 * through one MessagePort it gives the main frame's origin with `postWebMessage`; the frame cannot reach the main
 * frame's script, and the page forwards only the runtime messages the shared host allows. The page and its script are
 * answered from the app's assets; the main frame never navigates. The widget may load HTTPS images, styles, fonts and
 * scripts, as on iOS; any other request is refused.
 */
@SuppressLint("SetJavaScriptEnabled")
class DynamicUiWebHost(context: Context, private val onFrame: (DynamicUiFrame) -> Unit) {
    /** Read first: a build without the script fails here, before a WebView exists. */
    private val script: ByteArray = context.applicationContext.assets.open(SCRIPT).use { it.readBytes() }
    val webView = WebView(context)
    private val handler = Handler(Looper.getMainLooper())
    private var port: WebMessagePort? = null
    private var init: JSONObject? = null
    private var connected = false
    private var started = false
    private var stopped = false
    private val timeout = Runnable { if (!connected && !stopped) onFrame(DynamicUiFrame.Failed("Interactive content did not start.")) }

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
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()
    }

    /** Loads the host page and starts the widget with [init] once the page took the port. */
    fun start(init: JSONObject) {
        if (stopped || this.init != null) return
        this.init = init
        webView.loadUrl("$ORIGIN/")
        handler.postDelayed(timeout, STARTUP_MS)
    }

    private fun connect() {
        if (port != null || stopped) return
        val channel = webView.createWebMessageChannel()
        port = channel[0]
        channel[0].setWebMessageCallback(object : WebMessagePort.WebMessageCallback() {
            override fun onMessage(port: WebMessagePort, message: WebMessage) = receive(message.data)
        }, handler)
        webView.postWebMessage(WebMessage(HELLO, arrayOf(channel[1])), Uri.parse(ORIGIN))
    }

    private fun receive(data: String?) {
        if (stopped) return
        val frame = DynamicUiFrame.parse(data) ?: return
        if (frame == DynamicUiFrame.Connected) {
            if (connected) return
            connected = true
            handler.removeCallbacks(timeout)
            val start = init ?: return
            if (!started) {
                started = true
                port?.postMessage(WebMessage(JSONObject().put("kind", "start").put("init", start).toString()))
            }
            return
        }
        onFrame(frame)
    }

    fun stop() {
        if (stopped) return
        stopped = true
        handler.removeCallbacks(timeout)
        runCatching { port?.postMessage(WebMessage(JSONObject().put("kind", "stop").toString())) }
        runCatching { port?.close() }
        port = null
        webView.stopLoading()
        webView.webChromeClient = null
        webView.destroy()
    }

    private inner class Client : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String?) {
            if (url == "$ORIGIN/") connect()
        }

        /** No navigation leaves the container. Only the host page may put the runtime's blob document in its frame. */
        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            request.isForMainFrame || request.url.scheme != "blob"

        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
            when (route(request.method, request.url.toString(), request.isForMainFrame)) {
                Route.PAGE -> WebResourceResponse("text/html", "utf-8", 200, "OK",
                    mapOf("Content-Security-Policy" to PAGE_CSP, "Referrer-Policy" to "no-referrer"),
                    ByteArrayInputStream(PAGE.toByteArray()))
                Route.SCRIPT -> WebResourceResponse("text/javascript", "utf-8", ByteArrayInputStream(script))
                Route.NETWORK -> null
                Route.REFUSED ->
                    WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
            }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            if (!stopped) onFrame(DynamicUiFrame.Failed("Interactive content stopped."))
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

    enum class Route { PAGE, SCRIPT, NETWORK, REFUSED }

    companion object {
        /** The host page's private origin. Nothing is fetched from it: the WebView answers its page and script itself. */
        const val ORIGIN = "https://dynamic-ui-host.comma.invalid"
        private const val SCRIPT = "dynamic-ui-host.js"
        private const val HELLO = "comma-native"
        private const val STARTUP_MS = 10_000L

        /** The iOS host page's policy, and the page's own script. The runtime's frame adds the runtime's policy. */
        const val PAGE_CSP = "default-src 'none'; script-src 'self' 'unsafe-inline' https:; worker-src blob:; " +
            "style-src 'unsafe-inline' https:; img-src https:; font-src https:; frame-src blob:; connect-src 'none'; " +
            "form-action 'none'; base-uri 'none'"
        private const val PAGE = "<!doctype html><html><head><meta charset=utf-8>" +
            "<meta name=viewport content='width=device-width,initial-scale=1'>" +
            "<script src='/$SCRIPT'></script></head><body><script>commaDynamicUIAndroid.connect()</script></body></html>"

        /**
         * What answers one request: the fixed page (the main frame's only document), its script, the network for a
         * frame's HTTPS GET elsewhere (what the runtime's policy permits), or nothing.
         */
        fun route(method: String, url: String, mainFrame: Boolean): Route {
            if (method != "GET") return Route.REFUSED
            if (mainFrame) return if (url == "$ORIGIN/") Route.PAGE else Route.REFUSED
            if (url == "$ORIGIN/$SCRIPT") return Route.SCRIPT
            val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return Route.REFUSED
            val ours = java.net.URI(ORIGIN).host
            return if (uri.scheme == "https" && uri.rawUserInfo == null && !uri.host.isNullOrEmpty() && uri.host != ours)
                Route.NETWORK else Route.REFUSED
        }
    }
}
