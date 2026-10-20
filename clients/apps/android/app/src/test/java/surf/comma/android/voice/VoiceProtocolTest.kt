package surf.comma.android.voice

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VoiceProtocolTest {
    @Test fun encodesAllClientMessages() {
        val start = JSONObject(VoiceProtocol.start("1.2.3", "  Caller  "))
        assertEquals("session.start", start.getString("type"))
        assertEquals("pcm16_24k", start.getString("audio_format"))
        assertEquals("comma-android/1.2.3", start.getString("client"))
        assertEquals("Caller", start.getString("display_name"))
        assertFalse(JSONObject(VoiceProtocol.start("1", " ")).has("display_name"))
        assertEquals("a\"b", JSONObject(VoiceProtocol.played("a\"b")).getString("name"))
        assertEquals("session.end", JSONObject(VoiceProtocol.end()).getString("type"))
    }

    @Test fun decodesEveryServerMessageAndIgnoresExtensions() {
        assertEquals(VoiceMessage.Started("c", "pcm16_24k", 3600), VoiceProtocol.decode(
            """{"type":"session.started","call_id":"c","audio_format":"pcm16_24k","max_duration_s":3600,"future":42}"""))
        assertEquals(VoiceMessage.Clear, VoiceProtocol.decode("""{"type":"output.clear","future":true}"""))
        assertEquals(VoiceMessage.Mark("m"), VoiceProtocol.decode("""{"type":"output.mark","name":"m"}"""))
        val transcript = VoiceProtocol.decode("""{"type":"transcript","role":"agent","text":"hello","final":true}""") as VoiceMessage.Transcript
        assertEquals("agent", transcript.role)
        assertEquals("hello", transcript.text)
        assertTrue(transcript.final)
        assertEquals(VoiceMessage.Ended("completed", 1.2), VoiceProtocol.decode("""{"type":"session.ended","reason":"completed","duration_s":1.2}"""))
        assertEquals(VoiceMessage.Ended("completed", null), VoiceProtocol.decode("""{"type":"session.ended","reason":"completed"}"""))
        val error = VoiceProtocol.decode("""{"type":"error","code":4503,"message":"voice calls are disabled"}""") as VoiceMessage.Error
        assertEquals(4503, error.code)
        assertEquals(CallResult.Disabled, VoiceProtocol.result(error.code, error.message))
        assertNull(VoiceProtocol.decode("""{"type":"future.event","nested":{"anything":true}}"""))
        assertNull(VoiceProtocol.decode("not json"))
        assertNull(VoiceProtocol.decode("""{"type":"output.mark"}"""))
        assertNull(VoiceProtocol.decode(" ".repeat(16_385)))
    }

    @Test fun mapsAllCloseAndHandshakeCodes() {
        val codes = mapOf(1000 to CallResult.Ended, 4401 to CallResult.CredentialsExpired,
            401 to CallResult.CredentialsExpired, 4409 to CallResult.Busy, 409 to CallResult.Busy,
            4503 to CallResult.Unavailable, 503 to CallResult.Unavailable, 4400 to CallResult.Interrupted,
            4408 to CallResult.Interrupted, 4410 to CallResult.Interrupted, 1006 to CallResult.Interrupted)
        codes.forEach { (code, result) -> assertEquals("code $code", result, VoiceProtocol.result(code)) }
        assertEquals(CallResult.Disabled, VoiceProtocol.result(503, "disabled"))
        assertEquals(CallResult.Disabled, VoiceProtocol.result(4503, "disabled"))
        assertEquals(CallResult.Interrupted, VoiceProtocol.result(null))
        assertEquals(CallResult.CredentialsExpired, VoiceProtocol.endedResult("revoked"))
        assertEquals(CallResult.Unavailable, VoiceProtocol.endedResult("model_error"))
        assertEquals(CallResult.Unavailable, VoiceProtocol.endedResult("attach_timeout"))
        assertEquals(CallResult.Unavailable, VoiceProtocol.endedResult("billing_unavailable"))
        assertEquals(CallResult.Interrupted, VoiceProtocol.endedResult("other"))
        listOf("completed", "caller_hangup", "agent_hangup", "max_duration", "future_reason").forEach {
            assertEquals(it, CallResult.Ended, VoiceProtocol.endedResult(it))
        }
        assertEquals(CallResult.Unavailable, VoiceProtocol.errorResult(1000, "Billing is unavailable."))
        assertEquals(CallResult.Disabled, VoiceProtocol.errorResult(4503, "voice calls are disabled"))
        assertEquals(CallResult.Interrupted, VoiceProtocol.closeResult(4410, "slow_reader"))
        assertEquals(CallResult.Unavailable, VoiceProtocol.closeResult(1000, "attach_timeout"))
        assertEquals(CallResult.Ended, VoiceProtocol.closeResult(1000, ""))
        assertEquals(CallResult.Unavailable, VoiceProtocol.closeResult(4503, "free text"))
        assertEquals("unrecognized", VoiceProtocol.diagnosticReason("free text"))
    }

    @Test fun audioLimitsAreWholePcmSamples() {
        listOf(0, 2, 960, 16_384).forEach { assertTrue(VoiceProtocol.validAudio(it)) }
        listOf(-1, 1, 959, 16_385, 16_386).forEach { assertFalse(VoiceProtocol.validAudio(it)) }
    }
}
