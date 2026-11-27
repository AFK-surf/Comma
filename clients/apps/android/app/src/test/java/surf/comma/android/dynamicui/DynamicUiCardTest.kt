package surf.comma.android.dynamicui

import android.text.Layout
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRendererRegistry
import surf.comma.android.chat.render.MessageLayoutPrecomputer

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DynamicUiCardTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val screenWidth = activity.resources.displayMetrics.widthPixels
    private val density = activity.resources.displayMetrics.density
    private val precomputer = MessageLayoutPrecomputer(cardHeights = DynamicUiCardLayout(activity), bubbles = true)

    private val renderer = ChatCardRendererRegistry.forKind(LiveRowKinds.INTERACTIVE_SUMMARY)!!

    private fun card(summary: String, row: DynamicUiChatRow = renderer.create(activity) as DynamicUiChatRow): DynamicUiChatRow {
        val item = runBlocking {
            precomputer.prepare(listOf(ChatMessage(id = 1, conversationId = "c", role = ChatRole.AGENT, text = summary,
                createdAt = 0, cardKind = LiveRowKinds.INTERACTIVE_SUMMARY)), screenWidth, density, 1f, false).single()
        }
        return row.apply {
            renderer.bind(this, item)
            measure(View.MeasureSpec.makeMeasureSpec(screenWidth, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
            layout(0, 0, measuredWidth, measuredHeight)
        }
    }

    private val DynamicUiChatRow.box get() = getChildAt(0) as LinearLayout
    private val DynamicUiChatRow.summary get() = box.getChildAt(0) as TextView
    private val DynamicUiChatRow.chevron get() = box.getChildAt(1) as ImageView

    private fun DynamicUiChatRow.assertWhole() {
        val layout: Layout = summary.layout
        val last = layout.lineCount - 1
        assertEquals(0, layout.getEllipsisCount(last))
        // The last line itself, not only the view: a parent that squeezes the view would cut this line.
        val drawable = summary.height - summary.totalPaddingTop - summary.totalPaddingBottom
        assertTrue("last line ${layout.getLineBottom(last)} below text box $drawable", layout.getLineBottom(last) <= drawable)
        assertTrue("text ${summary.bottom} overflows card ${box.height}", summary.bottom <= box.height)
    }

    @Test fun `a long summary shows whole, with the chevron on its first line`() {
        val row = card(LONG)
        row.assertWhole()
        assertTrue(row.summary.lineCount > 2)
        // The middle of the first line's glyphs, not of its box, which carries the line spacing below them.
        val metrics = row.summary.paint.fontMetricsInt
        val firstLineMiddle = row.summary.top + row.summary.layout.getLineBaseline(0) + (metrics.ascent + metrics.descent) / 2
        val chevronMiddle = (row.chevron.top + row.chevron.bottom) / 2
        assertTrue("chevron $chevronMiddle vs first line $firstLineMiddle", kotlin.math.abs(chevronMiddle - firstLineMiddle) <= density * 2)
    }

    @Test fun `a row recycled from a short summary centres a long one`() {
        val row = card(LONG, card("香港本周末天气"))
        row.assertWhole()
        assertEquals(row.box.height - row.summary.bottom, row.summary.top, 2)
    }

    @Test fun `a short summary keeps the card's height and sits in its middle`() {
        val row = card("香港本周末天气")
        row.assertWhole()
        assertEquals((72 * density).toInt(), row.box.height, 1)
        assertEquals(row.box.height - row.summary.bottom, row.summary.top, 2)
    }

    private companion object {
        const val LONG = "香港本周末总体适合出门：11/21 周六阴天，12.6–20.5°C，降水概率 0%，降水量 0.0 mm，" +
            "风速最高 18 km/h；11/22 周日多云转晴，13.1–21.8°C，降水概率 5%，适合户外活动。"
    }

    private fun assertEquals(expected: Int, actual: Int, slack: Int) =
        assertTrue("expected $expected, was $actual", kotlin.math.abs(expected - actual) <= slack)
}
