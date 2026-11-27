package surf.comma.android.chat.render

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.SPEAKER_NOTICE
import surf.comma.android.chat.model.SPEAKER_PERSON
import surf.comma.android.chat.model.SPEAKER_WORKER
import java.util.concurrent.TimeUnit

// Invented test data only.
/**
 * In a Task every left-side row sits right of one avatar gutter, whatever view draws it: an Agent's bubble, another
 * person's bubble and a card share one left edge, and the account's own rows keep theirs. Only another person's
 * bubble was set in, so the left column was ragged; then a notice stayed centred across the whole page.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class SpeakerGutterTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val timeline = ChatTimelineView(activity)

    init {
        activity.setContentView(FrameLayout(activity).apply {
            addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        })
        settle()
    }

    private fun settle() = repeat(60) { ShadowLooper.idleMainLooper(16, TimeUnit.MILLISECONDS) }

    private fun row(id: Long, role: ChatRole, text: String, speaker: String? = null, cardKind: String? = null,
                    payload: String? = null, name: String? = null) =
        ChatMessage(id = id, conversationId = "c", turnId = "t", role = role, text = text, createdAt = id,
            cardKind = cardKind, cardPayload = payload, speaker = speaker, otherWriterName = name)

    @Test fun `an Agent's bubble, another person's bubble and a card and a notice share the gutter's left edge`() {
        val rows = listOf(
            row(1, ChatRole.USER, "mine"),
            row(2, ChatRole.AGENT, "the agent says", SPEAKER_WORKER),
            row(3, ChatRole.AGENT, "", SPEAKER_WORKER, LiveRowKinds.TASK_REF,
                LiveRowKinds.encode(LiveRowKinds.TaskRef("cnv_2", "Plan the trip", "in_progress", false))),
            row(4, ChatRole.AGENT, "theirs", SPEAKER_PERSON + "u2", name = "Maya"),
            row(5, ChatRole.SYSTEM, "A user cancelled this Task.", SPEAKER_NOTICE),
        )
        val prepared = runBlocking {
            MessageLayoutPrecomputer(bubbles = false).prepare(rows, viewportWidthPx = timeline.width, density = density,
                fontScale = 1f, darkTheme = false)
        }
        timeline.submitPrepared(prepared)
        settle()
        val gutter = (MessageLayoutPrecomputer.SPEAKER_GUTTER_DP * density).toInt()
        val lefts = (0 until timeline.childCount).associate { index ->
            val child = timeline.getChildAt(index)
            timeline.getChildItemId(child) to child.left
        }
        assertEquals(mapOf(1L to 0, 2L to gutter, 3L to gutter, 4L to gutter, 5L to gutter), lefts)
        // The rows are laid out in what the gutter leaves, with one side margin, so their content starts together.
        assertEquals(1, prepared.drop(1).map { it.sideMarginPx }.distinct().size)
        assertEquals(listOf(0, gutter, gutter, gutter, gutter), prepared.map { it.speakerGutterPx })
        // The notice starts on the bubbles' edge, not centred in the page.
        val notice = timeline.getChildAt(4) as ChatMessageCell
        assertEquals(prepared[4].sideMarginPx, notice.columnLeft())
    }
}
