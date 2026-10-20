package surf.comma.android.auth

import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.ClipboardManager
import android.content.ClipDescription
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextPaint
import android.text.TextWatcher
import android.util.TypedValue
import android.view.ActionMode
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.core.graphics.withScale
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.dynamicanimation.animation.FloatPropertyCompat
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography

/**
 * Six digit cells backed by one invisible editor. A single editor keeps the keyboard, paste,
 * autofill and keyboard code suggestions working as one field; the cells only draw its state.
 */
@SuppressLint("ViewConstructor")
internal class CodeInputView(context: Context) : ViewGroup(context) {
    /** Every change the person makes, including paste and autofill. */
    var onCodeChanged: ((String) -> Unit)? = null
    /** Fired once each time the code becomes six digits through input. */
    var onCodeComplete: ((String) -> Unit)? = null
    /** The rejected code has been emptied; not an edit, so an error message stays. */
    var onCodeReset: (() -> Unit)? = null

    internal val editor = CodeEditText(context)
    internal val cells = List(CodeText.LENGTH) { CodeCellView(context) }
    private val gap = dp(8)
    private val maxCell = dp(56)
    private val minHeight = dp(48)
    private var programmatic = false
    private var inserted: CharSequence? = null
    private var last = ""
    private var invalid = false
    private var clearAfterShake: Runnable? = null
    private val shakes = cells.map { DesignSpring(it, DynamicAnimation.TRANSLATION_X, DesignMotion.springShake) }

    /** While a code is being verified the digits stay put but remain focused, so the keyboard stays up. */
    var locked = false
        set(value) {
            if (field == value) return
            field = value
            cells.forEach { it.setDimmed(value) }
        }

    val code: String get() = editor.text.toString()

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onSingleTapUp(e: MotionEvent): Boolean {
            performClick()
            focusCell(cellAt(e.x), showKeyboard = true)
            return true
        }
        override fun onLongPress(e: MotionEvent) {
            if (!locked) showPasteMenu()
        }
    })

    private val watcher = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence, start: Int, count: Int, after: Int) = Unit
        override fun onTextChanged(s: CharSequence, start: Int, before: Int, count: Int) {
            if (!programmatic) inserted = if (count > 1) s.subSequence(start, start + count).toString() else null
        }
        override fun afterTextChanged(s: Editable) {
            if (programmatic) return
            val raw = s.toString()
            val chunk = inserted?.let(CodeText::extract)
            inserted = null
            val whole = chunk != null && chunk.length == CodeText.LENGTH
            val next = if (whole) chunk!! else CodeText.normalize(raw)
            if (next != raw) {
                val caret = if (whole) next.length
                else CodeText.normalize(raw.take(editor.selectionEnd.coerceAtLeast(0))).length
                programmatic = true
                s.replace(0, s.length, next)
                editor.setSelection(caret.coerceIn(0, next.length))
                programmatic = false
            }
            edited(next)
        }
    }

    init {
        clipChildren = false
        clipToPadding = false
        cells.forEach {
            it.importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            addView(it)
        }
        editor.apply {
            id = R.id.auth_code
            inputType = InputType.TYPE_CLASS_NUMBER
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            // The code never enters saved view state.
            isSaveEnabled = false
            background = null
            alpha = 0f
            isCursorVisible = false
            isLongClickable = false
            setTextColor(Color.TRANSPARENT)
            setHintTextColor(Color.TRANSPARENT)
            hint = context.getString(R.string.auth_code)
            setAutofillHints(AUTOFILL_EMAIL_OTP, AUTOFILL_SMS_OTP)
            importantForAutofill = IMPORTANT_FOR_AUTOFILL_YES
            filters = arrayOf(InputFilter { source, _, _, dest, start, end ->
                // Input waits for the error shake, which empties the cells when it settles.
                if ((locked || clearAfterShake != null) && !programmatic) dest.subSequence(start, end) else source
            })
            addTextChangedListener(watcher)
            onSelection = { syncActive() }
            onPaste = { pasteFromClipboard() }
            setOnFocusChangeListener { _, _ -> syncActive() }
        }
        addView(editor)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val cell = ((width - gap * (CodeText.LENGTH - 1)) / CodeText.LENGTH).coerceIn(0, maxCell)
        val height = maxOf(cell, minHeight)
        val exact = MeasureSpec.makeMeasureSpec(cell, MeasureSpec.EXACTLY)
        cells.forEach { it.measure(exact, exact) }
        editor.measure(MeasureSpec.makeMeasureSpec(rowWidth(cell), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY))
        setMeasuredDimension(width, resolveSize(height, heightMeasureSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val cell = cells[0].measuredWidth
        val start = (width - rowWidth(cell)) / 2
        val top = (height - cell) / 2
        val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
        cells.forEachIndexed { index, view ->
            val slot = if (rtl) CodeText.LENGTH - 1 - index else index
            val left = start + slot * (cell + gap)
            view.layout(left, top, left + cell, top + cell)
        }
        editor.layout(start, 0, start + rowWidth(cell), height)
    }

    private fun rowWidth(cell: Int) = cell * CodeText.LENGTH + gap * (CodeText.LENGTH - 1)

    // Taps choose a cell; the editor underneath never sees them, so no text handles appear.
    override fun onInterceptTouchEvent(ev: MotionEvent) = true

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean = gestures.onTouchEvent(event)

    override fun performClick(): Boolean = super.performClick()

    /** Moves the caret to [index]. A filled cell is selected, so typing replaces its digit. */
    fun focusCell(index: Int, showKeyboard: Boolean) {
        editor.requestFocus()
        editor.setSelection(index.coerceIn(0, code.length))
        if (showKeyboard) {
            context.getSystemService(InputMethodManager::class.java).showSoftInput(editor, 0)
        }
        syncActive()
    }

    /** Programmatic reset; does not report a change or a completion. */
    fun clear() {
        clearAfterShake?.let(::removeCallbacks)
        clearAfterShake = null
        setText("")
        setInvalid(false)
    }

    /** The wrong code: shake the row once, then empty it and return to the first cell. */
    fun reject() {
        setInvalid(true)
        performHapticFeedback(HapticFeedbackConstants.REJECT)
        clearAfterShake?.let(::removeCallbacks)
        val reset = Runnable {
            clearAfterShake = null
            setText("")
            if (editor.isFocused) focusCell(0, showKeyboard = false)
            onCodeReset?.invoke()
        }
        if (!ValueAnimator.areAnimatorsEnabled()) {
            reset.run()
            return
        }
        clearAfterShake = reset
        val amplitude = dp(SHAKE_AMPLITUDE_DP).toFloat()
        shakes.forEachIndexed { index, spring ->
            val start = Runnable {
                spring.cancel()
                cells[index].translationX = amplitude
                spring.animateTo(0f, 0f)
            }
            if (index == 0) start.run() else postDelayed(start, index * SHAKE_STAGGER_MS)
        }
        // Clear once the last cell has visibly settled (under half a dp of motion).
        postDelayed(reset, SHAKE_SETTLE_MS)
    }

    /** Replaces the whole code with the one found in [text]; used by paste. */
    fun paste(text: CharSequence) {
        if (locked || clearAfterShake != null) return
        val next = CodeText.extract(text)
        if (next.isEmpty()) return
        editor.requestFocus()
        replaceText(next)
        edited(next)
    }

    private fun pasteFromClipboard() {
        val clip = context.getSystemService(ClipboardManager::class.java).primaryClip ?: return
        if (clip.itemCount == 0) return
        paste(clip.getItemAt(0).coerceToText(context))
    }

    private fun showPasteMenu() {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        if (clipboard.primaryClipDescription?.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) != true &&
            clipboard.primaryClipDescription?.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML) != true) return
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        startActionMode(object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                menu.add(Menu.NONE, android.R.id.paste, Menu.NONE, android.R.string.paste)
                return true
            }
            override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false
            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
                if (item.itemId == android.R.id.paste) pasteFromClipboard()
                mode.finish()
                return true
            }
            override fun onDestroyActionMode(mode: ActionMode) = Unit
            override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
                outRect.set(editor.left, cells[0].top, editor.right, cells[0].bottom)
            }
        }, ActionMode.TYPE_FLOATING)
    }

    private fun replaceText(value: String) {
        programmatic = true
        editor.setText(value)
        editor.setSelection(value.length)
        programmatic = false
    }

    private fun setText(value: String) {
        replaceText(value)
        last = value
        cells.forEachIndexed { index, cell -> cell.setDigit(value.getOrNull(index), pop = false) }
        syncActive()
    }

    private fun setInvalid(value: Boolean) {
        invalid = value
        cells.forEach { it.setInvalid(value) }
    }

    private fun cellAt(x: Float): Int {
        val index = cells.indices.minBy { kotlin.math.abs(x - (cells[it].left + cells[it].right) / 2f) }
        return index
    }

    private fun syncActive() {
        val start = editor.selectionStart
        val active = if (editor.isFocused && start in 0 until CodeText.LENGTH) start else -1
        cells.forEachIndexed { index, cell -> cell.setActive(index == active) }
    }

    private fun edited(next: String) {
        val previous = last
        if (next == previous) return
        last = next
        if (invalid) setInvalid(false)
        cells.forEachIndexed { index, cell ->
            val digit = next.getOrNull(index)
            cell.setDigit(digit, pop = digit != null && digit != previous.getOrNull(index))
        }
        syncActive()
        onCodeChanged?.invoke(next)
        if (next.length == CodeText.LENGTH) onCodeComplete?.invoke(next)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        // Autofill hint values for one-time codes delivered by email or SMS.
        private const val AUTOFILL_EMAIL_OTP = "emailOTPCode"
        private const val AUTOFILL_SMS_OTP = "smsOTPCode"
        private const val SHAKE_AMPLITUDE_DP = 12
        private const val SHAKE_STAGGER_MS = 8L
        // springShake decays as e^(-ζ·ω·t) with ζ·ω ≈ 9/s: 12dp falls below 0.5dp after ~350ms.
        private const val SHAKE_SETTLE_MS = 420L
    }
}

/** The invisible editor behind the cells. */
@SuppressLint("AppCompatCustomView")
internal class CodeEditText(context: Context) : EditText(context) {
    var onSelection: (() -> Unit)? = null
    var onPaste: (() -> Unit)? = null

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        // A caret resting before a digit selects that digit, so the cell reads as selected.
        val text = text
        if (text != null && selStart == selEnd && selStart < text.length) {
            setSelection(selStart, selStart + 1)
            return
        }
        onSelection?.invoke()
    }

    override fun onTextContextMenuItem(id: Int): Boolean {
        if (id == android.R.id.paste || id == android.R.id.pasteAsPlainText) {
            onPaste?.invoke()
            return true
        }
        return super.onTextContextMenuItem(id)
    }
}

/** One digit cell: outline, digit and caret. Scale and shake are the view's own properties. */
internal class CodeCellView(context: Context) : View(context) {
    var digit: Char? = null
        private set
    var active = false
        private set
    var invalid = false
        private set
    private var dimmed = false
    private var digitScale = 1f
    private var digitAlpha = 1f
    private var caretOn = true
    private val density = resources.displayMetrics.density
    private val radius = 10 * density
    private val strokeWidth = 1 * density
    private val bounds = RectF()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_quaternary) }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = this@CodeCellView.strokeWidth
        color = strokeTarget()
    }
    private val caret = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = context.getColor(R.color.token_bg_brand_solid) }
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = DesignFonts.inter(context, DesignFonts.medium)
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP,
            DesignTypography.size(DesignTypography.Level.TITLE2).sp, resources.displayMetrics)
        textAlign = Paint.Align.CENTER
        color = context.getColor(R.color.token_text_primary)
    }
    private val growX = DesignSpring(this, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val growY = DesignSpring(this, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    private val digitSpring = DesignSpring(this, DigitScale, DesignMotion.springScale, 0.002f)
    private var strokeAnimator: ValueAnimator? = null
    private var alphaAnimator: ValueAnimator? = null
    private val blink = object : Runnable {
        override fun run() {
            caretOn = !caretOn
            invalidate()
            postDelayed(this, CARET_BLINK_MS / 2)
        }
    }

    fun setDigit(value: Char?, pop: Boolean) {
        if (digit == value && !pop) return
        digit = value
        alphaAnimator?.cancel()
        if (pop && value != null && ValueAnimator.areAnimatorsEnabled()) {
            digitSpring.cancel()
            digitScale = POP_FROM
            digitSpring.animateTo(1f)
            alphaAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = DesignMotion.durationMillis(DesignMotion.feedbackIn)
                interpolator = DesignMotion.smoothOut
                addUpdateListener { digitAlpha = it.animatedValue as Float; invalidate() }
                start()
            }
        } else {
            digitSpring.cancel()
            digitScale = 1f
            digitAlpha = 1f
        }
        updateBlink()
        invalidate()
    }

    fun setActive(value: Boolean) {
        if (active == value) return
        active = value
        val target = if (value) ACTIVE_SCALE else 1f
        growX.animateTo(target)
        growY.animateTo(target)
        caretOn = true
        updateBlink()
        animateStroke()
    }

    fun setInvalid(value: Boolean) {
        if (invalid == value) return
        invalid = value
        animateStroke()
    }

    fun setDimmed(value: Boolean) {
        dimmed = value
        text.color = context.getColor(if (value) R.color.token_text_quaternary else R.color.token_text_primary)
        invalidate()
    }

    private fun strokeTarget() = context.getColor(when {
        invalid -> R.color.token_text_error_primary
        active -> R.color.token_bg_brand_solid
        else -> R.color.token_border_primary
    })

    private fun animateStroke() {
        strokeAnimator?.cancel()
        strokeAnimator = ValueAnimator.ofObject(ArgbEvaluator(), stroke.color, strokeTarget()).apply {
            duration = DesignMotion.durationMillis(DesignMotion.stateChange)
            interpolator = DesignMotion.softInOut
            addUpdateListener { stroke.color = it.animatedValue as Int; invalidate() }
            start()
        }
    }

    // A looping caret has no target value, so it blinks rather than springs.
    private fun updateBlink() {
        removeCallbacks(blink)
        caretOn = true
        if (active && digit == null && isAttachedToWindow && ValueAnimator.areAnimatorsEnabled()) {
            postDelayed(blink, CARET_BLINK_MS / 2)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        updateBlink()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(blink)
        strokeAnimator?.cancel()
        alphaAnimator?.cancel()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val inset = strokeWidth / 2
        bounds.set(inset, inset, width - inset, height - inset)
        canvas.drawRoundRect(bounds, radius, radius, fill)
        canvas.drawRoundRect(bounds, radius, radius, stroke)
        val cx = width / 2f
        val cy = height / 2f
        val value = digit
        if (value != null) {
            text.alpha = (digitAlpha * 255).toInt().coerceIn(0, 255)
            val baseline = cy - (text.descent() + text.ascent()) / 2
            canvas.withScale(digitScale, digitScale, cx, cy) {
                drawText(value.toString(), cx, baseline, text)
            }
        } else if (active && caretOn && !dimmed) {
            val half = text.textSize * 0.55f
            val w = 1.5f * density
            canvas.drawRect(cx - w / 2, cy - half, cx + w / 2, cy + half, caret)
        }
    }

    private object DigitScale : FloatPropertyCompat<CodeCellView>("digitScale") {
        override fun getValue(view: CodeCellView) = view.digitScale
        override fun setValue(view: CodeCellView, value: Float) {
            view.digitScale = value
            view.invalidate()
        }
    }

    companion object {
        /** The active cell grows slightly; tune on device. */
        const val ACTIVE_SCALE = 1.06f
        /** A new digit springs in from this scale. */
        const val POP_FROM = 0.6f
        private const val CARET_BLINK_MS = 1_100L
    }
}
