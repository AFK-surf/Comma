package surf.comma.android.chat.live

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import surf.comma.android.R
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.FlightTarget
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.conversation.requestKey
import surf.comma.android.media.*
import surf.comma.android.ui.composer.AttachmentUploadState
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.ui.composer.demo.ComposerDemoActivity
import java.io.File
import kotlin.math.roundToInt

/**
 * The real composer, list and flight on a device, sending through [ChatSendFlow] like the chat
 * screen. The repository is replaced by a local list that commits each send before it returns
 * (as the real one publishes the pending message); nothing goes to a server.
 */
internal class ChatSendFixture(private val activity: ComposerDemoActivity, private val sampleWidth: Int = 160,
    private val sampleHeight: Int = 960, private val transparent: Boolean = false, showChrome: Boolean = false,
    /** Lays rows out with the live chat's bubbles and tails. */
    private val bubbles: Boolean = false) {
    val timeline = ChatTimelineView(activity).apply { clipToPadding = false }
    val composer = ComposerView(activity)
    val flight = SendFlightView(activity, timeline)
    /** A square in a corner whose colour names the case, so a screen recording can be cut by case. */
    val marker = android.view.View(activity).apply { setBackgroundColor(MARKERS[0]) }
    private val root = FrameLayout(activity).apply { setBackgroundColor(activity.getColor(R.color.token_bg_primary)) }
    val rows = ArrayList<ChatMessage>()
    private var nextId = 1L
    private var request = 0
    private var turn = 0
    private val density = activity.resources.displayMetrics.density
    private val input: EditText get() = ComposerView::class.java.getDeclaredField("editText").let {
        it.isAccessible = true; it.get(composer) as EditText
    }
    internal val sampleFile: File
    private val sample: Uri
    private val suppliedImages = HashMap<Uri, ViewerImage.Local>()
    private val flow: ChatSendFlow

    init {
        // Geometric sample generated locally; no gallery access or server request is needed.
        val bitmap = Bitmap.createBitmap(sampleWidth, sampleHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        if (!transparent) canvas.drawColor(android.graphics.Color.WHITE)
        paint.strokeWidth = 3f
        for (stripe in 0 until 12) {
            paint.color = if (stripe % 2 == 0) 0xff205bff.toInt() else 0xffeeeeee.toInt()
            if (!transparent || stripe % 2 == 0)
                canvas.drawRect(0f, stripe * sampleHeight / 12f, sampleWidth.toFloat(), (stripe + 1) * sampleHeight / 12f, paint)
        }
        paint.color = 0xff202020.toInt()
        paint.style = Paint.Style.STROKE
        for (x in 0..8) canvas.drawLine(x * sampleWidth / 8f, 0f, x * sampleWidth / 8f, sampleHeight.toFloat(), paint)
        for (y in 0..24) canvas.drawLine(0f, y * sampleHeight / 24f, sampleWidth.toFloat(), y * sampleHeight / 24f, paint)
        for (y in 1..5) canvas.drawCircle(sampleWidth / 2f, sampleHeight * y / 6f, minOf(sampleWidth, sampleHeight) / 4f, paint)
        paint.style = Paint.Style.FILL
        val size = minOf(sampleWidth, sampleHeight) / 5f
        listOf(0xffff0000.toInt(), 0xff00cc00.toInt(), 0xffffff00.toInt(), 0xffff00ff.toInt()).forEachIndexed { i, color ->
            paint.color = color
            val x = if (i % 2 == 0) 0f else sampleWidth - size
            val y = if (i < 2) 0f else sampleHeight - size
            canvas.drawRect(x, y, x + size, y + size, paint)
        }
        val directory = File(activity.cacheDir, "composer-camera").apply { mkdirs() }
        val file = File(directory, "chat-layout-sample-${sampleWidth}-${sampleHeight}-${transparent}.png")
        sampleFile = file
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        sample = FileProvider.getUriForFile(activity, "${activity.packageName}.composer.files", file)
        root.addView(timeline, FrameLayout.LayoutParams(-1, -1))
        val topBar = if (showChrome) HomeTopBar(activity).also { bar ->
            root.addView(bar, FrameLayout.LayoutParams(-1, -2, android.view.Gravity.TOP))
            bar.addOnLayoutChangeListener { _, _, top, _, bottom, _, _, _, _ ->
                val delta = bottom - top - timeline.paddingTop
                timeline.setPadding(timeline.paddingLeft, bottom - top, timeline.paddingRight, timeline.paddingBottom)
                timeline.shiftForTopInset(delta)
            }
        } else null
        composer.attachTo(root)
        root.addView(flight, FrameLayout.LayoutParams(-1, -1))
        val markerSize = (12 * density).toInt()
        root.addView(marker, FrameLayout.LayoutParams(markerSize, markerSize, android.view.Gravity.TOP or android.view.Gravity.START))
        flow = ChatSendFlow(activity.lifecycleScope, composer, timeline, flight,
            draftRequestId = { "fixture-$request" },
            sendDraft = { text, attachments ->
                val key = requestKey("fixture-${request++}")
                if (text.isNotEmpty()) rows += message(text, key, MessageStatus.PENDING)
                attachments.forEach { attachment -> rows += image(key, suppliedImages[attachment.uri]) }
                publishNow()
                true
            },
            sendVoice = { _, _ -> true })
        flow.bind()
        fun boundary() = flow.updateBoundary(composer.capsuleTop - timeline.y)
        composer.onImeOffset = { boundary() }
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> boundary() }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, if (topBar == null) bars.top else 0, bars.right, bars.bottom)
            topBar?.setStatusBarInset(bars.top)
            insets
        }
        composer.onAttachmentsAdded = { added -> added.forEach { composer.setAttachmentState(it.id, AttachmentUploadState.Done) } }
        activity.setContentView(root)
    }

    fun mark(case: Int) = marker.setBackgroundColor(MARKERS[case % MARKERS.size])

    fun draft(text: String, count: Int) {
        input.setText(text)
        // Inject the photo-picker result into the real attachment path, without touching personal media.
        if (count > 0) ComposerView::class.java.getDeclaredMethod("addUris", List::class.java).apply { isAccessible = true }
            .invoke(composer, List(count) { sample })
    }

    fun draftImages(text: String, images: List<ViewerImage.Local>) {
        input.setText(text)
        images.forEach { suppliedImages[it.uri] = it }
        ComposerView::class.java.getDeclaredMethod("addUris", List::class.java).apply { isAccessible = true }
            .invoke(composer, images.map { it.uri })
    }

    fun keyboard(shown: Boolean) {
        if (shown) {
            input.requestFocus()
            activity.getSystemService(InputMethodManager::class.java).showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
        } else composer.dismiss()
    }

    fun send() {
        check(!activity.isDestroyed && composer.isAttachedToWindow) { "Fixture activity was replaced before send" }
        ComposerView::class.java.getDeclaredMethod("sendNow").apply { isAccessible = true }.invoke(composer)
    }

    /** Rows of the latest send, in list order. */
    fun lastSend(): List<ChatMessage> = rows.filter { it.turnId == requestKey("fixture-${request - 1}") }

    fun appendHistoryUpdate() { turn++; rows += message("History update sample", "turn-$turn"); publish() }

    /** A reply on its way to [turnKey]: the typing row, then text replacing it. */
    fun typing(turnKey: String) {
        rows += message("", turnKey, role = ChatRole.AGENT).copy(cardKind = TimelineBlockKinds.LIVE_STATUS)
        publish()
    }

    fun reply(turnKey: String, text: String) {
        rows.removeAll { it.turnId == turnKey && it.cardKind == TimelineBlockKinds.LIVE_STATUS }
        rows += message(text, turnKey, role = ChatRole.AGENT)
        publish()
    }

    private fun message(text: String, turnId: String, status: MessageStatus = MessageStatus.COMPLETED,
                        role: ChatRole = ChatRole.USER) =
        ChatMessage(nextId++, "layout-fixture", turnId, role, text, 0L, status = status)

    private fun image(turnId: String, supplied: ViewerImage.Local? = null): ChatMessage {
        val local = supplied ?: ViewerImage.Local(sample, "image/png", "sample.png", ImageDimensions(sampleWidth, sampleHeight))
        return message("", turnId, MessageStatus.PENDING).copy(cardKind = LiveRowKinds.ATTACHMENT,
            attachment = ChatAttachment(MediaAttachment(local.fileName, local.mime, null,
                MediaSource.UploadedFile("/uploads/abcdefghijklmnopqrstuv-${local.fileName}")), local.dimensions, local))
    }

    private suspend fun publishNow() {
        val next = MessageLayoutPrecomputer(bubbles = bubbles).prepare(rows.toList(), timeline.width, density, 1f,
            activity.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES,
            palette = surf.comma.android.chat.render.ChatPalette.from(activity))
        flow.submit(next)
    }

    private fun publish() { activity.lifecycleScope.launch { publishNow() } }

    /** Where [id]'s content rests in its row, as drawn now (glide included), in window px. */
    fun targetBox(id: Long): FlightBox? {
        val view = timeline.viewForRow(id) ?: return null
        val bounds = RectF()
        if (!(view as FlightTarget).flightBounds(bounds)) return null
        // The row as drawn: its laid-out place plus its translation (the glide), in window px.
        val location = IntArray(2)
        timeline.getLocationInWindow(location)
        val x = location[0] + view.x
        val y = location[1] + view.y
        return FlightBox(x + bounds.left, y + bounds.top, x + bounds.right, y + bounds.bottom)
    }

    fun assertGap() {
        val last = requireNotNull(timeline.viewForRow(rows.last().id))
        assertEquals(activity.resources.getDimensionPixelSize(R.dimen.spacing_3xl),
            (composer.capsuleTop - timeline.y - last.bottom).roundToInt())
        assertEquals(0, timeline.bottomOffsetPx())
        assertTrue(timeline.isPinnedToEnd())
    }

    companion object {
        val MARKERS = intArrayOf(0xFF000000.toInt(), 0xFFFF0000.toInt(), 0xFF00FF00.toInt(), 0xFF0000FF.toInt(),
            0xFFFFFF00.toInt(), 0xFFFF00FF.toInt(), 0xFF00FFFF.toInt(), 0xFFFF8000.toInt(), 0xFF808080.toInt())
    }
}
