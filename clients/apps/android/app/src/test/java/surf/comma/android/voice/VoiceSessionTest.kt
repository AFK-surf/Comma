package surf.comma.android.voice

import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Delay
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** A call against [MemoryVoiceServer] on a virtual clock: time passes only when a test says so. */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceSessionTest {
    private val scheduler = TestCoroutineScheduler()
    private val server = MemoryVoiceServer()
    private val sessions = mutableListOf<VoiceSession>()
    private val started = """{"type":"session.started","call_id":"c","audio_format":"pcm16_24k","max_duration_s":3600}"""

    @After fun after() {
        sessions.forEach { it.close() }
        settle()
    }

    private inner class Credentials : VoiceCredentials {
        var invalidations = 0
        var fetches = 0
        override suspend fun endpoint(): VoiceEndpoint {
            fetches++
            return VoiceEndpoint("https://voice.test/issued/session", "https://voice.test/issued/readiness",
                "private-voice-$invalidations")
        }
        override suspend fun invalidate() { invalidations++ }
    }
    private class Sink : PlaybackSink {
        val audio = mutableListOf<ByteArray>()
        val marks = mutableListOf<Pair<String, () -> Unit>>()
        var clears = 0
        override fun audio(pcm: ByteArray) { audio += pcm }
        override fun mark(name: String, onPlayed: () -> Unit) { marks += name to onPlayed }
        override fun clear() { clears++ }
    }

    private fun call(
        sink: PlaybackSink = Sink(),
        credentials: VoiceCredentials = Credentials(),
        dispatcher: CoroutineDispatcher = StandardTestDispatcher(scheduler),
    ): VoiceSession =
        VoiceSession(credentials, sink, "1.2.3", null, OkHttpClient(), CoroutineScope(dispatcher),
            server.calls, server.sockets, { scheduler.currentTime * 1_000_000 })
            .also { sessions += it; it.start(); settle() }

    /** Runs what is due now and what the network has for the call, until neither has more. */
    private fun settle() {
        do scheduler.runCurrent() while (server.deliver())
    }

    /** Lets [millis] of time pass. */
    private fun pass(millis: Long) {
        scheduler.advanceTimeBy(millis)
        settle()
    }

    private fun texts(peer: MemoryVoiceServer.Peer): List<JSONObject> =
        generateSequence { peer.text.pollFirst() }.map(::JSONObject).toList()

    @Test fun handshakeAndImmediateStartPrecedePacedAudio() {
        val peer = server.upgrade()
        val call = call()
        val start = peer.nextText()
        assertEquals("session.start", start.getString("type"))
        assertEquals("comma-android/1.2.3", start.getString("client"))
        assertEquals("pcm16_24k", start.getString("audio_format"))
        val (readiness, handshake) = server.requests
        assertEquals("/issued/readiness", readiness.url.encodedPath)
        assertEquals("/issued/session", handshake.url.encodedPath)
        assertEquals("comma.voice.v1", handshake.header("Sec-WebSocket-Protocol"))
        assertEquals("Bearer private-voice-0", handshake.header("Authorization"))
        assertEquals(20_000, call.client.pingIntervalMillis)
        // Audio follows the start, one 20 ms frame of silence at a time.
        assertTrue(peer.audio.isEmpty())
        pass(19)
        assertTrue(peer.audio.isEmpty())
        pass(1)
        assertEquals(1, peer.audio.size)
        pass(380)
        assertEquals(20, peer.audio.size)
        peer.audio.forEach { assertEquals(960, it.size); assertTrue(it.toByteArray().all { b -> b == 0.toByte() }) }
    }

    @Test fun redirectsAreNotFollowedSoTheVoiceBearerStaysWithTheVoiceServer() {
        val call = call()
        assertFalse(call.client.followRedirects)
        assertFalse(call.client.followSslRedirects)
    }

    @Test fun microphoneFramesAreCopiedBoundedAndSilenceContinuesWhileMuted() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        assertFalse(call.offerAudio(ByteArray(959)))
        assertFalse(call.offerAudio(ByteArray(16_386)))
        val input = ByteArray(960) { 9 }
        assertTrue(call.offerAudio(input))
        input.fill(1)
        pass(20)
        assertTrue(peer.nextAudio().toByteArray().all { it == 9.toByte() })
        call.setMuted(true)
        assertFalse(call.offerAudio(ByteArray(960)))
        pass(60)
        repeat(3) {
            val bytes = peer.nextAudio()
            assertEquals(960, bytes.size)
            assertTrue(bytes.toByteArray().all { b -> b == 0.toByte() })
        }
    }

    /** Wakes every delay a millisecond late, as a busy device does. */
    @OptIn(InternalCoroutinesApi::class)
    private class LateWakes(private val inner: CoroutineDispatcher) : CoroutineDispatcher(), Delay {
        override fun isDispatchNeeded(context: CoroutineContext) = inner.isDispatchNeeded(context)
        override fun dispatch(context: CoroutineContext, block: Runnable) = inner.dispatch(context, block)
        override fun scheduleResumeAfterDelay(timeMillis: Long, continuation: CancellableContinuation<Unit>) =
            (inner as Delay).scheduleResumeAfterDelay(timeMillis + 1, continuation)
    }

    @Test fun uplinkKeepsTimeSoAMicrophoneOnItsOwnClockLosesNoFrames() {
        val peer = server.upgrade()
        // Each frame's wait ends late; the uplink keeps to its schedule anyway.
        val call = call(dispatcher = LateWakes(StandardTestDispatcher(scheduler)))
        peer.nextText()
        // The microphone delivers a frame every 20 ms, 7 ms out of step with the uplink, as AudioRecord does.
        pass(7)
        repeat(250) {
            call.offerAudio(ByteArray(960) { 9 })
            pass(20)
        }
        val uplink = call.uplink()
        assertEquals("microphone frames dropped: $uplink", 0L, uplink.droppedMic)
        assertEquals("frames sent: $uplink", 250L, uplink.sent)
        assertEquals(250, peer.audio.count { it[0] == 9.toByte() })
    }

    @Test fun anUplinkStallSkipsFramesInsteadOfEndingTheCallAndSendingResumesAfterIt() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        // The network takes nothing; frames back up in the socket's queue until it holds 1 s of audio.
        peer.socket.stalled = true
        pass(20L * 76)
        assertEquals(CallPhase.Calling, call.state.value.phase)
        assertEquals(25L, call.uplink().stalled)
        assertTrue(call.playbackReceipts().socketQueuedBytes <= 48_000L + VoiceProtocol.FRAME_BYTES * 2)
        val sentDuringStall = call.uplink().sent
        peer.drain()
        pass(20L * 30)
        assertEquals(sentDuringStall + 30, call.uplink().sent)
        assertEquals(CallPhase.Calling, call.state.value.phase)
    }

    @Test fun startedAloneDoesNotConnectAndFirstAudioDoes() {
        val peer = server.upgrade()
        val sink = Sink()
        val call = call(sink)
        peer.nextText()
        peer.send(started)
        settle()
        assertNotNull(call.state.value.started)
        assertEquals(CallPhase.Calling, call.state.value.phase)
        peer.pcm()
        settle()
        assertEquals(listOf(960), sink.audio.map { it.size })
        assertEquals(CallPhase.Connected, call.state.value.phase)
    }

    @Test fun firstAudioBeforeStartedStillNeedsStarted() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        peer.pcm()
        settle()
        assertTrue(call.state.value.receivedAudio)
        assertEquals(CallPhase.Calling, call.state.value.phase)
        peer.send(started)
        settle()
        assertEquals(CallPhase.Connected, call.state.value.phase)
    }

    @Test fun playbackReportsAreCumulativeOrderedAndClearAcknowledgesDiscardedMarksImmediately() {
        val peer = server.upgrade()
        val sink = Sink()
        val call = call(sink)
        peer.nextText()
        peer.pcm()
        peer.send("""{"type":"output.mark","name":"one"}""")
        peer.send("""{"type":"output.mark","name":"two"}""")
        settle()
        val (one, two) = sink.marks.map { it.second }
        assertEquals(emptyList<JSONObject>(), texts(peer))
        val pending = call.playbackReceipts()
        assertEquals(2L, pending.received)
        assertEquals(0L, pending.acknowledged)
        assertEquals(2, pending.pending)
        two()
        assertEquals(listOf("one", "two"), texts(peer).map { it.getString("name") })
        assertEquals(2L, call.playbackReceipts().acknowledged)
        one()
        peer.send("""{"type":"output.mark","name":"three"}""")
        peer.send("""{"type":"output.mark","name":"four"}""")
        settle()
        val (three, four) = sink.marks.drop(2).map { it.second }
        val clears = sink.clears
        peer.send("""{"type":"output.clear"}""")
        settle()
        assertEquals(listOf("three", "four"), texts(peer).map { it.getString("name") })
        assertTrue(sink.clears > clears)
        assertEquals(4L, call.playbackReceipts().acknowledged)
        assertEquals(0, call.playbackReceipts().pending)
        three(); four()
        assertEquals(emptyList<JSONObject>(), texts(peer))
    }

    @Test fun latePlaybackCallbacksCannotAcknowledgeMarksOnANewGeneration() {
        val first = server.upgrade()
        val sink = Sink()
        val call = call(sink)
        first.nextText()
        first.send("""{"type":"output.mark","name":"same"}""")
        settle()
        val old = sink.marks.single().second
        first.send("""{"type":"session.ended","reason":"completed"}""")
        settle()
        assertEquals(CallPhase.Ended, call.state.value.phase)
        val second = server.upgrade()
        call.start()
        settle()
        second.nextText()
        second.send("""{"type":"output.mark","name":"same"}""")
        settle()
        val current = sink.marks.last().second
        old()
        assertEquals(emptyList<JSONObject>(), texts(second))
        current()
        assertEquals("same", second.nextText().getString("name"))
    }

    @Test fun handshake401RefreshesOnceAndUsesTheNewBearer() {
        val credentials = Credentials()
        server.ready()
        server.reply(401, "{}")
        val peer = server.upgrade()
        val call = call(credentials = credentials)
        peer.nextText()
        peer.send(started); peer.pcm()
        settle()
        assertEquals(CallPhase.Connected, call.state.value.phase)
        assertEquals(1, credentials.invalidations)
        assertEquals(2, credentials.fetches)
        assertEquals(2L, call.state.value.generation)
        assertEquals(listOf("Bearer private-voice-0", "Bearer private-voice-0", "Bearer private-voice-1",
            "Bearer private-voice-1"), server.requests.map { it.header("Authorization") })
    }

    @Test fun secondReadiness401FailsAndInvalidatesWithoutAThirdAttempt() {
        val credentials = Credentials()
        repeat(2) { server.reply(401, "{}") }
        val call = call(credentials = credentials)
        assertEquals(CallPhase.Failed, call.state.value.phase)
        assertEquals(CallResult.CredentialsExpired, call.state.value.result)
        assertEquals(2, credentials.invalidations)
        assertEquals(2, credentials.fetches)
        assertEquals(2, server.requests.size)
    }

    @Test fun revokedSocketRefreshesOnlyOnce() {
        val credentials = Credentials()
        val first = server.upgrade()
        val second = server.upgrade()
        val call = call(credentials = credentials)
        first.nextText()
        first.close(4401, "revoked")
        settle()
        second.nextText()
        second.close(4401, "revoked")
        settle()
        assertEquals(CallPhase.Failed, call.state.value.phase)
        assertEquals(CallResult.CredentialsExpired, call.state.value.result)
        assertEquals(2, credentials.fetches)
        assertEquals(2, credentials.invalidations)
    }

    @Test fun mapsWireCloseCodesAndNetworkFailure() {
        for ((code, reason, expected) in listOf(
            Triple(1000, "completed", CallResult.Ended), Triple(4400, "bad_frame", CallResult.Interrupted),
            Triple(4408, "idle_timeout", CallResult.Interrupted), Triple(4409, "busy", CallResult.Busy),
            Triple(4410, "slow_reader", CallResult.Interrupted), Triple(4503, "draining", CallResult.Unavailable),
            Triple(4503, "disabled", CallResult.Disabled), Triple(1000, "caller_hangup", CallResult.Ended),
            // 1000 is the server's code for every unmapped reason; the reason says whether it failed.
            Triple(1000, "attach_timeout", CallResult.Unavailable), Triple(1000, "billing_unavailable", CallResult.Unavailable),
            Triple(1000, "carrier_error", CallResult.Interrupted), Triple(1000, "other", CallResult.Interrupted),
        )) {
            val peer = server.upgrade()
            val call = call()
            peer.nextText()
            peer.close(code, reason)
            settle()
            assertEquals(if (expected == CallResult.Ended) CallPhase.Ended else CallPhase.Failed, call.state.value.phase)
            assertEquals("$code $reason", expected, call.state.value.result)
        }
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        peer.drop()
        settle()
        assertEquals(CallPhase.Failed, call.state.value.phase)
        assertEquals(CallResult.Interrupted, call.state.value.result)
    }

    @Test fun readinessPreventsBusyOrUnavailableCallsAndHandshakeErrorsMap() {
        listOf(
            (200 to """{"ready":true,"busy":true}""") to CallResult.Busy,
            (200 to """{"ready":false,"reason":"disabled"}""") to CallResult.Disabled,
            (503 to """{"error":"disabled"}""") to CallResult.Disabled,
        ).forEach { (response, result) ->
            server.reply(response.first, response.second)
            assertEquals(result, call().state.value.result)
        }
        listOf(409 to CallResult.Busy, 503 to CallResult.Unavailable).forEach { (code, result) ->
            server.ready()
            server.reply(code, "{}")
            assertEquals(result, call().state.value.result)
        }
        assertEquals(7, server.requests.size)
    }

    @Test fun rejectsUnnegotiatedProtocolAndInvalidDownlinkFrames() {
        server.upgrade(protocol = null)
        assertEquals(CallResult.Interrupted, call().state.value.result)
        listOf(1, 16_386).forEach { size ->
            val peer = server.upgrade()
            val call = call()
            peer.nextText()
            peer.pcm(size)
            settle()
            assertEquals(CallPhase.Failed, call.state.value.phase)
            assertEquals(CallResult.Interrupted, call.state.value.result)
        }
    }

    @Test fun serverErrorAndUnknownEventsAreHandledWithoutLeakingDiagnostics() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        peer.send("""{"type":"new.extension","value":1}""")
        settle()
        assertEquals(CallPhase.Calling, call.state.value.phase)
        peer.send("""{"type":"error","code":4503,"message":"voice calls are disabled"}""")
        settle()
        assertEquals(CallResult.Disabled, call.state.value.result)
        assertFalse(call.state.value.toString().contains("private-voice"))
    }

    @Test fun anErrorClosedWithANormalCodeIsStillAFailure() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        peer.send("""{"type":"error","code":1000,"message":"Billing is unavailable."}""")
        settle()
        assertEquals(CallPhase.Failed, call.state.value.phase)
        assertEquals(CallResult.Unavailable, call.state.value.result)
    }

    @Test fun endReasonsReachDiagnosticsOnlyFromTheKnownVocabulary() {
        for ((reason, logged) in listOf("draining" to "draining", "a reason with private text" to "unrecognized")) {
            val peer = server.upgrade()
            val call = call()
            peer.nextText()
            peer.send("""{"type":"session.ended","reason":"$reason","duration_s":1.0}""")
            settle()
            assertEquals(if (reason == "draining") CallPhase.Failed else CallPhase.Ended, call.state.value.phase)
            val diagnostic = call.diagnostics.replayCache.last()
            assertEquals(VoiceDiagnostic.Kind.SessionEnded, diagnostic.kind)
            assertEquals(logged, diagnostic.reason)
        }
    }

    @Test fun disabledHandshakeBodyIsPreservedAsACategory() {
        server.ready()
        server.reply(503, """{"error":"disabled"}""")
        assertEquals(CallResult.Disabled, call().state.value.result)
    }

    @Test fun error4410ThenCloseWithoutEndedTerminatesCallingAndEndingAtOnce() {
        listOf(false, true).forEach { hangup ->
            val peer = server.upgrade()
            val call = call()
            peer.nextText()
            if (hangup) {
                call.hangUp()
                assertEquals("session.end", peer.nextText().getString("type"))
            }
            peer.send("""{"type":"error","code":4410,"message":"the client stopped reading agent audio"}""")
            peer.close(4410, "slow_reader")
            // No time passes: the call ends without waiting out the hang-up's two seconds.
            settle()
            assertEquals(CallPhase.Failed, call.state.value.phase)
            assertEquals(CallResult.Interrupted, call.state.value.result)
            assertEquals(VoiceDiagnostic.Kind.ServerError, call.diagnostics.replayCache.last().kind)
            assertEquals(4410, call.diagnostics.replayCache.last().code)
        }
    }

    @Test fun revokedWhileEndingInvalidatesWithoutReopening() {
        val credentials = Credentials()
        val peer = server.upgrade()
        val call = call(credentials = credentials)
        peer.nextText()
        call.hangUp()
        assertEquals("session.end", peer.nextText().getString("type"))
        peer.close(4401, "revoked")
        settle()
        assertEquals(CallPhase.Failed, call.state.value.phase)
        assertEquals(CallResult.CredentialsExpired, call.state.value.result)
        assertEquals(1, credentials.invalidations)
        assertEquals(1, credentials.fetches)
    }

    @Test fun hangupWaitsForEndedAndIgnoresSubsequentSocketFailures() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        call.hangUp()
        assertEquals("session.end", peer.nextText().getString("type"))
        assertEquals(CallPhase.Ending, call.state.value.phase)
        peer.send("""{"type":"session.ended","reason":"caller_hangup","duration_s":2}""")
        settle()
        assertEquals(CallPhase.Ended, call.state.value.phase)
        assertEquals(CallResult.Ended, call.state.value.result)
        peer.close(1000, "")
        settle()
        assertEquals(CallPhase.Ended, call.state.value.phase)
    }

    @Test fun hangupTimesOutAfterTwoSecondsWithoutWaitingForServer() {
        val peer = server.upgrade()
        val call = call()
        peer.nextText()
        call.hangUp()
        assertEquals("session.end", peer.nextText().getString("type"))
        pass(1_999)
        assertEquals(CallPhase.Ending, call.state.value.phase)
        pass(1)
        assertEquals(CallPhase.Ended, call.state.value.phase)
    }

    @Test fun hangupDuringPreparationPreventsLateSocketCreation() {
        val gate = CompletableDeferred<VoiceEndpoint>()
        val credentials = object : VoiceCredentials {
            override suspend fun endpoint(): VoiceEndpoint = gate.await()
            override suspend fun invalidate() = Unit
        }
        val call = call(credentials = credentials)
        assertEquals(CallPhase.Preparing, call.state.value.phase)
        call.hangUp()
        settle()
        assertEquals(CallPhase.Ended, call.state.value.phase)
        gate.complete(VoiceEndpoint("https://voice.test/session", "https://voice.test/ready", "private"))
        settle()
        assertEquals(0, server.requests.size)
    }
}
