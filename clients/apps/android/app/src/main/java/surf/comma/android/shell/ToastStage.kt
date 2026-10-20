package surf.comma.android.shell

import android.annotation.SuppressLint
import android.content.res.ColorStateList
import android.view.Gravity
import android.view.MotionEvent
import android.view.accessibility.AccessibilityManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceStore

/**
 * The app's toast, as the iOS app's: a glass capsule hugging its text under the status bar, where nothing on any
 * page waits for a thumb and neither the keyboard, the tab bar nor a composer can cover it. A failure's glyph carries
 * the colour, the words stay in the text colour; a change that can be taken back offers Undo. It drops in from the
 * top edge and leaves the way it came, by itself after four seconds (ten while TalkBack runs) or swiped up.
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class ToastStage(private val activity: ComponentActivity, private val store: WorkspaceStore) : FrameLayout(activity) {
    private val card = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = activity.dp(44)
        setPadding(activity.dp(14), 0, activity.dp(4), 0)
        glass()
        visibility = INVISIBLE
    }
    private val icon = ImageView(activity)
    private val message = activity.label(Level.SMALL, R.color.token_text_primary, DesignFonts.medium, lines = 2)
    private val undo = activity.label(Level.SMALL, R.color.token_bg_brand_solid, DesignFonts.semibold).apply {
        setText(R.string.shell_undo)
        gravity = Gravity.CENTER
        minHeight = activity.dp(44)
        setPadding(activity.dp(12), 0, activity.dp(12), 0)
        tactile(0.92f)
    }
    private val drop = DesignSpring(card, DynamicAnimation.TRANSLATION_Y, DesignMotion.springSpatial)
    private var shown: WorkspaceStore.Toast? = null
    private var timer: Job? = null
    private var downY = 0f

    init {
        clipChildren = false
        card.addView(icon, LinearLayout.LayoutParams(activity.dp(18), activity.dp(18)).apply { marginEnd = activity.dp(8) })
        card.addView(message, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            marginEnd = activity.dp(10)
        })
        card.addView(undo)
        addView(card, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
            marginStart = activity.dp(16); marginEnd = activity.dp(16)
        })
        card.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downY = event.rawY; timer?.cancel(); drop.cancel() }
                MotionEvent.ACTION_MOVE -> card.translationY = rest() + minOf(0f, event.rawY - downY) + maxOf(0f, event.rawY - downY) * 0.2f
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (event.rawY - downY < -activity.dp(20)) leave() else { drop.animateTo(rest()); schedule() }
                }
            }
            true
        }
        activity.lifecycleScope.launch { store.toast.collect(::present) }
    }

    /** Where the card rests: under the status bar. */
    private fun rest(): Float = (rootWindowInsets?.getInsets(android.view.WindowInsets.Type.statusBars())?.top ?: 0) + activity.dp(8).toFloat()

    private fun present(toast: WorkspaceStore.Toast?) {
        if (toast == null) { if (shown != null) leave(); return }
        val replacing = shown != null
        shown = toast
        message.text = toast.message
        icon.isVisible = toast.error
        icon.setImageResource(R.drawable.ic_warning_triangle)
        icon.imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_error_primary))
        undo.isVisible = toast.undo != null
        undo.setOnClickListener {
            val action = toast.undo ?: return@setOnClickListener
            store.dismissToast(toast.id)
            activity.lifecycleScope.launch { action() }
        }
        card.setPadding(activity.dp(14), 0, activity.dp(if (toast.undo != null) 4 else 16), 0)
        card.visibility = VISIBLE
        if (!replacing) {
            card.translationY = -activity.dp(80).toFloat()
            card.alpha = 0f
        }
        card.animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.dialogEnter)).start()
        post { drop.animateTo(rest()) }
        announceForAccessibility(toast.message)
        if (toast.error) performHapticFeedback(android.view.HapticFeedbackConstants.REJECT)
        schedule()
    }

    private fun schedule() {
        val toast = shown ?: return
        timer?.cancel()
        val talkback = activity.getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled == true
        timer = activity.lifecycleScope.launch {
            delay(if (talkback) 10_000 else 4_000)
            store.dismissToast(toast.id)
        }
    }

    private fun leave() {
        timer?.cancel()
        val toast = shown
        shown = null
        drop.animateTo(-activity.dp(80).toFloat())
        card.animate().alpha(0f).setDuration(DesignMotion.durationMillis(DesignMotion.dialogExit))
            .withEndAction { if (shown == null) card.visibility = INVISIBLE }.start()
        toast?.let { store.dismissToast(it.id) }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = false
}
