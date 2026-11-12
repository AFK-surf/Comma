package surf.comma.android.settings.desktop

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.net.Uri
import android.os.PersistableBundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.SettingsSwitch
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A Settings page of one Workspace: it opens with its own [WorkspaceScope] and closes it when it leaves the stack, so
 * an account or Workspace change retires its work. Without a Workspace it says so. Pages pushed from it share
 * [scope] and redraw with it.
 */
internal abstract class WorkspacePage(
    protected val ctx: SettingsContext,
    @StringRes title: Int,
    final override val key: String,
    /** The scope of the page this one was opened from; null opens a new one. */
    shared: WorkspaceScope? = null,
    titleText: CharSequence? = null,
) : SettingsPage {
    protected val activity = ctx.activity
    protected val layout = SettingsPageLayout(activity, titleText ?: activity.getString(title)) { ctx.back() }
    final override val view: View = layout
    private val owns = shared == null
    protected val scope: WorkspaceScope? = shared ?: ctx.workspaceScope()
    /** The error line, first on the page; tapping a retryable one retries. */
    protected val error = activity.text(Level.SMALL, R.color.token_text_error_primary).apply {
        isVisible = false
        setPadding(activity.dp(4), 0, activity.dp(4), 0)
    }
    protected val loading = activity.text(Level.SMALL, R.color.token_text_quaternary).apply {
        text = activity.getString(R.string.settings_devices_loading)
        gravity = Gravity.CENTER
    }
    private val renderer: () -> Unit = { if (scope?.current != false) render() }
    private var closed = false

    init {
        layout.section(error, top = 0)
        layout.section(loading, top = 0)
    }

    /** Called once the subclass has built its sections. */
    protected fun start(retry: (suspend () -> Unit)? = null) {
        val scope = scope
        if (scope == null) {
            loading.isVisible = false
            showError(PageError.Text(R.string.ds_error_no_workspace), null)
            return
        }
        scope.onChange(renderer)
        retryAction = retry
        render()
    }

    private var retryAction: (suspend () -> Unit)? = null

    protected fun showError(value: PageError?, retry: (suspend () -> Unit)? = retryAction) {
        error.isVisible = value != null
        error.text = value?.let { activity.describe(it) }?.let {
            if (retry != null) activity.getString(R.string.ds_error_retry, it) else it
        }
        error.setOnClickListener(if (value != null && retry != null) View.OnClickListener { launch { retry() } } else null)
    }

    protected fun launch(block: suspend CoroutineScope.() -> Unit) {
        (scope?.work ?: activity.lifecycleScope).launch(block = block)
    }

    /** Redraws from the models; also the error line and whether the page takes input. */
    protected open fun render() {
        val scope = scope ?: return
        showError(scope.error)
        layout.list.alpha = if (scope.current) 1f else 0.5f
    }

    /** Whether the page still works for [session]: the one it opened in. */
    fun belongsTo(session: surf.comma.android.auth.ConversationScope?): Boolean = scope?.session === session

    override fun onRemoved() {
        if (closed) return
        closed = true
        onClose()
        if (owns) scope?.close()
    }

    protected open fun onClose() {}
}

internal fun Context.describe(error: PageError): String = when (error) {
    is PageError.Message -> error.text
    is PageError.Text -> getString(error.id)
}

/** A section whose rows are replaced on each render; rows made once can be shown again. */
internal fun SettingsSection.fill(rows: List<View>): SettingsSection = apply {
    // Rows kept from the last render stay attached, so a text field being typed in keeps its focus.
    val keep = rows.toSet()
    for (index in card.childCount - 1 downTo 0) if (card.getChildAt(index) !in keep) card.removeViewAt(index)
    rows.forEachIndexed { index, row ->
        if (card.getChildAt(index) === row) return@forEachIndexed
        (row.parent as? ViewGroup)?.removeView(row)
        card.addView(row, index, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
    }
    isVisible = rows.isNotEmpty()
}

/** A row that acts: the brand colour, or red when it cannot be undone. */
internal fun Context.actionRow(title: CharSequence, destructive: Boolean = false, onClick: (SettingsRow) -> Unit) =
    SettingsRow(this, null, title, tint = if (destructive) R.color.token_text_error_primary else R.color.token_bg_brand_solid).onClick(onClick)

internal fun Context.infoRow(title: CharSequence, value: CharSequence? = null, @DrawableRes icon: Int? = null) =
    SettingsRow(this, icon, title).value(value)

/** A row that opens a page. */
internal fun Context.linkRow(title: CharSequence, value: CharSequence? = null, @DrawableRes icon: Int? = null, onClick: (SettingsRow) -> Unit) =
    SettingsRow(this, icon, title).value(value, chevron = true).onClick(onClick)

/** A row with a switch; [onToggle] gets the asked-for state, and the topic's next value moves the switch. */
internal class SwitchRow(context: Context, title: CharSequence, detail: CharSequence? = null, onToggle: (Boolean) -> Unit) {
    val switch = SettingsSwitch(context)
    val row = SettingsRow(context, null, title).detail(detail).trailing(switch).onClick { onToggle(!switch.checked) }
    private var first = true

    fun set(on: Boolean, enabled: Boolean = true) {
        switch.set(on, animate = !first)
        first = false
        row.isEnabled = enabled
    }
}

/** Title, a quieter detail line, then an optional status word and control, as the iOS app's voice and request rows. */
internal fun Context.describedRow(title: CharSequence, detail: CharSequence?, status: CharSequence? = null,
                                  statusColor: Int = R.color.token_text_tertiary, control: View? = null): LinearLayout =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = dp(50)
        setPadding(dp(14), dp(10), dp(10), dp(10))
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(text(Level.REGULAR, R.color.token_text_primary).apply { text = title })
            if (!detail.isNullOrEmpty()) addView(text(Level.SMALL, R.color.token_text_tertiary).apply { text = detail },
                LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(2) })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        if (status != null) addView(text(Level.SMALL, statusColor).apply { text = status },
            LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
        if (control != null) addView(control, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
    }

/** A small text button for the end of a row. */
internal fun Context.inlineButton(label: CharSequence, destructive: Boolean = false, onClick: (View) -> Unit): TextView =
    text(Level.SMALL, if (destructive) R.color.token_text_error_primary else R.color.token_bg_brand_solid, DesignFonts.medium).apply {
        text = label
        gravity = Gravity.CENTER
        minHeight = dp(40)
        setPadding(dp(10), dp(8), dp(6), dp(8))
        setOnClickListener(onClick)
    }

/** The more button of a row; it opens the row's menu. */
internal fun Context.moreButton(description: CharSequence, onClick: (View) -> Unit): ImageView = ImageView(this).apply {
    setImageResource(R.drawable.ic_inbox_actions)
    imageTintList = ColorStateList.valueOf(color(R.color.token_text_secondary))
    scaleType = ImageView.ScaleType.CENTER_INSIDE
    contentDescription = description
    layoutParams = LinearLayout.LayoutParams(dp(44), dp(44))
    PressFeedback(this, R.color.token_bg_quaternary, scale = true)
    setOnClickListener(onClick)
}

/** A text field inside a group, as a row. */
internal fun Context.fieldRow(hint: CharSequence, inputType: Int = InputType.TYPE_CLASS_TEXT, lines: Int = 1,
                              mono: Boolean = false, onChange: (String) -> Unit = {}): EditText = EditText(this).apply {
    DesignTypography.applyTo(this, Level.REGULAR)
    if (mono) typeface = android.graphics.Typeface.MONOSPACE
    setTextColor(color(R.color.token_text_primary))
    setHintTextColor(color(R.color.token_text_placeholder))
    this.hint = hint
    this.inputType = if (lines > 1) inputType or InputType.TYPE_TEXT_FLAG_MULTI_LINE else inputType
    if (lines > 1) {
        minLines = lines
        gravity = Gravity.TOP or Gravity.START
    } else isSingleLine = true
    background = null
    minHeight = dp(50)
    setPadding(dp(14), dp(12), dp(14), dp(12))
    doAfterTextChanged { onChange(it?.toString().orEmpty()) }
}

/** Selectable text inside a group. */
internal fun Context.textBlock(value: CharSequence, level: Level = Level.REGULAR, mono: Boolean = false,
                               colorRes: Int = R.color.token_text_primary): TextView = text(level, colorRes).apply {
    text = value
    if (mono) typeface = android.graphics.Typeface.MONOSPACE
    setTextIsSelectable(true)
    setPadding(dp(14), dp(12), dp(14), dp(12))
}

internal fun Context.noteRow(value: CharSequence, colorRes: Int = R.color.token_text_tertiary): TextView =
    text(Level.SMALL, colorRes).apply {
        text = value
        setPadding(dp(14), dp(12), dp(14), dp(12))
    }

/** Copies a secret or link; it is marked sensitive so the system does not show it in its preview. */
internal fun Context.copySensitive(value: String) {
    val clip = ClipData.newPlainText("", value).apply {
        description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    }
    getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
}

/** Opens an https link in the browser. */
internal fun Context.openLink(url: String) {
    if (!url.startsWith("https://")) return
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)) }
}

internal fun Context.shareText(value: String) {
    runCatching {
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, value), null))
    }
}

/** A setting with a few options: the current one's label as the value, a menu of the others on tap. */
internal fun SettingsRow.choices(options: List<Pair<String, CharSequence>>, selected: String, onPick: (String) -> Unit) = apply {
    value(options.firstOrNull { it.first == selected }?.second ?: selected, chevron = true)
    onClick { row ->
        surf.comma.android.settings.ChoiceMenu.show(row, options.map { it.second }, options.indexOfFirst { it.first == selected }) {
            onPick(options[it].first)
        }
    }
}
