package surf.comma.android.chat.render

import android.animation.ValueAnimator
import android.text.Layout
import android.view.Choreographer
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.TimelineBlockKinds
import kotlin.math.abs

/**
 * How fast a reply is revealed. The caret covers what is left in [TARGET_SECONDS], within
 * [MIN_DP_PER_SECOND]..[MAX_DP_PER_SECOND]; each arriving packet gives it a short push that eases
 * from [ARRIVAL_BURST] to [ARRIVAL_CRUISE] times that speed over [ARRIVAL_EASE_SECONDS].
 */
internal object RevealPacing {
    const val TARGET_SECONDS = 1.35f
    const val MIN_DP_PER_SECOND = 34f
    const val MAX_DP_PER_SECOND = 440f
    const val ARRIVAL_BURST = 1.48f
    const val ARRIVAL_CRUISE = 0.78f
    const val ARRIVAL_EASE_SECONDS = 0.2f

    /** Cards, and messages that arrive complete, fade in whole instead of a caret. */
    const val CARD_FADE_SECONDS = 0.25f

    /**
     * A message that arrives complete also rises into place from [MESSAGE_RISE_DP] below, on the
     * size spring, starting [MESSAGE_DELAY_SECONDS] after the typing bubble begins to shrink.
     * Its entry lasts [MESSAGE_ENTER_SECONDS], by which time the spring has settled.
     */
    const val MESSAGE_RISE_DP = 6f
    const val MESSAGE_DELAY_SECONDS = 0.035f
    const val MESSAGE_ENTER_SECONDS = 0.4f

    /** A reply that lands whole is revealed within this, however long it is. Drafts are not capped. */
    const val WHOLE_REPLY_SECONDS = 2f

    /**
     * The least speed that finishes [remainingPx] of text, plus [cards] card fades, within
     * [WHOLE_REPLY_SECONDS]. The cards' fades come out of the budget first.
     */
    fun wholeReplyFloor(remainingPx: Float, cards: Int): Float {
        val seconds = (WHOLE_REPLY_SECONDS - cards * CARD_FADE_SECONDS).coerceAtLeast(WHOLE_REPLY_SECONDS / 2f)
        return remainingPx / seconds
    }

    fun speedPxPerSecond(remainingPx: Float, density: Float): Float =
        (remainingPx / TARGET_SECONDS).coerceIn(MIN_DP_PER_SECOND * density, MAX_DP_PER_SECOND * density)

    fun arrivalScale(secondsSinceArrival: Float): Float {
        val t = (secondsSinceArrival / ARRIVAL_EASE_SECONDS).coerceIn(0f, 1f)
        val eased = t * t * (3f - 2f * t)
        return ARRIVAL_BURST + (ARRIVAL_CRUISE - ARRIVAL_BURST) * eased
    }
}

/**
 * How much of one row is revealed, as a distance along its [RevealTrack]. Time only enters
 * through [advance], so the pacing can be driven by a fake clock.
 */
internal class RevealCaret(
    totalPx: Float,
    private val density: Float,
    revealedPx: Float = 0f,
    /** Set for a card: the whole track is covered in this time, with no packet pacing. */
    private val fixedSeconds: Float? = null,
) {
    var totalPx = totalPx
        private set
    var revealedPx = revealedPx.coerceIn(0f, totalPx)
        private set
    var speedPxPerSecond = speedFor(totalPx - this.revealedPx)
        private set
    /** Never slower than this, whatever the packet push: set for replies that arrive whole. */
    var floorPxPerSecond = 0f
    private var sinceArrival = 0f

    val isDone: Boolean get() = revealedPx >= totalPx

    /** A packet arrived: the track is now [totalPx] long. */
    fun onContent(totalPx: Float) {
        this.totalPx = totalPx
        revealedPx = revealedPx.coerceAtMost(totalPx)
        speedPxPerSecond = speedFor(totalPx - revealedPx)
        sinceArrival = 0f
    }

    private fun speedFor(remainingPx: Float): Float = fixedSeconds?.let { totalPx / it }
        ?: RevealPacing.speedPxPerSecond(remainingPx, density)

    fun advance(seconds: Float) {
        if (seconds <= 0f || isDone) return
        val scale = if (fixedSeconds != null) 1f else RevealPacing.arrivalScale(sinceArrival)
        revealedPx = (revealedPx + maxOf(speedPxPerSecond * scale, floorPxPerSecond) * seconds)
            .coerceAtMost(totalPx)
        sinceArrival += seconds
    }

    fun finish() {
        revealedPx = totalPx
    }
}

/**
 * A row's content laid end to end: every text line is a segment as long as the line is wide,
 * every other block (code, table, rule, image) one segment as wide as it is drawn.
 */
internal class RevealTrack(
    /** For block `b`, its segments are `firstSegment[b] until firstSegment[b + 1]`. */
    private val firstSegment: IntArray,
    /** The layout line of a text segment; 0 for a whole-block segment. */
    private val line: IntArray,
    private val start: FloatArray,
    private val width: FloatArray,
    /** Where each segment starts vertically, in the row's coordinates. */
    private val top: FloatArray = FloatArray(width.size),
) {
    val totalPx: Float = if (width.isEmpty()) 0f else start.last() + width.last()

    /** Where [revealedPx] cuts block [block]; the result is written to [out]. */
    fun cut(block: Int, revealedPx: Float, out: RevealCut) {
        val first = firstSegment.getOrNull(block) ?: return out.full()
        val end = firstSegment.getOrNull(block + 1) ?: return out.full()
        if (first >= end) return out.full()
        val blockEnd = start[end - 1] + width[end - 1]
        if (revealedPx >= blockEnd) return out.full()
        if (revealedPx <= start[first]) return out.hidden()
        for (segment in first until end) {
            if (revealedPx < start[segment] + width[segment]) {
                out.kind = RevealCut.PARTIAL
                out.line = line[segment]
                out.offsetPx = revealedPx - start[segment]
                out.fraction = if (width[segment] > 0f) out.offsetPx / width[segment] else 1f
                return
            }
        }
        out.full()
    }

    /** The top of the segment the caret is in, in the row's coordinates. */
    fun caretTop(revealedPx: Float): Float {
        for (segment in width.indices) {
            if (revealedPx < start[segment] + width[segment]) return top[segment]
        }
        return top.lastOrNull() ?: 0f
    }

    companion object {
        /** [widths] per block, per segment; [tops] likewise, defaulting to 0. */
        fun of(widths: List<List<Float>>, tops: List<List<Float>>? = null): RevealTrack {
            val first = IntArray(widths.size + 1)
            val lines = ArrayList<Int>()
            val starts = ArrayList<Float>()
            val lengths = ArrayList<Float>()
            val ys = ArrayList<Float>()
            var at = 0f
            widths.forEachIndexed { block, segments ->
                first[block] = lengths.size
                segments.forEachIndexed { index, segmentWidth ->
                    lines += index
                    starts += at
                    lengths += segmentWidth
                    ys += tops?.getOrNull(block)?.getOrNull(index) ?: 0f
                    at += segmentWidth
                }
            }
            first[widths.size] = lengths.size
            return RevealTrack(first, lines.toIntArray(), starts.toFloatArray(), lengths.toFloatArray(), ys.toFloatArray())
        }

        fun of(item: PreparedChatMessage): RevealTrack {
            val widths = ArrayList<List<Float>>(item.blocks.size)
            val tops = ArrayList<List<Float>>(item.blocks.size)
            item.blocks.forEach { block ->
                val y = block.yOffsetPx.toFloat()
                when (block) {
                    is PreparedContentBlock.Text -> {
                        widths += lineWidths(block.layout).asList()
                        tops += List(block.layout.lineCount) { y + block.padPx + block.layout.getLineTop(it) }
                    }
                    else -> {
                        widths += listOf(when (block) {
                            is PreparedContentBlock.Code -> block.viewportWidthPx.toFloat()
                            is PreparedContentBlock.Table -> minOf(block.contentWidthPx, block.viewportWidthPx).toFloat()
                            is PreparedContentBlock.Math -> minOf(block.contentWidthPx, block.viewportWidthPx).toFloat()
                            is PreparedContentBlock.Rule -> block.widthPx.toFloat()
                            is PreparedContentBlock.Image -> block.widthPx.toFloat()
                            is PreparedContentBlock.Text -> 0f
                        })
                        tops += listOf(y)
                    }
                }
            }
            return of(widths, tops)
        }

        fun lineWidth(layout: Layout, line: Int): Float = abs(layout.getLineRight(line) - layout.getLineLeft(line))

        /**
         * Measuring a line's width shapes its text again, which is too slow to repeat for a whole
         * reply on every packet. A streaming reply keeps the layouts of its finished blocks, so
         * widths are kept per layout and only a block laid out anew is measured.
         */
        private val measured = java.util.WeakHashMap<Layout, FloatArray>()

        fun lineWidths(layout: Layout): FloatArray =
            measured.getOrPut(layout) { FloatArray(layout.lineCount) { lineWidth(layout, it) } }
    }
}

/** A reusable answer from [RevealTrack.cut]. */
internal class RevealCut {
    var kind = FULL
    /** For a partial text block: the line the caret is on, and how far into it. */
    var line = 0
    var offsetPx = 0f
    /** How far the caret is through its segment, for blocks that fade in whole. */
    var fraction = 1f

    fun full() { kind = FULL; fraction = 1f }
    fun hidden() { kind = HIDDEN; fraction = 0f }

    companion object {
        const val FULL = 0
        const val HIDDEN = 1
        const val PARTIAL = 2
    }
}

/** What a cell needs to draw a row mid-reveal. */
internal class RevealFrame(val track: RevealTrack, val revealedPx: Float)

/**
 * The reveal state of every row in one timeline. It lives outside the recycled cells, keyed by
 * row id, so scrolling a row away and back never replays it.
 *
 * Rows reveal one after another in list order: streaming text behind a caret, everything that
 * arrives complete as one fade. A row is revealed only if it arrives while the
 * reader follows the latest turn; replies found on opening, from the cache or while reading
 * history appear at once, and a row that leaves the screen mid-reveal is finished.
 */
internal class TextRevealBook(
    private val density: Float,
    private val scheduler: FrameScheduler = ChoreographerScheduler,
    private val motionEnabled: () -> Boolean = ValueAnimator::areAnimatorsEnabled,
    private val trackOf: (PreparedChatMessage) -> RevealTrack = RevealTrack::of,
) {
    /**
     * The lowest on-screen y of a row, in the row's own coordinates, or null when the row is not
     * on screen (or not laid out yet).
     */
    var visibleBottom: (Long) -> Float? = { null }
    /** Rows whose reveal moved this frame; the timeline redraws them. */
    var onFrame: (List<Long>) -> Unit = {}

    private class Entry(val caret: RevealCaret, val card: Boolean, var track: RevealTrack?, var cacheKey: String,
                        var order: Int, val turnId: String, var missingFrames: Int = 0,
                        /** A whole message: it fades in after a short delay and rises into place. */
                        val rise: Boolean = false)

    private val entries = LinkedHashMap<Long, Entry>()
    private var lastFrameNanos = 0L
    private var scheduled = false
    private val moved = ArrayList<Long>()

    val isRunning: Boolean get() = entries.values.any { !it.caret.isDone }

    /**
     * Called with each committed list. [live] is false for the first list, a page of history and
     * whenever the reader is not following the latest turn: new rows then appear whole.
     */
    fun onSubmit(previous: List<PreparedChatMessage>, next: List<PreparedChatMessage>, live: Boolean) {
        val animate = live && motionEnabled()
        val present = HashSet<Long>(next.size)
        next.forEach { present += it.message.id }
        // A streamed reply is replaced by its final message under another row id; the new rows
        // continue from where the old one had got to instead of starting over.
        val carried = HashMap<String, Float>()
        val before = HashMap<Long, PreparedChatMessage>(previous.size)
        previous.forEach { item ->
            before[item.message.id] = item
            if (item.message.id in present || !revealable(item) || item.message.cardKind != null) return@forEach
            val shown = entries[item.message.id]?.caret?.revealedPx ?: trackOf(item).totalPx
            carried[item.message.turnId] = (carried[item.message.turnId] ?: 0f) + shown
        }
        entries.keys.retainAll(present)
        if (!animate) entries.values.forEach { it.caret.finish() }
        // Rows that land whole in this list share one time budget.
        val whole = ArrayList<RevealCaret>()
        var wholeCards = 0
        next.forEachIndexed { order, item ->
            val id = item.message.id
            val entry = entries[id]
            if (entry != null) {
                entry.order = order
                if (entry.cacheKey != item.cacheKey && !entry.card) {
                    val track = trackOf(item)
                    entry.track = track
                    entry.cacheKey = item.cacheKey
                    if (animate) entry.caret.onContent(track.totalPx) else {
                        entry.caret.onContent(track.totalPx)
                        entry.caret.finish()
                    }
                }
                return@forEachIndexed
            }
            if (!animate || !revealable(item)) return@forEachIndexed
            val old = before[id]
            // A message that arrives complete is shown complete: its bubble fades in whole, like
            // a card. Only text still streaming in (or continuing a streamed one) uses the caret.
            val card = item.message.cardKind != null || (old == null &&
                item.message.status != MessageStatus.STREAMING && (carried[item.message.turnId] ?: 0f) <= 0f)
            val track = if (card) null else trackOf(item)
            val total = track?.totalPx ?: 1f
            val start = when {
                // A row already on screen that grows: only the new part is revealed.
                old != null -> if (card || old.cacheKey == item.cacheKey ||
                    item.message.status != MessageStatus.STREAMING) return@forEachIndexed
                    else trackOf(old).totalPx
                card -> 0f
                else -> {
                    val budget = carried[item.message.turnId] ?: 0f
                    val used = minOf(budget, total)
                    if (budget > 0f) carried[item.message.turnId] = budget - used
                    used
                }
            }
            if (start >= total && item.message.status != MessageStatus.STREAMING) return@forEachIndexed
            val rise = card && item.message.cardKind == null
            val caret = RevealCaret(total, density, start, when {
                rise -> RevealPacing.MESSAGE_ENTER_SECONDS
                card -> RevealPacing.CARD_FADE_SECONDS
                else -> null
            })
            entries[id] = Entry(caret, card, track, item.cacheKey, order, item.message.turnId, rise = rise)
            if (old == null && item.message.status != MessageStatus.STREAMING) {
                if (card) wholeCards++ else whole += caret
            }
        }
        if (whole.isNotEmpty()) {
            val floor = RevealPacing.wholeReplyFloor(whole.sumOf { (it.totalPx - it.revealedPx).toDouble() }.toFloat(), wholeCards)
            whole.forEach { it.floorPxPerSecond = floor }
        }
        if (entries.size > 1) {
            val sorted = entries.entries.sortedBy { it.value.order }
            entries.clear()
            sorted.forEach { entries[it.key] = it.value }
        }
        if (isRunning) schedule()
    }

    /** The row's reveal, or null when it is fully shown. */
    fun frameFor(item: PreparedChatMessage): RevealFrame? {
        val entry = entries[item.message.id] ?: return null
        if (entry.card || entry.caret.isDone) return null
        val track = entry.track?.takeIf { entry.cacheKey == item.cacheKey } ?: trackOf(item).also {
            entry.track = it
            entry.cacheKey = item.cacheKey
        }
        return RevealFrame(track, entry.caret.revealedPx)
    }

    /** Opacity of a card row: 0 while it waits its turn, fading in when reached. */
    fun cardAlpha(id: Long): Float {
        val entry = entries[id] ?: return 1f
        if (!entry.card) return 1f
        val t = if (entry.rise) {
            (entry.secondsIn() - RevealPacing.MESSAGE_DELAY_SECONDS) / RevealPacing.CARD_FADE_SECONDS
        } else {
            entry.caret.revealedPx / entry.caret.totalPx
        }
        return surf.comma.android.ui.theme.DesignMotion.smoothOut.getInterpolation(t.coerceIn(0f, 1f))
    }

    /** How far below its place a whole message is drawn while it rises in; 0 at rest. */
    fun riseOffset(id: Long): Float {
        val entry = entries[id]?.takeIf { it.rise && !it.caret.isDone } ?: return 0f
        val moved = surf.comma.android.ui.theme.DesignMotion.springSize
            .progressAt(entry.secondsIn() - RevealPacing.MESSAGE_DELAY_SECONDS)
        return RevealPacing.MESSAGE_RISE_DP * density * (1f - moved)
    }

    private fun Entry.secondsIn(): Float = caret.revealedPx / caret.totalPx * RevealPacing.MESSAGE_ENTER_SECONDS

    /** Show everything now, for example when the page stops. */
    fun finishAll() {
        val ids = entries.filterValues { !it.caret.isDone }.keys.toList()
        entries.values.forEach { it.caret.finish() }
        if (ids.isNotEmpty()) onFrame(ids)
    }

    fun clear() {
        entries.clear()
        scheduler.cancel(::tick)
        scheduled = false
        lastFrameNanos = 0L
    }

    private fun schedule() {
        if (scheduled) return
        scheduled = true
        scheduler.post(::tick)
    }

    /** One display frame. Only the first unfinished row, in list order, moves. */
    internal fun tick(frameTimeNanos: Long) {
        scheduled = false
        val seconds = if (lastFrameNanos == 0L) 0f
            else ((frameTimeNanos - lastFrameNanos) / 1e9f).coerceIn(0f, MAX_FRAME_SECONDS)
        lastFrameNanos = frameTimeNanos
        moved.clear()
        val head = entries.entries.firstOrNull { !it.value.caret.isDone }
        if (head != null) {
            val (id, entry) = head
            val where = visibleBottom(id)
            if (where == null) {
                // Not laid out yet on its first frames; gone from the screen after that.
                if (++entry.missingFrames > MISSING_FRAME_LIMIT) entry.caret.finish()
            } else {
                entry.missingFrames = 0
                if (!entry.card && caretBelow(entry, where)) entry.caret.finish() else entry.caret.advance(seconds)
            }
            moved += id
        }
        if (moved.isNotEmpty()) onFrame(moved)
        if (isRunning) schedule() else lastFrameNanos = 0L
    }

    /** The caret has gone below the bottom of the screen: the rest is not animated. */
    private fun caretBelow(entry: Entry, visibleBottom: Float): Boolean {
        val track = entry.track ?: return false
        return track.caretTop(entry.caret.revealedPx) > visibleBottom
    }

    private fun revealable(item: PreparedChatMessage): Boolean {
        if (item.message.role != ChatRole.AGENT) return false
        return when (item.message.cardKind) {
            null -> item.blocks.isNotEmpty()
            TimelineBlockKinds.LIVE_STATUS, TimelineBlockKinds.REPLY_ERROR, TimelineBlockKinds.TOOL_PLACEHOLDER,
            LiveRowKinds.REPLY_ACTIONS_RESERVED -> false
            else -> true
        }
    }

    private companion object {
        const val MAX_FRAME_SECONDS = 0.1f
        const val MISSING_FRAME_LIMIT = 3
    }
}

/** Where the reveal gets its frames; a test drives [TextRevealBook.tick] by hand instead. */
internal interface FrameScheduler {
    fun post(callback: (Long) -> Unit)
    fun cancel(callback: (Long) -> Unit)
}

internal object ChoreographerScheduler : FrameScheduler {
    private val callbacks = HashMap<(Long) -> Unit, Choreographer.FrameCallback>()

    override fun post(callback: (Long) -> Unit) {
        val frame = callbacks.getOrPut(callback) { Choreographer.FrameCallback { callback(it) } }
        Choreographer.getInstance().postFrameCallback(frame)
    }

    override fun cancel(callback: (Long) -> Unit) {
        callbacks.remove(callback)?.let(Choreographer.getInstance()::removeFrameCallback)
    }
}
