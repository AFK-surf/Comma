package surf.comma.android.media.viewer

import android.animation.ValueAnimator
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.chat.live.MediaImageGroupView
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.media.ImageDimensions
import surf.comma.android.media.MediaAttachment
import surf.comma.android.media.MediaSource
import surf.comma.android.media.ViewerImage
import java.io.File
import java.time.Duration
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "en-w420dp-h933dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ImageViewerTransitionTest {
    private val frameMs = 16L
    private val touchAt = 10_000L

    @Before
    fun setUp() {
        resetSpringFrames()
        ShadowChoreographer.setPaused(false)
        setDurationScale(1f)
    }

    @After
    fun tearDown() {
        ShadowChoreographer.setPaused(false)
        resetSpringFrames()
        ChatMediaLink.reveal = null
        ChatMediaLink.onAlignGroup = null
    }

    // --- Pure geometry tests ---

    @Test
    fun `uniform cover scale and rounded aperture match tile and fitted endpoints across aspect ratios`() {
        val cases = listOf(
            ImageDimensions(1024, 1024), // 1:1 square into 3:4 card
            ImageDimensions(1600, 900),  // 16:9 landscape into 3:4 card
            ImageDimensions(900, 1600),  // 9:16 portrait into 3:4 card
            ImageDimensions(750, 1000),  // 3:4 exact match
        )
        val tile = RectF(78f, 1680f, 573f, 2340f) // 495 x 660 (3:4) near bottom-left
        val fitted = RectF()
        val aperture = RectF()

        for (dims in cases) {
            ViewerTransitionGeometry.fittedRect(1260f, 2800f, dims.width.toFloat(), dims.height.toFloat(), fitted)
            val ep = ViewerTransitionGeometry.endpoints(tile, fitted, tileCornerRadius = 36f)

            // Endpoint 0 (tile): aperture == tile exactly, radius == tileCornerRadius, cover covers tile.
            val r0 = ViewerTransitionGeometry.aperture(ep, ep.tileCenterX, ep.tileCenterY, ep.tileScale, 0f, 0f, aperture)
            assertEquals("dims=$dims left", tile.left, aperture.left, 0.5f)
            assertEquals("dims=$dims top", tile.top, aperture.top, 0.5f)
            assertEquals("dims=$dims right", tile.right, aperture.right, 0.5f)
            assertEquals("dims=$dims bottom", tile.bottom, aperture.bottom, 0.5f)
            assertEquals("dims=$dims radius0", 36f, r0, 0.01f)
            assertTrue("covered width >= tile width", ep.fitWidth * ep.tileScale >= tile.width() - 0.5f)
            assertTrue("covered height >= tile height", ep.fitHeight * ep.tileScale >= tile.height() - 0.5f)

            // Endpoint 1 (fullscreen): aperture == fitted exactly, radius == 0.
            val r1 = ViewerTransitionGeometry.aperture(ep, ep.fitCenterX, ep.fitCenterY, 1f, 1f, 1f, aperture)
            assertEquals("dims=$dims fit left", fitted.left, aperture.left, 0.5f)
            assertEquals("dims=$dims fit top", fitted.top, aperture.top, 0.5f)
            assertEquals("dims=$dims fit right", fitted.right, aperture.right, 0.5f)
            assertEquals("dims=$dims fit bottom", fitted.bottom, aperture.bottom, 0.5f)
            assertEquals("dims=$dims radius1", 0f, r1, 0.01f)

            // Overshoot past q=1 never expands aperture beyond the scaled image (no letterbox bars).
            ViewerTransitionGeometry.aperture(ep, ep.fitCenterX, ep.fitCenterY, 1.04f, 1.08f, 1.05f, aperture)
            assertTrue(aperture.width() <= ep.fitWidth * 1.04f + 0.5f)
            assertTrue(aperture.height() <= ep.fitHeight * 1.04f + 0.5f)
        }
    }

    @Test
    fun `dragScaleVelocity matches numerical derivative of dragScale`() {
        val h = 2400f
        val vy = 1800f
        val offset = 360f
        val dt = 0.0005f
        val s0 = ViewerTransitionGeometry.dragScale(offset, h)
        val s1 = ViewerTransitionGeometry.dragScale(offset + vy * dt, h)
        val numerical = (s1 - s0) / dt
        val analytical = ViewerTransitionGeometry.dragScaleVelocity(offset, vy, h)
        assertEquals(numerical, analytical, 0.01f)
        assertTrue("dragging away shrinks scale", analytical < 0f)
        assertTrue("dragging back grows scale", ViewerTransitionGeometry.dragScaleVelocity(offset, -vy, h) > 0f)
    }

    // --- End-to-end Activity + MediaImageGroupView shared-element transition regressions ---

    @Test
    fun `closing from bottom-left 4-image stack lands on exact card bounds without Y-drift or non-uniform distortion`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))
            assertTrue("card must sit in lower half of screen", tileRect.centerY() > host.screenH * 0.55f)

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            // First posted open() positions frame 0 over the tile before hiding it.
            frames(16)
            val card = host.group.cardViewAt(0)!!
            assertEquals("frame 0 aperture matches card left", tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals("frame 0 aperture matches card top", tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            assertEquals("frame 0 aperture matches card right", tileRect.right.toFloat(), viewer.currentAperture.right, 2f)
            assertEquals("frame 0 aperture matches card bottom", tileRect.bottom.toFloat(), viewer.currentAperture.bottom, 2f)
            assertEquals("frame 0 corner radius matches 12dp card", host.group.cardCornerRadiusPx(), viewer.currentCornerRadius, 0.5f)

            // Trigger pre-draw to start open springs and check uniform scaling throughout opening.
            dispatchPreDraw(viewer)
            assertEquals("tile hidden once opening starts", 0f, card.alpha, 0f)

            val page = viewer.pager.page(0)!!
            repeat(8) {
                frames(16)
                dispatchPreDraw(viewer)
                assertEquals("uniform scale during open", page.zoom.scaleX, page.zoom.scaleY, 0.0001f)
            }

            // Settle open.
            frames(1200)
            dispatchPreDraw(viewer)
            assertEquals("tile stays hidden while viewer covers it so dragging never shows duplicates", 0f, card.alpha, 0f)
            assertEquals("full scale at rest", 1f, page.zoom.scaleX, 0.001f)
            assertEquals("full scaleY at rest", 1f, page.zoom.scaleY, 0.001f)

            // Close via close button / back and verify every frame keeps uniform scale and lands on exact card bounds.
            viewer.close()
            assertEquals("tile hidden while closing", 0f, card.alpha, 0f)
            repeat(12) {
                frames(16)
                dispatchPreDraw(viewer)
                assertEquals("uniform scale during close", page.zoom.scaleX, page.zoom.scaleY, 0.0001f)
            }
            frames(1200)
            dispatchPreDraw(viewer)

            // Regression for the self-feedback origin bug: old code landed ~650px too high near screen center!
            assertEquals("close lands on exact card left", tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals("close lands on exact card top", tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            assertEquals("close lands on exact card right", tileRect.right.toFloat(), viewer.currentAperture.right, 2f)
            assertEquals("close lands on exact card bottom", tileRect.bottom.toFloat(), viewer.currentAperture.bottom, 2f)
            assertEquals("close restores 12dp corner radius", host.group.cardCornerRadiusPx(), viewer.currentCornerRadius, 0.5f)
            assertEquals("tile restored before finish", 1f, card.alpha, 0f)

            // One extra vsync finishes the activity cleanly.
            frames(32)
            assertTrue("viewer finished after 1-frame handoff", viewer.isFinishing)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `drag-to-dismiss hands 2D finger velocity into springs and never flashes backdrop opaque on release`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            val w = viewer.pager.width.toFloat()
            val h = viewer.pager.height.toFloat()
            val startX = w * 0.5f
            val startY = h * 0.4f

            // Drag diagonally DOWN and RIGHT, then flick briskly right & down (+vx, +vy) even though target card is bottom-LEFT.
            val events = mutableListOf(MotionEvent.obtain(touchAt, touchAt, MotionEvent.ACTION_DOWN, startX, startY, 0))
            val steps = 6
            val totalDx = 120f
            val totalDy = h * 0.22f
            for (step in 1..steps) {
                val t = touchAt + step * 16L
                events += MotionEvent.obtain(
                    touchAt,
                    t,
                    MotionEvent.ACTION_MOVE,
                    startX + totalDx * step / steps,
                    startY + totalDy * step / steps,
                    0,
                )
            }
            events.forEach { viewer.pager.dispatchTouchEvent(it); it.recycle() }

            val backdropBeforeRelease = viewer.backdrop.alpha
            assertTrue("backdrop dimmed during drag ($backdropBeforeRelease)", backdropBeforeRelease in 10..220)
            val page = viewer.pager.page(0)!!
            val centerXBeforeRelease = w / 2f + page.zoom.translationX
            assertTrue("drag followed finger right", centerXBeforeRelease > w / 2f + 60f)
            assertTrue("drag scaled down smoothly", page.zoom.scaleX < 0.95f)

            // Release with brisk +vx, +vy.
            val upTime = touchAt + steps * 16L + 8L
            val up = MotionEvent.obtain(touchAt, upTime, MotionEvent.ACTION_UP, startX + totalDx + 40f, startY + totalDy + 60f, 0)
            viewer.pager.dispatchTouchEvent(up)
            up.recycle()

            // Backdrop must NOT jump back to 255 on release; it must stay <= backdropBeforeRelease and decay to 0.
            var maxBackdropAfterRelease = viewer.backdrop.alpha
            var peakCenterX = viewer.currentAperture.centerX()
            repeat(6) {
                frames(16)
                dispatchPreDraw(viewer)
                if (viewer.backdrop.alpha > maxBackdropAfterRelease) maxBackdropAfterRelease = viewer.backdrop.alpha
                val cx = viewer.currentAperture.centerX()
                if (cx > peakCenterX) peakCenterX = cx
            }
            assertTrue(
                "backdrop must never flash upward on release (before=$backdropBeforeRelease, maxAfter=$maxBackdropAfterRelease)",
                maxBackdropAfterRelease <= backdropBeforeRelease + 2,
            )
            assertTrue(
                "positive +vx momentum must carry centerX further right before curving back left (start=$centerXBeforeRelease, peak=$peakCenterX)",
                peakCenterX > centerXBeforeRelease + 5f,
            )

            // Eventually lands squarely on the bottom-left chat card.
            frames(1500)
            dispatchPreDraw(viewer)
            assertEquals(tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals(tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            assertEquals(tileRect.right.toFloat(), viewer.currentAperture.right, 2f)
            assertEquals(tileRect.bottom.toFloat(), viewer.currentAperture.bottom, 2f)
            assertEquals(0, viewer.backdrop.alpha)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `cancelling a short drag-to-dismiss springs back smoothly to full screen`() {
        val host = mountChatStackAtBottom()
        try {
            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            val w = viewer.pager.width.toFloat()
            val h = viewer.pager.height.toFloat()
            val startX = w * 0.5f
            val startY = h * 0.4f
            // Drag down only 8% (below 15% threshold) and release with zero velocity.
            val dragY = h * 0.08f
            val events = listOf(
                MotionEvent.obtain(touchAt, touchAt, MotionEvent.ACTION_DOWN, startX, startY, 0),
                MotionEvent.obtain(touchAt, touchAt + 100L, MotionEvent.ACTION_MOVE, startX + 40f, startY + dragY, 0),
                MotionEvent.obtain(touchAt, touchAt + 300L, MotionEvent.ACTION_MOVE, startX + 40f, startY + dragY, 0),
                MotionEvent.obtain(touchAt, touchAt + 300L, MotionEvent.ACTION_UP, startX + 40f, startY + dragY, 0),
            )
            events.forEach { viewer.pager.dispatchTouchEvent(it); it.recycle() }

            frames(1000)
            dispatchPreDraw(viewer)
            assertFalse("short drag must not dismiss viewer", viewer.isFinishing)
            val page = viewer.pager.page(0)!!
            assertEquals("returned to center X", 0f, page.zoom.translationX, 1f)
            assertEquals("returned to center Y", 0f, page.zoom.translationY, 1f)
            assertEquals("returned to full scale", 1f, page.zoom.scaleX, 0.01f)
            assertEquals("backdrop restored to opaque", 255, viewer.backdrop.alpha)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `pressing back mid-open reverses smoothly from live pose without snapping to full screen`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            // Advance ~64ms into opening: partway between tile and full screen.
            frames(64)
            dispatchPreDraw(viewer)
            val midScale = viewer.currentScale
            val midCy = viewer.currentAperture.centerY()
            assertTrue("mid-open scale must be between tile and 1 ($midScale)", midScale < 0.92f)

            viewer.close()
            dispatchPreDraw(viewer)
            assertEquals("reversing mid-open keeps live scale without snapping to 1", midScale, viewer.currentScale, 0.05f)
            assertTrue("reversing mid-open keeps live Y without snapping to center", abs(viewer.currentAperture.centerY() - midCy) < 40f)

            frames(1200)
            dispatchPreDraw(viewer)
            assertEquals(tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            frames(32)
            assertTrue(viewer.isFinishing)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `closing from zoomed-in state preserves frame-0 pixels and lands on card`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            val page = viewer.pager.page(0)!!
            page.zoom.jumpTo(ZoomState(scale = 2.4f, offsetX = 110f, offsetY = -90f))
            viewer.close()
            // Frame 0 absorbed the zoomed scale and offset instead of snapping back to 1.0.
            assertEquals(2.4f, viewer.currentScale, 0.01f)
            assertEquals(viewer.pager.width / 2f + 110f, viewer.currentAperture.centerX(), 2f)
            assertEquals(viewer.pager.height / 2f - 90f, viewer.currentAperture.centerY(), 2f)

            frames(1500)
            dispatchPreDraw(viewer)
            assertEquals(tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals(tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `predictive back cancels back to full screen and commits into tile with velocity`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            val back = viewer.onBackPressedDispatcher
            val w = viewer.pager.width.toFloat()
            val h = viewer.pager.height.toFloat()
            back.dispatchOnBackStarted(BackEventCompat(0f, h * 0.5f, 0f, BackEventCompat.EDGE_LEFT, touchAt))
            back.dispatchOnBackProgressed(BackEventCompat(w * 0.35f, h * 0.52f, 0.35f, BackEventCompat.EDGE_LEFT, touchAt + 32L))
            val page = viewer.pager.page(0)!!
            assertTrue("predictive back scales page down", page.zoom.scaleX < 0.98f)
            assertTrue("predictive back dims backdrop", viewer.backdrop.alpha < 255)

            // Cancel springs back to full screen.
            back.dispatchOnBackCancelled()
            frames(1000)
            dispatchPreDraw(viewer)
            assertFalse("cancelled back must not close viewer", viewer.isFinishing)
            assertEquals(1f, page.zoom.scaleX, 0.01f)
            assertEquals(255, viewer.backdrop.alpha)

            // Commit closes into the card.
            back.dispatchOnBackStarted(BackEventCompat(0f, h * 0.5f, 0f, BackEventCompat.EDGE_LEFT, touchAt + 2000L))
            back.dispatchOnBackProgressed(BackEventCompat(w * 0.35f, h * 0.52f, 0.35f, BackEventCompat.EDGE_LEFT, touchAt + 2032L))
            back.onBackPressed()
            frames(1500)
            dispatchPreDraw(viewer)
            assertEquals(tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals(tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            frames(32)
            assertTrue(viewer.isFinishing)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `paging inside viewer aligns stack and closes into newly selected card`() {
        val host = mountChatStackAtBottom()
        try {
            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            // Select card 2 inside the viewer and close.
            viewer.pager.select(2)
            assertEquals("stack aligned to card 2", 2, host.group.browseState.frontIndex)
            assertEquals("previous card restored on page switch", 1f, host.group.cardViewAt(0)!!.alpha, 0f)
            assertEquals("newly selected card hidden while viewer is open", 0f, host.group.cardViewAt(2)!!.alpha, 0f)
            val card2Rect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, card2Rect, 2))

            viewer.close()
            frames(1500)
            dispatchPreDraw(viewer)
            assertEquals(card2Rect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals(card2Rect.top.toFloat(), viewer.currentAperture.top, 2f)
            assertEquals(card2Rect.right.toFloat(), viewer.currentAperture.right, 2f)
            assertEquals(card2Rect.bottom.toFloat(), viewer.currentAperture.bottom, 2f)
            frames(32)
            assertTrue(viewer.isFinishing)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `touch down during opening transition tail rebases cleanly without teleporting off screen`() {
        val host = mountChatStackAtBottom()
        try {
            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            // Advance partway into opening while transitionActive is still true.
            frames(80)
            dispatchPreDraw(viewer)

            val w = viewer.pager.width.toFloat()
            val h = viewer.pager.height.toFloat()
            val downX = w * 0.5f
            val downY = h * 0.55f

            // Finger touches down while opening spring is still settling.
            val down = MotionEvent.obtain(touchAt, touchAt, MotionEvent.ACTION_DOWN, downX, downY, 0)
            viewer.pager.dispatchTouchEvent(down)
            down.recycle()

            // Opening settles while finger is still down.
            frames(800)
            dispatchPreDraw(viewer)

            // First MOVE after transitionActive becomes false must rebase to (downX, downY+20), NOT subtract 0!
            val move1 = MotionEvent.obtain(touchAt, touchAt + 816L, MotionEvent.ACTION_MOVE, downX, downY + 20f, 0)
            val move2 = MotionEvent.obtain(touchAt, touchAt + 832L, MotionEvent.ACTION_MOVE, downX, downY + 80f, 0)
            viewer.pager.dispatchTouchEvent(move1)
            viewer.pager.dispatchTouchEvent(move2)
            move1.recycle()
            move2.recycle()

            val page = viewer.pager.page(0)!!
            assertTrue(
                "translationY must follow actual 60px delta, not teleport by downY (${page.zoom.translationY})",
                abs(page.zoom.translationY) < 120f,
            )
            assertTrue("backdrop must remain mostly opaque on small 60px drag (${viewer.backdrop.alpha})", viewer.backdrop.alpha > 180)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `brisk downward flick never undershoots tile scale, never throws off bottom, and keeps tile hidden until landing`() {
        val host = mountChatStackAtBottom()
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))
            val card = host.group.cardViewAt(0)!!

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)
            frames(1200)
            dispatchPreDraw(viewer)

            val w = viewer.pager.width.toFloat()
            val h = viewer.pager.height.toFloat()
            val fitted = RectF()
            ViewerTransitionGeometry.fittedRect(w, h, 1024f, 1024f, fitted)
            val tileF = RectF(tileRect)
            val ep = ViewerTransitionGeometry.endpoints(tileF, fitted, host.group.cardCornerRadiusPx())

            // Very fast downward drag + flick (~12,000 px/s).
            val startX = w * 0.5f
            val startY = h * 0.35f
            val events = listOf(
                MotionEvent.obtain(touchAt, touchAt, MotionEvent.ACTION_DOWN, startX, startY, 0),
                MotionEvent.obtain(touchAt, touchAt + 16L, MotionEvent.ACTION_MOVE, startX, startY + 220f, 0),
                MotionEvent.obtain(touchAt, touchAt + 32L, MotionEvent.ACTION_MOVE, startX, startY + 460f, 0),
                MotionEvent.obtain(touchAt, touchAt + 48L, MotionEvent.ACTION_UP, startX, startY + 680f, 0),
            )
            // Tile must already be hidden before drag starts AND stay hidden throughout drag!
            for ((idx, ev) in events.withIndex()) {
                viewer.pager.dispatchTouchEvent(ev)
                ev.recycle()
                if (idx < events.lastIndex) {
                    assertEquals("tile stays hidden during drag step $idx", 0f, card.alpha, 0f)
                }
            }

            var minScaleDuringClose = Float.MAX_VALUE
            var maxTopDuringClose = Float.NEGATIVE_INFINITY
            repeat(60) {
                frames(16)
                dispatchPreDraw(viewer)
                if (!viewer.isFinishing) {
                    if (viewer.currentScale < minScaleDuringClose) minScaleDuringClose = viewer.currentScale
                    if (viewer.currentAperture.top > maxTopDuringClose) maxTopDuringClose = viewer.currentAperture.top
                }
            }
            assertTrue(
                "closing scale must never undershoot tileScale (min=$minScaleDuringClose, tileScale=${ep.tileScale})",
                minScaleDuringClose >= ep.tileScale - 0.006f,
            )
            assertTrue(
                "clamped fling velocity must never throw aperture completely off bottom (maxTop=$maxTopDuringClose, h=$h)",
                maxTopDuringClose < h * 0.92f,
            )
            assertEquals("tile restored once closing settles", 1f, card.alpha, 0f)
        } finally {
            host.cleanup()
        }
    }

    @Test
    fun `stale metadata dimensions never stretch viewer or snap crop when decoded bitmap has different aspect ratio`() {
        val host = mountChatStackAtBottom(
            bitmapDimensions = listOf(
                ImageDimensions(300, 400), // real 3:4 portrait pixels
                ImageDimensions(300, 400),
                ImageDimensions(300, 400),
                ImageDimensions(300, 400),
            ),
            metadataDimensions = listOf(
                ImageDimensions(1024, 1024), // wrong 1:1 square metadata from agent payload
                ImageDimensions(1024, 1024),
                ImageDimensions(1024, 1024),
                ImageDimensions(1024, 1024),
            ),
        )
        try {
            val tileRect = Rect()
            assertTrue(ChatMediaLink.bounds(host.rowId, tileRect, 0))

            pauseChoreographer()
            val viewer = launchViewer(host, index = 0)
            frames(16)
            dispatchPreDraw(viewer)

            val page = viewer.pager.page(0)!!
            val geom = page.zoom.geometry!!
            assertEquals(
                "ZoomImageView must honour decoded 3:4 bitmap ratio, not stale 1:1 metadata",
                0.75f,
                geom.contentWidth / geom.contentHeight,
                0.01f,
            )

            // Fullscreen fitted width for a 3:4 bitmap in a 1260x2800 viewport is 1260, height is 1680.
            // Expected cover scale into a 3:4 tile is tileWidth / 1260 (NOT tileHeight / 1260 which would zoom 1.33x).
            val expectedCoverScale = tileRect.width().toFloat() / viewer.pager.width.toFloat()
            frames(1200)
            dispatchPreDraw(viewer)

            viewer.close()
            frames(1200)
            dispatchPreDraw(viewer)
            assertEquals("landing scale matches true 3:4 cover without 1.33x crop jump", expectedCoverScale, viewer.currentScale, 0.02f)
            assertEquals(tileRect.left.toFloat(), viewer.currentAperture.left, 2f)
            assertEquals(tileRect.top.toFloat(), viewer.currentAperture.top, 2f)
            assertEquals(tileRect.right.toFloat(), viewer.currentAperture.right, 2f)
            assertEquals(tileRect.bottom.toFloat(), viewer.currentAperture.bottom, 2f)
        } finally {
            host.cleanup()
        }
    }

    // --- Helpers ---

    private class ChatHost(
        val activity: ComponentActivity,
        val group: MediaImageGroupView,
        val rowId: Long,
        val screenW: Int,
        val screenH: Int,
        val tempFiles: List<File>,
        val metadataDimensions: List<ImageDimensions>,
    ) {
        fun cleanup() {
            ChatMediaLink.unregisterGroup(rowId, group)
            tempFiles.forEach { it.delete() }
        }
    }

    private fun mountChatStackAtBottom(
        bitmapDimensions: List<ImageDimensions> = List(4) { ImageDimensions(600, 600) },
        metadataDimensions: List<ImageDimensions> = bitmapDimensions,
    ): ChatHost {
        val activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
        val density = activity.resources.displayMetrics.density
        val screenW = (420f * density).roundToInt()
        val screenH = (933f * density).roundToInt()
        val columnW = (364f * density).roundToInt()
        val sideMargin = (28f * density).roundToInt()

        val colors = listOf(Color.rgb(210, 140, 90), Color.rgb(90, 175, 210), Color.rgb(120, 185, 110), Color.rgb(190, 120, 180))
        val bitmaps = colors.mapIndexed { i, c ->
            val dim = bitmapDimensions[i]
            Bitmap.createBitmap(dim.width, dim.height, Bitmap.Config.ARGB_8888).apply {
                Canvas(this).drawColor(c)
            }
        }
        val tempFiles = bitmaps.mapIndexed { i, bmp ->
            File.createTempFile("viewer_test_$i", ".png", activity.cacheDir).also { file ->
                file.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
        val attachments = List(4) { i ->
            ChatAttachment(
                file = MediaAttachment(
                    fileName = "photo_$i.png",
                    mimeType = "image/png",
                    size = tempFiles[i].length(),
                    source = MediaSource.UploadedFile("/uploads/aaaaaaaaaaaaaaaaaaaaaa-photo_$i.png"),
                ),
                dimensions = metadataDimensions[i],
            )
        }

        val group = MediaImageGroupView(activity).apply {
            useSystemAnimator = false
            directDrawableProvider = { _, idx -> BitmapDrawable(activity.resources, bitmaps[idx]) }
            bind(attachments, alignEnd = false, expanded = false)
        }
        val root = FrameLayout(activity)
        val params = FrameLayout.LayoutParams(columnW, FrameLayout.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = sideMargin
            topMargin = (screenH * 0.58f).roundToInt()
        }
        root.addView(group, params)
        activity.setContentView(root)
        val decor = activity.window.decorView
        decor.measure(
            View.MeasureSpec.makeMeasureSpec(screenW, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(screenH, View.MeasureSpec.EXACTLY),
        )
        decor.layout(0, 0, screenW, screenH)

        val rowId = 9001L
        ChatMediaLink.registerGroup(rowId, group)
        return ChatHost(activity, group, rowId, screenW, screenH, tempFiles, metadataDimensions)
    }

    private fun launchViewer(host: ChatHost, index: Int): ImageViewerActivity {
        val items = host.tempFiles.mapIndexed { i, file ->
            ViewerImage.Local(
                uri = Uri.fromFile(file),
                mime = "image/png",
                fileName = "photo_$i.png",
                dimensions = host.metadataDimensions[i],
            )
        }
        val intent = ImageViewerActivity.intent(host.activity, items, index)
            .putExtra("surf.comma.android.media.viewer.ROWS", LongArray(items.size) { host.rowId })
            .putExtra("surf.comma.android.media.viewer.GROUP_INDICES", IntArray(items.size) { it })
        val controller = Robolectric.buildActivity(ImageViewerActivity::class.java, intent).setup()
        val viewer = controller.get()
        val decor = viewer.window.decorView
        decor.measure(
            View.MeasureSpec.makeMeasureSpec(host.screenW, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(host.screenH, View.MeasureSpec.EXACTLY),
        )
        decor.layout(0, 0, host.screenW, host.screenH)
        return viewer
    }

    private fun pauseChoreographer() {
        setDurationScale(1f)
        resetSpringFrames()
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(frameMs))
    }

    private fun frames(millis: Long) {
        repeat((millis / frameMs).toInt().coerceAtLeast(1)) {
            ShadowLooper.idleMainLooper(frameMs, TimeUnit.MILLISECONDS)
        }
    }

    private fun dispatchPreDraw(viewer: ImageViewerActivity) {
        viewer.window.decorView.viewTreeObserver.dispatchOnPreDraw()
    }

    private fun setDurationScale(scale: Float) {
        ValueAnimator::class.java.getDeclaredMethod("setDurationScale", Float::class.javaPrimitiveType)
            .apply { isAccessible = true }
            .invoke(null, scale)
    }

    private fun resetSpringFrames() {
        Class.forName("androidx.dynamicanimation.animation.AnimationHandler")
            .getDeclaredField("sAnimatorHandler").apply { isAccessible = true }
            .let { (it.get(null) as ThreadLocal<*>).remove() }
    }
}
