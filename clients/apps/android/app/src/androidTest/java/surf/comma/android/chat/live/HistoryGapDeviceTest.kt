package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.CueMessage
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File

/**
 * Offline device check of the chat list while a history gap fills (cached 1–100, newest 131–180,
 * then 101–130), with invented messages only: the row being read keeps its id and its place on
 * screen, and a reader following the newest messages stays on them.
 */
class HistoryGapDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(800); instrumentation.waitForIdleSync() }

    private lateinit var timeline: ChatTimelineView
    private var mapped: LiveTimeline? = null

    private fun message(seq: Long): CueMessage {
        val user = seq % 2 == 1L
        val json = JSONObject().put("message_id", "msg_fixture_$seq").put("seq", seq)
            .put("actor_type", if (user) "user" else "agent").put("kind", "message")
            .put("participant_id", if (user) "ptp_fixture_user" else "ptp_fixture_agent")
            .put("content", JSONArray().put(JSONObject().put("type", "text").put("text", "fixture message $seq\nsecond line")))
            .put("created_at", 1_700_000_000_000L + seq)
        if (user) json.put("client_request_id", "req-fixture-$seq") else json.put("agent_id", "agt_fixture")
        return CueMessage.parse(json)!!
    }

    private fun state(vararg ranges: LongRange) = ConversationState(conversationId = "cnv_fixture", timeline = buildList {
        ranges.forEachIndexed { index, range ->
            if (index > 0) add(TimelineEntry.Gap("gap:${range.first}"))
            range.forEach { seq ->
                val display = message(seq).display!!
                add(TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:msg_fixture_$seq", display))
            }
        }
    })

    private fun rowOf(seq: Long) = mapped!!.entryRows.getValue(if (seq % 2 == 1L) "r:req-fixture-$seq" else "m:msg_fixture_$seq")

    private fun submit(state: ConversationState) {
        val next = mapConversation(state, LiveLabels(historyGap = instrumentation.targetContext.getString(R.string.chat_history_gap)),
            replyActions = true)
        var width = 0
        main { width = timeline.width }
        val prepared = runBlocking {
            MessageLayoutPrecomputer().prepare(next.rows, viewportWidthPx = width,
                density = instrumentation.targetContext.resources.displayMetrics.density, fontScale = 1f, darkTheme = false)
        }
        mapped = next
        main { timeline.submitPrepared(prepared) }
        settle()
    }

    private fun anchor(): ChatTimelineView.VisibleAnchor {
        var anchor: ChatTimelineView.VisibleAnchor? = null
        main { anchor = timeline.visibleAnchor() }
        return requireNotNull(anchor)
    }

    private fun read(seq: Long): ChatTimelineView.VisibleAnchor {
        main { timeline.revealRow(rowOf(seq)) }
        settle()
        main { assertFalse(timeline.isPinnedToEnd()) }
        return anchor()
    }

    private fun assertStill(expected: ChatTimelineView.VisibleAnchor) {
        assertEquals("the row being read moved or left", expected, anchor())
        main { assertFalse("reading was turned into following", timeline.isPinnedToEnd()) }
    }

    private fun run(block: () -> Unit) = ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
        scenario.onActivity { activity ->
            timeline = ChatTimelineView(activity).apply { clipToPadding = false }
            activity.setContentView(FrameLayout(activity).apply {
                setBackgroundColor(activity.getColor(R.color.token_bg_primary))
                addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            })
        }
        settle()
        block()
    }

    @Test fun readingOldHistoryKeepsItsPlaceThroughTheGapAndTheFill() = run {
        submit(state(1L..100L))
        val anchor = read(40)
        val ids = (1L..100L).map(::rowOf)
        submit(state(1L..100L, 131L..180L))
        assertStill(anchor)
        assertEquals(ids, (1L..100L).map(::rowOf))
        assertEquals(1, mapped!!.rows.count { it.role == ChatRole.SYSTEM })
        submit(state(1L..180L))
        assertStill(anchor)
        assertEquals(ids, (1L..100L).map(::rowOf))
    }

    @Test fun readingTheNewestMessagesKeepsThemWhileTheGapFillsAbove() = run {
        submit(state(1L..100L, 131L..180L))
        // The gap row itself, just above the newest messages.
        main { timeline.revealRow(mapped!!.rows.single { it.role == ChatRole.SYSTEM }.id) }
        settle()
        capture("gap-open")
        val anchor = read(140)
        submit(state(1L..180L))
        assertStill(anchor)
        capture("gap-filled-reading")
    }

    @Test fun readingBetweenTwoGapsKeepsItsPlaceThroughBothFills() = run {
        submit(state(1L..100L, 131L..180L, 231L..280L))
        assertEquals(2, mapped!!.rows.count { it.role == ChatRole.SYSTEM })
        val anchor = read(150)
        submit(state(1L..100L, 131L..280L))
        assertStill(anchor)
        submit(state(1L..280L))
        assertStill(anchor)
        capture("two-gaps-filled-reading")
    }

    @Test fun followingTheNewestMessagesStaysOnThem() = run {
        submit(state(1L..100L))
        main { assertTrue(timeline.isPinnedToEnd()) }
        submit(state(1L..100L, 131L..180L))
        main {
            assertTrue(timeline.isPinnedToEnd())
            assertNotNull("the newest message is on screen", timeline.messageTopOnScreen(rowOf(180)))
        }
        submit(state(1L..180L))
        main {
            assertTrue(timeline.isPinnedToEnd())
            assertNotNull(timeline.messageTopOnScreen(rowOf(180)))
        }
        capture("gap-filled-following")
    }

    private fun capture(name: String) {
        val image = instrumentation.uiAutomation.takeScreenshot()
        val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "history-gap-check").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()
    }
}
