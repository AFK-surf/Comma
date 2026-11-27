package surf.comma.android.chat.live

import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaSource
import surf.comma.android.media.viewer.ChatMediaLink
import kotlin.math.roundToInt

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en-w390dp-h844dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MediaImageGroupViewTest {
    private val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    private val density = activity.resources.displayMetrics.density
    private val columnWidthPx = (358f * density).roundToInt()

    private fun image(index: Int, width: Int = 1200, height: Int = 900): ChatAttachment = ChatAttachment(
        file = MediaAttachment(
            fileName = "photo_$index.png",
            mimeType = "image/png",
            size = 4096L,
            source = MediaSource.UploadedFile("/uploads/aaaaaaaaaaaaaaaaaaaaaa-photo_$index.png"),
        ),
        dimensions = ImageDimensions(width, height),
    )

    private fun mount(count: Int, alignEnd: Boolean = false, expanded: Boolean = false): MediaImageGroupView {
        val view = MediaImageGroupView(activity).apply {
            useSystemAnimator = false
            directDrawableProvider = { _, idx -> ColorDrawable(Color.HSVToColor(floatArrayOf((idx * 47f) % 360f, 0.55f, 0.85f))) }
            bind(List(count) { image(it) }, alignEnd = alignEnd, expanded = expanded)
        }
        val host = FrameLayout(activity)
        host.addView(view, FrameLayout.LayoutParams(columnWidthPx, FrameLayout.LayoutParams.WRAP_CONTENT))
        activity.setContentView(host)
        val decor = activity.window.decorView
        val screenW = (390f * density).roundToInt()
        val screenH = (844f * density).roundToInt()
        decor.measure(
            View.MeasureSpec.makeMeasureSpec(screenW, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(screenH, View.MeasureSpec.EXACTLY),
        )
        decor.layout(0, 0, screenW, screenH)
        measureAndLayout(view)
        return view
    }

    private fun measureAndLayout(view: MediaImageGroupView) {
        view.measure(
            View.MeasureSpec.makeMeasureSpec(columnWidthPx, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
    }

    @Test fun `1, 2, 3, 4 and 8 image groups match precomputed heights and visibility rules`() {
        // 1 image: no toggle pill, no advance chevrons, original aspect ratio (4:3 -> 268x201dp).
        val single = mount(1)
        assertEquals(View.GONE, single.toggleButtonView().visibility)
        assertEquals(View.GONE, single.leftAdvanceButton().visibility)
        assertEquals((201f * density).roundToInt(), single.measuredHeight)
        assertEquals((268f * density).roundToInt(), single.cardViewAt(0)!!.width)
        assertEquals((201f * density).roundToInt(), single.cardViewAt(0)!!.height)

        // 2 and 3 images: side-by-side row, no toggle pill.
        for (count in listOf(2, 3)) {
            val view = mount(count)
            assertEquals(View.GONE, view.toggleButtonView().visibility)
            assertEquals(View.GONE, view.leftAdvanceButton().visibility)
            val expectedHeight = (MediaImageGroupGeometry.totalHeightDp(358f, count, expanded = false) * density).roundToInt()
            assertEquals("count=$count", expectedHeight, view.measuredHeight)
            // All cards sit on the same row (same top).
            val tops = (0 until count).map { view.cardViewAt(it)!!.top }.distinct()
            assertEquals(listOf(0), tops)
        }

        // 4 and 8 images: collapsed fan stack with toggle pill and chevrons.
        for (count in listOf(4, 8)) {
            val view = mount(count)
            assertEquals(View.VISIBLE, view.toggleButtonView().visibility)
            assertEquals("$count Images", view.toggleButtonView().text.toString())
            assertEquals(View.VISIBLE, view.leftAdvanceButton().visibility)
            assertEquals(View.VISIBLE, view.rightAdvanceButton().visibility)
            val expectedHeight = (MediaImageGroupGeometry.totalHeightDp(358f, count, expanded = false) * density).roundToInt()
            assertEquals("count=$count", expectedHeight, view.measuredHeight)
        }
    }

    @Test fun `rotating deck runs 320ms throw-arc animation and updates browse state`() {
        val view = mount(6)
        assertEquals(0, view.browseState.frontIndex)

        view.leftAdvanceButton().performClick()
        assertEquals(1, view.browseState.frontIndex)
        assertEquals(1, view.browseState.leftCount)
        assertTrue(view.isAnimating)
        assertEquals(MediaImageGroupGeometry.FLIGHT_DURATION_MS, view.activeAnimationDurationMs)

        // At apex (40% = 128ms): card 0 is thrown left ~0.7W and rotated -9deg.
        view.advanceAnimationTo(128L)
        val outgoing = view.cardViewAt(0)!!
        assertTrue("expected negative apex tx, got ${outgoing.translationX}", outgoing.translationX < -100f * density)
        assertEquals(-9f, outgoing.rotation, 0.5f)
        assertEquals(0.96f, outgoing.scaleX, 0.01f)

        // At end (320ms): animation finishes and card 0 rests in L1 while card 1 is FRONT.
        view.advanceAnimationTo(320L)
        assertFalse(view.isAnimating)
        assertEquals(ImageGroupStackSlot.L1.rotationDeg, outgoing.rotation, 0.01f)
        assertEquals(0f, view.cardViewAt(1)!!.rotation, 0.01f)

        // Right chevron rotates back to 0.
        view.rightAdvanceButton().performClick()
        view.advanceAnimationTo(320L)
        assertEquals(0, view.browseState.frontIndex)
        assertEquals(0, view.browseState.leftCount)
    }

    @Test fun `wrapping hidden card to front updates hardware Z immediately so lower cards never flash above it`() {
        val view = mount(4)
        val c0 = view.cardViewAt(0)!!
        val c1 = view.cardViewAt(1)!!
        val c2 = view.cardViewAt(2)!!
        val c3 = view.cardViewAt(3)!!
        val leftBtn = view.leftAdvanceButton()
        val rightBtn = view.rightAdvanceButton()

        // Rest order: c0 (FRONT) > c1 (R1) > c2 (R2) > c3 (HIDDEN_RIGHT at Z=0), chevrons on top.
        assertTrue(leftBtn.z > c0.z)
        assertTrue(rightBtn.z > c0.z)
        assertTrue(c0.z > c1.z && c1.z > c2.z && c2.z > c3.z)
        assertEquals(0f, c3.z, 0.0001f)

        // Tap right chevron from front=0: c0 flies right to R1, c3 wraps HIDDEN_RIGHT -> FRONT,
        // c1 shifts R1 -> R2, c2 fades R2 -> HIDDEN_RIGHT.
        rightBtn.performClick()
        assertEquals(3, view.browseState.frontIndex)

        // At apex (128ms, before 0.6 layer swap): chevrons > outgoing c0 > new FRONT c3 > c1 > hidden c2.
        view.advanceAnimationTo(128L)
        assertTrue("chevrons must stay above flying card", leftBtn.z > c0.z && rightBtn.z > c0.z)
        assertTrue("outgoing card stays above incoming front before layer swap", c0.z > c3.z)
        assertTrue("new front c3 must paint above R2 c1 during flight (c3.z=${c3.z}, c1.z=${c1.z})", c3.z > c1.z)
        assertTrue("new front c3 must paint above fading c2 during flight (c3.z=${c3.z}, c2.z=${c2.z})", c3.z > c2.z)
        assertEquals("newly wrapped front card must stay opaque so lower cards do not bleed through", 1f, c3.alpha, 0.001f)

        // After layer swap (200ms > 192ms): c3 (FRONT) > c0 (R1) > c1 (R2) > c2 (HIDDEN).
        view.advanceAnimationTo(200L)
        assertTrue("new front c3 must sit above outgoing c0 after layer swap", c3.z > c0.z)
        assertTrue("outgoing c0 (R1) must sit above c1 (R2)", c0.z > c1.z)
        assertTrue("c1 (R2) must sit above hidden c2", c1.z > c2.z)

        // Settled at 320ms: Z ordering matches rest poses with zero pop.
        view.advanceAnimationTo(320L)
        assertTrue(c3.z > c0.z && c0.z > c1.z && c1.z > c2.z)
        assertEquals(0f, c2.z, 0.0001f)
    }

    @Test fun `toggling expand and collapse runs staggered FLIP and transitions container height`() {
        val view = mount(6)
        val collapsedHeight = view.measuredHeight
        val expectedExpandedHeight = (MediaImageGroupGeometry.totalHeightDp(358f, 6, expanded = true) * density).roundToInt()
        assertTrue(expectedExpandedHeight > collapsedHeight)

        view.toggleButtonView().performClick()
        assertTrue(view.expanded)
        assertEquals("Hide", view.toggleButtonView().text.toString())
        assertEquals(View.GONE, view.leftAdvanceButton().visibility)
        assertTrue(view.isAnimating)

        // Mid-animation height interpolates smoothly between collapsed and expanded.
        view.advanceAnimationTo(120L)
        measureAndLayout(view)
        assertTrue(view.measuredHeight in (collapsedHeight + 1) until expectedExpandedHeight)

        // Settle at end of FLIP.
        view.advanceAnimationTo(view.activeAnimationDurationMs)
        measureAndLayout(view)
        assertFalse(view.isAnimating)
        assertEquals(expectedExpandedHeight, view.measuredHeight)

        // Collapse back to fan deck.
        view.toggleButtonView().performClick()
        assertFalse(view.expanded)
        assertEquals("6 Images", view.toggleButtonView().text.toString())
        view.advanceAnimationTo(view.activeAnimationDurationMs)
        measureAndLayout(view)
        assertEquals(collapsedHeight, view.measuredHeight)
    }

    @Test fun `click callback and ChatMediaLink bidirectional alignment return live card bounds`() {
        val view = mount(6)
        val rowId = 4242L
        var clicked = -1
        view.onCardClick = { clicked = it }
        ChatMediaLink.registerGroup(rowId, view)
        try {
            // Tapping front card invokes click with index 0.
            view.cardViewAt(0)!!.performClick()
            assertEquals(0, clicked)

            // Viewer pages to image 3 -> ChatMediaLink.align updates frontIndex to 3 and returns live bounds.
            ChatMediaLink.align(rowId, 3)
            assertEquals(3, view.browseState.frontIndex)
            assertEquals(3, view.browseState.leftCount)
            assertEquals(0f, view.cardViewAt(3)!!.rotation, 0.01f)
            assertNotNull(ChatMediaLink.picture(rowId, activity.resources, 3))

            val rect = Rect()
            assertTrue(ChatMediaLink.bounds(rowId, rect, 3))
            assertTrue(rect.width() > 0 && rect.height() > 0)
        } finally {
            ChatMediaLink.unregisterGroup(rowId, view)
        }
    }
}
