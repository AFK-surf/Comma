package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.PixelCopy
import android.widget.EditText
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.android.controller.ActivityController
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowLooper
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.FlightTarget
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.conversation.requestKey
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.widget.BackdropBlurLayout
import java.time.Duration
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * A message taller than the conversation's visible area flies in under the top chrome. The chat is
 * put together as [LiveChatScreen] does it (the list in its frosted backdrop, the top bar, the
 * composer, and the flight over all of them) and drawn by the hardware renderer, so the frost is a
 * real blur.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SendFlightFrostTest {
    private lateinit var controller: ActivityController<ComponentActivity>
    private lateinit var activity: ComponentActivity
    private lateinit var body: BackdropBlurLayout
    private lateinit var timeline: ChatTimelineView
    private lateinit var topBar: HomeTopBar
    private lateinit var composer: ComposerView
    private lateinit var flight: SendFlightView
    private lateinit var flow: ChatSendFlow
    private val density get() = activity.resources.displayMetrics.density
    private val rows = ArrayList<ChatMessage>()
    private var nextId = 1L
    private var request = 0

    @Before fun setUp() {
        resetSpringFrames()
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(FRAME_MS))
        controller = Robolectric.buildActivity(ComponentActivity::class.java)
        activity = controller.get()
        activity.setTheme(R.style.Theme_Chat)
        controller.setup()
        val root = FrameLayout(activity).apply { setBackgroundColor(activity.getColor(R.color.token_bg_primary)) }
        body = BackdropBlurLayout(activity)
        timeline = ChatTimelineView(activity).apply {
            clipToPadding = false
            drawsBehindComposer = true
        }
        topBar = HomeTopBar(activity, compact = true)
        composer = ComposerView(activity)
        flight = SendFlightView(activity, timeline)
        body.addView(timeline, FrameLayout.LayoutParams(-1, -1))
        root.addView(body, FrameLayout.LayoutParams(-1, -1))
        root.addView(topBar, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
        composer.attachTo(root)
        root.addView(flight, FrameLayout.LayoutParams(-1, -1))
        topBar.setStatusBarInset((STATUS_BAR_DP * density).roundToInt())
        topBar.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
            val delta = bottom - top - timeline.paddingTop
            timeline.setPadding(timeline.paddingLeft, bottom - top, timeline.paddingRight, timeline.paddingBottom)
            timeline.shiftForTopInset(delta)
            body.setTopBand(topBar.frostBottom, topBar.frostSolid)
            flight.frostUnderTop(body, topBar.frostBottom)
        }
        timeline.addOnScrollListener(object : surf.comma.android.scroll.widget.RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: surf.comma.android.scroll.widget.RecyclerView, dx: Int, dy: Int) {
                body.setTopOverflow(timeline.canScrollVertically(-1))
            }
        })
        flow = ChatSendFlow(activity.lifecycleScope, composer, timeline, flight,
            draftRequestId = { "send-$request" },
            sendDraft = { text, _ ->
                rows += ChatMessage(nextId++, CONVERSATION, requestKey("send-${request++}"), ChatRole.USER, text, 0L,
                    status = MessageStatus.PENDING)
                publishNow()
                true
            },
            sendVoice = { _, _ -> true })
        flow.bind()
        composer.onImeOffset = { boundary() }
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> boundary() }
        activity.setContentView(root)
        frames(10)
        rows += ChatMessage(nextId++, CONVERSATION, "old", ChatRole.USER, "earlier question", 0L)
        rows += ChatMessage(nextId++, CONVERSATION, "old", ChatRole.AGENT, (1..30).joinToString("\n\n") { "line $it" }, 0L)
        activity.lifecycleScope.launch { publishNow() }
        frames(60)
    }

    @After fun tearDown() {
        ShadowChoreographer.setPaused(false)
        controller.pause().stop().destroy()
        resetSpringFrames()
    }

    /** Springs share one frame handler per thread; see ChatSendMotionTest. */
    private fun resetSpringFrames() {
        Class.forName("androidx.dynamicanimation.animation.AnimationHandler")
            .getDeclaredField("sAnimatorHandler").apply { isAccessible = true }
            .let { (it.get(null) as ThreadLocal<*>).remove() }
    }

    private fun boundary() = flow.updateBoundary(composer.capsuleTop - timeline.y)

    private suspend fun publishNow() = flow.submit(MessageLayoutPrecomputer(bubbles = true).prepare(rows.toList(),
        timeline.width, density, 1f, false, palette = ChatPalette.from(activity)))

    private fun frames(count: Int) = repeat(count) { ShadowLooper.idleMainLooper(FRAME_MS, TimeUnit.MILLISECONDS) }

    private fun send(text: String) {
        ComposerView::class.java.getDeclaredField("editText").apply { isAccessible = true }.let {
            (it.get(composer) as EditText).setText(text)
        }
        frames(30)
        ComposerView::class.java.getDeclaredMethod("sendNow").apply { isAccessible = true }.invoke(composer)
    }

    /** Where [id]'s bubble rests in its row, as drawn now (glide included), in window px. */
    private fun targetBox(id: Long): RectF? {
        val view = timeline.viewForRow(id) ?: return null
        val bounds = RectF()
        if (!(view as FlightTarget).flightBounds(bounds)) return null
        val location = IntArray(2)
        timeline.getLocationInWindow(location)
        bounds.offset(location[0] + view.x, location[1] + view.y)
        return bounds
    }

    /** The window as the hardware renderer draws it. */
    private fun screenshot(): Bitmap {
        val decor = activity.window.decorView
        val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
        var result = -1
        PixelCopy.request(activity.window, bitmap, { result = it }, Handler(Looper.getMainLooper()))
        ShadowLooper.idleMainLooper()
        assertEquals(PixelCopy.SUCCESS, result)
        return bitmap
    }

    /** How much of the bubble's blue survives at ([x], [y]), averaged over a few pixels across. */
    private fun blue(shot: Bitmap, x: Int, y: Int): Float =
        (x - 2..x + 2).map { shot.getPixel(it, y) }.map { Color.blue(it) - Color.red(it) }.average().toFloat()

    @Test fun `a message taller than the screen stays frosted under the top chrome while it lands`() {
        send((1..30).joinToString(" ") { "Sentence $it of a message that is much taller than the screen." })
        val id = rows.last { it.role == ChatRole.USER }.id
        val location = IntArray(2)
        body.getLocationInWindow(location)
        val chromeEdge = location[1] + timeline.paddingTop
        val frostSolid = location[1] + topBar.frostSolid
        var checked = 0
        var frame = 0
        while (flight.isFlying || frame == 0) {
            frames(1)
            assertTrue("the flight lands", ++frame < 120)
            // Once the earlier rows are above the screen, only the message coming in is under the chrome.
            val target = targetBox(id) ?: continue
            if (target.top >= 0f || frame % 4 != 0 || !flight.isFlying) continue
            val piece = requireNotNull(flight.presentedBox(id))
            val x = (maxOf(piece.left, target.left) + 6 * density).roundToInt()
            val shot = screenshot()
            assertTrue("the top band frosts at frame $frame", body.isBlurring)
            // The page colour alone measures 0 to 2 here.
            val under = blue(shot, x, frostSolid + (chromeEdge - frostSolid) * 2 / 3)
            assertTrue("the message shows through the frost under the chrome at frame $frame: $under", under > 8f)
            val above = blue(shot, x, chromeEdge - 4)
            val below = blue(shot, x, chromeEdge + 4)
            assertTrue("no edge where the chrome ends at frame $frame: $above -> $below", abs(above - below) < 16f)
            shot.recycle()
            checked++
        }
        assertTrue("checked $checked frames of the landing", checked >= 3)
    }

    private companion object {
        const val FRAME_MS = 16L
        const val STATUS_BAR_DP = 24
        const val CONVERSATION = "c"
    }
}
