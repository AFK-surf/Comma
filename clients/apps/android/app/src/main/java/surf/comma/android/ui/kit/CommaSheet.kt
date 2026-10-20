package surf.comma.android.ui.kit

import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.tasks.ui.TaskSheetLayout
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A sheet presented the iOS app's way: on the opaque sheet surface (`card_primary`) with rounded top corners,
 * the grabber whenever it can be resized, the cross at the leading edge and the title centred a step quieter
 * than a page's. It rises over a dim from the bottom edge to [Detent.MEDIUM] or [Detent.LARGE]; a medium sheet
 * drags up to full height, and any sheet drags down, or closes on the dim, the cross or back.
 *
 * The body is [content]. A scrolling list in it shares its drags with the sheet through nested scrolling, as
 * [TaskSheetLayout] does: the sheet rises before the list scrolls, and follows the finger down once the list is
 * back at its top. Sheets stack: one opened from another lies over it.
 */
open class CommaSheet(
    protected val activity: ComponentActivity,
    title: CharSequence?,
    detent: Detent = Detent.MEDIUM,
    /** The close cross; a sheet whose content closes it another way may leave it out. */
    showClose: Boolean = true,
) {
    enum class Detent(val fraction: Float) { MEDIUM(0.56f), LARGE(1f) }

    private val host = activity.findViewById<ViewGroup>(android.R.id.content)
    private val sheetLayout = TaskSheetLayout(activity, TaskTheme(activity), detent.fraction)
    private val body = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        val radius = activity.dpf(RADIUS_DP)
        background = rounded(activity.getColor(R.color.token_card_primary), 0f).apply {
            cornerRadii = floatArrayOf(radius, radius, radius, radius, 0f, 0f, 0f, 0f)
        }
        clipToOutline = true
        outlineProvider = object : android.view.ViewOutlineProvider() {
            override fun getOutline(view: View, outline: android.graphics.Outline) =
                outline.setRoundRect(0, 0, view.width, view.height + radius.toInt(), radius)
        }
    }
    private val grabber = View(activity).apply {
        background = rounded(activity.getColor(R.color.token_border_primary), activity.dpf(2.5f))
        isVisible = detent == Detent.MEDIUM
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** The bar over the content: the cross, the title and a trailing slot. */
    val header = FrameLayout(activity)
    val titleView: TextView = activity.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply {
        text = title
        gravity = Gravity.CENTER
        isAccessibilityHeading = true
        isVisible = !title.isNullOrEmpty()
    }
    val close = GlassIconButton(activity, R.drawable.ic_action_close, activity.getString(R.string.shell_close))
    val trailing = FrameLayout(activity)
    private val contentFrame = FrameLayout(activity)
    private val back = object : OnBackPressedCallback(true) {
        override fun handleOnBackPressed() = dismiss()
    }

    /** Runs once the sheet has left the screen, however it was closed. */
    var onDismissed: (() -> Unit)? = null
    private var shown = false

    init {
        val headerHeight = activity.dp(HEADER_DP)
        header.addView(titleView, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER).apply { marginStart = activity.dp(68); marginEnd = activity.dp(68) })
        if (showClose) {
            close.setOnClickListener { dismiss() }
            header.addView(close, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_VERTICAL or Gravity.START).apply { marginStart = activity.dp(16) })
        }
        header.addView(trailing, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or Gravity.END).apply { marginEnd = activity.dp(16) })
        val top = FrameLayout(activity).apply {
            addView(grabber, FrameLayout.LayoutParams(activity.dp(36), activity.dp(5), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
                topMargin = activity.dp(6)
            })
            addView(header, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, headerHeight, Gravity.BOTTOM))
        }
        body.addView(top, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, headerHeight + activity.dp(12)))
        body.addView(contentFrame, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        sheetLayout.setSheet(body, headerHeight + activity.dp(12))
        sheetLayout.onClosed = ::removed
        // The content keeps clear of the keyboard and the navigation bar.
        ViewCompat.setOnApplyWindowInsetsListener(contentFrame) { view, insets ->
            val bottom = maxOf(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom,
                insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            view.setPadding(0, 0, 0, bottom)
            insets
        }
    }

    /** Sets the sheet's body, below the header. */
    fun setContent(view: View) {
        contentFrame.removeAllViews()
        contentFrame.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    fun show() {
        if (shown) return
        shown = true
        host.addView(sheetLayout, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        activity.onBackPressedDispatcher.addCallback(activity, back)
        ViewCompat.requestApplyInsets(sheetLayout)
        sheetLayout.open()
        onShown()
    }

    fun dismiss() {
        back.isEnabled = false
        sheetLayout.close()
    }

    protected open fun onShown() {}

    protected open fun onRemoved() {}

    private fun removed() {
        back.remove()
        host.removeView(sheetLayout)
        shown = false
        onRemoved()
        onDismissed?.invoke()
    }

    private companion object {
        const val RADIUS_DP = 28f
        const val HEADER_DP = 52
    }
}
