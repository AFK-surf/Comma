package surf.comma.android.notify

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import surf.comma.android.auth.ConversationScope
import surf.comma.android.conversation.ConversationState
import surf.comma.android.core.CoreApi
import surf.comma.android.core.TopicValue

@OptIn(ExperimentalCoroutinesApi::class)
class ReplyNotificationsTest {
    private val chatState = MutableStateFlow(ConversationState())
    private val notices = MutableSharedFlow<AppendedNotice>(extraBufferCapacity = 16)
    private val holds = mutableListOf<Boolean>()
    private val scopes = MutableStateFlow<ConversationScope?>(null)
    private val signedOut = MutableStateFlow(false)
    private val appVisible = MutableStateFlow(true)
    private val poster = FakePoster()
    private val prefs = FakePrefs()
    private var serviceStarts = 0
    private val chat = object : ReplyNotifications.ChatStream {
        override val state get() = chatState
        override fun setBackgroundHold(hold: Boolean) { holds += hold }
    }

    private fun TestScope.controller() = ReplyNotifications(chat, notices, scopes, signedOut, appVisible, poster, prefs,
        startService = { serviceStarts++ }, scope = backgroundScope, clock = { testScheduler.currentTime })

    /** The chat is open on [held] with the user's message sent and the reply on its way. */
    private fun TestScope.waiting(held: ConversationScope = scope()): ReplyNotifications {
        scopes.value = held
        chatState.value = state(agentEntry(2), userEntry(3), awaiting = true, scope = held)
        return controller().also { it.chatShown() }
    }

    /** The user leaves the app: the chat stops, then the process is no longer visible. */
    private fun ReplyNotifications.leaveApp() {
        chatHidden()
        appVisible.value = false
    }

    @Test fun `leaving with a reply pending keeps receiving in a service until the reply lands`() = runTest(UnconfinedTestDispatcher()) {
        val held = scope()
        val replies = waiting(held)
        replies.leaveApp()
        assertEquals(listOf(true), holds)
        assertTrue(replies.serviceWanted.value)
        assertEquals(1, serviceStarts)

        // The Router's message lands: the core words its notice, posted as it comes.
        chatState.value = state(agentEntry(2), userEntry(3), agentEntry(4, "Here it is"), participant = "active",
            scope = held)
        notices.tryEmit(noticeOf(4, "Here it is"))
        assertEquals(listOf(ReplyNotice(ACCOUNT_A, CHAT, "Comma", "Here it is", "m:msg_test_4")), poster.posted)
        assertTrue(replies.serviceWanted.value)
        // The reply finishes with a step the core gives no notice: the notification already posted stands.
        chatState.value = state(agentEntry(2), userEntry(3), agentEntry(4, "Here it is"), agentEntry(5, "step"),
            scope = held)
        assertEquals(listOf(true, false), holds)
        assertFalse(replies.serviceWanted.value)
        assertEquals(1, poster.posted.size)
    }

    @Test fun `a reply's message that lands after the reply reported done is still received and posted`() = runTest(UnconfinedTestDispatcher()) {
        val held = scope()
        val replies = waiting(held)
        replies.leaveApp()
        chatState.value = state(agentEntry(2), userEntry(3), draftEntry(ended = true), participant = "stopped", scope = held)
        assertTrue(replies.serviceWanted.value)
        chatState.value = state(agentEntry(2), userEntry(3), agentEntry(4, "Done."), participant = "stopped", scope = held)
        notices.tryEmit(noticeOf(4, "Done."))
        assertEquals(listOf(true, false), holds)
        assertEquals(listOf("Done."), poster.posted.map { it.body })
    }

    @Test fun `another conversation's notice posts nothing`() = runTest(UnconfinedTestDispatcher()) {
        waiting().leaveApp()
        notices.tryEmit(noticeOf(4, chat = "cnv_test_other"))
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `a notice while the chat is on screen posts nothing`() = runTest(UnconfinedTestDispatcher()) {
        waiting()
        notices.tryEmit(noticeOf(4, "Here it is"))
        chatState.value = state(agentEntry(2), userEntry(3), agentEntry(4, "Here it is"), scope = scopes.value)
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `the core's notices are taken from chatAppended once each, from when they are followed`() = runTest {
        fun entry(seq: Long, vararg messages: String) = JSONObject().put("seq", seq)
            .put("target", JSONObject().put("workspaceId", "wsp_test").put("groupId", "grp_test_1").put("conversationId", CHAT))
            .put("notices", JSONArray(messages.map { id ->
                JSONObject().put("messageId", id).put("title", "Comma").put("body", "said $id").put("replyPlaceholder", "Reply")
            }))
        fun value(vararg entries: JSONObject) = JSONObject().put("appended", JSONArray(entries.toList()))
        val values = listOf(
            // Kept before this followed: old news.
            value(entry(1, "m1")),
            value(entry(1, "m1"), entry(2, "m2", "m3")),
            // The core started again and counts from 0.
            value(entry(1, "m9")),
            value(entry(1, "m9"), entry(2, "m10")),
        )
        val core = object : CoreApi {
            override suspend fun call(name: String, params: JSONObject): Any? = null
            override fun <T> subscribe(topic: JSONObject, read: (Any?) -> T): Flow<TopicValue<T>> {
                assertEquals("chatAppended", topic.getString("topic"))
                return kotlinx.coroutines.flow.flowOf(*values.toTypedArray()).map { TopicValue.Value(read(it)) }
            }
        }
        assertEquals(listOf("m2", "m3", "m10"), appendedNotices(core).toList().map { it.messageId })
        assertEquals(AppendedNotice("grp_test_1", CHAT, "m10", "Comma", "said m10"), appendedNotices(core).toList().last())
    }

    @Test fun `leaving with nothing pending does not receive in the background`() = runTest(UnconfinedTestDispatcher()) {
        scopes.value = scope()
        chatState.value = state(userEntry(1), agentEntry(2))
        val replies = controller()
        replies.chatShown()
        replies.leaveApp()
        assertTrue(holds.isEmpty())
        assertFalse(replies.serviceWanted.value)
        assertEquals(0, serviceStarts)
    }

    @Test fun `receiving stops after 20 minutes without a reply`() = runTest {
        val replies = waiting()
        replies.leaveApp()
        runCurrent()
        assertTrue(replies.serviceWanted.value)
        advanceTimeBy(ReplyWatch.WINDOW_MILLIS - 1)
        runCurrent()
        assertTrue(replies.serviceWanted.value)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(true, false), holds)
        assertFalse(replies.serviceWanted.value)
        chatState.value = state(userEntry(3), agentEntry(4), scope = scopes.value)
        runCurrent()
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `hidden only behind another screen of the app holds without a service`() = runTest(UnconfinedTestDispatcher()) {
        val replies = waiting()
        replies.chatHidden()
        assertEquals(listOf(true), holds)
        assertFalse(replies.serviceWanted.value)
        appVisible.value = false
        assertTrue(replies.serviceWanted.value)
        appVisible.value = true
        assertFalse(replies.serviceWanted.value)
    }

    @Test fun `no notification when the chat is back on screen before the reply lands`() = runTest(UnconfinedTestDispatcher()) {
        val held = scope()
        val replies = waiting(held)
        replies.leaveApp()
        appVisible.value = true
        replies.chatShown()
        assertEquals(listOf(true, false), holds)
        chatState.value = state(userEntry(3), agentEntry(4), scope = held)
        notices.tryEmit(noticeOf(4))
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `opening the chat removes its notification, also when its data loads later`() = runTest(UnconfinedTestDispatcher()) {
        val replies = controller()
        replies.chatShown()
        assertTrue(poster.cancelled.isEmpty())
        chatState.value = state(userEntry(1), agentEntry(2), scope = scope())
        assertEquals(listOf(accountTag(ACCOUNT_A) to CHAT), poster.cancelled)
        chatState.value = state(userEntry(1), agentEntry(2), agentEntry(4), scope = chatState.value.scope)
        assertEquals(1, poster.cancelled.size)
    }

    @Test fun `signing out stops receiving and clears every notification`() = runTest(UnconfinedTestDispatcher()) {
        val replies = waiting()
        replies.leaveApp()
        poster.cancelledAll.clear()
        scopes.value = null
        assertEquals(listOf(true, false), holds)
        assertFalse(replies.serviceWanted.value)
        assertEquals(listOf<String?>(null), poster.cancelledAll)
        // A late notice of the old account must not notify.
        chatState.value = state(userEntry(3), agentEntry(4), scope = scope())
        notices.tryEmit(noticeOf(4))
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `a signed-out session found at start clears leftover notifications`() = runTest(UnconfinedTestDispatcher()) {
        controller()
        signedOut.value = true
        assertEquals(listOf<String?>(null), poster.cancelledAll)
    }

    @Test fun `switching accounts stops receiving and keeps only the new account's notifications`() = runTest(UnconfinedTestDispatcher()) {
        val replies = waiting()
        replies.leaveApp()
        poster.cancelledAll.clear()
        scopes.value = scope(2, ACCOUNT_B)
        assertEquals(listOf(true, false), holds)
        assertEquals(listOf<String?>(accountTag(ACCOUNT_B)), poster.cancelledAll)
    }

    @Test fun `turned off in settings, nothing is held or posted`() = runTest(UnconfinedTestDispatcher()) {
        prefs.enabled = false
        val replies = waiting()
        replies.leaveApp()
        assertTrue(holds.isEmpty())
        replies.setEnabled(true)
        replies.chatShown()
        replies.leaveApp()
        assertEquals(listOf(true), holds)
        replies.setEnabled(false)
        assertEquals(listOf(true, false), holds)
        notices.tryEmit(noticeOf(4))
        assertTrue(poster.posted.isEmpty())
    }

    @Test fun `the permission is asked once, after the first time a reply was left waiting`() = runTest(UnconfinedTestDispatcher()) {
        poster.granted = false
        val replies = waiting()
        assertFalse(replies.shouldAskPermission())
        // Not asked yet: the first hold still runs.
        replies.leaveApp()
        assertEquals(listOf(true), holds)
        appVisible.value = true
        replies.chatShown()
        assertTrue(replies.shouldAskPermission())
        replies.permissionAsked()
        assertFalse(replies.shouldAskPermission())
        // Denied: no more background receiving that could not notify anyway.
        replies.leaveApp()
        assertEquals(listOf(true, false), holds)
    }

    @Test fun `a notification link opens only the signed-in account's chat`() = runTest(UnconfinedTestDispatcher()) {
        scopes.value = scope()
        val replies = controller()
        val link = ReplyLink(accountTag(ACCOUNT_A), CHAT, "m:msg_test_4")
        assertEquals("m:msg_test_4", replies.target(link))
        assertEquals(listOf(accountTag(ACCOUNT_A) to CHAT), poster.cancelled)
        assertNull(replies.target(ReplyLink(accountTag(ACCOUNT_B), CHAT, "m:msg_test_4")))
        assertNull(replies.target(ReplyLink(accountTag(ACCOUNT_A), "cnv_test_other", "m:msg_test_4")))
    }

    private class FakePoster : ReplyPoster {
        var granted = true
        val posted = mutableListOf<ReplyNotice>()
        val cancelled = mutableListOf<Pair<String, String>>()
        val cancelledAll = mutableListOf<String?>()
        override fun canPost() = granted
        override fun permissionGranted() = granted
        override fun post(notice: ReplyNotice) { posted += notice }
        override fun cancel(accountTag: String, conversationId: String) { cancelled += accountTag to conversationId }
        override fun cancelReplies(keepAccountTag: String?) { cancelledAll += keepAccountTag }
    }

    private class FakePrefs : ReplyPrefs {
        override var enabled = true
        override var asked = false
        override var leftWhileWaiting = false
    }
}
