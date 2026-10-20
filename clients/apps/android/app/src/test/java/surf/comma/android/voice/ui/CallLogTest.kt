package surf.comma.android.voice.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.voice.CallControllerState
import surf.comma.android.voice.CallPhase
import surf.comma.android.voice.CallResult
import surf.comma.android.voice.CallState

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CallLogTest {
    private fun row(id: Long, role: ChatRole, at: Long, kind: String? = null) =
        ChatMessage(id = id, conversationId = "c", turnId = "t$id", role = role, text = "m$id", createdAt = at, cardKind = kind)

    private fun label(record: CallRecord) = "${CallPresentation.duration(record.seconds)} · Call ended"

    @Test fun `a record lands before the first message sent after the call`() {
        val rows = listOf(row(1, ChatRole.USER, 100), row(2, ChatRole.AGENT, 110), row(3, ChatRole.USER, 300), row(4, ChatRole.AGENT, 310))
        val out = CallLog.withRecords(rows, listOf(CallRecord(9, 200, 133)), "c", ::label)
        assertEquals(listOf("m1", "m2", "2:13 · Call ended", "m3", "m4"), out.map { it.text })
        val call = out[2]
        assertEquals(ChatRole.USER, call.role)
        assertEquals(LiveRowKinds.CALL_LOG, call.cardKind)
    }

    @Test fun `the latest call goes last, ahead of a typing bubble`() {
        val rows = listOf(row(1, ChatRole.USER, 100), row(2, ChatRole.AGENT, 110, TimelineBlockKinds.LIVE_STATUS))
        val out = CallLog.withRecords(rows, listOf(CallRecord(9, 500, 5), CallRecord(8, 400, 65)), "c", ::label)
        assertEquals(listOf("m1", "1:05 · Call ended", "0:05 · Call ended", "m2"), out.map { it.text })
    }

    @Test fun `only a call that connected and is over is logged, for as long as it was connected`() {
        val over = CallControllerState(id = 4, busy = false, call = CallState(phase = CallPhase.Ended, result = CallResult.Ended),
            connectedAtElapsedRealtime = 10_000, endedAtElapsedRealtime = 143_900)
        assertEquals(CallRecord(4, 1_000_000 - 6_100, 133), CallLog.recordFor(over, nowElapsed = 150_000, nowMillis = 1_000_000))
        assertNull(CallLog.recordFor(over.copy(connectedAtElapsedRealtime = null), 150_000, 1_000_000))
        assertNull(CallLog.recordFor(over.copy(busy = true), 150_000, 1_000_000))
        assertNull(CallLog.recordFor(over.copy(id = 0), 150_000, 1_000_000))
    }

    @Test fun `the store keeps each call once per conversation`() {
        val store = CallLogStore(org.robolectric.RuntimeEnvironment.getApplication())
        assertTrue(store.add("c", CallRecord(1, 200, 5)))
        assertFalse(store.add("c", CallRecord(1, 200, 5)))
        assertTrue(store.add("c", CallRecord(2, 100, 7)))
        assertEquals(listOf(2L, 1L), store.records("c").map { it.callId })
        assertTrue(store.records("other").isEmpty())
    }
}
