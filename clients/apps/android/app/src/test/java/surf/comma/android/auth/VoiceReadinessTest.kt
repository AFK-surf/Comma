package surf.comma.android.auth

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class VoiceReadinessTest {
    private fun status(ready: Boolean, reason: String?) =
        JSONObject().put("readiness", JSONObject().put("ready", ready).put("reason", reason ?: JSONObject.NULL))

    @Test fun `ready means calls can be made`() = assertTrue(voiceReadiness(status(true, null)))

    @Test fun `missing phone lines do not stop a call from the app`() {
        assertTrue(voiceReadiness(status(false, "twilio_not_configured")))
        assertTrue(voiceReadiness(status(false, "no_platform_lines")))
    }

    @Test fun `the voice service itself not being ready hides calls`() {
        assertFalse(voiceReadiness(status(false, "disabled")))
        assertFalse(voiceReadiness(status(false, "not_configured")))
        assertFalse(voiceReadiness(JSONObject()))
    }
}
