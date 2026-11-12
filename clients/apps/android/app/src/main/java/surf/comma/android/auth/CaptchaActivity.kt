package surf.comma.android.auth

import android.annotation.SuppressLint
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebResourceError
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/** One isolated hosted CAPTCHA page. No account bridge, bearer, file access, or callback navigation. */
class CaptchaActivity : ComponentActivity() {
    private var browser: WebView? = null
    private var operation: String? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        operation = intent.getStringExtra("operation")
        val request = operation?.let(CaptchaRequests.pending::get)
        if (request == null || !request.valid() || !WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) { settle(null); return }
        request.close = { settle(null) }
        val web = WebView(this)
        browser = web
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            setSupportMultipleWindows(false)
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        val uri = java.net.URI(request.url)
        val origin = "${uri.scheme}://${uri.host}" + if (uri.port >= 0) ":${uri.port}" else ""
        WebViewCompat.addWebMessageListener(web, "commaCaptcha", setOf(origin)) { _, message, source, mainFrame, _ ->
            request.message(source.toString(), mainFrame, message.data ?: "")?.let(::settle)
        }
        WebViewCompat.addDocumentStartJavaScript(web,
            "window.addEventListener('message',function(e){if(e.source===window&&e.origin===location.origin)commaCaptcha.postMessage(JSON.stringify(e.data))});",
            setOf(origin))
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, resource: WebResourceRequest): Boolean {
                if (resource.isForMainFrame) return resource.url.toString() != request.url
                val url = resource.url
                return !(url.toString() in setOf("about:blank", "about:srcdoc") ||
                    (url.scheme == "https" && url.host == "challenges.cloudflare.com"))
            }
            override fun shouldInterceptRequest(view: WebView, resource: WebResourceRequest): android.webkit.WebResourceResponse? {
                if (!resource.isForMainFrame || resource.url.toString() == request.url) return null
                return android.webkit.WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(),
                    java.io.ByteArrayInputStream(ByteArray(0)))
            }
            override fun onReceivedError(view: WebView, resource: WebResourceRequest, error: WebResourceError) {
                if (resource.isForMainFrame) settle(null)
            }
        }
        setContentView(web)
        web.loadUrl(request.url)
    }

    private fun settle(token: String?) {
        val current = operation?.let(CaptchaRequests.pending::remove)
        current?.close = null
        current?.complete?.invoke(token)
        browser?.stopLoading()
        finish()
    }

    override fun onDestroy() {
        operation?.let(CaptchaRequests.pending::remove)?.let { it.close = null; it.complete(null) }
        browser?.let { web ->
            web.stopLoading()
            WebViewCompat.removeWebMessageListener(web, "commaCaptcha")
            web.destroy()
        }
        browser = null
        super.onDestroy()
    }
}
