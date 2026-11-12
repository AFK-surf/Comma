package surf.comma.android.auth

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AbuseBoundaryTest {
    private val url = "https://api.example.test/v1/comma/auth/captcha?challenge_id=challenge&action=email_login"
    private fun request() = CaptchaRequest(url, "challenge", "https://api.example.test") {}
    private fun message(challenge: String = "challenge", token: String = "token") = JSONObject()
        .put("type", "comma.captcha").put("challengeId", challenge).put("token", token).toString()

    @Test fun acceptsOnlyTheActiveMainFrameAndExactOrigin() {
        val request = request()
        assertTrue(request.valid())
        assertEquals("token", request.message("https://api.example.test", true, message()))
        assertNull(request.message("https://api.example.test.evil.test", true, message()))
        assertNull(request.message("http://api.example.test", true, message()))
        assertNull(request.message("https://api.example.test:444", true, message()))
        assertNull(request.message("https://api.example.test", false, message()))
        assertNull(request.message("https://api.example.test", true, message("stale")))
        assertNull(request.message("https://api.example.test", true, message(token = "")))
        assertNull(request.message("https://api.example.test", true, message(token = "a".repeat(4097))))
    }

    @Test fun rejectsNavigationInputsOutsideTheHostedCaptcha() {
        assertFalse(CaptchaRequest("https://api.example.test/other", "challenge", "https://api.example.test") {}.valid())
        assertFalse(CaptchaRequest(url, "challenge", "https://other.test") {}.valid())
        assertFalse(CaptchaRequest("https://user@api.example.test/v1/comma/auth/captcha", "challenge", "https://api.example.test") {}.valid())
    }

    @Test fun playRequestHashUsesUtf8AndUnpaddedBase64url() {
        assertEquals("ANXFocPkUQ_LX7KyQxSCRaioeYYkLVf93yzqCtDUfQU", AndroidAbuse.requestHash("abuse_test_abc", "def-123_"))
        assertNotEquals(AndroidAbuse.requestHash("id", "secret"), AndroidAbuse.requestHash("other", "secret"))
    }
}
