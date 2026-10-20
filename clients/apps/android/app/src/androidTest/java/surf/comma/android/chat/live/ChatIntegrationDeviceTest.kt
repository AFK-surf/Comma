package surf.comma.android.chat.live

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.SystemClock
import androidx.core.content.FileProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import surf.comma.android.R
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.ViewerImage
import surf.comma.android.ui.composer.ComposerSendSnapshot
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/** Latest chrome and send motion together, with generated, distinct full-size local images. */
class ChatIntegrationDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val output = File(instrumentation.targetContext.getExternalFilesDir(null), "chat-integration-check").apply { mkdirs() }
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun settle() { SystemClock.sleep(1500); instrumentation.waitForIdleSync() }

    @Test fun lightCardAndThreeDistinctImages() = checkIntegration(false)
    @Test fun darkCardAndThreeDistinctImages() = checkIntegration(true)

    private fun checkIntegration(dark: Boolean) {
        val label = if (dark) "dark" else "light"
        ComposerDemoActivity.fixtureNightMode = if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        try {
            ActivityScenario.launch(ComposerDemoActivity::class.java).use { scenario ->
                lateinit var activity: ComposerDemoActivity
                lateinit var fixture: ChatSendFixture
                scenario.onActivity {
                    activity = it
                    it.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    fixture = ChatSendFixture(it, showChrome = true)
                }
                settle()
                main { fixture.draft("hi", 0) }
                settle()
                lateinit var sent: ComposerSendSnapshot
                var fill = 0
                main {
                    assertEquals(dark, activity.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES)
                    assertTrue(android.animation.ValueAnimator.areAnimatorsEnabled())
                    sent = fixture.composer.captureSendSnapshot()
                    fill = activity.getColor(R.color.token_composer_bg)
                    fixture.flight.hold(sent, "held-source")
                    fixture.draft("", 0)
                    fixture.flight.accept("held-source")
                }
                SystemClock.sleep(100)
                // Actual GPU pixels: the cleared field's hint must be covered with the card's fill,
                // not the former quaternary background. Sample beyond the short "hi" glyphs.
                val held = capture(activity, "$label-held")
                val x = (sent.textOrigin.x + sent.textLayout!!.width * .7f).roundToInt()
                val y = (sent.textOrigin.y + sent.textLayout!!.height / 2f).roundToInt()
                val actual = held.getPixel(x, y)
                held.recycle()
                assertTrue("source fill expected ${fill.toUInt().toString(16)}, got ${actual.toUInt().toString(16)}",
                    abs(Color.red(fill) - Color.red(actual)) <= 3 && abs(Color.green(fill) - Color.green(actual)) <= 3 &&
                        abs(Color.blue(fill) - Color.blue(actual)) <= 3)
                main { fixture.flight.cancel() }

                val images = listOf(2400 to 3200, 3200 to 2400, 1800 to 4800).mapIndexed { index, size ->
                    generate(activity, "$label-$index", size.first, size.second, index)
                }
                main { fixture.draftImages("Three different images\nwith the current input card", images); fixture.keyboard(true) }
                val deadline = SystemClock.uptimeMillis() + 8000
                var loaded = false
                while (!loaded && SystemClock.uptimeMillis() < deadline) {
                    SystemClock.sleep(100)
                    main { loaded = fixture.composer.captureSendSnapshot().attachments.let { it.size == 3 && it.all { image -> image.bitmap != null } } }
                }
                assertTrue("all distinct source previews ready", loaded)
                settle()
                main {
                    assertTrue("real keyboard shown", fixture.composer.liftPx > 0f)
                    val snapshot = fixture.composer.captureSendSnapshot()
                    assertEquals(3, snapshot.attachments.map { it.uri }.toSet().size)
                    val position = IntArray(2)
                    fixture.composer.getLocationInWindow(position)
                    assertEquals((12 * activity.resources.displayMetrics.density).roundToInt(),
                        (position[1] + fixture.composer.height - snapshot.surfaceBounds.bottom).roundToInt())
                    fixture.send()
                }
                for (index in 0..3) {
                    SystemClock.sleep(65)
                    capture(activity, "$label-flight-$index").recycle()
                }
                settle()
                main {
                    fixture.assertGap()
                    assertFalse(fixture.flight.isFlying)
                    assertTrue(fixture.timeline.hiddenRows.isEmpty())
                    assertEquals(images.map { it.uri }, fixture.lastSend().mapNotNull { it.attachment?.preview?.uri })
                    assertTrue(fixture.timeline.canScrollVertically(-1))
                }
                capture(activity, "$label-landed-ime").recycle()
                main { fixture.keyboard(false) }
                settle()
                main { fixture.assertGap() }
                capture(activity, "$label-landed").recycle()
            }
        } finally {
            ComposerDemoActivity.fixtureNightMode = null
        }
    }

    private fun generate(activity: ComposerDemoActivity, name: String, width: Int, height: Int, index: Int): ViewerImage.Local {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val paint = Paint().apply { color = listOf(0xff245bff.toInt(), 0xff159c75.toInt(), 0xffc7612c.toInt())[index] }
        for (stripe in 0..15 step 2) canvas.drawRect(0f, stripe * height / 16f, width.toFloat(), (stripe + 1) * height / 16f, paint)
        paint.apply { color = Color.BLACK; style = Paint.Style.STROKE; strokeWidth = 8f }
        for (i in 1..5) canvas.drawCircle(width / 2f, height * i / 6f, minOf(width, height) / 5f, paint)
        val file = File(activity.cacheDir, "composer-camera/integration-$name.jpg").apply { parentFile!!.mkdirs() }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        bitmap.recycle()
        return ViewerImage.Local(FileProvider.getUriForFile(activity, "${activity.packageName}.composer.files", file),
            "image/jpeg", file.name, ImageDimensions(width, height))
    }

    private fun capture(activity: ComposerDemoActivity, name: String): Bitmap {
        val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        // Saved evidence contains only the offline fixture, excluding system chrome.
        val bars = android.graphics.Rect()
        main { activity.window.decorView.getWindowVisibleDisplayFrame(bars) }
        val cropped = Bitmap.createBitmap(screenshot, bars.left, bars.top, bars.width(), bars.height())
        File(output, "$name.png").outputStream().use { cropped.compress(Bitmap.CompressFormat.PNG, 100, it) }
        if (cropped !== screenshot) cropped.recycle()
        return screenshot
    }
}
