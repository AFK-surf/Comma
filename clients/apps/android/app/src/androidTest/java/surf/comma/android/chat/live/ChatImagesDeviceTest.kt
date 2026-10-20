package surf.comma.android.chat.live

import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.Window
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import surf.comma.android.media.MediaGraph
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import java.util.Collections

/** Same assets/window/refresh rate for before/after; never record a performance run. */
class ChatImagesDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val args = InstrumentationRegistry.getArguments()
    private val output = File(instrumentation.targetContext.getExternalFilesDir(null), "chat-images-check").apply { mkdirs() }
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(1400); instrumentation.waitForIdleSync() }

    @Test fun images() {
        val performance = args.getString("imagesMode") == "performance"
        val worker = HandlerThread("image-frame-metrics").apply { start() }
        ComposerDemoActivity.fixtureNightMode = if (args.getString("imagesTheme") == "dark")
            android.content.res.Configuration.UI_MODE_NIGHT_YES else android.content.res.Configuration.UI_MODE_NIGHT_NO
        try {
            ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
                lateinit var activity: ComposerDemoActivity
                scenario.onActivity { activity = it; it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
                main {
                    assertEquals(args.getString("imagesTheme") == "dark",
                        activity.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES)
                    assertEquals(args.getString("imagesAnimationsOff") != "true", android.animation.ValueAnimator.areAnimatorsEnabled())
                }
                val metrics = Collections.synchronizedList(ArrayList<String>())
                val listener = Window.OnFrameMetricsAvailableListener { _, frame, dropped ->
                    metrics += listOf(FrameMetrics.INTENDED_VSYNC_TIMESTAMP, FrameMetrics.TOTAL_DURATION,
                        FrameMetrics.LAYOUT_MEASURE_DURATION, FrameMetrics.DRAW_DURATION, FrameMetrics.SYNC_DURATION,
                        FrameMetrics.COMMAND_ISSUE_DURATION, FrameMetrics.SWAP_BUFFERS_DURATION, FrameMetrics.GPU_DURATION)
                        .joinToString(",") { frame.getMetric(it).toString() } + ",$dropped"
                }
                main { activity.window.addOnFrameMetricsAvailableListener(listener, Handler(worker.looper)) }
                val sizes = if (performance) List(10) { Triple(160, 960, false) } else listOf(
                    Triple(960, 540, false), Triple(640, 640, false), Triple(160, 960, false),
                    Triple(160, 3200, false), Triple(640, 640, true), Triple(160, 960, false),
                    Triple(960, 540, false), Triple(640, 640, false))
                try {
                    sizes.forEachIndexed { index, (width, height, transparent) ->
                        lateinit var fixture: ChatSendFixture
                        main { fixture = ChatSendFixture(activity, width, height, transparent); fixture.mark(index + 1) }
                        settle()
                        if (index == 0 && !performance) {
                            File(output, "ready").writeText("ready")
                            SystemClock.sleep(3500)
                        }
                        if (performance && index % 2 == 0) runBlocking { MediaGraph.get(activity).images().clearCaches() }
                        main { fixture.draft(if (!performance && index == 2) "Text with an image" else "", if (performance || index == 5) 3 else 1) }
                        settle()
                        val delayed = !performance && index == 6
                        val failed = !performance && index == 7
                        val loader = runBlocking { MediaGraph.get(activity).images() }
                        if (delayed) main { loader.setFastScrolling(true) }
                        val savedFile = File(fixture.sampleFile.path + ".held")
                        if (failed) {
                            runBlocking { loader.clearCaches() }
                            check(fixture.sampleFile.renameTo(savedFile))
                        }
                        metrics.clear()
                        val start = System.nanoTime()
                        main { fixture.send() }
                        SystemClock.sleep(2200)
                        val end = System.nanoTime()
                        val captured = synchronized(metrics) { metrics.toList() }
                        val label = if (performance) (if (index % 2 == 0) "cold" else "warm") else "visual"
                        File(output, "$label-$index.csv").writeText("# start=$start,end=$end,refresh=${activity.display?.refreshRate}\n" +
                            "vsync,total,layout,draw,sync,command,swap,gpu,dropped\n" + captured.joinToString("\n"))
                        main {
                            assertFalse(fixture.flight.isFlying)
                            assertTrue(fixture.timeline.hiddenRows.isEmpty())
                            fixture.assertGap()
                        }
                        if (delayed || failed) {
                            lateinit var image: surf.comma.android.media.SendImagePresentation
                            var oldHeight = 0
                            main {
                                val row = fixture.timeline.viewForRow(fixture.lastSend().last().id) as AttachmentView
                                image = requireNotNull(row.flightImage)
                                oldHeight = row.height
                                assertNotNull("preview survives geometric landing", image.preview)
                                assertNull("HD not yet available", image.target)
                            }
                            if (delayed) main { loader.setFastScrolling(false) }
                            if (failed) {
                                check(savedFile.renameTo(fixture.sampleFile))
                                main {
                                    fun clickRetry(view: android.view.View) {
                                        if (view is android.widget.TextView && view.text.toString() == activity.getString(surf.comma.android.R.string.media_viewer_load_failed))
                                            view.performClick()
                                        if (view is android.view.ViewGroup) for (i in 0 until view.childCount) clickRetry(view.getChildAt(i))
                                    }
                                    clickRetry(fixture.timeline)
                                }
                            }
                            settle()
                            main {
                                assertNotNull("decode/retry provides drawable", image.target)
                                assertNull("preview released after clarity handoff", image.preview)
                                assertEquals(oldHeight, fixture.timeline.viewForRow(fixture.lastSend().last().id)!!.height)
                            }
                        }
                        settle()
                    }
                } finally {
                    main { activity.window.removeOnFrameMetricsAvailableListener(listener) }
                    if (!performance) {
                        File(output, "done").writeText("done")
                        // The recorder acknowledges its exact PID has stopped before the fixture exits.
                        val deadline = SystemClock.uptimeMillis() + 30_000
                        while (!File(output, "stopped").exists() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(50)
                    }
                }
            }
        } finally {
            ComposerDemoActivity.fixtureNightMode = null
            worker.quitSafely()
        }
    }
}
