package surf.comma.android.core

import okhttp3.OkHttpClient
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch

class AbuseHostTest {
    @get:Rule val folder = TemporaryFolder()
    private val sealer = object : Sealer {
        override fun seal(plaintext: ByteArray) = plaintext
        override fun open(sealed: ByteArray) = sealed
    }
    private fun host(abuse: NativeAbuse? = null): CoreHost {
        val custody = SessionCustody(folder.newFile().also { it.delete() }, sealer, "https://api.example.test")
        return CoreHost(OkHttpClient(), custody, folder.newFolder(), GoogleIdTokens { _, _ -> null },
            HostDownloads(folder.newFolder()), abuse = abuse)
    }
    private class Answer : CoreHostOps.Reply {
        val ready = CountDownLatch(1)
        var value: JSONObject? = null
        var failure: String? = null
        override fun ok(json: JSONObject, bytes: ByteArray?) { value = json; ready.countDown() }
        override fun fail(message: String) { failure = message; ready.countDown() }
    }

    @Test fun cancelledCaptchaClosesNativePresentationAndLateTokenCannotAnswerAnotherOperation() {
        var completion: ((JSONObject?, String?) -> Unit)? = null
        var closed = false
        val host = host(NativeAbuse { _, _, reply -> completion = reply; { closed = true } })
        val answer = Answer()
        host.call("session.captcha", 7, JSONObject().put("url", "public"), null, answer)
        host.call("abort", 8, JSONObject().put("id", 7), null, Answer())
        assertTrue(closed)
        completion!!(JSONObject().put("token", "late"), null)
        assertEquals(1L, answer.ready.count)
        assertNull(answer.value)
    }

    @Test fun digestBatchRunsRealSha256WithTheSharedCodecVector() {
        val answer = Answer()
        host().call("session.sha256", 1, JSONObject().put("inputs", JSONArray().put("comma-abuse:abuse_test_abc:def-123_")), null, answer)
        answer.ready.await()
        assertNull(answer.failure)
        assertEquals("ANXFocPkUQ/LX7KyQxSCRaioeYYkLVf93yzqCtDUfQU=", answer.value!!.getJSONArray("digests").getString(0))
    }
}
