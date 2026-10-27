package surf.comma.android.ui.composer

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.util.AttributeSet
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
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
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.widget.doAfterTextChanged
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.media.PickedFile
import surf.comma.android.platform.asr.AsrCredentialProvider
import surf.comma.android.platform.asr.AsrError
import surf.comma.android.platform.asr.DebugLocalAsrCredentialProvider
import surf.comma.android.platform.asr.SpeechRecognizer
import surf.comma.android.platform.logging.AppLog
import java.io.File
import java.util.UUID
import kotlin.math.ceil
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography

/**
 * The chat input: a rounded surface with "+", a growing multi-line field and one trailing button
 * (send with content or while a reply generates, microphone otherwise). A draft longer than
 * one line takes the full width, with the buttons on a row under it ([ComposerRow]). Images sit
 * above the text inside the same surface. Tapping the microphone dictates into the field; pressing and
 * holding the field or the microphone talks and sends on release.
 *
 * Usage: `ComposerView(activity).attachTo(root)`. The host activity must use
 * `windowSoftInputMode="adjustNothing"`; the composer accounts for its host's bottom padding
 * while following the keyboard, frame by frame. "+" opens a small menu floating above
 * the composer ([AttachMenuView]); it leaves the keyboard alone, so nothing underneath moves.
 */
class ComposerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    private val credentialProvider: AsrCredentialProvider = DebugLocalAsrCredentialProvider(),
) : FrameLayout(context, attrs) {

    // ---- Public API ----

    /** Send tapped. The input still holds the text while this runs; see [captureSendSnapshot]. */
    var onSend: ((text: String, attachments: List<ComposerAttachment>) -> Unit)? = null

    /** Optional asynchronous admission. Clear the draft only after its owner has saved it. */
    var onSubmit: ((String, List<ComposerAttachment>, (Boolean) -> Unit) -> Unit)? = null
    private var submitting = false

    /** Hold-to-talk released outside the cancel zone with something recognised. */
    var onVoiceSend: ((text: String) -> Unit)? = null

    /**
     * How far the composer is lifted above its resting line by navigation or the keyboard, in px,
     * every animation frame. Hosts move page content (an empty state, the list's bottom inset) by it.
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

    val text: String get() = model.text
    val attachments: List<ComposerAttachment>
        get() = model.attachments.map { files.getValue(it.id) }

    /** Current lift in px (see [onImeOffset]). */
    val liftPx: Float get() = -translationY

    /** Part of the host covered by the keyboard; the backdrop still reaches under navigation. */
    internal val keyboardInsetPx: Float get() = imeOffset

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

    /** Rewrites the draft as it is sent, such as task mentions into their links; the field keeps what was typed. */
    var transformOutgoing: ((String) -> String)? = null

    /** Puts the caret in the field and raises the keyboard. */
    fun focusInput() {
        editText.requestFocus()
        editText.post {
            context.getSystemService(android.view.inputmethod.InputMethodManager::class.java)?.showSoftInput(editText, 0)
        }
    }

    fun setGenerating(generating: Boolean) {
        if (model.generating == generating) return
        model.setGenerating(generating)
        render(animate = true)
    }

    fun setAttachmentState(id: String, state: AttachmentUploadState) {
        if (!model.setAttachmentState(id, state)) return
        thumbs[id]?.state = state
        render(animate = true)
    }

    /** Hide the keyboard and the attachment menu, as a tap on the page does. */
    fun dismiss() {
        hideKeyboard()
        closeMenu()
    }

    /**
     * A frozen copy of the message being sent: text layout, positions and thumbnails in window
     * coordinates. Call it from [onSend] or [onVoiceSend]; afterwards the composer clears.
     */
    fun captureSendSnapshot(): ComposerSendSnapshot =
        if (sendingVoice) snapshotOf(holdOverlay?.bubble, fromVoice = true)
        else snapshotOf(editText, fromVoice = false)

    /** Adds the composer, its attachment menu and its voice overlay to the bottom of [root]. */
    fun attachTo(root: FrameLayout) {
        hostRoot = root
        root.addView(this, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        root.addView(menu, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        root.addView(holdOverlay, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
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
    private val hold = HoldToTalk(
        touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat(),
        cancelDistance = style.dp(CANCEL_DISTANCE_DP.toFloat()),
        longPressMs = ViewConfiguration.getLongPressTimeout().toLong(),
    )
    private var hostRoot: FrameLayout? = null
    private val scales = HashMap<View, ButtonScale>()
    private var recognizer: SpeechRecognizer? = null
    private var awaitingFinal = false
    private var sendingVoice = false
    private var holdTarget: View? = null
    private var pendingCameraUri: Uri? = null
    private var dictateAfterPermission = false

    // ---- Views ----

    private val pill = ComposerPill(context, style)
    private val stripScroll = ScrollContainer(context).apply { orientation = ScrollContainer.HORIZONTAL }
    private val strip = LinearLayout(context)
    private val plusButton = iconButton(R.drawable.ic_composer_plus, R.string.composer_attach)
    private val dictationCancel = iconButton(R.drawable.ic_composer_close, R.string.composer_dictation_cancel)
    private val micButton = iconButton(R.drawable.ic_composer_mic, R.string.composer_mic)
    private val actionFill = GradientDrawable().apply { shape = GradientDrawable.OVAL }
    private val actionButton = iconButton(R.drawable.ic_composer_arrow_up, R.string.composer_send)
    private val confirmButton = iconButton(R.drawable.ic_composer_check, R.string.composer_dictation_confirm)
    private val timer = TextView(context)
    private val editText = EditText(context)
    private lateinit var row: ComposerRow
    private val dictationLayer = LinearLayout(context)
    private val dictationTranscript = TextView(context)
    private val dictationWave = VoiceWaveView(context, style)
    private val holdWave = VoiceWaveView(context, style)
    private val menu = AttachMenuView(context, style, onEntry = { entry ->
        // Like any menu, it closes as soon as a row is chosen; the picker opens over the page.
        closeMenu()
        when (entry) {
            AttachEntry.CAMERA -> launchCamera()
            AttachEntry.PHOTOS -> launchPhotos()
            AttachEntry.FILES -> launchFiles()
        }
    }, onDismiss = { closeMenu() })
    private val holdOverlay = HoldOverlayView(context, style)

    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            when {
                model.voice == VoiceMode.DICTATION -> cancelDictation()
                menu.shown -> closeMenu()
            }
        }
    }

    private var cameraLauncher: ActivityResultLauncher<Uri>? = null
    private var photosLauncher: ActivityResultLauncher<Int>? = null
    private var photoLauncher: ActivityResultLauncher<PickVisualMediaRequest>? = null
    private var documentLauncher: ActivityResultLauncher<Array<String>>? = null
    private var questionPhotosLauncher: ActivityResultLauncher<Int>? = null
    private var questionPhotoLauncher: ActivityResultLauncher<PickVisualMediaRequest>? = null
    /** The question card the photo picker is open for; kept across a recreation so its result still reaches it. */
    private var pickingQuestion: String? = null
    /** The photo picker's own cap; replaceable in tests. */
    internal var systemPhotoLimit: () -> Int = CappedPhotoPicker::systemLimit
    private var micPermissionLauncher: ActivityResultLauncher<String>? = null
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
        holdOverlay.visibility = GONE
        holdOverlay.alpha = 0f
        model.voiceAvailable = credentialProvider.isAvailable
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
            setPadding(style.dp(8), style.dp(8), style.dp(8), 0)
            addView(strip, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        }
        strip.orientation = LinearLayout.HORIZONTAL
        pill.addView(stripScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        val slot = style.dp(SLOT_DP)
        val button = style.dp(BUTTON_DP)

        val leading = FrameLayout(context)
        plusButton.setOnClickListener { if (menu.shown) closeMenu() else openMenu() }
        dictationCancel.background = circle(style.bgPrimary)
        dictationCancel.setOnClickListener { cancelDictation() }
        leading.addView(plusButton, LayoutParams(button, button, Gravity.CENTER))
        leading.addView(dictationCancel, LayoutParams(button, button, Gravity.CENTER))

        val center = FrameLayout(context)
        buildEditText()
        center.addView(editText, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        dictationLayer.apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = slot
            setPadding(style.dp(4), style.dp(12), 0, style.dp(12))
            dictationTranscript.apply {
                setTextColor(style.textPrimary)
                style.applyText(this, DesignTypography.Level.REGULAR)
                maxLines = 4
                ellipsize = TextUtils.TruncateAt.START
            }
            addView(dictationTranscript, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                bottomMargin = style.dp(4)
            })
            addView(dictationWave, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, style.dp(20)))
        }
        center.addView(dictationLayer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        center.addView(holdWave, LayoutParams(LayoutParams.MATCH_PARENT, style.dp(24), Gravity.CENTER_VERTICAL).apply {
            marginStart = style.dp(4)
        })

        val trailing = FrameLayout(context)
        micButton.setOnClickListener { startDictation() }
        actionButton.background = RippleDrawable(ColorStateList.valueOf(0x33FFFFFF), actionFill, null)
        actionButton.setOnClickListener { onActionTapped() }
        confirmButton.background = circle(style.brand)
        confirmButton.setColorFilter(style.onBrand)
        confirmButton.setOnClickListener { confirmDictation() }
        timer.apply {
            gravity = Gravity.CENTER
            setTextColor(style.textTertiary)
            style.applyText(this, DesignTypography.Level.SMALL)
            fontFeatureSettings = "tnum"
        }
        trailing.addView(micButton, LayoutParams(button, button, Gravity.CENTER))
        trailing.addView(actionButton, LayoutParams(button, button, Gravity.CENTER))
        trailing.addView(confirmButton, LayoutParams(button, button, Gravity.CENTER))
        trailing.addView(timer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        row = ComposerRow(context, style, leading, center, trailing, ::draftNeedsOwnRow).apply {
            // The strip beside the buttons of a stacked draft belongs to the field.
            isSoundEffectsEnabled = false
            setOnClickListener { if (model.voice == VoiceMode.NONE) showKeyboard() }
        }
        pill.addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }

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
        doAfterTextChanged {
            val before = model.text
            model.updateText(it?.toString().orEmpty())
            // The field travels between the two arrangements only while there is text to follow;
            // a cleared or freshly filled field simply appears in place as the surface resizes.
            row.refresh(animate = before.isNotEmpty() && model.text.isNotEmpty())
            render(animate = true)
        }
    }

    /** Voice always uses the single row; it only ever starts from an empty draft. */
    private fun draftNeedsOwnRow(inlineWidthPx: Int): Boolean =
        model.voice == VoiceMode.NONE && ComposerRow.needsOwnRow(
            editText.text, inlineWidthPx - editText.paddingLeft - editText.paddingRight,
        ) { Layout.getDesiredWidth(it, editText.paint) }

    private fun iconButton(icon: Int, description: Int) = PressableImageView(context).apply {
        onPressedChanged = { pressed -> scaleOf(this).setPressed(pressed) }
        setImageResource(icon)
        setColorFilter(style.fgPrimary)
        scaleType = ImageView.ScaleType.CENTER
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

    private var renderedTrailing: TrailingAction? = null

    private fun render(animate: Boolean) {
        val animated = animate && ComposerStyle.motionEnabled && isLaidOut
        val voice = model.voice
        setShown(plusButton, voice == VoiceMode.NONE, animated)
        setShown(dictationCancel, voice == VoiceMode.DICTATION, animated)
        editText.visibility = if (voice == VoiceMode.NONE) VISIBLE else INVISIBLE
        dictationLayer.visibility = if (voice == VoiceMode.DICTATION) VISIBLE else GONE
        holdWave.visibility = if (voice == VoiceMode.HOLD) VISIBLE else GONE
        setShown(confirmButton, voice == VoiceMode.DICTATION, animated)
        timer.visibility = if (voice == VoiceMode.HOLD) VISIBLE else GONE
        stripScroll.visibility = if (model.attachments.isNotEmpty()) VISIBLE else GONE
        row.refresh(animate = false)

        val trailing = model.trailingAction
        val idle = voice == VoiceMode.NONE
        setShown(micButton, idle && trailing == TrailingAction.MIC, animated)
        setShown(actionButton, idle && trailing != TrailingAction.MIC, animated)
        micButton.imageAlpha = if (model.voiceAvailable) 255 else DIMMED_IMAGE_ALPHA
        micButton.contentDescription = context.getString(
            if (model.voiceAvailable) R.string.composer_mic else R.string.composer_voice_unavailable,
        )
        if (trailing != TrailingAction.MIC) {
            if (trailing != renderedTrailing) {
                actionButton.setImageResource(R.drawable.ic_composer_arrow_up)
                actionButton.contentDescription = context.getString(R.string.composer_send)
            }
            // Keep send tappable to explain unfinished uploads; an empty draft sends nothing.
            actionFill.setColor(if (model.canSend) style.brand else style.textPlaceholder)
            actionButton.setColorFilter(style.onBrand)
        }
        renderedTrailing = trailing
        confirmButton.isEnabled = !awaitingFinal
        confirmButton.imageAlpha = if (awaitingFinal) DIMMED_IMAGE_ALPHA else 255
        plusButton.contentDescription = context.getString(
            if (menu.shown) R.string.composer_attach_close else R.string.composer_attach,
        )
        menu.bind(AttachMenuState.of(model))
        backCallback.isEnabled = menu.shown || voice == VoiceMode.DICTATION
    }

    /**
     * Buttons trade places in the same slot, never sliding: opacity fades on a duration and curve,
     * scale follows [DesignMotion.springScale] (see [ButtonScale]).
     */
    private fun setShown(view: View, shown: Boolean, animated: Boolean) {
        if (view.getTag(R.id.composer_shown) == shown) return
        view.setTag(R.id.composer_shown, shown)
        view.animate().cancel()
        val scale = scaleOf(view)
        if (!animated) {
            view.visibility = if (shown) VISIBLE else INVISIBLE
            view.alpha = if (shown) 1f else 0f
            scale.setShown(true, animated = false)
            return
        }
        if (shown) {
            if (view.visibility != VISIBLE) {
                view.alpha = 0f
                scale.setShown(false, animated = false)
                view.visibility = VISIBLE
            }
            view.animate().alpha(1f)
                .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                .setInterpolator(DesignMotion.softInOut)
                .start()
        } else {
            view.animate().alpha(0f)
                .setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                .setInterpolator(DesignMotion.softInOut)
                .withEndAction { if (view.getTag(R.id.composer_shown) == false) view.visibility = INVISIBLE }
                .start()
        }
        scale.setShown(shown, animated = true)
    }

    private fun scaleOf(view: View): ButtonScale = scales.getOrPut(view) { ButtonScale(view, action = true) }

    // ---- Send ----

    private fun onActionTapped() {
        when (model.trailingAction) {
            TrailingAction.SEND -> sendNow()
            TrailingAction.MIC -> Unit
        }
    }

    private fun sendNow() {
        if (submitting) return
        if (!model.canSend) {
            if (!model.uploadsSettled) toast(R.string.composer_uploads_pending)
            return
        }
        val draftText = model.text
        val outgoingText = draftText.trim()
        val outgoing = attachments
        sendingVoice = false
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
        val added = ids.mapIndexed { index, id -> ComposerAttachment(id, picked[index].first, picked[index].second) }
        added.forEach { attachment ->
            files[attachment.id] = attachment
            val thumb = AttachmentThumbView(context, style, attachment, ::removeAttachment) {
                onAttachmentRetry?.invoke(it)
            }
            thumbs[attachment.id] = thumb
            val size = style.dp(AttachmentThumbView.SIZE_DP)
            strip.addView(thumb, LinearLayout.LayoutParams(size, size).apply { marginEnd = style.dp(8) })
        }
        val dropped = picked.size - ids.size
        if (dropped > 0) toast(R.string.composer_attach_dropped, ComposerModel.MAX_ATTACHMENTS, dropped)
        render(animate = true)
        stripScroll.post { stripScroll.fullScroll(FOCUS_RIGHT) }
        if (added.isNotEmpty()) onAttachmentsAdded?.invoke(added)
    }

    private fun removeAttachment(id: String) {
        if (!model.removeAttachment(id)) return
        files.remove(id)
        thumbs.remove(id)?.let(strip::removeView)
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
            launcher.launch(uri)
        } catch (_: ActivityNotFoundException) {
            pendingCameraUri = null
            toast(R.string.composer_camera_unavailable)
        }
    }

    private fun launchPhotos() {
        when (val pick = PhotoPick.forRemaining(model.remainingSlots, systemPhotoLimit())) {
            PhotoPick.None -> toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
            PhotoPick.Single ->
                photoLauncher?.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
            is PhotoPick.Multiple -> photosLauncher?.launch(pick.limit)
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
                questionPhotoLauncher?.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            is PhotoPick.Multiple -> questionPhotosLauncher?.launch(pick.limit)
        }
    }

    private fun onQuestionPicked(picked: List<Uri>) {
        val question = pickingQuestion ?: return
        pickingQuestion = null
        if (picked.isNotEmpty()) onQuestionImagesPicked?.invoke(question, picked)
    }

    private fun launchFiles() {
        if (model.remainingSlots <= 0) return toast(R.string.composer_attach_limit, ComposerModel.MAX_ATTACHMENTS)
        try {
            // Any file: the core says which types it takes, as on every client.
            documentLauncher?.launch(arrayOf("*/*"))
        } catch (error: ActivityNotFoundException) {
            AppLog.warn(TAG, error, "No document picker")
        }
    }

    private fun onPicked(picked: List<Uri>) {
        if (picked.isEmpty()) return
        addUris(picked)
    }

    // ---- Attachment menu & keyboard ----

    private fun openMenu() {
        if (menu.shown) return
        // Above everything the host added after the composer (the task pill, for one).
        menu.bringToFront()
        applyTranslation()
        menu.show()
        rotatePlus(PLUS_OPEN_ROTATION)
        render(animate = true)
    }

    private fun closeMenu() {
        if (!menu.shown) return
        menu.hide()
        rotatePlus(0f)
        render(animate = true)
    }

    private val plusRotation = DesignSpring(plusButton, DynamicAnimation.ROTATION, DesignMotion.springRotation)

    private fun rotatePlus(degrees: Float) = plusRotation.animateTo(degrees)

    /** The single place the composer's vertical position is set; the menu rides along. */
    private fun applyTranslation() {
        val lifted = maxOf(imeOffset, navigationOffset)
        translationY = -lifted
        menu.follow(height, lifted, leading = left + paddingLeft)
        holdOverlay.setBottomClearance((lifted + height).toInt())
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
            if (imeVisible && !nowVisible) releaseFocusIfEmpty()
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

    private fun releaseFocusIfEmpty() {
        if (editText.text.isBlank()) editText.clearFocus()
    }

    private fun showKeyboard() {
        editText.requestFocus()
        editText.setSelection(editText.text.length)
        inputMethodManager().showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun hideKeyboard() {
        inputMethodManager().hideSoftInputFromWindow(editText.windowToken, 0)
        editText.clearFocus()
    }

    private fun inputMethodManager() =
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    // ---- Dictation (tap the microphone) ----

    private fun startDictation() {
        model.voiceAvailable = credentialProvider.isAvailable
        when (model.beginDictation()) {
            ComposerModel.VoiceStart.UNAVAILABLE -> return toast(R.string.composer_voice_unavailable)
            ComposerModel.VoiceStart.IGNORED -> return
            ComposerModel.VoiceStart.STARTED -> Unit
        }
        if (!hasMicPermission()) {
            model.endDictation(null, 0, 0)
            dictateAfterPermission = true
            requestMicPermission()
            return
        }
        hideKeyboard()
        closeMenu()
        awaitingFinal = false
        dictationTranscript.text = ""
        dictationTranscript.hint = context.getString(R.string.composer_listening)
        dictationTranscript.setHintTextColor(style.textPlaceholder)
        dictationWave.color = style.fgPrimary
        dictationWave.start()
        render(animate = true)
        startRecognizer(object : SpeechRecognizer.Callbacks {
            override fun onTranscript(text: String) {
                dictationTranscript.text = text
            }

            override fun onFinal(text: String) = finishDictation(text)

            override fun onError(error: AsrError) {
                finishDictation(null)
                toastFor(error)
            }

            override fun onSpectrum(bars: FloatArray) = dictationWave.setBars(bars)
        })
    }

    private fun confirmDictation() {
        if (model.voice != VoiceMode.DICTATION || awaitingFinal) return
        awaitingFinal = true
        dictationWave.stop()
        dictationTranscript.hint = context.getString(R.string.composer_recognizing)
        render(animate = true)
        val active = recognizer
        if (active == null) finishDictation(dictationTranscript.text?.toString()) else active.stop()
    }

    private fun cancelDictation() {
        if (model.voice != VoiceMode.DICTATION) return
        stopRecognizer()
        finishDictation(null)
    }

    private fun finishDictation(transcript: String?) {
        awaitingFinal = false
        dictationWave.stop()
        recognizer = null
        val insertion = model.endDictation(transcript, editText.selectionStart, editText.selectionEnd)
        if (insertion != null) {
            editText.setText(insertion.text)
            editText.setSelection(insertion.caret.coerceIn(0, editText.text.length))
        }
        render(animate = true)
    }

    // ---- Hold to talk ----

    private val longPressRunnable = Runnable { onLongPressElapsed() }
    private val holdTick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            when (val event = hold.tick(now)) {
                is HoldToTalk.Event.End -> return finishHold(event.cancelled)
                else -> Unit
            }
            val remaining = hold.remainingMs(now)
            val elapsed = (hold.maxDurationMs - remaining) / 1000
            timer.text = elapsedLabel(elapsed)
            holdOverlay.setAutoEndSeconds(
                if (remaining <= AUTO_END_WARNING_MS) ceil(remaining / 1000.0).toInt() else null,
            )
            postDelayed(this, HOLD_TICK_MS)
        }
    }

    /** Where a press can turn into hold-to-talk: the microphone, or the empty unfocused field. */
    private fun holdTargetAt(x: Float, y: Float): View? {
        if (model.voice != VoiceMode.NONE || awaitingFinal || model.hasContent) return null
        return when {
            micButton.visibility == VISIBLE && hitTest(micButton, x, y) -> micButton
            !editText.hasFocus() && editText.visibility == VISIBLE && hitTest(editText, x, y) -> editText
            else -> null
        }
    }

    private fun hitTest(view: View, x: Float, y: Float): Boolean {
        val here = IntArray(2)
        val there = IntArray(2)
        getLocationInWindow(here)
        view.getLocationInWindow(there)
        val left = there[0] - here[0]
        val top = there[1] - here[1]
        return x >= left && x < left + view.width && y >= top && y < top + view.height
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            val target = holdTargetAt(ev.x, ev.y) ?: return false
            holdTarget = target
            hold.down(ev.rawY, SystemClock.uptimeMillis())
            target.isPressed = true
            postDelayed(longPressRunnable, hold.longPressMs)
            return true
        }
        return false
    }

    @Suppress("ClickableViewAccessibility") // hold-to-talk has an accessible twin: tap to dictate
    override fun onTouchEvent(ev: MotionEvent): Boolean {
        if (holdTarget == null) return super.onTouchEvent(ev)
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE -> handleHoldEvent(hold.move(ev.rawY))
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPressRunnable)
                handleHoldEvent(hold.up())
                releaseHoldTarget()
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPressRunnable)
                handleHoldEvent(hold.cancel())
                releaseHoldTarget()
            }
        }
        return true
    }

    private fun releaseHoldTarget() {
        holdTarget?.isPressed = false
        holdTarget = null
    }

    private fun onLongPressElapsed() {
        val event = hold.longPressElapsed(SystemClock.uptimeMillis())
        if (event != HoldToTalk.Event.Start) return
        model.voiceAvailable = credentialProvider.isAvailable
        when (model.beginHold()) {
            ComposerModel.VoiceStart.UNAVAILABLE -> {
                hold.cancel()
                return toast(R.string.composer_voice_unavailable)
            }
            ComposerModel.VoiceStart.IGNORED -> {
                hold.cancel()
                return
            }
            ComposerModel.VoiceStart.STARTED -> Unit
        }
        if (!hasMicPermission()) {
            model.endHold(null, cancelled = true)
            hold.cancel()
            dictateAfterPermission = false
            requestMicPermission()
            return
        }
        holdTarget?.isPressed = false
        parent?.requestDisallowInterceptTouchEvent(true)
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        showHoldOverlay(true)
        holdWave.color = style.fgPrimary
        holdWave.start()
        timer.text = elapsedLabel(0)
        render(animate = true)
        postDelayed(holdTick, HOLD_TICK_MS)
        startRecognizer(object : SpeechRecognizer.Callbacks {
            override fun onTranscript(text: String) = holdOverlay.setTranscript(text)

            override fun onFinal(text: String) = deliverHold(text)

            override fun onError(error: AsrError) {
                removeCallbacks(holdTick)
                model.endHold(null, cancelled = true)
                endHoldUi()
                toastFor(error)
            }

            override fun onSpectrum(bars: FloatArray) = holdWave.setBars(bars)
        })
    }

    private fun handleHoldEvent(event: HoldToTalk.Event) {
        when (event) {
            is HoldToTalk.Event.Abandoned -> {
                removeCallbacks(longPressRunnable)
                if (event.wasTap) onHoldTargetTapped()
            }
            is HoldToTalk.Event.ZoneChanged -> {
                performHapticFeedback(HapticFeedbackConstants.SEGMENT_TICK)
                holdOverlay.setCancelZone(event.inCancelZone)
                holdWave.color = if (event.inCancelZone) style.textError else style.fgPrimary
                pill.setFillColor(if (event.inCancelZone) cancelTint() else style.composerBg)
            }
            is HoldToTalk.Event.End -> finishHold(event.cancelled)
            HoldToTalk.Event.Start, HoldToTalk.Event.None -> Unit
        }
    }

    private fun onHoldTargetTapped() {
        when (holdTarget) {
            micButton -> {
                micButton.performClick()
            }
            editText -> {
                performClick()
                showKeyboard()
            }
        }
    }

    private fun finishHold(cancelled: Boolean) {
        removeCallbacks(holdTick)
        if (model.voice != VoiceMode.HOLD) return
        if (cancelled) {
            performHapticFeedback(HapticFeedbackConstants.REJECT)
            stopRecognizer()
            model.endHold(null, cancelled = true)
            endHoldUi()
            return
        }
        awaitingFinal = true
        holdWave.stop()
        holdOverlay.showRecognizing()
        val active = recognizer
        if (active == null) deliverHold(null) else active.stop()
    }

    private fun deliverHold(transcript: String?) {
        awaitingFinal = false
        recognizer = null
        val send = model.endHold(transcript, cancelled = false)
        if (send != null) {
            holdOverlay.setTranscript(send)
            sendingVoice = true
            performHapticFeedback(HapticFeedbackConstants.CONFIRM)
            onVoiceSend?.invoke(send)
            sendingVoice = false
        } else {
            toast(R.string.composer_voice_empty)
        }
        endHoldUi()
    }

    private fun endHoldUi() {
        awaitingFinal = false
        holdWave.stop()
        pill.setFillColor(style.composerBg)
        showHoldOverlay(false)
        render(animate = true)
    }

    private fun showHoldOverlay(show: Boolean) {
        holdOverlay.animate().cancel()
        if (show) {
            holdOverlay.reset()
            // Over everything the host added after the composer (scroll-to-latest, the task pill).
            holdOverlay.bringToFront()
            holdOverlay.visibility = VISIBLE
            applyTranslation()
            if (ComposerStyle.motionEnabled) {
                holdOverlay.alpha = 0f
                holdOverlay.animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                    .setInterpolator(DesignMotion.smoothOut).start()
            } else {
                holdOverlay.alpha = 1f
            }
        } else if (ComposerStyle.motionEnabled) {
            holdOverlay.animate().alpha(0f).setDuration(DesignMotion.durationMillis(DesignMotion.feedbackOut))
                .withEndAction { holdOverlay.visibility = GONE }.start()
        } else {
            holdOverlay.visibility = GONE
        }
    }

    private fun elapsedLabel(seconds: Long): String =
        String.format(java.util.Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)

    private fun cancelTint(): Int {
        val error = style.textError
        // 12% of the error colour over the resting fill, opaque so the shadow never shows through.
        return ColorUtils.compositeColors((0x1F shl 24) or (error and 0x00FFFFFF), style.composerBg)
    }

    // ---- Recognizer ----

    private fun startRecognizer(callbacks: SpeechRecognizer.Callbacks) {
        stopRecognizer()
        val created = SpeechRecognizer(credentialProvider)
        recognizer = created
        created.start(callbacks)
    }

    private fun stopRecognizer() {
        recognizer?.cancel()
        recognizer = null
    }

    private fun toastFor(error: AsrError) = toast(
        when (error) {
            AsrError.NOT_CONFIGURED, AsrError.UNAUTHORIZED -> R.string.composer_voice_unavailable
            AsrError.MICROPHONE -> R.string.composer_asr_microphone
            AsrError.NETWORK -> R.string.composer_asr_network
            AsrError.SERVER -> R.string.composer_asr_failed
        },
    )

    // ---- Permissions & activity results ----

    private fun hasMicPermission() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission() {
        val launcher = micPermissionLauncher ?: return toast(R.string.composer_mic_denied)
        launcher.launch(Manifest.permission.RECORD_AUDIO)
    }

    private fun onMicPermissionResult(granted: Boolean) {
        val dictate = dictateAfterPermission
        dictateAfterPermission = false
        if (granted) {
            if (dictate) startDictation() else toast(R.string.composer_mic_granted_hold)
            return
        }
        val activity = hostActivity()
        val permanentlyDenied = activity != null &&
            !activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
        toast(if (permanentlyDenied) R.string.composer_mic_denied_forever else R.string.composer_mic_denied)
    }

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
        cameraLauncher = registry.register("$KEY_CAMERA.$slot", ActivityResultContracts.TakePicture()) { saved ->
            val uri = pendingCameraUri
            pendingCameraUri = null
            if (saved && uri != null) onPicked(listOf(uri))
        }
        photosLauncher = registry.register(
            "$KEY_PHOTOS.$slot", CappedPhotoPicker(ActivityResultContracts.PickVisualMedia.ImageAndVideo),
        ) { onPicked(it) }
        photoLauncher = registry.register("$KEY_PHOTO.$slot", ActivityResultContracts.PickVisualMedia()) { uri ->
            if (uri != null) onPicked(listOf(uri))
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
        micPermissionLauncher = registry.register(
            "$KEY_MIC.$slot", ActivityResultContracts.RequestPermission(), ::onMicPermissionResult,
        )
        activity.onBackPressedDispatcher.addCallback(backCallback)
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        removeCallbacks(longPressRunnable)
        removeCallbacks(holdTick)
        stopRecognizer()
        if (model.voice == VoiceMode.HOLD) model.endHold(null, cancelled = true)
        if (model.voice == VoiceMode.DICTATION) model.endDictation(null, 0, 0)
        listOf(cameraLauncher, photosLauncher, photoLauncher, documentLauncher, questionPhotosLauncher, questionPhotoLauncher,
            micPermissionLauncher).forEach { it?.unregister() }
        cameraLauncher = null
        photosLauncher = null
        photoLauncher = null
        documentLauncher = null
        questionPhotosLauncher = null
        questionPhotoLauncher = null
        micPermissionLauncher = null
        backCallback.remove()
        val activity = hostActivity() as? ComponentActivity
        if (activity != null && resultSlot >= 0) {
            activity.savedStateRegistry.unregisterSavedStateProvider("$KEY_STATE.$resultSlot")
            SLOTS[activity]?.remove(resultSlot)
        }
        resultSlot = -1
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

    private fun snapshotOf(source: TextView?, fromVoice: Boolean): ComposerSendSnapshot {
        val paint = TextPaint(source?.paint ?: editText.paint)
        val window = IntArray(2)
        val surface = RectF()
        val radius: Float
        if (fromVoice && source != null) {
            source.getLocationInWindow(window)
            surface.set(window[0].toFloat(), window[1].toFloat(), window[0] + source.width.toFloat(), window[1] + source.height.toFloat())
            radius = style.dp(20f)
        } else {
            pill.getLocationInWindow(window)
            surface.set(window[0].toFloat(), window[1].toFloat(), window[0] + pill.width.toFloat(), window[1] + pill.height.toFloat())
            radius = style.dp(ComposerPill.CORNER_DP.toFloat())
        }
        val text: CharSequence = source?.text?.toString().orEmpty()
        val live = source?.layout
        val origin = PointF()
        val frozen = if (source != null && live != null && text.isNotEmpty()) {
            if (fromVoice) freezeVoice(source, text, paint, origin, surface) else freeze(source, live, text, paint, live.width)
        } else null
        if (source != null && !fromVoice) {
            source.getLocationInWindow(window)
            origin.set(
                (window[0] + source.totalPaddingLeft).toFloat(),
                (window[1] + source.extendedPaddingTop - source.scrollY).toFloat(),
            )
        }
        val thumbnails = if (fromVoice) emptyList() else thumbs.values.map { thumb ->
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
        return ComposerSendSnapshot(text, frozen, paint, origin, surface, radius, thumbnails, fromVoice)
    }

    /**
     * The voice bubble has only just been given the final transcript and has not been laid out
     * with it, so the text is laid out here at its natural width (up to the bubble's widest),
     * centred where the bubble is centred. [origin] and [surface] are set.
     */
    private fun freezeVoice(source: TextView, text: CharSequence, paint: TextPaint, origin: PointF, surface: RectF): Layout {
        val window = IntArray(2)
        source.getLocationInWindow(window)
        val widest = ((hostRoot?.width ?: resources.displayMetrics.widthPixels) - style.dp(HoldOverlayView.SIDE_MARGIN_DP) * 2 -
            source.totalPaddingLeft - source.totalPaddingRight).coerceAtLeast(1)
        val width = kotlin.math.ceil(Layout.getDesiredWidth(text, paint)).toInt().coerceIn(1, widest)
        val centre = window[0] + source.width / 2f
        origin.set(centre - width / 2f, (window[1] + source.totalPaddingTop).toFloat())
        val layout = freeze(source, source.layout, text, paint, width)
        surface.set(origin.x - source.totalPaddingLeft, window[1].toFloat(), origin.x + width + source.totalPaddingRight,
            window[1] + source.totalPaddingTop + layout.height + source.totalPaddingBottom.toFloat())
        return layout
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
        const val BUTTON_DP = 36
        /** Page gutter beside the composer. */
        const val SIDE_DP = 24
        /** Above the composer, between it and the list. */
        const val TOP_DP = 8
        /** Under the composer, above the gesture bar (or the keyboard). */
        const val BOTTOM_DP = 20
        const val MAX_LINES = 6
        const val DIMMED_IMAGE_ALPHA = 102
        const val PLUS_OPEN_ROTATION = 45f
        const val CANCEL_DISTANCE_DP = 80
        const val HOLD_TICK_MS = 200L
        const val AUTO_END_WARNING_MS = 10_000L
        const val CAMERA_DIRECTORY = "composer-camera"
        const val KEY_CAMERA = "comma.composer.camera"
        const val KEY_PHOTOS = "comma.composer.photos"
        const val KEY_PHOTO = "comma.composer.photo"
        const val KEY_DOCUMENT = "comma.composer.document"
        const val KEY_QUESTION_PHOTOS = "comma.composer.question.photos"
        const val KEY_QUESTION_PHOTO = "comma.composer.question.photo"
        const val KEY_MIC = "comma.composer.mic"
        const val KEY_STATE = "comma.composer.state"
        const val STATE_CAMERA_URI = "cameraUri"
        const val STATE_QUESTION = "pickingQuestion"
        /** The places taken by each activity's attached composers; see [onAttachedToWindow]. */
        val SLOTS = java.util.WeakHashMap<Activity, MutableSet<Int>>()
    }
}
