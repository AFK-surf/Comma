package surf.comma.android.chat.live

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.graphics.text.LineBreaker
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import android.util.TypedValue
import android.view.ContentInfo
import android.view.Gravity
import android.view.OnReceiveContentListener
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.AnimationUtils
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardHeights
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.AgentQuestion
import surf.comma.android.conversation.DraftAttachmentStatus
import surf.comma.android.conversation.QuestionChoice
import surf.comma.android.conversation.QuestionStatus
import surf.comma.android.media.MediaGraph
import surf.comma.android.media.ViewerImage
import surf.comma.android.settings.filledButton
import surf.comma.android.ui.composer.ComposerModel
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * An Agent's question under its message ([LiveRowKinds.QUESTION]). While it is open the person picks, writes an
 * answer of their own (with images) or skips; whatever is sent closes it into a one-line receipt, and so does a
 * message written in the chat instead. Picking, sending and closing change the card at once, without motion.
 */
internal class QuestionCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.QUESTION

    /** A rough height for a page that does not measure the card; the pages that show it use [QuestionCardLayout]. */
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float {
        val question = QuestionCardPayload.decode(message.cardPayload)?.question ?: return 0f
        if (!question.state.status.answerable) return 72f
        return 16f + 24f + (if (question.multiSelect) 20f else 0f) + 12f + question.choices.size * 54f +
            (if (question.allowOther) 54f else 0f) + 12f + 48f + 8f
    }

    override fun create(context: Context): View = QuestionCardView(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as QuestionCardView).bind(item)
    override fun release(view: View) = (view as QuestionCardView).release()
}

/**
 * One text style of the card, laid out the same way by the view and by [QuestionCardLayout]: the first line is the
 * face's own height, each further line [lineHeightPx] more. Fallback line spacing is off, so Chinese lines keep the
 * same rhythm as Latin ones. Safe to measure with from a background thread.
 */
internal class QuestionText(val sizePx: Float, val lineHeightPx: Int, val typeface: Typeface) {
    private val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).also {
        it.typeface = typeface
        it.textSize = sizePx
    }
    val fontHeight: Int = paint.getFontMetricsInt(null)

    fun applyTo(view: TextView, simple: Boolean = false) {
        view.typeface = typeface
        view.setTextSize(TypedValue.COMPLEX_UNIT_PX, sizePx)
        view.includeFontPadding = false
        view.isFallbackLineSpacing = false
        view.letterSpacing = 0f
        view.breakStrategy = if (simple) LineBreaker.BREAK_STRATEGY_SIMPLE else LineBreaker.BREAK_STRATEGY_HIGH_QUALITY
        view.hyphenationFrequency = Layout.HYPHENATION_FREQUENCY_NONE
        view.lineHeight = lineHeightPx
    }

    fun lines(text: CharSequence, widthPx: Int, simple: Boolean = false): Int = synchronized(paint) {
        if (text.isEmpty()) return 1
        val width = widthPx.coerceAtLeast(1)
        StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
            .setIncludePad(false)
            .setUseLineSpacingFromFallbacks(false)
            .setBreakStrategy(if (simple) LineBreaker.BREAK_STRATEGY_SIMPLE else LineBreaker.BREAK_STRATEGY_HIGH_QUALITY)
            .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
            .build().lineCount.coerceAtLeast(1)
    }

    fun height(lines: Int): Int = fontHeight + (lines - 1).coerceAtLeast(0) * lineHeightPx

    fun height(text: CharSequence, widthPx: Int, simple: Boolean = false): Int = height(lines(text, widthPx, simple))

    fun width(text: CharSequence): Int = synchronized(paint) { ceil(Layout.getDesiredWidth(text, paint)).toInt() }
}

/** The card's type, geometry and colours, shared by the view and [QuestionCardLayout] so they cannot disagree. */
internal class QuestionCardStyle(private val context: Context) {
    private val metrics = context.resources.displayMetrics
    val density: Float = metrics.density

    fun dp(value: Float): Int = (value * density).roundToInt()

    private fun type(size: Float, line: Float, weight: Int): QuestionText {
        val scale = DesignTypography.chatScale()
        return QuestionText(
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size * scale, metrics),
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, line * scale, metrics).roundToInt(),
            DesignFonts.inter(context, weight),
        )
    }

    val prompt = type(17f, 24f, DesignFonts.semibold)
    val meta = type(13f, 18f, DesignFonts.regular)
    val label = type(16f, 22f, DesignFonts.medium)
    val description = type(14f, 20f, DesignFonts.regular)
    val pill = type(12f, 16f, DesignFonts.medium)
    val fieldText = type(16f, 22f, DesignFonts.regular)
    val note = type(13f, 18f, DesignFonts.regular)
    val error = type(14f, 20f, DesignFonts.regular)
    val smallButton = type(14f, 20f, DesignFonts.medium)
    val receiptPrompt = type(13f, 18f, DesignFonts.regular)
    val receiptAnswer = type(16f, 22f, DesignFonts.medium)
    val receiptMuted = type(16f, 22f, DesignFonts.regular)

    /** Drawn lines are one physical pixel (DESIGN §4). */
    val hairline = 1
    val cardRadius = dp(20f).toFloat()
    val headPad = dp(16f)
    val headGap = dp(2f)
    val listTop = dp(12f)
    val listSide = dp(8f)
    val rowGap = dp(6f)
    val rowRadius = dp(12f).toFloat()
    val rowPadH = dp(12f)
    val rowPadV = dp(14f)
    val rowMin = dp(48f)
    val indicator = dp(20f)
    val indicatorGap = dp(12f)
    val labelGap = dp(8f)
    val descGap = dp(2f)
    val pillPadH = dp(6f)
    val pillPadV = dp(2f)
    val otherPadV = dp(8f)
    val otherPadEnd = dp(6f)
    val otherLine = dp(32f)
    val otherLabelGap = dp(8f)
    val imageButton = dp(32f)
    val thumb = dp(56f)
    val thumbRadius = dp(10f).toFloat()
    val thumbGap = dp(8f)
    val thumbsTop = dp(8f)
    val thumbsBottom = dp(4f)
    val errorMargin = dp(8f)
    val errorPadStart = dp(12f)
    val errorPad = dp(4f)
    val errorGap = dp(8f)
    val smallButtonH = dp(32f)
    val smallButtonPad = dp(12f)
    val noteTop = dp(8f)
    val noteSide = dp(16f)
    val footTop = dp(12f)
    val footInset = dp(8f)
    val buttonH = dp(48f)
    val buttonGap = dp(8f)
    val receiptRadius = dp(16f).toFloat()
    val receiptPadV = dp(12f)
    val receiptPadStart = dp(12f)
    val receiptPadEnd = dp(16f)
    val receiptIcon = dp(24f)
    val receiptGlyph = dp(14f)
    val receiptGap = dp(12f)
    val receiptLineGap = dp(2f)

    val cardFill = context.getColor(R.color.token_bg_secondary)
    val border = context.getColor(R.color.token_border_primary)
    val borderSecondary = context.getColor(R.color.token_border_secondary)
    /** A picked row turns gray; only its radio or box carries the brand colour. */
    val picked = context.getColor(R.color.token_bg_quaternary)
    val ring = context.getColor(R.color.token_fg_quaternary)
    val brand = context.getColor(R.color.token_bg_brand_solid)
    val onBrand = Color.WHITE
    val bgPrimary = context.getColor(R.color.token_bg_primary)
    val bgTertiary = context.getColor(R.color.token_bg_tertiary)
    val fgPrimary = context.getColor(R.color.token_fg_primary)
    val textPrimary = context.getColor(R.color.token_text_primary)
    val textSecondary = context.getColor(R.color.token_text_secondary)
    val textTertiary = context.getColor(R.color.token_text_tertiary)
    val placeholder = context.getColor(R.color.token_text_placeholder)
    val errorFill = context.getColor(R.color.token_bg_error_primary)
    val errorText = context.getColor(R.color.token_text_error_primary)

    /** The field's padding, so one line of it stands exactly [otherLine] tall. */
    val fieldPadTop = ((otherLine - fieldText.fontHeight) / 2).coerceAtLeast(0)
    val fieldPadBottom = (otherLine - fieldText.fontHeight - fieldPadTop).coerceAtLeast(0)
    val pillHeight = pill.fontHeight + pillPadV * 2
    /** The pill sits on the label's first line. */
    val pillTop = ((label.fontHeight - pillHeight) / 2).coerceAtLeast(0)

    fun receiptIconTop(answer: QuestionText?): Int =
        ((receiptPrompt.fontHeight + (answer?.let { receiptLineGap + it.fontHeight } ?: 0) - receiptIcon) / 2).coerceAtLeast(0)

    fun rowBackground(fill: Int, radius: Float = rowRadius, stroke: Int = border) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = radius
        setColor(fill)
        setStroke(hairline, stroke)
    }
}

/** The card's words, read once. */
internal class QuestionCardStrings(context: Context) {
    val recommended: String = context.getString(R.string.chat_question_recommended)
    val multi: String = context.getString(R.string.chat_question_multi)
    val other: String = context.getString(R.string.chat_question_other)
    val placeholder: String = context.getString(R.string.chat_question_other_placeholder)
    val addImage: String = context.getString(R.string.chat_question_add_image)
    val uploading: String = context.getString(R.string.chat_question_uploading)
    val skip: String = context.getString(R.string.chat_question_skip)
    val send: String = context.getString(R.string.chat_question_send)
    val failed: String = context.getString(R.string.chat_question_failed)
    val retry: String = context.getString(R.string.chat_question_retry)
    val receipt = QuestionReceiptLabels(
        sending = context.getString(R.string.chat_question_sending),
        skipped = context.getString(R.string.chat_question_skipped),
        replied = context.getString(R.string.chat_question_replied),
        replaced = context.getString(R.string.chat_question_replaced),
    )
    val notes: Map<QuestionNote, String> = mapOf(
        QuestionNote.PICK_ONE to context.getString(R.string.chat_question_pick_one),
        QuestionNote.PICK_ANY to context.getString(R.string.chat_question_pick_any),
        QuestionNote.OTHER_EMPTY to context.getString(R.string.chat_question_other_empty),
        QuestionNote.UPLOAD_FAILED to context.getString(R.string.chat_question_upload_failed),
        QuestionNote.WAIT_UPLOAD to context.getString(R.string.chat_question_wait_upload),
    )
    val removeImage: (String) -> String = { name -> context.getString(R.string.chat_question_remove_image, name) }
}

/**
 * Question card heights, measured ahead of time from the payload with the card's own type, so the list knows each
 * row's height before the view loads. An open card is measured as it first shows (its own picks and words grow it
 * afterwards); [interactive] false is a page that cannot answer, which shows every card as its receipt.
 * Background-thread safe: it reads only immutable values.
 */
internal class QuestionCardLayout(context: Context, private val interactive: Boolean) : ChatCardHeights {
    private val style = QuestionCardStyle(context)
    private val strings = QuestionCardStrings(context)

    override fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int? {
        if (message.cardKind != LiveRowKinds.QUESTION) return null
        val payload = QuestionCardPayload.decode(message.cardPayload) ?: return 0
        val width = (rowWidthPx - sideMarginPx * 2).coerceAtLeast(1)
        return if (interactive && payload.question.state.status.answerable) formHeight(payload, width)
        else receiptHeight(payload.question, width)
    }

    fun formHeight(payload: QuestionCardPayload, width: Int): Int = with(style) {
        val question = payload.question
        val form = QuestionForm(question)
        val head = width - headPad * 2
        var height = headPad + prompt.height(question.prompt, head)
        if (question.multiSelect) height += headGap + meta.height(strings.multi, head)
        height += listTop
        val rowWidth = width - listSide * 2
        val rows = question.choices.map { optionHeight(it, rowWidth) } +
            if (question.allowOther) listOf(otherHeight(form.other, payload.imageCount, rowWidth)) else emptyList()
        height += rows.sum() + rowGap * (rows.size - 1).coerceAtLeast(0)
        if (question.state.status == QuestionStatus.FAILED) height += errorMargin + errorHeight(width)
        height + footTop + buttonH + footInset
    }

    private fun optionHeight(choice: QuestionChoice, rowWidth: Int): Int = with(style) {
        val column = rowWidth - rowPadH * 2 - indicator - indicatorGap
        val pillWidth = if (choice.recommended) pill.width(strings.recommended) + pillPadH * 2 + labelGap else 0
        val labelHeight = label.height(choice.label, column - pillWidth)
        val head = if (choice.recommended) max(labelHeight, pillTop + pillHeight) else labelHeight
        val described = choice.description?.let { descGap + description.height(it, column) } ?: 0
        max(rowMin, rowPadV * 2 + max(indicator, head + described))
    }

    private fun otherHeight(other: String, images: Int, rowWidth: Int): Int = with(style) {
        val fieldWidth = rowWidth - rowPadH - otherPadEnd - indicator - indicatorGap - label.width(strings.other) -
            otherLabelGap - imageButton
        val lines = min(fieldText.lines(other.ifEmpty { strings.placeholder }, fieldWidth, simple = true), FIELD_MAX_LINES)
        val line = max(otherLine, fieldPadTop + fieldText.height(lines) + fieldPadBottom)
        otherPadV * 2 + line + thumbsHeight(images, rowWidth - rowPadH - otherPadEnd - indicator - indicatorGap)
    }

    private fun thumbsHeight(count: Int, stripWidth: Int): Int = with(style) {
        if (count <= 0) return 0
        val perRow = thumbsPerRow(stripWidth, thumb, thumbGap)
        val rows = (count + perRow - 1) / perRow
        thumbsTop + rows * thumb + (rows - 1) * thumbGap + thumbsBottom
    }

    private fun errorHeight(width: Int): Int = with(style) {
        val retry = smallButton.width(strings.retry) + smallButtonPad * 2
        val text = width - errorMargin * 2 - errorPadStart - errorPad - retry - errorGap
        errorPad * 2 + max(smallButtonH, error.height(strings.failed, text))
    }

    fun receiptHeight(question: AgentQuestion, width: Int): Int = with(style) {
        val line = questionReceiptLine(question, strings.receipt)
        val column = width - receiptPadStart - receiptPadEnd - receiptIcon - receiptGap
        val answer = if (line.isEmpty()) null else receiptAnswerStyle(question)
        val text = receiptPrompt.height(question.prompt, column) + (answer?.let { receiptLineGap + it.height(line, column) } ?: 0)
        receiptPadV * 2 + max(receiptIconTop(answer) + receiptIcon, text)
    }

    private fun receiptAnswerStyle(question: AgentQuestion) = if (question.given) style.receiptAnswer else style.receiptMuted
}

/** The answer itself is the receipt's line: it is being sent, or it was. */
private val AgentQuestion.given: Boolean
    get() = state.status == QuestionStatus.ANSWERED || state.status == QuestionStatus.SENDING

/** The other answer's field grows to this many lines, then scrolls inside itself. */
private const val FIELD_MAX_LINES = 6

internal fun thumbsPerRow(width: Int, size: Int, gap: Int): Int = max(1, (width + gap) / (size + gap))

@SuppressLint("ViewConstructor")
internal class QuestionCardView(context: Context) : FrameLayout(context) {
    private val style = QuestionCardStyle(context)
    private val strings = QuestionCardStrings(context)

    /** The page's way to answer; the adapter gives it. None: every card shows as its receipt. */
    var hostOf: () -> QuestionCardHost? = { null }

    // ---- The open card ----
    private val prompt = text(style.prompt, style.textPrimary)
    private val meta = text(style.meta, style.textTertiary).apply { text = strings.multi }
    private val list = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(style.listSide, style.listTop, style.listSide, 0)
    }
    private val options = ArrayList<OptionRow>()
    private val otherIndicator = ChoiceIndicator(context, style)
    private val otherPick = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        isClickable = true
        addView(FrameLayout(context).apply {
            addView(otherIndicator, LayoutParams(style.indicator, style.indicator, Gravity.CENTER))
        }, LinearLayout.LayoutParams(style.indicator, style.otherLine))
        addView(text(style.label, style.textPrimary).apply {
            text = strings.other
            gravity = Gravity.CENTER_VERTICAL
            maxLines = 1
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, style.otherLine).apply {
            marginStart = style.indicatorGap
        })
        accessibilityDelegate = checkable { otherIndicator.multiple to otherIndicator.checked }
    }
    /** The other answer: what the person writes when no choice fits. */
    val otherField = EditText(context).apply {
        style.fieldText.applyTo(this, simple = true)
        background = null
        minHeight = 0
        minimumHeight = 0
        setPadding(0, style.fieldPadTop, 0, style.fieldPadBottom)
        gravity = Gravity.TOP or Gravity.START
        setTextColor(style.textPrimary)
        setHintTextColor(style.placeholder)
        hint = strings.placeholder
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = FIELD_MAX_LINES
        isVerticalScrollBarEnabled = false
    }
    private val imageButton = ImageView(context).apply {
        setImageResource(R.drawable.ic_composer_photo)
        setColorFilter(style.textTertiary)
        val pad = style.dp(6f)
        setPadding(pad, pad, pad, pad)
        contentDescription = strings.addImage
        isClickable = true
    }
    private val thumbs = ThumbStrip(context, style.thumb, style.thumbGap)
    private val otherRow = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(style.rowPadH, style.otherPadV, style.otherPadEnd, style.otherPadV)
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            addView(otherPick, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, style.otherLine))
            addView(otherField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = style.otherLabelGap
            })
            addView(imageButton, LinearLayout.LayoutParams(style.imageButton, style.imageButton))
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(thumbs, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginStart = style.indicator + style.indicatorGap
            topMargin = style.thumbsTop
            bottomMargin = style.thumbsBottom
        })
    }
    private val errorText = text(style.error, style.textSecondary).apply { text = strings.failed }
    private val retry = text(style.smallButton, style.textPrimary).apply {
        text = strings.retry
        gravity = Gravity.CENTER
        maxLines = 1
        setPadding(style.smallButtonPad, 0, style.smallButtonPad, 0)
        background = style.rowBackground(style.picked, style.dp(8f).toFloat(), style.picked)
        isClickable = true
    }
    private val errorBox = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(style.errorPadStart, style.errorPad, style.errorPad, style.errorPad)
        background = style.rowBackground(style.bgPrimary, style.dp(10f).toFloat())
        addView(errorText, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        addView(retry, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, style.smallButtonH).apply {
            marginStart = style.errorGap
        })
    }
    private val note = text(style.note, style.textSecondary).apply { setPadding(style.noteSide, 0, style.noteSide, 0) }
    val skip = context.filledButton(strings.skip, R.color.token_bg_quaternary, R.color.token_text_primary)
    val send = context.filledButton(strings.send, R.color.token_bg_brand_solid, null)
    private val form = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply {
            cornerRadius = style.cardRadius
            setColor(style.cardFill)
            setStroke(style.hairline, style.border)
        }
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(style.headPad, style.headPad, style.headPad, 0)
            addView(prompt, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(meta, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = style.headGap
            })
        })
        addView(list, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        addView(errorBox, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = style.errorMargin
            marginStart = style.errorMargin
            marginEnd = style.errorMargin
        })
        addView(note, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = style.noteTop
        })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(style.footInset, style.footTop, style.footInset, style.footInset)
            addView(skip, LinearLayout.LayoutParams(0, style.buttonH, 1f))
            addView(send, LinearLayout.LayoutParams(0, style.buttonH, 2f).apply { marginStart = style.buttonGap })
        })
    }

    // ---- The receipt ----
    private val receiptGlyph = ImageView(context)
    private val receiptSpinner = QuestionSpinner(context, style.textTertiary, style.dp(1.5f).toFloat())
    private val receiptIcon = FrameLayout(context).apply {
        addView(receiptGlyph, LayoutParams(style.receiptGlyph, style.receiptGlyph, Gravity.CENTER))
        addView(receiptSpinner, LayoutParams(style.receiptGlyph, style.receiptGlyph, Gravity.CENTER))
    }
    private val receiptPrompt = text(style.receiptPrompt, style.textSecondary)
    private val receiptAnswer = TextView(context)
    private val receipt = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.TOP
        setPadding(style.receiptPadStart, style.receiptPadV, style.receiptPadEnd, style.receiptPadV)
        background = style.rowBackground(style.cardFill, style.receiptRadius, style.borderSecondary)
        addView(receiptIcon, LinearLayout.LayoutParams(style.receiptIcon, style.receiptIcon))
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(receiptPrompt, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            addView(receiptAnswer, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = style.receiptLineGap
            })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = style.receiptGap })
    }

    private var item: PreparedChatMessage? = null
    private var payload: QuestionCardPayload? = null
    private var shownForm: QuestionForm? = null
    /** Set while the card writes the field itself, so its listeners do not take it for typing. */
    private var binding = false
    private var loads: CoroutineScope? = null

    init {
        addView(form)
        addView(receipt)
        form.visibility = GONE
        receipt.visibility = GONE
        otherRow.background = style.rowBackground(Color.TRANSPARENT)
        otherPick.setOnClickListener {
            val state = shownForm ?: return@setOnClickListener
            state.pickOther()
            render()
            if (state.otherOn) focusField()
        }
        otherField.doAfterTextChanged { text ->
            if (binding) return@doAfterTextChanged
            shownForm?.write(text?.toString().orEmpty()) ?: return@doAfterTextChanged
            render()
        }
        otherField.setOnFocusChangeListener { _, focused ->
            if (!focused || binding) return@setOnFocusChangeListener
            shownForm?.focusOther() ?: return@setOnFocusChangeListener
            render()
        }
        otherField.setOnReceiveContentListener(arrayOf("image/*"), OnReceiveContentListener { _, content ->
            val question = shownForm?.question?.messageId
            val host = hostOf()
            if (question == null || host == null || !content.clip.description.hasMimeType("image/*")) return@OnReceiveContentListener content
            val clip = content.clip
            val items = (0 until clip.itemCount).map(clip::getItemAt)
            val uris = items.mapNotNull { it.uri }
            if (uris.isEmpty()) return@OnReceiveContentListener content
            host.addImages(question, uris)
            // Anything but the images goes on to the field as usual.
            val rest = items.filter { it.uri == null }
            if (rest.isEmpty()) null
            else ContentInfo.Builder(content)
                .setClip(ClipData(clip.description, rest.first()).apply { rest.drop(1).forEach(::addItem) })
                .build()
        })
        imageButton.setOnClickListener {
            val question = shownForm?.question?.messageId ?: return@setOnClickListener
            val held = payload?.imageCount ?: 0
            hostOf()?.pickImages(question, (ComposerModel.MAX_ATTACHMENTS - held).coerceAtLeast(0))
        }
        send.setOnClickListener { submit() }
        retry.setOnClickListener { submit() }
        skip.setOnClickListener {
            val state = shownForm ?: return@setOnClickListener
            dispatch(state, QuestionCardAnswer.SKIP)
        }
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        show(QuestionCardPayload.decode(item.message.cardPayload))
        requestLayout()
    }

    /** Shows [next]: the open card when this page can answer it, its receipt otherwise. */
    fun show(next: QuestionCardPayload?) {
        val previous = payload
        payload = next
        if (next == null) {
            shownForm = null
            form.visibility = GONE
            receipt.visibility = GONE
            return
        }
        val question = next.question
        val host = hostOf()
        if (previous?.question?.messageId != question.messageId) letGoOfField()
        if (host == null || !question.state.status.answerable) {
            host?.forms?.drop(question.messageId)
            shownForm = null
            letGoOfField()
            showReceipt(question)
            return
        }
        val state = host.forms.of(question)
        shownForm = state
        val before = previous?.question
        if (before == null || before.messageId != question.messageId || before.choices != question.choices ||
            before.multiSelect != question.multiSelect || before.allowOther != question.allowOther || options.isEmpty() && question.choices.isNotEmpty()) {
            build(question)
        }
        prompt.text = question.prompt
        meta.isVisible = question.multiSelect
        state.images(next.imageCount)
        thumbs.show(next)
        receipt.visibility = GONE
        form.visibility = VISIBLE
        // An answer asked for while its images uploaded goes once they have.
        if (state.waitingForUploads && !next.uploading) submit() else render()
    }

    /** The rows for [question]'s choices, and its other answer when it takes one. */
    private fun build(question: AgentQuestion) {
        list.removeAllViews()
        options.clear()
        question.choices.forEachIndexed { index, choice ->
            val row = OptionRow(context, style, strings, choice, question.multiSelect)
            row.setOnClickListener {
                shownForm?.choose(choice.id) ?: return@setOnClickListener
                render()
            }
            options += row
            list.addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                if (index > 0) topMargin = style.rowGap
            })
        }
        otherIndicator.multiple = question.multiSelect
        if (question.allowOther) {
            list.addView(otherRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                topMargin = style.rowGap
            })
        }
    }

    /** Puts the open card's picks, words and notes on screen. Changes are instant. */
    private fun render() {
        val current = payload ?: return
        val state = shownForm ?: return
        options.forEach { it.checked = it.choice.id in state.picks }
        otherIndicator.checked = state.otherOn
        otherRow.background = style.rowBackground(if (state.otherOn) style.picked else Color.TRANSPARENT)
        if (otherField.text.toString() != state.other) {
            binding = true
            otherField.setText(state.other)
            otherField.setSelection(otherField.length())
            binding = false
        }
        val failed = (state.question.state.status == QuestionStatus.FAILED || state.refused) && !state.sending
        errorBox.isVisible = failed
        val said = state.note?.let(strings.notes::getValue)
        note.text = said.orEmpty()
        note.isVisible = said != null
        thumbs.isVisible = current.imageCount > 0
        for (button in listOf(skip, send, retry)) {
            button.isEnabled = !state.sending
            button.alpha = if (state.sending) DISABLED_ALPHA else 1f
        }
    }

    private fun submit() {
        val state = shownForm ?: return
        val current = payload ?: return
        if (state.sending) return
        val answer = state.submit(current.uploading, current.uploadFailed)
        if (answer == null) {
            render()
            return
        }
        dispatch(state, answer)
    }

    private fun dispatch(state: QuestionForm, answer: QuestionCardAnswer) {
        val host = hostOf() ?: return
        if (state.sending) return
        state.sending = true
        state.refused = false
        host.answer(state.question.messageId, answer) { taken ->
            state.sending = false
            if (!taken) state.refused = true
            if (shownForm === state) render()
        }
        render()
    }

    private fun showReceipt(question: AgentQuestion) {
        form.visibility = GONE
        receipt.visibility = VISIBLE
        receiptPrompt.text = question.prompt
        val status = question.state.status
        val line = questionReceiptLine(question, strings.receipt)
        val answerStyle = if (question.given) style.receiptAnswer else style.receiptMuted
        answerStyle.applyTo(receiptAnswer)
        receiptAnswer.setTextColor(if (question.given) style.textPrimary else style.textSecondary)
        receiptAnswer.text = if (status == QuestionStatus.SENDING) {
            // "· Sending" after the answer is quieter than the answer itself.
            val tail = line.lastIndexOf(strings.receipt.sending).let { at -> if (at > 0) line.lastIndexOf(" · ", at) else at }
            SpannableString(line).apply {
                if (tail >= 0) setSpan(ForegroundColorSpan(style.textTertiary), tail, line.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        } else line
        receiptAnswer.isVisible = line.isNotEmpty()
        receiptIcon.layoutParams = (receiptIcon.layoutParams as LinearLayout.LayoutParams).apply {
            topMargin = style.receiptIconTop(if (line.isEmpty()) null else answerStyle)
        }
        val answered = status == QuestionStatus.ANSWERED
        receiptIcon.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (answered) style.brand else style.bgTertiary)
        }
        receiptSpinner.isVisible = status == QuestionStatus.SENDING
        receiptGlyph.isVisible = status != QuestionStatus.SENDING
        receiptGlyph.setImageResource(when (status) {
            QuestionStatus.ANSWERED -> R.drawable.ic_composer_check
            QuestionStatus.SKIPPED -> R.drawable.ic_settings_chevron
            QuestionStatus.REPLACED -> R.drawable.ic_arrow_rotate_cw
            else -> R.drawable.ic_history_reply
        })
        receiptGlyph.setColorFilter(if (answered) style.onBrand else style.textTertiary)
        receipt.contentDescription = listOf(question.prompt, line).filter { it.isNotEmpty() }.joinToString("\n")
    }

    /** The row of listed choice [id], for tests. */
    internal fun choiceRow(id: String): View? = options.firstOrNull { it.choice.id == id }

    /** What the open card says under its choices, or null; for tests. */
    internal val noteShown: CharSequence? get() = note.text.takeIf { form.isVisible && note.isVisible }

    /** The open card says its answer was not sent; for tests. */
    internal val failedShown: Boolean get() = form.isVisible && errorBox.isVisible

    /** The receipt's answer line when the card is closed, or null while it is open; for tests. */
    internal val receiptLine: CharSequence? get() = if (receipt.isVisible) receiptAnswer.text.takeIf { receiptAnswer.isVisible } ?: "" else null

    private fun focusField() {
        otherField.requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(otherField, 0)
    }

    /** The card shows another question, or closed: its field lets go of the keyboard. */
    private fun letGoOfField() {
        if (!otherField.hasFocus()) return
        otherField.clearFocus()
        context.getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(otherField.windowToken, 0)
    }

    fun release() {
        loads?.cancel()
        loads = null
        thumbs.clear()
    }

    override fun onDetachedFromWindow() {
        loads?.cancel()
        loads = null
        super.onDetachedFromWindow()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        thumbs.loadAll()
    }

    private fun imageScope(): CoroutineScope =
        loads ?: CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).also { loads = it }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val current = item
        val side = current?.sideMarginPx ?: 0
        val top = current?.topMarginPx ?: 0
        val content = shown()
        if (content == null) {
            setMeasuredDimension(width, top)
            return
        }
        content.measure(MeasureSpec.makeMeasureSpec((width - side * 2).coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        setMeasuredDimension(width, top + content.measuredHeight)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val content = shown() ?: return
        val left = item?.sideMarginPx ?: 0
        val top = item?.topMarginPx ?: 0
        content.layout(left, top, left + content.measuredWidth, top + content.measuredHeight)
    }

    private fun shown(): View? = when {
        form.isVisible -> form
        receipt.isVisible -> receipt
        else -> null
    }

    private fun text(type: QuestionText, color: Int) = TextView(context).apply {
        type.applyTo(this)
        setTextColor(color)
    }

    /** The other answer's images: the core's rows, then the ones still being made ready. */
    @SuppressLint("ViewConstructor")
    private inner class ThumbStrip(context: Context, private val size: Int, private val gap: Int) : ViewGroup(context) {
        private val tiles = LinkedHashMap<String, ThumbTile>()

        fun show(payload: QuestionCardPayload) {
            val question = payload.question.messageId
            val wanted = payload.images.map { it.id to it } + (0 until payload.preparing).map { "$PREPARING$it" to null }
            val keep = wanted.mapTo(HashSet()) { it.first }
            tiles.keys.filter { it !in keep }.forEach { id -> tiles.remove(id)?.let { it.cancel(); removeView(it) } }
            removeAllViews()
            for ((id, image) in wanted) {
                val tile = tiles.getOrPut(id) { ThumbTile(context) }
                tile.show(question, image)
                addView(tile)
            }
        }

        fun loadAll() = tiles.values.forEach(ThumbTile::load)

        fun clear() {
            tiles.values.forEach(ThumbTile::cancel)
            tiles.clear()
            removeAllViews()
        }

        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val width = MeasureSpec.getSize(widthMeasureSpec)
            val exact = MeasureSpec.makeMeasureSpec(size, MeasureSpec.EXACTLY)
            for (index in 0 until childCount) getChildAt(index).measure(exact, exact)
            val perRow = thumbsPerRow(width, size, gap)
            val rows = (childCount + perRow - 1) / perRow
            setMeasuredDimension(width, if (rows == 0) 0 else rows * size + (rows - 1) * gap)
        }

        override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
            val perRow = thumbsPerRow(r - l, size, gap)
            for (index in 0 until childCount) {
                val x = (index % perRow) * (size + gap)
                val y = (index / perRow) * (size + gap)
                getChildAt(index).layout(x, y, x + size, y + size)
            }
        }
    }

    /** One image: its preview, a turning ring while it uploads, a way to retry a failed upload, and remove. */
    @SuppressLint("ViewConstructor")
    private inner class ThumbTile(context: Context) : FrameLayout(context) {
        private val image = ImageView(context).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = GradientDrawable().apply {
                cornerRadius = style.thumbRadius
                setColor(style.bgTertiary)
            }
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) =
                    outline.setRoundRect(0, 0, view.width, view.height, style.thumbRadius)
            }
        }
        private val failedCover = ImageView(context).apply {
            setImageResource(R.drawable.ic_composer_retry)
            setColorFilter(style.errorText)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            val pad = style.dp(18f)
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                cornerRadius = style.thumbRadius
                setColor(style.errorFill)
            }
        }
        private val spinner = QuestionSpinner(context, style.textTertiary, style.dp(2f).toFloat())
        private val remove = ImageView(context).apply {
            setImageResource(R.drawable.ic_composer_close)
            setColorFilter(style.cardFill)
            val pad = style.dp(3f)
            setPadding(pad, pad, pad, pad)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(style.fgPrimary)
            }
        }
        private var question: String? = null
        private var shown: QuestionImage? = null
        private var preview: String? = null
        private var loaded: String? = null
        private var job: Job? = null

        init {
            addView(image, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            addView(failedCover, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            addView(spinner, LayoutParams(style.dp(20f), style.dp(20f), Gravity.CENTER))
            addView(remove, LayoutParams(style.dp(20f), style.dp(20f), Gravity.TOP or Gravity.END).apply {
                topMargin = style.dp(4f)
                marginEnd = style.dp(4f)
            })
            remove.setOnClickListener {
                val id = shown?.id ?: return@setOnClickListener
                hostOf()?.removeImage(question ?: return@setOnClickListener, id)
            }
            setOnClickListener {
                val failed = shown?.takeIf { it.status == DraftAttachmentStatus.FAILED } ?: return@setOnClickListener
                hostOf()?.retryImage(question ?: return@setOnClickListener, failed.id)
            }
        }

        /** [value] null is an image still being made ready on this device. */
        fun show(questionMessageId: String, value: QuestionImage?) {
            question = questionMessageId
            shown = value
            val status = value?.status ?: DraftAttachmentStatus.UPLOADING
            spinner.isVisible = status == DraftAttachmentStatus.UPLOADING
            failedCover.isVisible = status == DraftAttachmentStatus.FAILED
            remove.isVisible = value != null
            image.alpha = if (status == DraftAttachmentStatus.UPLOADING) UPLOADING_ALPHA else 1f
            contentDescription = when (status) {
                DraftAttachmentStatus.FAILED -> strings.retry
                DraftAttachmentStatus.UPLOADING -> strings.uploading
                DraftAttachmentStatus.UPLOADED -> value?.name
            }
            remove.contentDescription = value?.let { strings.removeImage(it.name) }
            if (value?.preview != preview) {
                preview = value?.preview
                if (preview == null) {
                    cancel()
                    image.setImageDrawable(null)
                }
                load()
            }
        }

        fun load() {
            val uri = preview ?: return
            if (!isAttachedToWindow && !this@QuestionCardView.isAttachedToWindow) return
            if (loaded == uri || job?.isActive == true) return
            job = imageScope().launch {
                try {
                    val drawable = MediaGraph.get(context).images()
                        .load(ViewerImage.Local(uri.toUri(), "image/*", null), PREVIEW_EDGE, PREVIEW_EDGE)
                    if (preview == uri) {
                        image.setImageDrawable(drawable)
                        loaded = uri
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // The tile stays plain: the image still goes with the answer.
                }
            }
        }

        fun cancel() {
            job?.cancel()
            job = null
            loaded = null
        }
    }

    companion object {
        private const val DISABLED_ALPHA = 0.5f
        private const val UPLOADING_ALPHA = 0.45f
        private const val PREVIEW_EDGE = 512
        private const val PREPARING = "preparing#"

        /**
         * Whether ([x], [y]) in [list]'s coordinates lands on a question card's field: a tap there keeps the
         * keyboard, where a tap elsewhere on the conversation puts it away.
         */
        fun isOnField(list: ViewGroup, x: Float, y: Float): Boolean {
            val bounds = Rect()
            for (index in 0 until list.childCount) {
                val card = list.getChildAt(index) as? QuestionCardView ?: continue
                if (!card.otherField.isShown) continue
                card.otherField.getDrawingRect(bounds)
                list.offsetDescendantRectToMyCoords(card.otherField, bounds)
                if (bounds.contains(x.toInt(), y.toInt())) return true
            }
            return false
        }

        /** A tap elsewhere on the conversation: a card's field lets go of its focus with the keyboard. */
        fun releaseFields(list: ViewGroup) {
            for (index in 0 until list.childCount) {
                val card = list.getChildAt(index) as? QuestionCardView ?: continue
                if (card.otherField.hasFocus()) card.otherField.clearFocus()
            }
        }
    }
}

/** One listed choice: its radio or box, its label (with a pill when recommended) and its description. */
@SuppressLint("ViewConstructor")
private class OptionRow(
    context: Context,
    private val style: QuestionCardStyle,
    strings: QuestionCardStrings,
    val choice: QuestionChoice,
    private val multiple: Boolean,
) : LinearLayout(context) {
    private val indicator = ChoiceIndicator(context, style).also { it.multiple = multiple }

    var checked = false
        set(value) {
            if (field == value && background != null) return
            field = value
            indicator.checked = value
            background = style.rowBackground(if (value) style.picked else Color.TRANSPARENT)
        }

    init {
        orientation = HORIZONTAL
        gravity = Gravity.TOP
        isClickable = true
        minimumHeight = style.rowMin
        setPadding(style.rowPadH, style.rowPadV, style.rowPadH, style.rowPadV)
        addView(indicator, LayoutParams(style.indicator, style.indicator))
        val column = LinearLayout(context).apply {
            orientation = VERTICAL
            addView(LinearLayout(context).apply {
                orientation = HORIZONTAL
                gravity = Gravity.TOP
                addView(TextView(context).apply {
                    style.label.applyTo(this)
                    setTextColor(style.textPrimary)
                    text = choice.label
                }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                if (choice.recommended) addView(TextView(context).apply {
                    style.pill.applyTo(this)
                    setTextColor(style.brand)
                    text = strings.recommended
                    maxLines = 1
                    setPadding(style.pillPadH, style.pillPadV, style.pillPadH, style.pillPadV)
                    background = GradientDrawable().apply {
                        cornerRadius = style.pillHeight / 2f
                        setColor(style.brand and 0x00FFFFFF or (PILL_FILL_ALPHA shl 24))
                    }
                }, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                    marginStart = style.labelGap
                    topMargin = style.pillTop
                })
            }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            choice.description?.let { said ->
                addView(TextView(context).apply {
                    style.description.applyTo(this)
                    setTextColor(style.textSecondary)
                    text = said
                }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = style.descGap })
            }
        }
        addView(column, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = style.indicatorGap })
        checked = false
        accessibilityDelegate = checkable { multiple to checked }
    }

    private companion object {
        /** The recommended pill is the brand colour over a light wash of itself. */
        const val PILL_FILL_ALPHA = 0x1F
    }
}

/** Reads a row as a radio button or a check box, checked as [state] says (multiple to checked). */
private fun checkable(state: () -> Pair<Boolean, Boolean>) = object : View.AccessibilityDelegate() {
    override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(host, info)
        val (multiple, checked) = state()
        info.className = if (multiple) CheckBox::class.java.name else RadioButton::class.java.name
        info.isCheckable = true
        info.isChecked = checked
    }
}

/** A radio (a ring, or the brand colour with a white dot) or a box (a rounded ring, or the brand colour with a check). */
@SuppressLint("ViewConstructor")
private class ChoiceIndicator(context: Context, private val look: QuestionCardStyle) : View(context) {
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).also {
        it.style = Paint.Style.STROKE
        it.strokeWidth = look.dp(1.5f).toFloat()
        it.color = look.ring
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).also { it.color = look.brand }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).also { it.color = look.onBrand }
    private val check = ContextCompat.getDrawable(context, R.drawable.ic_composer_check)!!.mutate().also { it.setTint(look.onBrand) }
    private val bounds = RectF()

    var multiple = false
        set(value) {
            if (field != value) { field = value; invalidate() }
        }
    var checked = false
        set(value) {
            if (field != value) { field = value; invalidate() }
        }

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onDraw(canvas: Canvas) {
        val inset = ringPaint.strokeWidth / 2f
        val size = width.toFloat()
        if (!multiple) {
            val radius = size / 2f
            if (checked) {
                canvas.drawCircle(radius, radius, radius, fill)
                canvas.drawCircle(radius, radius, look.dp(4f).toFloat(), dot)
            } else {
                canvas.drawCircle(radius, radius, radius - inset, ringPaint)
            }
            return
        }
        val corner = look.dp(6f).toFloat()
        if (checked) {
            bounds.set(0f, 0f, size, height.toFloat())
            canvas.drawRoundRect(bounds, corner, corner, fill)
            check.setBounds(0, 0, width, height)
            check.draw(canvas)
        } else {
            bounds.set(inset, inset, size - inset, height - inset)
            canvas.drawRoundRect(bounds, corner, corner, ringPaint)
        }
    }
}

/** A turning arc while something is on its way; still when the system has animations off. */
@SuppressLint("ViewConstructor")
private class QuestionSpinner(context: Context, color: Int, strokePx: Float) : View(context) {
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = strokePx
        this.color = color
        alpha = TRACK_ALPHA
    }
    private val arc = Paint(track).apply {
        alpha = 0xFF
        strokeCap = Paint.Cap.ROUND
    }
    private val bounds = RectF()

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onDraw(canvas: Canvas) {
        val inset = arc.strokeWidth / 2f
        bounds.set(inset, inset, width - inset, height - inset)
        canvas.drawOval(bounds, track)
        val turning = ValueAnimator.areAnimatorsEnabled()
        val start = if (turning) 360f * (AnimationUtils.currentAnimationTimeMillis() % TURN_MS) / TURN_MS - 90f else -90f
        canvas.drawArc(bounds, start, SWEEP, false, arc)
        if (turning && isShown) postInvalidateOnAnimation()
    }

    private companion object {
        const val TURN_MS = 900L
        const val SWEEP = 90f
        const val TRACK_ALPHA = 0x40
    }
}
