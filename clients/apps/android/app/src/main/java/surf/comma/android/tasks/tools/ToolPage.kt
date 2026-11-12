package surf.comma.android.tasks.tools

import android.content.Context
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.view.isEmpty
import surf.comma.android.R
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * The scrolling column a Task tool page (task files, code review, the remote browser) lays its grouped sections in,
 * as the iOS app's settings-style pages: 16dp side margins, 24dp between groups. A page rebuilds its rows with
 * [clear] and the helpers below whenever what it shows changes; nothing it shows is long enough to need recycling.
 */
internal class ToolPage(private val context: Context) {
    val column = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(context.dp(16), context.dp(8), context.dp(16), context.dp(32))
    }
    val view = ScrollContainer(context).apply {
        addView(column, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    fun clear() = column.removeAllViews()

    fun add(view: View, top: Int = SECTION_GAP_DP) {
        column.addView(view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = if (column.isEmpty()) 0 else context.dp(top)
        })
    }

    fun section(title: CharSequence? = null): SettingsSection = SettingsSection(context, title).also { add(it) }

    fun progress() = add(FrameLayout(context).apply {
        addView(ProgressBar(context), FrameLayout.LayoutParams(context.dp(28), context.dp(28), Gravity.CENTER))
        minimumHeight = context.dp(56)
    })

    /** A quiet line in a group: a fact the page cannot act on. */
    fun note(section: SettingsSection, text: CharSequence): TextView = context.label(Level.SMALL, R.color.token_text_tertiary, lines = 0).apply {
        this.text = text
        setPadding(context.dp(14), context.dp(12), context.dp(14), context.dp(12))
        section.add(this)
    }

    /** A row that does something, in the brand colour. */
    fun action(section: SettingsSection, title: CharSequence, destructive: Boolean = false, enabled: Boolean = true,
               act: () -> Unit): SettingsRow = SettingsRow(context, null, title,
        if (destructive) R.color.token_text_error_primary else R.color.token_bg_brand_solid).apply {
        isEnabled = enabled
        if (enabled) onClick { act() }
        section.add(this)
    }

    /** What failed, with a way to try again. */
    fun error(message: CharSequence, retry: (() -> Unit)?) = add(LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(context.label(Level.SMALL, R.color.token_text_error_primary, lines = 0).apply { text = message },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (retry != null) addView(context.label(Level.SMALL, R.color.token_bg_brand_solid, DesignFonts.medium).apply {
            setText(R.string.task_tools_retry)
            minHeight = context.dp(44)
            gravity = Gravity.CENTER_VERTICAL
            setPadding(context.dp(12), 0, 0, 0)
            setOnClickListener { retry() }
        })
    }, top = 12)

    private companion object { const val SECTION_GAP_DP = 24 }
}
