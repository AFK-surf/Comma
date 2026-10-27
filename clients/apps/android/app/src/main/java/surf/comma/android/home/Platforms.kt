package surf.comma.android.home

import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.ImageSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.children
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.routines.PlatformRoutine
import surf.comma.android.routines.ProviderMarks
import surf.comma.android.routines.RecommendationAction
import surf.comma.android.routines.RecommendationFeed
import surf.comma.android.routines.RecommendationItem
import surf.comma.android.routines.RecommendationPart
import surf.comma.android.routines.RecommendationSource
import surf.comma.android.routines.RemoteImages
import surf.comma.android.routines.RoutineQuote
import surf.comma.android.scroll.widget.LinearLayoutManager
import surf.comma.android.scroll.widget.RecyclerView
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.pressedFill
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceStore
import kotlin.math.abs
import kotlin.math.roundToInt

/** What choosing a pre-task does: a prompt only fills the router composer, which the member sends. */
class RoutineActions(
    private val context: Context,
    private val usePrompt: (String) -> Unit,
    private val openTask: (String) -> Unit,
) {
    fun perform(item: RecommendationItem) {
        val task = item.linkedTaskId
        if (task != null) return openTask(task)
        when (val action = item.action) {
            is RecommendationAction.OpenUrl -> openUrl(action.url)
            is RecommendationAction.Prompt -> usePrompt(if (action.memberTask) memberRequest(action.prompt) else action.prompt)
            null -> Unit
        }
    }

    fun openUrl(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    /** A member row's prompt is their own task; the composer asks Comma for help with it in their voice. */
    private fun memberRequest(task: String): String {
        var words = task
        val first = words.firstOrNull()
        if (first != null && first.isUpperCase() && words.drop(1).takeWhile(Char::isLetter).all(Char::isLowerCase)) {
            words = first.lowercase() + words.drop(1)
        }
        return context.getString(R.string.routines_help_me, words)
    }
}

/**
 * A connected app on Home: its mark, then its name with how many pre-tasks wait for the member, in the
 * bottom-leading corner. An app connected more than once names the account in the empty top corner. Tapping the
 * card opens the pre-tasks.
 */
class PlatformCard(context: Context) : FrameLayout(context) {
    private val logo = ImageView(context)
    private val name = context.label(Level.REGULAR, R.color.token_text_primary)
    private val count = context.label(Level.REGULAR, R.color.token_text_secondary).apply { fontFeatureSettings = "tnum" }
    private val warning = ImageView(context).apply {
        setImageResource(R.drawable.ic_warning_triangle)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_fg_attention))
    }
    private val account = context.label(Level.MINI, R.color.token_text_quaternary)

    init {
        background = rounded(context.getColor(R.color.token_card_primary), context.dp(RADIUS_DP).toFloat(),
            context.getColor(R.color.token_border_primary), maxOf(1, context.dp(1)))
        minimumHeight = context.dp(104)
        setPadding(context.dp(12), context.dp(12), context.dp(12), context.dp(12))
        val bottom = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(logo, LinearLayout.LayoutParams(context.dp(28), context.dp(28)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(name, LinearLayout.LayoutParams(0, -2, 1f).apply { weight = 0f; width = LinearLayout.LayoutParams.WRAP_CONTENT })
                addView(count, LinearLayout.LayoutParams(-2, -2).apply { marginStart = context.dp(6) })
                addView(warning, LinearLayout.LayoutParams(context.dp(16), context.dp(16)).apply { marginStart = context.dp(6) })
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(8) })
        }
        addView(bottom, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        addView(account, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START))
        isClickable = true
        isFocusable = true
        tactile(0.96f)
    }

    fun bind(platform: PlatformRoutine, pretasks: Int, refreshing: Boolean) {
        logo.setImageDrawable(ProviderMarks.drawable(context, platform.source?.appId))
        // A recycled card may still be fetching the previous app's icon, which would land over this one's mark.
        if (ProviderMarks.hasArtwork(platform.source?.appId)) RemoteImages.cancel(logo)
        else RemoteImages.load(logo, platform.source?.iconUrl, context.dp(28))
        name.text = platform.name
        name.setTextColor(context.getColor(R.color.token_text_primary))
        name.background = null
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        count.text = pretasks.toString()
        count.setTextColor(context.getColor(if (pretasks > 0) R.color.token_text_secondary else R.color.token_text_quaternary))
        count.alpha = if (refreshing) 0.3f else 1f
        val reconnect = platform.source?.needsReconnect == true
        warning.isVisible = reconnect
        account.text = platform.connectionLabel
        account.isVisible = platform.connectionLabel != null
        val label = listOfNotNull(platform.name, platform.connectionLabel).joinToString(", ")
        contentDescription = (if (pretasks > 0) context.getString(R.string.routines_card_count, label, pretasks)
            else context.getString(R.string.routines_card_nothing, label)) +
            if (reconnect) ", " + context.getString(R.string.routines_needs_reconnecting) else ""
    }

    fun placeholder() {
        RemoteImages.cancel(logo)
        logo.setImageDrawable(rounded(context.getColor(R.color.token_bg_tertiary), context.dp(8).toFloat()))
        name.text = "Platform"
        name.setTextColor(0)
        name.background = rounded(context.getColor(R.color.token_bg_tertiary), context.dp(6).toFloat())
        count.text = ""
        warning.isVisible = false
        account.isVisible = false
        isEnabled = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }

    companion object { const val RADIUS_DP = 20 }
}

/**
 * Home's platform cards: one per connected app, two and a peek per screen, in a strip that settles on a card's
 * leading edge, with a scroll indicator under it once they do not all fit. Stands in with placeholders, a retry or
 * a hint to connect apps when there are no cards to show. Cards line up with the page's 20dp text margin.
 */
class PlatformCarousel(private val activity: ComponentActivity, private val store: WorkspaceStore,
                       private val open: (PlatformRoutine) -> Unit) : LinearLayout(activity) {
    private val strip = RecyclerView(activity).apply {
        layoutManager = LinearLayoutManager(activity, LinearLayoutManager.HORIZONTAL, false)
        clipToPadding = false
        setPadding(activity.dp(MARGIN_DP), 0, activity.dp(MARGIN_DP), 0)
        overScrollMode = OVER_SCROLL_NEVER
    }
    private val indicator = Indicator(activity)
    private val unavailable = LinearLayout(activity).apply {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(activity.dp(MARGIN_DP), 0, activity.dp(MARGIN_DP), 0)
        minimumHeight = activity.dp(44)
        addView(activity.label(Level.SMALL, R.color.token_text_quaternary).apply { setText(R.string.routines_unavailable) }, LayoutParams(0, -2, 1f))
        addView(activity.label(Level.SMALL, R.color.token_bg_brand_solid, DesignFonts.semibold).apply {
            setText(R.string.shell_retry)
            setPadding(activity.dp(12), activity.dp(12), 0, activity.dp(12))
            setOnClickListener { store.routines.retry() }
        })
    }
    private val connect = ConnectCard(activity)
    private val rateLimited = activity.label(Level.MINI, R.color.token_text_quaternary, lines = 0).apply {
        setText(R.string.routines_rate_limited)
        setPadding(activity.dp(MARGIN_DP), activity.dp(8), activity.dp(MARGIN_DP), 0)
    }
    private val adapter = Cards()

    init {
        orientation = VERTICAL
        addView(strip, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(indicator, LayoutParams(activity.dp(44), activity.dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; topMargin = activity.dp(16) })
        addView(unavailable, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(connect, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            setMargins(activity.dp(MARGIN_DP), activity.dp(8), activity.dp(MARGIN_DP), 0)
        })
        addView(rateLimited, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        strip.adapter = adapter
        strip.addItemDecoration(object : RecyclerView.ItemDecoration() {
            override fun getItemOffsets(outRect: android.graphics.Rect, view: View, parent: RecyclerView, state: RecyclerView.State) {
                if (parent.getChildAdapterPosition(view) > 0) outRect.left = activity.dp(SPACING_DP)
            }
        })
        strip.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) = updateIndicator()
            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                if (newState == RecyclerView.SCROLL_STATE_IDLE) settle()
            }
        })
    }

    /** Shows the briefing as it is now. */
    fun render() {
        val feed = store.routines.feed.value
        val failure = store.routines.failure.value
        val platforms = feed?.platforms.orEmpty()
        val placeholders = feed == null && failure == null
        strip.isVisible = platforms.isNotEmpty() || placeholders
        unavailable.isVisible = feed == null && failure != null
        connect.isVisible = feed != null && platforms.isEmpty()
        rateLimited.isVisible = failure == WorkspaceStore.RoutinesFailure.RATE_LIMITED
        adapter.show(platforms, placeholders)
        strip.post { updateIndicator() }
    }

    /** The member's Tasks changed: a card whose pre-tasks opened or ended shows its new count. */
    fun refreshCounts() = adapter.refreshCounts()

    private fun cardWidth(): Int {
        val perScreen = if (resources.configuration.fontScale >= 1.6f) 1.2f else 2.2f
        val available = width.takeIf { it > 0 } ?: resources.displayMetrics.widthPixels
        return ((available - 2 * activity.dp(MARGIN_DP) - activity.dp(SPACING_DP)) / perScreen).roundToInt()
    }

    private fun step() = cardWidth() + activity.dp(SPACING_DP)

    /** Settles on the card nearest where the strip came to rest. */
    private fun settle() {
        val offset = strip.computeHorizontalScrollOffset()
        val range = strip.computeHorizontalScrollRange() - strip.computeHorizontalScrollExtent()
        if (offset >= range) return
        val target = (offset.toFloat() / step()).roundToInt() * step()
        val delta = target.coerceAtMost(range) - offset
        if (abs(delta) > 1) strip.smoothScrollBy(delta, 0)
    }

    private fun updateIndicator() {
        val count = adapter.itemCount
        val perScreen = if (resources.configuration.fontScale >= 1.6f) 1 else 2
        indicator.isVisible = !adapter.placeholders && count > perScreen
        val range = strip.computeHorizontalScrollRange() - strip.computeHorizontalScrollExtent()
        indicator.progress = if (range > 0) strip.computeHorizontalScrollOffset().toFloat() / range else 0f
        indicator.contentDescription = context.getString(R.string.routines_platforms)
    }

    private inner class Cards : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
        var platforms = emptyList<PlatformRoutine>()
        var placeholders = false
        private var counts = emptyList<Int>()

        fun show(next: List<PlatformRoutine>, placeholder: Boolean) {
            platforms = next
            placeholders = placeholder
            counts = count()
            notifyDataSetChanged()
        }

        /** Rebinds only the cards whose count moved, so a Task update does not redraw the whole strip. */
        fun refreshCounts() {
            if (placeholders) return
            val next = count()
            val previous = counts
            counts = next
            next.forEachIndexed { index, value -> if (previous.getOrNull(index) != value) notifyItemChanged(index) }
        }

        private fun count() = platforms.map { it.preTasks(store::task).size }

        override fun getItemCount() = if (placeholders) 2 else platforms.size

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(PlatformCard(parent.context).apply {
            layoutParams = RecyclerView.LayoutParams(cardWidth(), RecyclerView.LayoutParams.WRAP_CONTENT)
        }) {}

        override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
            val card = holder.itemView as PlatformCard
            card.layoutParams.width = cardWidth()
            if (placeholders) return card.placeholder()
            val platform = platforms[position]
            card.isEnabled = true
            card.bind(platform, counts[position], store.routines.isRefreshing)
            card.setOnClickListener { open(platform) }
            card.setOnLongClickListener {
                ActionMenu(activity).item(activity.getString(R.string.routines_refresh), R.drawable.ic_arrow_rotate_cw,
                    enabled = !store.routines.isRefreshing && store.routines.feed.value?.canRefresh == true) { store.routines.refresh() }
                    .show(it, haptic = true)
                true
            }
        }
    }

    /** Where the strip is, as a thumb sliding along a short track. */
    private class Indicator(context: Context) : View(context) {
        private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_border_secondary) }
        private val thumb = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_text_primary) }
        var progress = 0f
            set(value) { field = value.coerceIn(0f, 1f); invalidate() }

        override fun onDraw(canvas: Canvas) {
            val r = height / 2f
            canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), r, r, track)
            val length = width * 0.4f
            val start = progress * (width - length)
            canvas.drawRoundRect(start, 0f, start + length, height.toFloat(), r, r, thumb)
        }
    }

    /** Stands in for the cards before any app is connected: the sample marks, and where to connect apps. */
    private class ConnectCard(context: Context) : LinearLayout(context) {
        private val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = context.dp(1).toFloat()
            color = context.getColor(R.color.token_border_primary)
            pathEffect = DashPathEffect(floatArrayOf(context.dp(4).toFloat(), context.dp(3).toFloat()), 0f)
        }

        init {
            orientation = VERTICAL
            gravity = Gravity.BOTTOM
            minimumHeight = context.dp(104)
            setPadding(context.dp(12), context.dp(12), context.dp(12), context.dp(12))
            setWillNotDraw(false)
            addView(LogoStack(context, ProviderMarks.samples))
            addView(context.label(Level.SMALL, R.color.token_text_quaternary, lines = 2).apply { setText(R.string.routines_connect_apps) },
                LayoutParams(-2, -2).apply { topMargin = context.dp(8) })
        }

        override fun onDraw(canvas: Canvas) {
            val inset = dash.strokeWidth / 2
            val radius = context.dp(PlatformCard.RADIUS_DP).toFloat()
            canvas.drawRoundRect(RectF(inset, inset, width - inset, height - inset), radius, radius, dash)
        }
    }

    companion object {
        const val MARGIN_DP = 20
        const val SPACING_DP = 12
    }
}

/** Several apps' marks overlapping in small rings, standing for the apps as a group. Each app shows once. */
class LogoStack(context: Context, appIds: List<String?>) : LinearLayout(context) {
    init {
        orientation = HORIZONTAL
        appIds.distinct().forEachIndexed { index, app ->
            addView(FrameLayout(context).apply {
                background = rounded(context.getColor(R.color.token_card_primary), context.dp(13).toFloat(),
                    context.getColor(R.color.token_border_primary), 1)
                addView(ImageView(context).apply { setImageDrawable(ProviderMarks.drawable(context, app)) },
                    FrameLayout.LayoutParams(context.dp(16), context.dp(16), Gravity.CENTER))
            }, LayoutParams(context.dp(26), context.dp(26)).apply { if (index > 0) marginStart = -context.dp(4) })
        }
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    }
}

/**
 * A pre-task in a sheet, as a card of its own as on the desktop: what it is, the source words it quotes as its
 * evidence, then where it comes from ([origin], left out where the page's title already names it). The whole card
 * is what the member taps; nothing is ever sent from here. The minus in its top-end corner stops suggesting the
 * row's source item, and the card leaves at once. A row with nothing to do is drawn without the press.
 */
internal fun preTaskRow(context: Context, item: RecommendationItem, feed: RecommendationFeed, source: RecommendationSource?,
                        origin: String? = null, dismiss: ((RecommendationItem) -> Unit)? = null,
                        choose: (RecommendationItem) -> Unit): View = FrameLayout(context).apply {
    val radius = context.dp(CARD_RADIUS_DP).toFloat()
    background = rounded(context.getColor(R.color.token_bg_tertiary), radius)
    clipToOutline = true
    val dismissible = dismiss != null && item.sourceItem != null
    val column = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(context.dp(14), context.dp(12), context.dp(14), context.dp(12))
    }
    // Words first on every card, so the cards' text keeps one leading edge; a picture trails them.
    val head = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        if (dismissible) setPadding(0, 0, context.dp(DISMISS_DP - 14), 0)
    }
    val words = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    if (item.objective != null) {
        words.addView(context.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium, lines = 0).apply { text = item.objective })
    } else {
        item.title?.let { words.addView(context.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium, lines = 0).apply { text = it }) }
        if (item.parts.isNotEmpty()) {
            words.addView(prose(context, item.parts, feed, lead = false, home = source?.appId), LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(3) })
        } else item.detail?.let {
            words.addView(context.label(Level.MINI, R.color.token_text_tertiary, lines = 0).apply { text = it },
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(3) })
        }
    }
    head.addView(words, LinearLayout.LayoutParams(0, -2, 1f))
    item.imageUrl?.let { url ->
        head.addView(ImageView(context).apply {
            setImageDrawable(ProviderMarks.drawable(context, source?.appId))
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = rounded(context.getColor(R.color.token_surface_ink), context.dp(10).toFloat())
            clipToOutline = true
            setPadding(0, 0, 0, 0)
            RemoteImages.load(this, url, context.dp(36))
        }, LinearLayout.LayoutParams(context.dp(36), context.dp(36)).apply { marginStart = context.dp(12) })
    }
    column.addView(head, LinearLayout.LayoutParams(-1, -2))
    item.quote?.let { column.addView(quote(context, it), LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(8) }) }
    origin?.let { name ->
        column.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ImageView(context).apply { setImageDrawable(ProviderMarks.drawable(context, source?.appId)) },
                LinearLayout.LayoutParams(context.dp(16), context.dp(16)))
            addView(context.label(Level.MINI, R.color.token_text_quaternary).apply { text = name },
                LinearLayout.LayoutParams(-2, -2).apply { marginStart = context.dp(6) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(8) })
    }
    addView(column, FrameLayout.LayoutParams(-1, -2))
    val acts = item.linkedTaskId != null || item.action != null
    contentDescription = listOfNotNull(item.objective ?: item.title, if (item.objective != null) null else item.text.ifEmpty { item.detail },
        item.quote?.plainText, origin).joinToString(", ")
    if (acts) {
        val goesOut = item.linkedTaskId == null && item.action is RecommendationAction.OpenUrl
        stateDescription = context.getString(when {
            item.linkedTaskId != null -> R.string.routines_opens_task
            goesOut -> R.string.routines_opens_link
            else -> R.string.routines_adds_prompt
        })
        pressedFill(radius = radius)
        setOnClickListener { choose(item) }
    }
    if (dismiss != null && item.sourceItem != null) {
        val card = this
        addView(FrameLayout(context).apply {
            addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_circle_minus)
                imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_quaternary))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, FrameLayout.LayoutParams(context.dp(18), context.dp(18), Gravity.CENTER))
            contentDescription = context.getString(R.string.routines_dismiss)
            isClickable = true
            isFocusable = true
            // The minus sits on the card's own press, so it asks once, as the long press did, before the card leaves.
            setOnClickListener { minus ->
                ActionMenu(context).item(context.getString(R.string.routines_dismiss), R.drawable.ic_action_close) {
                    card.isVisible = false
                    // A platform whose last card left leaves with it.
                    (card.parent as? ViewGroup)?.let { group -> if (group.children.none(View::isVisible)) group.isVisible = false }
                    dismiss(item)
                }.show(minus, haptic = true)
            }
        }, FrameLayout.LayoutParams(context.dp(DISMISS_DP), context.dp(DISMISS_DP), Gravity.TOP or Gravity.END))
    }
}

private const val CARD_RADIUS_DP = 24
/** The minus's touch target in a card's top-end corner, which the card's title leaves room for. */
private const val DISMISS_DP = 44

/**
 * A member task's quoted source words under a quote rule, in the title's size and a quieter ink: at most four lines, a
 * mention a weight heavier, a link underlined.
 */
private fun quote(context: Context, quote: RoutineQuote): View = LinearLayout(context).apply {
    orientation = LinearLayout.HORIZONTAL
    addView(View(context).apply { background = rounded(context.getColor(R.color.token_border_primary), context.dp(1).toFloat()) },
        LinearLayout.LayoutParams(context.dp(2), LinearLayout.LayoutParams.MATCH_PARENT))
    val text = SpannableStringBuilder()
    quote.lines.forEachIndexed { index, line ->
        if (index > 0) text.append("\n")
        if (line.listItem) text.append("• ")
        line.runs.forEach { run ->
            val start = text.length
            text.append(run.text)
            when (run.kind) {
                RoutineQuote.Kind.MENTION -> {
                    text.setSpan(StyleSpan(Typeface.BOLD), start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    text.setSpan(ForegroundColorSpan(context.getColor(R.color.token_text_primary)), start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
                RoutineQuote.Kind.LINK -> text.setSpan(UnderlineSpan(), start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                RoutineQuote.Kind.TEXT, RoutineQuote.Kind.CHANNEL -> Unit
            }
        }
    }
    addView(context.label(Level.REGULAR, R.color.token_text_tertiary, lines = 4).apply { this.text = text },
        LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = context.dp(8) })
}

/**
 * Briefing prose: in a row, a step under the page's body, with links and Tasks as mentions a weight heavier; as the
 * briefing's summary, a lead paragraph, with links and Tasks in the app's blue after their source's mark, which open
 * what they name.
 */
internal fun prose(context: Context, parts: List<RecommendationPart>, feed: RecommendationFeed, lead: Boolean, home: String? = null,
                   openTask: (String) -> Unit = {}, openUrl: (String) -> Unit = {}): TextView {
    val text = SpannableStringBuilder()
    val link = context.getColor(R.color.token_bg_brand_solid)
    val markSize = context.dp(if (lead) 17 else 15)
    fun reference(label: String, sourceId: String?, click: (() -> Unit)?) {
        val app = feed.source(sourceId)?.appId
        if (!(lead.not() && app == home) && app != null && ProviderMarks.hasArtwork(app)) {
            val start = text.length
            text.append("￼ ")
            val mark = ProviderMarks.drawable(context, app).apply { setBounds(0, 0, markSize, markSize) }
            text.setSpan(ImageSpan(mark, ImageSpan.ALIGN_BASELINE), start, start + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val start = text.length
        text.append(label)
        if (lead && click != null) {
            text.setSpan(object : ClickableSpan() {
                override fun onClick(widget: View) = click()
                override fun updateDrawState(ds: TextPaint) { ds.color = link; ds.isUnderlineText = false }
            }, start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        text.setSpan(StyleSpan(Typeface.BOLD), start, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    parts.forEach { part ->
        when (part) {
            is RecommendationPart.Text -> appendInlineMarkdown(text, part.text)
            is RecommendationPart.Link -> reference(part.label, part.sourceId) { openUrl(part.url) }
            is RecommendationPart.Task -> reference(part.label, part.sourceId) { openTask(part.conversationId) }
        }
    }
    return context.label(if (lead) Level.LARGE else Level.REGULAR, R.color.token_text_primary, lines = 0).apply {
        this.text = text
        if (lead) setLineSpacing(context.dp(5).toFloat(), 1f)
        if (lead) movementMethod = LinkMovementMethod.getInstance()
    }
}

/** The model writes light Markdown: bold and code. It is rendered; everything else stays literal. */
private fun appendInlineMarkdown(out: SpannableStringBuilder, value: String) {
    val pattern = Regex("\\*\\*(.+?)\\*\\*|`([^`]+)`")
    var last = 0
    for (match in pattern.findAll(value)) {
        out.append(value, last, match.range.first)
        val start = out.length
        out.append(match.groupValues[1].ifEmpty { match.groupValues[2] })
        out.setSpan(StyleSpan(Typeface.BOLD), start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        last = match.range.last + 1
    }
    out.append(value, last, value.length)
}

/**
 * A platform's pre-tasks, each a card of its own, or the card's own words when this app can't draw its template.
 * [showsOrigin] names the platform under each card's words, where nothing above them does.
 */
internal fun preTaskGroup(context: Context, platform: PlatformRoutine, items: List<RecommendationItem>, feed: RecommendationFeed,
                          showsOrigin: Boolean = false, dismiss: ((RecommendationItem) -> Unit)? = null,
                          choose: (RecommendationItem) -> Unit): View = cardColumn(context).apply {
    val cards = mutableListOf<View>()
    platform.card?.fallbackText?.let { cards += context.label(Level.REGULAR, R.color.token_text_primary, lines = 0).apply {
        text = it
        background = rounded(context.getColor(R.color.token_bg_tertiary), context.dp(CARD_RADIUS_DP).toFloat())
        setPadding(context.dp(14), context.dp(12), context.dp(14), context.dp(12))
    } }
    items.forEach { cards += preTaskRow(context, it, feed, platform.source, if (showsOrigin) platform.heading else null, dismiss, choose) }
    cards.forEach { addView(it, LinearLayout.LayoutParams(-1, -2)) }
}

/** A column of pre-task cards, 8dp apart. The gap sits between visible cards only, so a dismissed card leaves none. */
private fun cardColumn(context: Context) = LinearLayout(context).apply {
    orientation = LinearLayout.VERTICAL
    showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
    dividerDrawable = GradientDrawable().apply { setSize(0, context.dp(8)) }
}

/**
 * A platform's pre-tasks: the app's mark and name as the title, then its suggestions, each a card of its own. A
 * sideways swipe pages to the previous or next platform in the carousel's order, over page dots, and the title
 * follows the page; it opens on the card that was tapped. Choosing a row closes the sheet, then acts.
 */
class PreTaskSheet(activity: ComponentActivity, private val store: WorkspaceStore, start: PlatformRoutine,
                   private val actions: RoutineActions) : CommaSheet(activity, start.heading) {
    private val pages = store.routines.feed.value?.platforms?.takeIf { all -> all.any { it.id == start.id } } ?: listOf(start)
    private val titleMark = ImageView(activity)
    private var chosen: RecommendationItem? = null
    private var page = pages.indexOfFirst { it.id == start.id }.coerceAtLeast(0)

    init {
        val pager = RecyclerView(activity).apply {
            layoutManager = LinearLayoutManager(activity, LinearLayoutManager.HORIZONTAL, false)
            overScrollMode = View.OVER_SCROLL_NEVER
        }
        pager.adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun getItemCount() = pages.size
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(FrameLayout(parent.context).apply {
                layoutParams = RecyclerView.LayoutParams(parent.width, RecyclerView.LayoutParams.MATCH_PARENT)
            }) {}
            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
                val frame = holder.itemView as FrameLayout
                frame.layoutParams.width = pager.width
                frame.removeAllViews()
                frame.addView(pageView(pages[position], position))
            }
        }
        pager.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                if (newState != RecyclerView.SCROLL_STATE_IDLE || pager.width == 0) return
                val offset = pager.computeHorizontalScrollOffset()
                val target = (offset.toFloat() / pager.width).roundToInt().coerceIn(0, pages.lastIndex)
                if (abs(target * pager.width - offset) > 1) pager.smoothScrollBy(target * pager.width - offset, 0)
                if (target != page) { page = target; showTitle() }
            }
        })
        pager.post { pager.scrollToPosition(page) }
        setContent(pager)
        val titleRow = titleView.parent as FrameLayout
        titleRow.addView(titleMark, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
        showTitle()
        onDismissed = { chosen?.let(actions::perform) }
    }

    private fun showTitle() {
        val platform = pages[page]
        titleView.text = platform.heading
        titleMark.setImageDrawable(ProviderMarks.drawable(activity, platform.source?.appId))
        titleView.post {
            val width = titleView.width
            titleMark.translationX = -(width / 2f + activity.dp(14))
        }
    }

    private fun pageView(platform: PlatformRoutine, index: Int): View {
        val feed = store.routines.feed.value
        val column = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(activity.dp(16), activity.dp(8), activity.dp(16), activity.dp(16))
        }
        if (feed != null && platform.hasPreTasks(store::task)) {
            column.addView(preTaskGroup(activity, platform, platform.preTasks(store::task), feed, dismiss = store.routines::dismiss) { item ->
                chosen = item
                dismiss()
            })
        } else {
            column.addView(emptyLine(activity, platform))
        }
        // The page dots under the rows, where a medium sheet still shows them.
        if (pages.size > 1) column.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            pages.indices.forEach { dot ->
                addView(View(activity).apply {
                    background = rounded(activity.getColor(if (dot == index) R.color.token_text_primary else R.color.token_text_placeholder),
                        activity.dp(4).toFloat())
                }, LinearLayout.LayoutParams(activity.dp(7), activity.dp(7)).apply { marginStart = activity.dp(4); marginEnd = activity.dp(4) })
            }
        }, LinearLayout.LayoutParams(-1, activity.dp(28)).apply { topMargin = activity.dp(8) })
        return ScrollContainer(activity).apply { addView(column) }
    }
}

/** An idle platform's line in its sheet; one Routines can't read says so, since that needs the member. */
private fun emptyLine(context: Context, platform: PlatformRoutine): View = context.label(Level.SMALL, R.color.token_text_tertiary, lines = 0).apply {
    val reconnect = platform.source?.needsReconnect == true
    text = context.getString(if (reconnect) R.string.routines_reconnect else R.string.routines_nothing_from, platform.name)
    gravity = Gravity.CENTER
    setPadding(context.dp(14), context.dp(16), context.dp(14), context.dp(16))
    if (reconnect) {
        setCompoundDrawablesRelativeWithIntrinsicBounds(context.getDrawable(R.drawable.ic_warning_triangle)?.mutate()?.apply {
            setTint(context.getColor(R.color.token_fg_attention)); setBounds(0, 0, context.dp(16), context.dp(16))
        }, null, null, null)
        compoundDrawablePadding = context.dp(6)
    }
}

/**
 * The whole briefing in one sheet, opened from Home's greeting: the summary as plain prose, then every pre-task as a
 * card of its own that names its platform under its words, in the carousel's order, as the desktop's Routines do.
 * Platforms with nothing fold into one quiet line.
 */
class RoutineSheet(activity: ComponentActivity, private val store: WorkspaceStore, private val actions: RoutineActions,
                   private val openTask: (String) -> Unit) : CommaSheet(activity, activity.getString(R.string.routines_title)) {
    private var after: (() -> Unit)? = null

    init {
        val feed = store.routines.feed.value
        val column = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(activity.dp(16), activity.dp(8), activity.dp(16), activity.dp(24))
        }
        if (feed != null) {
            if (feed.summaryBody.isNotEmpty()) {
                column.addView(prose(activity, feed.summaryBody, feed, lead = true,
                    openTask = { id -> after = { openTask(id) }; dismiss() },
                    openUrl = actions::openUrl).apply { setPadding(activity.dp(4), 0, activity.dp(4), 0) })
            }
            val platforms = feed.platforms
            val busy = platforms.filter { it.hasPreTasks(store::task) }
            if (busy.isNotEmpty()) column.addView(cardColumn(activity).apply {
                busy.forEach { platform ->
                    addView(preTaskGroup(activity, platform, platform.preTasks(store::task), feed, showsOrigin = true,
                        dismiss = store.routines::dismiss) { item ->
                        after = { actions.perform(item) }
                        dismiss()
                    }, LinearLayout.LayoutParams(-1, -2))
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(24) })
            val quiet = platforms.filterNot { it.hasPreTasks(store::task) }
            if (quiet.isNotEmpty()) column.addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(activity.dp(4), 0, activity.dp(4), 0)
                addView(LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(LogoStack(activity, quiet.map { it.source?.appId }))
                    addView(activity.label(Level.MINI, R.color.token_text_tertiary, lines = 0).apply {
                        text = activity.getString(R.string.routines_nothing_from, quiet.joinToString(", ") { it.heading })
                    }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(8) })
                })
                quiet.filter { it.source?.needsReconnect == true }.forEach { platform ->
                    addView(activity.label(Level.MINI, R.color.token_text_tertiary, lines = 0).apply {
                        text = activity.getString(R.string.routines_reconnect, platform.name)
                    }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(24) })
        }
        setContent(ScrollContainer(activity).apply { addView(column) })
        onDismissed = { after?.invoke() }
    }
}
