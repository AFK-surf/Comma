package surf.comma.android.notify

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import surf.comma.android.MainActivity
import surf.comma.android.chat.live.mapConversation

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ReplyLinkTest {
    private val context = RuntimeEnvironment.getApplication()

    @Test fun `a reply link survives the intent and brings the chat to the front`() {
        val link = ReplyLink(accountTag(ACCOUNT_A), CHAT, "m:msg_test_4")
        val intent = link.intent(context)
        assertEquals(MainActivity::class.java.name, intent.component?.className)
        assertTrue(intent.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
        assertEquals(link, ReplyLink.from(intent))
    }

    @Test fun `anything but a complete reply link is ignored`() {
        assertNull(ReplyLink.from(null))
        assertNull(ReplyLink.from(Intent(context, MainActivity::class.java)))
        assertNull(ReplyLink.from(Intent(ReplyLink.ACTION).putExtra("reply.account", accountTag(ACCOUNT_A))))
    }

    @Test fun `the link carries no account id and routes only to its own account and chat`() {
        val link = ReplyLink.of(ReplyNotice(ACCOUNT_A, CHAT, "Comma", "hi", "m:msg_test_4"))
        val extras = link.intent(context).extras!!
        assertFalse(extras.keySet().any { extras.getString(it)?.contains(ACCOUNT_A) == true })
        assertEquals("m:msg_test_4", link.targetFor(scope()))
        assertNull(link.targetFor(scope(account = ACCOUNT_B)))
        assertNull(link.targetFor(scope(chat = "cnv_test_other")))
        assertNull(link.targetFor(null))
    }

    @Test fun `notification tags are per account and conversation`() {
        val tag = replyTag(accountTag(ACCOUNT_A), CHAT)
        assertEquals(accountTag(ACCOUNT_A), replyTagAccount(tag))
        assertNull(replyTagAccount("other"))
        assertNull(replyTagAccount(null))
    }

    @Test fun `a reply's entry key leads to its first row on the list`() {
        val timeline = mapConversation(state(userEntry(3), agentEntry(4, "first"), agentEntry(5, "second")))
        val row = timeline.entryRows.getValue("m:msg_test_4")
        assertEquals("first", timeline.rows.first { it.id == row }.text)
    }
}
