package surf.comma.android.chat.render

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import android.graphics.Color
import surf.comma.android.R
import surf.comma.android.chat.model.TimelineBlockKinds
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.Shadows.shadowOf
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowSystemClock
import android.os.Looper
import java.time.Duration
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.ui.widget.DrawerHostLayout
import java.io.File

/**
 * Code blocks and tables scroll sideways in real `:scroll` containers inside the real chat list,
 * under the real drawer: touches go in at the top of the window, the way a finger's do.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MarkdownScrollTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val root = DrawerHostLayout(activity)
    private val timeline = ChatTimelineView(activity)
    private val precomputer = MessageLayoutPrecomputer(bubbles = true)
    private var shown: List<PreparedChatMessage> = emptyList()
    private val copied = mutableListOf<String>()
    private val longPressed = mutableListOf<Long>()
    private var downTime = 0L
    // A new window-sized bitmap per frame piles up native pixel memory faster than GC frees it.
    private var frameBitmap: Bitmap? = null

    init {
        // Frames come only when the test moves the clock, 16 ms at a time, like a 60 Hz display;
        // otherwise the looper fast-forwards through a whole fling in one idle.
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(16))
        val page = FrameLayout(activity).apply { addView(timeline, match()) }
        val scrim = View(activity)
        val drawer = FrameLayout(activity)
        root.addView(page, match())
        root.addView(scrim, match())
        root.addView(drawer, FrameLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT))
        root.bind(drawer, scrim, listOf(page)) {}
        activity.setContentView(root)
        timeline.onCopyCode = { copied += it }
        timeline.onLongPressMessage = { _, item -> longPressed += item.message.id }
        settle()
    }

    private val wideCode = "val first = \"" + "a wide line of code ".repeat(14) + "\"\nprintln(first)"
    private val otherCode = "echo " + "second block, also wide ".repeat(12)
    private val table = "| Name | Region | Owner | Status | Opened | Notes |\n|---|---|---|---|---|---|\n" +
        (1..3).joinToString("\n") { "| row $it | eu-west-$it | someone $it | waiting on review | 2026-10-0$it | a long note that keeps going |" }
    private val reply = "Here you go:\n\n```kotlin\n$wideCode\n```\n\n$table\n\n```sh\n$otherCode\n```\n\n```sh\nls\n```"

    private fun message(id: Long, role: ChatRole, text: String) =
        ChatMessage(id = id, conversationId = "c", turnId = "t$id", role = role, text = text, createdAt = id,
            // An agent's text as the core parsed it.
            markdown = if (role == ChatRole.AGENT && text.isNotEmpty()) Md.of(text) else null)

    private val history = (1L..6L).flatMap {
        listOf(message(it * 10, ChatRole.USER, "question $it"),
            message(it * 10 + 1, ChatRole.AGENT, (1..6).joinToString("\n\n") { p -> "Paragraph $p of an older answer." }))
    }

    private fun submit(rows: List<ChatMessage>) {
        shown = runBlocking {
            precomputer.prepareChanged(shown, rows, viewportWidthPx = timeline.width, density = density,
                fontScale = 1f, darkTheme = false)
        }
        timeline.submitPrepared(shown)
        settle()
    }

    private fun settle(frames: Int = 120) = repeat(frames) { frame() }

    /** One display frame: the clock moves, flingers and springs step, and the window draws. */
    private fun frame() {
        ShadowSystemClock.advanceBy(Duration.ofMillis(16))
        shadowOf(Looper.getMainLooper()).idle()
        if (root.width > 0) root.draw(Canvas(frameBuffer()))
    }

    private fun frameBuffer(): Bitmap = frameBitmap?.takeIf { it.width == root.width && it.height == root.height }
        ?: Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888).also {
            frameBitmap?.recycle()
            frameBitmap = it
        }

    private fun touch(action: Int, x: Float, y: Float) {
        val now = SystemClock.uptimeMillis()
        if (action == MotionEvent.ACTION_DOWN) downTime = now
        val event = MotionEvent.obtain(downTime, now, action, x, y, 0)
        root.dispatchTouchEvent(event)
        event.recycle()
    }

    /** A finger put down at [x],[y] and moved by [dx],[dy] in [steps] frames; it stays down. */
    private fun drag(x: Float, y: Float, dx: Float, dy: Float, steps: Int = 8) {
        touch(MotionEvent.ACTION_DOWN, x, y)
        moveBy(x, y, dx, dy, steps)
    }

    private fun moveBy(x: Float, y: Float, dx: Float, dy: Float, steps: Int) {
        for (step in 1..steps) {
            frame()
            touch(MotionEvent.ACTION_MOVE, x + dx * step / steps, y + dy * step / steps)
        }
    }

    private val replyId = 100L
    private fun cell() = timeline.viewForRow(replyId) as ChatMessageCell
    private fun slots(cell: ChatMessageCell = cell()) =
        (0 until cell.childCount).map(cell::getChildAt).filterIsInstance<ScrollContainer>().filter { it.visibility == View.VISIBLE }
    private fun list(slot: ScrollContainer) =
        (0 until slot.childCount).map(slot::getChildAt).filterIsInstance<RecyclerView>().single()

    /** [slot]'s bounds in window coordinates. */
    private fun bounds(slot: View) = Rect(0, 0, slot.width, slot.height).also { root.offsetDescendantRectToMyCoords(slot, it) }

    private fun maxOffset(slot: ScrollContainer) = list(slot).getChildAt(0).width - slot.width

    private fun showReply() {
        submit(history + message(replyId - 1, ChatRole.USER, "show me") + message(replyId, ChatRole.AGENT, reply))
        assertTrue(timeline.isPinnedToEnd())
    }

    @Test fun `every code body and table gets its own scroll container, and only wide ones can scroll`() {
        showReply()
        val slots = slots()
        assertEquals("three code blocks and a table", 4, slots.size)
        assertEquals(listOf(true, true, true, false), slots.map { it.canScroll })
        val cell = cell()
        val item = shown.single { it.message.id == replyId }
        val code = item.blocks.filterIsInstance<PreparedContentBlock.Code>().first()
        // The body sits under the header, as wide as the box; the header stays outside the scroller.
        assertEquals(code.yOffsetPx + code.headerHeightPx, slots[0].top)
        assertEquals(code.viewportWidthPx, slots[0].width)
        assertEquals(code.heightPx - code.headerHeightPx, slots[0].height)
        assertEquals(code.contentWidthPx, list(slots[0]).getChildAt(0).width)
        assertTrue(slots.all { it.right <= cell.width - item.sideMarginPx })
    }

    @Test fun `a sideways drag scrolls that block alone, through the scroll module, and not the list or drawer`() {
        showReply()
        val (first, table, second) = slots()
        val listOffset = timeline.computeVerticalScrollOffset()
        val box = bounds(first)
        drag(box.right - 40f, box.centerY().toFloat(), dx = -400f, dy = 30f)
        assertEquals(RecyclerView.SCROLL_STATE_DRAGGING, list(first).scrollState)
        assertTrue(first.scrollOffset in 300..400)
        touch(MotionEvent.ACTION_CANCEL, box.right - 440f, box.centerY() + 30f)
        settle()
        assertEquals(0, table.scrollOffset)
        assertEquals(0, second.scrollOffset)
        assertEquals(listOffset, timeline.computeVerticalScrollOffset())
        assertEquals(0f, root.drawerProgress)
    }

    @Test fun `a flick keeps scrolling after the finger lifts and comes to rest at the far edge`() {
        showReply()
        val slot = slots()[0]
        val box = bounds(slot)
        drag(box.right - 20f, box.centerY().toFloat(), dx = -900f, dy = 0f, steps = 3)
        touch(MotionEvent.ACTION_UP, box.right - 920f, box.centerY().toFloat())
        val released = slot.scrollOffset
        frame()
        assertEquals("the module's flinger carries it on", RecyclerView.SCROLL_STATE_SETTLING, list(slot).scrollState)
        settle(10)
        assertTrue(slot.scrollOffset > released)
        settle(240)
        assertEquals(RecyclerView.SCROLL_STATE_IDLE, list(slot).scrollState)
        assertEquals("rests exactly on the end, after any overscroll springs back", maxOffset(slot), slot.scrollOffset)
    }

    @Test fun `a touch stops a flick where it is`() {
        showReply()
        val slot = slots()[0]
        val box = bounds(slot)
        drag(box.right - 20f, box.centerY().toFloat(), dx = -500f, dy = 0f, steps = 3)
        touch(MotionEvent.ACTION_UP, box.right - 520f, box.centerY().toFloat())
        settle(3)
        assertEquals(RecyclerView.SCROLL_STATE_SETTLING, list(slot).scrollState)
        touch(MotionEvent.ACTION_DOWN, box.centerX().toFloat(), box.centerY().toFloat())
        val caught = slot.scrollOffset
        settle(20)
        assertEquals(caught, slot.scrollOffset)
        touch(MotionEvent.ACTION_UP, box.centerX().toFloat(), box.centerY().toFloat())
        settle(20)
        assertEquals(caught, slot.scrollOffset)
        assertTrue(caught in 1 until maxOffset(slot))
    }

    @Test fun `dragging back within one gesture follows the finger, and the start edge holds`() {
        showReply()
        val slot = slots()[0]
        val box = bounds(slot)
        val y = box.centerY().toFloat()
        drag(box.right - 40f, y, dx = -300f, dy = 0f)
        val out = slot.scrollOffset
        moveBy(box.right - 340f, y, dx = 200f, dy = 0f, steps = 6)
        assertTrue(slot.scrollOffset in (out - 210)..(out - 190))
        // Past the start: the content stretches (drawn), the offset stays at the edge, no drawer.
        moveBy(box.right - 140f, y, dx = 400f, dy = 0f, steps = 8)
        assertEquals(0, slot.scrollOffset)
        assertEquals(0f, root.drawerProgress)
        touch(MotionEvent.ACTION_UP, box.right + 260f, y)
        settle(200)
        assertEquals(0, slot.scrollOffset)
        assertEquals(0f, root.drawerProgress)
    }

    @Test fun `a cancelled drag stops without a fling`() {
        showReply()
        val slot = slots()[0]
        val box = bounds(slot)
        drag(box.right - 20f, box.centerY().toFloat(), dx = -500f, dy = 0f, steps = 3)
        touch(MotionEvent.ACTION_CANCEL, box.right - 520f, box.centerY().toFloat())
        val cancelled = slot.scrollOffset
        settle(30)
        assertEquals(RecyclerView.SCROLL_STATE_IDLE, list(slot).scrollState)
        assertEquals(cancelled, slot.scrollOffset)
    }

    @Test fun `a mostly vertical drag over a code block scrolls the list and not the block`() {
        showReply()
        val slot = slots()[0]
        val box = bounds(slot)
        val before = timeline.computeVerticalScrollOffset()
        drag(box.centerX().toFloat(), box.centerY().toFloat(), dx = -60f, dy = 300f)
        touch(MotionEvent.ACTION_UP, box.centerX() - 60f, box.centerY() + 300f)
        settle()
        assertEquals(0, slot.scrollOffset)
        assertTrue("the list moved", timeline.computeVerticalScrollOffset() < before)
    }

    @Test fun `a shallow diagonal over a code block scrolls the block and leaves the list`() {
        showReply()
        val again = bounds(slots()[0])
        val listOffset = timeline.computeVerticalScrollOffset()
        drag(again.right - 40f, again.centerY().toFloat(), dx = -300f, dy = 150f)
        touch(MotionEvent.ACTION_CANCEL, again.right - 340f, again.centerY() + 150f)
        assertTrue(slots()[0].scrollOffset > 200)
        assertEquals(listOffset, timeline.computeVerticalScrollOffset())
    }

    @Test fun `a block that fits leaves sideways drags to the page, so the drawer still opens there`() {
        showReply()
        val fits = slots()[3]
        assertFalse(fits.canScroll)
        val box = bounds(fits)
        drag(box.left + 10f, box.centerY().toFloat(), dx = 300f, dy = 0f)
        assertTrue("the drawer took the drag", root.drawerProgress > 0f)
        touch(MotionEvent.ACTION_CANCEL, box.left + 310f, box.centerY().toFloat())
        settle(200)
    }

    @Test fun `copy taps and long presses still reach the message, wide or not`() {
        showReply()
        val item = shown.single { it.message.id == replyId }
        val code = item.blocks.filterIsInstance<PreparedContentBlock.Code>().first()
        val slot = slots()[0]
        // Scroll the body first: the header and its copy button do not move with it.
        val box = bounds(slot)
        drag(box.right - 40f, box.centerY().toFloat(), dx = -300f, dy = 0f)
        touch(MotionEvent.ACTION_UP, box.right - 340f, box.centerY().toFloat())
        settle(240)
        assertTrue(slot.scrollOffset > 0)
        val copyX = box.right - code.copyHitWidthPx / 2f
        val copyY = box.top - code.headerHeightPx / 2f
        touch(MotionEvent.ACTION_DOWN, copyX, copyY)
        frame()
        touch(MotionEvent.ACTION_UP, copyX, copyY)
        assertEquals(listOf(code.copyText), copied)

        for (target in listOf(slot, slots()[3])) {
            longPressed.clear()
            val at = bounds(target)
            touch(MotionEvent.ACTION_DOWN, at.centerX().toFloat(), at.centerY().toFloat())
            settle(50)
            touch(MotionEvent.ACTION_UP, at.centerX().toFloat(), at.centerY().toFloat())
            assertEquals(listOf(replyId), longPressed)
        }
        // A drag is not a long press.
        longPressed.clear()
        drag(box.right - 40f, box.centerY().toFloat(), dx = 200f, dy = 0f)
        settle(50)
        touch(MotionEvent.ACTION_UP, box.right + 160f, box.centerY().toFloat())
        assertEquals(emptyList<Long>(), longPressed)
    }

    @Test fun `offsets belong to a message and block, across rebinding, reuse and growing content`() {
        val book = BlockScrollBook()
        fun prepared(id: Long, text: String) = runBlocking {
            precomputer.prepare(listOf(message(id, ChatRole.AGENT, text)), viewportWidthPx = (411 * density).toInt(),
                density = density, fontScale = 1f, darkTheme = false)
        }.single()
        fun cellFor(item: PreparedChatMessage) = ChatMessageCell(activity).apply {
            blockScrolls = book
            bind(item)
        }
        fun layOut(cell: ChatMessageCell) {
            cell.measure(View.MeasureSpec.makeMeasureSpec((411 * density).toInt(), View.MeasureSpec.EXACTLY),
                View.MeasureSpec.UNSPECIFIED)
            cell.layout(0, 0, cell.measuredWidth, cell.measuredHeight)
        }
        val a = prepared(1, reply)
        val b = prepared(2, reply)
        val cell = cellFor(a)
        layOut(cell)
        slots(cell)[0].scrollOffset = 500
        slots(cell)[2].scrollOffset = 120
        layOut(cell)
        assertEquals(listOf(500, 0, 120, 0), slots(cell).map { it.scrollOffset })

        // The cell is reused for another message: nothing carries over.
        cell.bind(b)
        layOut(cell)
        assertEquals(listOf(0, 0, 0, 0), slots(cell).map { it.scrollOffset })
        slots(cell)[1].scrollOffset = 80
        layOut(cell)

        // Message A comes back, in this cell or another one.
        cell.bind(a)
        layOut(cell)
        assertEquals(listOf(500, 0, 120, 0), slots(cell).map { it.scrollOffset })
        val other = cellFor(b).also(::layOut)
        assertEquals(listOf(0, 80, 0, 0), slots(other).map { it.scrollOffset })

        // The same message rebinds with a shorter first block: the offset is clamped to it.
        val shorter = prepared(1, reply.replace(wideCode, "val first = \"" + "short ".repeat(5) + "\""))
        cell.bind(shorter)
        layOut(cell)
        val clamped = slots(cell)[0]
        assertEquals(maxOffset(clamped), clamped.scrollOffset)
        assertTrue(clamped.scrollOffset < 500)
        assertEquals(clamped.scrollOffset, book[BlockScrollBook.Key(1, shorter.blocks.first { it is PreparedContentBlock.Code }.contentIndex)])
        assertEquals(120, slots(cell)[2].scrollOffset)
        // And it grows again (more streamed text): the clamped place holds.
        cell.bind(a)
        layOut(cell)
        assertEquals(clamped.scrollOffset, slots(cell)[0].scrollOffset)
    }

    @Test fun `the offset book stays bounded`() {
        val book = BlockScrollBook(capacity = 4)
        (1L..10L).forEach { book[BlockScrollBook.Key(it, 0)] = it.toInt() }
        assertEquals(4, book.size)
        assertEquals(0, book[BlockScrollBook.Key(1, 0)])
        assertEquals(10, book[BlockScrollBook.Key(10, 0)])
    }

    @Test fun `a slot left over by a message with fewer blocks stops, lets go of its layout, and restores later`() {
        val book = BlockScrollBook()
        val viewport = (411 * density).toInt()
        fun prepared(id: Long, text: String) = runBlocking {
            precomputer.prepare(listOf(message(id, ChatRole.AGENT, text)), viewportWidthPx = viewport,
                density = density, fontScale = 1f, darkTheme = false)
        }.single()
        val wide = prepared(1, reply)
        val cell = ChatMessageCell(activity).apply { blockScrolls = book; bind(wide) }
        root.removeAllViews()
        root.addView(cell, FrameLayout.LayoutParams(viewport, ViewGroup.LayoutParams.WRAP_CONTENT))
        settle(4)
        // The third block (the wide sh one) is mid-fling when the cell is reused.
        val slot = slots(cell)[2]
        assertTrue(list(slot).fling(2500, 0))
        settle(4)
        assertEquals(RecyclerView.SCROLL_STATE_SETTLING, list(slot).scrollState)

        // Reused for a message with one code block: slots 1-3 have nothing to show.
        val single = prepared(2, "One block:\n\n```sh\nls\n```")
        cell.bind(single)
        val all = (0 until cell.childCount).map(cell::getChildAt).filterIsInstance<ScrollContainer>()
        assertEquals(4, all.size)
        assertEquals(listOf(View.VISIBLE, View.GONE, View.GONE, View.GONE), all.map { it.visibility })
        val stopped = slot.scrollOffset
        assertTrue(stopped > 0)
        settle(20)
        assertEquals("a slot with nothing to show does not keep flinging", stopped, slot.scrollOffset)
        all.forEach { assertEquals(RecyclerView.SCROLL_STATE_IDLE, list(it).scrollState) }
        assertEquals("slot 0 shows the new message's block from its start", 0, all[0].scrollOffset)
        val bodies = all.map { (list(it).getChildAt(0) as ViewGroup).getChildAt(0) as ScrollableBlockBody }
        assertTrue("no slot keeps the old message's layout", bodies.drop(1).all { it.block == null })
        // The book keeps where the first message's blocks were left.
        val codes = wide.blocks.filter { ScrollableBlockSlot.scrolls(it) }.map { it.contentIndex }
        assertEquals(stopped, book[BlockScrollBook.Key(1, codes[2])])

        // Message 1 comes back to this cell: every block is where it was.
        cell.bind(wide)
        settle(4)
        assertEquals(listOf(0, 0, stopped, 0), slots(cell).map { it.scrollOffset })
        assertTrue(bodies.all { it.block != null })
    }

    /** A brief, closed or open, drawn into a bitmap at the cell's current height. */
    private fun briefCell(text: String, expanded: Boolean) = runBlocking {
        precomputer.prepare(listOf(message(7, ChatRole.AGENT, text).copy(cardKind = TimelineBlockKinds.TASK_BRIEF,
            cardPayload = if (expanded) TimelineBlockKinds.TASK_BRIEF_EXPANDED else null)),
            viewportWidthPx = (411 * density).toInt(), density = density, fontScale = 1f, darkTheme = false)
    }.single()

    private fun snapshot(cell: View) = Bitmap.createBitmap(cell.width, cell.height, Bitmap.Config.ARGB_8888)
        .also { cell.draw(Canvas(it)) }

    /**
     * Over the [fadeDp] above a closed brief's cut, every pixel of ink the open brief shows there
     * must come out lighter: the fade covers code bodies and tables, not just text.
     */
    private fun assertFadesAboveCut(open: Bitmap, closed: Bitmap, cut: Int, item: PreparedChatMessage, what: String) {
        val left = item.sideMarginPx + item.horizontalPaddingPx + dp(20f)
        val right = open.width - item.sideMarginPx - item.horizontalPaddingPx - dp(20f)
        val background = ContextCompat.getColor(activity, R.color.token_bg_secondary)
        val backgroundLuma = Color.red(background) + Color.green(background) + Color.blue(background)
        var ink = 0
        var unfaded = 0
        for (y in cut - dp(23f) until cut) for (x in left until right) {
            val pixel = open.getPixel(x, y)
            if (backgroundLuma - (Color.red(pixel) + Color.green(pixel) + Color.blue(pixel)) > 40) {
                ink++
                if (closed.getPixel(x, y) == pixel) unfaded++
            }
        }
        assertTrue("$what: the fixture needs ink above the cut", ink > 20)
        assertEquals("$what: ink left at full strength above the cut", 0, unfaded)
    }

    private fun dp(value: Float) = (value * density).toInt()

    private val tallCode = "```text\n" + (1..15).joinToString("\n") { "MMMMM WWWWW ".repeat(12) } + "\n```"
    private val tallTable = "| A | B | C | D |\n|---|---|---|---|\n" +
        (1..15).joinToString("\n") { "| WWWWW WWWWW | MMMMM MMMMM | WWWWW WWWWW | MMMMM MMMMM |" }

    @Test fun `a closed brief fades code bodies and tables out above Show all`() {
        for ((what, text) in listOf("code" to tallCode, "table" to tallTable)) {
            val closedItem = briefCell(text, expanded = false)
            val openItem = briefCell(text, expanded = true)
            fun drawn(item: PreparedChatMessage) = ChatMessageCell(activity).apply {
                bind(item)
                measure(View.MeasureSpec.makeMeasureSpec((411 * density).toInt(), View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.UNSPECIFIED)
                layout(0, 0, measuredWidth, measuredHeight)
            }
            val closed = drawn(closedItem)
            assertTrue("$what scrolls in a slot", slots(closed).isNotEmpty())
            assertFadesAboveCut(snapshot(drawn(openItem)), snapshot(closed),
                closed.height - closedItem.brief!!.footerBlockPx, closedItem, what)
        }
    }

    @Test fun `while a brief opens or closes, the moving cut fades code and tables too`() {
        for ((what, text) in listOf("code" to tallCode, "table" to tallTable)) {
            val closedItem = briefCell(text, expanded = false)
            val openItem = briefCell(text, expanded = true)
            val width = (411 * density).toInt()
            val reference = ChatMessageCell(activity).apply {
                bind(openItem)
                measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
                layout(0, 0, measuredWidth, measuredHeight)
            }
            val open = snapshot(reference)
            for ((from, to) in listOf(closedItem to openItem, openItem to closedItem)) {
                val cell = ChatMessageCell(activity).apply { bind(from) }
                root.removeAllViews()
                root.addView(cell, FrameLayout.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT))
                settle(4)
                cell.bind(to)
                settle(6)
                val low = minOf(closedItem.cellHeightPx, openItem.cellHeightPx)
                val high = maxOf(closedItem.cellHeightPx, openItem.cellHeightPx)
                assertTrue("$what is mid-spring: ${cell.height}", cell.height in (low + 1) until high - 1)
                val mid = Bitmap.createBitmap(width, open.height, Bitmap.Config.ARGB_8888)
                cell.draw(Canvas(mid))
                assertFadesAboveCut(open, mid, cell.height - closedItem.brief!!.footerBlockPx, closedItem,
                    "$what ${if (to === openItem) "opening" else "closing"}")
                settle(60)
                assertEquals(to.cellHeightPx, cell.height)
            }
        }
    }

    /**
     * A static guard over the chat renderer: no hand-made scrolling may come back. It only reads
     * these sources for the primitives such code needs (velocity tracking, scrollers, edge
     * effects, taking a gesture from the list); it cannot prove that some other view scrolls
     * through `:scroll`, which is what the gesture tests above show for code blocks and tables.
     */
    @Test fun `the chat renderer has no hand-made scrolling of its own`() {
        val dir = File("src/main/java/surf/comma/android/chat").takeIf { it.isDirectory }
            ?: File("app/src/main/java/surf/comma/android/chat")
        val sources = dir.walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue(sources.size > 10)
        val forbidden = listOf("VelocityTracker", "OverScroller", "android.widget.Scroller", "EdgeEffect",
            "requestDisallowInterceptTouchEvent", "HorizontalDragRegion")
        val hits = sources.flatMap { file ->
            val text = file.readText()
            forbidden.filter { it in text }.map { "${file.name}: $it" }
        }
        assertEquals(emptyList<String>(), hits)
        val cell = sources.single { it.name == "ChatMessageCell.kt" }.readText()
        assertFalse("the cell must not keep offsets itself", Regex("scrollOffsets|offsetOf\\(|dragSideways").containsMatchIn(cell))
        assertNotEquals(-1, cell.indexOf("ScrollableBlockSlot("))
    }

    private fun match() = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
}
