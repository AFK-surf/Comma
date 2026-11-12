package surf.comma.android.ui.composer

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class DictationModelTest {
    private class Capture(private val audio: ByteArray? = byteArrayOf(1, 2, 3)) : DictationCapture {
        override var level = 0.5f
        var stopped = 0
        var discarded = 0
        override suspend fun stop(): ByteArray? { stopped++; return audio }
        override fun discard() { discarded++ }
    }

    private class Microphone(var capture: Capture = Capture()) : DictationMicrophone {
        var starts = 0
        var refusal: Exception? = null
        /** Holds a start back, as a slow audio session does. */
        var gate: CompletableDeferred<Unit>? = null
        var ended: (() -> Unit)? = null
        override suspend fun start(ended: () -> Unit): DictationCapture {
            starts++
            gate?.await()
            refusal?.let { throw it }
            this.ended = ended
            return capture
        }
    }

    private class Rig(scope: TestScope) {
        val microphone = Microphone()
        var answer: suspend (ByteArray) -> String = { "words" }
        var permission: suspend () -> Boolean = { true }
        val inserted = ArrayList<String>()
        val failures = ArrayList<DictationFailure>()
        val phases = ArrayList<DictationPhase>()
        val model = DictationModel(kotlinx.coroutines.CoroutineScope(scope.backgroundScope.coroutineContext + UnconfinedTestDispatcher(scope.testScheduler)), microphone,
            { permission() }, { answer(it) }, failures::add, phases::add)
        fun toggle() = model.toggle { inserted += it }
    }

    @Test fun `a tap records, the next transcribes, and the words arrive`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        assertEquals(DictationPhase.RECORDING, rig.model.phase)
        assertTrue(rig.model.capturing)
        assertEquals(0.5f, rig.model.level)
        rig.toggle()
        assertEquals(listOf("words"), rig.inserted)
        assertEquals(listOf(DictationPhase.RECORDING, DictationPhase.TRANSCRIBING, DictationPhase.IDLE), rig.phases)
        assertEquals(1, rig.microphone.capture.stopped)
        assertEquals(0, rig.microphone.capture.discarded)
    }

    @Test fun `the recording stops and transcribes by itself at the limit`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        advanceTimeBy(DictationModel.MAX_RECORDING_MS - 1)
        assertEquals(DictationPhase.RECORDING, rig.model.phase)
        advanceTimeBy(2)
        assertEquals(listOf("words"), rig.inserted)
    }

    @Test fun `the system taking the microphone transcribes what there is`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        rig.microphone.ended!!()
        assertEquals(listOf("words"), rig.inserted)
    }

    @Test fun `a late end of an old recording does not touch the next`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        val old = rig.microphone.ended!!
        rig.model.cancel()
        rig.microphone.capture = Capture()
        rig.toggle()
        old()
        assertEquals(DictationPhase.RECORDING, rig.model.phase)
    }

    @Test fun `only one transcription runs, and a tap during it does nothing`() = runTest {
        val rig = Rig(this)
        val held = CompletableDeferred<String>()
        rig.answer = { held.await() }
        rig.toggle()
        rig.toggle()
        rig.toggle()
        assertEquals(DictationPhase.TRANSCRIBING, rig.model.phase)
        assertEquals(1, rig.microphone.starts)
        held.complete("late")
        runCurrent()
        assertEquals(listOf("late"), rig.inserted)
    }

    @Test fun `cancelling drops the recording`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        rig.model.cancel()
        assertEquals(DictationPhase.IDLE, rig.model.phase)
        assertEquals(1, rig.microphone.capture.discarded)
        assertEquals(0, rig.microphone.capture.stopped)
        assertTrue(rig.inserted.isEmpty())
        assertTrue(rig.failures.isEmpty())
    }

    @Test fun `cancelling drops a late transcription`() = runTest {
        val rig = Rig(this)
        val held = CompletableDeferred<String>()
        rig.answer = { held.await() }
        rig.toggle()
        rig.toggle()
        rig.model.cancel()
        held.complete("late")
        runCurrent()
        assertTrue(rig.inserted.isEmpty())
        assertTrue(rig.failures.isEmpty())
    }

    @Test fun `a recording that starts after it was dropped is let go`() = runTest {
        val rig = Rig(this)
        val gate = CompletableDeferred<Unit>()
        rig.microphone.gate = gate
        rig.toggle()
        rig.model.cancel()
        gate.complete(Unit)
        runCurrent()
        assertEquals(1, rig.microphone.capture.discarded)
        assertFalse(rig.model.capturing)
    }

    @Test fun `a tap while the microphone starts has nothing to transcribe`() = runTest {
        val rig = Rig(this)
        val gate = CompletableDeferred<Unit>()
        rig.microphone.gate = gate
        rig.toggle()
        rig.toggle()
        assertEquals(listOf(DictationFailure.NOTHING_RECORDED), rig.failures)
        gate.complete(Unit)
        runCurrent()
        assertEquals(1, rig.microphone.capture.discarded)
    }

    @Test fun `each failure says why and inserts nothing`() = runTest {
        fun expect(failure: DictationFailure, arrange: Rig.() -> Unit) {
            val rig = Rig(this)
            rig.arrange()
            rig.toggle()
            if (rig.model.busy) rig.toggle()
            assertEquals(listOf(failure), rig.failures)
            assertTrue(rig.inserted.isEmpty())
            assertEquals(DictationPhase.IDLE, rig.model.phase)
        }
        expect(DictationFailure.MICROPHONE_DENIED) { permission = { false } }
        expect(DictationFailure.VOICE_CALL) { microphone.refusal = DictationRefused(DictationFailure.VOICE_CALL) }
        expect(DictationFailure.MICROPHONE_UNAVAILABLE) { microphone.refusal = IllegalStateException() }
        expect(DictationFailure.NOTHING_RECORDED) { microphone.capture = Capture(audio = null) }
        expect(DictationFailure.NOTHING_RECORDED) { microphone.capture = Capture(audio = ByteArray(0)) }
        expect(DictationFailure.NO_SPEECH) { answer = { "  \n" } }
        expect(DictationFailure.TRANSCRIPTION_FAILED) { answer = { throw IllegalStateException() } }
    }

    @Test fun `leaving the app transcribes what there is, or drops a recording not begun`() = runTest {
        val rig = Rig(this)
        rig.toggle()
        rig.model.leftApp()
        assertEquals(listOf("words"), rig.inserted)
        val waiting = Rig(this)
        waiting.permission = { CompletableDeferred<Boolean>().await() }
        waiting.toggle()
        waiting.model.leftApp()
        assertEquals(DictationPhase.IDLE, waiting.model.phase)
        assertTrue(waiting.failures.isEmpty())
    }

    private fun press(rig: Rig) = DictationPress({ rig.model.phase }, { rig.model.asking }, rig::toggle)

    @Test fun `a hold that lifts while the microphone starts leaves it off`() = runTest {
        val rig = Rig(this)
        val gate = CompletableDeferred<Unit>()
        rig.microphone.gate = gate
        val press = press(rig)
        press.down(1_000)
        press.up(1_400, cancelled = false)
        assertEquals(DictationPhase.IDLE, rig.model.phase)
        assertEquals(listOf(DictationFailure.NOTHING_RECORDED), rig.failures)
        gate.complete(Unit)
        runCurrent()
        assertEquals(1, rig.microphone.capture.discarded)
    }

    @Test fun `a hold that lifts under the permission prompt leaves the prompt up`() = runTest {
        val rig = Rig(this)
        val answer = CompletableDeferred<Boolean>()
        rig.permission = { answer.await() }
        val press = press(rig)
        press.down(1_000)
        press.up(2_000, cancelled = true)
        assertEquals(DictationPhase.RECORDING, rig.model.phase)
        answer.complete(true)
        runCurrent()
        assertTrue(rig.model.capturing)
        assertFalse(rig.model.asking)
    }

    @Test fun `a hold whose start failed does not start again on the lift`() = runTest {
        val rig = Rig(this)
        rig.microphone.refusal = DictationRefused(DictationFailure.VOICE_CALL)
        val press = press(rig)
        press.down(1_000)
        press.up(1_400, cancelled = false)
        assertEquals(1, rig.microphone.starts)
        assertEquals(DictationPhase.IDLE, rig.model.phase)
    }
}

class DictationPressTest {
    private var phase = DictationPhase.IDLE
    private var asking = false
    private var toggles = 0
    private val press = DictationPress({ phase }, { asking }) {
        toggles++
        phase = if (phase == DictationPhase.IDLE) DictationPhase.RECORDING else DictationPhase.TRANSCRIBING
    }

    @Test fun `a tap starts a recording that keeps running`() {
        press.down(1_000)
        press.up(1_349, cancelled = false)
        assertEquals(1, toggles)
        assertEquals(DictationPhase.RECORDING, phase)
    }

    @Test fun `a hold records until the finger lifts`() {
        press.down(1_000)
        press.up(1_350, cancelled = false)
        assertEquals(DictationPhase.TRANSCRIBING, phase)
    }

    @Test fun `a hold that lifts under the permission prompt ends nothing`() {
        asking = true
        press.down(1_000)
        press.up(2_000, cancelled = true)
        assertEquals(1, toggles)
    }

    @Test fun `a tap on the capsule ends the recording, a cancelled touch does not`() {
        phase = DictationPhase.RECORDING
        press.down(1_000)
        press.up(1_010, cancelled = true)
        assertEquals(0, toggles)
        press.down(2_000)
        press.up(2_010, cancelled = false)
        assertEquals(1, toggles)
    }
}

class DictationEditTest {
    private fun apply(text: String, start: Int, end: Int, words: String): String {
        val edit = dictationEdit(text, start, end, words)
        return text.replaceRange(edit.start, edit.end, edit.inserted)
    }

    @Test fun `words go at the caret and replace a selection`() {
        assertEquals("say hello now", apply("say  now", 4, 4, "hello"))
        assertEquals("say hello now", apply("say that now", 4, 8, "hello"))
        assertEquals("say hello now", apply("say that now", 8, 4, "hello"))
    }

    @Test fun `no caret means the end of the draft`() {
        assertEquals("draft words", apply("draft", -1, -1, "words"))
        assertEquals("draft words", apply("draft", 40, 40, "words"))
    }

    @Test fun `a space keeps words apart from a neighbour`() {
        assertEquals("one two three", apply("onethree", 3, 3, "two"))
        assertEquals("words", apply("", 0, 0, "words"))
    }

    @Test fun `punctuation holds on to its neighbour`() {
        assertEquals("one two.", apply("one.", 3, 3, "two"))
        assertEquals("(two)", apply("()", 1, 1, "two"))
        assertEquals("one, two", apply("one,", 4, 4, "two"))
    }

    @Test fun `korean is written with spaces`() {
        assertEquals("안녕 세계", apply("안녕", 2, 2, "세계"))
    }

    @Test fun `scripts written without spaces join as they are`() {
        assertEquals("你好世界", apply("你好", 2, 2, "世界"))
        assertEquals("draft你好", apply("draft", 5, 5, "你好"))
    }

    @Test fun `the caret follows the words`() {
        val edit = dictationEdit("onethree", 3, 3, "two")
        assertEquals(" two ", edit.inserted)
        assertEquals(8, edit.start + edit.inserted.length)
    }
}

class DictationStripTest {
    @Test fun `the clock starts on the first frame, however long after the reset`() {
        val strip = DictationStrip()
        strip.reset()
        strip.advance(90_000, 0f)
        assertEquals(0, strip.entered)
        assertEquals(0f, strip.travelled)
        strip.advance(90_060, 0f)
        strip.advance(90_000 + DictationStrip.INTERVAL_MS, 0f)
        assertEquals(1, strip.entered)
    }

    @Test fun `a stall does not jump the strip ahead`() {
        val strip = DictationStrip()
        strip.advance(0, 0f)
        strip.advance(16, 0f)
        strip.advance(1_016, 0f)
        assertEquals(32f / DictationStrip.INTERVAL_MS, strip.travelled)
        assertEquals(0, strip.entered)
    }

    @Test fun `a bar takes the highest level heard since the last`() {
        val strip = DictationStrip()
        strip.advance(0, 0.2f)
        strip.advance(60, 0.9f)
        strip.advance(90, 0.3f)
        strip.advance(120, 0.1f)
        assertEquals(1, strip.entered)
        assertEquals(0.9f, strip.height(0))
        strip.advance(180, 0.1f)
        strip.advance(240, 0.1f)
        assertEquals(0.1f, strip.height(1))
    }

    @Test fun `a bar grows slowly at both ends of its time`() {
        val strip = DictationStrip()
        fun growthAt(age: Long): Float {
            var time = 0L
            strip.advance(time, 1f)
            while (time < DictationStrip.INTERVAL_MS + age) {
                time += 50
                strip.advance(minOf(time, DictationStrip.INTERVAL_MS + age), 1f)
            }
            return strip.growth(0)
        }
        assertEquals(0f, growthAt(0))
        strip.reset()
        assertEquals(0.5f, growthAt(350), 0.001f)
        strip.reset()
        assertEquals(1f, growthAt(700))
    }

    @Test fun `a new recording starts over`() {
        val strip = DictationStrip()
        strip.advance(0, 1f)
        strip.advance(90, 1f)
        strip.advance(180, 1f)
        strip.reset()
        strip.advance(5_000, 0f)
        assertEquals(0, strip.entered)
        assertEquals(0f, strip.travelled)
        assertEquals(0f, strip.height(0))
    }
}

class DictationLevelTest {
    @Test fun `silence reads as nothing and full scale as one`() {
        assertEquals(0f, dictationLevel(0))
        assertEquals(0f, dictationLevel(50))
        assertEquals(1f, dictationLevel(32767))
        assertTrue(dictationLevel(3000) in 0.5f..0.7f)
    }
}
