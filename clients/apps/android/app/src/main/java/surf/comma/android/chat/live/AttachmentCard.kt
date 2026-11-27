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
import surf.comma.android.chat.model.ChatAttachment
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
import kotlin.math.roundToInt

/** Per-conversation UI state for multi-image group rows, surviving RecyclerView recycling. */
internal interface ImageGroupHost {
    fun isExpanded(rowId: Long): Boolean
    fun setExpanded(rowId: Long, expanded: Boolean)
    fun browseState(rowId: Long): MediaImageGroupBrowseState
    fun setBrowseState(rowId: Long, state: MediaImageGroupBrowseState)
}

/** Exact precomputed height for image group attachment rows matching [MediaImageGroupView.onMeasure]. */
internal class MediaImageGroupLayout(
    private val density: Float,
    private val isExpanded: (Long) -> Boolean,
) : ChatCardHeights {
    override fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int? {
        if (message.cardKind != LiveRowKinds.ATTACHMENT) return null
        val group = message.imageGroup
        if (group.isEmpty()) return null
        val columnWidthDp = (rowWidthPx - sideMarginPx * 2).coerceAtLeast(1) / density
        val first = group.first()
        val bodyDp = MediaImageGroupGeometry.totalHeightDp(
            columnWidthDp = columnWidthDp,
            count = group.size,
            expanded = isExpanded(message.id),
            singleWidthPx = first.dimensions?.width,
            singleHeightPx = first.dimensions?.height,
        ) + if (message.status == MessageStatus.FAILED) AttachmentCardRenderer.FAILURE_HEIGHT_DP else 0f
        return (bodyDp * density).roundToInt()
    }
}

internal class AttachmentCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.ATTACHMENT
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float {
        val group = message.imageGroup
        val body = if (group.isNotEmpty()) {
            val first = group.first()
            MediaImageGroupGeometry.totalHeightDp(
                columnWidthDp = cardWidthDp,
                count = group.size,
                expanded = false,
                singleWidthPx = first.dimensions?.width,
                singleHeightPx = first.dimensions?.height,
            )
        } else {
            val media = message.attachment
            if (media == null || media.display == AttachmentDisplay.FILE) FILE_CARD_HEIGHT_DP
            else imageBoxWidthDp(cardWidthDp + CARD_SIDE_INSET_DP, ratio(message)) / ratio(message)
        }
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
    var onOpenMedia: ((PreparedChatMessage, Int) -> Boolean)? = null
    var imageGroupHost: ImageGroupHost? = null
    /** Optional test override for [MediaComponents]; defaults to [MediaGraph.get]. */
    internal var mediaComponentsProvider: (() -> MediaComponents)? = null
    /** Optional test hook observing failed `MediaSource.MessageAttachment` file-open taps. */
    internal var onOpenFileOverride: ((ChatAttachment) -> Unit)? = null
    /** The picture's read failed; a tap then retries or opens the file instead of the viewer. */
    private var failed = false
    private var registered: Long? = null
    private var registeredGroup: MediaImageGroupView? = null
    private var item: PreparedChatMessage? = null
    private var scope: CoroutineScope? = null
    private var binding: MediaImageBinding? = null
    internal var flightImage: SendImagePresentation? = null
        private set
    internal var imageGroupView: MediaImageGroupView? = null
        private set
    private var video: VideoCardView? = null
    private var file: FileCardView? = null
    private var visible = false
    private val surface = FrameLayout(context).apply {
        clipChildren = false
        clipToPadding = false
    }
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

    init {
        clipChildren = false
        clipToPadding = false
        addView(surface)
    }

    fun bind(next: PreparedChatMessage) {
        val previousGroup = item?.message?.imageGroup.orEmpty()
        val nextGroup = next.message.imageGroup
        val previous = item?.message?.attachment
        val attachment = next.message.attachment
        val changed = item?.message?.id != next.message.id ||
            previousGroup != nextGroup ||
            (nextGroup.isEmpty() && (
                item?.let(::boxWidth) != boxWidth(next) ||
                    previous?.session != attachment?.session || previous?.display != attachment?.display ||
                    previous?.file?.source != attachment?.file?.source ||
                    previous?.dimensions != attachment?.dimensions || previous?.preview != attachment?.preview ||
                    (attachment?.display == AttachmentDisplay.FILE && previous != attachment)
                ))
        item = next
        showSendFailure(next.message.status == MessageStatus.FAILED)
        contentDescription = nextGroup.firstOrNull()?.file?.displayName ?: next.message.attachment?.file?.displayName
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
        if (scope != null || imageGroupView != null) return
        val current = item ?: return
        val group = current.message.imageGroup
        if (group.isNotEmpty()) {
            startImageGroup(current, group)
            return
        }
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
            ChatMediaLink.register(current.message.id, surface, flightCornerRadius)
            registered = current.message.id
            surface.setOnLongClickListener { showMenu(attachment, surface); true }
        }
        when (attachment.display) {
            AttachmentDisplay.IMAGE -> Unit // Handled by startImageGroup above.
            AttachmentDisplay.VIDEO -> {
                val card = VideoCardView(context).also { video = it }
                // A video opens in the viewer from its Play button, even before its cover is read.
                card.onOpen = { open(0) }
                card.setOnLongClickListener { showMenu(attachment, surface); true }
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

    private fun startImageGroup(current: PreparedChatMessage, group: List<ChatAttachment>) {
        surface.removeAllViews()
        failed = false
        val rowId = current.message.id
        val view = MediaImageGroupView(context).also { imageGroupView = it }
        view.mediaComponentsProvider = mediaComponentsProvider
        val host = imageGroupHost
        view.bind(
            items = group,
            alignEnd = current.message.role == ChatRole.USER,
            expanded = host?.isExpanded(rowId) ?: false,
            browseState = host?.browseState(rowId) ?: MediaImageGroupBrowseState(),
            session = group.firstOrNull()?.session,
        )
        view.setMediaVisible(visible)
        view.onCardClick = { index ->
            val attachment = group.getOrNull(index)
            when {
                attachment == null -> Unit
                view.isFailed(index) -> {
                    if (attachment.file.source is MediaSource.MessageAttachment) openFile(attachment)
                    else view.retryCard(index)
                }
                !view.hasLoadedImage(index) -> Unit
                else -> open(index)
            }
        }
        view.onCardLongClick = { index, anchor ->
            group.getOrNull(index)?.let { showMenu(it, anchor, imageIndex = index) }
        }
        view.onExpandedChange = { exp -> host?.setExpanded(rowId, exp) }
        view.onBrowseStateChange = { st -> host?.setBrowseState(rowId, st) }
        flightImage = view.primaryFlightImage
        surface.addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        ChatMediaLink.register(rowId, surface, flightCornerRadius)
        ChatMediaLink.registerGroup(rowId, view)
        registered = rowId
        registeredGroup = view
    }

    /** The image or file card, where a sent attachment lands. */
    override fun flightBounds(out: android.graphics.RectF): Boolean {
        if (item == null || surface.width <= 0) return false
        val group = imageGroupView
        val card = group?.cardViewAt(0)
        if (group != null && card != null && card.width > 0 && card.height > 0) {
            val container = card.parent as? View
            val dx = surface.left + group.left + (container?.left ?: 0)
            val dy = surface.top + group.top + (container?.top ?: 0)
            out.set(
                (dx + card.left).toFloat(),
                (dy + card.top).toFloat(),
                (dx + card.right).toFloat(),
                (dy + card.bottom).toFloat(),
            )
            return true
        }
        out.set(surface.left.toFloat(), surface.top.toFloat(), surface.right.toFloat(), surface.bottom.toFloat())
        return true
    }

    override val flightCornerRadius: Float get() = resources.getDimension(
        when {
            item?.message?.imageGroup?.isNotEmpty() == true -> R.dimen.radius_xl
            item?.message?.attachment?.display == AttachmentDisplay.VIDEO -> R.dimen.radius_4xl
            else -> R.dimen.radius_xl
        },
    )

    override fun setMediaVisible(visible: Boolean) {
        this.visible = visible
        imageGroupView?.setMediaVisible(visible)
        binding?.setVisible(visible)
        video?.setVisible(visible)
    }

    private fun open(imageIndex: Int) {
        val current = item ?: return
        val group = current.message.imageGroup
        val attachment = group.getOrNull(imageIndex) ?: current.message.attachment ?: return
        val media = mediaComponentsProvider?.invoke() ?: MediaGraph.get(context)
        val session = media.http.session.value ?: return
        if (attachment.session != null && (attachment.session != session.id || !media.http.isCurrent(session))) return
        if (onOpenMedia?.invoke(current, imageIndex) == true) return
        if (attachment.gallery.isNotEmpty()) {
            val targetIndex = attachment.galleryIndex.coerceIn(0, attachment.gallery.lastIndex)
            ImageViewerActivity.start(context, attachment.gallery, targetIndex)
        }
    }

    /** Downloads the attachment and hands it to another app. */
    private fun openFile(attachment: ChatAttachment) {
        onOpenFileOverride?.let {
            it(attachment)
            return
        }
        withFile(attachment) { file, media -> FileCardView.open(context, file, media) }
    }

    /** Downloads the attachment, then runs [act] with it while this row still shows it. */
    private fun withFile(attachment: ChatAttachment, act: (java.io.File, MediaAttachment) -> Unit) {
        val mediaFile = attachment.file
        val owner = scope ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope = it }
        val media = mediaComponentsProvider?.invoke() ?: MediaGraph.get(context)
        val download = media.files.download(mediaFile) ?: return
        owner.launch {
            val file = download.awaitFile() ?: return@launch
            if (isAttachedToWindow) act(file, mediaFile)
        }
    }

    /** The menu entries for [attachment] (optionally at [imageIndex] inside an image group). */
    internal fun menuEntries(attachment: ChatAttachment, imageIndex: Int? = null): List<Pair<String, () -> Unit>> {
        val entries = ArrayList<Pair<String, () -> Unit>>()
        val media = mediaComponentsProvider?.invoke() ?: MediaGraph.get(context)
        val imageRetryable = imageIndex != null && imageGroupView?.let { it.isFailed(imageIndex) || !it.hasLoadedImage(imageIndex) } == true
        val videoFailed = attachment.display == AttachmentDisplay.VIDEO &&
            media.files.download(attachment.file)?.state?.value is surf.comma.android.media.MediaDownloadState.Failed
        if (imageRetryable) {
            entries += context.getString(R.string.media_tile_retry) to { imageGroupView?.retryCard(imageIndex!!) ?: Unit }
        } else if (videoFailed) {
            entries += context.getString(R.string.media_tile_retry) to { media.files.download(attachment.file)?.start() ?: Unit }
        }
        if (attachment.file.source is MediaSource.MessageAttachment) {
            entries += context.getString(R.string.media_tile_open_file) to { openFile(attachment) }
        }
        if (attachment.file.source != null) {
            entries += context.getString(R.string.media_file_save_as) to {
                withFile(attachment) { file, fileMedia -> AttachmentFileActions.saveAs(context, file, fileMedia) }
            }
            entries += context.getString(R.string.media_file_share) to {
                withFile(attachment) { file, fileMedia -> AttachmentFileActions.share(context, file, fileMedia) }
            }
        }
        return entries
    }

    /** The tile's menu: Retry while failed or unloaded, then Open file, Save as and Share for a downloadable file. */
    private fun showMenu(attachment: ChatAttachment, anchor: View, imageIndex: Int? = null) {
        val menu = surf.comma.android.ui.ActionMenu(context)
        menuEntries(attachment, imageIndex).forEach { (label, action) -> menu.item(label) { action() } }
        menu.show(anchor, haptic = true)
    }

    override fun releaseMedia() {
        registered?.let { id ->
            ChatMediaLink.unregister(id, surface)
            registeredGroup?.let { ChatMediaLink.unregisterGroup(id, it) }
        }
        registered = null
        registeredGroup = null
        surface.setOnLongClickListener(null)
        imageGroupView?.releaseMedia()
        imageGroupView = null
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

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val current = item
        val width = MeasureSpec.getSize(widthMeasureSpec)
        if (current == null) {
            setMeasuredDimension(width, 0)
            return
        }
        val failureHeight = if (failure?.visibility == View.VISIBLE) {
            (AttachmentCardRenderer.FAILURE_HEIGHT_DP * resources.displayMetrics.density).toInt()
        } else 0

        if (current.message.imageGroup.isNotEmpty()) {
            val columnWidth = (width - current.sideMarginPx * 2).coerceAtLeast(1)
            surface.measure(
                MeasureSpec.makeMeasureSpec(columnWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
            )
            val totalHeight = current.topMarginPx + surface.measuredHeight + failureHeight
            if (failureHeight > 0) {
                failure?.measure(
                    MeasureSpec.makeMeasureSpec(columnWidth, MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec(failureHeight, MeasureSpec.EXACTLY),
                )
            }
            setMeasuredDimension(width, totalHeight)
            return
        }

        val height = current.cellHeightPx
        setMeasuredDimension(width, height)
        val boxWidth = if (current.message.attachment?.display == AttachmentDisplay.FILE)
            (width - current.sideMarginPx * 2).coerceAtLeast(1) else boxWidth(current)
        surface.measure(MeasureSpec.makeMeasureSpec(boxWidth, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - current.topMarginPx - failureHeight).coerceAtLeast(1), MeasureSpec.EXACTLY))
        if (failureHeight > 0) failure?.measure(MeasureSpec.makeMeasureSpec(boxWidth, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(failureHeight, MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val x = if (current.message.imageGroup.isNotEmpty()) {
            current.sideMarginPx
        } else if (current.message.role == ChatRole.USER) {
            width - current.sideMarginPx - surface.measuredWidth
        } else {
            current.sideMarginPx
        }
        val y = current.topMarginPx
        surface.layout(x, y, x + surface.measuredWidth, y + surface.measuredHeight)
        failure?.takeIf { it.visibility == View.VISIBLE }?.let { it.layout(x, surface.bottom, x + it.measuredWidth, height) }
    }
}
