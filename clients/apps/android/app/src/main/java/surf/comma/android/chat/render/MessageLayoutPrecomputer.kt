package surf.comma.android.chat.render

import android.graphics.Color
import android.graphics.Typeface
import android.graphics.text.LineBreaker
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.LruCache
import surf.comma.android.chat.math.MathBox
import surf.comma.android.chat.math.MathLimits
import surf.comma.android.chat.math.MathSpan
import surf.comma.android.chat.math.MathTypesetter
import surf.comma.android.chat.model.ImageDimensions
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.model.CoreMediaRef
import surf.comma.android.chat.model.MessageStatus
import surf.comma.android.chat.model.TimelineBlockKinds
import surf.comma.android.ui.Background
import surf.comma.android.ui.theme.UiSansSemiBold
import surf.comma.android.ui.theme.UiSansTypeface
import surf.comma.android.ui.theme.uiSansAt
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * One drawable chunk of a message, already measured.
 *
 * Text is cut into ~10-line pieces so a cell can skip off-screen paragraphs
 * Images are first-class blocks so they can sit between two paragraphs.
 */
sealed class PreparedContentBlock {
    abstract val yOffsetPx: Int
    abstract val heightPx: Int
    abstract val contentIndex: Int

    data class Text(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val layout: StaticLayout,
        val firstLine: Int,
        val lineCount: Int,
        val padPx: Int,
        val leftInsetPx: Int = 0,
        /** `>` 的层数。0 是普通文本，>0 时每层在左边画一条竖线。 */
        val quoteDepth: Int = 0,
        /** 列表标号/符号。只挂在一条列表项的第一块上，折行的后续块没有。 */
        val marker: PreparedListMarker? = null,
    ) : PreparedContentBlock()

    data class Image(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val source: String,
        val widthPx: Int,
        val leftInsetPx: Int,
        /** Present for Core media; carries the size, orientation and download identity. */
        val media: CoreMediaRef? = null,
    ) : PreparedContentBlock()

    /**
     * 代码块。自成一个容器：圆角底、顶部一条语言 + 复制的 header、正文按自然宽排（不折行），
     * 超出的部分横向滚动看。[contentWidthPx] 是正文的自然宽，可能远大于 [viewportWidthPx]。
     */
    data class Code(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val layout: StaticLayout,
        val headerHeightPx: Int,
        val padPx: Int,
        val contentWidthPx: Int,
        val viewportWidthPx: Int,
        val languageLayout: StaticLayout?,
        val copyLayout: StaticLayout,
        val copyHitWidthPx: Int,
        val copyText: String,
    ) : PreparedContentBlock()

    /**
     * A display formula, drawn at its natural width in a sideways-scrolling region, like a table:
     * centred when it fits, scrolled when it does not. [box] already holds its glyphs and outlines;
     * [color] is the text colour it is drawn in where it sets none of its own.
     */
    data class Math(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val box: MathBox,
        val padHPx: Int,
        val padVPx: Int,
        val contentWidthPx: Int,
        val viewportWidthPx: Int,
        val leftInsetPx: Int,
        val color: Int,
    ) : PreparedContentBlock()

    /** `---`：一条一像素的横线，宽度跟正文栏对齐。 */
    data class Rule(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val widthPx: Int,
        val leftInsetPx: Int,
    ) : PreparedContentBlock()

    /**
     * 表格。单元格按自然宽排好，[contentWidthPx] 可能超过 [viewportWidthPx]——
     * 超出的部分靠横向滚动看，而不是把列挤扁。
     */
    data class Table(
        override val yOffsetPx: Int,
        override val heightPx: Int,
        override val contentIndex: Int,
        val cells: List<PreparedTableCell>,
        val columnEdges: List<Int>,
        val rowEdges: List<Int>,
        val contentWidthPx: Int,
        val viewportWidthPx: Int,
        val leftInsetPx: Int,
    ) : PreparedContentBlock()
}

/**
 * 列表标号，排在正文栏左边自己的一栏里。[columnRightPx] 是这一栏的右边界（相对正文块的
 * 左缘），标号右对齐到它——序号列表因此按小数点对齐，`9.` 和 `10.` 不会互相错开。
 */
data class PreparedListMarker(
    val layout: StaticLayout,
    val columnRightPx: Int,
)

/** 一个单元格：已经量好的 layout，加上它在表格局部坐标系里的落点。 */
data class PreparedTableCell(
    val layout: StaticLayout,
    val leftPx: Int,
    val topPx: Int,
    val row: Int,
    val column: Int,
)

/** 失败行尾的显式动作。整格轻点重发太容易误触——读一半失败回答就把请求重发了。 */
enum class MessageAction {
    RETRY,
    DISCARD,

    /** Ask Core again to stop a turn whose stop did not get through. Goes out as a retry of the row. */

    /** The failure mark or note of an unsent user message: offers retry or delete. */
    SEND_FAILED,
}

data class PreparedMessageAction(
    val action: MessageAction,
    val label: String,
    val widthPx: Int,
)

/** 失败行按钮的文案。预排层不碰 Context，标题由 UI 层带进来。 */
data class MessageActionLabels(
    val retry: String = "重试",
    val discard: String = "放弃",
    /** Under a user message that did not send. */
    val sendFailedNote: String = "未发送 · 点按重试",
)

/** 代码块 header 上的文案。同上：预排层拿不到资源，由 UI 层带进来。 */
data class MessageCodeLabels(
    val copy: String = "复制",
)

/**
 * 代码块的语法配色，按 [CodeToken] 取色。预排层拿不到资源，由 UI 层按当前明暗主题带进来。
 *
 * 默认值是浅色主题的语法色，跟 `values/colors.xml` 同一份；给不带 Context 的
 * JVM 测试兜底，真机上永远是 UI 层传的那套。
 */
data class CodeSyntaxTheme(
    val colors: Map<CodeToken, Int> = emptyMap(),
) {
    fun colorOf(token: CodeToken): Int? = colors[token]
}

data class PreparedChatMessage(
    val message: ChatMessage,
    val cacheKey: String,
    val contents: List<MessageContent>,
    val blocks: List<PreparedContentBlock>,
    val bubbleWidthPx: Int,
    val bubbleHeightPx: Int,
    val bubbleTopPx: Int,
    val cellHeightPx: Int,
    val horizontalPaddingPx: Int,
    val verticalPaddingPx: Int,
    val sideMarginPx: Int,
    val topMarginPx: Int,
    val cornerRadiusPx: Float,
    val drawBubble: Boolean,
    val imageCornerRadiusPx: Float,
    val imageSources: List<String>,
    /** 失败行尾的按钮。空表示这行不可操作。 */
    val actions: List<PreparedMessageAction> = emptyList(),
    val actionsTopPx: Int = 0,
    val actionsHeightPx: Int = 0,
    /** 发送中的用户消息灰显：气泡整体透明度。 */
    val contentAlpha: Float = 1f,
    /** An unsent user message: the note laid out under the bubble, and where it sits. */
    val sendFailedNote: StaticLayout? = null,
    val sendFailedNoteTopPx: Int = 0,
    /** Set on a [TimelineBlockKinds.TASK_BRIEF] row. */
    val brief: PreparedBrief? = null,
    /**
     * The tail under the bubble ([BubbleTail]), as the space the row reserves for it under the
     * bubble; 0 without one. Only the last bubble of a run of one speaker has a tail.
     */
    val tailPx: Int = 0,
) {
    /** A speaker's message bubble, which takes a tail when it ends a run of that speaker's bubbles. */
    val tailable: Boolean get() = drawBubble && brief == null && message.cardKind == null &&
        (message.role == ChatRole.USER || message.role == ChatRole.AGENT)
}

/** Copy for the task brief card; the defaults are only for tests. */
data class MessageBriefLabels(
    val title: String = "Task instructions",
    val showAll: String = "Show all",
    val showLess: String = "Show less",
)

/**
 * A task brief's card around the message text. The card fills the cell, and the footer sits on
 * its bottom edge with the text cut just above it, so a cell can draw the card at any height
 * between [collapsedCellHeightPx] and [expandedCellHeightPx] while it opens or closes.
 */
data class PreparedBrief(
    /** "Task instructions", drawn at the text's left edge. */
    val title: StaticLayout,
    val titleTopPx: Int,
    /** "Show all" or "Show less"; null when the text fits and there is nothing to open. */
    val footer: StaticLayout?,
    /** From where the text is cut to the bottom of the cell. */
    val footerBlockPx: Int,
    /** Space under the card, before the first message after it. */
    val bottomGapPx: Int,
    val expanded: Boolean,
    val collapsedCellHeightPx: Int,
    val expandedCellHeightPx: Int,
) {
    val expandable: Boolean get() = footer != null
}

/**
 * Turns messages into ready-to-draw layouts off the UI thread.
 *
 * Body text is 16sp (assistant 27sp lines, user bubble 22sp); the user bubble hugs its widest line.
 * Messages are split into documents —
 * paragraphs / code / images are independent blocks, and a streaming reply
 * reuses every finished block so only the last paragraph is laid out again.
 */
class MessageLayoutPrecomputer(
    cacheEntries: Int = 320,
    private val jsonParser: JsonParser = OrgJsonParser,
    /** Left and right page margin. The chat uses DESIGN §3.1's; other pages pass their gutter. */
    private val sideMarginDp: Float = CHAT_SIDE_MARGIN_DP,
    /** Copy for [TimelineBlockKinds.TASK_BRIEF] rows. */
    private val briefLabels: MessageBriefLabels = MessageBriefLabels(),
    /** Heights for cards whose size follows their text, e.g. task cards. */
    private val cardHeights: ChatCardHeights? = null,
    /**
     * Agent messages in a grey bubble on the left, like the user's on the right, each run of
     * bubbles ending in a tail. Off, agent text sits on the page (the task page).
     */
    private val bubbles: Boolean = false,
    /** Draws formulas; without it (tests, previews) they stay as their source text. */
    private val math: MathTypesetter? = MathTypesetter.installed,
) {
    private val cache = LruCache<String, PreparedChatMessage>(cacheEntries)
    private val streamingScratch = HashMap<Long, PreparedChatMessage>()

    suspend fun prepare(
        messages: List<ChatMessage>,
        viewportWidthPx: Int,
        density: Float,
        fontScale: Float,
        darkTheme: Boolean,
        actionLabels: MessageActionLabels = MessageActionLabels(),
        statusLabels: MessageStatusLabels = MessageStatusLabels(),
        codeLabels: MessageCodeLabels = MessageCodeLabels(),
        syntaxTheme: CodeSyntaxTheme = CodeSyntaxTheme(),
        palette: ChatPalette = ChatPalette.DEFAULT,
    ): List<PreparedChatMessage> = prepareChanged(
        previous = emptyList(),
        messages = messages,
        viewportWidthPx = viewportWidthPx,
        density = density,
        fontScale = fontScale,
        darkTheme = darkTheme,
        actionLabels = actionLabels,
        statusLabels = statusLabels,
        codeLabels = codeLabels,
        syntaxTheme = syntaxTheme,
        palette = palette,
    )

    /**
     * Incremental timeline preparation. Stable rows reuse their already measured object; only a
     * changed row (plus the paging boundary row whose previous speaker changed) is laid out again.
     */
    suspend fun prepareChanged(
        previous: List<PreparedChatMessage>,
        messages: List<ChatMessage>,
        viewportWidthPx: Int,
        density: Float,
        fontScale: Float,
        darkTheme: Boolean,
        actionLabels: MessageActionLabels = MessageActionLabels(),
        statusLabels: MessageStatusLabels = MessageStatusLabels(),
        codeLabels: MessageCodeLabels = MessageCodeLabels(),
        syntaxTheme: CodeSyntaxTheme = CodeSyntaxTheme(),
        palette: ChatPalette = ChatPalette.DEFAULT,
        firstPreviousRole: ChatRole? = null,
    ): List<PreparedChatMessage> = withContext(Background.compute) {
        if (viewportWidthPx <= 0) return@withContext emptyList()
        val liveIds = HashSet<Long>()
        val previousById = previous.associateBy { it.message.id }
        messages.mapIndexed { index, message ->
            val previousRole = if (index == 0) firstPreviousRole else messages[index - 1].role
            val key = buildKey(message, previousRole, viewportWidthPx, fontScale, darkTheme, palette)
            // A row whose tail came or went is still unchanged underneath; the tail is put back below.
            val unchanged = previousById[message.id]?.takeIf { it.cacheKey.removeSuffix(TAIL_KEY) == key }
            val cached = unchanged ?: cache.get(key)
            val prepared = cached ?: create(
                message = message,
                previousRole = previousRole,
                cacheKey = key,
                viewportWidthPx = viewportWidthPx,
                density = density,
                fontScale = fontScale,
                darkTheme = darkTheme,
                actionLabels = actionLabels,
                statusLabels = statusLabels,
                codeLabels = codeLabels,
                syntaxTheme = syntaxTheme,
                palette = palette,
                previousStreaming = if (message.status.isActive) streamingScratch[message.id] else null,
            ).also { built ->
                if (!message.status.isActive) {
                    cache.put(key, built)
                    streamingScratch.remove(message.id)
                }
            }
            if (message.status.isActive) {
                liveIds.add(message.id)
                streamingScratch[message.id] = prepared
            }
            prepared
        }.also {
            streamingScratch.keys.retainAll(liveIds)
        }.let { rows -> if (bubbles) withTails(rows, density) else rows }
    }

    /**
     * Gives the last bubble of each run of one speaker's bubbles its tail, and takes it from the
     * others. Only the row's height below the bubble changes; nothing is laid out again. The
     * typing bubble continues the agent's run: while it shows, the message above it has no tail.
     */
    private fun withTails(rows: List<PreparedChatMessage>, density: Float): List<PreparedChatMessage> {
        val depth = (BubbleTail.DEPTH_DP * density).toInt()
        return rows.mapIndexed { index, row ->
            val next = rows.getOrNull(index + 1)
            val continues = next != null && next.message.role == row.message.role &&
                (next.tailable || TypingBubble.isTypingRow(next))
            withTail(row, if (row.tailable && !continues) depth else 0)
        }
    }

    private fun withTail(row: PreparedChatMessage, tailPx: Int): PreparedChatMessage {
        if (row.tailPx == tailPx) return row
        // Everything under the bubble (failure buttons, the unsent note) moves down with it.
        val shift = tailPx - row.tailPx
        val base = row.cacheKey.removeSuffix(TAIL_KEY)
        return row.copy(
            cacheKey = if (tailPx > 0) base + TAIL_KEY else base,
            cellHeightPx = row.cellHeightPx + shift,
            actionsTopPx = if (row.actions.isEmpty()) row.actionsTopPx else row.actionsTopPx + shift,
            sendFailedNoteTopPx = if (row.sendFailedNote == null) row.sendFailedNoteTopPx else row.sendFailedNoteTopPx + shift,
            tailPx = tailPx,
        )
    }

    private fun create(
        message: ChatMessage,
        previousRole: ChatRole?,
        cacheKey: String,
        viewportWidthPx: Int,
        density: Float,
        fontScale: Float,
        darkTheme: Boolean,
        actionLabels: MessageActionLabels,
        statusLabels: MessageStatusLabels,
        codeLabels: MessageCodeLabels,
        syntaxTheme: CodeSyntaxTheme,
        palette: ChatPalette,
        previousStreaming: PreparedChatMessage?,
    ): PreparedChatMessage {
        fun dp(value: Float) = (value * density).toInt()
        fun sp(value: Float) = value * density * fontScale

        val role = message.role
        val topMargin = when {
            previousRole == null -> dp(4f)
            previousRole == role -> dp(SAME_SPEAKER_GAP_DP)
            else -> dp(SPEAKER_CHANGE_GAP_DP)
        }
        val nativeCardRenderer = ChatCardRendererRegistry.forKind(message.cardKind)
        if (nativeCardRenderer != null) {
            return PreparedChatMessage(
                message = message,
                cacheKey = cacheKey,
                contents = emptyList(),
                blocks = emptyList(),
                bubbleWidthPx = 0,
                bubbleHeightPx = 0,
                bubbleTopPx = topMargin,
                cellHeightPx = topMargin + (
                    cardHeights?.bodyHeightPx(message, viewportWidthPx, dp(sideMarginDp)) ?: dp(
                        // 卡片比行窄 CARD_SIDE_INSET_DP；比例是按卡片自己的宽度算的。
                        nativeCardRenderer.bodyHeightDp(
                            message,
                            viewportWidthPx / density - CARD_SIDE_INSET_DP,
                        ) * if (message.cardKind == surf.comma.android.settings.devices.DeviceSetupOffer.TYPE)
                            fontScale.coerceAtLeast(1f) else 1f,
                    )
                ),
                horizontalPaddingPx = 0,
                verticalPaddingPx = 0,
                sideMarginPx = dp(sideMarginDp),
                topMarginPx = topMargin,
                cornerRadiusPx = 24f * density,
                drawBubble = false,
                imageCornerRadiusPx = 24f * density,
                imageSources = emptyList(),
            )
        }
        if (message.cardKind == TimelineBlockKinds.LIVE_STATUS &&
            message.cardPayload == TimelineBlockKinds.LIVE_STATUS_SKELETON
        ) {
            // 思考态骨架：不排状态文字，行高 = 三条骨架条（≈首段正文高度），
            // 首个 delta 原位换正文时结构上就没有 13sp→16sp 的跳变。
            return PreparedChatMessage(
                message = message,
                cacheKey = cacheKey,
                contents = emptyList(),
                blocks = emptyList(),
                bubbleWidthPx = 0,
                bubbleHeightPx = 0,
                bubbleTopPx = topMargin,
                cellHeightPx = topMargin + dp(LiveStatusSkeleton.TOTAL_HEIGHT_DP),
                horizontalPaddingPx = 0,
                verticalPaddingPx = 0,
                sideMarginPx = dp(sideMarginDp),
                topMarginPx = topMargin,
                cornerRadiusPx = dp(LiveStatusSkeleton.CORNER_RADIUS_DP).toFloat(),
                drawBubble = false,
                imageCornerRadiusPx = 16f * density,
                imageSources = emptyList(),
            )
        }
        if (message.cardKind == TimelineBlockKinds.LIVE_STATUS) {
            // The typing bubble: a fixed box drawn by the cell, with no text to lay out.
            return PreparedChatMessage(
                message = message,
                cacheKey = cacheKey,
                contents = emptyList(),
                blocks = emptyList(),
                bubbleWidthPx = 0,
                bubbleHeightPx = 0,
                bubbleTopPx = topMargin,
                cellHeightPx = topMargin + dp(TypingBubble.HEIGHT_DP),
                horizontalPaddingPx = 0,
                verticalPaddingPx = 0,
                sideMarginPx = dp(sideMarginDp),
                topMarginPx = topMargin,
                cornerRadiusPx = dp(TypingBubble.BODY_HEIGHT_DP / 2f).toFloat(),
                drawBubble = false,
                imageCornerRadiusPx = 16f * density,
                imageSources = emptyList(),
            )
        }
        val isPhotoGrid = message.cardKind == TimelineBlockKinds.PHOTO_GRID
        // A Core image is a picture row, not a card: full-bleed, no bubble, the same
        // treatment `photo.inline` already gets. Its own kind exists for streaming
        // (see TimelineBlockKinds.CORE_IMAGE), not to make it look different.
        val isPhotoContent = isPhotoGrid ||
            message.cardKind == TimelineBlockKinds.INLINE_PHOTO ||
            message.cardKind == TimelineBlockKinds.CORE_IMAGE
        val isTransientStatus = message.cardKind == TimelineBlockKinds.LIVE_STATUS ||
            message.cardKind == TimelineBlockKinds.TOOL_PLACEHOLDER
        val isCard = !message.cardKind.isNullOrBlank() && !isPhotoContent && !isTransientStatus
        val isBrief = message.cardKind == TimelineBlockKinds.TASK_BRIEF
        val contents = MessageContentParser.parse(message, statusLabels, jsonParser)
        // An agent message in the chat is a grey bubble, mirroring the user's; images alone are not.
        val agentBubble = bubbles && role == ChatRole.AGENT && message.cardKind == null &&
            contents.any { it !is MessageContent.Image }
        val speakerBubble = role == ChatRole.USER || agentBubble
        val horizontalPadding = when {
            isCard -> dp(16f)
            speakerBubble -> dp(USER_BUBBLE_PAD_H_DP)
            role == ChatRole.AGENT -> 0
            else -> dp(14f)
        }
        val verticalPadding = when {
            isCard -> dp(12f)
            speakerBubble -> dp(USER_BUBBLE_PAD_V_DP)
            role == ChatRole.AGENT -> 0
            else -> dp(8f)
        }
        val oppositeBudget = when {
            // A bubble stops 42dp short of the opposite margin, on either side.
            speakerBubble -> dp(sideMarginDp + USER_BUBBLE_OPPOSITE_DP)
            role == ChatRole.AGENT -> dp(sideMarginDp)
            else -> dp(56f)
        }
        val sideMargin = dp(sideMarginDp)
        val maxTextWidth = (viewportWidthPx - sideMargin - oppositeBudget - horizontalPadding * 2)
            .coerceAtLeast(dp(120f))
        val blockGap = dp(BLOCK_GAP_DP)
        val imageHeight = dp(IMAGE_BOX_HEIGHT_DP)
        val maxImageHeight = dp(IMAGE_MAX_HEIGHT_DP)
        val imageWidth = maxTextWidth
        val imageInset = if (role == ChatRole.AGENT && !agentBubble) 0 else horizontalPadding

        // 发送中的用户消息灰显：文字和气泡一起压到 55%，一眼看得出「还没送到」。
        // A failed send reads the same as one still sending; its note says what happened.
        val pendingSend = role == ChatRole.USER &&
            (message.status == MessageStatus.PENDING || message.status == MessageStatus.FAILED)
        val sendFailed = role == ChatRole.USER && message.status == MessageStatus.FAILED
        val replyError = message.cardKind == TimelineBlockKinds.REPLY_ERROR
        val bodyPaint = textPaint(
            role = role,
            palette = palette,
            textSize = if (role == ChatRole.SYSTEM) sp(13f) else sp(BODY_TEXT_SP),
            typeface = UiSansTypeface,
            alpha = if (pendingSend) PENDING_ALPHA else 1f,
        )
        val codePaint = textPaint(
            role = role,
            palette = palette,
            textSize = sp(13.5f),
            typeface = Typeface.MONOSPACE,
        )
        val bodyExtra = lineSpacingExtra(
            bodyPaint,
            when (role) {
                ChatRole.AGENT -> sp(AGENT_LINE_SP)
                ChatRole.USER -> sp(USER_LINE_SP)
                ChatRole.SYSTEM -> sp(18f)
            },
        )
        // Inline code and link colours; the brand-coloured user bubble keeps plain white text.
        // Inside the grey bubble, inline code sits on the page colour so it still stands out.
        val inlineColors = when {
            role == ChatRole.USER -> null
            agentBubble -> palette.copy(inlineCodeBackground = palette.bubbleInset)
            else -> palette
        }
        val codeExtra = lineSpacingExtra(codePaint, sp(20f))
        val codePad = dp(CODE_PAD_DP)

        val drawBubble = (role != ChatRole.AGENT || isCard || agentBubble) &&
            contents.any { it !is MessageContent.Image }
        val bubblePad = if (drawBubble) verticalPadding else 0
        val reusable = reusablePrefix(previousStreaming, contents, cacheKey)
        val blocks = ArrayList<PreparedContentBlock>(contents.size + 2)
        var y = topMargin + bubblePad
        var widest = 0
        var briefTitle: StaticLayout? = null
        if (isBrief) {
            val titlePaint = textPaint(ChatRole.SYSTEM, palette, sp(13f), uiSansAt(UiSansSemiBold))
            val title = briefLabels.title
            briefTitle = buildLayout(title, 0, title.length, titlePaint, maxTextWidth, lineSpacingExtra(titlePaint, sp(18f)))
            y += briefTitle.height + dp(BRIEF_TITLE_GAP_DP)
        }
        val briefTitleTop = topMargin + bubblePad
        val briefContentTop = y

        // h1–h6 以前是同一个 17.5sp，一级和六级长得一模一样。比例按常见编辑器的标题梯度
        // 的标题梯度（26/22/17/15/13/11 相对 13px 正文），按本仓库 16sp 的正文基准折算。
        val headingPaints = HEADING_SCALE.map { scale ->
            textPaint(
                role = role,
                palette = palette,
                textSize = sp(BODY_TEXT_SP * scale),
                typeface = uiSansAt(UiSansSemiBold),
            )
        }
        val headingExtras = headingPaints.map { paint ->
            lineSpacingExtra(paint, paint.textSize * HEADING_LINE_HEIGHT)
        }
        val statusPaint = textPaint(
            role = ChatRole.SYSTEM,
            palette = palette,
            textSize = sp(13f),
            typeface = UiSansTypeface,
        )
        val errorStatusPaint = TextPaint(statusPaint).apply { color = palette.error }
        val statusExtra = lineSpacingExtra(statusPaint, sp(18f))
        val codeChromePaint = textPaint(
            role = ChatRole.SYSTEM,
            palette = palette,
            textSize = sp(12f),
            typeface = UiSansTypeface,
        )
        val tableHeadPaint = textPaint(
            role = role,
            palette = palette,
            textSize = sp(14.5f),
            typeface = uiSansAt(UiSansSemiBold),
        )
        val listIndent = dp(LIST_INDENT_DP)
        val listGap = dp(LIST_MARKER_GAP_DP)
        val quoteInset = dp(14f)
        val ruleThickness = dp(1f).coerceAtLeast(1)
        val gridGap = dp(6f)
        // Formulas this message may still typeset; past MathLimits.MAX_PER_MESSAGE they stay as source.
        var mathBudget = MathLimits.MAX_PER_MESSAGE
        fun mathBox(latex: String, display: Boolean, textSize: Float): MathBox? {
            val typesetter = math ?: return null
            if (mathBudget <= 0) return null
            mathBudget--
            return typesetter.box(latex, display, textSize * MATH_SCALE)
        }
        /**
         * Inline formulas in text of [paint] set in a column [width] wide. One wider than the
         * column is set smaller, down to [MATH_MIN_FIT]; past that it stays as its source, which
         * wraps, rather than running out of the bubble.
         */
        fun inlineMath(paint: TextPaint, width: Int): ((String, Boolean) -> Any?)? {
            if (math == null) return null
            val pad = dp(MATH_INLINE_PAD_DP)
            return inline@{ latex, display ->
                val box = mathBox(latex, display, paint.textSize) ?: return@inline null
                val room = (width - pad * 2).toFloat()
                if (box.widthPx <= room) return@inline MathSpan(box, pad)
                val fit = room / box.widthPx
                if (fit < MATH_MIN_FIT) return@inline null
                math.box(latex, display, box.textSizePx * fit)?.let { MathSpan(it, pad) }
            }
        }

        var contentIndex = 0
        while (contentIndex < contents.size) {
            val content = contents[contentIndex]
            if (contentIndex > 0) {
                y += gapBefore(
                    previous = contents[contentIndex - 1],
                    next = content,
                    blockGap = blockGap,
                    listGap = dp(LIST_ITEM_GAP_DP),
                    headingTop = dp(HEADING_GAP_TOP_DP),
                    headingBottom = dp(HEADING_GAP_BOTTOM_DP),
                )
            }
            if (content is MessageContent.Image && isPhotoGrid) {
                val gridEnd = (contentIndex until contents.size)
                    .firstOrNull { contents[it] !is MessageContent.Image }
                    ?: contents.size
                val grid = contents.subList(contentIndex, gridEnd)
                    .filterIsInstance<MessageContent.Image>()
                if (grid.size > 1) {
                    val laid = layoutPhotoGrid(
                        images = grid,
                        startIndex = contentIndex,
                        yStart = y,
                        columnWidth = maxTextWidth,
                        inset = imageInset,
                        gap = gridGap,
                    )
                    blocks.addAll(laid)
                    y = laid.maxOf { it.yOffsetPx + it.heightPx }
                    widest = max(widest, maxTextWidth)
                    contentIndex = gridEnd
                    continue
                }
            }
            val prefix = reusable[contentIndex]
            if (prefix != null) {
                prefix.forEach { block ->
                    blocks.add(shift(block, y - block.yOffsetPx))
                }
                val height = prefix.last().yOffsetPx + prefix.last().heightPx - prefix.first().yOffsetPx
                y += height
                widest = max(widest, prefix.maxOf { widthOf(it) })
                contentIndex++
                continue
            }
            when (content) {
                is MessageContent.Paragraph -> {
                    val laid = splitText(
                        text = MarkdownSpans.spannable(content.text, inlineColors, inlineMath(bodyPaint, maxTextWidth)),
                        paint = bodyPaint,
                        width = maxTextWidth,
                        extra = bodyExtra,
                        y = y,
                        contentIndex = contentIndex,
                        padPx = 0,
                    )
                    blocks.addAll(laid)
                    y += laid.sumOf { it.heightPx }
                    widest = max(widest, laid.maxOf { widthOf(it) })
                }
                is MessageContent.Heading -> {
                    val level = (content.level - 1).coerceIn(0, HEADING_SCALE.lastIndex)
                    val laid = splitText(
                        text = MarkdownSpans.spannable(content.text, inlineColors,
                            inlineMath(headingPaints[level], maxTextWidth)),
                        paint = headingPaints[level],
                        width = maxTextWidth,
                        extra = headingExtras[level],
                        y = y,
                        contentIndex = contentIndex,
                        padPx = 0,
                    )
                    blocks.addAll(laid)
                    y += laid.sumOf { it.heightPx }
                    widest = max(widest, laid.maxOf { widthOf(it) })
                }
                is MessageContent.ListItem -> {
                    // 缩进按层级累加，项目符号也随层级换形——三层之后不再更深，窄屏上正文没地方站。
                    // 标号/符号独立成栏，正文缩进不含它——以前 "1.  " 是拼进正文的，
                    // 折行后第二行会顶到标号底下，两位数的标号还会把正文推歪。
                    val depth = content.depth.coerceIn(0, BULLETS.lastIndex)
                    val inset = listIndent * (depth + 1)
                    val marker = if (content.ordered) "${content.index}." else BULLETS[depth].toString()
                    val laid = splitText(
                        text = MarkdownSpans.spannable(content.text, inlineColors,
                            inlineMath(bodyPaint, (maxTextWidth - inset).coerceAtLeast(dp(80f)))),
                        paint = bodyPaint,
                        width = (maxTextWidth - inset).coerceAtLeast(dp(80f)),
                        extra = bodyExtra,
                        y = y,
                        contentIndex = contentIndex,
                        padPx = 0,
                        leftInsetPx = inset,
                        marker = PreparedListMarker(
                            layout = buildLayout(
                                marker,
                                0,
                                marker.length,
                                bodyPaint,
                                ceil(Layout.getDesiredWidth(marker, bodyPaint)).toInt(),
                                0f,
                                Layout.Alignment.ALIGN_NORMAL,
                            ),
                            columnRightPx = inset - listGap,
                        ),
                    )
                    blocks.addAll(laid)
                    y += laid.sumOf { it.heightPx }
                    widest = max(widest, laid.maxOf { widthOf(it) })
                }
                is MessageContent.Quote -> {
                    val depth = content.depth.coerceIn(1, MAX_QUOTE_DEPTH)
                    val inset = quoteInset * depth
                    val laid = splitText(
                        text = MarkdownSpans.spannable(content.text, inlineColors,
                            inlineMath(bodyPaint, (maxTextWidth - inset).coerceAtLeast(dp(80f)))),
                        paint = bodyPaint,
                        width = (maxTextWidth - inset).coerceAtLeast(dp(80f)),
                        extra = bodyExtra,
                        y = y,
                        contentIndex = contentIndex,
                        padPx = 0,
                        leftInsetPx = inset,
                        quoteDepth = depth,
                    )
                    blocks.addAll(laid)
                    y += laid.sumOf { it.heightPx }
                    widest = max(widest, laid.maxOf { widthOf(it) })
                }
                is MessageContent.Math -> {
                    val box = if (content.closed) mathBox(content.latex, display = true, textSize = bodyPaint.textSize) else null
                    val padH = dp(MATH_PAD_H_DP)
                    val padV = dp(MATH_PAD_V_DP)
                    val contentWidth = box?.let { ceil(it.widthPx).toInt() + padH * 2 }
                    if (box != null && contentWidth!! <= maxTextWidth * MATH_MAX_WIDTH_FACTOR) {
                        val block = PreparedContentBlock.Math(
                            yOffsetPx = y,
                            heightPx = ceil(box.ascentPx + box.descentPx).toInt() + padV * 2,
                            contentIndex = contentIndex,
                            box = box,
                            padHPx = padH,
                            padVPx = padV,
                            contentWidthPx = contentWidth,
                            viewportWidthPx = maxTextWidth,
                            leftInsetPx = 0,
                            color = bodyPaint.color,
                        )
                        blocks.add(block)
                        y += block.heightPx
                        widest = max(widest, widthOf(block))
                    } else {
                        // Still arriving, or not drawable: the source as written, as plain text.
                        val laid = splitText(
                            text = content.source,
                            paint = bodyPaint,
                            width = maxTextWidth,
                            extra = bodyExtra,
                            y = y,
                            contentIndex = contentIndex,
                            padPx = 0,
                        )
                        blocks.addAll(laid)
                        y += laid.sumOf { it.heightPx }
                        widest = max(widest, laid.maxOf { widthOf(it) })
                    }
                }
                is MessageContent.Divider -> {
                    val rule = PreparedContentBlock.Rule(
                        yOffsetPx = y,
                        heightPx = ruleThickness,
                        contentIndex = contentIndex,
                        widthPx = maxTextWidth,
                        leftInsetPx = 0,
                    )
                    blocks.add(rule)
                    y += rule.heightPx
                    widest = max(widest, maxTextWidth)
                }
                is MessageContent.Table -> {
                    val table = layoutTable(
                        content = content,
                        yStart = y,
                        contentIndex = contentIndex,
                        viewportWidth = maxTextWidth,
                        bodyPaint = bodyPaint,
                        headerPaint = tableHeadPaint,
                        extra = bodyExtra,
                        padH = dp(TABLE_CELL_PAD_H_DP),
                        padV = dp(TABLE_CELL_PAD_V_DP),
                        minColumn = dp(40f),
                        inlineColors = inlineColors,
                        cellMath = { paint -> inlineMath(paint, (maxTextWidth - dp(TABLE_CELL_PAD_H_DP) * 2).coerceAtLeast(dp(40f))) },
                    )
                    blocks.add(table)
                    y += table.heightPx
                    widest = max(widest, widthOf(table))
                }
                is MessageContent.Code -> {
                    val code = layoutCode(
                        content = content,
                        yStart = y,
                        contentIndex = contentIndex,
                        viewportWidth = maxTextWidth,
                        codePaint = codePaint,
                        chromePaint = codeChromePaint,
                        extra = codeExtra,
                        padPx = codePad,
                        headerHeight = dp(CODE_HEADER_HEIGHT_DP),
                        copyHitWidth = dp(CODE_COPY_HIT_DP),
                        copyText = codeLabels.copy,
                        syntaxTheme = syntaxTheme,
                    )
                    blocks.add(code)
                    y += code.heightPx
                    widest = max(widest, maxTextWidth)
                }
                is MessageContent.Image -> {
                    val boxHeight = imageBoxHeight(
                        media = content.media,
                        dimensions = content.dimensions,
                        widthPx = imageWidth,
                        fallbackPx = imageHeight,
                        maxPx = maxImageHeight,
                    )
                    val image = PreparedContentBlock.Image(
                        yOffsetPx = y,
                        heightPx = boxHeight,
                        contentIndex = contentIndex,
                        source = content.source,
                        widthPx = imageWidth,
                        leftInsetPx = imageInset,
                        media = content.media,
                    )
                    blocks.add(image)
                    y += boxHeight
                    widest = max(widest, imageWidth)
                }
                is MessageContent.Status -> {
                    val copy = buildString {
                        append(content.label)
                        content.detail?.takeIf { it.isNotBlank() }?.let {
                            append(" / ")
                            append(it)
                        }
                    }
                    val laid = splitText(
                        text = copy,
                        paint = if (content.tone == StatusTone.ERROR) errorStatusPaint else statusPaint,
                        width = maxTextWidth,
                        extra = statusExtra,
                        y = y,
                        contentIndex = contentIndex,
                        padPx = 0,
                    )
                    blocks.addAll(laid)
                    y += laid.sumOf { it.heightPx }
                    widest = max(widest, laid.maxOf { widthOf(it) })
                }
            }
            contentIndex++
        }

        // A retryable reply error keeps a row inside the card for its retry control.
        if (replyError && message.retryable) y += dp(REPLY_ERROR_RETRY_ROW_DP)
        var brief: PreparedBrief? = null
        if (briefTitle != null) {
            val contentBottom = y
            val cut = briefCut(blocks, briefContentTop, sp(AGENT_LINE_SP).toInt())
            val expandable = contentBottom > cut + 1
            val expanded = expandable && message.cardPayload == TimelineBlockKinds.TASK_BRIEF_EXPANDED
            val footer = if (!expandable) null else {
                val footerPaint = textPaint(ChatRole.SYSTEM, palette, sp(13f), uiSansAt(UiSansSemiBold))
                val label = if (expanded) briefLabels.showLess else briefLabels.showAll
                buildLayout(label, 0, label.length, footerPaint, maxTextWidth, lineSpacingExtra(footerPaint, sp(18f)))
            }
            val bottomGap = dp(BRIEF_BOTTOM_GAP_DP)
            val footerBlock = bubblePad + bottomGap + (footer?.let { it.height + dp(BRIEF_FOOTER_GAP_DP) } ?: 0)
            brief = PreparedBrief(
                title = briefTitle,
                titleTopPx = briefTitleTop,
                footer = footer,
                footerBlockPx = footerBlock,
                bottomGapPx = bottomGap,
                expanded = expanded,
                collapsedCellHeightPx = (if (expandable) cut else contentBottom) + footerBlock,
                expandedCellHeightPx = contentBottom + footerBlock,
            )
            y = (if (expanded || !expandable) contentBottom else cut) + footerBlock - bubblePad
        }
        val bubbleWidth = when {
            !drawBubble -> 0
            replyError || isBrief -> maxTextWidth + horizontalPadding * 2
            speakerBubble -> {
                (widest + horizontalPadding * 2).coerceIn(dp(USER_BUBBLE_MIN_WIDTH_DP), maxTextWidth + horizontalPadding * 2)
            }
            else -> widest + horizontalPadding * 2
        }
        // Display formulas sit in the middle of the column (the bubble's, when there is one).
        val column = if (drawBubble) bubbleWidth - horizontalPadding * 2 else maxTextWidth
        for (index in blocks.indices) {
            val block = blocks[index] as? PreparedContentBlock.Math ?: continue
            val inset = ((column - min(block.contentWidthPx, block.viewportWidthPx)) / 2).coerceAtLeast(0)
            if (block.leftInsetPx != inset) blocks[index] = block.copy(leftInsetPx = inset)
        }
        // A very short message is widened to the minimum bubble; its plain text sits in the middle.
        // Quotes and list markers keep their inset, which also places their bars and markers.
        val minWidthSlack = if (speakerBubble && drawBubble) (bubbleWidth - widest - horizontalPadding * 2) / 2 else 0
        if (minWidthSlack > 0 && blocks.all { it is PreparedContentBlock.Text && it.quoteDepth == 0 && it.marker == null }) {
            for (index in blocks.indices) {
                val block = blocks[index] as PreparedContentBlock.Text
                blocks[index] = block.copy(leftInsetPx = block.leftInsetPx + minWidthSlack)
            }
        }
        val bubbleTop = topMargin
        var cellHeight = y + bubblePad
        val bubbleHeight = if (drawBubble) cellHeight - bubbleTop else 0

        // 失败行尾的显式按钮。它们排在气泡外面，所以先把气泡高度定下来再加。
        val actionPaint = textPaint(
            role = ChatRole.SYSTEM,
            palette = palette,
            textSize = sp(13f),
            typeface = UiSansTypeface,
        )
        val actions = messageActionsFor(message, actionLabels).map { (action, label) ->
            PreparedMessageAction(
                action = action,
                label = label,
                widthPx = ceil(actionPaint.measureText(label)).toInt() + dp(ACTION_PAD_DP) * 2,
            )
        }
        var actionsTop = 0
        var actionsHeight = 0
        if (actions.isNotEmpty()) {
            actionsTop = cellHeight + dp(ACTION_GAP_DP)
            actionsHeight = dp(ACTION_HEIGHT_DP)
            cellHeight = actionsTop + actionsHeight
        }
        var failedNote: StaticLayout? = null
        var failedNoteTop = 0
        if (sendFailed) {
            val notePaint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
                color = palette.error
                textSize = sp(SEND_FAILED_NOTE_SP)
                typeface = UiSansTypeface
            }
            val note = actionLabels.sendFailedNote
            failedNote = buildLayout(note, 0, note.length, notePaint,
                ceil(Layout.getDesiredWidth(note, notePaint)).toInt(),
                lineSpacingExtra(notePaint, sp(SEND_FAILED_NOTE_LINE_SP)))
            failedNoteTop = cellHeight + dp(SEND_FAILED_NOTE_GAP_DP)
            cellHeight = failedNoteTop + failedNote.height
        }

        return PreparedChatMessage(
            message = message,
            cacheKey = cacheKey,
            contents = contents,
            blocks = blocks,
            bubbleWidthPx = bubbleWidth,
            bubbleHeightPx = bubbleHeight,
            bubbleTopPx = bubbleTop,
            cellHeightPx = cellHeight,
            horizontalPaddingPx = horizontalPadding,
            verticalPaddingPx = verticalPadding,
            sideMarginPx = sideMargin,
            topMarginPx = topMargin,
            cornerRadiusPx = when {
                speakerBubble -> BubbleTail.RADIUS_DP * density
                replyError || isBrief -> REPLY_ERROR_RADIUS_DP * density
                else -> 14f * density
            },
            drawBubble = drawBubble,
            imageCornerRadiusPx = 16f * density,
            imageSources = contents.filterIsInstance<MessageContent.Image>().map { it.source },
            actions = actions,
            actionsTopPx = actionsTop,
            actionsHeightPx = actionsHeight,
            contentAlpha = if (pendingSend) PENDING_ALPHA else 1f,
            sendFailedNote = failedNote,
            sendFailedNoteTopPx = failedNoteTop,
            brief = brief,
        )
    }

    /**
     * Where a closed brief cuts its text: after its first [BRIEF_LINES] lines, or before the first
     * block that is not text (a code block or table is not cut part way, unless it comes first).
     */
    private fun briefCut(blocks: List<PreparedContentBlock>, contentTop: Int, linePx: Int): Int {
        var lines = 0
        var bottom = contentTop
        for (block in blocks) {
            if (block !is PreparedContentBlock.Text) {
                return if (lines > 0) bottom else min(block.yOffsetPx + block.heightPx, block.yOffsetPx + linePx * BRIEF_LINES)
            }
            if (block.lineCount <= 0) continue
            val take = min(block.lineCount, BRIEF_LINES - lines)
            bottom = if (take == block.lineCount) {
                block.yOffsetPx + block.heightPx
            } else {
                block.yOffsetPx + block.padPx + block.layout.getLineBottom(take - 1)
            }
            lines += take
            if (lines >= BRIEF_LINES) return bottom
        }
        return bottom
    }


    /** Two-up cover tiles: 3 photos is 2+1, not three full-width billboards. */
    private fun layoutPhotoGrid(
        images: List<MessageContent.Image>,
        startIndex: Int,
        yStart: Int,
        columnWidth: Int,
        inset: Int,
        gap: Int,
    ): List<PreparedContentBlock.Image> {
        val columns = 2
        val tileWidth = ((columnWidth - gap) / columns).coerceAtLeast(1)
        val tileHeight = (tileWidth * 1.15f).toInt().coerceAtLeast(1)
        return images.mapIndexed { index, image ->
            val column = index % columns
            val row = index / columns
            PreparedContentBlock.Image(
                yOffsetPx = yStart + row * (tileHeight + gap),
                heightPx = tileHeight,
                contentIndex = startIndex + index,
                source = image.source,
                widthPx = tileWidth,
                leftInsetPx = inset + column * (tileWidth + gap),
            )
        }
    }

    /**
     * 代码块排版。
     *
     * 正文按自然宽排，**不折行**——一行 shell 命令被折成三行读起来比横着滚更糟。
     * 宽出去的部分交给横向滚动（`ChatMessageCell`），所以这里量的是内容真实宽度，
     * 只在病态长行上封顶，免得一段 base64 把 layout 宽度顶到几十万像素。
     *
     * header 从围栏一出现就在：`closed` 与否不改任何几何，收尾的 ``` 到达时块不会跳。
     */
    private fun layoutCode(
        content: MessageContent.Code,
        yStart: Int,
        contentIndex: Int,
        viewportWidth: Int,
        codePaint: TextPaint,
        chromePaint: TextPaint,
        extra: Float,
        padPx: Int,
        headerHeight: Int,
        copyHitWidth: Int,
        copyText: String,
        syntaxTheme: CodeSyntaxTheme,
    ): PreparedContentBlock.Code {
        val body = highlighted(content, syntaxTheme)
        val innerViewport = (viewportWidth - padPx * 2).coerceAtLeast(1)
        val natural = ceil(Layout.getDesiredWidth(body, codePaint)).toInt()
        val innerWidth = natural.coerceIn(innerViewport, innerViewport * CODE_MAX_WIDTH_FACTOR)
        val layout = buildLayout(body, 0, body.length, codePaint, innerWidth, extra)
        val languageLayout = content.language.takeIf { it.isNotBlank() }?.let { language ->
            val width = ceil(Layout.getDesiredWidth(language, chromePaint)).toInt()
            buildLayout(language, 0, language.length, chromePaint, width, 0f)
        }
        val copyWidth = ceil(Layout.getDesiredWidth(copyText, chromePaint)).toInt()
        return PreparedContentBlock.Code(
            yOffsetPx = yStart,
            heightPx = headerHeight + padPx * 2 + layout.height,
            contentIndex = contentIndex,
            layout = layout,
            headerHeightPx = headerHeight,
            padPx = padPx,
            contentWidthPx = innerWidth + padPx * 2,
            viewportWidthPx = viewportWidth,
            languageLayout = languageLayout,
            copyLayout = buildLayout(copyText, 0, copyText.length, chromePaint, copyWidth, 0f),
            copyHitWidthPx = max(copyHitWidth, copyWidth + padPx * 2),
            copyText = content.text,
        )
    }

    /**
     * 表格排版。列宽按自然宽取，单列封顶一个视口宽——三列各要 400px 就让它横着 1200px，
     * 挤扁列比横向滚动难读得多。半行（流式里还没到齐的一行）在解析层已经补齐到表头列数，
     * 这里不需要再猜。
     */
    private fun layoutTable(
        content: MessageContent.Table,
        yStart: Int,
        contentIndex: Int,
        viewportWidth: Int,
        bodyPaint: TextPaint,
        headerPaint: TextPaint,
        extra: Float,
        padH: Int,
        padV: Int,
        minColumn: Int,
        inlineColors: ChatPalette?,
        cellMath: (TextPaint) -> ((String, Boolean) -> Any?)? = { null },
    ): PreparedContentBlock.Table {
        val columns = max(content.header.size, content.rows.maxOfOrNull { it.size } ?: 0)
            .coerceAtLeast(1)
        val rows = ArrayList<List<MarkdownText>>(content.rows.size + 1)
        rows.add(padRow(content.header, columns))
        content.rows.forEach { rows.add(padRow(it, columns)) }
        val headMath = cellMath(headerPaint)
        val bodyMath = cellMath(bodyPaint)
        val spanned = rows.mapIndexed { index, row ->
            row.map { MarkdownSpans.spannable(it, inlineColors, if (index == 0) headMath else bodyMath) }
        }

        val cap = (viewportWidth - padH * 2).coerceAtLeast(minColumn)
        val columnWidths = IntArray(columns)
        spanned.forEachIndexed { rowIndex, row ->
            val paint = if (rowIndex == 0) headerPaint else bodyPaint
            row.forEachIndexed { column, cell ->
                val natural = ceil(Layout.getDesiredWidth(cell, paint)).toInt()
                columnWidths[column] = max(columnWidths[column], natural.coerceAtMost(cap))
            }
        }
        val columnEdges = ArrayList<Int>(columns + 1)
        var x = 0
        columnEdges.add(0)
        for (column in 0 until columns) {
            x += columnWidths[column].coerceAtLeast(minColumn) + padH * 2
            columnEdges.add(x)
        }

        val cells = ArrayList<PreparedTableCell>(columns * spanned.size)
        val rowEdges = ArrayList<Int>(spanned.size + 1)
        var top = 0
        rowEdges.add(0)
        spanned.forEachIndexed { rowIndex, row ->
            val paint = if (rowIndex == 0) headerPaint else bodyPaint
            val laid = row.mapIndexed { column, cell ->
                val alignment = alignmentOf(content.alignments.getOrNull(column))
                cell.getSpans(0, cell.length, InlineCodeSpan::class.java).forEach { it.alignment = alignment }
                buildLayout(
                    text = cell,
                    start = 0,
                    end = cell.length,
                    paint = paint,
                    width = columnEdges[column + 1] - columnEdges[column] - padH * 2,
                    lineSpacingExtra = extra,
                    alignment = alignment,
                )
            }
            val rowHeight = (laid.maxOfOrNull { it.height } ?: 0) + padV * 2
            laid.forEachIndexed { column, layout ->
                cells.add(
                    PreparedTableCell(
                        layout = layout,
                        leftPx = columnEdges[column] + padH,
                        topPx = top + padV,
                        row = rowIndex,
                        column = column,
                    ),
                )
            }
            top += rowHeight
            rowEdges.add(top)
        }

        return PreparedContentBlock.Table(
            yOffsetPx = yStart,
            heightPx = top,
            contentIndex = contentIndex,
            cells = cells,
            columnEdges = columnEdges,
            rowEdges = rowEdges,
            contentWidthPx = columnEdges.last(),
            viewportWidthPx = viewportWidth,
            leftInsetPx = 0,
        )
    }

    /**
     * 代码正文加上语法色。切分在 [CodeHighlighter] 里（纯 Kotlin、可测），这里只把
     * 区间换成 span——高亮不改任何几何，所以流式里加不加色，块的高度都一样。
     */
    private fun highlighted(
        content: MessageContent.Code,
        theme: CodeSyntaxTheme,
    ): CharSequence {
        val text = content.text.ifEmpty { " " }
        if (theme.colors.isEmpty()) return text
        val spans = CodeHighlighter.spans(content.language, content.text)
        if (spans.isEmpty()) return text
        val out = android.text.SpannableString(text)
        spans.forEach { span ->
            val color = theme.colorOf(span.token) ?: return@forEach
            val end = span.end.coerceAtMost(text.length)
            if (span.start >= end) return@forEach
            out.setSpan(
                android.text.style.ForegroundColorSpan(color),
                span.start,
                end,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
        return out
    }

    /**
     * 两个块之间留多少。
     *
     * 标题上下不对称——上面留得多、下面留得少，标题因此跟它领起的那段绑在一起，而不是浮在
     * 两段之间谁也不挨着。这条取自 rendered-editor 的 `--apple-heading-margin-top`
     * （0.6rem + 0.5em）对 `margin-bottom`（0.3em）。同一条列表里的相邻项贴得比段落近。
     */
    private fun gapBefore(
        previous: MessageContent,
        next: MessageContent,
        blockGap: Int,
        listGap: Int,
        headingTop: Int,
        headingBottom: Int,
    ): Int = when {
        next is MessageContent.ListItem && previous is MessageContent.ListItem -> listGap
        next is MessageContent.Heading -> headingTop
        previous is MessageContent.Heading -> headingBottom
        else -> blockGap
    }

    private fun padRow(cells: List<MarkdownText>, columns: Int): List<MarkdownText> =
        if (cells.size >= columns) cells else cells + List(columns - cells.size) { MarkdownText("") }

    private fun alignmentOf(align: TableAlign?): Layout.Alignment = when (align) {
        TableAlign.CENTER -> Layout.Alignment.ALIGN_CENTER
        TableAlign.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
        else -> Layout.Alignment.ALIGN_NORMAL
    }

    private fun reusablePrefix(
        previous: PreparedChatMessage?,
        contents: List<MessageContent>,
        cacheKey: String,
    ): Map<Int, List<PreparedContentBlock>> {
        if (previous == null) return emptyMap()
        // Viewport / type / theme live in the cache key after the last ':' group;
        // streaming keys always differ on the text hash, so compare geometry bits only.
        if (!sameGeometry(previous.cacheKey, cacheKey)) return emptyMap()
        val shared = sharedContentPrefix(previous.contents, contents)
        if (shared == 0) return emptyMap()
        return previous.blocks
            .filter { it.contentIndex < shared }
            .groupBy { it.contentIndex }
    }

    private fun sameGeometry(oldKey: String, newKey: String): Boolean {
        val oldTail = oldKey.substringAfterLast(':', "")
        // key ends with previousRole:viewport:fontScale:darkTheme — compare from role onward
        val oldGeo = oldKey.split(':').takeLast(4)
        val newGeo = newKey.split(':').takeLast(4)
        return oldGeo == newGeo && oldTail.isNotEmpty()
    }

    private fun shift(block: PreparedContentBlock, dy: Int): PreparedContentBlock {
        if (dy == 0) return block
        return when (block) {
            is PreparedContentBlock.Text -> block.copy(yOffsetPx = block.yOffsetPx + dy)
            is PreparedContentBlock.Image -> block.copy(yOffsetPx = block.yOffsetPx + dy)
            is PreparedContentBlock.Code -> block.copy(yOffsetPx = block.yOffsetPx + dy)
            is PreparedContentBlock.Rule -> block.copy(yOffsetPx = block.yOffsetPx + dy)
            is PreparedContentBlock.Table -> block.copy(yOffsetPx = block.yOffsetPx + dy)
            is PreparedContentBlock.Math -> block.copy(yOffsetPx = block.yOffsetPx + dy)
        }
    }

    private fun widthOf(block: PreparedContentBlock): Int = when (block) {
        is PreparedContentBlock.Text -> {
            var widest = 0f
            for (line in 0 until block.layout.lineCount) {
                widest = max(widest, block.layout.getLineWidth(line))
            }
            ceil(widest).toInt() + block.padPx * 2 + block.leftInsetPx
        }
        is PreparedContentBlock.Image -> block.widthPx
        is PreparedContentBlock.Rule -> block.widthPx + block.leftInsetPx
        // 代码块和表格再宽也只占一个视口，多出来的部分是横向滚动的事，不该把气泡撑开。
        is PreparedContentBlock.Code -> block.viewportWidthPx
        is PreparedContentBlock.Table -> min(block.contentWidthPx, block.viewportWidthPx) + block.leftInsetPx
        is PreparedContentBlock.Math -> min(block.contentWidthPx, block.viewportWidthPx)
    }

    private fun splitText(
        text: CharSequence,
        paint: TextPaint,
        width: Int,
        extra: Float,
        y: Int,
        contentIndex: Int,
        padPx: Int,
        leftInsetPx: Int = 0,
        quoteDepth: Int = 0,
        marker: PreparedListMarker? = null,
    ): List<PreparedContentBlock.Text> {
        val full = buildLayout(text, 0, text.length, paint, width, extra)
        val padHeight = padPx * 2
        if (full.lineCount <= LINES_PER_BLOCK) {
            return listOf(
                PreparedContentBlock.Text(
                    yOffsetPx = y,
                    heightPx = full.height + padHeight,
                    contentIndex = contentIndex,
                    layout = full,
                    firstLine = 0,
                    lineCount = full.lineCount,
                    padPx = padPx,
                    leftInsetPx = leftInsetPx,
                    quoteDepth = quoteDepth,
                    marker = marker,
                ),
            )
        }
        val out = ArrayList<PreparedContentBlock.Text>()
        var line = 0
        var offset = 0
        while (line < full.lineCount) {
            val endLine = min(line + LINES_PER_BLOCK, full.lineCount)
            val start = full.getLineStart(line)
            var end = full.getLineEnd(endLine - 1)
            if (end > start && text[end - 1] == '\n') end--
            val block = buildLayout(text, start, end, paint, width, extra)
            val topPad = if (out.isEmpty()) padPx else 0
            val bottomPad = if (endLine == full.lineCount) padPx else 0
            out.add(
                PreparedContentBlock.Text(
                    yOffsetPx = y + offset,
                    heightPx = block.height + topPad + bottomPad,
                    contentIndex = contentIndex,
                    layout = block,
                    firstLine = line,
                    lineCount = endLine - line,
                    padPx = padPx,
                    leftInsetPx = leftInsetPx,
                    quoteDepth = quoteDepth,
                    marker = marker.takeIf { out.isEmpty() },
                ),
            )
            offset += block.height + topPad + bottomPad
            line = endLine
        }
        return out
    }

    private fun textPaint(
        role: ChatRole,
        palette: ChatPalette,
        textSize: Float,
        typeface: Typeface,
        alpha: Float = 1f,
    ): TextPaint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
        val base = messageTextColor(role, palette)
        // 位运算而不是 Color.argb()：那也是 JVM 测试里的桩。
        color = if (alpha >= 1f) {
            base
        } else {
            val dimmedAlpha = (((base ushr 24) and 0xFF) * alpha).toInt().coerceIn(0, 255)
            (dimmedAlpha shl 24) or (base and 0x00FFFFFF)
        }
        this.textSize = textSize
        this.typeface = typeface
    }

    private fun lineSpacingExtra(paint: TextPaint, lineHeight: Float): Float {
        val metrics = paint.fontMetricsInt
        return max(0f, lineHeight - (metrics.descent - metrics.ascent))
    }

    private fun buildLayout(
        text: CharSequence,
        start: Int,
        end: Int,
        paint: TextPaint,
        width: Int,
        lineSpacingExtra: Float,
        alignment: Layout.Alignment = Layout.Alignment.ALIGN_NORMAL,
    ): StaticLayout = StaticLayout.Builder.obtain(text, start, end.coerceAtLeast(start), paint, width.coerceAtLeast(1))
        .setAlignment(alignment)
        .setBreakStrategy(LineBreaker.BREAK_STRATEGY_SIMPLE)
        .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
        .setIncludePad(false)
        .setLineSpacing(lineSpacingExtra, 1f)
        .build()

    private fun buildKey(
        message: ChatMessage,
        previousRole: ChatRole?,
        viewportWidthPx: Int,
        fontScale: Float,
        darkTheme: Boolean,
        palette: ChatPalette,
    ): String = buildString {
        append(message.id)
        append(':')
        append(message.turnId)
        append(':')
        append(message.text.hashCode())
        append(':')
        append(message.status)
        append(':')
        append(message.statusDetail.hashCode())
        append(':')
        append(message.retryable)
        append(':')
        append(message.cardKind)
        append(':')
        append(message.cardPayload.hashCode())
        append(':')
        append(message.attachment.hashCode())
        append(':')
        append(message.imageSource.hashCode())
        append(':')
        append(message.imageDimensions)
        append(':')
        append(message.role)
        append(':')
        append(previousRole)
        append(':')
        append(viewportWidthPx)
        append(':')
        append(fontScale)
        append(':')
        append(darkTheme)
        append(':')
        append(palette.hashCode())
    }

    companion object {
        private const val LINES_PER_BLOCK = 10
        /** Chat content margin (DESIGN §3.1). */
        const val CHAT_SIDE_MARGIN_DP = 28f
        /** Consecutive messages from one side, and a change of side. */
        private const val SAME_SPEAKER_GAP_DP = 6f
        private const val SPEAKER_CHANGE_GAP_DP = 28f
        /** Message body: 16sp, with a looser line for the assistant than inside the user bubble. */
        private const val BODY_TEXT_SP = 16f
        private const val AGENT_LINE_SP = 27f
        private const val USER_LINE_SP = 22f
        private const val USER_BUBBLE_PAD_H_DP = 13f
        private const val USER_BUBBLE_PAD_V_DP = 10f
        /** Marks the cache key of a row laid out with its tail; see [withTails]. */
        private const val TAIL_KEY = ":tail"
        private const val USER_BUBBLE_MIN_WIDTH_DP = 50f
        private const val USER_BUBBLE_OPPOSITE_DP = 42f
        private const val SEND_FAILED_NOTE_SP = 12f
        private const val SEND_FAILED_NOTE_LINE_SP = 16f
        private const val SEND_FAILED_NOTE_GAP_DP = 6f
        private const val REPLY_ERROR_RADIUS_DP = 12f
        private const val REPLY_ERROR_RETRY_ROW_DP = 28f
        /** Lines a closed task brief shows. */
        internal const val BRIEF_LINES = 3
        private const val BRIEF_TITLE_GAP_DP = 6f
        private const val BRIEF_FOOTER_GAP_DP = 8f
        /** Added to the gap a message keeps from the one before, so the card does not crowd it. */
        private const val BRIEF_BOTTOM_GAP_DP = 12f
        /** The failure mark beside an unsent bubble, its touch target, and its gap to the bubble. */
        internal const val SEND_FAILED_ICON_DP = 20f
        internal const val SEND_FAILED_HIT_DP = 44f
        internal const val SEND_FAILED_ICON_GAP_DP = 8f
        /** 块与块之间。10dp 太挤——正文、代码、表格叠在一起时读不出段落边界。 */
        private const val BLOCK_GAP_DP = 17f

        /** 同一条列表里相邻两项：比段落近，但不能贴死。 */
        private const val LIST_ITEM_GAP_DP = 7f

        /** 标题上面留得多、下面留得少，标题才跟它领起的内容是一体的。 */
        private const val HEADING_GAP_TOP_DP = 28f
        private const val HEADING_GAP_BOTTOM_DP = 10f
        /** The box for a picture whose shape is not known until it decodes. */
        private const val IMAGE_BOX_HEIGHT_DP = 240f

        /**
         * How tall a picture of known shape may get.
         *
         * A full-page screenshot is 3:1 or worse; reserving its true height
         * would hand one message most of a screen and bury the sentence after
         * it. Above this the tile is cover-fitted — the aspect ratio is still
         * honoured for everything that fits, which is what stops the layout
         * jumping when the bytes arrive.
         */
        private const val IMAGE_MAX_HEIGHT_DP = 420f

        /**
         * The reserved box for one picture.
         *
         * `media.width`/`height` are the **displayed** size (`shared/media.md`),
         * already through Core's one reading of the orientation, so this is the
         * shape the decoded bitmap will have — not the shape of the stored file.
         * Explicit local dimensions take precedence. Without either source of dimensions,
         * gallery and markdown pictures keep the fixed placeholder.
         */
        internal fun imageBoxHeight(
            media: CoreMediaRef?,
            widthPx: Int,
            fallbackPx: Int,
            maxPx: Int,
            dimensions: ImageDimensions? = null,
        ): Int {
            val sourceWidth = dimensions?.widthPx ?: media?.widthPx ?: return fallbackPx
            val sourceHeight = dimensions?.heightPx ?: media?.heightPx ?: return fallbackPx
            if (sourceWidth <= 0 || sourceHeight <= 0) return fallbackPx
            val scaled = widthPx.toLong() * sourceHeight / sourceWidth
            return scaled.coerceIn(1L, maxPx.toLong()).toInt()
        }
        private const val ACTION_HEIGHT_DP = 32f
        private const val ACTION_GAP_DP = 8f
        private const val ACTION_PAD_DP = 14f
        private const val PENDING_ALPHA = 0.55f

        /** 列表项目符号，按嵌套层级取。第四层起复用第一层——再深就不是给人读的了。 */
        private val BULLETS = charArrayOf('\u2022', '\u25E6', '\u25AA', '\u2023')

        /** 引用最多画三条左边线。 */
        private const val MAX_QUOTE_DEPTH = 3

        /**
         * h1–h6 相对正文的倍率。按 26/22/17/15/13/11 相对
         * 13px 正文，四舍五入到我们这边的 16sp 基准；h5 与正文同号，h6 略小。
         */
        private val HEADING_SCALE = floatArrayOf(1.6f, 1.4f, 1.2f, 1.1f, 1f, 0.9f)

        /** 标题行高。比正文的 1.55 紧——大字号不需要那么松。 */
        private const val HEADING_LINE_HEIGHT = 1.3f

        private const val LIST_INDENT_DP = 22f

        /** 标号栏和正文之间的空。 */
        private const val LIST_MARKER_GAP_DP = 6f

        /** 代码块内边距。左右留白比 12dp 宽一档，代码不贴着圆角。 */
        private const val CODE_PAD_DP = 16f

        private const val TABLE_CELL_PAD_H_DP = 14f
        private const val TABLE_CELL_PAD_V_DP = 9f

        /** 代码块 header：语言在左，复制在右。 */
        private const val CODE_HEADER_HEIGHT_DP = 34f

        /** 复制的命中区：48dp，指头够得着就行。 */
        private const val CODE_COPY_HIT_DP = 48f

        /**
         * 单行再长也只排到视口的六倍宽。一段没有空格的 base64 否则会把 layout 宽度
         * 顶到几十万像素——横向滚动条也就没有意义了，不如让它折行。
         */
        private const val CODE_MAX_WIDTH_FACTOR = 6

        /**
         * Formulas are set a little larger than the text around them: the math faces have a
         * smaller x-height than the body face, and at the same size read as a size smaller.
         */
        private const val MATH_SCALE = 1.1f
        /** An inline formula too wide for its column is set smaller, but not below this. */
        private const val MATH_MIN_FIT = 0.75f
        /** Room for italic overhang and accents, which draw a little outside the formula's box. */
        private const val MATH_INLINE_PAD_DP = 1f
        private const val MATH_PAD_H_DP = 2f
        private const val MATH_PAD_V_DP = 4f
        /** A display formula scrolls up to this many columns wide; past it, it shows its source. */
        private const val MATH_MAX_WIDTH_FACTOR = 6

        /** 按钮之间的间距。排版和绘制共用一个来源。 */
        internal const val ACTION_SPACING_DP = 8f

        fun cardImages(
            message: ChatMessage,
            jsonParser: JsonParser = OrgJsonParser,
        ): List<String> {
            if (message.cardKind != TimelineBlockKinds.PHOTO_GRID) {
                return listOfNotNull(message.imageSource)
            }
            val parsed = PhotoGridCardPayload.images(message.cardPayload, jsonParser).orEmpty()
            return parsed.ifEmpty { listOfNotNull(message.imageSource) }
        }
    }
}

/**
 * 哪些行该带按钮。
 *
 * 用户消息没有按钮：没送出去（FAILED）时，气泡旁的失败标记和下方提示打开「重试 / 删除」。助手行失败时
 * 「放弃」永远在，「重试」只在 Core 说过可以安全重放时出现。成功和进行中的行
 * 一个按钮都没有——整格轻点重发的老行为正是靠这个消失的。
 */
internal fun messageActionsFor(
    message: ChatMessage,
    labels: MessageActionLabels,
): List<Pair<MessageAction, String>> = when {
    // An unsent user message has no buttons; its failure mark and note open the options.
    message.role != ChatRole.AGENT -> emptyList()
    message.cardKind == TimelineBlockKinds.REPLY_ERROR -> emptyList()
    message.status == MessageStatus.FAILED ->
        buildList {
            if (message.retryable) add(MessageAction.RETRY to labels.retry)
            add(MessageAction.DISCARD to labels.discard)
        }
    else -> emptyList()
}

/**
 * 两次内容从头一致的块数。增量预排就是靠它决定「哪些块可以原样搬过来」：
 * 变了的那一块之前的照旧复用，中间某一块变了也不会让前面十几段一起重新 measure。
 */
internal fun sharedContentPrefix(
    previous: List<MessageContent>,
    next: List<MessageContent>,
): Int {
    val limit = min(previous.size, next.size)
    var shared = 0
    while (shared < limit && previous[shared] == next[shared]) shared++
    return shared
}

internal fun messageTextColor(role: ChatRole, palette: ChatPalette): Int = when (role) {
    // User bubbles are the brand colour in both themes, so their foreground stays white.
    ChatRole.USER -> palette.userText
    ChatRole.AGENT -> palette.agentText
    ChatRole.SYSTEM -> palette.secondaryText
}
