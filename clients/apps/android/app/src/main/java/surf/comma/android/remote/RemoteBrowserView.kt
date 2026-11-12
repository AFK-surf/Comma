package surf.comma.android.remote

import android.annotation.SuppressLint
import android.graphics.Matrix
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsRow
import surf.comma.android.tasks.tools.ToolPage
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.GlassIconButton
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.dpf
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * The remote browser page for one [RemoteBrowser] viewer: its tabs and who has control, the live viewport (a tap
 * clicks there while the member has control), a keyboard section, and reconnecting or clearing its storage. The same
 * view shows in a sheet and, on a wide screen, beside the Task's conversation; [close] given, it draws its own header.
 * The viewport keeps its view across updates, so a new frame only swaps the picture.
 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
internal class RemoteBrowserView(
    private val activity: ComponentActivity,
    val model: RemoteBrowser,
    private val close: (() -> Unit)? = null,
) : LinearLayout(activity) {
    private val page = ToolPage(activity)
    private val viewport = ImageView(activity).apply {
        adjustViewBounds = true
        scaleType = ImageView.ScaleType.FIT_CENTER
        contentDescription = activity.getString(R.string.remote_browser_viewport)
        background = rounded(activity.getColor(R.color.token_bg_tertiary), activity.dpf(16f))
        clipToOutline = true
    }
    private val waiting = FrameLayout(activity).apply {
        addView(ProgressBar(activity), FrameLayout.LayoutParams(activity.dp(28), activity.dp(28), Gravity.CENTER))
        minimumHeight = activity.dp(120)
    }
    private val text = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        setHint(R.string.remote_browser_text_hint)
        isSingleLine = true
        background = null
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
    }
    private var shownKey: Any? = null

    init {
        orientation = VERTICAL
        setBackgroundColor(activity.getColor(R.color.token_card_primary))
        if (close != null) addView(header(close), LayoutParams(LayoutParams.MATCH_PARENT, activity.dp(64)))
        addView(page.view, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        val taps = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent) = true
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                val point = bitmapFraction(e.x, e.y) ?: return false
                activity.lifecycleScope.launch { model.tap(point.first, point.second) }
                return true
            }
        })
        viewport.setOnTouchListener { _, event -> model.controlling && taps.onTouchEvent(event) }
        model.onChange = ::render
        render()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        model.onChange = ::render
        model.start(this, activity.lifecycleScope)
        render()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        model.stop(this)
    }

    private fun header(close: () -> Unit) = FrameLayout(activity).apply {
        addView(GlassIconButton(activity, R.drawable.ic_action_close, activity.getString(R.string.shell_close)).apply {
            setOnClickListener { close() }
        }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or Gravity.START).apply { marginStart = activity.dp(16) })
        addView(activity.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply {
            setText(R.string.remote_browser_title)
            isAccessibilityHeading = true
        }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
    }

    /** Where a touch lands on the frame, as fractions of it; null outside the picture. */
    private fun bitmapFraction(x: Float, y: Float): Pair<Double, Double>? {
        val bitmap = model.image ?: return null
        val inverse = Matrix()
        if (!viewport.imageMatrix.invert(inverse)) return null
        val point = floatArrayOf(x - viewport.paddingLeft, y - viewport.paddingTop)
        inverse.mapPoints(point)
        if (point[0] < 0 || point[1] < 0 || point[0] > bitmap.width || point[1] > bitmap.height) return null
        return point[0].toDouble() / bitmap.width to point[1].toDouble() / bitmap.height
    }

    private fun render() {
        viewport.setImageBitmap(model.image)
        val key = listOf(model.loaded, model.ref?.toString(), model.tabs, model.tab, model.controlling, model.connectionFailed,
            model.error, model.busy, model.image != null, model.participant)
        if (key == shownKey) return
        shownKey = key
        page.clear()
        isEnabled = model.current
        when {
            !model.loaded -> page.progress()
            model.ref == null -> page.note(page.section(), activity.getString(R.string.remote_browser_none))
            else -> controls()
        }
        model.error?.let { page.error(it) { activity.lifecycleScope.launch { model.reconnect() } } }
    }

    private fun controls() {
        val enabled = !model.busy && model.current
        val section = page.section()
        val tabs = model.tabs
        val current = tabs.firstOrNull { it.first == model.tab }?.second
        section.add(SettingsRow(activity, null, activity.getString(R.string.remote_browser_tab)).value(current, chevron = tabs.size > 1).apply {
            isEnabled = enabled
            if (tabs.size > 1) onClick { anchor ->
                val menu = ActionMenu(activity)
                tabs.forEach { (id, title) -> menu.item(title, checked = id == model.tab) { activity.lifecycleScope.launch { model.select(id) } } }
                menu.show(anchor)
            }
        })
        section.add(SettingsRow(activity, null, activity.getString(R.string.remote_browser_control))
            .value(activity.getString(if (model.controlling) R.string.remote_browser_you else R.string.remote_browser_agent)))
        page.action(section, activity.getString(if (model.controlling) R.string.remote_browser_return_control else R.string.remote_browser_take_control),
            enabled = enabled) {
            activity.lifecycleScope.launch { model.command(if (model.controlling) "return_control" else "take_control") }
        }
        (viewport.parent as? ViewGroup)?.removeView(viewport)
        (waiting.parent as? ViewGroup)?.removeView(waiting)
        page.add(if (model.image != null) viewport else waiting)
        if (model.controlling) keyboard(enabled)
        val more = page.section()
        page.action(more, activity.getString(R.string.remote_browser_reconnect), enabled = enabled) {
            activity.lifecycleScope.launch { model.reconnect() }
        }
        page.action(more, activity.getString(R.string.remote_browser_clear), destructive = true, enabled = enabled) {
            ConfirmDialog(activity, activity.getString(R.string.remote_browser_clear_title), activity.getString(R.string.remote_browser_clear_message),
                activity.getString(R.string.remote_browser_clear_confirm), destructive = true) {
                activity.lifecycleScope.launch { model.command("clear_storage") }
            }.show()
        }
        if (model.connectionFailed) page.error(activity.getString(R.string.remote_browser_failed)) {
            activity.lifecycleScope.launch { model.reconnect() }
        }
    }

    private fun keyboard(enabled: Boolean) {
        val section = page.section(activity.getString(R.string.remote_browser_keyboard))
        (text.parent as? ViewGroup)?.removeView(text)
        section.add(text)
        page.action(section, activity.getString(R.string.remote_browser_type), enabled = enabled) {
            val typed = text.text?.toString().orEmpty()
            if (typed.isEmpty()) return@action
            // The words stay in the field until they were sent.
            activity.lifecycleScope.launch { if (model.type(typed) && text.text?.toString() == typed) text.setText("") }
        }
        listOf(
            listOf(RemoteBrowser.NavigationKey.TAB to R.string.remote_browser_key_tab, RemoteBrowser.NavigationKey.ENTER to R.string.remote_browser_key_enter,
                RemoteBrowser.NavigationKey.ESCAPE to R.string.remote_browser_key_escape),
            listOf(RemoteBrowser.NavigationKey.PAGE_UP to R.string.remote_browser_key_page_up,
                RemoteBrowser.NavigationKey.PAGE_DOWN to R.string.remote_browser_key_page_down),
        ).forEach { keys ->
            section.add(LinearLayout(activity).apply {
                orientation = HORIZONTAL
                keys.forEach { (key, name) ->
                    addView(activity.label(Level.REGULAR, R.color.token_bg_brand_solid, DesignFonts.medium).apply {
                        setText(name)
                        gravity = Gravity.CENTER
                        minHeight = activity.dp(48)
                        isEnabled = enabled
                        setOnClickListener { activity.lifecycleScope.launch { model.key(key) } }
                    }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
                }
            })
        }
    }
}

/** The remote browser in a sheet, as on a phone held upright. Closing it lets the viewer go. */
internal class RemoteBrowserSheet(activity: ComponentActivity, model: RemoteBrowser) :
    CommaSheet(activity, activity.getString(R.string.remote_browser_title), Detent.LARGE) {
    val view = RemoteBrowserView(activity, model)

    init {
        setContent(view)
    }
}
