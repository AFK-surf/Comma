package surf.comma.android.ui.composer

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.DrawableWrapper
import android.net.Uri
import android.os.Bundle
import android.Manifest
import android.content.pm.PackageManager
import android.text.InputType
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.AttributeSet
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import surf.comma.android.scroll.widget.ScrollContainer
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.doAfterTextChanged
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import surf.comma.android.R
import surf.comma.android.media.PickedFile
import surf.comma.android.platform.logging.AppLog
import java.io.File
import java.util.UUID
import surf.comma.android.ui.widget.GlassPress
import surf.comma.android.ui.widget.GlassShape
import surf.comma.android.ui.widget.LiquidGlass
import kotlin.math.roundToInt
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography

/**
 * The chat input: a rounded surface with "+", a growing multi-line field and a send button, dimmed
 * and inert while the draft is empty. A draft longer than one line takes the full width, with the
 * buttons on a row under it ([ComposerRow]). Images sit above the text inside the same surface.
 *
 * Usage: `ComposerView(activity).attachTo(root)`. The host activity must use
 * `windowSoftInputMode="adjustNothing"`; the composer accounts for its host's bottom padding
 * while following the keyboard, frame by frame. "+" opens a small menu floating above
 * the composer ([AttachMenuView]); it leaves the keyboard alone, so nothing underneath moves.
 *
 * With [transcribeDictation] set, a microphone sits before send. Tapping it records and shows the waveform in the
 * composer; tapping the composer ends the recording, and the words go into the draft at the caret ([DictationModel]).
 * While it dictates the composer holds its one-row capsule, and "+" turns into the × that cancels.
 */
class ComposerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    // ---- Public API ----

    /** Send tapped. The input still holds the text while this runs; see [captureSendSnapshot]. */
    var onSend: ((text: String, attachments: List<ComposerAttachment>) -> Unit)? = null

    /** Optional asynchronous admission. Clear the draft only after its owner has saved it. */
    var onSubmit: ((String, List<ComposerAttachment>, (Boolean) -> Unit) -> Unit)? = null
    private var submitting = false

    /**
     * The composer's lift from navigation or the keyboard, including its extra keyboard spacing, in px.
     * Hosts move page content (an empty state, the list's bottom inset) by it each animation frame.
     */
    var onImeOffset: ((Float) -> Unit)? = null

    /** New files were attached; start uploading them and report back with [setAttachmentState]. */
    var onAttachmentsAdded: ((List<ComposerAttachment>) -> Unit)? = null

    /** The user removed an attachment; cancel its upload. */
    var onAttachmentRemoved: ((id: String) -> Unit)? = null

    /** The user tapped a failed attachment to retry its upload. */
    var onAttachmentRetry: ((id: String) -> Unit)? = null

    /** Images picked for a question card's other answer ([pickQuestionImages]), apart from the draft. */
    var onQuestionImagesPicked: ((questionMessageId: String, List<Uri>) -> Unit)? = null

    /**
     * A picker or the camera opened from here came over the app (true), or it went (false): it answered or was
     * cancelled, the app came back without its answer, or the composer left its window and can take none.
     */
    var onPicking: ((Boolean) -> Unit)? = null

    /** Writes out a recording's words, and shows the microphone. Throws when it cannot; empty when it heard none. */
    var transcribeDictation: (suspend (ByteArray) -> String)? = null
        set(value) {
            field = value
            microphone.visibility = if (value == null) GONE else VISIBLE
        }

    /** A dictation ended with no words. The host says why; without a host the composer does. */
    internal var onDictationFailed: ((DictationFailure) -> Unit)? = null

    /** Dictated words were put in the draft. */
    var onDictated: (() -> Unit)? = null

    val text: String get() = model.text
    val attachments: List<ComposerAttachment>
        get() = model.attachments.map { files.getValue(it.id) }

    /** Current lift in px (see [onImeOffset]). */
    val liftPx: Float get() = -translationY

    /** Part of the host covered by the keyboard; the backdrop still reaches under navigation. */
    internal val keyboardInsetPx: Float get() = imeOffset

    /** The field and its shape changed in a way the layout does not show; for the glass under it. */
    var onSurfaceChanged: (() -> Unit)? = null
    /** Sees every touch on the composer, for the glass under it. */
    var onGlassTouch: ((MotionEvent) -> Unit)? = null

    /** The field and, while it stands apart from it, the attachment button, in the parent's coordinates. */
    fun glassShapes(): List<GlassShape> {
        if (visibility != VISIBLE) return emptyList()
        pill.outlineProvider.getOutline(pill, shadowOutline)
        if (!shadowOutline.getRect(shadowBounds)) return emptyList()
        val field = Rect(shadowBounds).apply { offset((x + pill.x).roundToInt(), (y + pill.y).roundToInt()) }
        val shapes = mutableListOf(GlassShape(field, shadowOutline.radius))
        if (!expanded()) {
            val rest = plusBounds()
            val halfWidth = rest.width() * plusButton.scaleX / 2f
            val halfHeight = rest.height() * plusButton.scaleY / 2f
            val centerX = rest.exactCenterX() + plusButton.translationX + x
            val centerY = rest.exactCenterY() + plusButton.translationY + y
            val plus = Rect((centerX - halfWidth).roundToInt(), (centerY - halfHeight).roundToInt(), (centerX + halfWidth).roundToInt(), (centerY + halfHeight).roundToInt())
            shapes += GlassShape(plus, minOf(plus.width(), plus.height()) / 2f)
        }
        return shapes
    }

    private fun plusBounds() = Rect().also {
        plusButton.getDrawingRect(it)
        offsetDescendantRectToMyCoords(plusButton, it)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        onGlassTouch?.invoke(event)
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            plusTouched = !expanded() && plusBounds().contains(event.x.toInt(), event.y.toInt())
        }
        if (plusTouched) plusPress?.track(event)
        return super.dispatchTouchEvent(event)
    }

    /** Actual capsule edge in the parent, including the current keyboard/panel translation. */
    val capsuleTop: Float get() = y + pill.y

    /**
     * Adds [text] to the draft after a blank line and raises the keyboard on it. The member sends it; nothing is
     * sent here. The added words fade in where they land.
     */
    fun fillDraft(text: String) {
        val current = editText.text.toString().trimEnd()
        val next = if (current.isEmpty()) text else "$current\n\n$text"
        editText.setText(next)
        editText.setSelection(next.length)
        editText.alpha = 0f
        editText.animate().alpha(1f).setDuration(surf.comma.android.ui.theme.DesignMotion.durationMillis(
            surf.comma.android.ui.theme.DesignMotion.dialogEnter)).setInterpolator(surf.comma.android.ui.theme.DesignMotion.smoothOut).start()
        focusInput()
    }

    /** The text field, for the @ and / menus that read and edit the draft at the caret. */
    internal val field: EditText get() = editText
    /** A physical keyboard's Tab in the field; true when it was taken. */
    internal var onTabKey: (() -> Boolean)? = null

    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        val tab = event.keyCode == android.view.KeyEvent.KEYCODE_TAB && event.action == android.view.KeyEvent.ACTION_DOWN &&
            !event.isShiftPressed
        if (tab && editText.hasFocus() && onTabKey?.invoke() == true) return true
        return super.dispatchKeyEvent(event)
    }

    /** Rewrites the draft as it is sent, such as task mentions into their links; the field keeps what was typed. */
    var transformOutgoing: ((String) -> String)? = null

    /** Puts the caret in the field and raises the keyboard. */
    fun focusInput() {
        editText.requestFocus()
        requestKeyboard()
    }

    fun setAttachmentState(id: String, state: AttachmentUploadState) {
        if (!model.setAttachmentState(id, state)) return
        thumbs[id]?.state = state
        render(animate = true)
    }

    /**
     * Shows [shown], the draft's files as the host lists them, in order and each with how its upload goes: a file no
     * longer listed goes, and one that changed is drawn again. From then on the host's list alone takes a file away:
     * a file the person removes ([onAttachmentRemoved]) goes once the host no longer lists it.
     */
    fun showAttachments(shown: List<ShownAttachment>) {
        listed = true
        val ids = shown.mapTo(HashSet()) { it.attachment.id }
        files.keys.filter { it !in ids }.forEach(::dropThumb)
        shown.forEachIndexed { index, (attachment, state) ->
            if (files[attachment.id] != attachment) {
                dropThumb(attachment.id)
                addThumb(attachment, index)
            }
            val thumb = thumbs.getValue(attachment.id)
            if (strip.getChildAt(index) !== thumb) {
                strip.removeView(thumb)
                strip.addView(thumb, index)
            }
            thumb.state = state
        }
        model.showAttachments(shown.map { ComposerModel.Slot(it.attachment.id, it.state) })
        render(animate = true)
    }

    /** Drops a recording and any words still on their way; the draft stays as it is. */
    fun cancelDictation() = dictation.cancel()

    /** Hide the keyboard and the attachment menu, as a tap on the page does. */
    fun dismiss() {
        hideKeyboard()
        closeMenu()
    }

    /**
     * A frozen copy of the message being sent: text layout, positions and thumbnails in window
     * coordinates. Call it from [onSend]; afterwards the composer clears.
     */
    fun captureSendSnapshot(): ComposerSendSnapshot = snapshotOf(editText)

    /** Adds the composer and its attachment menu to the bottom of [root]. */
    fun attachTo(root: FrameLayout) {
        root.addView(this, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        root.addView(menu, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        root.setOnClickListener { dismiss() }
        // Being clickable made the whole page focusable. Focused outside touch mode (after a key
        // press, once the field let go) it wore the system focus highlight: the screen greyed
        // until the next touch. A tap here is not a control, so it never takes focus.
        root.isFocusable = false
        addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> applyTranslation() }
    }

    // ---- State ----

    private val style = ComposerStyle(context)
    private val model = ComposerModel(newId = { UUID.randomUUID().toString() })
    /** Insets beyond the space already reserved by the host, per animation frame. */
    private var imeOffset = 0f
    private var navigationOffset = 0f
    private val files = LinkedHashMap<String, ComposerAttachment>()
    private val thumbs = LinkedHashMap<String, AttachmentThumbView>()
    /** Whether the host lists the draft's files ([showAttachments]). */
    private var listed = false
    private val scales = HashMap<View, ButtonScale>()
    private var pendingCameraUri: Uri? = null

    // ---- Views ----

    private val pill = ComposerPill(context, style)
    private val stripScroll = ScrollContainer(context).apply { orientation = ScrollContainer.HORIZONTAL }
    private val strip = LinearLayout(context)
    private val plusButton = iconButton(R.drawable.ic_composer_plus, R.string.composer_attach)

    /** Standing apart from the field, the button presses as glass of its own. */
    private val plusPress = if (LiquidGlass.enabled) GlassPress(plusButton) { _, _, _ -> onSurfaceChanged?.invoke() } else null
    private var plusTouched = false
    private val actionFill = GradientDrawable().apply { shape = GradientDrawable.OVAL }
    private val actionCircle = VisibleScaleDrawable(actionFill)
    private val actionButton = iconButton(R.drawable.ic_composer_arrow_up, R.string.composer_send)
    private val microphone = iconButton(R.drawable.ic_call_mic, R.string.composer_dictate).apply { visibility = GONE }
    private val editText = EditText(context)
    private val dictation = DictationModel(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
        microphone = object : DictationMicrophone {
            override suspend fun start(ended: () -> Unit) = dictationAudio.start(ended)
        },
        allowed = ::microphoneAllowed,
        transcribe = { audio -> transcribeDictation?.invoke(audio).orEmpty() },
        failed = { failure -> onDictationFailed?.invoke(failure) ?: toast(failure.message) },
        phaseChanged = ::dictationChanged,
    )
    /** The recorder; replaceable in tests. */
    internal var dictationAudio: DictationMicrophone = DictationRecorder(context)
    private val dictationCapsule = DictationCapsule(context, style) { dictation.level }
    private val dictationPress = DictationPress({ dictation.phase }, { dictation.asking }, ::toggleDictation)
    private lateinit var row: ComposerRow
    private val menu = AttachMenuView(context, style, onEntry = { entry ->
        // Like any menu, it closes as soon as a row is chosen; the picker opens over the page.
        closeMenu()
        when (entry) {
            AttachEntry.CAMERA -> launchCamera()
            AttachEntry.PHOTOS -> launchPhotos()
            AttachEntry.FILES -> launchFiles()
        }
    }, onDismiss = { closeMenu() })

    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = if (menu.shown) closeMenu() else dictation.cancel()
    }

    private var cameraLauncher: ActivityResultLauncher<Uri>? = null
    private var photosLauncher: ActivityResultLauncher<Int>? = null
    private var photoLauncher: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var documentLauncher: ActivityResultLauncher<Array<String>>? = null
    private var questionPhotosLauncher: ActivityResultLauncher<Int>? = null
    private var questionPhotoLauncher: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var microphoneLauncher: ActivityResultLauncher<String>? = null
    /** The answer the microphone permission prompt is awaited for. */
    private var microphoneAnswer: CompletableDeferred<Boolean>? = null
    /** The question card the photo picker is open for; kept across a recreation so its result still reaches it. */
    private var pickingQuestion: String? = null
    /** Whether a picker or the camera opened from here is over the app; see [onPicking]. */
    private var picking = false
    /** The app coming back without a picker's answer, such as from a camera in a task of its own, ends the pick. */
    private val returnWatch = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_START) setPicking(false)
        if (event == Lifecycle.Event.ON_STOP) dictation.leftApp()
    }
    /** The photo picker's own cap; replaceable in tests. */
    internal var systemPhotoLimit: () -> Int = CappedPhotoPicker::systemLimit
    /** This composer's place among the activity's attached composers, which keys its results; -1 while detached. */
    private var resultSlot = -1

    init {
        id = R.id.comma_composer
        clipChildren = false
        // The pill's shadow spills into the padding around it.
        clipToPadding = false
        setPadding(style.dp(SIDE_DP), style.dp(TOP_DP), style.dp(SIDE_DP), style.dp(BOTTOM_DP))
        buildPill()
        addView(pill, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        setupImeFollow()
        render(animate = false)
    }

    // ---- Construction ----

    private fun buildPill() {
        stripScroll.apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = OVER_SCROLL_NEVER
            clipToPadding = false
            visibility = GONE
            setPadding(style.dp(10), style.dp(10), style.dp(10), 0)
            addView(strip, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        }
        strip.orientation = LinearLayout.HORIZONTAL
        pill.addView(stripScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val button = style.dp(BUTTON_DP)

        val leading = FrameLayout(context)
        if (plusPress != null) plusButton.onPressedChanged = null
        plusButton.setOnClickListener {
            if (dictation.busy) dictation.cancel() else if (menu.shown) closeMenu() else openMenu()
        }
        leading.addView(plusButton, LayoutParams(button, button, Gravity.CENTER))

        val center = FrameLayout(context)
        buildEditText()
        center.addView(editText, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))

        val trailing = FrameLayout(context)
        actionButton.background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), InsetDrawable(actionCircle, style.dp(6)), null)
        actionButton.setPadding(style.dp(13), style.dp(13), style.dp(13), style.dp(13))
        actionButton.setImageDrawable(VisibleScaleDrawable(actionButton.drawable))
        actionButton.setColorFilter(style.onBrand)
        actionButton.setOnClickListener { sendNow() }
        trailing.addView(actionButton, LayoutParams(button, button, Gravity.CENTER))

        bindDictationPress(microphone)
        bindDictationPress(dictationCapsule)

        row = ComposerRow(context, style, leading, center, trailing, microphone, dictationCapsule, ::draftNeedsOwnRow,
            ::expanded, ::applyArrangement).apply {
            // The strip beside the buttons of a stacked draft belongs to the field.
            isSoundEffectsEnabled = false
            setOnClickListener { showKeyboard() }
        }
        pill.addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

    // The listener observes touches. EditText still handles clicks and text selection.
    @SuppressLint("ClickableViewAccessibility")
    private fun buildEditText() = editText.apply {
        background = null
        val vertical = (style.dp(SLOT_DP) - style.dp(24)) / 2
        setPadding(style.dp(4), vertical, style.dp(4), vertical)
        // As tall as the button row, so a single line (and the hint) centres on the buttons
        // instead of sitting on the row's bottom edge.
        minHeight = style.dp(SLOT_DP)
        style.applyText(this, DesignTypography.Level.REGULAR)
        setTextColor(style.textPrimary)
        setHintTextColor(style.textPlaceholder)
        setHint(R.string.composer_hint)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
            InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
        maxLines = MAX_LINES
        isVerticalScrollBarEnabled = false
        gravity = Gravity.START or Gravity.CENTER_VERTICAL
        textCursorDrawable = GradientDrawable().apply {
            setSize(style.dp(2), 0)
            setColor(style.brand)
        }
        onFocusChangeListener = OnFocusChangeListener { _, focused ->
            row.refresh(animate = true)
            row.requestLayout()
            if (!focused) removeCallbacks(showInput)
        }
        setOnTouchListener { _, event ->
            // Let the first touch give the field focus before requesting the IME.
            if (!hasFocus() && (event.actionMasked == MotionEvent.ACTION_DOWN || event.actionMasked == MotionEvent.ACTION_UP)) {
                requestKeyboard()
            }
            false
        }
        // A physical keyboard's Return sends and the field keeps focus; Shift- or Alt-Return breaks the line. The
        // software keyboard's Return still types a line break. The @ and / menus do not take Return.
        setOnKeyListener { _, _, event ->
            val action = hardwareReturnAction(event) ?: return@setOnKeyListener false
            if (event.action == KeyEvent.ACTION_DOWN) when (action) {
                HardwareReturn.SEND -> if (event.repeatCount == 0) sendNow()
                HardwareReturn.LINE_BREAK -> insertLineBreak()
            }
            true
        }
        doAfterTextChanged {
            val before = model.text
            model.updateText(it?.toString().orEmpty())
            // The field travels between the two arrangements only while there is text to follow;
            // a cleared or freshly filled field simply appears in place as the surface resizes.
            row.refresh(animate = before.isNotEmpty() && model.text.isNotEmpty())
            render(animate = true)
        }
    }

    private fun expanded(): Boolean = !dictation.busy && (editText.hasFocus() || model.attachments.isNotEmpty())

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        row.refresh(animate = false)
    }

    private fun compactHeight() = resources.configuration.screenHeightDp < 480

    private fun draftNeedsOwnRow(): Boolean = expanded() && (!compactHeight() || model.attachments.isNotEmpty())

    private var plusOnCard: Boolean? = null

    private fun applyArrangement(stacked: Boolean, expanded: Boolean) {
        pill.setExpanded(expanded)
        if (plusOnCard != expanded) {
            plusOnCard = expanded
            // Glass answers a press itself. A ripple would swell with the button and be cut by the composer's edge.
            plusButton.background = if (plusPress != null) null else RippleDrawable(
                ColorStateList.valueOf(0x14000000),
                if (expanded) null else circle(style.composerSurface).apply {
                    setStroke(style.dp(ComposerPill.BORDER_DP).toInt().coerceAtLeast(1), style.composerBorder)
                }, circle(android.graphics.Color.BLACK),
            )
        }
        val top = if (stacked) { if (model.attachments.isEmpty()) 16 else 12 } else 11
        editText.setPaddingRelative(
            style.dp(if (stacked || expanded) 0 else 16), style.dp(top), 0,
            style.dp(if (stacked) 10 else 11),
        )
        val minimum = if (stacked) 0 else style.dp(SLOT_DP)
        if (editText.minHeight != minimum) editText.minHeight = minimum
        val lines = if (dictation.busy) 1 else if (expanded && !stacked) 2 else MAX_LINES
        if (editText.maxLines != lines) editText.maxLines = lines
        onSurfaceChanged?.invoke()
    }

    private val surfaceShadow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        val tokens = this@ComposerView.style
        color = tokens.composerBg
        // The iOS material fallback uses black at 6%, radius 10 and a 3pt downward offset.
        setShadowLayer(tokens.dp(10f), 0f, tokens.dp(3f), tokens.composerShadow)
    }
    private val shadowOutline = Outline()
    private val shadowBounds = Rect()
    private val shadowRect = RectF()

    override fun dispatchDraw(canvas: Canvas) {
        // The shadow's caster is a solid fill, which would cover the glass.
        if (LiquidGlass.enabled) return super.dispatchDraw(canvas)
        pill.outlineProvider.getOutline(pill, shadowOutline)
        if (shadowOutline.getRect(shadowBounds)) {
            shadowRect.set(shadowBounds)
            shadowRect.offset(pill.x, pill.y)
            drawSurfaceShadow(canvas, shadowOutline.radius)
        }
        if (!expanded()) {
            plusButton.getDrawingRect(shadowBounds)
            offsetDescendantRectToMyCoords(plusButton, shadowBounds)
            shadowRect.set(shadowBounds)
            val saved = canvas.save()
            canvas.scale(plusButton.scaleX, plusButton.scaleY, shadowRect.centerX(), shadowRect.centerY())
            drawSurfaceShadow(canvas, shadowRect.width() / 2f)
            canvas.restoreToCount(saved)
        }
        super.dispatchDraw(canvas)
    }

    private fun drawSurfaceShadow(canvas: Canvas, radius: Float) {
        canvas.drawRoundRect(shadowRect, radius, radius, surfaceShadow)
    }

    private fun iconButton(icon: Int, description: Int) = PressableImageView(context).apply {
        onPressedChanged = { pressed -> scaleOf(this).setPressed(pressed) }
        setImageResource(icon)
        setColorFilter(style.textPrimary)
        scaleType = ImageView.ScaleType.FIT_CENTER
        val glyphSize = when (icon) {
            R.drawable.ic_composer_plus -> 22
            R.drawable.ic_composer_arrow_up -> 18
            R.drawable.ic_call_mic -> 20
            else -> 24
        }
        val inset = style.dp((BUTTON_DP - glyphSize) / 2)
        setPadding(inset, inset, inset, inset)
        contentDescription = context.getString(description)
        background = RippleDrawable(ColorStateList.valueOf(0x14000000), null, circle(0xFF000000.toInt()))
        isClickable = true
        isFocusable = true
    }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    // ---- Rendering ----

    private fun render(animate: Boolean) {
        val animated = animate && ComposerStyle.motionEnabled && isLaidOut
        stripScroll.visibility = if (model.attachments.isNotEmpty() && !dictation.busy) VISIBLE else GONE
        row.refresh(animate = false)

        // An empty draft has nothing to send: send stays in its place, dimmed and inert.
        actionButton.isEnabled = model.hasContent
        // Keep send tappable to explain unfinished uploads.
        setActionFill(if (model.canSend) style.brand else style.textPlaceholder, animated)
        plusButton.contentDescription = context.getString(
            if (dictation.busy) R.string.composer_dictate_cancel
            else if (menu.shown) R.string.composer_attach_close else R.string.composer_attach,
        )
        menu.bind(AttachMenuState.of(model))
        backCallback.isEnabled = menu.shown || dictation.busy
    }

    private var actionFillTarget: Int? = null
    private var actionFillShown = 0
    private var actionFillAnimator: ValueAnimator? = null

    /** Send's fill changes colour on the duration and curve of [DesignMotion.stateChange]. */
    private fun setActionFill(color: Int, animated: Boolean) {
        if (color == actionFillTarget) return
        actionFillTarget = color
        actionFillAnimator?.cancel()
        actionFillAnimator = null
        val targetLevel = if (model.canSend) 10000 else 9200
        val startLevel = actionCircle.level
        if (!animated) {
            actionCircle.level = targetLevel
            actionButton.drawable.level = targetLevel
            actionFillShown = color
            actionFill.setColor(color)
            return
        }
        actionFillAnimator = ValueAnimator.ofArgb(actionFillShown, color).apply {
            duration = DesignMotion.durationMillis(DesignMotion.stateChange)
            interpolator = DesignMotion.softInOut
            addUpdateListener {
                val level = (startLevel + (targetLevel - startLevel) * it.animatedFraction).toInt()
                actionCircle.level = level
                actionButton.drawable.level = level
                actionFillShown = it.animatedValue as Int
                actionFill.setColor(actionFillShown)
            }
            start()
        }
    }

    private fun scaleOf(view: View): ButtonScale = scales.getOrPut(view) { ButtonScale(view, action = true) }

    // ---- Send ----

    private fun sendNow() {
        // A dictation still on its way holds send, so its words are not left behind.
        if (submitting || dictation.busy) return
        if (!model.canSend) {
            when (model.sendBlock) {
                ComposerModel.SendBlock.UPLOAD_FAILED -> toast(R.string.composer_uploads_failed)
                ComposerModel.SendBlock.UPLOADING -> toast(R.string.composer_uploads_pending)
                else -> Unit
            }
            return
        }
        val draftText = model.text
        val outgoingText = draftText.trim()
        val outgoing = attachments
        performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        fun complete(accepted: Boolean) {
            submitting = false
            if (accepted) {
                model.consumeSentDraft(draftText, outgoing.map { it.id }.toSet())
                outgoing.forEach { attachment ->
                    files.remove(attachment.id)
                    thumbs.remove(attachment.id)?.let(strip::removeView)
                }
                if (editText.text.toString() != model.text) editText.setText(model.text)
            }
            render(animate = true)
        }
        val submit = onSubmit
        val sentText = transformOutgoing?.invoke(outgoingText) ?: outgoingText
        if (submit != null) {
            submitting = true
            // Keep the input connection alive while the owner saves the pending message.
            submit(sentText, outgoing, ::complete)
        } else {
            onSend?.invoke(sentText, outgoing)
            complete(true)
        }
    }

    /** A line break replaces the selection, or goes at the end with no caret, and the caret follows it. */
    private fun insertLineBreak() {
        val text = editText.text
        val start = minOf(editText.selectionStart, editText.selectionEnd).takeIf { it >= 0 } ?: text.length
        val end = maxOf(editText.selectionStart, editText.selectionEnd).takeIf { it >= 0 } ?: text.length
        text.replace(start, end, "\n")
        editText.setSelection(start + 1)
    }

    // ---- Attachments ----

    private fun addUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        if (model.remainingSlots <= 0) {
            toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
            return
        }
        // A file sent as it is must fit the upload limit; an image is made smaller to fit.
        val described = uris.map { it to PickedFile.describe(context.contentResolver, it) }
        val picked = described.filterNot { it.second.tooLarge }
        if (picked.size < described.size) toast(R.string.composer_attach_too_large)
        if (picked.isEmpty()) return
        val ids = model.addAttachments(picked.size)
        val names = files.values.mapTo(HashSet()) { it.file.name }
        val added = ids.mapIndexed { index, id ->
            val file = picked[index].second
            val named = file.copy(name = PickedFile.distinctName(file.name, names)).also { names += it.name }
            ComposerAttachment(id, picked[index].first, named)
        }
        added.forEach { addThumb(it) }
        val dropped = picked.size - ids.size
        if (dropped > 0) toast(R.string.composer_attach_dropped, ComposerModel.MAX_ATTACHMENTS, dropped)
        render(animate = true)
        stripScroll.post { stripScroll.fullScroll(FOCUS_RIGHT) }
        if (added.isNotEmpty()) onAttachmentsAdded?.invoke(added)
    }

    private fun addThumb(attachment: ComposerAttachment, index: Int = -1) {
        files[attachment.id] = attachment
        val thumb = AttachmentThumbView(context, style, attachment, ::removeAttachment) {
            onAttachmentRetry?.invoke(it)
        }
        thumbs[attachment.id] = thumb
        val size = style.dp(AttachmentThumbView.SIZE_DP)
        strip.addView(thumb, index, LinearLayout.LayoutParams(size, size).apply { marginEnd = style.dp(8) })
    }

    private fun dropThumb(id: String) {
        files.remove(id)
        thumbs.remove(id)?.let(strip::removeView)
    }

    private fun removeAttachment(id: String) {
        if (listed) {
            // It goes when the host's list leaves it out.
            onAttachmentRemoved?.invoke(id)
            return
        }
        if (!model.removeAttachment(id)) return
        dropThumb(id)
        render(animate = true)
        onAttachmentRemoved?.invoke(id)
    }

    private fun launchCamera() {
        if (model.remainingSlots <= 0) return toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
        val launcher = cameraLauncher ?: return
        val uri = try {
            val directory = File(context.cacheDir, CAMERA_DIRECTORY).apply { mkdirs() }
            val file = File(directory, "IMG_${System.currentTimeMillis()}.jpg")
            FileProvider.getUriForFile(context, "${context.packageName}.composer.files", file)
        } catch (error: Exception) {
            AppLog.warn(TAG, error, "Camera output file")
            return toast(R.string.composer_camera_unavailable)
        }
        pendingCameraUri = uri
        try {
            launcher.open(uri)
        } catch (_: ActivityNotFoundException) {
            pendingCameraUri = null
            toast(R.string.composer_camera_unavailable)
        }
    }

    private fun launchPhotos() {
        when (val pick = PhotoPick.forRemaining(model.remainingSlots, systemPhotoLimit())) {
            PhotoPick.None -> toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
            PhotoPick.Single ->
                photoLauncher?.open(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
            is PhotoPick.Multiple -> photosLauncher?.open(pick.limit)
        }
    }

    /**
     * Opens the photo picker for up to [remaining] images of question card [questionMessageId]'s other answer. They
     * go to [onQuestionImagesPicked], never into the draft.
     */
    fun pickQuestionImages(questionMessageId: String, remaining: Int) {
        val pick = PhotoPick.forRemaining(remaining, systemPhotoLimit())
        if (pick == PhotoPick.None) return toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
        pickingQuestion = questionMessageId
        when (pick) {
            PhotoPick.None -> Unit
            PhotoPick.Single ->
                questionPhotoLauncher?.open(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            is PhotoPick.Multiple -> questionPhotosLauncher?.open(pick.limit)
        }
    }

    private fun onQuestionPicked(picked: List<Uri>) {
        setPicking(false)
        val question = pickingQuestion ?: return
        pickingQuestion = null
        if (picked.isNotEmpty()) onQuestionImagesPicked?.invoke(question, picked)
    }

    private fun launchFiles() {
        if (model.remainingSlots <= 0) return toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
        try {
            // Any file: the core says which types it takes, as on every client.
            documentLauncher?.open(arrayOf("*/*"))
        } catch (error: ActivityNotFoundException) {
            AppLog.warn(TAG, error, "No document picker")
        }
    }

    private fun onPicked(picked: List<Uri>) {
        setPicking(false)
        if (picked.isEmpty()) return
        addUris(picked)
    }

    /** Opens this picker over the app, which [onPicking] tells the host until it goes. */
    private fun <I> ActivityResultLauncher<I>.open(input: I) {
        setPicking(true)
        try {
            launch(input)
        } catch (error: Throwable) {
            setPicking(false)
            throw error
        }
    }

    private fun setPicking(open: Boolean) {
        if (picking == open) return
        picking = open
        onPicking?.invoke(open)
    }

    // ---- Attachment menu & keyboard ----

    private fun openMenu() {
        if (menu.shown) return
        // Above everything the host added after the composer (the task pill, for one).
        menu.bringToFront()
        applyTranslation()
        menu.show()
        rotatePlus()
        render(animate = true)
    }

    private fun closeMenu() {
        if (!menu.shown) return
        menu.hide()
        rotatePlus()
        render(animate = true)
    }

    private val plusRotation = DesignSpring(plusButton, DynamicAnimation.ROTATION, DesignMotion.springRotation)

    /** "+" is one glyph, turned into the × that closes the menu or cancels a dictation; nothing about it lays out. */
    private fun rotatePlus() = plusRotation.animateTo(if (menu.shown || dictation.busy) PLUS_OPEN_ROTATION else 0f)

    // ---- Dictation ----

    private fun toggleDictation() {
        if (dictation.phase == DictationPhase.IDLE) dismiss()
        dictation.toggle(::insertDictation)
    }

    // The listener takes the whole press, for hold-to-talk. TalkBack's click still toggles.
    @SuppressLint("ClickableViewAccessibility")
    private fun bindDictationPress(view: View) {
        view.setOnClickListener { if (dictation.phase != DictationPhase.TRANSCRIBING) toggleDictation() }
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    view.isPressed = true
                    dictationPress.down(event.eventTime)
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    view.isPressed = false
                    dictationPress.up(event.eventTime, event.actionMasked == MotionEvent.ACTION_CANCEL)
                }
            }
            true
        }
    }

    private fun dictationChanged(phase: DictationPhase) {
        when (phase) {
            DictationPhase.RECORDING -> performHapticFeedback(HapticFeedbackConstants.GESTURE_START)
            DictationPhase.TRANSCRIBING -> performHapticFeedback(HapticFeedbackConstants.GESTURE_END)
            DictationPhase.IDLE -> Unit
        }
        dictationCapsule.show(phase)
        val quiet = if (phase == DictationPhase.IDLE) 1f else 0f
        val fade = DesignMotion.durationMillis(DesignMotion.stateChange)
        listOf(editText.parent as View, actionButton.parent as View, microphone).forEach {
            it.animate().alpha(quiet).setDuration(fade).setInterpolator(DesignMotion.softInOut).start()
        }
        rotatePlus()
        row.refresh(animate = true)
        render(animate = true)
        invalidate()
    }

    private fun insertDictation(words: String) {
        val edit = dictationEdit(editText.text, editText.selectionStart, editText.selectionEnd, words)
        editText.text.replace(edit.start, edit.end, edit.inserted)
        editText.setSelection(edit.start + edit.inserted.length)
        onDictated?.invoke()
    }

    private suspend fun microphoneAllowed(): Boolean {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return true
        val launcher = microphoneLauncher ?: return false
        val answer = CompletableDeferred<Boolean>()
        microphoneAnswer = answer
        launcher.launch(Manifest.permission.RECORD_AUDIO)
        return answer.await()
    }

    /** The single place the composer's vertical position is set; the menu rides along. */
    private fun applyTranslation() {
        val extraGap = (imeOffset - navigationOffset).coerceIn(
            0f, (resources.getDimensionPixelSize(R.dimen.spacing_xl) - paddingBottom).coerceAtLeast(0).toFloat(),
        )
        val lifted = maxOf(imeOffset, navigationOffset) + extraGap
        translationY = -lifted
        menu.follow(height, lifted, leading = left + paddingLeft)
        onImeOffset?.invoke(lifted)
    }

    private fun setupImeFollow() {
        var imeAnimating = false
        var imeVisible = false
        fun applyInsets(insets: WindowInsetsCompat) {
            val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val navigation = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            val reserved = (parent as? View)?.paddingBottom ?: 0
            imeOffset = (ime - reserved).toFloat().coerceAtLeast(0f)
            navigationOffset = (navigation - reserved).toFloat().coerceAtLeast(0f)
            applyTranslation()
            val nowVisible = ime > 0
            if (imeVisible && !nowVisible) releaseInputFocus()
            imeVisible = nowVisible
        }
        // Static insets arrive with the end state before an animation starts; ignore them then.
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            if (!imeAnimating) applyInsets(insets)
            insets
        }
        ViewCompat.setWindowInsetsAnimationCallback(this, object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_STOP) {
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() != 0) imeAnimating = true
            }

            override fun onProgress(
                insets: WindowInsetsCompat,
                runningAnimations: List<WindowInsetsAnimationCompat>,
            ): WindowInsetsCompat {
                applyInsets(insets)
                return insets
            }

            override fun onEnd(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                imeAnimating = false
                ViewCompat.getRootWindowInsets(this@ComposerView)?.let(::applyInsets)
            }
        })
    }

    private fun releaseInputFocus() {
        editText.clearFocus()
    }

    private fun showKeyboard() {
        focusInput()
        editText.setSelection(editText.text.length)
    }

    private val showInput = Runnable {
        if (editText.isShown && editText.hasFocus()) inputMethodManager().showSoftInput(editText, 0)
    }

    private fun requestKeyboard() {
        editText.removeCallbacks(showInput)
        editText.post(showInput)
    }

    private fun hideKeyboard() {
        inputMethodManager().hideSoftInputFromWindow(editText.windowToken, 0)
        editText.clearFocus()
    }

    private fun inputMethodManager() =
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    // ---- Activity results ----

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        val activity = hostActivity() as? ComponentActivity ?: return
        val registry = activity.activityResultRegistry
        // The router chat and an open Task's chat each have a composer in the same activity, and a key registered
        // twice takes the other's results and is unregistered with it. Each composer takes the lowest place free
        // among the attached ones; the shell attaches them in the same order after a recreation, so a result the
        // system delivers then still reaches the composer that asked for it.
        val taken = SLOTS.getOrPut(activity) { mutableSetOf() }
        val slot = generateSequence(0) { it + 1 }.first { it !in taken }
        taken += slot
        resultSlot = slot
        // The camera's file is kept per place for the same reason: views with one id share one saved state.
        val stateKey = "$KEY_STATE.$slot"
        activity.savedStateRegistry.consumeRestoredStateForKey(stateKey)?.let {
            pendingCameraUri = it.getParcelable(STATE_CAMERA_URI, Uri::class.java)
            pickingQuestion = it.getString(STATE_QUESTION)
        }
        activity.savedStateRegistry.registerSavedStateProvider(stateKey) {
            Bundle().apply {
                putParcelable(STATE_CAMERA_URI, pendingCameraUri)
                putString(STATE_QUESTION, pickingQuestion)
            }
        }
        // Every answer, nothing picked included, ends the pick.
        cameraLauncher = registry.register("$KEY_CAMERA.$slot", ActivityResultContracts.TakePicture()) { saved ->
            val uri = pendingCameraUri
            pendingCameraUri = null
            onPicked(listOfNotNull(uri?.takeIf { saved }))
        }
        photosLauncher = registry.register(
            "$KEY_PHOTOS.$slot", CappedPhotoPicker(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
        ) { onPicked(it) }
        photoLauncher = registry.register("$KEY_PHOTO.$slot", ActivityResultContracts.PickVisualMedia()) { uri ->
            onPicked(listOfNotNull(uri))
        }
        documentLauncher = registry.register("$KEY_DOCUMENT.$slot", ActivityResultContracts.OpenMultipleDocuments()) {
            onPicked(it)
        }
        questionPhotosLauncher = registry.register(
            "$KEY_QUESTION_PHOTOS.$slot", CappedPhotoPicker(ActivityResultContracts.PickVisualMedia.ImageOnly),
        ) { onQuestionPicked(it) }
        questionPhotoLauncher = registry.register("$KEY_QUESTION_PHOTO.$slot", ActivityResultContracts.PickVisualMedia()) { uri ->
            onQuestionPicked(listOfNotNull(uri))
        }
        microphoneLauncher = registry.register("$KEY_MICROPHONE.$slot", ActivityResultContracts.RequestPermission()) { granted ->
            microphoneAnswer?.complete(granted)
            microphoneAnswer = null
        }
        activity.onBackPressedDispatcher.addCallback(backCallback)
        activity.lifecycle.addObserver(returnWatch)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        // Its answer can no longer reach this composer.
        setPicking(false)
        dictation.cancel()
        listOf(cameraLauncher, photosLauncher, photoLauncher, documentLauncher, questionPhotosLauncher, questionPhotoLauncher,
            microphoneLauncher).forEach { it?.unregister() }
        cameraLauncher = null
        photosLauncher = null
        photoLauncher = null
        documentLauncher = null
        questionPhotosLauncher = null
        questionPhotoLauncher = null
        microphoneLauncher = null
        backCallback.remove()
        val activity = hostActivity() as? ComponentActivity
        activity?.lifecycle?.removeObserver(returnWatch)
        if (activity != null && resultSlot >= 0) {
            activity.savedStateRegistry.unregisterSavedStateProvider("$KEY_STATE.$resultSlot")
            SLOTS[activity]?.remove(resultSlot)
        }
        resultSlot = -1
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        // Hidden on its page: gone from the member's sight. The window hiding is the app leaving (see [returnWatch]).
        if (!isVisible && windowVisibility == VISIBLE) dictation.cancel()
    }

    private fun hostActivity(): Activity? {
        var current: Context? = context
        while (current is ContextWrapper) {
            if (current is Activity) return current
            current = current.baseContext
        }
        return null
    }

    private fun toast(message: Int, vararg args: Any) {
        Toast.makeText(context, context.getString(message, *args), Toast.LENGTH_SHORT).show()
    }

    // ---- Send snapshot ----

    private fun snapshotOf(source: TextView): ComposerSendSnapshot {
        val paint = TextPaint(source.paint)
        val window = IntArray(2)
        val surface = RectF()
        pill.getLocationInWindow(window)
        surface.set(window[0].toFloat(), window[1].toFloat(), window[0] + pill.width.toFloat(), window[1] + pill.height.toFloat())
        val text: CharSequence = source.text.toString()
        val live = source.layout
        val frozen = if (live != null && text.isNotEmpty()) freeze(source, live, text, paint, live.width) else null
        source.getLocationInWindow(window)
        val origin = PointF(
            (window[0] + source.totalPaddingLeft).toFloat(),
            (window[1] + source.extendedPaddingTop - source.scrollY).toFloat(),
        )
        val thumbnails = thumbs.values.map { thumb ->
            thumb.getLocationInWindow(window)
            val visible = android.graphics.Rect()
            val visibleBounds = if (thumb.getLocalVisibleRect(visible)) RectF(visible).apply {
                offset(window[0].toFloat(), window[1].toFloat())
            } else RectF()
            ComposerSendSnapshot.Attachment(
                thumb.attachmentId, thumb.uri,
                RectF(window[0].toFloat(), window[1].toFloat(), window[0] + thumb.width.toFloat(), window[1] + thumb.height.toFloat()),
                thumb.bitmap,
                visibleBounds,
            )
        }
        return ComposerSendSnapshot(text, frozen, paint, origin, surface, thumbnails)
    }

    /** A static copy of the live layout, so the snapshot survives the field being cleared. */
    private fun freeze(source: TextView, live: Layout, text: CharSequence, paint: TextPaint, width: Int): Layout =
        StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
            .setAlignment(live.alignment)
            .setLineSpacing(source.lineSpacingExtra, source.lineSpacingMultiplier)
            .setIncludePad(source.includeFontPadding)
            .setBreakStrategy(source.breakStrategy)
            .setHyphenationFrequency(source.hyphenationFrequency)
            .setJustificationMode(source.justificationMode)
            .setUseLineSpacingFromFallbacks(source.isFallbackLineSpacing)
            .build()

    private companion object {
        const val TAG = "Composer"
        const val SLOT_DP = ComposerRow.SLOT_DP
        const val BUTTON_DP = 44
        /** Page gutter beside the composer. */
        const val SIDE_DP = 12
        /** Above the composer, between it and the list. */
        const val TOP_DP = 8
        /** Under the composer, above the gesture bar (or the keyboard). */
        const val BOTTOM_DP = 8
        const val MAX_LINES = 6
        const val PLUS_OPEN_ROTATION = 45f
        const val CAMERA_DIRECTORY = "composer-camera"
        const val KEY_CAMERA = "comma.composer.camera"
        const val KEY_PHOTOS = "comma.composer.photos"
        const val KEY_PHOTO = "comma.composer.photo"
        const val KEY_DOCUMENT = "comma.composer.document"
        const val KEY_QUESTION_PHOTOS = "comma.composer.question.photos"
        const val KEY_QUESTION_PHOTO = "comma.composer.question.photo"
        const val KEY_MICROPHONE = "comma.composer.microphone"
        const val KEY_STATE = "comma.composer.state"
        const val STATE_CAMERA_URI = "cameraUri"
        const val STATE_QUESTION = "pickingQuestion"
        /** The places taken by each activity's attached composers; see [onAttachedToWindow]. */
        val SLOTS = java.util.WeakHashMap<Activity, MutableSet<Int>>()
    }
}

/** What a Return key press in the composer does. */
internal enum class HardwareReturn { SEND, LINE_BREAK }

/**
 * A physical keyboard's Return sends, and with Shift or Alt it breaks the line. Null for any other key and for a
 * Return a software keyboard sends, which keeps typing a line break.
 */
internal fun hardwareReturnAction(event: KeyEvent): HardwareReturn? {
    if (event.keyCode != KeyEvent.KEYCODE_ENTER && event.keyCode != KeyEvent.KEYCODE_NUMPAD_ENTER) return null
    if (event.deviceId == KeyCharacterMap.VIRTUAL_KEYBOARD || event.flags and KeyEvent.FLAG_SOFT_KEYBOARD != 0) return null
    return if (event.isShiftPressed || event.isAltPressed) HardwareReturn.LINE_BREAK else HardwareReturn.SEND
}

/** A newly assigned image remains visible before its first animated state update. */
private class VisibleScaleDrawable(drawable: android.graphics.drawable.Drawable) :
    DrawableWrapper(drawable) {
    override fun draw(canvas: Canvas) {
        val scale = if (level == 0) 1f else level / 10000f
        val saved = canvas.save()
        canvas.scale(scale, scale, bounds.exactCenterX(), bounds.exactCenterY())
        super.draw(canvas)
        canvas.restoreToCount(saved)
    }
}
