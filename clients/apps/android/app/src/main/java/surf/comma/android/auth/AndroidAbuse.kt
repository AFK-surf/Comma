package surf.comma.android.auth

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import org.json.JSONObject
import surf.comma.android.core.NativeAbuse
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** No account bearer crosses this adapter. Google's token is evidence for the server, never a local verdict. */
internal class AndroidAbuse(private val context: Context, private val audience: String) : NativeAbuse {
    private val main = Handler(Looper.getMainLooper())
    private val manager by lazy { IntegrityManagerFactory.createStandard(context) }
    private var prepared: Pair<Long, StandardIntegrityManager.StandardIntegrityTokenProvider>? = null

    override fun request(op: String, input: JSONObject, complete: (JSONObject?, String?) -> Unit): () -> Unit {
        val active = AtomicBoolean(true)
        val operation = UUID.randomUUID().toString()
        fun settle(value: JSONObject?, error: String?) {
            if (active.compareAndSet(true, false)) complete(value, error)
        }
        main.post {
            if (!active.get()) return@post
            if (op == "session.captcha") {
                try {
                    val request = CaptchaRequest(input.getString("url"), input.getString("challengeId"), audience) { token ->
                        settle(JSONObject().put("token", token ?: JSONObject.NULL), null)
                    }
                    check(request.valid()) { "The CAPTCHA address is invalid." }
                    CaptchaRequests.pending[operation] = request
                    context.startActivity(Intent(context, CaptchaActivity::class.java)
                        .putExtra("operation", operation).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (_: Exception) {
                    CaptchaRequests.pending.remove(operation)
                    settle(null, "CAPTCHA could not open.")
                }
            } else {
                try {
                    // Debug and staging package names cannot claim the Play-distributed application.
                    check(context.packageName == "surf.comma.android")
                    val project = input.getString("google_cloud_project_number").toLong().also { check(it > 0) }
                    val hash = requestHash(input.getString("id"), input.getString("secret"))
                    fun token(provider: StandardIntegrityManager.StandardIntegrityTokenProvider) {
                        if (!active.get()) return
                        provider.request(StandardIntegrityManager.StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
                            .addOnSuccessListener { result -> settle(JSONObject().put("provider", "play").put("play_token", result.token()), null) }
                            .addOnFailureListener { prepared = null; settle(null, "Play Integrity is unavailable.") }
                    }
                    val provider = prepared?.takeIf { it.first == project }?.second
                    if (provider != null) token(provider)
                    else manager.prepareIntegrityToken(StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
                        .setCloudProjectNumber(project).build())
                        .addOnSuccessListener { result ->
                            if (active.get()) { prepared = project to result; token(result) }
                        }
                        .addOnFailureListener { settle(null, "Play Integrity is unavailable.") }
                } catch (_: Exception) { settle(null, "Play Integrity is unavailable.") }
            }
        }
        return {
            active.set(false)
            main.post {
                CaptchaRequests.pending.remove(operation)?.close?.invoke()
            }
        }
    }

    companion object {
        internal fun requestHash(id: String, secret: String): String = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(MessageDigest.getInstance("SHA-256").digest("comma-abuse:$id:$secret".toByteArray(Charsets.UTF_8)))
    }
}

internal object CaptchaRequests {
    val pending = ConcurrentHashMap<String, CaptchaRequest>()
}

internal class CaptchaRequest(val url: String, val challengeId: String, private val audience: String,
                             val complete: (String?) -> Unit) {
    var close: (() -> Unit)? = null
    fun valid(): Boolean = runCatching {
        val uri = java.net.URI(url)
        val query = uri.rawQuery?.split("&")?.map { pair ->
            val parts = pair.split("=", limit = 2)
            check(parts.size == 2)
            java.net.URLDecoder.decode(parts[0], "UTF-8") to java.net.URLDecoder.decode(parts[1], "UTF-8")
        } ?: emptyList()
        sameOrigin(url, audience) && uri.rawUserInfo == null && uri.rawFragment == null &&
            uri.path == "/v1/comma/auth/captcha" && challengeId.isNotEmpty() && query.size == 2 &&
            query.toMap()["challenge_id"] == challengeId && query.toMap()["action"] in setOf("email_login", "registration")
    }.getOrDefault(false)

    fun message(source: String, mainFrame: Boolean, data: String): String? = runCatching {
        if (!mainFrame || !sameOrigin(source, url) || data.toByteArray().size > 8192) return null
        val body = JSONObject(data)
        if (body.optString("type") != "comma.captcha" || body.optString("challengeId") != challengeId) return null
        (body.opt("token") as? String)?.takeIf { it.isNotEmpty() && it.toByteArray().size <= 4096 }
    }.getOrNull()

    companion object {
        internal fun sameOrigin(left: String, right: String): Boolean {
            val a = java.net.URI(left)
            val b = java.net.URI(right)
            fun port(uri: java.net.URI) = if (uri.port >= 0) uri.port else if (uri.scheme == "https") 443 else 80
            return a.scheme in setOf("https", "http") && a.scheme == b.scheme && a.host != null && a.host == b.host && port(a) == port(b)
        }
    }
}
