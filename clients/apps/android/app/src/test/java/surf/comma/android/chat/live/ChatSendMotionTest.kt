package surf.comma.android.chat.live

import android.animation.ValueAnimator
import android.net.Uri
import android.os.SystemClock
import android.view.MotionEvent
import android.widget.EditText
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.requestKey
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaSource
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerAttachment
import surf.comma.android.ui.composer.ComposerView
import java.time.Duration
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The send path as the chat screen runs it ([ChatSendFlow] between the real composer, flight and
 * list), stepped one 16 ms frame at a time. The repository is a stand-in that commits the rows
 * the way the real one publishes them: before the send returns, or after it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class ChatSendMotionTest {
    private lateinit var controller: ActivityController<ComponentActivity>
    private lateinit var activity: ComponentActivity
    private lateinit var timeline: ChatTimelineView
    private lateinit var composer: ComposerView
    private lateinit var flight: SendFlightView
    private lateinit var flow: ChatSendFlow
    private val density get() = activity.resources.displayMetrics.density
    private val rows = ArrayList<ChatMessage>()
    private var nextId = 1L
    private var request = 0
    private var currentRequestId = "send-0"
    /** Commit the sent rows inside the send (as the repository does) or only after it returns. */
    private var commitBeforeReturn = true
    private var refuse = false
    private var conversation = "c"

    @Before fun setUp() {
        resetSpringFrames()
        // One vsync per 16 ms of looper time, instead of frames run eagerly inside an idle.
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(FRAME_MS))
        controller = Robolectric.buildActivity(ComponentActivity::class.java)
        activity = controller.get()
        activity.setTheme(R.style.Theme_Chat)
        controller.setup()
        val root = FrameLayout(activity)
        timeline = ChatTimelineView(activity).apply { clipToPadding = false }
        composer = ComposerView(activity)
        flight = SendFlightView(activity, timeline)
        root.addView(timeline, FrameLayout.LayoutParams(-1, -1))
        composer.attachTo(root)
        root.addView(flight, FrameLayout.LayoutParams(-1, -1))
        flow = ChatSendFlow(activity.lifecycleScope, composer, timeline, flight,
            draftRequestId = { currentRequestId },
            sendDraft = { text, attachments -> admit(text, attachments) },
            sendVoice = { _, _ -> true })
        flow.bind()
        composer.onAttachmentsAdded = { added -> added.forEach { composer.setAttachmentState(it.id, AttachmentUploadState.Done) } }
        composer.onImeOffset = { boundary() }
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> boundary() }
        activity.setContentView(root)
        frames(10)
        rows += ChatMessage(nextId++, conversation, "old", ChatRole.USER, "earlier question", 0L)
        rows += ChatMessage(nextId++, conversation, "old", ChatRole.AGENT, (1..30).joinToString("\n\n") { "line $it" }, 0L)
        publish()
        frames(60)
    }

    @After fun tearDown() {
        setAnimations(true)
        ShadowChoreographer.setPaused(false)
        controller.pause().stop().destroy()
        resetSpringFrames()
    }

    /**
     * Springs share one frame handler per thread, and the main thread outlives each test. A spring
     * still running when a test ends leaves the handler waiting for a frame from a looper that is
     * reset, and every later spring on the thread would freeze; start and leave it empty.
     */
    private fun resetSpringFrames() {
        Class.forName("androidx.dynamicanimation.animation.AnimationHandler")
            .getDeclaredField("sAnimatorHandler").apply { isAccessible = true }
            .let { (it.get(null) as ThreadLocal<*>).remove() }
    }

    private fun boundary() = flow.updateBoundary(composer.capsuleTop - timeline.y)

    private suspend fun admit(text: String, attachments: List<ComposerAttachment>): Boolean {
        if (refuse) return false
        val turn = requestKey(currentRequestId)
        if (text.isNotEmpty()) rows += ChatMessage(nextId++, conversation, turn, ChatRole.USER, text, 0L,
            status = MessageStatus.PENDING)
        attachments.forEach { _ -> rows += image(turn) }
        currentRequestId = "send-${++request}"
        if (commitBeforeReturn) publishNow()
        if (!commitBeforeReturn) activity.lifecycleScope.launchWhenCreated { publishNow() }
        return true
    }

    private fun image(turn: String) = ChatMessage(nextId++, conversation, turn, ChatRole.USER, "", 0L,
        status = MessageStatus.PENDING, cardKind = LiveRowKinds.ATTACHMENT,
        cardPayload = LiveRowKinds.encode(LiveRowKinds.Attachment(true, "sample.png", 160, 960)),
        attachment = ChatAttachment(MediaAttachment("sample.png", "image/png", null,
            MediaSource.UploadedFile("/uploads/abcdefghijklmnopqrstuv-sample.png")), ImageDimensions(160, 960)))

    private fun prepared(): List<PreparedChatMessage> = runBlocking {
        MessageLayoutPrecomputer().prepare(rows.toList(), timeline.width, density, 1f, false)
    }

    private suspend fun publishNow() = flow.submit(prepared())

    private fun publish() { activity.lifecycleScope.launchWhenCreated { publishNow() } }

    private fun frames(count: Int, each: (Int) -> Unit = {}) = repeat(count) {
        ShadowLooper.idleMainLooper(FRAME_MS, TimeUnit.MILLISECONDS)
        each(it)
    }

    private val input: EditText get() = ComposerView::class.java.getDeclaredField("editText").let {
        it.isAccessible = true; it.get(composer) as EditText
    }

    private fun draft(text: String, images: Int = 0) {
        input.setText(text)
        if (images > 0) ComposerView::class.java.getDeclaredMethod("addUris", List::class.java)
            .apply { isAccessible = true }
            .invoke(composer, List(images) { Uri.parse("content://sample/$it") })
        frames(30)
    }

    private fun send() = ComposerView::class.java.getDeclaredMethod("sendNow").apply { isAccessible = true }.invoke(composer)

    private fun lastUser(): ChatMessage = rows.last { it.role == ChatRole.USER }
    private fun textRow(turnIndex: Int = request - 1): ChatMessage =
        rows.first { it.turnId == requestKey("send-$turnIndex") && it.cardKind == null }

    /** The top of a row as drawn: laid out position plus the list's glide, in window px. */
    private fun drawnTop(id: Long): Float? = timeline.viewForRow(id)?.let { view ->
        val location = IntArray(2)
        timeline.getLocationInWindow(location)
        location[1] + view.y
    }

    /** Where [id]'s content rests in its row, as drawn now (glide included), in window px. */
    private fun targetBox(id: Long): FlightBox? {
        val view = timeline.viewForRow(id) ?: return null
        val bounds = android.graphics.RectF()
        if (!(view as surf.comma.android.chat.render.FlightTarget).flightBounds(bounds)) return null
        // The row as drawn: its laid-out place plus its translation (the glide), in window px.
        val location = IntArray(2)
        timeline.getLocationInWindow(location)
        val x = location[0] + view.x
        val y = location[1] + view.y
        return FlightBox(x + bounds.left, y + bounds.top, x + bounds.right, y + bounds.bottom)
    }

    private class Sample(val box: FlightBox?, val rowTop: Float?, val glide: Float, val target: FlightBox?)

    /** Steps frames until the flight is over, recording [id]'s piece and row after every frame. */
    private fun record(id: Long, maxFrames: Int = 120, during: (Int) -> Unit = {}): List<Sample> {
        val samples = ArrayList<Sample>()
        var frame = 0
        while (frame < maxFrames && (flight.isFlying || frame == 0)) {
            during(frame)
            frames(1)
            frame++
            samples += Sample(flight.presentedBox(id), drawnTop(id), timeline.glideOffsetPx, targetBox(id))
        }
        assertFalse("the flight lands within ${maxFrames * FRAME_MS} ms", flight.isFlying)
        return samples
    }

    private fun assertContinuous(label: String, values: List<Float>, maxStep: Float) {
        values.zipWithNext().forEachIndexed { index, (a, b) ->
            assertTrue("$label jumps ${b - a}px at frame $index: $values", abs(b - a) <= maxStep)
        }
    }

    /** Accelerations stay those of a spring: no frame changes speed by more than [maxChange]. */
    private fun assertSmooth(label: String, values: List<Float>, maxChange: Float) {
        values.zipWithNext { a, b -> b - a }.zipWithNext().forEachIndexed { index, (v0, v1) ->
            assertTrue("$label speed changes by ${v1 - v0}px/frame at frame $index: $values", abs(v1 - v0) <= maxChange)
        }
    }

    private fun assertRestingGap(id: Long) {
        val view = requireNotNull(timeline.viewForRow(id))
        assertEquals(0f, timeline.glideOffsetPx, 0f)
        assertEquals("24 dp above the capsule", activity.resources.getDimensionPixelSize(R.dimen.spacing_3xl),
            (composer.capsuleTop - timeline.y - view.bottom).roundToInt())
        assertEquals(0, timeline.bottomOffsetPx())
    }

    private fun assertAllShown() {
        assertTrue(timeline.hiddenRows.isEmpty())
        rows.forEach { row -> timeline.viewForRow(row.id)?.let { assertEquals("row ${row.id} shown", 1f, it.alpha, 0f) } }
    }

    @Test fun `short text leaves its source and lands on its row without a jump`() {
        draft("layout sample")
        val source = composer.captureSendSnapshot().textOrigin.y
        send()
        val id = lastUser().id
        val samples = record(id)
        val tops = samples.mapNotNull { it.box?.top }
        assertTrue("flew for a while: ${tops.size} frames", tops.size >= 10)
        assertTrue("starts in the composer", abs(tops.first() - source) < 80 * density)
        val last = samples.last { it.box != null && it.target != null }
        assertEquals("ends on the row's bubble", last.target!!.top, last.box!!.top, 1f)
        assertEquals(last.target.right, last.box.right, 1f)
        assertContinuous("text top", tops, maxStep = 60 * density)
        assertSmooth("text top", tops, maxChange = 14 * density)
        // The list made room on the same spring, also without a jump. Its first step is the new row's height, which the
        // rows' translation takes up; from there it only runs down.
        assertContinuous("glide", samples.map { it.glide }.dropWhile { it == 0f }, maxStep = 60 * density)
        assertAllShown()
        assertRestingGap(id)
    }

    /** Steps frames until no flight runs and the list has rested at its glide's end for a while. */
    private fun waitUntilStill() {
        var still = 0
        var frame = 0
        while (still < 10) {
            frames(1)
            still = if (!flight.isFlying && timeline.glideOffsetPx == 0f) still + 1 else 0
            assertTrue("the send settles", ++frame < 200)
        }
    }

    /**
     * A reply that comes after the send has fully settled: the typing row first, then the text in
     * its place. Neither may move what is on screen in one frame, whether the list fits or not.
     */
    private fun lateTypingAndReply(shortConversation: Boolean) {
        if (shortConversation) {
            rows.clear()
            rows += ChatMessage(nextId++, conversation, "old", ChatRole.USER, "earlier question", 0L)
            publish()
            frames(60)
        }
        draft("late reply sample")
        send()
        waitUntilStill()
        val sent = lastUser()
        val before = requireNotNull(drawnTop(sent.id))
        val tops = ArrayList<Float>()
        val sample: (Int) -> Unit = { drawnTop(sent.id)?.let(tops::add) }
        val typing = ChatMessage(nextId++, conversation, sent.turnId, ChatRole.AGENT, "", 0L,
            cardKind = TimelineBlockKinds.LIVE_STATUS)
        rows += typing
        publish()
        frames(45, sample)
        val afterTyping = tops.last()
        rows.remove(typing)
        val reply = ChatMessage(nextId++, conversation, sent.turnId, ChatRole.AGENT,
            "A late reply\n\nwith a second paragraph\n\nand a third one", 0L)
        rows += reply
        publish()
        frames(60, sample)
        assertTrue("typing made room: $before -> $afterTyping", afterTyping < before - 20 * density)
        assertTrue("the reply made room: $afterTyping -> ${tops.last()}", tops.last() < afterTyping - 20 * density)
        assertContinuous("sent row as drawn", listOf(before) + tops, maxStep = 16 * density)
        assertSmooth("sent row as drawn", listOf(before) + tops, maxChange = 10 * density)
        assertAllShown()
        assertRestingGap(reply.id)
    }

    @Test fun `streamed growth follows frame by frame without starting a glide`() {
        draft("streaming sample")
        send()
        waitUntilStill()
        val sent = lastUser()
        var text = "First words"
        val reply = ChatMessage(nextId++, conversation, sent.turnId, ChatRole.AGENT, text, 0L, status = MessageStatus.STREAMING)
        rows += reply
        publish()
        waitUntilStill()
        val glides = ArrayList<Float>()
        repeat(8) { step ->
            text += "\n\nmore streamed text $step"
            rows[rows.indexOfFirst { it.id == reply.id }] = reply.copy(text = text)
            publish()
            frames(4) { glides += timeline.glideOffsetPx }
        }
        assertTrue("growth of a row already there is followed 1:1: $glides", glides.all { it == 0f })
        frames(30)
        assertRestingGap(reply.id)
    }

    @Test fun `a late typing row and reply in a short conversation make room smoothly`() = lateTypingAndReply(true)

    @Test fun `a late typing row and reply below a full screen make room smoothly`() = lateTypingAndReply(false)

    @Test fun `in a short conversation the earlier rows glide up instead of jumping`() {
        rows.clear()
        rows += ChatMessage(nextId++, conversation, "old", ChatRole.USER, "earlier question", 0L)
        rows += ChatMessage(nextId++, conversation, "old", ChatRole.AGENT, "a short answer", 0L)
        publish()
        frames(60)
        val earlier = rows.last().id
        val before = requireNotNull(drawnTop(earlier))
        draft("layout sample")
        send()
        val tops = ArrayList<Float>()
        record(lastUser().id) { drawnTop(earlier)?.let(tops::add) }
        assertTrue("the earlier row moved up: $tops", tops.last() < before - 40 * density)
        assertContinuous("earlier row", listOf(before) + tops, maxStep = 40 * density)
        assertAllShown()
        assertRestingGap(lastUser().id)
    }

    @Test fun `a reply and its typing row arriving mid-flight do not move what is drawn`() {
        draft("layout sample")
        send()
        val id = lastUser().id
        val turn = lastUser().turnId
        var injectedAt = -1
        val samples = record(id) { frame ->
            if (frame == 6) {
                injectedAt = frame
                rows += ChatMessage(nextId++, conversation, turn, ChatRole.AGENT, "", 0L, cardKind = TimelineBlockKinds.LIVE_STATUS)
                publish()
            }
            if (frame == 9) {
                rows.removeAt(rows.lastIndex)
                rows += ChatMessage(nextId++, conversation, turn, ChatRole.AGENT, "A fast reply\n\nwith two paragraphs", 0L)
                publish()
            }
        }
        assertTrue(injectedAt >= 0)
        val tops = samples.mapNotNull { it.box?.top }
        val rowTops = samples.mapNotNull { it.rowTop }
        assertContinuous("text top", tops, maxStep = 60 * density)
        assertSmooth("text top", tops, maxChange = 14 * density)
        assertContinuous("row as drawn", rowTops, maxStep = 60 * density)
        assertAllShown()
        assertRestingGap(rows.last().id)
    }

    @Test fun `the composer shrinking and the keyboard moving carry the flight with the list`() {
        draft("first line\nsecond line\nthird line")
        send()
        val id = lastUser().id
        val samples = record(id) { frame ->
            // An IME-driven boundary moves per frame; the list and the flight follow it 1:1.
            if (frame in 4..12) timeline.setComposerInset(timeline.paddingBottom + (8 * density).toInt())
        }
        val gaps = samples.filter { it.box != null && it.target != null }.map { it.box!!.top - it.target!!.top }
        assertTrue("the piece converges on its row: $gaps", abs(gaps.last()) < 2f)
        assertSmooth("piece relative to its row", gaps, maxChange = 14 * density)
        frames(60)
        assertAllShown()
    }

    @Test fun `text with a tall image keeps the image below the text all the way`() {
        draft("layout sample", images = 1)
        send()
        val text = textRow().id
        val image = lastUser().id
        val boxes = ArrayList<Pair<FlightBox?, FlightBox?>>()
        var frame = 0
        while (frame < 150 && (flight.isFlying || frame == 0)) {
            frames(1)
            frame++
            boxes += flight.presentedBox(text) to flight.presentedBox(image)
        }
        assertFalse(flight.isFlying)
        val both = boxes.filter { it.first != null && it.second != null }
        assertTrue("both flew: ${both.size}", both.size >= 8)
        var imageLeft = false
        val source = both.first().second!!
        for ((t, i) in both) {
            val textBox = t!!
            val imageBox = i!!
            // Waiting in the strip above the text it was typed under, the image has not left yet.
            if (imageBox != source && imageBox.top < imageBox.bottom - 1f) {
                // Never across the text: the image's visible top stays under the text bubble.
                assertTrue("image top ${imageBox.top} under text bottom ${textBox.bottom}", imageBox.top >= textBox.bottom - 0.5f)
            }
            if (imageBox.bottom < composer.capsuleTop - timeline.y) imageLeft = true
        }
        assertTrue("the image left the composer", imageLeft)
        // It leaves later than the text, while the list is already moving, yet from rest.
        assertSmooth("image bottom", both.map { it.second!!.bottom }, maxChange = 14 * density)
        assertAllShown()
        assertRestingGap(image)
    }

    @Test fun `several tall images degrade to the list for targets off screen`() {
        draft("", images = 3)
        send()
        val ids = rows.filter { it.turnId == requestKey("send-0") }.map { it.id }
        assertEquals(3, ids.size)
        frames(90)
        assertFalse(flight.isFlying)
        assertAllShown()
        assertRestingGap(ids.last())
        assertTrue("earlier images can be scrolled to", timeline.canScrollVertically(-1))
    }

    @Test fun `a second send while the first flies lets both land`() {
        draft("first sample")
        send()
        val first = lastUser().id
        val firstTops = ArrayList<Float>()
        val sample: (Int) -> Unit = { flight.presentedBox(first)?.let { firstTops += it.top } }
        frames(5, sample)
        input.setText("second sample")
        frames(1, sample)
        send()
        val second = lastUser().id
        frames(5, sample)
        assertNotNull("the second one flies", flight.presentedBox(second))
        frames(80, sample)
        assertFalse(flight.isFlying)
        assertContinuous("first flight", firstTops, maxStep = 60 * density)
        assertAllShown()
        assertRestingGap(second)
    }

    @Test fun `rows committed only after the send returns still fly`() {
        commitBeforeReturn = false
        draft("late rows")
        send()
        frames(2)
        val id = lastUser().id
        val samples = record(id)
        assertTrue(samples.count { it.box != null } >= 10)
        assertAllShown()
        assertRestingGap(id)
    }

    @Test fun `a refused send leaves nothing behind`() {
        refuse = true
        draft("refused sample")
        send()
        frames(10)
        assertFalse(flight.isFlying)
        assertEquals("the composer keeps the draft", "refused sample", input.text.toString())
        assertAllShown()
    }

    @Test fun `another conversation cancels a flight and shows its rows`() {
        draft("switching sample")
        send()
        frames(3)
        assertTrue(flight.isFlying)
        flow.showConversation("c")
        flow.showConversation("other")
        frames(1)
        assertFalse(flight.isFlying)
        assertAllShown()
    }

    /** A conversation of short rows, then a send: the glide is taller than a row. */
    private fun glidingOverShortRows(): Long {
        rows.clear()
        repeat(30) { rows += ChatMessage(nextId++, conversation, "t$it", if (it % 2 == 0) ChatRole.USER else ChatRole.AGENT,
            "short row $it", 0L) }
        publish()
        frames(60)
        draft("gliding sample")
        send()
        frames(3)
        val glide = timeline.glideOffsetPx
        assertTrue("gliding: $glide", glide > 40 * density)
        return lastUser().id
    }

    /** A row that is not this send, whose drawn and laid-out places do not overlap. */
    private fun displacedRow(): android.view.View {
        val glide = timeline.glideOffsetPx
        return (0 until timeline.childCount).map(timeline::getChildAt).first { child ->
            child.alpha == 1f && child.height < glide && child.top + glide > timeline.paddingTop &&
                child.bottom + glide < timeline.chatBottomPx
        }
    }

    @Test fun `during a glide a long press lands on the row where it is drawn`() {
        glidingOverShortRows()
        val row = displacedRow()
        val pressed = ArrayList<Long>()
        timeline.onLongPressMessage = { _, item -> pressed += item.message.id }
        val x = timeline.width / 2f
        val y = row.y + row.height / 2f
        assertTrue("the drawn point is outside the row's layout", y > row.bottom)
        assertTrue("hit testing finds the drawn row", timeline.findChildViewUnder(x, y) === row)
        val expected = (row as surf.comma.android.chat.render.ChatMessageCell).let { cell ->
            timeline.getChildAdapterPosition(cell)
        }
        val now = SystemClock.uptimeMillis()
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0))
        frames((android.view.ViewConfiguration.getLongPressTimeout() / FRAME_MS + 4).toInt())
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0))
        assertEquals("the long press went to the row under the finger", 1, pressed.size)
        assertEquals(timeline.positionOf(pressed.single()), expected)
        frames(60)
        assertFalse(flight.isFlying)
        assertAllShown()
    }

    @Test fun `during a glide accessibility bounds are where the rows are drawn`() {
        glidingOverShortRows()
        val row = displacedRow()
        val node = row.createAccessibilityNodeInfo()
        val bounds = android.graphics.Rect()
        node.getBoundsInScreen(bounds)
        val screen = IntArray(2)
        timeline.getLocationOnScreen(screen)
        assertEquals("focus box top follows the glide", (screen[1] + row.y).toDouble(), bounds.top.toDouble(), 1.0)
        assertEquals((screen[1] + row.y + row.height).toDouble(), bounds.bottom.toDouble(), 1.0)
        node.recycle()
    }

    @Test fun `a drag during a glide takes over where the rows are drawn`() {
        val id = glidingOverShortRows()
        val row = displacedRow()
        val before = row.y
        val slop = android.view.ViewConfiguration.get(activity).scaledTouchSlop
        val x = timeline.width / 2f
        val y = before + row.height / 2f
        val now = SystemClock.uptimeMillis()
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0))
        // The list takes the gesture once it passes the slop; the glide becomes a scroll in place.
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now + 8, MotionEvent.ACTION_MOVE, x, y + slop + 1f, 0))
        assertEquals("the glide became a scroll", 0f, timeline.glideOffsetPx, 0f)
        assertEquals("nothing jumped when the drag began", before, row.y, 2f)
        // From then on the row follows the finger exactly.
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now + 16, MotionEvent.ACTION_MOVE, x, y + slop + 41f, 0))
        assertEquals("the row moves with the finger", before + 40f, row.y, 2f)
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now + 24, MotionEvent.ACTION_UP, x, y + slop + 41f, 0))
        assertFalse("reading history now", timeline.isPinnedToEnd())
        frames(90)
        assertFalse(flight.isFlying)
        assertAllShown()
    }

    @Test fun `a drag on a list shorter than the screen does not jump the gliding rows`() {
        rows.clear()
        rows += ChatMessage(nextId++, conversation, "old", ChatRole.USER, "earlier question", 0L)
        publish()
        frames(60)
        val earlier = rows.single().id
        draft("short list drag")
        send()
        frames(3)
        val before = requireNotNull(drawnTop(earlier))
        assertTrue(timeline.glideOffsetPx != 0f)
        val x = timeline.width / 2f
        val y = before + 10f
        val slop = android.view.ViewConfiguration.get(activity).scaledTouchSlop
        val now = SystemClock.uptimeMillis()
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x, y, 0))
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now + 8, MotionEvent.ACTION_MOVE, x, y + slop + 40f, 0))
        assertEquals("nothing jumped when the drag began", before, requireNotNull(drawnTop(earlier)), 2f)
        timeline.dispatchTouchEvent(MotionEvent.obtain(now, now + 16, MotionEvent.ACTION_UP, x, y + slop + 40f, 0))
        val tops = ArrayList<Float>()
        frames(90) { drawnTop(earlier)?.let(tops::add) }
        assertContinuous("earlier row", listOf(before) + tops, maxStep = 16 * density)
        assertFalse(flight.isFlying)
        assertAllShown()
    }

    @Test fun `with animations off the rows appear at rest at once`() {
        setAnimations(false)
        draft("no motion")
        send()
        frames(30)
        assertFalse(flight.isFlying)
        assertNull(flight.presentedBox(lastUser().id))
        assertAllShown()
        assertRestingGap(lastUser().id)
    }

    private fun setAnimations(enabled: Boolean) {
        ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .invoke(null, if (enabled) 1f else 0f)
    }

    private companion object {
        const val FRAME_MS = 16L
    }
}
