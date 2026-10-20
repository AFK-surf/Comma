package surf.comma.android.settings

import android.animation.ValueAnimator
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import androidx.annotation.ColorRes
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.R
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A centred card over a dimmed page. The dimming and the card's opacity use the dialog timings;
 * the card's scale uses the scale spring. Dismissing plays the exit before the window goes.
 */
internal open class SettingsDialog(private val activity: Activity, keyboard: Boolean = false) {
    // The app's translucent theme: transparent system bars with the right icon colours.
    private val dialog = Dialog(activity, R.style.Theme_Comma_Settings)
    private val scrim = View(activity).apply { setBackgroundColor(activity.color(R.color.token_bg_overlay)); alpha = 0f }
    protected val card = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        val radius = activity.dp(20).toFloat()
        background = roundRect(activity.color(R.color.token_bg_primary), radius)
        clipToRoundedBackground(radius)
        setPadding(activity.dp(20), activity.dp(20), activity.dp(20), activity.dp(16))
        isClickable = true
        alpha = 0f
    }
    private val scaleX = DesignSpring(card, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val scaleY = DesignSpring(card, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    private var fade: ValueAnimator? = null
    private var closing = false

    init {
        // The dimming covers the system bars too; only the card keeps clear of them and the keyboard.
        val content = FrameLayout(activity).apply {
            addView(card, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER).apply {
                marginStart = activity.dp(24)
                marginEnd = activity.dp(24)
            })
        }
        val root = FrameLayout(activity).apply {
            addView(scrim, FrameLayout.LayoutParams(-1, -1))
            addView(content, FrameLayout.LayoutParams(-1, -1))
            setOnClickListener { dismiss() }
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            content.setPadding(0, bars.top, 0, bars.bottom)
            WindowInsetsCompat.CONSUMED
        }
        dialog.setContentView(root)
        dialog.window?.apply {
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
            val light = !surf.comma.android.ui.AppearanceStore.isNight(activity)
            androidx.core.view.WindowCompat.getInsetsController(this, decorView).apply {
                isAppearanceLightStatusBars = light
                isAppearanceLightNavigationBars = light
            }
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setWindowAnimations(0)
            setDimAmount(0f)
            setDecorFitsSystemWindows(false)
            // [keyboard]: a dialog built around a text field opens with the keyboard up.
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING or
                if (keyboard) WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE else 0)
        }
        dialog.setOnKeyListener { _, keyCode, event ->
            if (keyCode == android.view.KeyEvent.KEYCODE_BACK && event.action == android.view.KeyEvent.ACTION_UP) { dismiss(); true } else false
        }
        dialog.setOnShowListener { animate(entering = true) }
        // Signing out can finish the activity while the exit is still playing; the window goes with it.
        (activity as? androidx.lifecycle.LifecycleOwner)?.lifecycle?.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onDestroy(owner: androidx.lifecycle.LifecycleOwner) {
                fade?.cancel()
                if (dialog.isShowing) dialog.dismiss()
            }
        })
    }

    fun show() {
        if (!activity.isFinishing) dialog.show()
    }

    fun dismiss() {
        if (closing || !dialog.isShowing) return
        closing = true
        onClosing()
        animate(entering = false)
    }

    protected open fun onClosing() {}

    private fun animate(entering: Boolean) {
        fade?.cancel()
        val from = if (entering) 0f else card.alpha
        fade = ValueAnimator.ofFloat(from, if (entering) 1f else 0f).apply {
            duration = DesignMotion.durationMillis(if (entering) DesignMotion.dialogEnter else DesignMotion.dialogExit)
            interpolator = if (entering) DesignMotion.smoothOut else DesignMotion.softInOut
            addUpdateListener {
                val value = it.animatedValue as Float
                card.alpha = value
                scrim.alpha = value * SCRIM_ALPHA
            }
            if (!entering) doOnEnd { if (dialog.isShowing) dialog.dismiss() }
            start()
        }
        if (entering) {
            card.scaleX = ENTER_SCALE
            card.scaleY = ENTER_SCALE
        }
        val target = if (entering) 1f else ENTER_SCALE
        scaleX.animateTo(target)
        scaleY.animateTo(target)
    }

    protected fun title(text: CharSequence) = activity.text(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply {
        this.text = text
        isAccessibilityHeading = true
    }

    protected fun message(text: CharSequence) = activity.text(Level.REGULAR, R.color.token_text_tertiary).apply { this.text = text }

    /** Cancel and confirm side by side. */
    protected fun buttons(confirm: CharSequence, destructive: Boolean, onConfirm: () -> Unit): LinearLayout =
        LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            val cancel = button(activity.getString(R.string.settings_cancel), R.color.token_bg_quaternary, R.color.token_text_primary)
            cancel.setOnClickListener { dismiss() }
            val ok = button(confirm, if (destructive) R.color.token_fg_error else R.color.token_bg_brand_solid, null)
            ok.id = R.id.settings_dialog_confirm
            ok.setOnClickListener {
                onConfirm()
                dismiss()
            }
            addView(cancel, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
            addView(ok, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(8) })
        }

    protected fun button(label: CharSequence, fill: Int, textColor: Int?): TextView = activity.filledButton(label, fill, textColor)

    private fun ValueAnimator.doOnEnd(action: () -> Unit) = addListener(object : android.animation.AnimatorListenerAdapter() {
        override fun onAnimationEnd(animation: android.animation.Animator) = action()
    })

    private companion object {
        const val SCRIM_ALPHA = 0.4f
        const val ENTER_SCALE = 0.96f
    }
}

/** A filled button; [textColor] null means white, for the brand and error fills. */
internal fun Context.filledButton(label: CharSequence, @ColorRes fill: Int, @ColorRes textColor: Int?): TextView =
    text(Level.REGULAR, textColor ?: R.color.token_text_primary, DesignFonts.medium).apply {
        text = label
        gravity = Gravity.CENTER
        // White on the brand and error fills, as on the other filled buttons.
        if (textColor == null) setTextColor(Color.WHITE)
        val radius = dp(12).toFloat()
        background = roundRect(color(fill), radius)
        isClickable = true
        PressScale(this)
    }

/** Spring press scale for filled buttons, which keep their own background. */
internal class PressScale(view: View) {
    private val x = DesignSpring(view, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val y = DesignSpring(view, DynamicAnimation.SCALE_Y, DesignMotion.springScale)

    init {
        view.setOnTouchListener { v, event ->
            val target = when (event.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> if (v.isEnabled) DesignMotion.pressScale(action = true) else null
                android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> 1f
                else -> null
            }
            if (target != null) { x.animateTo(target); y.animateTo(target) }
            false
        }
    }
}

/** Asks before something that cannot be undone from here. */
internal class ConfirmDialog(
    activity: Activity,
    title: CharSequence,
    message: CharSequence,
    confirm: CharSequence,
    destructive: Boolean,
    onConfirm: () -> Unit,
) : SettingsDialog(activity) {
    init {
        card.addView(title(title))
        card.addView(message(message), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        card.addView(buttons(confirm, destructive, onConfirm), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }
}

/**
 * A one-field prompt: a title, an optional description, the field, then Cancel and Save, which stays off until the
 * trimmed value is new and [refused] lets it through. [problem] is the message under the field for a refused value,
 * null to say nothing.
 */
internal open class FieldDialog(
    private val activity: Activity,
    title: CharSequence,
    hint: CharSequence,
    current: String,
    saveLabel: CharSequence,
    inputType: Int,
    maxLength: Int,
    onSave: (String) -> Unit,
    description: CharSequence? = null,
    inputId: Int = View.NO_ID,
    keyboard: Boolean = false,
    refused: (String) -> Boolean = { it.isBlank() },
    problem: (String) -> CharSequence? = { null },
) : SettingsDialog(activity, keyboard) {
    private val input = EditText(activity).apply {
        id = inputId
        setText(current)
        setSelection(text.length)
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.color(R.color.token_text_primary))
        setHintTextColor(activity.color(R.color.token_text_placeholder))
        this.hint = hint
        this.inputType = inputType
        imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        isSingleLine = true
        background = roundRect(activity.color(R.color.token_bg_quaternary), activity.dp(10).toFloat())
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
        filters = arrayOf(android.text.InputFilter.LengthFilter(maxLength))
    }
    private val error = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val save: TextView

    init {
        card.addView(title(title))
        if (description != null) card.addView(message(description).apply {
            DesignTypography.applyTo(this, Level.SMALL)
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        card.addView(input, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(16) })
        card.addView(error, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        val row = buttons(saveLabel, destructive = false) { onSave(input.text.toString().trim()) }
        save = row.findViewById(R.id.settings_dialog_confirm)
        card.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        val original = current.trim()
        fun validate() {
            val value = input.text.toString()
            val message = problem(value)
            error.isVisible = message != null
            error.text = message
            val enabled = !refused(value) && value.trim() != original
            save.isEnabled = enabled
            save.alpha = if (enabled) 1f else 0.4f
        }
        input.doAfterTextChanged { validate() }
        input.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_DONE && save.isEnabled) { save.performClick(); true } else false
        }
        validate()
        input.post {
            input.requestFocus()
            activity.getSystemService(InputMethodManager::class.java).showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    override fun onClosing() {
        activity.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(input.windowToken, 0)
    }
}

/** Edits the display name: trimmed, not empty, at most 64 characters; Save stays off until it changes. */
internal class NameDialog(activity: Activity, current: String, onSave: (String) -> Unit) : FieldDialog(
    activity,
    title = activity.getString(R.string.settings_name),
    hint = activity.getString(R.string.settings_name),
    current = current,
    saveLabel = activity.getString(R.string.settings_save),
    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PERSON_NAME or InputType.TYPE_TEXT_FLAG_CAP_WORDS,
    // One more than the limit so an over-long name shows the message instead of being cut.
    maxLength = ProfileRules.MAX_NAME_LENGTH * 2 + 1,
    onSave = onSave,
    description = activity.getString(R.string.settings_name_description),
    inputId = R.id.settings_name_input,
    refused = { ProfileRules.problem(it) != null },
    problem = { value ->
        activity.getString(R.string.settings_name_too_long).takeIf { ProfileRules.problem(value) == SettingsProblem.NAME_TOO_LONG }
    },
)

/**
 * The options of a setting, anchored under its row like a menu, with the current one checked.
 * Opacity uses the menu timings; the scale uses the scale spring.
 */
internal object ChoiceMenu {
    fun show(anchor: View, options: List<CharSequence>, selected: Int, onPick: (Int) -> Unit) {
        val context = anchor.context
        val list = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val radius = context.dp(12).toFloat()
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = radius
                setColor(context.color(R.color.token_bg_secondary))
                setStroke(1, context.color(R.color.token_border_primary))
            }
            clipToRoundedBackground(radius)
            setPadding(0, context.dp(4), 0, context.dp(4))
            alpha = 0f
        }
        val popup = PopupWindow(list, context.dp(220), ViewGroup.LayoutParams.WRAP_CONTENT, true).apply {
            animationStyle = 0
            isOutsideTouchable = true
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            elevation = 0f
        }
        options.forEachIndexed { index, label ->
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = context.dp(44)
                setPadding(context.dp(14), 0, context.dp(12), 0)
                addView(context.text(Level.REGULAR, R.color.token_text_primary).apply { text = label },
                    LinearLayout.LayoutParams(0, -2, 1f))
                addView(ImageView(context).apply {
                    setImageResource(R.drawable.ic_composer_check)
                    imageTintList = ColorStateList.valueOf(context.color(R.color.token_fg_primary))
                    visibility = if (index == selected) View.VISIBLE else View.INVISIBLE
                }, LinearLayout.LayoutParams(context.dp(18), context.dp(18)))
                isSelected = index == selected
                contentDescription = label
                PressFeedback(this, R.color.token_bg_quaternary, scale = false)
                setOnClickListener {
                    popup.dismiss()
                    if (index != selected) onPick(index)
                }
            }
            list.addView(row, LinearLayout.LayoutParams(-1, -2))
        }
        list.measure(View.MeasureSpec.makeMeasureSpec(context.dp(220), View.MeasureSpec.EXACTLY), View.MeasureSpec.UNSPECIFIED)
        popup.showAsDropDown(anchor, anchor.width - context.dp(220) - context.dp(8), -context.dp(4), Gravity.NO_GRAVITY)
        list.pivotX = context.dp(220).toFloat()
        list.pivotY = 0f
        list.scaleX = 0.96f
        list.scaleY = 0.96f
        DesignSpring(list, DynamicAnimation.SCALE_X, DesignMotion.springScale).animateTo(1f)
        DesignSpring(list, DynamicAnimation.SCALE_Y, DesignMotion.springScale).animateTo(1f)
        ValueAnimator.ofFloat(0f, 1f).apply {
            duration = DesignMotion.durationMillis(DesignMotion.menuEnter)
            interpolator = DesignMotion.smoothOut
            addUpdateListener { list.alpha = it.animatedValue as Float }
            start()
        }
    }
}
