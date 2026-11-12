package surf.comma.android.voice.ui

import androidx.activity.ComponentActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.robolectric.Robolectric
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.auth.awaitState
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.FakeChatViewCore
import surf.comma.android.conversation.FakeSessions
import surf.comma.android.conversation.awaitState
import surf.comma.android.conversation.scope
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

    @Test fun `a main chat call never enters a task timeline when its dock observes the finished call`() = runBlocking {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.create()
            val lifetime = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val auth = TestAuthRepository(MemorySessions())
            AuthGraph.install(auth, lifetime)
            auth.start()
            auth.awaitState<AuthState.Login>()
            val views = mutableListOf<ChatView>()
            val screens = mutableListOf<LiveChatScreen>()
            suspend fun screen(id: String, embedded: Boolean): LiveChatScreen {
                val core = FakeChatViewCore().apply {
                    show(emptyList(), fields = JSONObject().put("conversation", JSONObject().put("id", id)))
                }
                val sessions = FakeSessions().apply { scopes.value = scope(1) }
                val view = ChatView(sessions, core, main = false).also { views += it }
                view.start()
                view.open(id)
                view.setForeground(true)
                view.awaitState { it.conversationId == id && it.cacheLoaded }
                return LiveChatScreen(activity, view, auth.state, retrySession = {}, onOpenAccount = {},
                    embedded = embedded).also { screens += it }
            }
            try {
                val main = screen("main", embedded = false)
                val task = screen("task", embedded = true)
                val over = CallControllerState(id = 9, call = CallState(phase = CallPhase.Ended, result = CallResult.Ended),
                    connectedAtElapsedRealtime = 1_000, endedAtElapsedRealtime = 43_000)
                // Both screens receive the same global event, also replayed when a dock opens later.
                val log = LiveChatScreen::class.java.getDeclaredMethod("logCall", CallControllerState::class.java)
                    .apply { isAccessible = true }
                log.invoke(main, over)
                log.invoke(task, over)
                log.invoke(task, over)
                val store = CallLogStore(activity)
                val mainRows = CallLog.withRecords(emptyList(), store.records("main"), "main", ::label)
                assertEquals(listOf("0:42 · Call ended"), mainRows.map { it.text })
                val taskRows = listOf(row(1, ChatRole.USER, 110_000).copy(conversationId = "task"))
                assertEquals(taskRows, CallLog.withRecords(taskRows, store.records("task"), "task", ::label))
            } finally {
                screens.forEach { it.release() }
                views.forEach { it.close() }
                lifetime.cancel()
            }
        }
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
