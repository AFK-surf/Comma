package surf.comma.android.chat.live

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Resources
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.animation.LinearInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.chat.model.ChatAttachment
import surf.comma.android.media.MediaComponents
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.MediaImageBinding
import surf.comma.android.media.MediaSessionId
import surf.comma.android.media.SendImagePresentation
import surf.comma.android.media.SendImageView
import surf.comma.android.media.viewer.ChatMediaLink
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Native Android view mirroring Web `ChatPanelImageGroup`:
 * - 1 image: original aspect ratio rounded card (12dp radius, 0.5dp border, no fan allowance)
 * - 2-3 images: side-by-side 3:4 cards (8dp gap, no toggle pill)
 * - 4+ images: "N Images" / "Hide" pill + collapsed fan-stack deck with 32dp `<`/`>` chevrons,
 *   horizontal swipe-to-flip, 320ms throw-arc flight animation, and 240ms staggered FLIP expand/collapse.
 *
 * Supports both Agent (left-aligned) and User (right-aligned) via [alignEnd], uses only
 * `R.color.token_*` resources, and exposes deterministic animation stepping for 60fps capture.
 */
internal class MediaImageGroupView(context: Context) : ViewGroup(context), ChatMediaLink.GroupHost {
    var onCardClick: ((Int) -> Unit)? = null
    var onCardLongClick: ((Int, View) -> Unit)? = null
    var onExpandedChange: ((Boolean) -> Unit)? = null
    var onBrowseStateChange: ((MediaImageGroupBrowseState) -> Unit)? = null

    /** Optional synchronous drawable override for deterministic Robolectric/demo rendering. */
    var directDrawableProvider: ((ChatAttachment, Int) -> Drawable?)? = null

    /** Optional test override for [MediaComponents]; defaults to [MediaGraph.get]. */
    internal var mediaComponentsProvider: (() -> MediaComponents)? = null

    /** Whether [ValueAnimator] drives animations automatically; tests can disable and call [advanceAnimationTo]. */
    internal var useSystemAnimator: Boolean = true

    internal var alignEnd: Boolean = false
        private set

    internal var expanded: Boolean = false
        private set

    internal var browseState: MediaImageGroupBrowseState = MediaImageGroupBrowseState()
        private set

    internal var images: List<ChatAttachment> = emptyList()
        private set

    internal val isStackable: Boolean get() = MediaImageGroupGeometry.isStackable(images.size)
    internal val isExpandedEffective: Boolean get() = !isStackable || expanded

    /** Primary image presentation for single-image send flights. */
    internal val primaryFlightImage: SendImagePresentation?
        get() = cards.firstOrNull()?.imageView?.presentation

    private val density = resources.displayMetrics.density
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val cardRadiusPx = MediaImageGroupGeometry.CARD_RADIUS_DP * density
    private val borderWidthPx = (MediaImageGroupGeometry.BORDER_WIDTH_DP * density).coerceAtLeast(1f)
    private val gapPx = dp(MediaImageGroupGeometry.CARD_GAP_DP)
    private val fanHPx = dp(MediaImageGroupGeometry.FAN_ALLOWANCE_HORIZONTAL_DP)
    private val fanVPx = dp(MediaImageGroupGeometry.FAN_ALLOWANCE_VERTICAL_DP)
    private val toggleHeightPx = dp(MediaImageGroupGeometry.TOGGLE_PILL_HEIGHT_DP)
    private val toggleGapPx = dp(MediaImageGroupGeometry.TOGGLE_PILL_GAP_DP)
    private val advanceSizePx = dp(MediaImageGroupGeometry.ADVANCE_BUTTON_SIZE_DP)

    private val flipCurve = PathInterpolator(0.22f, 1f, 0.36f, 1f)
    private val drawerCurve = PathInterpolator(0.32f, 0.72f, 0f, 1f)
    private val softInOutCurve = PathInterpolator(0.4f, 0f, 0.2f, 1f)

    private val toggleButton = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.MINI, DesignFonts.medium)
        setTextColor(context.getColor(R.color.token_text_primary))
        gravity = Gravity.CENTER
        val padH = dp(12f)
        setPadding(padH, 0, padH, 0)
        background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = toggleHeightPx / 2f
            setColor(context.getColor(R.color.token_bg_quaternary))
        }
        setOnClickListener { toggleExpanded() }
    }

    private val cardsContainer = DeckContainer(context).apply {
        clipChildren = false
        clipToPadding = false
    }

    private val leftAdvance = buildAdvanceButton(isLeft = true) { rotate(1) }
    private val rightAdvance = buildAdvanceButton(isLeft = false) { rotate(-1) }

    private val cards = ArrayList<ImageGroupCardView>()
    private val bindings = HashMap<Int, MediaImageBinding>()
    private val requestedLoads = HashSet<Int>()
    private val failedIndices = HashSet<Int>()
    private var scope: CoroutineScope? = null
    private var mediaVisible = false
    private var sessionId: MediaSessionId? = null
    private var lastColumnWidthDp = 0f

    // Active flight animation state (deck rotation)
    private var activeFlight: ActiveFlight? = null
    private var flightAnimator: ValueAnimator? = null

    // Active FLIP animation state (expand / collapse)
    private var activeFlip: ActiveFlip? = null
    private var flipAnimator: ValueAnimator? = null
    private var animatedCardsHeightPx: Int? = null

    // Swipe gesture tracking on collapsed deck
    private var swipeDownX = 0f
    private var swipeDownY = 0f
    private var swipingDeck = false

    init {
        clipChildren = false
        clipToPadding = false
        addView(toggleButton)
        addView(cardsContainer)
        cardsContainer.addView(leftAdvance)
        cardsContainer.addView(rightAdvance)
        leftAdvance.zOrder = Z_ADVANCE
        rightAdvance.zOrder = Z_ADVANCE
        leftAdvance.translationZ = Z_ADVANCE * Z_ORDER_STEP_DP * density
        rightAdvance.translationZ = Z_ADVANCE * Z_ORDER_STEP_DP * density
    }

    fun bind(
        items: List<ChatAttachment>,
        alignEnd: Boolean,
        expanded: Boolean = this.expanded,
        browseState: MediaImageGroupBrowseState = this.browseState,
        session: MediaSessionId? = items.firstOrNull()?.session,
    ) {
        val listChanged = items != images || session != sessionId
        val stateChanged = this.alignEnd != alignEnd || this.expanded != expanded || this.browseState != browseState
        this.images = items
        this.alignEnd = alignEnd
        this.expanded = if (MediaImageGroupGeometry.isStackable(items.size)) expanded else false
        this.browseState = MediaImageGroupBrowseState(
            frontIndex = browseState.normalizedFront(items.size),
            leftCount = browseState.clampedLeftCount(items.size),
        )
        this.sessionId = session

        if (listChanged) {
            cancelAnimations()
            rebuildCards()
            if (isAttachedToWindow) startLoads()
        } else if (stateChanged) {
            cancelAnimations()
            applyRestPoses()
        }
        updateToggleChrome()
        updateAdvanceVisibility()
        requestLayout()
        invalidate()
    }

    fun setMediaVisible(visible: Boolean) {
        mediaVisible = visible
        bindings.values.forEach { it.setVisible(visible) }
    }

    fun releaseMedia() {
        cancelAnimations()
        clearBindings()
        scope?.cancel()
        scope = null
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        startLoads()
    }

    override fun onDetachedFromWindow() {
        releaseMedia()
        super.onDetachedFromWindow()
    }

    /** Rotates the collapsed fan deck by [step] (+1 pushes front to left pile; -1 returns from left pile). */
    fun rotate(step: Int, animated: Boolean = true) {
        if (!isStackable || isExpandedEffective || images.size <= 1) return
        require(step == 1 || step == -1)

        val count = images.size
        val outgoingIndex = browseState.normalizedFront(count)
        val previousPoses = captureCardPoses()

        cancelFlightOnly()
        val nextState = browseState.rotate(count, step)
        browseState = nextState
        onBrowseStateChange?.invoke(nextState)

        val shouldAnimate = animated && cards.getOrNull(outgoingIndex)?.width.orZero() > 0 &&
            (!useSystemAnimator || ValueAnimator.areAnimatorsEnabled())
        if (!shouldAnimate) {
            applyRestPoses()
            ensureVisibleLoads()
            return
        }

        val targetSlots = List(count) { idx -> nextState.slotFor(idx, count) }
        val flight = ActiveFlight(
            outgoingIndex = outgoingIndex,
            step = step,
            fromPoses = previousPoses,
            targetSlots = targetSlots,
            durationMs = MediaImageGroupGeometry.FLIGHT_DURATION_MS,
        )
        activeFlight = flight
        ensureVisibleLoads()
        applyFlightAt(0L)

        if (useSystemAnimator) {
            flightAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = flight.durationMs
                interpolator = LinearInterpolator()
                addUpdateListener { anim ->
                    applyFlightAt((anim.animatedFraction * flight.durationMs).toLong())
                }
                addListener(object : android.animation.AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: android.animation.Animator) {
                        if (activeFlight === flight) finishFlight()
                    }
                })
                start()
            }
        }
    }

    /** Toggles between collapsed fan deck and expanded wrapping grid with 240ms staggered FLIP. */
    fun toggleExpanded(animated: Boolean = true) {
        if (!isStackable) return
        val count = images.size
        val shouldAnimate = animated && cardsContainer.width > 0 && cardsContainer.height > 0 &&
            (!useSystemAnimator || ValueAnimator.areAnimatorsEnabled())

        val captured = if (shouldAnimate) captureFlipSnapshot() else null
        cancelAnimations()

        expanded = !expanded
        updateToggleChrome()
        updateAdvanceVisibility()
        onExpandedChange?.invoke(expanded)

        if (captured == null) {
            applyRestPoses()
            ensureVisibleLoads()
            requestLayout()
            return
        }

        val columnWidthDp = if (lastColumnWidthDp > 0f) lastColumnWidthDp else width / density
        val targetLayout = computeTargetLayout(columnWidthDp)
        val maxDelay = (0 until count).maxOfOrNull { idx ->
            val depth = captured.cards[idx]?.depth ?: 0
            MediaImageGroupGeometry.flipStaggerDelayMs(depth, expanding = expanded)
        } ?: 0L

        val flip = ActiveFlip(
            expanding = expanded,
            captured = captured,
            targetBoxes = targetLayout.cardBoxes,
            targetContainerHeightPx = targetLayout.containerHeightPx,
            targetContainerLeftPx = targetLayout.containerLeftPx,
            totalDurationMs = MediaImageGroupGeometry.FLIP_DURATION_MS + maxDelay,
        )
        activeFlip = flip
        ensureVisibleLoads()

        // Measure & lay out at target boxes immediately, then pin cards at captured visual poses.
        animatedCardsHeightPx = captured.containerHeightPx
        applyFlipAt(0L)
        requestLayout()

        if (useSystemAnimator) {
            flipAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = flip.totalDurationMs
                interpolator = LinearInterpolator()
                addUpdateListener { anim ->
                    applyFlipAt((anim.animatedFraction * flip.totalDurationMs).toLong())
                }
                addListener(object : android.animation.AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: android.animation.Animator) {
                        if (activeFlip === flip) finishFlip()
                    }
                })
                start()
            }
        }
    }

    /**
     * Deterministic clock hook for 60fps tests/video capture: advances whichever animation
     * (flight or FLIP) is currently active to [elapsedMs] since its start.
     */
    internal fun advanceAnimationTo(elapsedMs: Long) {
        val flight = activeFlight
        if (flight != null) {
            if (elapsedMs >= flight.durationMs) {
                finishFlight()
            } else {
                applyFlightAt(elapsedMs.coerceAtLeast(0L))
            }
            return
        }
        val flip = activeFlip
        if (flip != null) {
            if (elapsedMs >= flip.totalDurationMs) {
                finishFlip()
            } else {
                applyFlipAt(elapsedMs.coerceAtLeast(0L))
            }
        }
    }

    internal val isAnimating: Boolean get() = activeFlight != null || activeFlip != null
    internal val activeAnimationDurationMs: Long
        get() = activeFlight?.durationMs ?: activeFlip?.totalDurationMs ?: 0L

    internal fun cardViewAt(index: Int): View? = cards.getOrNull(index)
    internal fun toggleButtonView(): TextView = toggleButton
    internal fun leftAdvanceButton(): ImageButton = leftAdvance
    internal fun rightAdvanceButton(): ImageButton = rightAdvance

    fun isFailed(index: Int): Boolean = index in failedIndices

    fun hasLoadedImage(index: Int): Boolean = cards.getOrNull(index)?.imageView?.presentation?.target != null

    fun retryCard(index: Int) {
        if (index !in images.indices) return
        clearCardFailure(index)
        val existing = bindings[index]
        if (existing != null) {
            existing.retry()
        } else {
            ensureVisibleLoads()
        }
    }

    private fun showCardFailure(index: Int) {
        if (index !in cards.indices) return
        failedIndices.add(index)
        val name = images.getOrNull(index)?.file?.displayName.orEmpty()
        cards[index].showFailure(name)
    }

    private fun clearCardFailure(index: Int) {
        failedIndices.remove(index)
        cards.getOrNull(index)?.clearFailure()
    }

    // --- ChatMediaLink.GroupHost ---

    override fun alignToImage(imageIndex: Int): View? {
        if (imageIndex !in images.indices) return null
        val next = browseState.alignPreview(images.size, imageIndex)
        if (next != browseState) {
            cancelFlightOnly()
            browseState = next
            onBrowseStateChange?.invoke(next)
            applyRestPoses()
            ensureVisibleLoads()
        }
        return cards.getOrNull(imageIndex)
    }

    override fun cardView(imageIndex: Int): View? = cards.getOrNull(imageIndex)

    override fun picture(imageIndex: Int, resources: Resources): Drawable? =
        cards.getOrNull(imageIndex)?.imageView?.presentation?.target?.constantState?.newDrawable(resources)

    override fun cardCornerRadiusPx(): Float = cardRadiusPx

    // --- Measure & Layout ---

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val count = images.size
        val availableWidth = MeasureSpec.getSize(widthMeasureSpec).coerceAtLeast(1)
        val columnWidthDp = availableWidth / density
        lastColumnWidthDp = columnWidthDp

        if (count == 0) {
            setMeasuredDimension(availableWidth, 0)
            return
        }

        var totalHeight = 0
        if (isStackable) {
            toggleButton.visibility = View.VISIBLE
            val expandText = context.getString(R.string.media_image_group_expand, count)
            val hideText = context.getString(R.string.media_image_group_hide)
            val textWidth = max(toggleButton.paint.measureText(expandText), toggleButton.paint.measureText(hideText))
            val pillWidth = ceil(textWidth).toInt() + toggleButton.paddingLeft + toggleButton.paddingRight
            toggleButton.measure(
                MeasureSpec.makeMeasureSpec(pillWidth, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(toggleHeightPx, MeasureSpec.EXACTLY),
            )
            totalHeight += toggleHeightPx + toggleGapPx
        } else {
            toggleButton.visibility = View.GONE
        }

        val layout = computeTargetLayout(columnWidthDp)
        val containerHeight = animatedCardsHeightPx ?: layout.containerHeightPx
        cardsContainer.measure(
            MeasureSpec.makeMeasureSpec(layout.containerWidthPx, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(containerHeight, MeasureSpec.EXACTLY),
        )
        for (index in 0 until count) {
            val box = layout.cardBoxes[index]
            cards[index].measure(
                MeasureSpec.makeMeasureSpec(box.width().roundToInt().coerceAtLeast(1), MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(box.height().roundToInt().coerceAtLeast(1), MeasureSpec.EXACTLY),
            )
        }
        val advanceSpec = MeasureSpec.makeMeasureSpec(advanceSizePx, MeasureSpec.EXACTLY)
        leftAdvance.measure(advanceSpec, advanceSpec)
        rightAdvance.measure(advanceSpec, advanceSpec)

        totalHeight += containerHeight
        setMeasuredDimension(availableWidth, totalHeight)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val count = images.size
        if (count == 0) return
        val w = r - l
        val columnWidthDp = w / density
        lastColumnWidthDp = columnWidthDp

        var y = 0
        if (isStackable) {
            val pillLeft = if (alignEnd) w - toggleButton.measuredWidth else 0
            toggleButton.layout(pillLeft, 0, pillLeft + toggleButton.measuredWidth, toggleButton.measuredHeight)
            y += toggleButton.measuredHeight + toggleGapPx
        }

        val layout = computeTargetLayout(columnWidthDp)
        val containerHeight = animatedCardsHeightPx ?: layout.containerHeightPx
        val containerLeft = layout.containerLeftPx
        cardsContainer.layout(
            containerLeft,
            y,
            containerLeft + layout.containerWidthPx,
            y + containerHeight,
        )

        for (index in 0 until count) {
            val box = layout.cardBoxes[index]
            cards[index].layout(
                box.left.roundToInt(),
                box.top.roundToInt(),
                box.right.roundToInt(),
                box.bottom.roundToInt(),
            )
        }

        // Advance chevrons straddle the collapsed front card's left and right edges at vertical center.
        val cardW = dp(MediaImageGroupGeometry.CARD_WIDTH_DP)
        val cardH = dp(MediaImageGroupGeometry.CARD_HEIGHT_DP)
        val halfBtn = advanceSizePx / 2
        val btnTop = fanVPx + cardH / 2 - halfBtn
        val leftCenter = fanHPx
        val rightCenter = fanHPx + cardW
        leftAdvance.layout(leftCenter - halfBtn, btnTop, leftCenter + halfBtn, btnTop + advanceSizePx)
        rightAdvance.layout(rightCenter - halfBtn, btnTop, rightCenter + halfBtn, btnTop + advanceSizePx)

        if (activeFlight == null && activeFlip == null) {
            applyRestPoses()
        }
    }

    // --- Touch / Swipe on Collapsed Deck ---

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        if (!isStackable || isExpandedEffective) return false
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                swipeDownX = ev.x
                swipeDownY = ev.y
                swipingDeck = false
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = ev.x - swipeDownX
                val dy = ev.y - swipeDownY
                if (!swipingDeck && abs(dx) > touchSlop && abs(dx) > abs(dy)) {
                    swipingDeck = true
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                swipingDeck = false
            }
        }
        return false
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isStackable || isExpandedEffective) return super.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                swipeDownX = event.x
                swipeDownY = event.y
                swipingDeck = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - swipeDownX
                val dy = event.y - swipeDownY
                if (!swipingDeck && abs(dx) > touchSlop && abs(dx) > abs(dy)) {
                    swipingDeck = true
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                val dx = event.x - swipeDownX
                val threshold = dp(24f)
                if (swipingDeck && abs(dx) >= threshold) {
                    rotate(if (dx < 0f) 1 else -1)
                }
                swipingDeck = false
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                swipingDeck = false
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    // --- Internals ---

    private fun buildAdvanceButton(isLeft: Boolean, onClick: () -> Unit): AdvanceButtonView =
        AdvanceButtonView(context).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            if (isLeft) rotation = 180f
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            val pad = dp(6f)
            setPadding(pad, pad, pad, pad)
            imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_secondary))
            contentDescription = context.getString(
                if (isLeft) R.string.media_image_group_next else R.string.media_image_group_previous,
            )
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(context.getColor(R.color.token_card_primary))
                setStroke(borderWidthPx.roundToInt().coerceAtLeast(1), context.getColor(R.color.token_border_primary))
            }
            elevation = CARD_ELEVATION_DP * density
            setOnClickListener { onClick() }
        }

    private fun rebuildCards() {
        clearBindings()
        cards.forEach { cardsContainer.removeView(it) }
        cards.clear()

        for (index in images.indices) {
            val card = ImageGroupCardView(context, cardRadiusPx, borderWidthPx).apply {
                contentDescription = images[index].file.displayName
                setOnClickListener {
                    if (isExpandedEffective || browseState.normalizedFront(images.size) == index) {
                        onCardClick?.invoke(index)
                    }
                }
                setOnLongClickListener {
                    if (isExpandedEffective || browseState.normalizedFront(images.size) == index) {
                        onCardLongClick?.invoke(index, this)
                        true
                    } else false
                }
            }
            cards += card
            cardsContainer.addView(card)
        }
        // Keep advance buttons at end of child list too.
        leftAdvance.bringToFront()
        rightAdvance.bringToFront()
        applyRestPoses()
    }

    private fun startLoads() {
        clearBindings()
        scope?.cancel()
        scope = null
        if (images.isEmpty()) return

        val provider = directDrawableProvider
        if (provider != null) {
            images.forEachIndexed { index, attachment ->
                val drawable = provider(attachment, index)
                if (drawable != null) cards[index].imageView.setImageDrawable(drawable)
            }
            return
        }

        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { scope = it }
        ensureVisibleLoads(owner)
    }

    private fun ensureVisibleLoads(owner: CoroutineScope? = scope) {
        val provider = directDrawableProvider
        if (provider != null) {
            images.forEachIndexed { index, attachment ->
                if (cards[index].imageView.presentation.target == null) {
                    provider(attachment, index)?.let { cards[index].imageView.setImageDrawable(it) }
                }
            }
            return
        }
        val activeScope = owner ?: return
        val count = images.size
        val media = mediaComponentsProvider?.invoke() ?: MediaGraph.get(context)
        val widthPx = if (count == 1) {
            val colDp = if (lastColumnWidthDp > 0f) lastColumnWidthDp else 334f
            dp(MediaImageGroupGeometry.singleImageSizeDp(colDp, images[0].dimensions?.width, images[0].dimensions?.height).widthDp)
        } else {
            dp(MediaImageGroupGeometry.CARD_WIDTH_DP)
        }

        for (index in 0 until count) {
            if (bindings.containsKey(index) || index in requestedLoads) continue
            if (!shouldPreloadCard(index, count)) continue
            val attachment = images[index]
            val viewerImage = attachment.image() ?: continue
            val card = cards[index]
            val ratio = if (count == 1) {
                attachment.dimensions?.ratio ?: MediaImageGroupGeometry.DEFAULT_SINGLE_ASPECT_RATIO.toDouble()
            } else {
                MediaImageGroupGeometry.CARD_ASPECT_RATIO.toDouble()
            }
            requestedLoads.add(index)
            activeScope.launch {
                val loader = media.images()
                if (sessionId != null) {
                    val current = media.http.session.value
                    if (current == null || current.id != sessionId || !media.http.isCurrent(current)) {
                        requestedLoads.remove(index)
                        return@launch
                    }
                }
                try {
                    val binding = loader.bind(
                        view = card.imageView,
                        image = viewerImage,
                        widthPx = widthPx,
                        visible = mediaVisible,
                        fallbackRatio = ratio,
                        onLoaded = { clearCardFailure(index) },
                        onError = { showCardFailure(index) },
                    )
                    bindings[index] = binding
                } catch (cancelled: CancellationException) {
                    requestedLoads.remove(index)
                    throw cancelled
                } catch (_: Exception) {
                    requestedLoads.remove(index)
                    showCardFailure(index)
                }
            }
        }
    }

    /**
     * Preloads every card for small collapsed stacks (<= [PRELOAD_ALL_STACK_LIMIT]) and the visible fan
     * plus immediate next swipe neighbors for larger stacks, so flipping or closing never flashes blank grey.
     */
    private fun shouldPreloadCard(index: Int, count: Int): Boolean {
        if (isExpandedEffective || activeFlip != null || count <= PRELOAD_ALL_STACK_LIMIT) return true
        val slot = browseState.slotFor(index, count)
        if (slot.paintsImage) return true
        val front = browseState.normalizedFront(count)
        val distance = (((index - front) % count) + count) % count
        return distance == 1 || distance == count - 1
    }

    private fun clearBindings() {
        requestedLoads.clear()
        failedIndices.clear()
        bindings.values.forEach { it.close() }
        bindings.clear()
    }

    private fun updateToggleChrome() {
        if (!isStackable) return
        toggleButton.text = if (expanded) {
            context.getString(R.string.media_image_group_hide)
        } else {
            context.getString(R.string.media_image_group_expand, images.size)
        }
    }

    private fun updateAdvanceVisibility() {
        val show = isStackable && !isExpandedEffective
        leftAdvance.visibility = if (show) View.VISIBLE else View.GONE
        rightAdvance.visibility = if (show) View.VISIBLE else View.GONE
    }

    private fun applyRestPoses() {
        val count = images.size
        for (index in 0 until count) {
            val card = cards[index]
            if (isExpandedEffective) {
                card.translationX = 0f
                card.translationY = 0f
                card.rotation = 0f
                card.scaleX = 1f
                card.scaleY = 1f
                card.alpha = 1f
                card.dimAlpha = 0f
                applyCardDepthZ(card, zOrder = 1, baseElevationPx = 0f, addZStep = false)
                card.isClickable = true
                card.isEnabled = true
                card.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_AUTO
            } else {
                val slot = browseState.slotFor(index, count)
                card.translationX = slot.translationXDp * density
                card.translationY = 0f
                card.rotation = slot.rotationDeg
                card.scaleX = slot.scale
                card.scaleY = slot.scale
                card.alpha = slot.alpha
                card.dimAlpha = slot.dimAlpha
                applyCardDepthZ(
                    card,
                    zOrder = slot.zIndex,
                    baseElevationPx = if (slot.zIndex > 0) CARD_ELEVATION_DP * density else 0f,
                )
                val front = slot == ImageGroupStackSlot.FRONT
                card.isClickable = front
                card.isEnabled = front
                card.importantForAccessibility = if (front) IMPORTANT_FOR_ACCESSIBILITY_YES else IMPORTANT_FOR_ACCESSIBILITY_NO
            }
        }
        cardsContainer.invalidate()
    }

    private fun captureCardPoses(): List<CardPose> = cards.map { card ->
        CardPose(
            tx = card.translationX,
            ty = card.translationY,
            rotation = card.rotation,
            scale = card.scaleX,
            alpha = card.alpha,
            dimAlpha = card.dimAlpha,
            zOrder = card.zOrder,
        )
    }

    private fun applyFlightAt(elapsedMs: Long) {
        val flight = activeFlight ?: return
        val count = images.size
        val tFlight = (elapsedMs.toFloat() / flight.durationMs.toFloat()).coerceIn(0f, 1f)
        val tSettle = flipCurve.getInterpolation(
            (elapsedMs.toFloat() / MediaImageGroupGeometry.SLOT_SETTLE_DURATION_MS.toFloat()).coerceIn(0f, 1f),
        )

        for (index in 0 until count) {
            val card = cards[index]
            val from = flight.fromPoses[index]
            val toSlot = flight.targetSlots[index]
            if (index == flight.outgoingIndex) {
                val cardW = card.width.takeIf { it > 0 }?.toFloat() ?: (MediaImageGroupGeometry.CARD_WIDTH_DP * density)
                val pose = MediaImageGroupGeometry.flightPose(
                    t = tFlight,
                    step = flight.step,
                    cardWidthPx = cardW,
                    fromX = from.tx,
                    fromRotation = from.rotation,
                    fromScale = from.scale,
                    fromAlpha = from.alpha,
                    toSlot = toSlot,
                    density = density,
                    drawer = drawerCurve::getInterpolation,
                    softInOut = softInOutCurve::getInterpolation,
                )
                card.translationX = pose.translationXPx
                card.translationY = 0f
                card.rotation = pose.rotationDeg
                card.scaleX = pose.scale
                card.scaleY = pose.scale
                card.alpha = pose.alpha
                card.dimAlpha = pose.dimAlpha
                applyCardDepthZ(
                    card,
                    zOrder = pose.zIndex,
                    baseElevationPx = if (pose.zIndex > 0) CARD_ELEVATION_DP * density else 0f,
                )
            } else if (toSlot == ImageGroupStackSlot.FRONT && from.alpha <= 0.01f) {
                // Wrapping a hidden back card straight to FRONT: keep it opaque and tucked behind
                // the outgoing card at t=0 so lower cards never bleed through while outgoing flies off.
                card.translationX = 0f
                card.translationY = 0f
                card.rotation = 0f
                val s = lerp(ImageGroupStackSlot.R1.scale, toSlot.scale, tSettle)
                card.scaleX = s
                card.scaleY = s
                card.alpha = 1f
                card.dimAlpha = lerp(ImageGroupStackSlot.R1.dimAlpha, toSlot.dimAlpha, tSettle)
                applyCardDepthZ(card, zOrder = toSlot.zIndex, baseElevationPx = CARD_ELEVATION_DP * density)
            } else {
                card.translationX = lerp(from.tx, toSlot.translationXDp * density, tSettle)
                card.translationY = 0f
                card.rotation = lerp(from.rotation, toSlot.rotationDeg, tSettle)
                val s = lerp(from.scale, toSlot.scale, tSettle)
                card.scaleX = s
                card.scaleY = s
                card.alpha = lerp(from.alpha, toSlot.alpha, tSettle)
                card.dimAlpha = lerp(from.dimAlpha, toSlot.dimAlpha, tSettle)
                applyCardDepthZ(
                    card,
                    zOrder = toSlot.zIndex,
                    baseElevationPx = if (toSlot.zIndex > 0) CARD_ELEVATION_DP * density else 0f,
                )
            }
        }
        cardsContainer.invalidate()
    }

    private fun finishFlight() {
        flightAnimator?.cancel()
        flightAnimator = null
        activeFlight = null
        applyRestPoses()
    }

    private fun cancelFlightOnly() {
        flightAnimator?.cancel()
        flightAnimator = null
        activeFlight = null
    }

    private fun captureFlipSnapshot(): FlipSnapshot {
        val count = images.size
        val map = HashMap<Int, CapturedFlipCard>(count)
        for (index in 0 until count) {
            val card = cards[index]
            val slot = browseState.slotFor(index, count)
            map[index] = CapturedFlipCard(
                box = RectF(card.left.toFloat(), card.top.toFloat(), card.right.toFloat(), card.bottom.toFloat()),
                depth = slot.depth,
                tx = card.translationX,
                ty = card.translationY,
                rotation = card.rotation,
                scale = card.scaleX,
                alpha = card.alpha,
                dimAlpha = card.dimAlpha,
            )
        }
        return FlipSnapshot(
            cards = map,
            containerLeftPx = cardsContainer.left,
            containerHeightPx = cardsContainer.height,
        )
    }

    private fun applyFlipAt(elapsedMs: Long) {
        val flip = activeFlip ?: return
        val count = images.size
        val heightT = flipCurve.getInterpolation(
            (elapsedMs.toFloat() / MediaImageGroupGeometry.FLIP_DURATION_MS.toFloat()).coerceIn(0f, 1f),
        )
        val nextHeight = lerp(
            flip.captured.containerHeightPx.toFloat(),
            flip.targetContainerHeightPx.toFloat(),
            heightT,
        ).roundToInt()
        if (animatedCardsHeightPx != nextHeight) {
            animatedCardsHeightPx = nextHeight
            requestLayout()
        }

        val containerDx = (flip.captured.containerLeftPx - flip.targetContainerLeftPx).toFloat()
        val flipElevationPx = (if (flip.expanding) 1f - heightT else heightT) * CARD_ELEVATION_DP * density

        for (index in 0 until count) {
            val card = cards[index]
            val captured = flip.captured.cards[index] ?: continue
            val targetBox = flip.targetBoxes[index]
            if (targetBox.width() <= 0f) continue

            val startScale = (captured.scale * captured.box.width()) / targetBox.width()
            val startDx = (captured.box.centerX() + captured.tx + containerDx) - targetBox.centerX()
            val startDy = (captured.box.centerY() + captured.ty) - targetBox.centerY()

            val targetSlot = if (flip.expanding) null else browseState.slotFor(index, count)
            val endDx = targetSlot?.let { it.translationXDp * density } ?: 0f
            val endDy = 0f
            val endRot = targetSlot?.rotationDeg ?: 0f
            val endScale = targetSlot?.scale ?: 1f
            val endAlpha = targetSlot?.alpha ?: 1f
            val endDim = targetSlot?.dimAlpha ?: 0f

            val delayMs = MediaImageGroupGeometry.flipStaggerDelayMs(captured.depth, flip.expanding)
            val localP = flipCurve.getInterpolation(
                ((elapsedMs - delayMs).toFloat() / MediaImageGroupGeometry.FLIP_DURATION_MS.toFloat()).coerceIn(0f, 1f),
            )

            card.translationX = lerp(startDx, endDx, localP)
            card.translationY = lerp(startDy, endDy, localP)
            card.rotation = lerp(captured.rotation, endRot, localP)
            val s = lerp(startScale, endScale, localP)
            card.scaleX = s
            card.scaleY = s
            card.alpha = lerp(captured.alpha, endAlpha, localP)
            card.dimAlpha = lerp(captured.dimAlpha, endDim, localP)
            applyCardDepthZ(card, zOrder = 10 + captured.depth, baseElevationPx = flipElevationPx)
        }
        cardsContainer.invalidate()
    }

    private fun finishFlip() {
        flipAnimator?.cancel()
        flipAnimator = null
        activeFlip = null
        animatedCardsHeightPx = null
        applyRestPoses()
        requestLayout()
    }

    private fun cancelAnimations() {
        cancelFlightOnly()
        flipAnimator?.cancel()
        flipAnimator = null
        activeFlip = null
        animatedCardsHeightPx = null
    }

    private fun computeTargetLayout(columnWidthDp: Float): TargetLayout {
        val count = images.size
        val colPx = (columnWidthDp * density).roundToInt().coerceAtLeast(1)
        if (count == 0) return TargetLayout(0, 0, 0, emptyList())

        if (count == 1) {
            val size = MediaImageGroupGeometry.singleImageSizeDp(
                columnWidthDp,
                images[0].dimensions?.width,
                images[0].dimensions?.height,
            )
            val w = dp(size.widthDp).coerceAtMost(colPx)
            val h = dp(size.heightDp)
            val left = if (alignEnd) colPx - w else 0
            return TargetLayout(
                containerLeftPx = left,
                containerWidthPx = w,
                containerHeightPx = h,
                cardBoxes = listOf(RectF(0f, 0f, w.toFloat(), h.toFloat())),
            )
        }

        if (isStackable && !expanded) {
            val deck = MediaImageGroupGeometry.collapsedDeckSizeDp()
            val deckW = dp(deck.widthDp)
            val deckH = dp(deck.heightDp)
            val cardW = dp(MediaImageGroupGeometry.CARD_WIDTH_DP)
            val cardH = dp(MediaImageGroupGeometry.CARD_HEIGHT_DP)
            val box = RectF(
                fanHPx.toFloat(),
                fanVPx.toFloat(),
                (fanHPx + cardW).toFloat(),
                (fanVPx + cardH).toFloat(),
            )
            val left = if (alignEnd) (colPx - deckW).coerceAtLeast(0) else 0
            return TargetLayout(
                containerLeftPx = left,
                containerWidthPx = deckW,
                containerHeightPx = deckH,
                cardBoxes = List(count) { RectF(box) },
            )
        }

        // Expanded wrapping grid (2-3 images, or 4+ expanded).
        val cardWDp = MediaImageGroupGeometry.expandedCardWidthDp(columnWidthDp, count)
        val cardHDp = MediaImageGroupGeometry.expandedCardHeightDp(cardWDp)
        val cardW = dp(cardWDp)
        val cardH = dp(cardHDp)
        val cols = MediaImageGroupGeometry.expandedColumnCount(columnWidthDp, count)
        val rows = ceil(count.toFloat() / cols.toFloat()).toInt().coerceAtLeast(1)
        val gridW = cols * cardW + (cols - 1) * gapPx
        val gridH = rows * cardH + (rows - 1) * gapPx
        val containerLeft = if (alignEnd) (colPx - gridW).coerceAtLeast(0) else 0

        val boxes = ArrayList<RectF>(count)
        for (index in 0 until count) {
            val row = index / cols
            val colInRow = index % cols
            val itemsInThisRow = if (row == rows - 1) {
                val rem = count % cols
                if (rem == 0) cols else rem
            } else cols
            val rowWidth = itemsInThisRow * cardW + (itemsInThisRow - 1) * gapPx
            val rowStartX = if (alignEnd) gridW - rowWidth else 0
            val x = rowStartX + colInRow * (cardW + gapPx)
            val y = row * (cardH + gapPx)
            boxes += RectF(x.toFloat(), y.toFloat(), (x + cardW).toFloat(), (y + cardH).toFloat())
        }
        return TargetLayout(
            containerLeftPx = containerLeft,
            containerWidthPx = gridW,
            containerHeightPx = gridH,
            cardBoxes = boxes,
        )
    }

    /**
     * Keeps hardware Z (`elevation + translationZ`) strictly monotonic with [zOrder] so HWUI's
     * Z-sorted RenderNode pass never lets a lower card with stale elevation paint over a newly
     * promoted front card during deck flights or expand/collapse FLIP transitions.
     */
    private fun applyCardDepthZ(
        card: ImageGroupCardView,
        zOrder: Int,
        baseElevationPx: Float,
        addZStep: Boolean = zOrder > 0,
    ) {
        card.zOrder = zOrder
        card.elevation = baseElevationPx
        card.translationZ = if (addZStep) zOrder * Z_ORDER_STEP_DP * density else 0f
    }

    private fun dp(value: Float): Int = (value * density).roundToInt()

    private fun Int?.orZero(): Int = this ?: 0

    private fun lerp(start: Float, end: Float, t: Float): Float = start + (end - start) * t

    private data class CardPose(
        val tx: Float,
        val ty: Float,
        val rotation: Float,
        val scale: Float,
        val alpha: Float,
        val dimAlpha: Float,
        val zOrder: Int,
    )

    private data class ActiveFlight(
        val outgoingIndex: Int,
        val step: Int,
        val fromPoses: List<CardPose>,
        val targetSlots: List<ImageGroupStackSlot>,
        val durationMs: Long,
    )

    private data class CapturedFlipCard(
        val box: RectF,
        val depth: Int,
        val tx: Float,
        val ty: Float,
        val rotation: Float,
        val scale: Float,
        val alpha: Float,
        val dimAlpha: Float,
    )

    private data class FlipSnapshot(
        val cards: Map<Int, CapturedFlipCard>,
        val containerLeftPx: Int,
        val containerHeightPx: Int,
    )

    private data class ActiveFlip(
        val expanding: Boolean,
        val captured: FlipSnapshot,
        val targetBoxes: List<RectF>,
        val targetContainerHeightPx: Int,
        val targetContainerLeftPx: Int,
        val totalDurationMs: Long,
    )

    private data class TargetLayout(
        val containerLeftPx: Int,
        val containerWidthPx: Int,
        val containerHeightPx: Int,
        val cardBoxes: List<RectF>,
    )

    private interface ZOrderedChild {
        var zOrder: Int
    }

    @SuppressLint("AppCompatCustomView")
    private class AdvanceButtonView(context: Context) : ImageButton(context), ZOrderedChild {
        override var zOrder: Int = Z_ADVANCE
    }

    /**
     * Container that paints children sorted by [ZOrderedChild.zOrder] so z-ordering
     * is identical in both hardware rendering and software Robolectric canvas captures.
     */
    private class DeckContainer(context: Context) : ViewGroup(context) {
        private var drawOrder = IntArray(0)

        init {
            isChildrenDrawingOrderEnabled = true
            clipChildren = false
            clipToPadding = false
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) = Unit

        override fun dispatchDraw(canvas: Canvas) {
            val n = childCount
            if (drawOrder.size != n) drawOrder = IntArray(n)
            for (i in 0 until n) drawOrder[i] = i
            // Insertion sort preserves relative order for equal zOrder (e.g. card indices).
            for (i in 1 until n) {
                val keyIdx = drawOrder[i]
                val keyZ = (getChildAt(keyIdx) as? ZOrderedChild)?.zOrder ?: 0
                var j = i - 1
                while (j >= 0) {
                    val cmpZ = (getChildAt(drawOrder[j]) as? ZOrderedChild)?.zOrder ?: 0
                    if (cmpZ <= keyZ) break
                    drawOrder[j + 1] = drawOrder[j]
                    j--
                }
                drawOrder[j + 1] = keyIdx
            }
            super.dispatchDraw(canvas)
        }

        override fun getChildDrawingOrder(childCount: Int, drawingPosition: Int): Int =
            if (drawingPosition in drawOrder.indices) drawOrder[drawingPosition] else drawingPosition
    }

    /** One image card with 12dp clip, 0.5dp `token_border_primary` hairline, and depth dim overlay. */
    private class ImageGroupCardView(
        context: Context,
        private val radiusPx: Float,
        private val borderPx: Float,
    ) : FrameLayout(context), ZOrderedChild {
        override var zOrder: Int = 0
        var dimAlpha: Float = 0f
            set(value) {
                if (field != value) {
                    field = value
                    invalidate()
                }
            }

        val imageView = SendImageView(context, radiusPx).apply {
            contentDescription = null
        }

        private val bgColor = context.getColor(R.color.token_bg_quaternary)
        private val borderColor = context.getColor(R.color.token_border_primary)
        private val overlayColor = context.getColor(R.color.token_bg_overlay)

        private val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
            color = bgColor
        }
        private val dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            color = borderColor
            strokeWidth = borderPx
        }
        private val rect = RectF()
        private var failurePanel: LinearLayout? = null
        private var failureLabel: TextView? = null

        init {
            setWillNotDraw(false)
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, radiusPx)
                }
            }
            clipToOutline = true
            addView(imageView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        }

        fun showFailure(fileName: String) {
            val density = resources.displayMetrics.density
            val panel = failurePanel ?: LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                val pad = (8 * density).toInt()
                setPadding(pad, pad, pad, pad)
                background = GradientDrawable().apply {
                    setColor(context.getColor(R.color.token_bg_secondary))
                    setStroke(density.toInt().coerceAtLeast(1), context.getColor(R.color.token_border_primary))
                    cornerRadius = radiusPx
                }
                addView(
                    ImageView(context).apply {
                        setImageResource(R.drawable.ic_media_file_image)
                        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_secondary))
                    },
                    LinearLayout.LayoutParams((20 * density).toInt(), (20 * density).toInt()),
                )
                val label = TextView(context).apply {
                    DesignTypography.applyTo(this, DesignTypography.Level.MINI)
                    setTextColor(context.getColor(R.color.token_text_secondary))
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                    gravity = Gravity.CENTER
                }.also { failureLabel = it }
                addView(
                    label,
                    LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                        topMargin = (6 * density).toInt()
                    },
                )
                isClickable = false
                failurePanel = this
                this@ImageGroupCardView.addView(this, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            }
            failureLabel?.text = fileName.ifBlank { context.getString(R.string.media_tile_unavailable) }
            panel.visibility = View.VISIBLE
            stateDescription = context.getString(R.string.media_tile_unavailable)
        }

        fun clearFailure() {
            failurePanel?.visibility = View.GONE
            stateDescription = null
        }

        override fun onDraw(canvas: Canvas) {
            rect.set(0f, 0f, width.toFloat(), height.toFloat())
            canvas.drawRoundRect(rect, radiusPx, radiusPx, bgPaint)
            super.onDraw(canvas)
        }

        override fun dispatchDraw(canvas: Canvas) {
            super.dispatchDraw(canvas)
            if (dimAlpha > 0f) {
                dimPaint.color = ColorUtils.setAlphaComponent(
                    overlayColor,
                    (dimAlpha.coerceIn(0f, 1f) * 255f).roundToInt(),
                )
                rect.set(0f, 0f, width.toFloat(), height.toFloat())
                canvas.drawRoundRect(rect, radiusPx, radiusPx, dimPaint)
            }
            val inset = borderPx / 2f
            rect.set(inset, inset, width - inset, height - inset)
            canvas.drawRoundRect(rect, radiusPx - inset, radiusPx - inset, borderPaint)
        }
    }

    private companion object {
        const val Z_ADVANCE = 20
        const val CARD_ELEVATION_DP = 2f
        const val Z_ORDER_STEP_DP = 0.01f
        const val PRELOAD_ALL_STACK_LIMIT = 6
    }
}
