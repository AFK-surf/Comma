package surf.comma.android.chat.render

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Region
import android.view.View
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.live.LiveRowKinds
import kotlin.math.abs

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatBubblesTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val width = (411 * density).toInt()
    private fun dp(value: Float) = (value * density).toInt()

    private fun message(id: Long, role: ChatRole, text: String = "Hi", cardKind: String? = null,
                        status: MessageStatus = MessageStatus.COMPLETED) =
        ChatMessage(id, "c", "t", role, text, 0, status = status, cardKind = cardKind,
            // An agent's text as the core parsed it.
            markdown = if (role == ChatRole.AGENT && cardKind == null && text.isNotEmpty()) Md.of(text) else null)

    private fun prepare(vararg rows: ChatMessage, viewport: Int = width, fontScale: Float = 1f,
                        precomputer: MessageLayoutPrecomputer = MessageLayoutPrecomputer(bubbles = true)) =
        runBlocking { precomputer.prepare(rows.toList(), viewport, density, fontScale, false) }

    /** The widest a bubble may be: the row less both margins and 42 dp short of the far one. */
    private fun maxBubble(item: PreparedChatMessage, viewport: Int = width) =
        viewport - item.sideMarginPx * 2 - dp(42f)

    private fun bound(item: PreparedChatMessage, viewport: Int = width) = ChatMessageCell(activity).apply {
        bind(item)
        measure(View.MeasureSpec.makeMeasureSpec(viewport, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        layout(0, 0, measuredWidth, measuredHeight)
    }

    private fun drawn(item: PreparedChatMessage, viewport: Int = width): Bitmap {
        val cell = bound(item, viewport)
        return Bitmap.createBitmap(cell.width, cell.height, Bitmap.Config.ARGB_8888).also { cell.draw(Canvas(it)) }
    }

    private fun color(id: Int) = ContextCompat.getColor(activity, id)

    /** Left edge of the bubble in the row. */
    private fun bubbleLeft(item: PreparedChatMessage, viewport: Int = width) =
        if (item.message.role == ChatRole.USER) viewport - item.sideMarginPx - item.bubbleWidthPx else item.sideMarginPx

    @Test fun `both speakers get bubbles, and only the last of a run gets a tail`() {
        val rows = prepare(message(1, ChatRole.USER), message(2, ChatRole.USER),
            message(3, ChatRole.AGENT), message(4, ChatRole.AGENT))
        assertTrue(rows.all { it.drawBubble && it.tailable })
        assertEquals(listOf(false, true, false, true), rows.map { it.tailPx > 0 })
        assertTrue(rows.all { it.cornerRadiusPx == BubbleTail.RADIUS_DP * density })
        // The tail's room is below the bubble, inside the row.
        rows.filter { it.tailPx > 0 }.forEach {
            assertEquals(it.bubbleTopPx + it.bubbleHeightPx + it.tailPx, it.cellHeightPx)
            assertTrue(it.tailPx >= (BubbleTail.lowestDp * density).toInt())
        }
    }

    @Test fun `the typing bubble continues the agent's run, and its message takes the tail when it goes`() {
        val typing = message(3, ChatRole.AGENT, "", TimelineBlockKinds.LIVE_STATUS)
        val waiting = prepare(message(1, ChatRole.USER), message(2, ChatRole.AGENT), typing)
        assertEquals(0, waiting[1].tailPx)
        val precomputer = MessageLayoutPrecomputer(bubbles = true)
        val before = runBlocking { precomputer.prepare(listOf(message(1, ChatRole.USER), message(2, ChatRole.AGENT), typing),
            width, density, 1f, false) }
        val after = runBlocking { precomputer.prepareChanged(before, listOf(message(1, ChatRole.USER), message(2, ChatRole.AGENT)),
            width, density, 1f, false) }
        assertTrue(after[1].tailPx > 0)
        // Only the row's height below the bubble changed; the text was not laid out again.
        assertSame(before[1].blocks.first(), after[1].blocks.first())
        assertEquals(before[1].bubbleHeightPx, after[1].bubbleHeightPx)
        assertFalse(before[1].cacheKey == after[1].cacheKey)
        // Taking the tail away again gives back the same row.
        val again = runBlocking { precomputer.prepareChanged(after, listOf(message(1, ChatRole.USER), message(2, ChatRole.AGENT), typing),
            width, density, 1f, false) }
        assertEquals(before[1].cacheKey, again[1].cacheKey)
        assertEquals(before[1].cellHeightPx, again[1].cellHeightPx)
    }

    @Test fun `cards, attachments, reply buttons, status lines and gaps break a run and get no tail`() {
        val rows = prepare(message(1, ChatRole.AGENT), message(2, ChatRole.AGENT, "", LiveRowKinds.TASK_REF),
            message(3, ChatRole.AGENT), message(4, ChatRole.AGENT, "", LiveRowKinds.REPLY_ACTIONS),
            message(5, ChatRole.SYSTEM, "Loading missed messages…"),
            message(6, ChatRole.AGENT, "Something went wrong", TimelineBlockKinds.REPLY_ERROR, MessageStatus.FAILED))
        assertTrue(rows[0].tailPx > 0)
        assertTrue(rows[2].tailPx > 0)
        listOf(1, 3, 4, 5).forEach { assertEquals(0, rows[it].tailPx) }
        assertFalse("a gap is not an agent bubble", rows[4].tailable)
        assertFalse(rows[5].tailable)
    }

    @Test fun `short messages hug their text, long ones stop at the available width`() {
        for (role in listOf(ChatRole.USER, ChatRole.AGENT)) {
            val short = prepare(message(1, role, "Ok")).single()
            assertTrue("$role short ${short.bubbleWidthPx}", short.bubbleWidthPx < dp(80f))
            assertTrue(short.bubbleWidthPx >= dp(50f))
            val long = prepare(message(2, role, "word ".repeat(120))).single()
            assertTrue("$role long ${long.bubbleWidthPx}", long.bubbleWidthPx in maxBubble(long) - dp(48f)..maxBubble(long))
            val link = prepare(message(3, role, "https://example.org/" + "a".repeat(300))).single()
            assertTrue(link.bubbleWidthPx <= maxBubble(link))
            assertTrue(link.blocks.all { it !is PreparedContentBlock.Text || it.layout.width <= maxBubble(link) - link.horizontalPaddingPx * 2 })
        }
    }

    @Test fun `one agent message is one bubble, however many paragraphs and blocks it has`() {
        val text = "First paragraph.\n\n## A heading\n\n- one\n- two\n\n> quoted\n\n```kt\nval x = 1\n```\n\n" +
            "| A | B |\n|---|---|\n| 1 | 2 |\n\nLast paragraph."
        val rows = prepare(message(1, ChatRole.USER, "q"), message(2, ChatRole.AGENT, text))
        val reply = rows.last()
        assertTrue(reply.drawBubble)
        assertTrue(reply.blocks.size > 5)
        assertEquals(maxBubble(reply), reply.bubbleWidthPx)
        // Every block sits inside the bubble's padding.
        val top = reply.bubbleTopPx + reply.verticalPaddingPx
        val bottom = reply.bubbleTopPx + reply.bubbleHeightPx - reply.verticalPaddingPx
        reply.blocks.forEach { block ->
            assertTrue(block.yOffsetPx >= top)
            assertTrue(block.yOffsetPx + block.heightPx <= bottom)
        }
    }

    @Test fun `code, tables and images stay inside an agent bubble, and wide ones scroll inside it`() {
        val samples = listOf(
            "```kt\nval text = \"${"long ".repeat(40)}\"\n```",
            "| A | B | C |\n|---|---|---|\n| ${"long ".repeat(20)} | value | more |",
            "See this:\n\n![sample](https://example.org/sample.png)",
        )
        samples.forEachIndexed { index, text ->
            val row = prepare(message(index.toLong(), ChatRole.AGENT, text)).single()
            assertTrue(text, row.drawBubble)
            val inner = row.bubbleWidthPx - row.horizontalPaddingPx * 2
            row.blocks.forEach { block ->
                when (block) {
                    is PreparedContentBlock.Code -> assertTrue(block.viewportWidthPx <= inner)
                    is PreparedContentBlock.Table -> assertTrue(minOf(block.contentWidthPx, block.viewportWidthPx) <= inner)
                    is PreparedContentBlock.Image -> {
                        assertEquals(row.horizontalPaddingPx, block.leftInsetPx)
                        assertTrue(block.leftInsetPx + block.widthPx <= row.bubbleWidthPx - row.horizontalPaddingPx)
                    }
                    else -> Unit
                }
            }
        }
        // A wide code block keeps its own horizontal scroll inside the bubble.
        val code = prepare(message(9, ChatRole.AGENT, samples[0])).single().blocks.filterIsInstance<PreparedContentBlock.Code>().single()
        assertTrue(code.contentWidthPx > code.viewportWidthPx)
    }

    @Test fun `an image alone is a picture, not a bubble`() {
        val row = prepare(message(1, ChatRole.AGENT, "![sample](https://example.org/sample.png)")).single()
        assertFalse(row.drawBubble)
        assertEquals(0, row.tailPx)
    }

    @Test fun `large text and a narrow screen keep bubbles and tails inside the row`() {
        val narrow = dp(320f)
        for ((viewport, scale) in listOf(narrow to 1f, width to 2f, narrow to 2f)) {
            for (role in listOf(ChatRole.USER, ChatRole.AGENT)) {
                val row = prepare(message(1, role, "A longer sentence that wraps over a few lines. ".repeat(4)),
                    viewport = viewport, fontScale = scale).single()
                assertTrue(row.tailPx > 0)
                assertTrue(row.bubbleWidthPx <= maxBubble(row, viewport))
                val left = bubbleLeft(row, viewport)
                assertTrue(left >= row.sideMarginPx && left + row.bubbleWidthPx <= viewport - row.sideMarginPx)
                val bitmap = drawn(row, viewport)
                assertEquals(row.cellHeightPx, bitmap.height)
                // Under the tail's lowest point, the row is empty: the tail is whole, not cut off.
                for (x in 0 until bitmap.width) assertEquals(0, Color.alpha(bitmap.getPixel(x, bitmap.height - 1)))
            }
        }
    }

    @Test fun `the tail hangs under a fully rounded corner, mirrored for the agent, and never past the sides`() {
        val body = RectF(100f, 50f, 400f, 150f)
        for (right in listOf(true, false)) {
            val path = Path()
            BubbleTail.outline(path, Path(), body, 20 * density, right, density)
            val bounds = RectF().also { path.computeBounds(it, true) }
            assertEquals(body.left, bounds.left, 0.5f)
            assertEquals(body.right, bounds.right, 0.5f)
            assertEquals(body.top, bounds.top, 0.5f)
            assertTrue(bounds.bottom > body.bottom + 5 * density)
            assertTrue(bounds.bottom <= body.bottom + BubbleTail.DEPTH_DP * density)
            val region = Region().apply { setPath(path, Region(0, 0, 600, 300)) }
            /** Whether the shape covers the point [inward] dp in from the tail's side and [down] dp below the bubble. */
            fun filled(inward: Float, down: Float): Boolean {
                val x = if (right) body.right - inward * density else body.left + inward * density
                return region.contains(x.toInt(), (body.bottom + down * density).toInt())
            }
            // The corner keeps its full curve: the side does not run straight down into the tail.
            assertFalse("corner cut off (right=$right)", filled(4f, -3f))
            assertTrue(filled(6.5f, -6f))
            // Where the tail leaves the corner's curve it turns inward: a notch, not a fill.
            assertFalse("notch filled (right=$right)", filled(10f, -1f))
            assertFalse(filled(9.5f, 1f))
            // One shape: a column through the tail is filled from inside the bubble down into it.
            var down = -6f
            while (down < 4f) {
                assertTrue("gap at $down (right=$right)", filled(12f, down))
                down += 0.25f
            }
            // It narrows to a fine point, and nothing hangs under it.
            assertTrue(filled(10f, 5.5f))
            assertFalse(filled(14f, 6f))
            assertFalse(filled(9.5f, 6.9f))
            // The far bottom corner is untouched.
            assertFalse(filled(body.width() / density - 4f, 2f))
        }
    }

    @Test fun `drawn bubbles use the speaker's colour, with the tail on the speaker's side`() {
        val user = prepare(message(1, ChatRole.USER, "Hello there")).single()
        val agent = prepare(message(2, ChatRole.AGENT, "Hello back")).single()
        for ((row, colour, right) in listOf(Triple(user, color(R.color.token_bg_brand_solid), true),
            Triple(agent, color(R.color.token_markdown_bg_message), false))) {
            val bitmap = drawn(row)
            val left = bubbleLeft(row)
            val bottom = row.bubbleTopPx + row.bubbleHeightPx
            // Inside the bubble, clear of the text.
            assertEquals(colour, bitmap.getPixel(left + dp(4f), row.bubbleTopPx + row.bubbleHeightPx / 2))
            // In the tail, below the bubble near its outer corner.
            val tailX = if (right) left + row.bubbleWidthPx - dp(12f) else left + dp(12f)
            assertEquals(colour, bitmap.getPixel(tailX, bottom + dp(4f)))
            // Below the other corner nothing is drawn.
            val farX = if (right) left + dp(4f) else left + row.bubbleWidthPx - dp(4f)
            assertEquals(0, Color.alpha(bitmap.getPixel(farX, bottom + dp(3f))))
            // From inside the bubble down into the tail, every pixel is the bubble's: no seam.
            for (y in bottom - dp(8f) until bottom + dp(3f)) assertEquals("y=$y", colour, bitmap.getPixel(tailX, y))
        }
    }

    @Test @Config(qualifiers = "w411dp-h891dp-night-xxhdpi")
    fun `in the dark theme the agent bubble takes the dark message colour`() {
        val agent = prepare(message(2, ChatRole.AGENT, "Hello back")).single()
        val bitmap = drawn(agent)
        assertEquals(0xFF343538.toInt(), bitmap.getPixel(bubbleLeft(agent) + dp(4f), agent.bubbleTopPx + agent.bubbleHeightPx / 2))
        val user = prepare(message(1, ChatRole.USER, "Hello there")).single()
        val userBitmap = drawn(user)
        assertEquals(0xFF3B7CFF.toInt(), userBitmap.getPixel(bubbleLeft(user) + dp(4f), user.bubbleTopPx + user.bubbleHeightPx / 2))
    }

    @Test fun `the task page keeps agent text on the page`() {
        val row = prepare(message(1, ChatRole.AGENT, "Plain"), precomputer = MessageLayoutPrecomputer()).single()
        assertFalse(row.drawBubble)
        assertEquals(0, row.tailPx)
    }

    @Test fun `a sent message flies into the bubble and its tail fades in with the row`() {
        val row = prepare(message(1, ChatRole.USER, "Hello there")).single()
        val cell = bound(row)
        val bounds = RectF()
        assertTrue(cell.flightBounds(bounds))
        assertEquals(row.bubbleHeightPx.toFloat(), bounds.height(), 0f)
        assertEquals(row.tailPx.toFloat(), cell.flightTailPx, 0f)
        assertTrue(abs(bounds.bottom + cell.flightTailPx - cell.height) < 1f)
    }

    private object Color {
        fun alpha(color: Int) = color ushr 24
    }
}
