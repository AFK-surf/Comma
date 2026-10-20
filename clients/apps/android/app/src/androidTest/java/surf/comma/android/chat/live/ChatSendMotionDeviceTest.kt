package surf.comma.android.chat.live

import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.ViewTreeObserver
import android.view.animation.AnimationUtils
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import kotlin.math.abs
import kotlin.math.max

/**
 * Send motion on a device, frame by frame, through [ChatSendFlow] and the real views. Every drawn
 * frame records where each piece is drawn and where its row is; the series are written as CSV
 * next to the screenshots, and checked for jumps: a frame that moves a piece several times more
 * than the frames on either side of it. Pauses between cases leave room for a screen recording.
 */
class ChatSendMotionDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(1200); instrumentation.waitForIdleSync() }
    private val output = File(instrumentation.targetContext.getExternalFilesDir(null), "chat-motion-check").apply { mkdirs() }

    private class Frame(val nanos: Long, val frameMs: Long, val boxes: Map<Long, FlightBox?>, val targets: Map<Long, FlightBox?>, val glide: Float)

    /** Records every frame the timeline draws until the flight is over (or [maxMillis]). */
    private fun recordFlight(fixture: ChatSendFixture, name: String, ids: () -> List<Long>, maxMillis: Long = 2500,
                             untilLanded: Boolean = true, during: (Long) -> Unit = {}): List<Frame> {
        val frames = ArrayList<Frame>()
        val start = SystemClock.uptimeMillis()
        val listener = ViewTreeObserver.OnPreDrawListener {
            val rows = ids()
            frames += Frame(System.nanoTime(), AnimationUtils.currentAnimationTimeMillis(), rows.associateWith { fixture.flight.presentedBox(it) },
                rows.associateWith { fixture.targetBox(it) }, fixture.timeline.glideOffsetPx)
            true
        }
        main { fixture.timeline.viewTreeObserver.addOnPreDrawListener(listener) }
        Log.i(TAG, "case $name start")
        while (SystemClock.uptimeMillis() - start < maxMillis) {
            during(SystemClock.uptimeMillis() - start)
            SystemClock.sleep(8)
            var flying = true
            main { flying = fixture.flight.isFlying }
            if (untilLanded && !flying && SystemClock.uptimeMillis() - start > 200) break
        }
        main { fixture.timeline.viewTreeObserver.removeOnPreDrawListener(listener) }
        Log.i(TAG, "case $name end after ${frames.size} frames")
        write(name, frames)
        return frames
    }

    private fun write(name: String, frames: List<Frame>) {
        val ids = frames.flatMap { it.boxes.keys }.distinct()
        File(output, "$name.csv").printWriter().use { out ->
            out.println("ms,frame_ms,glide," + ids.joinToString(",") { "piece${it}_l,piece${it}_t,piece${it}_r,piece${it}_b,row${it}_t,row${it}_b" })
            val t0 = frames.firstOrNull()?.nanos ?: 0L
            frames.forEach { frame ->
                out.println("${(frame.nanos - t0) / 1_000_000.0},${frame.frameMs},${frame.glide}," + ids.joinToString(",") { id ->
                    val b = frame.boxes[id]
                    val r = frame.targets[id]
                    "${b?.left ?: ""},${b?.top ?: ""},${b?.right ?: ""},${b?.bottom ?: ""},${r?.top ?: ""},${r?.bottom ?: ""}"
                })
            }
        }
    }

    /**
     * A jump: between two frames a piece's edge moves 3x faster than across the frames on either
     * side, and visibly so. Speeds are per millisecond of animation time, so a dropped frame (a
     * longer step in the same motion) is not a jump; two draws in one vsync count as one.
     */
    private fun assertNoJumps(name: String, frames: List<Frame>, id: Long, relativeToRow: Boolean = false) {
        val density = instrumentation.targetContext.resources.displayMetrics.density
        val drawn = frames.filter { it.boxes[id] != null && (!relativeToRow || it.targets[id] != null) }
            .associateBy { it.frameMs }.values.sortedBy { it.frameMs }
        fun FlightBox.edge(edge: Int) = when (edge) { 0 -> left; 1 -> top; 2 -> right; else -> bottom }
        for (edge in 0..3) {
            val values = drawn.map { frame ->
                val box = frame.boxes.getValue(id)!!
                // Under a finger the list moves as the finger does; the flight is what moves on top of it.
                if (relativeToRow) box.edge(edge) - frame.targets.getValue(id)!!.edge(edge) else box.edge(edge)
            }
            val speeds = values.indices.drop(1).map { i ->
                abs(values[i] - values[i - 1]) / (drawn[i].frameMs - drawn[i - 1].frameMs).coerceAtLeast(1)
            }
            for (i in 1 until speeds.size - 1) {
                val neighbours = max(speeds[i - 1], speeds[i + 1])
                assertTrue("$name piece $id edge $edge moves ${speeds[i]}px/ms at frame $i (neighbours $neighbours): $values",
                    speeds[i] <= 3f * neighbours + 0.75f * density)
            }
        }
    }

    /** The same jump test on a row as the list draws it (glide included), for moves with no flight. */
    private fun assertRowNoJumps(name: String, frames: List<Frame>, id: Long) {
        val density = instrumentation.targetContext.resources.displayMetrics.density
        val drawn = frames.filter { it.targets[id] != null }.associateBy { it.frameMs }.values.sortedBy { it.frameMs }
        val values = drawn.map { it.targets.getValue(id)!!.top }
        val speeds = values.indices.drop(1).map { i ->
            abs(values[i] - values[i - 1]) / (drawn[i].frameMs - drawn[i - 1].frameMs).coerceAtLeast(1)
        }
        for (i in 1 until speeds.size - 1) {
            val neighbours = max(speeds[i - 1], speeds[i + 1])
            assertTrue("$name row $id moves ${speeds[i]}px/ms at frame $i (neighbours $neighbours): $values",
                speeds[i] <= 3f * neighbours + 0.75f * density)
        }
        assertTrue("$name: row $id moved", values.isNotEmpty() && values.first() - values.last() > 20 * density)
    }

    private fun waitUntilStill(fixture: ChatSendFixture) {
        var still = 0
        while (still < 10) {
            SystemClock.sleep(16)
            var quiet = false
            main { quiet = !fixture.flight.isFlying && fixture.timeline.glideOffsetPx == 0f }
            still = if (quiet) still + 1 else 0
        }
    }

    private fun assertLanded(name: String, fixture: ChatSendFixture) {
        main {
            assertFalse("$name: flight over", fixture.flight.isFlying)
            assertTrue("$name: rows shown", fixture.timeline.hiddenRows.isEmpty())
            fixture.rows.forEach { row ->
                fixture.timeline.viewForRow(row.id)?.let { assertTrue("$name: row ${row.id} visible", it.alpha == 1f) }
            }
            fixture.assertGap()
        }
    }

    @Test fun sendMotionStaysContinuous() {
        ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
            lateinit var fixture: ChatSendFixture
            scenario.onActivity { fixture = ChatSendFixture(it) }
            settle()
            // The screen recording starts once this line appears, with the fixture in front.
            main {
                val at = IntArray(2)
                fixture.marker.getLocationOnScreen(at)
                Log.i(TAG, "marker ${at[0]} ${at[1]} ${fixture.marker.width}")
            }
            Log.i(TAG, "fixture ready")
            SystemClock.sleep(3000)
            main { fixture.draft("Earlier message", 0); fixture.send() }
            settle()

            // 1. Short text with the keyboard open.
            main { fixture.mark(1) }
            main { fixture.keyboard(true); fixture.draft("Short sample", 0) }
            settle()
            main { fixture.send() }
            var ids = fixture.lastSend().map { it.id }
            recordFlight(fixture, "01-short-text", { ids }).also { assertNoJumps("short", it, ids.single()) }
            settle(); assertLanded("short", fixture)

            // 2. Several lines; the keyboard closes while it flies.
            main { fixture.mark(2) }
            main { fixture.draft("First line of a sample\nsecond line\nthird line", 0) }
            settle()
            main { fixture.send() }
            ids = fixture.lastSend().map { it.id }
            var closed = false
            recordFlight(fixture, "02-multiline-keyboard-closes", { ids }) { ms ->
                if (!closed && ms > 90) { closed = true; main { fixture.keyboard(false) } }
            }.also { assertNoJumps("multiline", it, ids.single()) }
            settle(); assertLanded("multiline", fixture)

            // 3. Text and a tall image: the image stays under the text.
            main { fixture.mark(3) }
            main { fixture.keyboard(true); fixture.draft("Text with a tall image", 1) }
            settle()
            main { fixture.send() }
            ids = fixture.lastSend().map { it.id }
            val mixed = recordFlight(fixture, "03-text-tall-image", { ids })
            ids.forEach { assertNoJumps("mixed", mixed, it) }
            val source = mixed.firstNotNullOfOrNull { it.boxes[ids[1]] }
            mixed.forEach { frame ->
                val text = frame.boxes[ids[0]] ?: return@forEach
                val image = frame.boxes[ids[1]] ?: return@forEach
                if (image != source && image.bottom - image.top > 1f) {
                    assertTrue("image top ${image.top} under text bottom ${text.bottom}", image.top >= text.bottom - 1f)
                }
            }
            settle(); assertLanded("mixed", fixture)

            // 4. Three tall images; the ones that rest off screen are left to the list.
            main { fixture.mark(4) }
            main { fixture.draft("", 3) }
            settle()
            main { fixture.send() }
            ids = fixture.lastSend().map { it.id }
            recordFlight(fixture, "04-three-images", { ids }).also { frames -> ids.forEach { assertNoJumps("images", frames, it) } }
            settle(); assertLanded("images", fixture)

            // 5. A second send while the first flies.
            main { fixture.mark(5) }
            main { fixture.draft("First of two", 0); fixture.send() }
            val first = fixture.lastSend().map { it.id }
            SystemClock.sleep(110)
            main { fixture.draft("Second of two", 0); fixture.send() }
            val second = fixture.lastSend().map { it.id }
            recordFlight(fixture, "05-two-sends", { first + second }).also {
                assertNoJumps("two sends (first)", it, first.single())
                assertNoJumps("two sends (second)", it, second.single())
            }
            settle(); assertLanded("two sends", fixture)

            // 6. A fast reply: typing at once, the text soon after, both while the piece flies.
            main { fixture.mark(6) }
            main { fixture.draft("Question with a fast reply", 0) }
            settle()
            main { fixture.send() }
            ids = fixture.lastSend().map { it.id }
            val turn = fixture.lastSend().first().turnId
            var typed = false
            var replied = false
            recordFlight(fixture, "06-fast-reply", { ids }) { ms ->
                if (!typed && ms > 40) { typed = true; main { fixture.typing(turn) } }
                if (!replied && ms > 160) { replied = true; main { fixture.reply(turn, "A fast reply\n\nin two paragraphs") } }
            }.also { assertNoJumps("fast reply", it, ids.single()) }
            settle(); assertLanded("fast reply", fixture)

            // 7. After the send has fully settled, a typing row and then the reply arrive late.
            main { fixture.mark(7) }
            main { fixture.draft("Late reply sample", 0) }
            settle()
            main { fixture.send() }
            val late = fixture.lastSend().single()
            waitUntilStill(fixture)
            SystemClock.sleep(300)
            var lateTyping = false
            var lateReply = false
            recordFlight(fixture, "07-late-typing-reply", { listOf(late.id) }, maxMillis = 1800, untilLanded = false) { ms ->
                if (!lateTyping && ms > 50) { lateTyping = true; main { fixture.typing(late.turnId) } }
                if (!lateReply && ms > 900) {
                    lateReply = true
                    main { fixture.reply(late.turnId, "A late reply\n\nwith a second paragraph\n\nand a third one") }
                }
            }.also { assertRowNoJumps("late typing and reply", it, late.id) }
            settle(); assertLanded("late typing and reply", fixture)

            // 8. A finger lands on the list mid-flight and drags it.
            main { fixture.mark(8) }
            main { fixture.draft("Dragged while flying", 0) }
            settle()
            main { fixture.send() }
            ids = fixture.lastSend().map { it.id }
            var dragged = false
            recordFlight(fixture, "08-drag", { ids }) { ms ->
                if (!dragged && ms > 80) { dragged = true; drag(fixture) }
            }.also { assertNoJumps("drag", it, ids.single(), relativeToRow = true) }
            settle()
            main {
                assertFalse(fixture.flight.isFlying)
                assertTrue(fixture.timeline.hiddenRows.isEmpty())
            }
        }
    }

    private fun drag(fixture: ChatSendFixture) {
        var x = 0f
        var y = 0f
        main {
            val location = IntArray(2)
            fixture.timeline.getLocationOnScreen(location)
            x = location[0] + fixture.timeline.width / 2f
            y = location[1] + fixture.timeline.height / 3f
        }
        val down = SystemClock.uptimeMillis()
        instrumentation.sendPointerSync(MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0))
        for (step in 1..8) {
            val time = down + step * 16L
            instrumentation.sendPointerSync(MotionEvent.obtain(down, time, MotionEvent.ACTION_MOVE, x, y + step * 30f, 0))
        }
        instrumentation.sendPointerSync(MotionEvent.obtain(down, down + 150, MotionEvent.ACTION_UP, x, y + 240f, 0))
    }

    private companion object {
        const val TAG = "ChatSendMotion"
    }
}
