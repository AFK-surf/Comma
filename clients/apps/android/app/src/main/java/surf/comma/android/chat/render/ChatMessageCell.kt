package surf.comma.android.chat.render

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.RenderNode
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import surf.comma.android.media.TimelineImageView
import surf.comma.android.media.localViewerImage
import android.view.animation.AnimationUtils
import androidx.core.content.ContextCompat
import androidx.core.graphics.withTranslation
import androidx.core.view.isGone
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.DeviceOrigin
import surf.comma.android.chat.model.MessageSource
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.min

class ChatMessageCell(context: Context) : FrameLayout(context), TimelineMediaCell, FlightTarget {
    private val pictures = mutableListOf<Pair<PreparedContentBlock.Image, TimelineImageView>>()
    private var mediaVisible = false
    private var visibleTop = 0
    private var visibleHeight = 0
    init { setWillNotDraw(false) }

    override fun setMediaVisible(visible: Boolean) {
        mediaVisible = visible
        updatePictureVisibility()
    }

    /** Where each row's streaming reveal stands; set by the adapter. */
    internal var reveals: TextRevealBook? = null
    private val revealCut = RevealCut()
    private val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.DST_IN)
    }
    private val maskShader = LinearGradient(0f, 0f, 1f, 0f, 0xFFFFFFFF.toInt(), 0x00FFFFFF, Shader.TileMode.CLAMP)
        .also { maskPaint.shader = it }
    private val maskMatrix = Matrix()

    private fun updatePictureVisibility() {
        pictures.forEach { (block, view) ->
            view.setVisible(mediaVisible && block.yOffsetPx + block.heightPx > visibleTop &&
                block.yOffsetPx < visibleTop + visibleHeight)
        }
    }

    override fun releaseMedia() { pictures.forEach { it.second.release() } }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val item = prepared ?: return
        val columnLeft = when (item.message.role) {
            ChatRole.USER -> width - item.sideMarginPx - contentWidth(item)
            ChatRole.AGENT -> item.sideMarginPx
            ChatRole.SYSTEM -> (width - contentWidth(item)) / 2
        }
        pictures.forEach { (block, view) ->
            val x = columnLeft + block.leftInsetPx
            view.layout(x, block.yOffsetPx, x + block.widthPx, block.yOffsetPx + block.heightPx)
        }
        scrollSlots.forEach { slot ->
            if (slot.container.isGone) return@forEach
            val x = columnLeft + slot.leftInset
            slot.container.layout(x, slot.top, x + slot.viewportWidth, slot.top + slot.viewportHeight)
        }
    }

    /** The bubble, where a sent message lands. */
    override fun flightBounds(out: android.graphics.RectF): Boolean {
        val item = prepared ?: return false
        if (!item.drawBubble || item.message.role != ChatRole.USER) return false
        val left = (width - item.sideMarginPx - contentWidth(item)).toFloat()
        out.set(left, item.bubbleTopPx.toFloat(), left + item.bubbleWidthPx, (item.bubbleTopPx + item.bubbleHeightPx).toFloat())
        return true
    }

    override val flightCornerRadius: Float get() = prepared?.cornerRadiusPx ?: 0f

    override val flightTailPx: Float get() = prepared?.tailPx?.toFloat() ?: 0f

    var onImageClick: ((String) -> Unit)? = null
    var onRetry: ((Long) -> Unit)? = null
    var onDiscard: ((Long) -> Unit)? = null
    /** The failure mark or note of an unsent user message was tapped. */
    var onSendFailed: ((Long) -> Unit)? = null
    var onLongPress: ((PreparedChatMessage) -> Unit)? = null
    var onCopyCode: ((String) -> Unit)? = null
    /** A task brief was tapped open or closed; the host flips it and binds the row again. */
    var onToggleBrief: ((Long) -> Unit)? = null

    private val density = resources.displayMetrics.density
    private val bubblePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bubbleBounds = RectF()
    /** The bubble with its tail, rebuilt only when the bubble moves or changes size. */
    private val bubbleOutline = android.graphics.Path()
    private val tailScratch = android.graphics.Path()
    private val outlineBounds = RectF()
    private var outlineRight = false
    private val actionHits = ArrayList<RectF>()
    private val actionKinds = ArrayList<MessageAction>()
    private val actionPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rulePaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val deviceMarkers = HashMap<DeviceOrigin, Drawable>()
    private val copyHits = ArrayList<RectF>()
    private val copyTexts = ArrayList<String>()
    /**
     * Code bodies and tables scroll sideways in `:scroll` containers, one per block. Offsets are
     * kept in [blockScrolls] by message id and block, so streaming rebinds keep them and a reused
     * cell does not carry them to another message. The adapter shares one book per timeline.
     */
    internal var blockScrolls = BlockScrollBook()
    private val scrollSlots = ArrayList<ScrollableBlockSlot>()
    private var downX = 0f
    private var downY = 0f
    private var selectionAnchor: PointF? = null
    private val touchSlop = android.view.ViewConfiguration.get(context).scaledTouchSlop
    private val actionTextPaint = android.text.TextPaint(Paint.ANTI_ALIAS_FLAG)
    private var prepared: PreparedChatMessage? = null
    internal var textSelection: MessageTextSelection? = null
        private set

    fun selectText(fullBlocks: List<MessageContent> = prepared?.contents.orEmpty()) {
        val item = prepared ?: return
        clearTextSelection()
        val geometry = MessageSelectionGeometry(item)
        if (geometry.text.isBlank()) return
        (parent as? ChatTimelineView)?.stopScroll()
        textSelection = MessageTextSelection(this, geometry,
            runs = { geometry.runs(columnLeftOf(item)) { index -> blockScrolls[BlockScrollBook.Key(item.message.id, index)] } },
            fullText = SelectableText.build(fullBlocks).toString(),
            onFinish = { textSelection = null })
        textSelection?.begin(selectionAnchor)
        selectionAnchor = null
    }

    internal fun clearTextSelection() { textSelection?.finish() }

    internal fun scrollSelectionHorizontally(x: Float, y: Float) {
        val item = prepared ?: return
        val slot = scrollSlots.firstOrNull { !it.container.isGone && y >= it.top && y < it.top + it.viewportHeight } ?: return
        val left = columnLeftOf(item) + slot.leftInset
        val edge = resources.getDimension(R.dimen.spacing_3xl)
        val step = (8 * density).toInt()
        val delta = when {
            x < left + edge -> -step
            x > left + slot.viewportWidth - edge -> step
            else -> 0
        }
        if (delta != 0) slot.container.scrollOffset += delta
    }
    private var blockNodes: Array<RenderNode?> = emptyArray()
    private var firstVisibleBlock = 0
    private var lastVisibleBlock = -1
    private var actionMessageId: Long? = null
    private val longPressDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onLongPress(event: MotionEvent) {
                val item = prepared ?: return
                if (TypingBubble.isTypingRow(item)) return
                if (actionHits.any { it.contains(event.x, event.y) }) return
                selectionAnchor = PointF(event.x, event.y)
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                onLongPress?.invoke(item)
            }

            /** A closed brief opens from anywhere on it; an open one closes from its title or footer. */
            override fun onSingleTapUp(event: MotionEvent): Boolean {
                val brief = prepared?.brief?.takeIf { it.expandable } ?: return false
                // A gesture whose moves were coalesced away still ends far from where it began.
                if (abs(event.x - downX) > touchSlop || abs(event.y - downY) > touchSlop) return false
                val onChrome = event.y < brief.titleTopPx + brief.title.height + BRIEF_TITLE_HIT_DP * density ||
                    event.y in (height - brief.footerBlockPx).toFloat()..(height - brief.bottomGapPx).toFloat()
                if (brief.expanded && !onChrome) return false
                performClick()
                return true
            }
        },
    )
    /** A brief's drawn height, which follows the row's height with a spring as it opens. */
    private var briefHeight = 0f
        set(value) {
            if (field == value) return
            field = value
            requestLayout()
            invalidate()
        }
    private val briefSpring = DesignSpring(this, BRIEF_HEIGHT, DesignMotion.springSize, BRIEF_HEIGHT_STEP)
    private val briefFade = Paint(Paint.ANTI_ALIAS_FLAG)
    private var briefFadeKey = 0L
    private val sendFailedIcon by lazy { ContextCompat.getDrawable(context, R.drawable.ic_chat_send_failed)!!.mutate() }
    private val retryIcon by lazy { ContextCompat.getDrawable(context, R.drawable.ic_chat_retry)!!.mutate() }
    private val skeletonPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val sheenPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var sheenShader: LinearGradient? = null
    private var sheenTrackWidth = 0f
    private var sheenColor = 0
    private val sheenMatrix = Matrix()
    private val typing = TypingBubble()
    /** The typing bubble's pop-in scale; 1 at rest. */
    private var typingScale = 1f
        set(value) {
            field = value
            invalidate()
        }
    private val typingPop = DesignSpring(this, TYPING_SCALE, DesignMotion.springScale, TYPING_SCALE_STEP)
    /** Whether the last draw of the typing bubble asked for another frame. */
    private var typingLooping = false
    private var fadeFrom: PreparedChatMessage? = null
    /** The first-token cross-fade's opacity at the last draw, for children drawn after it. */
    private var childFadeIn = 1f
    private var fadeStartMs = 0L

    fun bind(item: PreparedChatMessage) {
        if (prepared?.cacheKey == item.cacheKey) {
            invalidate()
            return
        }
        clearTextSelection()
        selectionAnchor = null
        val previous = prepared
        val previousNodes = blockNodes
        if (previous?.message?.id != item.message.id) settleTypingPop()
        val briefMoves = item.brief != null && previous?.brief != null && previous.message.id == item.message.id &&
            previous.cellHeightPx != item.cellHeightPx && isAttachedToWindow
        if (briefMoves) {
            if (!briefSpring.isRunning) briefHeight = previous!!.cellHeightPx.toFloat()
        } else {
            briefSpring.cancel()
            briefHeight = item.cellHeightPx.toFloat()
        }
        prepared = item
        if (briefMoves) briefSpring.animateTo(item.cellHeightPx.toFloat())
        val imageBlocks = item.blocks.filterIsInstance<PreparedContentBlock.Image>()
        if (pictures.map { it.first } != imageBlocks) {
            releaseMedia()
            pictures.forEach { removeView(it.second) }
            pictures.clear()
            imageBlocks.forEach { block ->
                val picture = TimelineImageView(context).apply {
                    bind(localViewerImage(block.source))
                    onOpen = { onImageClick?.invoke(block.source) }
                    setVisible(mediaVisible)
                }
                pictures += block to picture
                addView(picture)
            }
        }
        // 骨架行原地转正文（首 token）：结构高度由骨架≈首段正文兜住，
        // 观感再用交叉淡入收口（骨架淡出 250ms、正文淡入 400ms）。
        fadeFrom = if (
            previous != null && previous.message.id == item.message.id &&
            previous.message.cardKind == TimelineBlockKinds.LIVE_STATUS &&
            item.message.cardKind == null
        ) {
            fadeStartMs = AnimationUtils.currentAnimationTimeMillis()
            previous
        } else {
            null
        }
        blockNodes = arrayOfNulls<RenderNode>(item.blocks.size).also { next ->
            if (previous != null) {
                item.blocks.forEachIndexed { newIndex, newBlock ->
                    if (newBlock !is PreparedContentBlock.Text) return@forEachIndexed
                    val oldIndex = previous.blocks.indexOfFirst { oldBlock ->
                        oldBlock is PreparedContentBlock.Text &&
                            oldBlock.contentIndex == newBlock.contentIndex &&
                            oldBlock.firstLine == newBlock.firstLine &&
                            oldBlock.layout === newBlock.layout
                    }
                    if (oldIndex >= 0) next[newIndex] = previousNodes.getOrNull(oldIndex)
                }
            }
        }
        bindScrollSlots(item)
        firstVisibleBlock = 0
        lastVisibleBlock = -1
        // 格子本体不再是重试按钮：读一半失败回答随手一点就重发过一次请求。
        actionMessageId = item.message.id.takeIf { item.actions.isNotEmpty() }
        isClickable = actionMessageId != null || item.imageSources.isNotEmpty() || item.brief?.expandable == true
        isLongClickable = true
        val stateDescription = when (item.message.status) {
            MessageStatus.FAILED -> ". Failed: ${item.message.statusDetail.orEmpty()}"
            else -> ""
        }
        val sourceNote = listOfNotNull(
            DeviceOrigin.markFor(item.message)?.let { context.getString(DeviceOriginMarker.labelFor(it)) },
            context.getString(R.string.message_source_voice)
                .takeIf { item.message.source == MessageSource.VOICE },
        ).takeIf { it.isNotEmpty() }?.joinToString(", ", prefix = " (", postfix = ")").orEmpty()
        contentDescription = when (item.message.role) {
            ChatRole.USER -> "You$sourceNote: ${item.message.text}"
            ChatRole.AGENT -> if (TypingBubble.isTypingRow(item)) "Agent is replying" else
                "Agent$sourceNote: ${item.message.text}$stateDescription"
            ChatRole.SYSTEM -> "System$sourceNote: ${item.message.text}"
        }
        requestLayout()
        invalidate()
    }

    /**
     * Long presses are watched for here, before the children, so pressing and holding a code body
     * or table opens the menu like the rest of the message. Moving past the touch slop cancels the
     * press at the same distance a sideways scroll starts.
     */
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            downX = event.x
            downY = event.y
        }
        longPressDetector.onTouchEvent(event)
        return super.dispatchTouchEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val action = actionHits.indexOfFirst { it.contains(event.x, event.y) }
        val copy = copyHits.indexOfFirst { it.contains(event.x, event.y) }
        return when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> action >= 0 || copy >= 0 || isLongClickable
            MotionEvent.ACTION_UP -> {
                if (copy >= 0) {
                    onCopyCode?.invoke(copyTexts[copy])
                    performClick()
                } else if (action >= 0) {
                    actionMessageId?.let { messageId ->
                        when (actionKinds[action]) {
                            // A row retries whatever it failed at: the turn, or its stop.
                            MessageAction.RETRY -> onRetry?.invoke(messageId)
                            MessageAction.DISCARD -> onDiscard?.invoke(messageId)
                            MessageAction.SEND_FAILED -> onSendFailed?.invoke(messageId)
                        }
                        performClick()
                    }
                }
                action >= 0 || copy >= 0
            }
            else -> super.onTouchEvent(event)
        }
    }

    /** One `:scroll` container per code block and table, reused in order across binds. */
    private fun bindScrollSlots(item: PreparedChatMessage) {
        var used = 0
        item.blocks.forEachIndexed { index, block ->
            if (!ScrollableBlockSlot.scrolls(block)) return@forEachIndexed
            val slot = scrollSlots.getOrNull(used) ?: ScrollableBlockSlot(context) { blockScrolls }.also {
                scrollSlots += it
                addView(it.container)
            }
            slot.bind(item.message.id, index, block, item.horizontalPaddingPx)
            slot.container.visibility = VISIBLE
            used++
        }
        for (index in used until scrollSlots.size) {
            scrollSlots[index].release()
            scrollSlots[index].container.visibility = GONE
        }
    }

    override fun performClick(): Boolean {
        super.performClick()
        prepared?.takeIf { it.brief?.expandable == true }?.let { onToggleBrief?.invoke(it.message.id) }
        return true
    }

    override fun performLongClick(): Boolean {
        selectionAnchor = null
        val item = prepared?.takeUnless(TypingBubble::isTypingRow) ?: return false
        val action = onLongPress ?: return super.performLongClick()
        action(item)
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        textSelection?.let { selection ->
            info.text = selection.text
            info.isTextSelectable = true
            info.setTextSelection(selection.start, selection.end)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_SELECTION)
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_COPY)
        }
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        textSelection?.let { selection ->
            if (action == AccessibilityNodeInfo.ACTION_COPY) { selection.copy(); return true }
            if (action == AccessibilityNodeInfo.ACTION_SET_SELECTION && arguments != null) {
                return selection.selectRange(arguments.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT),
                    arguments.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT))
            }
        }
        return super.performAccessibilityAction(action, arguments)
    }

    fun setVisiblePart(visibleTop: Int, visibleHeight: Int) {
        this.visibleTop = visibleTop
        this.visibleHeight = visibleHeight
        updatePictureVisibility()
        val item = prepared ?: return
        resumeTyping()
        if (item.blocks.size <= 1) return
        val top = visibleTop
        val bottom = visibleTop + visibleHeight
        var newFirst = -1
        var newLast = -1
        for (index in item.blocks.indices) {
            val block = item.blocks[index]
            if (block.yOffsetPx + block.heightPx >= top && block.yOffsetPx <= bottom) {
                if (newFirst == -1) newFirst = index
                newLast = index
            } else if (block.yOffsetPx > bottom) {
                break
            }
        }
        if (newFirst != firstVisibleBlock || newLast != lastVisibleBlock) {
            firstVisibleBlock = newFirst
            lastVisibleBlock = newLast
            invalidate()
        }
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val desiredHeight = prepared?.let { if (it.brief != null) briefHeight.toInt() else it.cellHeightPx }
            ?: (56f * density).toInt()
        setMeasuredDimension(width, resolveSize(desiredHeight, heightMeasureSpec))
        pictures.forEach { (block, view) ->
            view.measure(MeasureSpec.makeMeasureSpec(block.widthPx, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(block.heightPx, MeasureSpec.EXACTLY))
        }
        scrollSlots.forEach { slot ->
            if (slot.container.isGone) return@forEach
            slot.container.measure(MeasureSpec.makeMeasureSpec(slot.viewportWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(slot.viewportHeight, MeasureSpec.EXACTLY))
        }
    }

    /** A whole message rising into place is drawn lower, with its pictures; its touch areas stay put. */
    override fun draw(canvas: Canvas) {
        val rise = prepared?.let { reveals?.riseOffset(it.message.id) } ?: 0f
        if (rise == 0f) return super.draw(canvas)
        val save = canvas.save()
        canvas.translate(0f, rise)
        super.draw(canvas)
        canvas.restoreToCount(save)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val item = prepared ?: return
        val columnLeft = columnLeftOf(item)

        val fade = fadeFrom
        var fadeIn = 1f
        if (fade != null) {
            val elapsed = AnimationUtils.currentAnimationTimeMillis() - fadeStartMs
            if (elapsed >= FADE_IN_MS) {
                fadeFrom = null
            } else {
                val tIn = (elapsed.toFloat() / FADE_IN_MS).coerceIn(0f, 1f)
                fadeIn = 1f - (1f - tIn) * (1f - tIn) // ease-out
                val fadeOut = 1f - (elapsed.toFloat() / FADE_OUT_MS).coerceIn(0f, 1f)
                drawFadeOut(canvas, fade, fadeOut)
                postInvalidateOnAnimation()
            }
        }
        val fading = fadeIn < 1f
        childFadeIn = fadeIn
        if (fading) {
            canvas.saveLayerAlpha(0f, 0f, width.toFloat(), height.toFloat(), (fadeIn * 255).toInt())
        }

        val replyError = item.message.cardKind == TimelineBlockKinds.REPLY_ERROR
        val brief = item.brief
        if (brief != null) {
            drawBriefCard(canvas, item, brief, columnLeft)
        } else if (item.drawBubble) {
            bubblePaint.color = when {
                replyError -> color(R.color.chat_error_card_bg)
                item.message.role == ChatRole.USER -> color(R.color.token_bg_brand_solid)
                item.message.role == ChatRole.SYSTEM -> color(R.color.token_bg_tertiary)
                else -> color(R.color.token_markdown_bg_message)
            }
            bubbleBounds.set(
                columnLeft,
                item.bubbleTopPx.toFloat(),
                columnLeft + item.bubbleWidthPx,
                (item.bubbleTopPx + item.bubbleHeightPx).toFloat(),
            )
            if (item.contentAlpha < 1f) {
                bubblePaint.alpha = (bubblePaint.alpha * item.contentAlpha).toInt()
            }
            if (item.tailPx > 0) {
                canvas.drawPath(outlineWithTail(item), bubblePaint)
            } else {
                canvas.drawRoundRect(bubbleBounds, item.cornerRadiusPx, item.cornerRadiusPx, bubblePaint)
            }
            bubblePaint.alpha = 255
            if (replyError) {
                val stroke = density
                rulePaint.color = color(R.color.token_border_error)
                rulePaint.style = Paint.Style.STROKE
                rulePaint.strokeWidth = stroke
                bubbleBounds.inset(stroke / 2f, stroke / 2f)
                canvas.drawRoundRect(bubbleBounds, item.cornerRadiusPx, item.cornerRadiusPx, rulePaint)
                bubbleBounds.inset(-stroke / 2f, -stroke / 2f)
                rulePaint.style = Paint.Style.FILL
            }
        }

        actionHits.clear()
        actionKinds.clear()
        copyHits.clear()
        copyTexts.clear()
        if (isSkeleton(item)) {
            drawSkeleton(canvas, item, shimmer = item.message.status.isActive && motionEnabled())
            if (fading) canvas.restore()
            return
        }
        if (TypingBubble.isTypingRow(item)) {
            drawTyping(canvas, item, columnLeft)
            if (fading) canvas.restore()
            return
        }
        val reveal = reveals?.frameFor(item)
        applyRevealToPictures(item, reveal)
        applyRevealToScrollSlots(reveal)
        val first = if (lastVisibleBlock < 0) 0 else firstVisibleBlock
        val last = if (lastVisibleBlock < 0) item.blocks.lastIndex else lastVisibleBlock
        // A brief's text stops above its footer; while closed, the cut fades out.
        val briefCut = brief?.let { height - it.footerBlockPx }
        if (briefCut != null) {
            canvas.save()
            canvas.clipRect(0, 0, width, briefCut)
        }
        if (first >= 0) {
            for (index in first..min(last, item.blocks.lastIndex)) {
                val block = item.blocks[index]
                val cut = reveal?.let { revealCut.also { cut -> it.track.cut(index, it.revealedPx, cut) } }
                if (cut?.kind == RevealCut.HIDDEN) break
                val partial = cut?.kind == RevealCut.PARTIAL
                // A block other than text fades in whole while the caret crosses it.
                val faded = partial && block !is PreparedContentBlock.Text && block !is PreparedContentBlock.Image
                val layer = if (faded) canvas.saveLayerAlpha(0f, block.yOffsetPx.toFloat(), width.toFloat(),
                    (block.yOffsetPx + block.heightPx).toFloat(), (cut!!.fraction * 255).toInt()) else -1
                when (block) {
                    is PreparedContentBlock.Image -> Unit // Native Coil-backed child, laid out in the reserved box.
                    is PreparedContentBlock.Text -> drawTextBlock(canvas, item, block, index, columnLeft,
                        cut?.takeIf { partial })
                    is PreparedContentBlock.Code -> drawCodeBlock(canvas, item, block, columnLeft)
                    is PreparedContentBlock.Rule -> drawRuleBlock(canvas, item, block, columnLeft)
                    // Drawn whole by its scroll slot, a child of this cell.
                    is PreparedContentBlock.Table, is PreparedContentBlock.Math -> Unit
                }
                if (layer >= 0) canvas.restoreToCount(layer)
            }
        }
        // The footer and its fade are drawn in dispatchDraw, over the code and table children.
        if (briefCut != null) canvas.restore()
        drawVoiceMarker(canvas, item, columnLeft)
        drawDeviceMarker(canvas, item, columnLeft)
        drawActions(canvas, item)
        drawSendFailure(canvas, item, columnLeft)
        if (replyError && item.message.retryable) drawReplyRetry(canvas, item, columnLeft)
        if (fading) canvas.restore()
    }

    /**
     * 语音来源标记。画在正文栏左侧已有的空白里，不改 [PreparedChatMessage]
     * 的任何几何——加进去不会让流式 delta 重排整条消息。
     */
    private fun drawVoiceMarker(canvas: Canvas, item: PreparedChatMessage, columnLeft: Float) {
        val spec = VoiceMarker.spec(
            source = item.message.source,
            columnLeft = columnLeft,
            contentTop = markerTop(item),
            density = density,
        ) ?: return
        markerPaint.color = color(R.color.token_markdown_text_secondary)
        markerPaint.alpha = (255 * item.contentAlpha).toInt().coerceIn(0, 255)
        var cy = spec.top + spec.dotRadius
        for (row in VoiceMarker.DOTS) {
            var cx = spec.left + spec.dotRadius
            for (col in 0 until VoiceMarker.COLS) {
                if (row and (1 shl (VoiceMarker.COLS - 1 - col)) != 0) {
                    canvas.drawCircle(cx, cy, spec.dotRadius, markerPaint)
                }
                cx += spec.pitch
            }
            cy += spec.pitch
        }
        markerPaint.alpha = 255
    }

    /**
     * 另一种设备（比如 Mac）发来的用户消息：在语音标记同一处空白里画设备小图。
     * 和语音标记一样只是标签，不碰气泡、颜色和任何几何。
     */
    private fun drawDeviceMarker(canvas: Canvas, item: PreparedChatMessage, columnLeft: Float) {
        val origin = DeviceOrigin.markFor(item.message) ?: return
        val drawable = deviceMarkers.getOrPut(origin) {
            ContextCompat.getDrawable(context, DeviceOriginMarker.drawableFor(origin))?.mutate() ?: return
        }
        val spec = DeviceOriginMarker.spec(
            origin = origin,
            source = item.message.source,
            columnLeft = columnLeft,
            contentTop = markerTop(item),
            iconWidth = drawable.intrinsicWidth.toFloat(),
            iconHeight = drawable.intrinsicHeight.toFloat(),
            density = density,
        ) ?: return
        drawable.setBounds(
            spec.left.toInt(),
            spec.top.toInt(),
            spec.right.toInt(),
            spec.bottom.toInt(),
        )
        drawable.alpha = (255 * item.contentAlpha).toInt().coerceIn(0, 255)
        drawable.draw(canvas)
    }

    /** [bubbleBounds] and the tail on the speaker's side, as one shape. */
    private fun outlineWithTail(item: PreparedChatMessage): android.graphics.Path {
        val right = item.message.role == ChatRole.USER
        if (outlineBounds != bubbleBounds || outlineRight != right || bubbleOutline.isEmpty) {
            outlineBounds.set(bubbleBounds)
            outlineRight = right
            BubbleTail.outline(bubbleOutline, tailScratch, bubbleBounds, item.cornerRadiusPx, right, density)
        }
        return bubbleOutline
    }

    /** The first line's top: where both source markers line up. */
    private fun markerTop(item: PreparedChatMessage): Float = if (item.drawBubble) {
        (item.bubbleTopPx + item.verticalPaddingPx).toFloat()
    } else {
        item.topMarginPx.toFloat()
    }

    /**
     * An unsent user message: a red mark centred beside the bubble and a note under its right
     * edge. Either opens retry / delete; the mark's touch target is larger than the mark.
     */
    private fun drawSendFailure(canvas: Canvas, item: PreparedChatMessage, bubbleLeft: Float) {
        val note = item.sendFailedNote ?: return
        val icon = sendFailedIcon
        val size = MessageLayoutPrecomputer.SEND_FAILED_ICON_DP * density
        val hit = MessageLayoutPrecomputer.SEND_FAILED_HIT_DP * density
        val centerX = bubbleLeft - MessageLayoutPrecomputer.SEND_FAILED_ICON_GAP_DP * density - size / 2f
        val centerY = item.bubbleTopPx + item.bubbleHeightPx / 2f
        icon.setBounds((centerX - size / 2f).toInt(), (centerY - size / 2f).toInt(),
            (centerX + size / 2f).toInt(), (centerY + size / 2f).toInt())
        icon.draw(canvas)
        addAction(RectF(centerX - hit / 2f, centerY - hit / 2f, centerX + hit / 2f, centerY + hit / 2f),
            MessageAction.SEND_FAILED, item)
        val right = bubbleLeft + item.bubbleWidthPx
        val left = right - note.width
        val top = item.sendFailedNoteTopPx.toFloat()
        canvas.withTranslation(left, top) { note.draw(this) }
        val slack = ((hit - note.height) / 2f).coerceAtLeast(0f)
        addAction(RectF(left, top - slack, right, top + note.height + slack), MessageAction.SEND_FAILED, item)
    }

    /** The retry control in the bottom-right corner of a retryable reply error card. */
    private fun drawReplyRetry(canvas: Canvas, item: PreparedChatMessage, cardLeft: Float) {
        val size = MessageLayoutPrecomputer.SEND_FAILED_ICON_DP * density
        val hit = MessageLayoutPrecomputer.SEND_FAILED_HIT_DP * density
        val right = cardLeft + item.bubbleWidthPx - item.horizontalPaddingPx
        val bottom = item.bubbleTopPx + item.bubbleHeightPx - item.verticalPaddingPx.toFloat()
        retryIcon.setBounds((right - size).toInt(), (bottom - size).toInt(), right.toInt(), bottom.toInt())
        retryIcon.draw(canvas)
        val centerX = right - size / 2f
        val centerY = bottom - size / 2f
        addAction(RectF(centerX - hit / 2f, centerY - hit / 2f, centerX + hit / 2f, centerY + hit / 2f),
            MessageAction.RETRY, item)
    }

    private fun addAction(bounds: RectF, action: MessageAction, item: PreparedChatMessage) {
        actionHits.add(bounds)
        actionKinds.add(action)
        actionMessageId = item.message.id
    }

    /**
     * 失败行尾的「重试 / 放弃」。
     *
     * 描边药丸，右对齐到助手行的左栏 / 用户气泡的右缘，命中区就是药丸本身——
     * 整格轻点不再触发任何东西。
     */
    private fun drawActions(canvas: Canvas, item: PreparedChatMessage) {
        if (item.actions.isEmpty()) return
        val spacing = MessageLayoutPrecomputer.ACTION_SPACING_DP * density
        val height = item.actionsHeightPx.toFloat()
        val total = item.actions.sumOf { it.widthPx } + spacing * (item.actions.size - 1)
        var left = when (item.message.role) {
            ChatRole.USER -> width - item.sideMarginPx - total
            else -> item.sideMarginPx.toFloat()
        }
        val top = item.actionsTopPx.toFloat()
        val radius = height / 2f
        actionTextPaint.textSize = 13f * density * resources.configuration.fontScale
        actionTextPaint.typeface = surf.comma.android.ui.theme.UiSansTypeface
        item.actions.forEach { action ->
            val right = left + action.widthPx
            bubbleBounds.set(left, top, right, top + height)
            val accent = action.action != MessageAction.DISCARD
            actionPaint.style = Paint.Style.STROKE
            actionPaint.strokeWidth = 1f * density
            actionPaint.color = color(if (accent) R.color.token_bg_brand_solid else R.color.token_border_primary)
            canvas.drawRoundRect(bubbleBounds, radius, radius, actionPaint)
            actionTextPaint.color = color(if (accent) R.color.token_bg_brand_solid else R.color.token_text_quaternary)
            val baseline = top + height / 2f -
                (actionTextPaint.descent() + actionTextPaint.ascent()) / 2f
            actionTextPaint.textAlign = Paint.Align.CENTER
            canvas.drawText(action.label, (left + right) / 2f, baseline, actionTextPaint)
            actionHits.add(RectF(left, top, right, top + height))
            actionKinds.add(action.action)
            left = right + spacing
        }
        actionPaint.style = Paint.Style.FILL
    }

    private fun motionEnabled(): Boolean = android.animation.ValueAnimator.areAnimatorsEnabled()

    /**
     * The typing bubble. While it is on screen the row redraws itself every frame; nothing is
     * laid out again. The loop stops as soon as a draw finds the row off screen or its window
     * hidden, and [resumeTyping] restarts it.
     */
    private fun drawTyping(canvas: Canvas, item: PreparedChatMessage, columnLeft: Float) {
        val animate = motionEnabled()
        val scale = typingScale
        typing.draw(canvas, columnLeft, item.topMarginPx.toFloat(), density, TypingBubble.bubbleColor(this),
            TypingBubble.dotColor(this), AnimationUtils.currentAnimationTimeMillis(), scale,
            // The pop starts from nothing, so its first part also fades in.
            alpha = (scale / TYPING_POP_OPAQUE_AT).coerceIn(0f, 1f), animate = animate)
        typingLooping = animate && TypingBubble.keepsAnimating(isAttachedToWindow, windowVisibility == VISIBLE,
            visibleTop, visibleHeight, height)
        if (typingLooping) postInvalidateOnAnimation()
    }

    /** Plays the bubble's pop-in; called when it has just been added to the list. */
    internal fun popInTyping() {
        if (prepared?.let(TypingBubble::isTypingRow) != true || !motionEnabled()) return
        typingPop.cancel()
        typingScale = 0f
        typingPop.animateTo(1f)
    }

    private fun settleTypingPop() {
        typingPop.cancel()
        typingScale = 1f
    }

    /** Restarts the typing loop after the row came back on screen or its window became visible. */
    private fun resumeTyping() {
        if (!typingLooping && prepared?.let(TypingBubble::isTypingRow) == true) invalidate()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        if (visibility == VISIBLE) resumeTyping()
    }

    override fun onDetachedFromWindow() {
        clearTextSelection()
        selectionAnchor = null
        settleTypingPop()
        typingLooping = false
        briefSpring.cancel()
        prepared?.takeIf { it.brief != null }?.let { briefHeight = it.cellHeightPx.toFloat() }
        super.onDetachedFromWindow()
    }

    private fun isSkeleton(item: PreparedChatMessage): Boolean =
        item.message.cardKind == TimelineBlockKinds.LIVE_STATUS &&
            item.message.cardPayload == TimelineBlockKinds.LIVE_STATUS_SKELETON

    /**
     * 思考态骨架：3 条圆角骨架条 + 2000ms 线性循环的 LinearGradient sheen。
     * 自驱逐帧重绘，行被回收/移出窗口后 invalidate 不再排帧，动画自然停。
     */
    private fun drawSkeleton(canvas: Canvas, item: PreparedChatMessage, shimmer: Boolean) {
        val left = item.sideMarginPx.toFloat()
        val available = (width - item.sideMarginPx * 2).coerceAtLeast(1).toFloat()
        val barHeight = LiveStatusSkeleton.BAR_HEIGHT_DP * density
        val gap = LiveStatusSkeleton.BAR_GAP_DP * density
        val radius = LiveStatusSkeleton.CORNER_RADIUS_DP * density
        skeletonPaint.color = color(R.color.skeleton_base)
        var top = item.topMarginPx.toFloat()
        for (index in 0 until LiveStatusSkeleton.BAR_COUNT) {
            val barWidth = if (index == LiveStatusSkeleton.BAR_COUNT - 1) {
                available * LiveStatusSkeleton.LAST_BAR_WIDTH_FRACTION
            } else {
                available
            }
            bubbleBounds.set(left, top, left + barWidth, top + barHeight)
            canvas.drawRoundRect(bubbleBounds, radius, radius, skeletonPaint)
            if (shimmer) {
                canvas.drawRoundRect(bubbleBounds, radius, radius, sheenPaint(left, available))
            }
            top += barHeight + gap
        }
        if (shimmer && isAttachedToWindow) postInvalidateOnAnimation()
    }

    private fun sheenPaint(trackLeft: Float, trackWidth: Float): Paint {
        val sheen = color(R.color.skeleton_sheen)
        val band = (trackWidth * 0.45f).coerceAtLeast(1f)
        if (sheenShader == null || sheenTrackWidth != trackWidth || sheenColor != sheen) {
            sheenShader = LinearGradient(
                0f,
                0f,
                band,
                0f,
                intArrayOf(sheen and 0x00FFFFFF, sheen, sheen and 0x00FFFFFF),
                floatArrayOf(0f, 0.5f, 1f),
                Shader.TileMode.CLAMP,
            )
            sheenPaint.shader = sheenShader
            sheenTrackWidth = trackWidth
            sheenColor = sheen
        }
        val phase = LiveStatusSkeleton.phase(AnimationUtils.currentAnimationTimeMillis())
        val offset = trackLeft - band + phase * (trackWidth + 2 * band)
        sheenMatrix.setTranslate(offset, 0f)
        sheenShader?.setLocalMatrix(sheenMatrix)
        return sheenPaint
    }

    /** 交叉淡入的「出」半场：骨架行画静态骨架条，文字状态行画原布局。 */
    private fun drawFadeOut(canvas: Canvas, fade: PreparedChatMessage, alpha: Float) {
        val layerAlpha = (alpha * 255).toInt()
        if (layerAlpha <= 0) return
        canvas.saveLayerAlpha(0f, 0f, width.toFloat(), height.toFloat(), layerAlpha)
        if (isSkeleton(fade)) {
            drawSkeleton(canvas, fade, shimmer = false)
        } else {
            val columnLeft = fade.sideMarginPx.toFloat()
            for (block in fade.blocks) {
                if (block !is PreparedContentBlock.Text) continue
                canvas.save()
                canvas.translate(
                    columnLeft + fade.horizontalPaddingPx + block.padPx + block.leftInsetPx,
                    (block.yOffsetPx + block.padPx).toFloat(),
                )
                block.layout.draw(canvas)
                canvas.restore()
            }
        }
        canvas.restore()
    }

    /** The card behind a task brief, at the cell's current height, and its title. */
    private fun drawBriefCard(canvas: Canvas, item: PreparedChatMessage, brief: PreparedBrief, columnLeft: Float) {
        val stroke = 1f
        bubbleBounds.set(columnLeft + stroke / 2f, item.bubbleTopPx + stroke / 2f,
            columnLeft + item.bubbleWidthPx - stroke / 2f, height - brief.bottomGapPx - stroke / 2f)
        bubblePaint.color = color(R.color.token_bg_secondary)
        canvas.drawRoundRect(bubbleBounds, item.cornerRadiusPx, item.cornerRadiusPx, bubblePaint)
        rulePaint.color = color(R.color.token_border_primary)
        rulePaint.style = Paint.Style.STROKE
        rulePaint.strokeWidth = stroke
        canvas.drawRoundRect(bubbleBounds, item.cornerRadiusPx, item.cornerRadiusPx, rulePaint)
        rulePaint.style = Paint.Style.FILL
        canvas.withTranslation(columnLeft + item.horizontalPaddingPx, brief.titleTopPx.toFloat()) {
            brief.title.draw(this)
        }
    }

    /** "Show all" / "Show less" on the card's bottom edge, under a fade while text is hidden. */
    private fun drawBriefFooter(canvas: Canvas, item: PreparedChatMessage, brief: PreparedBrief, columnLeft: Float, cut: Int) {
        val footer = brief.footer ?: return
        val left = columnLeft + item.horizontalPaddingPx
        val right = columnLeft + item.bubbleWidthPx - item.horizontalPaddingPx
        if (height < brief.expandedCellHeightPx - 1) {
            val fadeHeight = BRIEF_FADE_DP * density
            val background = color(R.color.token_bg_secondary)
            val key = (background.toLong() shl 32) or cut.toLong()
            if (key != briefFadeKey) {
                briefFadeKey = key
                briefFade.shader = LinearGradient(0f, cut - fadeHeight, 0f, cut.toFloat(),
                    background and 0x00FFFFFF, background, Shader.TileMode.CLAMP)
            }
            canvas.drawRect(left, cut - fadeHeight, right, cut.toFloat(), briefFade)
        }
        canvas.withTranslation(left, (height - brief.bottomGapPx - item.verticalPaddingPx - footer.height).toFloat()) {
            footer.draw(this)
        }
    }

    private fun contentWidth(item: PreparedChatMessage): Int =
        if (item.drawBubble) item.bubbleWidthPx else item.blocks.maxOfOrNull { widthOf(it) } ?: 0

    private fun widthOf(block: PreparedContentBlock): Int = when (block) {
        is PreparedContentBlock.Image -> block.widthPx
        is PreparedContentBlock.Text -> block.layout.width + block.padPx * 2 +
            (prepared?.horizontalPaddingPx ?: 0) * 2
        is PreparedContentBlock.Rule -> block.widthPx + block.leftInsetPx
        is PreparedContentBlock.Code -> block.viewportWidthPx +
            (prepared?.horizontalPaddingPx ?: 0) * 2
        is PreparedContentBlock.Table -> min(block.contentWidthPx, block.viewportWidthPx) +
            block.leftInsetPx
        is PreparedContentBlock.Math -> min(block.contentWidthPx, block.viewportWidthPx) +
            block.leftInsetPx
    }

    /** A code body or table fades in with its block while the caret crosses it, like the box behind it. */
    private fun applyRevealToScrollSlots(reveal: RevealFrame?) {
        scrollSlots.forEach { slot ->
            if (slot.container.visibility != VISIBLE) return@forEach
            val alpha = if (reveal == null) 1f else {
                reveal.track.cut(slot.blockIndex, reveal.revealedPx, revealCut)
                revealCut.fraction
            }
            if (slot.container.alpha != alpha) slot.container.alpha = alpha
        }
    }

    /**
     * A brief's "Show all" and the fade above it go over everything in the card, children
     * included: code bodies and tables are children, drawn after [onDraw], and would otherwise
     * end in a hard edge instead of fading out.
     */
    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        textSelection?.draw(canvas)
        val item = prepared ?: return
        val brief = item.brief ?: return
        drawBriefFooter(canvas, item, brief, columnLeftOf(item), height - brief.footerBlockPx)
    }

    private fun columnLeftOf(item: PreparedChatMessage): Float = when (item.message.role) {
        ChatRole.USER -> (width - item.sideMarginPx - contentWidth(item)).toFloat()
        ChatRole.AGENT -> item.sideMarginPx.toFloat()
        ChatRole.SYSTEM -> (width - contentWidth(item)) / 2f
    }

    /**
     * Scroll slots are children, drawn after [onDraw]: they get the same cross-fade from the
     * thinking skeleton and the same cut above a brief's footer as the text they sit among.
     */
    override fun drawChild(canvas: Canvas, child: View, drawingTime: Long): Boolean {
        if (scrollSlots.none { it.container === child }) return super.drawChild(canvas, child, drawingTime)
        val save = canvas.save()
        prepared?.brief?.let { canvas.clipRect(0, 0, width, height - it.footerBlockPx) }
        if (childFadeIn < 1f) {
            canvas.saveLayerAlpha(child.left.toFloat(), child.top.toFloat(), child.right.toFloat(),
                child.bottom.toFloat(), (childFadeIn * 255).toInt())
        }
        val drawn = super.drawChild(canvas, child, drawingTime)
        canvas.restoreToCount(save)
        return drawn
    }

    /** Pictures inside a revealing reply stay hidden until the caret reaches them. */
    private fun applyRevealToPictures(item: PreparedChatMessage, reveal: RevealFrame?) {
        if (pictures.isEmpty()) return
        pictures.forEach { (block, view) ->
            val alpha = if (reveal == null) 1f else {
                reveal.track.cut(item.blocks.indexOf(block), reveal.revealedPx, revealCut)
                revealCut.fraction
            }
            if (view.alpha != alpha) view.alpha = alpha
        }
    }

    private fun drawTextBlock(
        canvas: Canvas,
        item: PreparedChatMessage,
        block: PreparedContentBlock.Text,
        index: Int,
        columnLeft: Float,
        /** Set while the reveal caret is inside this block. */
        cut: RevealCut? = null,
    ) {
        val textLeft = columnLeft + item.horizontalPaddingPx + block.padPx + block.leftInsetPx
        val textTop = block.yOffsetPx + block.padPx
        val revealedBottom = cut?.let { textTop + block.layout.getLineBottom(it.line) }
        if (revealedBottom != null) {
            canvas.save()
            canvas.clipRect(0, 0, width, revealedBottom)
        }
        if (block.quoteDepth > 0) {
            // 每层一条 2dp 竖线，贴着这一层的缩进落点，不给引用加底色。
            rulePaint.color = color(R.color.token_markdown_border_table)
            val barWidth = QUOTE_BAR_DP * density
            val step = (block.leftInsetPx.toFloat() / block.quoteDepth)
            for (depth in 0 until block.quoteDepth) {
                val barLeft = columnLeft + item.horizontalPaddingPx + depth * step
                bubbleBounds.set(
                    barLeft,
                    block.yOffsetPx.toFloat(),
                    barLeft + barWidth,
                    (block.yOffsetPx + block.heightPx).toFloat(),
                )
                canvas.drawRoundRect(bubbleBounds, barWidth / 2f, barWidth / 2f, rulePaint)
            }
        }
        block.marker?.let { marker ->
            // 右对齐到标号栏的右边界：序号按小数点对齐，9. 和 10. 不互相错开。
            canvas.save()
            canvas.translate(
                columnLeft + item.horizontalPaddingPx + marker.columnRightPx - marker.layout.width,
                textTop.toFloat(),
            )
            marker.layout.draw(canvas)
            canvas.restore()
        }
        if (revealedBottom != null) canvas.restore()
        canvas.save()
        canvas.translate(textLeft, textTop.toFloat())
        if (cut == null) {
            drawBlockText(canvas, item, index, block)
        } else {
            // Lines above the caret as they are; the caret's line behind a soft gradient edge.
            val layout = block.layout
            if (cut.line > 0) {
                canvas.save()
                canvas.clipRect(0f, 0f, layout.width.toFloat(), layout.getLineBottom(cut.line - 1).toFloat())
                drawBlockText(canvas, item, index, block)
                canvas.restore()
            }
            drawCaretLine(canvas, item, index, block, cut.line, cut.offsetPx)
        }
        canvas.restore()
    }

    private fun drawBlockText(canvas: Canvas, item: PreparedChatMessage, index: Int, block: PreparedContentBlock.Text) {
        if (canvas.isHardwareAccelerated) {
            val cached = blockNodes.getOrNull(index)?.takeIf { it.hasDisplayList() }
            canvas.drawRenderNode(cached ?: recordBlock(item, index, block))
        } else {
            block.layout.draw(canvas)
        }
    }

    /**
     * The line the reveal caret is on: drawn in a layer as narrow as the line's glyphs, then
     * masked by a gradient whose transparent edge trails the caret.
     */
    private fun drawCaretLine(
        canvas: Canvas,
        item: PreparedChatMessage,
        index: Int,
        block: PreparedContentBlock.Text,
        line: Int,
        offsetPx: Float,
    ) {
        if (offsetPx <= 0f) return
        val layout = block.layout
        val top = layout.getLineTop(line).toFloat()
        val bottom = layout.getLineBottom(line).toFloat()
        val lineLeft = minOf(layout.getLineLeft(line), layout.getLineRight(line))
        val lineRight = maxOf(layout.getLineLeft(line), layout.getLineRight(line))
        val lineWidth = lineRight - lineLeft
        if (lineWidth <= 0f) return
        val fade = REVEAL_FADE_DP * density
        val layer = canvas.saveLayer(lineLeft, top, lineRight, bottom, null)
        canvas.clipRect(lineLeft, top, lineRight, bottom)
        drawBlockText(canvas, item, index, block)
        // The gradient starts a full fade width before the line, so its first glyph is not faint.
        val edge = -fade + (lineWidth + fade) * (offsetPx / lineWidth).coerceIn(0f, 1f)
        maskMatrix.reset()
        if (layout.getParagraphDirection(line) >= 0) {
            maskMatrix.setScale(fade, 1f)
            maskMatrix.postTranslate(lineLeft + edge, 0f)
        } else {
            maskMatrix.setScale(-fade, 1f)
            maskMatrix.postTranslate(lineRight - edge, 0f)
        }
        maskShader.setLocalMatrix(maskMatrix)
        canvas.drawRect(lineLeft, top, lineRight, bottom, maskPaint)
        canvas.restoreToCount(layer)
    }

    /**
     * 代码块：自己的圆角底 + 顶部一条 header（左语言、右复制），正文不折行、横向滚动，
     * 不画滚动条，颜色圆角一律走本仓库的 token。
     */
    private fun drawCodeBlock(
        canvas: Canvas,
        item: PreparedChatMessage,
        block: PreparedContentBlock.Code,
        columnLeft: Float,
    ) {
        val left = columnLeft + item.horizontalPaddingPx
        val top = block.yOffsetPx.toFloat()
        // 代码块永远占满正文栏：两行短代码套一个半宽的盒子看着像出了 bug。
        val boxWidth = block.viewportWidthPx.toFloat()
        val bottom = top + block.heightPx
        val radius = CODE_CORNER_DP * density

        bubblePaint.color = when {
            item.message.role == ChatRole.USER -> color(R.color.bubble_code_user)
            // On the grey agent bubble the table colour barely shows; the page colour does.
            item.tailable -> color(R.color.token_bg_primary)
            else -> color(R.color.token_markdown_bg_table)
        }
        bubbleBounds.set(left, top, left + boxWidth, bottom)
        canvas.drawRoundRect(bubbleBounds, radius, radius, bubblePaint)

        val headerBottom = top + block.headerHeightPx
        rulePaint.color = color(R.color.token_markdown_border_table)
        canvas.drawRect(
            left,
            headerBottom - (1f * density).coerceAtLeast(1f),
            left + boxWidth,
            headerBottom,
            rulePaint,
        )

        block.languageLayout?.let { language ->
            canvas.save()
            canvas.translate(
                left + block.padPx,
                top + (block.headerHeightPx - language.height) / 2f,
            )
            language.draw(canvas)
            canvas.restore()
        }
        val copyRight = left + boxWidth - block.padPx
        canvas.save()
        canvas.translate(
            copyRight - block.copyLayout.width,
            top + (block.headerHeightPx - block.copyLayout.height) / 2f,
        )
        block.copyLayout.draw(canvas)
        canvas.restore()
        copyHits.add(
            RectF(left + boxWidth - block.copyHitWidthPx, top, left + boxWidth, headerBottom),
        )
        copyTexts.add(block.copyText)

        // 正文由这个块的 :scroll 容器画在 header 下面（ScrollableBlockSlot），滚动条不画——隐藏是有意的。
    }

    /** `---`：一条贴着正文栏的横线。 */
    private fun drawRuleBlock(
        canvas: Canvas,
        item: PreparedChatMessage,
        block: PreparedContentBlock.Rule,
        columnLeft: Float,
    ) {
        val left = columnLeft + item.horizontalPaddingPx + block.leftInsetPx
        rulePaint.color = color(R.color.token_markdown_border_table)
        canvas.drawRect(
            left,
            block.yOffsetPx.toFloat(),
            left + block.widthPx,
            (block.yOffsetPx + block.heightPx).toFloat(),
            rulePaint,
        )
    }

    private fun recordBlock(
        item: PreparedChatMessage,
        index: Int,
        block: PreparedContentBlock.Text,
    ): RenderNode {
        val node = RenderNode("message-${item.message.id}-$index")
        node.setPosition(0, 0, block.layout.width, block.layout.height)
        val recordingCanvas = node.beginRecording(block.layout.width, block.layout.height)
        block.layout.draw(recordingCanvas)
        node.endRecording()
        if (index < blockNodes.size) blockNodes[index] = node
        return node
    }

    private fun color(id: Int): Int = ContextCompat.getColor(context, id)

    private companion object {
        /** 首 token 的过渡时长：入 400ms、出 250ms，缓出无过冲。 */
        const val FADE_IN_MS = 400L
        const val FADE_OUT_MS = 250L

        /** How far the reveal's soft edge trails the caret. */
        const val REVEAL_FADE_DP = 50f

        /**
         * 代码块圆角（表格的在 [ScrollableBlockBody]），以及引用条宽度。数值对齐常见编辑器
         * （代码块 8px、表格 6px、引用条 4px），跟本仓库的卡片体系（24dp）不冲突——
         * 那是卡片的圆角，这些是正文里的块。
         */
        const val CODE_CORNER_DP = 8f
        const val QUOTE_BAR_DP = 4f

        /** The pop-in scale at which the bubble has become fully opaque. */
        const val TYPING_POP_OPAQUE_AT = 0.5f
        const val TYPING_SCALE_STEP = 0.002f

        /** Below a brief's title, taps still count as the title's. */
        const val BRIEF_TITLE_HIT_DP = 6f
        const val BRIEF_FADE_DP = 24f
        const val BRIEF_HEIGHT_STEP = 0.5f
        val BRIEF_HEIGHT = object : FloatPropertyCompat<ChatMessageCell>("briefHeight") {
            override fun getValue(cell: ChatMessageCell): Float = cell.briefHeight
            override fun setValue(cell: ChatMessageCell, value: Float) { cell.briefHeight = value }
        }
        val TYPING_SCALE = object : FloatPropertyCompat<ChatMessageCell>("typingScale") {
            override fun getValue(cell: ChatMessageCell): Float = cell.typingScale
            override fun setValue(cell: ChatMessageCell, value: Float) { cell.typingScale = value }
        }
    }
}
