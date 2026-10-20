package surf.comma.android.chat.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.ui.theme.DesignMotion

@RunWith(RobolectricTestRunner::class) // Card fades use the platform's curve interpolator.
@Config(sdk = [35])
class TextRevealTest {
    // Density 1: dp and px are the same, so the numbers below read as dp.
    private val density = 1f

    @Test fun `speed covers what is left in 1_35 s within 34 to 440 dp per second`() {
        assertEquals(100f, RevealPacing.speedPxPerSecond(135f, density), 0.001f)
        assertEquals(34f, RevealPacing.speedPxPerSecond(10f, density), 0.001f)
        assertEquals(440f, RevealPacing.speedPxPerSecond(10_000f, density), 0.001f)
        assertEquals(34f * 3f, RevealPacing.speedPxPerSecond(1f, 3f), 0.001f)
    }

    @Test fun `each packet pushes the caret at 1_48x and eases to 0_78x over 200 ms`() {
        assertEquals(1.48f, RevealPacing.arrivalScale(0f), 0.0001f)
        assertEquals((1.48f + 0.78f) / 2f, RevealPacing.arrivalScale(0.1f), 0.0001f)
        assertEquals(0.78f, RevealPacing.arrivalScale(0.2f), 0.0001f)
        assertEquals(0.78f, RevealPacing.arrivalScale(5f), 0.0001f)
    }

    @Test fun `a caret driven by a fake clock follows the pacing frame by frame`() {
        val caret = RevealCaret(totalPx = 270f, density = density)
        assertEquals(200f, caret.speedPxPerSecond, 0.001f) // 270 / 1.35
        caret.advance(0.016f)
        assertEquals(200f * 1.48f * 0.016f, caret.revealedPx, 0.001f)
        // Run the clock past the push: the rest goes at the cruising speed.
        repeat(12) { caret.advance(0.016f) }
        val before = caret.revealedPx
        caret.advance(0.016f)
        assertEquals(200f * 0.78f * 0.016f, caret.revealedPx - before, 0.001f)
        // A new packet re-plans the speed from what is left and pushes again.
        caret.onContent(540f)
        val remaining = 540f - caret.revealedPx
        assertEquals(remaining / 1.35f, caret.speedPxPerSecond, 0.001f)
        val start = caret.revealedPx
        caret.advance(0.016f)
        assertEquals(caret.speedPxPerSecond * 1.48f * 0.016f, caret.revealedPx - start, 0.001f)
        repeat(1_000) { caret.advance(0.016f) }
        assertTrue(caret.isDone)
        assertEquals(540f, caret.revealedPx, 0f)
    }

    @Test fun `a whole reply at once takes the capped time, not an instant`() {
        val caret = RevealCaret(totalPx = 4_400f, density = density)
        assertEquals(440f, caret.speedPxPerSecond, 0f)
        var frames = 0
        while (!caret.isDone) { caret.advance(1f / 60f); frames++ }
        // 440 dp/s at 0.78x after the first push: a little under 13 s for 4400 dp.
        assertEquals(4_400f / (440f * 0.78f), frames / 60f, 0.2f)
    }

    @Test fun `the track cuts text blocks by line and other blocks as a whole`() {
        val track = RevealTrack.of(listOf(listOf(100f, 80f), listOf(300f), listOf(50f)))
        val cut = RevealCut()
        track.cut(0, 130f, cut)
        assertEquals(RevealCut.PARTIAL, cut.kind)
        assertEquals(1, cut.line)
        assertEquals(30f, cut.offsetPx, 0.001f)
        track.cut(1, 130f, cut)
        assertEquals(RevealCut.HIDDEN, cut.kind)
        track.cut(1, 330f, cut)
        assertEquals(RevealCut.PARTIAL, cut.kind)
        assertEquals(0.5f, cut.fraction, 0.001f)
        track.cut(0, 330f, cut)
        assertEquals(RevealCut.FULL, cut.kind)
        assertEquals(530f, track.totalPx, 0f)
    }

    @Test fun `each layout's line widths are measured once, not on every packet`() {
        val paint = android.text.TextPaint().apply { textSize = 40f }
        val text = "one two three four five six seven eight nine ten ".repeat(8)
        val layout = android.text.StaticLayout.Builder.obtain(text, 0, text.length, paint, 400).build()
        val first = RevealTrack.lineWidths(layout)
        assertEquals(layout.lineCount, first.size)
        assertTrue(first.all { it > 0f })
        // The same layout, as a streaming reply keeps its finished blocks: the same measurement.
        assertTrue(first === RevealTrack.lineWidths(layout))
        val relaid = android.text.StaticLayout.Builder.obtain(text, 0, text.length, paint, 400).build()
        assertTrue(first !== RevealTrack.lineWidths(relaid))
    }

    // ---- The book: which rows reveal, in what order, on a fake clock ----

    private val widths = HashMap<String, List<Float>>()
    private var frame = 0L
    private val clock = FakeScheduler()

    private fun book(visible: (Long) -> Float? = { 10_000f }) = TextRevealBook(density, clock, { true }) { item ->
        RevealTrack.of(listOf(widths.getValue(item.cacheKey)))
    }.also { it.visibleBottom = visible }

    private fun row(id: Long, role: ChatRole, key: String, lines: List<Float> = listOf(200f),
                    status: MessageStatus = MessageStatus.COMPLETED, cardKind: String? = null): PreparedChatMessage {
        widths[key] = lines
        return PreparedChatMessage(
            message = ChatMessage(id = id, conversationId = "c", turnId = "t1", role = role, text = key,
                createdAt = 0L, status = status, cardKind = cardKind),
            cacheKey = key, contents = emptyList(),
            blocks = listOf(PreparedContentBlock.Rule(0, 1, 0, 1, 0)),
            bubbleWidthPx = 0, bubbleHeightPx = 0, bubbleTopPx = 0, cellHeightPx = 10, horizontalPaddingPx = 0,
            verticalPaddingPx = 0, sideMarginPx = 0, topMarginPx = 0, cornerRadiusPx = 0f, drawBubble = false,
            imageCornerRadiusPx = 0f, imageSources = emptyList(),
        )
    }

    private fun TextRevealBook.frames(count: Int) = repeat(count) { frame += 16_000_000L; tick(frame) }

    private val user = row(1, ChatRole.USER, "question")
    private val status = row(2, ChatRole.AGENT, "thinking", cardKind = TimelineBlockKinds.LIVE_STATUS)

    @Test fun `a reply that lands whole while following the bottom fades in whole, with no caret`() {
        val book = book()
        val reply = row(3, ChatRole.AGENT, "answer", listOf(300f, 300f))
        book.onSubmit(listOf(user, status), listOf(user, reply), live = true)
        assertTrue(clock.posted)
        assertNull("complete from the first frame", book.frameFor(reply))
        assertEquals(0f, book.cardAlpha(3), 0f)
        book.frames(1)
        assertEquals(0f, book.cardAlpha(3), 0f) // The first frame only starts the clock.
        book.frames(6)
        assertNull(book.frameFor(reply))
        assertTrue(book.cardAlpha(3) > 0f && book.cardAlpha(3) < 1f)
        book.frames(26) // The fade and the rise are both done in 0.4 s.
        assertEquals(1f, book.cardAlpha(3), 0f)
        assertEquals(0f, book.riseOffset(3), 0f)
        assertFalse(book.isRunning)
    }

    @Test fun `replies from the cache or while reading history appear at once`() {
        val book = book()
        val reply = row(3, ChatRole.AGENT, "answer")
        book.onSubmit(emptyList(), listOf(user, reply), live = false)
        assertNull(book.frameFor(reply))
        book.onSubmit(listOf(user, status), listOf(user, reply), live = false)
        assertNull(book.frameFor(reply))
        assertFalse(clock.posted)
    }

    @Test fun `a whole message rises into place on the size spring while it fades in`() {
        val book = book()
        val reply = row(3, ChatRole.AGENT, "answer")
        val chip = row(4, ChatRole.AGENT, "chip", cardKind = "task.ref")
        book.onSubmit(listOf(user, status), listOf(user, reply, chip), live = true)
        val full = RevealPacing.MESSAGE_RISE_DP * density
        assertEquals(full, book.riseOffset(3), 0.01f)
        assertEquals("cards only fade", 0f, book.riseOffset(4), 0f)
        book.frames(1)
        val offsets = (0 until 30).map { book.frames(1); book.riseOffset(3) }
        assertTrue(offsets.zipWithNext().all { (a, b) -> b <= a + 0.01f })
        assertTrue(offsets[5] in 0.01f..full)
        assertEquals(0f, offsets.last(), 0f)
        assertEquals(1f, book.cardAlpha(3), 0f)
    }

    @Test fun `spring progress starts at rest and settles on its target`() {
        val tokens = with(DesignMotion) {
            listOf(springSize, springSpatial, springScale, springFlight, DesignMotion.SpringToken(100f, 1f), DesignMotion.SpringToken(100f, 2f))
        }
        for (token in tokens) {
            assertEquals(0f, token.progressAt(0f), 0f)
            assertTrue(token.progressAt(0.001f) < 0.01f)
            assertEquals("$token", 1f, token.progressAt(3f), 0.01f)
        }
        // The size spring barely overshoots.
        val size = surf.comma.android.ui.theme.DesignMotion.springSize
        assertTrue((0 until 100).map { size.progressAt(it / 100f) }.max() < 1.01f)
    }

    @Test fun `a reply that is not on screen is finished instead of animated`() {
        val book = book(visible = { null })
        val reply = row(3, ChatRole.AGENT, "answer")
        book.onSubmit(listOf(user, status), listOf(user, reply), live = true)
        book.frames(2)
        assertTrue(book.isRunning) // Not laid out yet: it waits a few frames.
        book.frames(3)
        assertFalse(book.isRunning)
        assertEquals(1f, book.cardAlpha(3), 0f)
    }

    @Test fun `the caret stops animating once it passes the bottom of the screen`() {
        val tops = HashMap<Long, Float>()
        val book = TextRevealBook(density, clock, { true }) { item ->
            RevealTrack.of(listOf(widths.getValue(item.cacheKey)), listOf(listOf(0f, 40f, 80f)))
        }.also { it.visibleBottom = { id -> tops[id] } }
        val reply = row(3, ChatRole.AGENT, "long", listOf(100f, 100f, 100f), MessageStatus.STREAMING)
        tops[3] = 60f // Lines at 0 and 40 are on screen, the one at 80 is not.
        book.onSubmit(listOf(user, status), listOf(user, reply), live = true)
        book.frames(40)
        assertTrue(book.frameFor(reply)!!.revealedPx in 100f..200f) // On the second line.
        book.frames(40)
        assertNull(book.frameFor(reply)) // Reached the third line and stopped animating.
    }

    @Test fun `rows of one reply fade in one after another, cards like messages`() {
        val book = book()
        val first = row(3, ChatRole.AGENT, "first", listOf(100f))
        val chip = row(4, ChatRole.AGENT, "chip", cardKind = "task.ref")
        val second = row(5, ChatRole.AGENT, "second", listOf(100f))
        book.onSubmit(listOf(user, status), listOf(user, first, chip, second), live = true)
        book.frames(5)
        assertTrue(book.cardAlpha(3) > 0f)
        assertEquals(0f, book.cardAlpha(4), 0f)
        assertEquals(0f, book.cardAlpha(5), 0f)
        listOf(first, chip, second).forEach { assertNull(book.frameFor(it)) }
        book.frames(22)
        assertEquals(1f, book.cardAlpha(3), 0f)
        assertTrue(book.cardAlpha(5) < 1f)
        book.frames(80)
        assertEquals(1f, book.cardAlpha(4), 0f)
        assertEquals(1f, book.cardAlpha(5), 0f)
        assertFalse(book.isRunning)
    }

    @Test fun `a streamed reply replaced by its final message does not start over`() {
        val book = book()
        val draft = row(10, ChatRole.AGENT, "draft", listOf(400f), MessageStatus.STREAMING)
        book.onSubmit(listOf(user, status), listOf(user, draft), live = true)
        book.frames(20)
        val reached = book.frameFor(draft)!!.revealedPx
        assertTrue(reached > 0f && reached < 400f)
        val final = row(11, ChatRole.AGENT, "final", listOf(400f, 100f))
        book.onSubmit(listOf(user, draft), listOf(user, final), live = true)
        assertEquals(reached, book.frameFor(final)!!.revealedPx, 0.001f)
    }

    @Test fun `a finished draft replaced by its final message shows at once`() {
        val book = book()
        val draft = row(10, ChatRole.AGENT, "draft", listOf(400f), MessageStatus.COMPLETED)
        // Shown whole while reading history, then the final message lands while following.
        book.onSubmit(listOf(user), listOf(user, draft), live = false)
        val final = row(11, ChatRole.AGENT, "final", listOf(400f))
        book.onSubmit(listOf(user, draft), listOf(user, final), live = true)
        assertNull(book.frameFor(final))
    }

    @Test fun `a streaming row reveals each packet from where the last one ended`() {
        val book = book()
        val one = row(10, ChatRole.AGENT, "p1", listOf(100f), MessageStatus.STREAMING)
        book.onSubmit(listOf(user, status), listOf(user, one), live = true)
        book.frames(200)
        assertNull(book.frameFor(one))
        val two = row(10, ChatRole.AGENT, "p2", listOf(100f, 60f), MessageStatus.STREAMING)
        book.onSubmit(listOf(user, one), listOf(user, two), live = true)
        assertEquals(100f, book.frameFor(two)!!.revealedPx, 0f)
        book.frames(200)
        assertNull(book.frameFor(two))
    }

    @Test fun `a long reply that lands whole is complete at once and in place within half a second`() {
        val book = book()
        val reply = row(3, ChatRole.AGENT, "long", List(40) { 330f }) // 13,200 dp: 30 s by the plain rule.
        book.onSubmit(listOf(user, status), listOf(user, reply), live = true)
        assertNull(book.frameFor(reply))
        book.frames(1 + 26) // The clock starts on the first frame; then 26 frames of 16 ms is 0.42 s.
        assertNull(book.frameFor(reply))
        assertEquals(1f, book.cardAlpha(3), 0f)
        assertFalse(book.isRunning)
    }

    @Test fun `rows and cards landing together are all in within two seconds`() {
        val book = book()
        val first = row(3, ChatRole.AGENT, "first", List(10) { 330f })
        val chip = row(4, ChatRole.AGENT, "chip", cardKind = "task.ref")
        val second = row(5, ChatRole.AGENT, "second", List(10) { 330f })
        book.onSubmit(listOf(user, status), listOf(user, first, chip, second), live = true)
        book.frames(1 + 128) // About 2 s, with a frame or two of slack for row hand-offs.
        assertNull(book.frameFor(first))
        assertEquals(1f, book.cardAlpha(4), 0f)
        assertNull(book.frameFor(second))
    }

    @Test fun `a streamed draft keeps the plain rule however long it gets`() {
        val book = book()
        val draft = row(10, ChatRole.AGENT, "draft", List(40) { 330f }, MessageStatus.STREAMING)
        book.onSubmit(listOf(user, status), listOf(user, draft), live = true)
        book.frames(1 + 140)
        val shown = book.frameFor(draft)!!.revealedPx
        // At most 440 dp/s with the 1.48x push: well short of the 13,200 dp after 2.2 s.
        assertTrue("shown $shown", shown < 440f * 1.48f * 2.3f)
    }

    @Test fun `user messages and status lines are never revealed`() {
        val book = book()
        val sent = row(20, ChatRole.USER, "sent")
        book.onSubmit(listOf(user), listOf(user, sent, status), live = true)
        assertNull(book.frameFor(sent))
        assertNull(book.frameFor(status))
        assertFalse(book.isRunning)
    }

    @Test fun `with animations off everything appears at once`() {
        val book = TextRevealBook(density, clock, { false }) { RevealTrack.of(listOf(widths.getValue(it.cacheKey))) }
        val reply = row(3, ChatRole.AGENT, "answer")
        book.onSubmit(listOf(user, status), listOf(user, reply), live = true)
        assertNull(book.frameFor(reply))
    }

    private class FakeScheduler : FrameScheduler {
        var posted = false
        override fun post(callback: (Long) -> Unit) { posted = true }
        override fun cancel(callback: (Long) -> Unit) { posted = false }
    }
}
