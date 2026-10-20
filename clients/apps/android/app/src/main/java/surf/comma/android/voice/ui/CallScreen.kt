package surf.comma.android.voice.ui

import android.animation.ValueAnimator
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.graphics.ColorUtils
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.PressScale
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.voice.CallController
import surf.comma.android.voice.CallControllerState
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The call, over everything else in the chat: a full page while expanded, a dark card hanging
 * from the top of the screen while minimized. Both are this one surface, drawn from a single
 * spring-driven progress (0 expanded, 1 minimized): the frame, its colour, the mark, the two lines
 * of text and the button that switches between them all follow it, and the page's round buttons
 * hand over to the card's wide ones halfway.
 *
 * It only shows the call; [CallController] and its service own it. Leaving the page, rotating or
 * destroying the activity never ends the call. A finished call keeps its last words up for as
 * long as the service keeps its notification, then the surface fades out.
 */
class CallScreen(
    private val activity: ComponentActivity,
    private val controller: CallController = CallController.get(activity),
) : FrameLayout(activity) {
    private val density = resources.displayMetrics.density
    private val dark = AppearanceStore.isNight(activity)
    private val pageBg = activity.getColor(R.color.token_bg_primary)
    private val cardBg = activity.getColor(R.color.token_call_card_bg)
    private val cardBorder = activity.getColor(R.color.token_call_card_border)
    private val cardFg = activity.getColor(R.color.token_call_card_fg)
    private val cardControl = activity.getColor(R.color.token_call_card_control)
    private val cardControlOn = activity.getColor(R.color.token_call_card_control_on)
    private val fgPrimary = activity.getColor(R.color.token_fg_primary)
    private val textPrimary = activity.getColor(R.color.token_text_primary)
    private val textSecondary = activity.getColor(R.color.token_text_secondary)
    private val endFill = activity.getColor(R.color.token_fg_error)
    private val control = ColorUtils.setAlphaComponent(fgPrimary, CONTROL_ALPHA)

    /** 0 is the full page, 1 the card; the spring may carry it a little past either end. */
    private var progress = 0f
    private val spring = DesignSpring(this, PROGRESS, DesignMotion.springCall, minimumVisibleChange = 1f / 1000f)
    private val enterScaleX = DesignSpring(this, DynamicAnimation.SCALE_X, DesignMotion.springCall)
    private val enterScaleY = DesignSpring(this, DynamicAnimation.SCALE_Y, DesignMotion.springCall)
    private var fade: ValueAnimator? = null

    private var insetTop = 0
    private var insetBottom = 0
    private val card = RectF()
    private var radius = 0f
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1f }

    private val avatar = CallAvatar(activity, activity.getColor(R.color.token_label_success))
    private val name = TextView(activity).apply {
        DesignTypography.applyTo(this, Level.TITLE3, DesignFonts.semibold)
        setText(R.string.chat_brand_name)
        gravity = Gravity.CENTER
        maxLines = 1
        includeFontPadding = false
    }
    private val status = TextView(activity).apply {
        id = R.id.call_status
        DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.regular)
        fontFeatureSettings = "tnum"
        gravity = Gravity.CENTER
        maxLines = 3
        includeFontPadding = false
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE
    }
    private val toggle = ToggleButton()
    private val outputColumn = ControlColumn(R.id.call_output)
    private val muteColumn = ControlColumn(R.id.call_mute)
    private val endColumn = ControlColumn(R.id.call_end, end = true)
    private val controls = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        listOf(muteColumn, endColumn, outputColumn).forEach { column ->
            addView(column, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
    }
    private val outputPill = Pill(R.id.call_card_output)
    private val endPill = Pill(R.id.call_card_end, end = true)
    private val mutePill = Pill(R.id.call_card_mute)
    private val pills = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        listOf(outputPill, endPill, mutePill).forEach { addView(it, LinearLayout.LayoutParams(dp(PILL_WIDTH_DP), dp(PILL_HEIGHT_DP))) }
    }

    private val clock = Handler(Looper.getMainLooper())
    private val tick = Runnable { renderStatus() }
    private val dismiss = Runnable { dismissCurrent() }
    private var current = CallControllerState()
    private var shownKey: Long? = null
    private var outputSheet: AudioOutputSheet? = null
    private var lightStatusBars: Boolean? = null

    private val back = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = minimize()
    }

    init {
        id = R.id.call_screen
        visibility = GONE
        isClickable = true
        clipChildren = false
        setWillNotDraw(false)
        clipToOutline = true
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(card.left.roundToInt(), card.top.roundToInt(), card.right.roundToInt(),
                    card.bottom.roundToInt(), radius)
                outline.alpha = 1f
            }
        }
        addView(avatar, LayoutParams(dp(CallAvatar.BOX_DP), dp(CallAvatar.BOX_DP)))
        addView(name, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(status, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(controls, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(CONTROLS_SIDE_DP)
            marginEnd = dp(CONTROLS_SIDE_DP)
        })
        addView(pills, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(toggle, LayoutParams(dp(TOUCH_DP), dp(TOUCH_DP)))

        toggle.setOnClickListener { if (CallUiMemory.minimized) expand() else minimize() }
        outputColumn.button.setOnClickListener { openOutputs() }
        outputPill.setOnClickListener { openOutputs() }
        muteColumn.button.setOnClickListener { toggleMute() }
        mutePill.setOnClickListener { toggleMute() }
        endColumn.button.setOnClickListener { endNow() }
        endPill.setOnClickListener { endNow() }
        endColumn.label.setText(R.string.call_end)
        endColumn.button.contentDescription = activity.getString(R.string.call_end_call)
        endColumn.setIcon(R.drawable.ic_call_end)
        endPill.setIcon(R.drawable.ic_call_end)
        endPill.contentDescription = activity.getString(R.string.call_end_call)
        outputPill.contentDescription = activity.getString(R.string.call_output_title)

        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            insetTop = bars.top
            insetBottom = bars.bottom
            applyProgress()
            insets
        }
        addOnLayoutChangeListener { _, left, _, right, _, _, _, _, _ ->
            // A long notice wraps inside the name's 64 dp side padding.
            val maxWidth = (right - left - 2 * dp(TEXT_SIDE_DP)).coerceAtLeast(0)
            if (status.maxWidth != maxWidth) status.maxWidth = maxWidth
            applyProgress()
        }
        activity.onBackPressedDispatcher.addCallback(activity, back)
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                controller.state.collect(::render)
            }
        }
    }

    /** The surface's frame on screen, for tests. */
    internal fun cardTop() = card.top
    internal fun cardBottom() = card.bottom

    /** Opens the full page, e.g. from the top bar or the call notification. Starts nothing. */
    fun expand() {
        CallUiMemory.minimized = false
        if (visibility == VISIBLE) spring.animateTo(0f)
        back.isEnabled = visibility == VISIBLE
    }

    /** Folds the page into its card; the call goes on. */
    fun minimize() {
        if (visibility != VISIBLE) return
        CallUiMemory.minimized = true
        spring.animateTo(1f)
        back.isEnabled = false
    }

    /**
     * Shows the current finished state again even if it was already shown and put away: a start
     * refused for the microphone leaves the same state behind each time.
     */
    fun revealCurrent() {
        val state = controller.state.value
        val key = CallUiMemory.key(state)
        CallUiMemory.dismissed.remove(key)
        CallUiMemory.terminalAt.remove(key)
        if (shownKey == key) shownKey = null
        CallUiMemory.minimized = false
        render(state)
    }

    private fun render(state: CallControllerState) {
        current = state
        val key = CallUiMemory.key(state)
        if (!CallPresentation.isShown(state) || key in CallUiMemory.dismissed) {
            hide(animated = shownKey != null)
            return
        }
        if (shownKey != key) {
            val fresh = CallUiMemory.presentedKey != key
            if (fresh) {
                CallUiMemory.presentedKey = key
                CallUiMemory.minimized = false
            }
            shownKey = key
            show(enter = fresh)
        }
        val terminal = CallPresentation.isTerminal(state)
        if (terminal) {
            outputSheet?.dismiss()
            val at = CallUiMemory.terminalAt.getOrPut(key) { SystemClock.elapsedRealtime() }
            clock.removeCallbacks(dismiss)
            val dwell = if (key in CallUiMemory.ending) USER_END_DWELL_MS else CallPresentation.dwellMillis(state)
            clock.postDelayed(dismiss, max(0L, at + dwell - SystemClock.elapsedRealtime()))
        }
        val output = CallPresentation.output(state)
        val outputOn = CallPresentation.outputActive(state)
        outputColumn.setIcon(CallPresentation.outputIcon(output))
        outputColumn.label.setText(CallPresentation.outputLabel(output))
        outputColumn.button.contentDescription = activity.getString(R.string.call_output_title)
        outputColumn.setActive(outputOn)
        outputPill.setIcon(CallPresentation.outputIcon(output))
        outputPill.setActive(outputOn)
        val muteIcon = if (state.muted) R.drawable.ic_call_mic_off else R.drawable.ic_call_mic
        val muteLabel = activity.getString(if (state.muted) R.string.call_unmute else R.string.call_mute)
        muteColumn.setIcon(muteIcon)
        muteColumn.label.text = muteLabel
        muteColumn.button.contentDescription = muteLabel
        muteColumn.setActive(state.muted)
        mutePill.setIcon(muteIcon)
        mutePill.contentDescription = muteLabel
        mutePill.setActive(state.muted)
        listOf(outputColumn.button, muteColumn.button, endColumn.button, outputPill, mutePill, endPill)
            .forEach { it.isEnabled = !terminal && key !in CallUiMemory.ending }
        avatar.speaking = state.agentSpeaking && !terminal
        renderStatus()
        applyProgress()
    }

    private fun renderStatus() {
        clock.removeCallbacks(tick)
        val state = current
        val text = when (val value = CallPresentation.status(state, CallUiMemory.key(state) in CallUiMemory.ending)) {
            is CallStatus.Text -> activity.getString(value.res)
            is CallStatus.Notice -> value.text
            is CallStatus.Timer -> {
                val elapsed = SystemClock.elapsedRealtime() - value.connectedAtElapsedRealtime
                // Wake on the next whole second, not a second from now, so the timer never skips.
                clock.postDelayed(tick, SECOND - elapsed.mod(SECOND) + 1)
                CallPresentation.duration(elapsed / SECOND)
            }
        }
        if (status.text.toString() != text) status.text = text
    }

    private fun show(enter: Boolean) {
        fade?.cancel()
        visibility = VISIBLE
        bringToFront()
        val target = if (CallUiMemory.minimized) 1f else 0f
        spring.cancel()
        progress = target
        back.isEnabled = !CallUiMemory.minimized
        applyProgress()
        if (!enter || !ValueAnimator.areAnimatorsEnabled()) {
            alpha = 1f
            scaleX = 1f
            scaleY = 1f
            return
        }
        // Grows out of the top bar's Call button, at the top end.
        post { pivotX = width.toFloat(); pivotY = 0f }
        scaleX = ENTER_SCALE
        scaleY = ENTER_SCALE
        enterScaleX.animateTo(1f)
        enterScaleY.animateTo(1f)
        alpha = 0f
        fade = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = DesignMotion.durationMillis(DesignMotion.dialogEnter)
            interpolator = DesignMotion.smoothOut
            addUpdateListener { alpha = it.animatedValue as Float }
            start()
        }
    }

    private fun hide(animated: Boolean) {
        shownKey = null
        back.isEnabled = false
        clock.removeCallbacks(tick)
        clock.removeCallbacks(dismiss)
        outputSheet?.dismiss()
        avatar.speaking = false
        if (visibility != VISIBLE) {
            restoreStatusBars()
            return
        }
        fade?.cancel()
        val done = {
            visibility = GONE
            spring.cancel()
            progress = 0f
            restoreStatusBars()
        }
        if (!animated || !ValueAnimator.areAnimatorsEnabled()) {
            done()
            return
        }
        fade = ValueAnimator.ofFloat(alpha, 0f).apply {
            duration = DesignMotion.durationMillis(DesignMotion.dialogExit)
            interpolator = DesignMotion.softInOut
            addUpdateListener { alpha = it.animatedValue as Float }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                private var cancelled = false
                override fun onAnimationCancel(animation: android.animation.Animator) { cancelled = true }
                override fun onAnimationEnd(animation: android.animation.Animator) { if (!cancelled) done() }
            })
            start()
        }
    }

    private fun dismissCurrent() {
        CallUiMemory.dismissed += CallUiMemory.key(current)
        render(current)
    }

    private fun toggleMute() {
        if (current.busy) controller.setMuted(!current.muted)
    }

    private fun openOutputs() {
        if (!current.busy || outputSheet != null) return
        outputSheet = AudioOutputSheet(activity, controller) { outputSheet = null }.also { it.show() }
    }

    /**
     * One tap on either End ends the call, as on a phone. The page or card says "Call ended" at once
     * and goes after a short beat, without waiting for the service to close the call (up to 2 s)
     * and the longer dwell meant for calls the other side or an error ended.
     */
    private fun endNow() {
        if (!current.busy) return
        val key = CallUiMemory.key(current)
        if (key in CallUiMemory.ending) return
        CallUiMemory.ending += key
        CallUiMemory.terminalAt[key] = SystemClock.elapsedRealtime()
        controller.hangUp()
        render(current)
        clock.removeCallbacks(dismiss)
        clock.postDelayed(dismiss, USER_END_DWELL_MS)
    }

    /** Lays every part out for [progress]; also called each frame of the spring. */
    private fun applyProgress() {
        if (width == 0 || height == 0) return
        val p = progress
        val w = width.toFloat()
        val h = height.toFloat()
        val inset = dp(CARD_INSET_DP).toFloat()
        val miniBottom = miniCardBottom()
        card.set(lerp(0f, inset, p), lerp(0f, inset, p), lerp(w, w - inset, p), lerp(h, miniBottom, p))
        radius = max(0f, lerp(0f, dpf(CARD_RADIUS_DP), p))
        val colour = clamp01(p * COLOUR_LEAD)
        fill.color = ColorUtils.blendARGB(pageBg, cardBg, colour)
        edge.color = ColorUtils.setAlphaComponent(cardBorder, (Color.alpha(cardBorder) * clamp01(p)).roundToInt())
        val centreX = card.centerX()

        // iOS CallPage: equal flexible space above and below the identity, between the
        // top-left minimize target and the bottom row of Mute, End, and Output.
        val controlsTop = h - insetBottom - dpf(CONTROLS_BOTTOM_DP) - controls.height
        val headerBottom = insetTop + dpf(TOUCH_DP)
        val identityHeight = dpf(CallAvatar.BOX_DP + PAGE_NAME_GAP_DP + PAGE_STATUS_GAP_DP) + name.height + status.height
        val spacer = max(dpf(PAGE_SPACER_DP), (controlsTop - headerBottom - identityHeight) / 2f)
        val identityTop = headerBottom + spacer
        val pageAvatarTop = identityTop + dpf(CallAvatar.BOX_DP - AVATAR_DP) / 2f
        val logo = lerp(dpf(AVATAR_DP), dpf(CARD_AVATAR_DP), p)
        val avatarTop = lerp(pageAvatarTop, insetTop + dpf(CARD_AVATAR_TOP_DP), p)
        avatar.scaleX = logo / dpf(AVATAR_DP)
        avatar.scaleY = avatar.scaleX
        avatar.translationX = centreX - avatar.width / 2f
        avatar.translationY = avatarTop + logo / 2f - avatar.height / 2f

        val nameTop = lerp(identityTop + dpf(CallAvatar.BOX_DP + PAGE_NAME_GAP_DP),
            avatarTop + logo + dpf(NAME_GAP_DP), p)
        name.setTextColor(ColorUtils.blendARGB(textPrimary, cardFg, colour))
        name.translationX = centreX - name.width / 2f
        name.translationY = nameTop
        val statusCentre = lerp(nameTop + name.height + dpf(PAGE_STATUS_GAP_DP) + status.height / 2f,
            nameTop + name.height / 2f + dpf(CARD_STATUS_GAP_DP), p)
        status.setTextColor(ColorUtils.blendARGB(textSecondary,
            ColorUtils.setAlphaComponent(cardFg, CARD_STATUS_ALPHA), colour))
        status.scaleX = lerp(1f, CARD_STATUS_SCALE, p)
        status.scaleY = status.scaleX
        status.pivotX = status.width / 2f
        status.pivotY = status.height / 2f
        status.translationX = centreX - status.width / 2f
        status.translationY = statusCentre - status.height / 2f

        val toggleRight = card.right - dpf(CARD_TOGGLE_END_DP)
        toggle.translationX = lerp(dpf(PAGE_TOGGLE_SIDE_DP),
            toggleRight - dpf(TOGGLE_DP) - (toggle.width - dpf(TOGGLE_DP)) / 2f, p)
        toggle.translationY = lerp(insetTop.toFloat(),
            avatarTop + dpf(TOGGLE_TOP_DP) - (toggle.height - dpf(TOGGLE_DP)) / 2f, p)
        toggle.apply(p)

        val pageControls = clamp01(1f - p * HANDOVER)
        controls.alpha = pageControls
        controls.visibility = if (pageControls > 0f) VISIBLE else INVISIBLE
        controls.translationX = centreX - controls.width / 2f - controls.left
        controls.translationY = card.bottom - lerp(insetBottom.toFloat(), 0f, p) - dpf(CONTROLS_BOTTOM_DP) - controls.height
        val cardControls = clamp01(p * HANDOVER - (HANDOVER - 1f))
        pills.alpha = cardControls
        pills.visibility = if (cardControls > 0f) VISIBLE else INVISIBLE
        fitPills()
        pills.translationX = centreX - pills.width / 2f
        pills.translationY = miniBottom - dpf(PILLS_BOTTOM_DP) - dpf(PILL_HEIGHT_DP)
        val pageFirst = p < 0.5f
        listOf(outputColumn.button, muteColumn.button, endColumn.button).forEach { it.isClickable = pageFirst }
        listOf(outputPill, endPill, mutePill).forEach { it.isClickable = !pageFirst }

        elevation = dpf(CARD_ELEVATION_DP) * clamp01(p)
        invalidateOutline()
        invalidate()
        updateStatusBars()
    }

    /** The card's bottom edge: the mark, the two lines and the pills under the status bar. */
    private fun miniCardBottom(): Float {
        val nameTop = insetTop + dpf(CARD_AVATAR_TOP_DP) + dpf(CARD_AVATAR_DP) + dpf(NAME_GAP_DP)
        val statusCentre = nameTop + name.height / 2f + dpf(CARD_STATUS_GAP_DP)
        return statusCentre + dpf(CARD_PILLS_GAP_DP) + dpf(PILL_HEIGHT_DP) + dpf(PILLS_BOTTOM_DP)
    }

    /** Three 96 dp pills with 24 dp between, narrower only where the card cannot hold them. */
    private fun fitPills() {
        val room = card.width() - 2 * dpf(CARD_INSET_DP) - 2 * dpf(PILLS_SIDE_DP)
        val gap = if (3 * dpf(PILL_WIDTH_DP) + 2 * dpf(PILL_GAP_DP) <= room) dpf(PILL_GAP_DP) else dpf(PILL_GAP_TIGHT_DP)
        val pill = min(dpf(PILL_WIDTH_DP), (room - 2 * gap) / 3f).roundToInt()
        for (index in 0 until pills.childCount) {
            val params = pills.getChildAt(index).layoutParams as LinearLayout.LayoutParams
            val start = if (index > 0) gap.roundToInt() else 0
            if (params.width != pill || params.marginStart != start) {
                params.width = pill
                params.marginStart = start
                pills.getChildAt(index).layoutParams = params
            }
        }
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRoundRect(card, radius, radius, fill)
        if (Color.alpha(edge.color) > 0) {
            val half = edge.strokeWidth / 2f
            canvas.drawRoundRect(card.left + half, card.top + half, card.right - half, card.bottom - half,
                radius, radius, edge)
        }
    }

    /** Only the card takes touches; the chat around it keeps working. */
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN && !card.contains(event.x, event.y)) return false
        return super.dispatchTouchEvent(event)
    }

    override fun onDetachedFromWindow() {
        clock.removeCallbacksAndMessages(null)
        super.onDetachedFromWindow()
    }

    /** Light status bar icons while the dark card is under them; the page's own otherwise. */
    private fun updateStatusBars() {
        val overCard = visibility == VISIBLE && progress > STATUS_BAR_SWITCH
        apply(light = !dark && !overCard)
    }

    private fun restoreStatusBars() = apply(light = !dark)

    private fun apply(light: Boolean) {
        if (lightStatusBars == light) return
        lightStatusBars = light
        val window = activity.window ?: return
        WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = light
    }

    private fun dp(value: Int) = (value * density).roundToInt()
    private fun dpf(value: Int) = value * density
    private fun dpf(value: Float) = value * density

    /** The button between the mark and the edge: minimize on the page, expand on the card. */
    private inner class ToggleButton : FrameLayout(activity) {
        private val circle = GradientDrawable().apply { shape = GradientDrawable.OVAL }
        private val minimizeIcon = icon(R.drawable.ic_call_minimize, fgPrimary)
        private val expandIcon = icon(R.drawable.ic_call_expand, cardFg)

        init {
            id = R.id.call_toggle
            isClickable = true
            isFocusable = true
            val inset = dp(TOUCH_DP - TOGGLE_DP) / 2
            background = android.graphics.drawable.InsetDrawable(circle, inset)
            addView(minimizeIcon, LayoutParams(dp(TOGGLE_ICON_DP), dp(TOGGLE_ICON_DP), Gravity.CENTER))
            addView(expandIcon, LayoutParams(dp(TOGGLE_ICON_DP), dp(TOGGLE_ICON_DP), Gravity.CENTER))
            PressScale(this)
        }

        fun apply(p: Float) {
            circle.setColor(ColorUtils.blendARGB(Color.TRANSPARENT, cardControl, clamp01(p * COLOUR_LEAD)))
            minimizeIcon.alpha = clamp01(1f - p * 2f)
            expandIcon.alpha = clamp01(p * 2f - 1f)
            contentDescription = activity.getString(if (p < 0.5f) R.string.call_minimize else R.string.call_expand)
        }
    }

    /** A round page button with its label under it. */
    private inner class ControlColumn(buttonId: Int, private val end: Boolean = false) : LinearLayout(activity) {
        val button = FrameLayout(activity).apply {
            id = buttonId
            isClickable = true
            isFocusable = true
        }
        private val circle = GradientDrawable().apply { shape = GradientDrawable.OVAL }
        private val glyph = ImageView(activity).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
        val label = TextView(activity).apply {
            DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
            setTextColor(textSecondary)
            gravity = Gravity.CENTER
            maxLines = 1
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        init {
            orientation = VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            button.background = circle
            val iconSize = dp(if (end) END_ICON_DP else CONTROL_ICON_DP)
            button.addView(glyph, FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER))
            addView(button, LayoutParams(dp(CONTROL_DP), dp(CONTROL_DP)))
            addView(label, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = dp(LABEL_GAP_DP) })
            PressScale(button)
            setActive(false)
        }

        fun setIcon(res: Int) = glyph.setImageResource(res)

        fun setActive(active: Boolean) {
            when {
                end -> { circle.setColor(endFill); glyph.setColorFilter(Color.WHITE) }
                active -> { circle.setColor(textPrimary); glyph.setColorFilter(pageBg) }
                else -> { circle.setColor(control); glyph.setColorFilter(fgPrimary) }
            }
        }
    }

    /** A wide button on the card. */
    private inner class Pill(pillId: Int, private val end: Boolean = false) : FrameLayout(activity) {
        private val shape = GradientDrawable().apply { cornerRadius = dpf(PILL_HEIGHT_DP) / 2f }
        private val glyph = ImageView(activity).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

        init {
            id = pillId
            isFocusable = true
            background = shape
            addView(glyph, LayoutParams(dp(PILL_ICON_DP), dp(PILL_ICON_DP), Gravity.CENTER))
            PressScale(this)
            setActive(false)
        }

        fun setIcon(res: Int) = glyph.setImageResource(res)

        fun setActive(active: Boolean) {
            when {
                end -> { shape.setColor(endFill); glyph.setColorFilter(cardFg) }
                active -> { shape.setColor(cardControlOn); glyph.setColorFilter(cardBg) }
                else -> { shape.setColor(cardControl); glyph.setColorFilter(cardFg) }
            }
        }
    }

    private fun icon(res: Int, tint: Int) = ImageView(activity).apply {
        setImageResource(res)
        setColorFilter(tint)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    private companion object {
        val PROGRESS = object : FloatPropertyCompat<CallScreen>("callProgress") {
            override fun getValue(view: CallScreen) = view.progress
            override fun setValue(view: CallScreen, value: Float) {
                view.progress = value
                view.applyProgress()
            }
        }

        fun lerp(from: Float, to: Float, p: Float) = from + (to - from) * p
        fun clamp01(value: Float) = value.coerceIn(0f, 1f)

        const val SECOND = 1_000L
        /** How long "Call ended" stays after the user's own End. */
        const val USER_END_DWELL_MS = 800L
        const val ENTER_SCALE = 0.96f
        /** Colours reach the card's a little before the frame does. */
        const val COLOUR_LEAD = 1.4f
        /** The page's buttons are gone by 45 %, the card's start at 55 %. */
        const val HANDOVER = 2.2f
        const val STATUS_BAR_SWITCH = 0.35f
        /** The page's round buttons: the foreground at 14 % (of 255). */
        const val CONTROL_ALPHA = 0x24
        /** The card's status line: white at 85 %. */
        const val CARD_STATUS_ALPHA = 0xD9
        val CARD_STATUS_SCALE = 16f / DesignTypography.regular.sp

        const val CARD_INSET_DP = 8
        const val CARD_RADIUS_DP = 40
        const val CARD_ELEVATION_DP = 16
        const val AVATAR_DP = CallAvatar.AVATAR_DP
        const val CARD_AVATAR_DP = 74
        const val CARD_AVATAR_TOP_DP = 10
        /** Clear of the speaking ring, which reaches 9 dp past the mark. */
        const val NAME_GAP_DP = 14
        const val PAGE_NAME_GAP_DP = 28
        const val PAGE_STATUS_GAP_DP = 6
        const val PAGE_SPACER_DP = 24
        const val CARD_STATUS_GAP_DP = 38
        const val CARD_PILLS_GAP_DP = 36
        const val PILLS_BOTTOM_DP = 26
        const val PILL_WIDTH_DP = 96
        const val PILL_HEIGHT_DP = 46
        const val PILL_GAP_DP = 24
        const val PILL_GAP_TIGHT_DP = 16
        const val PILLS_SIDE_DP = 4
        const val PILL_ICON_DP = 24
        const val TOUCH_DP = 48
        const val TOGGLE_DP = 42
        const val TOGGLE_ICON_DP = 20
        const val TOGGLE_TOP_DP = 2
        const val PAGE_TOGGLE_SIDE_DP = 8
        const val CARD_TOGGLE_END_DP = 20
        const val CONTROL_DP = 80
        const val CONTROL_ICON_DP = 30
        const val END_ICON_DP = 32
        const val CONTROLS_SIDE_DP = 24
        const val LABEL_GAP_DP = 8
        const val CONTROLS_BOTTOM_DP = 40
        const val TEXT_SIDE_DP = 64
    }
}

/**
 * What the call UI remembers across activity recreation (rotation, leaving and coming back), for
 * as long as the process lives: the controller remembers the call, this how it was being shown.
 */
internal object CallUiMemory {
    var minimized = false
    /** The call (or finished-call state) last put on screen; a different one starts expanded. */
    var presentedKey: Long? = null
    val terminalAt = HashMap<Long, Long>()
    val dismissed = HashSet<Long>()
    /** Calls the user ended here, shown as "Ending…" until the service catches up. */
    val ending = HashSet<Long>()

    /** A call's id; the id-less states (a refused or recovered start) by identity. */
    fun key(state: CallControllerState): Long =
        if (state.id != 0L) state.id else -(System.identityHashCode(state).toLong() + 1)
}
