package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.activity.ComponentActivity
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.widget.BackdropBlurLayout
import kotlin.math.abs

/** Native canvas checks the same band's fallback and clipping, without depending on a GPU's blur kernel. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ChatBottomBackdropTest {
    @Test fun `content continues under the composer and the bottom wash grows toward the edge`() = checkBand(lift = false)

    @Test fun `the bottom band follows the keyboard without growing across the conversation`() = checkBand(lift = true)

    private fun checkBand(lift: Boolean) {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val screen = LiveChatScreen(activity, ChatGraph.conversations(activity), AuthGraph.get(activity).state,
                retrySession = {}, onOpenAccount = {}, router = true)
            activity.setContentView(screen.root)
            ShadowLooper.idleMainLooper()
            try {
                val body = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<BackdropBlurLayout>().single()
                val timeline = activity.findViewById<ChatTimelineView>(R.id.conversation_timeline)
                val composer = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<ComposerView>().single()
                val top = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<HomeTopBar>().single()
                // A solid source makes the band's coverage measurable in both the clear and frosted regions.
                timeline.setBackgroundColor(Color.RED)
                body.mode = BackdropBlurLayout.Mode.FADE
                val keyboard = if (lift) body.height / 3 else 0
                ViewCompat.dispatchApplyWindowInsets(screen.root, WindowInsetsCompat.Builder()
                    .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, 72))
                    .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, keyboard))
                    .build())
                if (lift) {
                    assertEquals("the input clears the whole keyboard in an edge-to-edge host", keyboard.toFloat(), composer.liftPx, 0f)
                } else {
                    assertEquals("the input clears the navigation area", 72f, composer.liftPx, 0f)
                }
                body.setTopOverflow(true)
                timeline.onBottomOverflowChanged?.invoke(body.height)
                val bitmap = Bitmap.createBitmap(body.width, body.height, Bitmap.Config.ARGB_8888)
                body.draw(Canvas(bitmap))
                val edge = body.height - keyboard
                val capsuleTop = (composer.capsuleTop - body.y).toInt()
                val transition = top.frostBottom - top.frostSolid
                val start = capsuleTop - transition
                val x = body.width / 2
                assertEquals("content above the band stays clear", Color.RED, bitmap.getPixel(x, start - 1))
                val high = bitmap.getPixel(x, start + (edge - start) / 4)
                val low = bitmap.getPixel(x, edge - 2)
                assertEquals("the content is drawn behind the input", 255, Color.alpha(low))
                assertTrue("the wash becomes stronger toward the bottom", Color.green(low) > Color.green(high))
                assertTrue("the transition starts above the composer", Color.green(high) > 0)
                // The visible transition above the input must be the top band's reflection,
                // not a faint sliver of a ramp hidden underneath the opaque capsule.
                for (fraction in listOf(0.25f, 0.5f, 0.75f)) {
                    val distance = (transition * fraction).toInt()
                    val upper = bitmap.getPixel(x, top.frostSolid + distance)
                    val lower = bitmap.getPixel(x, capsuleTop - distance)
                    assertEquals("the top and bottom use the same visible falloff", Color.green(upper).toFloat(),
                        Color.green(lower).toFloat(), 2f)
                }
                assertEquals("navigation gestures do not reserve a blank strip below the chat", 0, screen.root.paddingBottom)
                bitmap.recycle()
            } finally {
                screen.release()
            }
        }
    }

    /**
     * The last reply rests in the ramp above the composer. The frost over it comes and goes with how far the
     * content is under the composer, never at once at the first or the last pixel. Drawn by the hardware
     * renderer, so the blur is real.
     */
    @Test fun `the frost above the composer comes in with the content that goes under it`() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val screen = LiveChatScreen(activity, ChatGraph.conversations(activity), AuthGraph.get(activity).state,
                retrySession = {}, onOpenAccount = {}, router = true)
            activity.setContentView(screen.root)
            ShadowLooper.idleMainLooper()
            try {
                val body = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<BackdropBlurLayout>().single()
                val timeline = activity.findViewById<ChatTimelineView>(R.id.conversation_timeline)
                val composer = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<ComposerView>().single()
                val top = (0 until screen.root.childCount).map(screen.root::getChildAt).filterIsInstance<HomeTopBar>().single()
                // Lines of text, as far as the blur and the tint can tell: crisp, they keep their full contrast.
                timeline.background = Stripes()
                ShadowLooper.idleMainLooper()
                val location = IntArray(2)
                body.getLocationInWindow(location)
                val y = location[1] + (composer.capsuleTop - body.y).toInt() - (30 * activity.resources.displayMetrics.density).toInt()
                val ramp = top.frostBottom - top.frostSolid
                val contrasts = ((0 until ramp step 12) + ramp).map { overflow ->
                    timeline.onBottomOverflowChanged?.invoke(overflow)
                    val shot = screenshot(activity)
                    val greens = (y until y + 2 * Stripes.LINE_PX).map { Color.green(shot.getPixel(shot.width / 2, it)) }
                    shot.recycle()
                    greens.max() - greens.min()
                }
                assertEquals("the resting reply is not frosted: $contrasts", 255, contrasts.first())
                contrasts.zipWithNext().forEach { (before, after) ->
                    assertTrue("the frost changes a little with each step under the composer: $contrasts", abs(after - before) <= 64)
                }
                assertTrue("all the way under, it is frosted: $contrasts", contrasts.last() < 64)
            } finally {
                screen.release()
            }
        }
    }

    private fun screenshot(activity: ComponentActivity): Bitmap {
        val decor = activity.window.decorView
        val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
        var result = -1
        PixelCopy.request(activity.window, bitmap, { result = it }, Handler(Looper.getMainLooper()))
        ShadowLooper.idleMainLooper()
        assertEquals(PixelCopy.SUCCESS, result)
        return bitmap
    }

    private class Stripes : Drawable() {
        private val paint = Paint()

        override fun draw(canvas: Canvas) {
            for (line in 0 until bounds.height() / LINE_PX) {
                paint.color = if (line % 2 == 0) Color.BLACK else Color.WHITE
                canvas.drawRect(0f, (line * LINE_PX).toFloat(), bounds.width().toFloat(), ((line + 1) * LINE_PX).toFloat(), paint)
            }
        }

        override fun setAlpha(alpha: Int) = Unit
        override fun setColorFilter(colorFilter: ColorFilter?) = Unit
        @Deprecated("Deprecated in Java")
        override fun getOpacity() = PixelFormat.OPAQUE

        companion object {
            const val LINE_PX = 12
        }
    }
}
