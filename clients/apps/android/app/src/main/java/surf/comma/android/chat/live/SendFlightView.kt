package surf.comma.android.chat.live

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffColorFilter
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.RenderNode
import android.text.Layout
import android.view.View
import android.view.animation.AnimationUtils
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.core.graphics.ColorUtils
import surf.comma.android.media.SendImagePresentation
import surf.comma.android.media.ImageCrop
import surf.comma.android.R
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.FlightTarget
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.ui.composer.ComposerSendSnapshot
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import kotlin.math.abs
import kotlin.math.max

/**
 * The send transition: what the user just sent flies from the composer into its rows.
 *
 * One send is one [Transition], matched to its rows by the turn key of its request, so a message
 * from elsewhere is never mistaken for it and a second send does not cut the first one short:
 *
 * 1. [hold] freezes the draft (the source) while the composer still shows it.
 * 2. The rows may be committed before the send returns; they are hidden at once.
 * 3. [accept]: the composer has cleared; the frozen copy now stands in for it.
 * 4. Accepted and committed: the timeline has already laid the rows out at rest and glides the
 *    list there (see [ChatTimelineView.glideOffsetPx]); once the targets are laid out each piece
 *    starts from its source.
 * 5. Every piece has settled and crossfaded: the rows show, the copy goes.
 *
 * A piece is drawn at its target plus an offset; the offset is four springs (one per edge) going
 * to zero. The list carries the piece, so a scroll, a keyboard or the glide moves it with its
 * row, and a target that changes size is absorbed into the offset with the velocity kept.
 * Opacity (the bubble colour, the crossfade to the row's own pixels) runs on durations.
 *
 * The text leads. A piece that lands below another (an image under its text, the next image
 * under the previous one) leaves only once the one above has passed its source, and is masked so
 * it never reaches above it: a tall image unfolds under the text instead of sweeping across it.
 */
internal class SendFlightView(context: Context, private val timeline: ChatTimelineView) : View(context) {
    private inner class Piece(
        val spec: FlightPiece,
        val from: FlightBox,
        val padH: Float,
        val padV: Float,
        val surfaceAlpha: Float,
        val sourceBitmap: Bitmap?,
        val fromBubble: Boolean = false,
    ) {
        var target: View? = null
        var image: SendImagePresentation? = null
        /** The landing rectangle in the target's coordinates. */
        val bounds = RectF()
        private var boundsWidth = -1f
        private var boundsHeight = -1f
        /** Where the landing rectangle is on screen this frame, glide included. */
        var to: FlightBox = from
        /**
         * The target's speed per edge in px/s: the glide's own, exactly, plus the layout's (the
         * composer, the keyboard) from the last two steps.
         */
        val targetVelocity = FloatArray(4)
        private val layoutVelocity = FloatArray(4)
        private var steppedRest: FlightBox? = null
        private var steppedAt = 0L
        /** Drawn position minus [to], per edge: left, top, right, bottom. */
        val offset = FloatArray(4)
        private var startMagnitude = 0f
        val springs = Array(4) { DesignSpring(this, EDGES[it], DesignMotion.springFlight, minimumVisibleChange = 0.5f) }
        var launchedAt = -1L
        val launched: Boolean get() = launchedAt >= 0
        /**
         * Launched, but the springs have not taken a step yet. The layout of this frame may still
         * move the target (the composer shrinking, say); until then the piece stays on its source.
         */
        private var onSource = false
        private var springFrames = 0

        init {
            // A spring's first frame only notes the time; it moves from the second one.
            springs[0].animation.addUpdateListener { _, _, _ -> if (++springFrames > 1) onSource = false }
        }
        /** Nothing above this line (window px) while flying; see the class comment. */
        var maskTop = Float.NEGATIVE_INFINITY
        val node = RenderNode("send-flight-target")
        val viewportClip = SendFlightClip()
        /** When the piece first left its source aperture, or -1. */
        var departedAt = -1L

        fun frame(): FlightBox = if (!launched) from else SendFlightGeometry.drawn(to, offset)

        /** Reads the target where it is drawn now. False when it is gone or no longer this row's. */
        fun resolve(): Boolean {
            val view = findTarget(spec.targetRowId)?.takeIf { it.isAttachedToWindow && it.isLaidOut && it is FlightTarget }
                ?: return false
            if (!(view as FlightTarget).flightBounds(bounds)) return false
            target = view
            if (!spec.isText) {
                val nextImage = (view as? AttachmentView)?.flightImage
                if (image !== nextImage) image?.land()
                image = nextImage
                nextImage?.hold(sourceBitmap)
            }
            // Where the row is drawn, glide (its translation) included, without rounding to pixels.
            timeline.getLocationInWindow(targetWindow)
            val x = targetWindow[0] + view.left + view.translationX
            val y = targetWindow[1] + view.top + view.translationY
            val next = FlightBox(x + bounds.left, y + bounds.top, x + bounds.right, y + bounds.bottom)
            // The row itself changed shape (a note appeared, a size was corrected): keep what is
            // drawn where it is and let the springs, with their velocity, take up the change.
            if (launched && boundsWidth >= 0f && (abs(bounds.width() - boundsWidth) > 0.5f ||
                    abs(bounds.height() - boundsHeight) > 0.5f)) {
                springs[0].shiftBy(to.left - next.left)
                springs[1].shiftBy(to.top - next.top)
                springs[2].shiftBy(to.right - next.right)
                springs[3].shiftBy(to.bottom - next.bottom)
            }
            boundsWidth = bounds.width()
            boundsHeight = bounds.height()
            to = next
            if (onSource) {
                updateTargetVelocity()
                springs[0].shiftBy(from.left - to.left - offset[0])
                springs[1].shiftBy(from.top - to.top - offset[1])
                springs[2].shiftBy(from.right - to.right - offset[2])
                springs[3].shiftBy(from.bottom - to.bottom - offset[3])
                // Leave the source at rest: move against the target exactly as fast as it moves.
                if (!stallSprings) springs.forEachIndexed { edge, spring -> spring.animateTo(0f, -targetVelocity[edge]) }
            }
            return true
        }

        /** Once per step, after [resolve]: how fast the layout (not the glide) moves the target. */
        fun track(now: Long) {
            val glide = timeline.glideOffsetPx
            val rest = FlightBox(to.left, to.top - glide, to.right, to.bottom - glide)
            val previous = steppedRest
            val elapsed = now - steppedAt
            if (previous != null && elapsed > 0) {
                val perSecond = 1000f / elapsed
                layoutVelocity[0] = (rest.left - previous.left) * perSecond
                layoutVelocity[1] = (rest.top - previous.top) * perSecond
                layoutVelocity[2] = (rest.right - previous.right) * perSecond
                layoutVelocity[3] = (rest.bottom - previous.bottom) * perSecond
            }
            steppedRest = rest
            steppedAt = now
        }

        private fun updateTargetVelocity() {
            val glide = timeline.glideVelocityPxPerSecond
            targetVelocity[0] = layoutVelocity[0]
            targetVelocity[1] = layoutVelocity[1] + glide
            targetVelocity[2] = layoutVelocity[2]
            targetVelocity[3] = layoutVelocity[3] + glide
        }

        fun launch(now: Long) {
            offset[0] = from.left - to.left
            offset[1] = from.top - to.top
            offset[2] = from.right - to.right
            offset[3] = from.bottom - to.bottom
            startMagnitude = offset.maxOf { abs(it) }
            launchedAt = now
            onSource = true
            springFrames = 0
            updateTargetVelocity()
            // A piece leaves its source at rest, even when the list is already carrying its target.
            if (!stallSprings) springs.forEachIndexed { edge, spring -> spring.animateTo(0f, -targetVelocity[edge]) }
        }

        /** 0 at the source, 1 at the target, by the edge that has the furthest to go. */
        fun geometricProgress(): Float = when {
            !launched -> 0f
            startMagnitude <= 0f -> 1f
            else -> (1f - offset.maxOf { abs(it) } / startMagnitude).coerceIn(0f, 1f)
        }

        fun settled(now: Long): Boolean = launched && springs.none { it.isRunning } && !stallSprings &&
            now - launchedAt >= FADE_END_MS

        fun cancel() {
            springs.forEach { it.cancel() }
            image?.land()
            image = null
            node.discardDisplayList()
            target = null
        }

        fun moved() {
            motionFrames++
            invalidate()
        }
    }

    private enum class Stage { WAITING, AWAITING_TARGETS, FLYING }

    private inner class Transition(val snapshot: ComposerSendSnapshot, val turnKey: String) {
        val animated = ValueAnimator.areAnimatorsEnabled()
        var stage = Stage.WAITING
        var accepted = false
        var turn: List<PreparedChatMessage>? = null
        /** In landing order: the text, then each attachment. */
        var pieces: List<Piece> = emptyList()
        /** Sources without a row on screen: they fade where they are while the list shows the rows. */
        var orphans: List<Piece> = emptyList()
        var orphansSince = 0L
        var waitedFrames = 0
        val callbacks = ArrayList<Runnable>()
        val rows: Set<Long> get() = pieces.mapTo(HashSet()) { it.spec.targetRowId }
    }

    private val transitions = ArrayList<Transition>()
    /** Spring updates so far; the failsafe tells a slow flight from a stalled one by it. */
    private var motionFrames = 0L
    private var frameTime = 0L
    private var stepPosted = false
    private val stepper = Runnable { stepPosted = false; step() }

    private val surfacePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_brand_solid) }
    private val tintPaint = Paint()
    private val inputFillPaint = Paint().apply { color = context.getColor(R.color.token_composer_bg) }
    /** Draws a row's own pixels added onto a layer that holds the source at the remaining weight. */
    private val addPaint = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.ADD) }
    private val layerBounds = RectF()
    private val bubbleTextColor = ChatPalette.from(context).userText
    private val imageFallbackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_tertiary) }
    private val bitmapPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val clip = Path()
    private val drawRect = RectF()
    private val cropRect = RectF()
    private val chatBounds = RectF()
    private val sourceImageRadius = resources.getDimension(R.dimen.radius_2xl)
    private val imageRadius = resources.getDimension(R.dimen.radius_4xl)
    private val window = IntArray(2)
    private val targetWindow = IntArray(2)

    init {
        isClickable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        visibility = GONE
    }

    /**
     * Freezes what is being sent, before the composer clears. [turnKey] is the turn its rows will
     * carry (the request's key), so the flight finds exactly its own rows.
     */
    fun hold(snapshot: ComposerSendSnapshot, turnKey: String) {
        transitions.firstOrNull { it.turnKey == turnKey }?.let(::finish)
        if (!isAttachedToWindow) return
        if (snapshot.textLayout == null && snapshot.attachments.isEmpty()) return
        val transition = Transition(snapshot, turnKey)
        transitions += transition
        visibility = VISIBLE
        // A send that never shows up (refused, or its rows never come) must not leave a ghost.
        schedule(transition, HOLD_TIMEOUT_MS) {
            if (transition in transitions && transition.stage == Stage.WAITING) finish(transition)
        }
        invalidate()
    }

    /** The send was taken and the composer cleared: the frozen copy now stands in for it. */
    fun accept(turnKey: String) {
        val transition = transitions.firstOrNull { it.turnKey == turnKey } ?: return
        transition.accepted = true
        tryBegin(transition)
        invalidate()
    }

    /** The send was refused: the composer keeps the draft, so the frozen copy goes. */
    fun cancel(turnKey: String) {
        transitions.firstOrNull { it.turnKey == turnKey }?.let(::finish)
    }

    /** Ends every send at once: the screen is going, or another conversation is shown. */
    fun cancel() {
        transitions.toList().forEach(::finish)
    }

    /** A list was committed. A held send whose rows are in it takes them. */
    fun onCommitted(rows: List<PreparedChatMessage>) {
        for (transition in transitions.toList()) {
            if (transition.stage != Stage.WAITING) continue
            val turn = SendFlightGeometry.turnRows(transition.turnKey, rows)
            if (turn.isEmpty()) continue
            transition.turn = turn
            pairPieces(transition, turn)
            if (transition.pieces.isEmpty()) { finish(transition); continue }
            // Hidden before they are first drawn, even if the composer has not cleared yet.
            syncHiddenRows()
            tryBegin(transition)
        }
    }

    /** How long the rows may stay hidden before a stalled flight is ended (see [armFailsafe]). */
    internal val failsafeMillis: Long = SendFlightGeometry.failsafeMillis(DesignMotion.springFlight, TARGET_WAIT_FRAMES)

    /** Where a row's view is found; a test can stand in for the timeline. */
    internal var findTarget: (Long) -> View? = timeline::viewForRow

    /** A test can stall the springs to check what guards a flight that never ends. */
    internal var stallSprings = false

    /** Called after every step, with the pieces where they will be drawn; for tests. */
    internal var onFrame: (() -> Unit)? = null



    internal val isFlying: Boolean get() = transitions.any { it.stage != Stage.WAITING || it.turn != null }

    /** Where the piece landing in [rowId] is drawn now, after layout, in window px; null if none is. */
    internal fun presentedBox(rowId: Long): FlightBox? {
        val transition = transitions.firstOrNull { t -> t.stage == Stage.FLYING && t.pieces.any { it.spec.targetRowId == rowId } }
            ?: return null
        transition.pieces.forEach { it.resolve() }
        updateMasks(transition)
        return visibleFrame(transition.pieces.first { it.spec.targetRowId == rowId })
    }

    private fun pairPieces(transition: Transition, turn: List<PreparedChatMessage>) {
        val sent = transition.snapshot
        val paired = SendFlightGeometry.pair(sent.textLayout != null, sent.attachments.size, turn)
        val byId = turn.associateBy { it.message.id }
        transition.pieces = paired.map { spec ->
            val row = byId.getValue(spec.targetRowId)
            val piece = if (spec.isText && sent.fromVoice) {
                // A voice message starts as the brand bubble it was spoken into.
                val bubble = sent.surfaceBounds
                Piece(spec, FlightBox(bubble.left, bubble.top, bubble.right, bubble.bottom),
                    sent.textOrigin.x - bubble.left, sent.textOrigin.y - bubble.top, row.contentAlpha, null, fromBubble = true)
            } else if (spec.isText) {
                val layout = sent.textLayout!!
                Piece(spec, SendFlightGeometry.textSource(sent.textOrigin.x, sent.textOrigin.y, widest(layout),
                    layout.height.toFloat(), row.horizontalPaddingPx.toFloat(), row.verticalPaddingPx.toFloat()),
                    row.horizontalPaddingPx.toFloat(), row.verticalPaddingPx.toFloat(), row.contentAlpha, null)
            } else {
                val thumb = sent.attachments[spec.source]
                Piece(spec, FlightBox(thumb.bounds.left, thumb.bounds.top, thumb.bounds.right, thumb.bounds.bottom),
                    0f, 0f, 0f, thumb.bitmap)
            }
            val sourceClip = piece.viewportClip.sourceInWindow
            if (spec.isText) {
                sourceClip.set(sent.surfaceBounds)
                if (!sourceClip.intersect(piece.from.left, piece.from.top, piece.from.right, piece.from.bottom))
                    sourceClip.setEmpty()
            } else {
                sourceClip.set(sent.attachments[spec.source].visibleBounds)
            }
            piece
        }
    }

    private fun tryBegin(transition: Transition) {
        if (!transition.accepted || transition.turn == null || transition.stage != Stage.WAITING) return
        transition.stage = Stage.AWAITING_TARGETS
        // Whatever happens to the springs from here, the rows must come back.
        armFailsafe(transition, motionFrames, rearms = 0)
        startStepping()
    }

    /** A flight still moving on slow frames gets more time, twice; a stalled one ends at once. */
    private fun armFailsafe(transition: Transition, framesBefore: Long, rearms: Int) {
        schedule(transition, failsafeMillis) {
            if (transition !in transitions) return@schedule
            val moving = transition.pieces.any { piece -> piece.springs.any { it.isRunning } } && motionFrames != framesBefore
            if (moving && rearms < FAILSAFE_REARMS) armFailsafe(transition, motionFrames, rearms + 1)
            else finish(transition)
        }
    }

    private fun schedule(transition: Transition, delay: Long, block: () -> Unit) {
        val callback = Runnable(block)
        transition.callbacks += callback
        postDelayed(callback, delay)
    }

    private fun startStepping() {
        if (stepPosted || transitions.none { it.stage != Stage.WAITING }) return
        stepPosted = true
        postOnAnimation(stepper)
    }

    /**
     * Once per frame, with the animations: targets, launches and landings are decided here. The
     * drawing reads the targets again after layout, so a piece is never a frame behind its row.
     */
    private fun step() {
        frameTime = AnimationUtils.currentAnimationTimeMillis()
        for (transition in transitions.toList()) when (transition.stage) {
            Stage.WAITING -> Unit
            Stage.AWAITING_TARGETS -> awaitTargets(transition)
            Stage.FLYING -> fly(transition)
        }
        onFrame?.invoke()
        invalidate()
        startStepping()
    }

    /** The rows are laid out on a later frame; every piece waits for its target a few frames. */
    private fun awaitTargets(transition: Transition) {
        val missing = transition.pieces.count { piece -> !piece.resolve().also { if (it) piece.track(frameTime) } }
        if (missing > 0 && transition.waitedFrames++ < TARGET_WAIT_FRAMES) return
        // An oversized group need not be laid out in full. Rows that stayed off screen are shown
        // by the list itself; their sources fade where they are instead of floating anywhere.
        val (found, orphaned) = transition.pieces.partition { it.target != null }
        transition.pieces = found
        transition.orphans = orphaned
        transition.orphansSince = frameTime
        syncHiddenRows()
        if (!transition.animated) { finish(transition); return }
        transition.stage = Stage.FLYING
        fly(transition)
    }

    private fun fly(transition: Transition) {
        // A target scrolled away, recycled or gone with its conversation: that row shows as it is.
        val lost = transition.pieces.filter { piece -> !piece.resolve().also { if (it) piece.track(frameTime) } }
        if (lost.isNotEmpty()) {
            lost.forEach { it.cancel() }
            transition.pieces = transition.pieces - lost.toSet()
            syncHiddenRows()
        }
        var above: Piece? = null
        for (piece in transition.pieces) {
            val previous = above
            if (!piece.launched) {
                // Wait until the piece landing above has passed this one's source.
                val clear = previous == null || (previous.launched &&
                    SendFlightGeometry.mayLeave(visibleFrame(previous).bottom, gapAbove(previous, piece), piece.from.top))
                if (clear) piece.launch(frameTime)
            }
            above = piece
        }
        updateMasks(transition)
        val orphansDone = frameTime - transition.orphansSince >= DesignMotion.feedbackOut
        if (transition.pieces.all { it.settled(frameTime) } && (transition.orphans.isEmpty() || orphansDone)) {
            finish(transition)
        }
    }

    private fun updateMasks(transition: Transition) {
        var above: Piece? = null
        for (piece in transition.pieces) {
            val previous = above
            piece.maskTop = if (previous == null || !piece.launched) Float.NEGATIVE_INFINITY
                else visibleFrame(previous).bottom + gapAbove(previous, piece)
            above = piece
        }
    }

    /** The space the rows keep between [above] and [below] at rest. */
    private fun gapAbove(above: Piece, below: Piece): Float = (below.to.top - above.to.bottom).coerceAtLeast(0f)

    /** The piece's rectangle with its mask applied. */
    private fun visibleFrame(piece: Piece): FlightBox = SendFlightGeometry.masked(piece.frame(), piece.maskTop)


    private fun finish(transition: Transition) {
        if (!transitions.remove(transition)) return
        transition.callbacks.forEach(::removeCallbacks)
        transition.callbacks.clear()
        transition.pieces.forEach { it.cancel() }
        textNodes.remove(transition.snapshot)?.discardDisplayList()
        syncHiddenRows()
        if (transitions.isEmpty()) {
            removeCallbacks(stepper)
            stepPosted = false
            visibility = GONE
        }
        invalidate()
    }

    private fun syncHiddenRows() {
        val hidden = transitions.flatMapTo(HashSet()) { if (it.animated && it.turn != null) it.rows else emptySet() }
        if (hidden != timeline.hiddenRows) timeline.setHiddenRows(hidden)
    }

    override fun onDetachedFromWindow() {
        cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        if (transitions.isEmpty()) return
        getLocationInWindow(window)
        val originX = window[0].toFloat()
        val originY = window[1].toFloat()
        timeline.chatBoundsInWindow(chatBounds)
        chatBounds.offset(-originX, -originY)
        for (transition in transitions) {
            if (!transition.animated) continue
            when (transition.stage) {
                // Until the composer clears it still shows the draft itself.
                Stage.WAITING, Stage.AWAITING_TARGETS -> if (transition.accepted) drawHeld(canvas, transition.snapshot, originX, originY)
                Stage.FLYING -> drawFlying(canvas, transition, originX, originY)
            }
        }
    }

    private fun drawFlying(canvas: Canvas, transition: Transition, originX: Float, originY: Float) {
        val fade = 1f - DesignMotion.softInOut.getInterpolation(
            ((frameTime - transition.orphansSince).toFloat() / DesignMotion.feedbackOut).coerceIn(0f, 1f))
        if (fade > 0f) for (orphan in transition.orphans) {
            val save = canvas.save()
            val source = orphan.viewportClip.sourceInWindow
            canvas.clipRect(source.left - originX, source.top - originY, source.right - originX, source.bottom - originY)
            drawRect.set(orphan.from.left - originX, orphan.from.top - originY, orphan.from.right - originX, orphan.from.bottom - originY)
            if (orphan.spec.isText) drawSourceText(canvas, transition.snapshot, orphan, fade)
            else orphan.sourceBitmap?.let { drawCropped(canvas, it, (255 * fade).toInt()) }
            canvas.restoreToCount(save)
        }
        // The field's fill stays over its hint while the text is still leaving it, then fades.
        val sent = transition.snapshot
        val text = (transition.pieces + transition.orphans).firstOrNull { it.spec.isText }
        if (text != null && sent.textLayout != null && !sent.fromVoice) {
            val cover = if (text.departedAt < 0) 1f else 1f - DesignMotion.softInOut.getInterpolation(
                ((frameTime - text.departedAt).toFloat() / DesignMotion.feedbackOut).coerceIn(0f, 1f))
            if (cover > 0f) {
                val save = canvas.save()
                canvas.clipRect(sent.surfaceBounds.left - originX, sent.surfaceBounds.top - originY,
                    sent.surfaceBounds.right - originX, sent.surfaceBounds.bottom - originY)
                // Only where the field still is: a composer that moved (the keyboard closing)
                // leaves no patch of its fill behind over the chat.
                canvas.clipRect(0f, chatBounds.bottom, width.toFloat(), height.toFloat())
                inputFillPaint.alpha = (255 * cover).toInt()
                val left = sent.textOrigin.x - originX
                val top = sent.textOrigin.y - originY
                canvas.drawRect(left, top, left + hintCoverWidth(sent), top + sent.textLayout.height, inputFillPaint)
                canvas.restoreToCount(save)
            }
        }
        // After layout: the rows may have moved since the step.
        for (piece in transition.pieces) piece.resolve()
        updateMasks(transition)
        // Images first: before it leaves, the text passes over the strip it was typed under.
        for (piece in transition.pieces.sortedBy { it.spec.isText }) {
            val box = piece.frame()
            drawRect.set(box.left - originX, box.top - originY, box.right - originX, box.bottom - originY)
            val save = canvas.save()
            piece.viewportClip.apply(canvas, chatBounds, drawRect, originX, originY, piece.settled(frameTime))
            if (piece.viewportClip.departed && piece.departedAt < 0) piece.departedAt = frameTime
            if (piece.maskTop.isFinite()) canvas.clipRect(0f, piece.maskTop - originY, width.toFloat(), height.toFloat())
            if (piece.spec.isText) drawText(canvas, transition.snapshot, piece) else drawImage(canvas, piece)
            canvas.restoreToCount(save)
        }
    }

    /** Before the rows arrive: the frozen text and thumbnails exactly where they were. */
    private fun drawHeld(canvas: Canvas, sent: ComposerSendSnapshot, originX: Float, originY: Float) {
        if (sent.fromVoice) {
            surfacePaint.alpha = 255
            val bubble = sent.surfaceBounds
            drawRect.set(bubble.left - originX, bubble.top - originY, bubble.right - originX, bubble.bottom - originY)
            canvas.drawRoundRect(drawRect, sent.surfaceCornerRadius, sent.surfaceCornerRadius, surfacePaint)
        }
        if (sent.textLayout != null) {
            canvas.save()
            canvas.clipRect(sent.surfaceBounds.left - originX, sent.surfaceBounds.top - originY,
                sent.surfaceBounds.right - originX, sent.surfaceBounds.bottom - originY)
            canvas.translate(sent.textOrigin.x - originX, sent.textOrigin.y - originY)
            // The cleared field already shows its hint here; the copy stands on the field's own fill.
            if (!sent.fromVoice) {
                inputFillPaint.alpha = 255
                canvas.drawRect(0f, 0f, hintCoverWidth(sent), sent.textLayout.height.toFloat(), inputFillPaint)
            }
            canvas.drawRenderNode(textNode(sent).apply { alpha = 1f; setUseCompositingLayer(false, null) })
            canvas.restore()
        }
        sent.attachments.forEach { thumb ->
            val save = canvas.save()
            canvas.clipRect(thumb.visibleBounds.left - originX, thumb.visibleBounds.top - originY,
                thumb.visibleBounds.right - originX, thumb.visibleBounds.bottom - originY)
            drawRect.set(thumb.bounds.left - originX, thumb.bounds.top - originY,
                thumb.bounds.right - originX, thumb.bounds.bottom - originY)
            if (thumb.bitmap != null) drawCropped(canvas, thumb.bitmap, 255)
            else canvas.drawRoundRect(drawRect, sourceImageRadius, sourceImageRadius, imageFallbackPaint)
            canvas.restoreToCount(save)
        }
    }

    /**
     * A node's properties are read when the frame is rendered, not when it is drawn here, so its
     * alpha is set once per frame and left as it is: a send draws its text node only once.
     */
    private fun drawSourceText(canvas: Canvas, sent: ComposerSendSnapshot, piece: Piece, alpha: Float, tint: Int? = null) {
        val node = textNode(sent)
        node.alpha = alpha
        if (tint == null) node.setUseCompositingLayer(false, null)
        else node.setUseCompositingLayer(true, tintPaint.apply { colorFilter = PorterDuffColorFilter(tint, PorterDuff.Mode.SRC_IN) })
        canvas.save()
        canvas.translate(drawRect.left + piece.padH, drawRect.top + piece.padV)
        canvas.drawRenderNode(node)
        canvas.restore()
    }

    /** The text rides 1:1 inside a bubble whose colour arrives first; then the bubble's own snapshot. */
    private fun drawText(canvas: Canvas, sent: ComposerSendSnapshot, piece: Piece) {
        val target = piece.target
        val radius = (target as? FlightTarget)?.flightCornerRadius ?: 0f
        val elapsed = if (piece.launched) frameTime - piece.launchedAt else 0L
        val mix = crossfade(elapsed)
        // The colour arrives early; a voice bubble starts opaque and settles to the row's opacity.
        val surface = if (piece.fromBubble) {
            1f + (piece.surfaceAlpha - 1f) * DesignMotion.softInOut.getInterpolation(timeFraction(elapsed, DesignMotion.stateChange))
        } else {
            DesignMotion.smoothOut.getInterpolation(timeFraction(elapsed, DesignMotion.feedbackIn)) * piece.surfaceAlpha
        }
        // A true crossfade: source at (1 - mix) and the row's own pixels at mix, summed in one
        // layer, so the bubble keeps its opacity throughout instead of thinning in the middle.
        layerBounds.set(drawRect)
        // The row's tail hangs under its bubble and fades in with the row.
        layerBounds.bottom += (target as? FlightTarget)?.flightTailPx ?: 0f
        val layer = canvas.saveLayer(layerBounds, null)
        canvas.saveLayerAlpha(layerBounds, (255 * (1f - mix)).toInt().coerceIn(0, 255))
        surfacePaint.alpha = (255 * surface).toInt().coerceIn(0, 255)
        canvas.drawRoundRect(drawRect, radius, radius, surfacePaint)
        canvas.clipRect(drawRect)
        // The typed text takes the bubble's text colour as the bubble's colour arrives, so the
        // crossfade blends two labels of one colour instead of dimming through a dark/light mix.
        val toBubble = if (piece.fromBubble) 0f
            else DesignMotion.smoothOut.getInterpolation(timeFraction(elapsed, DesignMotion.feedbackIn))
        val tint = if (toBubble > 0f) ColorUtils.blendARGB(sent.textPaint.color, bubbleTextColor, toBubble) else null
        drawSourceText(canvas, sent, piece, 1f, tint)
        canvas.restore()
        if (target != null && mix > 0f) {
            recordTarget(piece, target)
            addTarget(piece, mix)
            canvas.save()
            canvas.translate(drawRect.left - piece.bounds.left, drawRect.top - piece.bounds.top)
            canvas.drawRenderNode(piece.node)
            canvas.restore()
        }
        canvas.restoreToCount(layer)
    }

    /** Wide enough for the typed text and for the hint the cleared field shows in its place. */
    private fun hintCoverWidth(sent: ComposerSendSnapshot): Float =
        max(sent.textLayout?.width?.toFloat() ?: 0f, sent.textPaint.measureText(hint) + hintSlack)

    private val hint = context.getString(R.string.composer_hint)
    private val hintSlack = resources.getDimension(R.dimen.spacing_xl)

    /** The target's node, added at [weight] onto the layer below (see [addPaint]). */
    private fun addTarget(piece: Piece, weight: Float) {
        piece.node.alpha = 1f
        addPaint.alpha = (255 * weight).toInt().coerceIn(0, 255)
        piece.node.setUseCompositingLayer(true, addPaint)
    }

    /** The same full-image preview and crop as the row, at a changing aperture. */
    private fun drawImage(canvas: Canvas, piece: Piece) {
        val radius = sourceImageRadius + (imageRadius - sourceImageRadius) * piece.geometricProgress()
        val image = piece.image
        if (image != null) image.drawInto(canvas, drawRect, radius, frameTime)
        else if (piece.sourceBitmap != null) drawCropped(canvas, piece.sourceBitmap, 255, radius)
        else canvas.drawRoundRect(drawRect, radius, radius, imageFallbackPaint)
    }

    /** [bitmap] scaled to cover [drawRect], centred, like the thumbnail and the image both show it. */
    private fun drawCropped(canvas: Canvas, bitmap: Bitmap, alpha: Int, radius: Float = sourceImageRadius) {
        if (alpha <= 0 || bitmap.width <= 0 || bitmap.height <= 0) return
        ImageCrop.cover(bitmap.width, bitmap.height, drawRect, cropRect)
        bitmapPaint.alpha = alpha
        canvas.save()
        clip.reset()
        clip.addRoundRect(drawRect, radius, radius, Path.Direction.CW)
        canvas.clipPath(clip)
        canvas.drawBitmap(bitmap, null, cropRect, bitmapPaint)
        canvas.restore()
    }

    /** The target row's current pixels, recorded fresh so an image that finishes loading shows. */
    private fun recordTarget(piece: Piece, target: View) {
        val node = piece.node
        node.setPosition(0, 0, target.width, target.height)
        val recording = node.beginRecording(target.width, target.height)
        target.draw(recording)
        node.endRecording()
    }

    private val textNodes = HashMap<ComposerSendSnapshot, RenderNode>()

    private fun textNode(sent: ComposerSendSnapshot): RenderNode {
        textNodes.keys.retainAll(transitions.mapTo(HashSet()) { it.snapshot })
        return textNodes.getOrPut(sent) {
            val layout = sent.textLayout!!
            RenderNode("send-flight-text").apply {
                setPosition(0, 0, layout.width, layout.height)
                val recording = beginRecording(layout.width, layout.height)
                layout.draw(recording)
                endRecording()
            }
        }
    }

    private fun widest(layout: Layout): Float {
        var widest = 0f
        for (line in 0 until layout.lineCount) widest = max(widest, layout.getLineRight(line))
        return widest
    }

    private companion object {
        const val HOLD_TIMEOUT_MS = 3_000L
        const val TARGET_WAIT_FRAMES = 6
        const val FAILSAFE_REARMS = 2
        /** The row's own pixels take over once the bubble's colour has arrived. */
        const val CROSSFADE_DELAY_MS = 40L
        val FADE_END_MS = CROSSFADE_DELAY_MS + DesignMotion.stateChange

        fun timeFraction(elapsed: Long, duration: Long) = (elapsed.toFloat() / duration).coerceIn(0f, 1f)

        fun crossfade(elapsed: Long) =
            DesignMotion.softInOut.getInterpolation(timeFraction(elapsed - CROSSFADE_DELAY_MS, DesignMotion.stateChange))

        val EDGES = Array(4) { edge ->
            object : FloatPropertyCompat<Piece>("flightEdge$edge") {
                override fun getValue(piece: Piece) = piece.offset[edge]
                override fun setValue(piece: Piece, value: Float) {
                    piece.offset[edge] = value
                    piece.moved()
                }
            }
        }
    }
}
