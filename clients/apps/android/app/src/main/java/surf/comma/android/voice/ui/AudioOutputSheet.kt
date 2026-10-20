package surf.comma.android.voice.ui

import android.animation.ValueAnimator
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.dp
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.voice.CallAudioOutput
import surf.comma.android.voice.CallController
import surf.comma.android.voice.CallControllerState

/**
 * "Change audio output": a sheet from the bottom with the four outputs, the current one marked
 * Selected and the ones not connected greyed out. It follows the call while open, so plugging in
 * headphones lights their row; picking one switches the call and closes the sheet.
 */
internal class AudioOutputSheet(
    private val activity: ComponentActivity,
    private val controller: CallController,
    private val onClosed: () -> Unit,
) {
    private val dialog = Dialog(activity, R.style.Theme_Comma_Settings)
    private val scrim = View(activity).apply { setBackgroundColor(activity.getColor(R.color.token_bg_overlay)); alpha = 0f }
    private val rows = CallAudioOutput.entries.associateWith { Row(it) }
    private val list = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        rows.values.forEach { addView(it, LinearLayout.LayoutParams(-1, activity.dp(ROW_DP))) }
    }
    private val sheet = LinearLayout(activity).apply {
        id = R.id.call_output_sheet
        orientation = LinearLayout.VERTICAL
        isClickable = true
        val radius = activity.dp(RADIUS_DP).toFloat()
        background = GradientDrawable().apply {
            setColor(activity.getColor(R.color.token_bg_primary))
            cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
        }
        addView(View(activity).apply {
            background = GradientDrawable().apply {
                cornerRadius = activity.dp(2).toFloat()
                setColor(activity.getColor(R.color.token_border_primary))
            }
        }, LinearLayout.LayoutParams(activity.dp(36), activity.dp(4)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = activity.dp(10)
        })
        addView(TextView(activity).apply {
            DesignTypography.applyTo(this, Level.LARGE, DesignFonts.semibold)
            setTextColor(activity.getColor(R.color.token_text_primary))
            setText(R.string.call_output_title)
            isAccessibilityHeading = true
        }, LinearLayout.LayoutParams(-1, -2).apply {
            marginStart = activity.dp(SIDE_DP)
            marginEnd = activity.dp(SIDE_DP)
            topMargin = activity.dp(14)
            bottomMargin = activity.dp(8)
        })
        addView(ScrollContainer(activity).apply {
            isVerticalScrollBarEnabled = false
            addView(list, FrameLayout.LayoutParams(-1, -2))
        }, LinearLayout.LayoutParams(-1, -2))
    }
    private val slide = DesignSpring(sheet, DynamicAnimation.TRANSLATION_Y, DesignMotion.springSpatial)
    private var fade: ValueAnimator? = null
    private var watching: Job? = null
    private var closing = false

    init {
        val root = FrameLayout(activity).apply {
            addView(scrim, FrameLayout.LayoutParams(-1, -1))
            addView(sheet, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
            setOnClickListener { dismiss() }
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            list.setPadding(0, 0, 0, bars.bottom + activity.dp(BOTTOM_DP))
            (sheet.layoutParams as FrameLayout.LayoutParams).topMargin = bars.top + activity.dp(TOP_ROOM_DP)
            WindowInsetsCompat.CONSUMED
        }
        dialog.setContentView(root)
        dialog.window?.apply {
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
            WindowCompat.getInsetsController(this, decorView).isAppearanceLightNavigationBars = !AppearanceStore.isNight(activity)
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setWindowAnimations(0)
            setDimAmount(0f)
            setDecorFitsSystemWindows(false)
        }
        dialog.setOnKeyListener { _, keyCode, event ->
            if (keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) { dismiss(); true } else false
        }
        dialog.setOnShowListener { enter() }
        activity.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                fade?.cancel()
                watching?.cancel()
                if (dialog.isShowing) dialog.dismiss()
            }
        })
    }

    fun show() {
        if (activity.isFinishing) return
        render(controller.state.value)
        watching = activity.lifecycleScope.launch { controller.state.collect(::render) }
        dialog.show()
    }

    fun dismiss() {
        if (closing || !dialog.isShowing) return
        closing = true
        watching?.cancel()
        onClosed()
        fade(entering = false)
        slide.animateTo(sheet.height.toFloat())
    }

    private fun enter() {
        sheet.doOnLayout {
            sheet.translationY = sheet.height.toFloat()
            slide.animateTo(0f)
        }
        fade(entering = true)
    }

    private fun fade(entering: Boolean) {
        fade?.cancel()
        fade = ValueAnimator.ofFloat(scrim.alpha / SCRIM_ALPHA, if (entering) 1f else 0f).apply {
            duration = DesignMotion.durationMillis(if (entering) DesignMotion.dialogEnter else DesignMotion.dialogExit)
            interpolator = DesignMotion.drawer
            addUpdateListener { scrim.alpha = (it.animatedValue as Float) * SCRIM_ALPHA }
            if (!entering) addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (dialog.isShowing) dialog.dismiss()
                }
            })
            start()
        }
    }

    private fun render(state: CallControllerState) {
        if (!state.busy) {
            dismiss()
            return
        }
        val selected = state.selected
        rows.forEach { (output, row) -> row.bind(available = output in state.outputs, selected = output == selected) }
    }

    private inner class Row(private val output: CallAudioOutput) : LinearLayout(activity) {
        private val mark = TextView(activity).apply {
            DesignTypography.applyTo(this, Level.SMALL)
            setTextColor(activity.getColor(R.color.token_text_tertiary))
            setText(R.string.call_output_selected)
        }

        init {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(SIDE_DP), 0, activity.dp(SIDE_DP), 0)
            addView(ImageView(activity).apply {
                setImageResource(CallPresentation.outputIcon(output))
                setColorFilter(activity.getColor(R.color.token_fg_primary))
                importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LayoutParams(activity.dp(24), activity.dp(24)))
            addView(TextView(activity).apply {
                DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.medium)
                setTextColor(activity.getColor(R.color.token_text_primary))
                setText(CallPresentation.outputLabel(output))
            }, LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(14) })
            addView(mark, LayoutParams(-2, -2))
            isClickable = true
            isFocusable = true
            PressFeedback(this, R.color.token_bg_quaternary, scale = false)
            setOnClickListener {
                controller.select(output)
                postDelayed({ dismiss() }, PICKED_MS)
            }
        }

        fun bind(available: Boolean, selected: Boolean) {
            isEnabled = available
            alpha = if (available) 1f else DISABLED_ALPHA
            mark.visibility = if (selected) VISIBLE else GONE
            isSelected = selected
        }
    }

    private companion object {
        const val SCRIM_ALPHA = 0.4f
        const val DISABLED_ALPHA = 0.35f
        const val RADIUS_DP = 28
        const val ROW_DP = 56
        const val SIDE_DP = 24
        const val BOTTOM_DP = 16
        /** The sheet never climbs closer than this under the status bar. */
        const val TOP_ROOM_DP = 48
        /** Long enough to see the pick land before the sheet goes. */
        const val PICKED_MS = 120L
    }
}
