package surf.comma.android.chat.live

import android.content.Context
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.*
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.render.*
import surf.comma.android.media.*
import surf.comma.android.media.file.AttachmentFileActions
import surf.comma.android.media.file.FileCardView
import surf.comma.android.media.video.VideoCardView
import surf.comma.android.media.video.VideoPlayerActivity
import surf.comma.android.media.viewer.ChatMediaLink
import surf.comma.android.media.viewer.ImageViewerActivity
import surf.comma.android.ui.theme.DesignTypography

internal class AttachmentCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.ATTACHMENT
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float {
        val media = message.attachment
        val body = if (media == null || media.display == AttachmentDisplay.FILE) FILE_CARD_HEIGHT_DP
            else imageBoxWidthDp(cardWidthDp + CARD_SIDE_INSET_DP, ratio(message)) / ratio(message)
        return body + if (message.status == MessageStatus.FAILED) FAILURE_HEIGHT_DP else 0f
    }
    override fun create(context: Context): View = AttachmentView(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as AttachmentView).bind(item)
    override fun release(view: View) = (view as AttachmentView).releaseMedia()

    companion object {
        const val FILE_CARD_HEIGHT_DP = 64f
        const val IMAGE_MAX_HEIGHT_DP = 420f
        const val FAILURE_HEIGHT_DP = 32f
        fun ratio(message: ChatMessage): Float = message.attachment?.dimensions?.ratio?.toFloat()
            ?: if (message.attachment?.display == AttachmentDisplay.VIDEO) 16f / 9f else 1f
        fun imageBoxWidthDp(rowWidthDp: Float, ratio: Float = 1f) =
            minOf((rowWidthDp - 56f).coerceAtLeast(1f), 320f, IMAGE_MAX_HEIGHT_DP * ratio)
    }
}

/** A fixed-size row; only its pixels and controls change when media arrives. */
internal class AttachmentView(context: Context) : FrameLayout(context), TimelineMediaCell, FlightTarget {
    var onSendFailed: ((Long) -> Unit)? = null
    /** Opens the chat's media viewer at this row's image or video; false when no page handled it. */
    var onOpenMedia: ((PreparedChatMessage) -> Boolean)? = null
    /** The picture's read failed; a tap then retries or opens the file instead of the viewer. */
    private var failed = false
    private var registered: Long? = null
    private var item: PreparedChatMessage? = null
    private var scope: CoroutineScope? = null
    private var binding: MediaImageBinding? = null
    internal var flightImage: SendImagePresentation? = null
        private set
    private var video: VideoCardView? = null
    private var file: FileCardView? = null
    private var visible = false
    private val surface = FrameLayout(context)
    // Neither error label belongs on the common three-image layout path. Construct on failure.
    private var failure: TextView? = null
    private fun showSendFailure(show: Boolean) {
        if (show && failure == null) {
            failure = TextView(context).apply {
                DesignTypography.applyTo(this, DesignTypography.Level.MINI)
                setTextColor(context.getColor(R.color.token_text_error_primary))
                setText(R.string.chat_send_failed_note)
                gravity = Gravity.CENTER_VERTICAL or Gravity.END
                setOnClickListener { item?.message?.id?.let { onSendFailed?.invoke(it) } }
            }.also { addView(it) }
        }
        failure?.visibility = if (show) View.VISIBLE else View.GONE
    }

    init { addView(surface) }

    fun bind(next: PreparedChatMessage) {
        val previous = item?.message?.attachment
        val attachment = next.message.attachment
        val changed = item?.message?.id != next.message.id || item?.let(::boxWidth) != boxWidth(next) ||
            previous?.session != attachment?.session || previous?.display != attachment?.display || previous?.file?.source != attachment?.file?.source ||
            previous?.dimensions != attachment?.dimensions || previous?.preview != attachment?.preview ||
            (attachment?.display == AttachmentDisplay.FILE && previous != attachment)
        item = next
        showSendFailure(next.message.status == MessageStatus.FAILED)
        contentDescription = next.message.attachment?.file?.displayName
        if (changed) {
            releaseMedia()
            surface.removeAllViews()
            if (isAttachedToWindow) start()
        }
        requestLayout()
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); start() }
    override fun onDetachedFromWindow() { releaseMedia(); super.onDetachedFromWindow() }

    private fun start() {
        if (scope != null) return
        val current = item ?: return
        val attachment = current.message.attachment ?: return
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope = it }
        val media = MediaGraph.get(context)
        fun currentSession(): Boolean = attachment.session == null || media.http.session.value?.let {
            it.id == attachment.session && media.http.isCurrent(it)
        } == true
        surface.removeAllViews()
        if (!currentSession()) return
        val widthPx = boxWidth(current)
        failed = false
        if (attachment.display != AttachmentDisplay.FILE) {
            ChatMediaLink.register(current.message.id, surface)
            registered = current.message.id
            surface.setOnLongClickListener { showMenu(); true }
        }
        when (attachment.display) {
            AttachmentDisplay.IMAGE -> {
                val image = SendImageView(context)
                flightImage = image.presentation
                surface.addView(image, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                image.contentDescription = attachment.file.displayName
                image.stateDescription = null
                image.setOnLongClickListener { showMenu(); true }
                image.setOnClickListener {
                    when {
                        failed -> if (attachment.file.source is MediaSource.MessageAttachment) openFile() else retry()
                        // A tap on a loading tile leaves its read running.
                        image.presentation.target == null -> Unit
                        else -> open()
                    }
                }
                owner.launch {
                    val images = media.images()
                    if (!currentSession()) return@launch
                    try {
                        binding = images.bind(image, attachment.image()!!, widthPx, visible,
                            AttachmentCardRenderer.ratio(current.message).toDouble(), onLoaded = ::clearFailure) { showFailure() }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { showFailure() }
                }
            }
            AttachmentDisplay.VIDEO -> {
                val card = VideoCardView(context).also { video = it }
                // A video opens in the viewer from its Play button, even before its cover is read.
                card.onOpen = { open() }
                card.setOnLongClickListener { showMenu(); true }
                surface.addView(card)
                owner.launch {
                    val covers = media.covers()
                    if (!currentSession()) return@launch
                    card.bind(media.files.download(attachment.file), covers, widthPx, owner,
                        attachment.dimensions ?: ImageDimensions(16, 9), visible) { cover, local ->
                        if (visible && currentSession()) context.startActivity(VideoPlayerActivity.intent(context, local,
                            cover?.dimensions?.width ?: 0, cover?.dimensions?.height ?: 0))
                    }
                }
            }
            AttachmentDisplay.FILE -> {
                val card = FileCardView(context).also { file = it }
                surface.addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
                card.bind(attachment.file, media.files.download(attachment.file), owner)
            }
        }
    }

    /** The image or file card, where a sent attachment lands. */
    override fun flightBounds(out: android.graphics.RectF): Boolean {
        if (item == null || surface.width <= 0) return false
        out.set(surface.left.toFloat(), surface.top.toFloat(), surface.right.toFloat(), surface.bottom.toFloat())
        return true
    }

    override val flightCornerRadius: Float get() = resources.getDimension(
        when (item?.message?.attachment?.display) {
            AttachmentDisplay.IMAGE, AttachmentDisplay.VIDEO -> R.dimen.radius_4xl
            else -> R.dimen.radius_xl
        },
    )

    override fun setMediaVisible(visible: Boolean) {
        this.visible = visible
        binding?.setVisible(visible)
        video?.setVisible(visible)
    }

    /** The read failed: the tile keeps its size and shows the file's name with a file glyph instead. */
    private fun showFailure() {
        failed = true
        val name = item?.message?.attachment?.file?.displayName.orEmpty()
        val panel = surface.findViewWithTag<View>(FAILURE_TAG) ?: LinearLayout(context).apply {
            tag = FAILURE_TAG
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val padding = (8 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(context.getColor(R.color.token_bg_secondary))
                setStroke((resources.displayMetrics.density).toInt().coerceAtLeast(1), context.getColor(R.color.token_border_primary))
                cornerRadius = resources.getDimension(R.dimen.radius_4xl)
            }
            addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_media_file_image)
                imageTintList = android.content.res.ColorStateList.valueOf(context.getColor(R.color.token_text_secondary))
            }, LinearLayout.LayoutParams((20 * resources.displayMetrics.density).toInt(), (20 * resources.displayMetrics.density).toInt()))
            addView(TextView(context).apply {
                DesignTypography.applyTo(this, DesignTypography.Level.MINI)
                setTextColor(context.getColor(R.color.token_text_secondary))
                maxLines = 2
                ellipsize = android.text.TextUtils.TruncateAt.END
                gravity = Gravity.CENTER
                text = name
            }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = (6 * resources.displayMetrics.density).toInt() })
            // The panel passes taps and presses to the tile under it.
            isClickable = false
            surface.addView(this, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        }
        panel.visibility = View.VISIBLE
        (surface.getChildAt(0) as? SendImageView)?.stateDescription = context.getString(R.string.media_tile_unavailable)
    }

    private fun clearFailure() {
        failed = false
        surface.findViewWithTag<View>(FAILURE_TAG)?.visibility = View.GONE
        (surface.getChildAt(0) as? SendImageView)?.stateDescription = null
    }

    private fun retry() {
        clearFailure()
        binding?.retry()
        val attachment = item?.message?.attachment
        if (attachment?.display == AttachmentDisplay.VIDEO) MediaGraph.get(context).files.download(attachment.file)?.start()
    }

    private fun open() {
        val current = item ?: return
        val attachment = current.message.attachment ?: return
        val media = MediaGraph.get(context)
        val session = media.http.session.value ?: return
        if (attachment.session != null && (attachment.session != session.id || !media.http.isCurrent(session))) return
        if (onOpenMedia?.invoke(current) == true) return
        if (attachment.gallery.isNotEmpty()) ImageViewerActivity.start(context, attachment.gallery, attachment.galleryIndex)
    }

    /** Downloads the message's attachment and hands it to another app. */
    private fun openFile() = withFile { file, attachment -> FileCardView.open(context, file, attachment) }

    /** Downloads the message's attachment, then runs [act] with it while this row still shows it. */
    private fun withFile(act: (java.io.File, MediaAttachment) -> Unit) {
        val attachment = item?.message?.attachment?.file ?: return
        val owner = scope ?: return
        val download = MediaGraph.get(context).files.download(attachment) ?: return
        owner.launch {
            val file = download.awaitFile() ?: return@launch
            if (isAttachedToWindow) act(file, attachment)
        }
    }

    /** The tile's menu: Retry while it has no picture, then Open file, Save as and Share for a downloadable file. */
    private fun showMenu() {
        val attachment = item?.message?.attachment ?: return
        val menu = surf.comma.android.ui.ActionMenu(context)
        val pictureMissing = if (attachment.display == AttachmentDisplay.VIDEO)
            MediaGraph.get(context).files.download(attachment.file)?.state?.value is surf.comma.android.media.MediaDownloadState.Failed
        else (surface.getChildAt(0) as? SendImageView)?.presentation?.target == null
        if (pictureMissing) menu.item(context.getString(R.string.media_tile_retry)) { retry() }
        if (attachment.file.source is MediaSource.MessageAttachment) menu.item(context.getString(R.string.media_tile_open_file)) { openFile() }
        if (attachment.file.source != null) {
            menu.item(context.getString(R.string.media_file_save_as)) {
                withFile { file, media -> AttachmentFileActions.saveAs(context, file, media) }
            }
            menu.item(context.getString(R.string.media_file_share)) {
                withFile { file, media -> AttachmentFileActions.share(context, file, media) }
            }
        }
        menu.show(surface, haptic = true)
    }

    override fun releaseMedia() {
        registered?.let { ChatMediaLink.unregister(it, surface) }
        registered = null
        surface.setOnLongClickListener(null)
        surface.findViewWithTag<View>(FAILURE_TAG)?.let(surface::removeView)
        binding?.close(); binding = null
        flightImage?.clear(); flightImage = null
        video?.unbind(); video = null
        file?.unbind(); file = null
        scope?.cancel(); scope = null
    }

    private fun boxWidth(current: PreparedChatMessage): Int {
        val density = resources.displayMetrics.density
        // Prepared geometry already knows the measured viewport, even before this row attaches.
        val body = current.cellHeightPx - current.topMarginPx -
            if (current.message.status == MessageStatus.FAILED) (AttachmentCardRenderer.FAILURE_HEIGHT_DP * density).toInt() else 0
        return if (current.message.attachment?.display == AttachmentDisplay.FILE)
            (resources.displayMetrics.widthPixels - current.sideMarginPx * 2).coerceAtLeast(1)
        else (body * AttachmentCardRenderer.ratio(current.message)).toInt().coerceAtLeast(1)
    }

    private companion object {
        const val FAILURE_TAG = "attachment-failure"
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val current = item
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = current?.cellHeightPx ?: 0
        setMeasuredDimension(width, height)
        if (current == null) return
        val failureHeight = if (failure?.visibility == View.VISIBLE) (AttachmentCardRenderer.FAILURE_HEIGHT_DP * resources.displayMetrics.density).toInt() else 0
        val boxWidth = if (current.message.attachment?.display == AttachmentDisplay.FILE)
            (width - current.sideMarginPx * 2).coerceAtLeast(1) else boxWidth(current)
        surface.measure(MeasureSpec.makeMeasureSpec(boxWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - current.topMarginPx - failureHeight).coerceAtLeast(1), MeasureSpec.EXACTLY))
        if (failureHeight > 0) failure?.measure(MeasureSpec.makeMeasureSpec(boxWidth, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(failureHeight, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val x = if (current.message.role == ChatRole.USER) width - current.sideMarginPx - surface.measuredWidth else current.sideMarginPx
        val y = current.topMarginPx
        surface.layout(x, y, x + surface.measuredWidth, y + surface.measuredHeight)
        failure?.takeIf { it.visibility == View.VISIBLE }?.let { it.layout(x, surface.bottom, x + it.measuredWidth, height) }
    }
}
