package surf.comma.android.tasks.list

import android.content.Context
import android.content.res.ColorStateList
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import surf.comma.android.R
import surf.comma.android.labels.LabelDot
import surf.comma.android.routines.ProviderMarks
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.tasks.ui.TaskTheme
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.pressedFill
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.selectionTick
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignLabelColors
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.scroll.widget.ScrollContainer

/** One choice of a filter field: its id in [TaskListFilter], its name and its glyph. */
data class FilterOption(val id: String, val name: String, val glyph: Glyph) {
    sealed interface Glyph {
        data class Status(val bucket: TaskStatusBucket) : Glyph
        data class Label(val color: String) : Glyph
        data class Origin(val origin: String) : Glyph
        data object Device : Glyph
        data object None : Glyph
    }
}

/** What the filter pages choose from: the loaded Tasks and the Group's labels. */
class FilterChoices(private val context: Context, val tasks: List<TaskSummary>, private val labels: List<TaskLabel>) {
    private val theme = TaskTheme(context)

    fun options(field: TaskListFilter.Field, filter: TaskListFilter): List<FilterOption> =
        filter.options(field, tasks, labels.map { it.id }).map { option(field, it) }

    fun chosen(field: TaskListFilter.Field, filter: TaskListFilter): List<FilterOption> {
        val values = filter.values(field).orEmpty()
        return options(field, filter).filter { it.id in values }
    }

    /** The ids [filter] lets through for [field]: every option while the field doesn't narrow. */
    fun selected(field: TaskListFilter.Field, filter: TaskListFilter): Set<String> =
        filter.values(field) ?: options(field, filter).map { it.id }.toSet()

    /** [filter] with one option checked or unchecked; checking every option stops the field narrowing. */
    fun toggling(id: String, field: TaskListFilter.Field, filter: TaskListFilter): TaskListFilter {
        val all = options(field, filter).map { it.id }.toSet()
        val next = (filter.values(field) ?: all).toMutableSet()
        if (!next.remove(id)) next += id
        return filter.setting(field, next, all)
    }

    fun counts(field: TaskListFilter.Field): Map<String, Int> =
        TaskListFilter.counts(field, tasks, labels.map { it.id }.toSet())

    private fun option(field: TaskListFilter.Field, id: String): FilterOption = when (field) {
        TaskListFilter.Field.STATUS -> {
            val bucket = TaskStatusBucket.entries.firstOrNull { it.wireName == id } ?: TaskStatusBucket.IN_PROGRESS
            FilterOption(id, theme.statusLabel(bucket), FilterOption.Glyph.Status(bucket))
        }
        TaskListFilter.Field.LABEL -> labels.firstOrNull { it.id == id }?.let { FilterOption(id, it.name, FilterOption.Glyph.Label(it.color)) }
            ?: FilterOption(id, context.getString(R.string.filter_no_label), FilterOption.Glyph.None)
        TaskListFilter.Field.PLATFORM -> originName(context, id)?.let { FilterOption(id, it, FilterOption.Glyph.Origin(id)) }
            ?: FilterOption(id, context.getString(R.string.filter_unspecified), FilterOption.Glyph.None)
        TaskListFilter.Field.CLIENT_PLATFORM -> FilterOption(id, deviceName(context, id), FilterOption.Glyph.Device)
    }

    companion object {
        fun title(context: Context, field: TaskListFilter.Field): String = context.getString(when (field) {
            TaskListFilter.Field.STATUS -> R.string.filter_status
            TaskListFilter.Field.LABEL -> R.string.filter_label
            TaskListFilter.Field.PLATFORM -> R.string.filter_platform
            TaskListFilter.Field.CLIENT_PLATFORM -> R.string.filter_client_platform
        })

        fun icon(field: TaskListFilter.Field): Int = when (field) {
            TaskListFilter.Field.STATUS -> R.drawable.ic_task_in_progress
            TaskListFilter.Field.LABEL -> R.drawable.ic_filter_label
            TaskListFilter.Field.PLATFORM -> R.drawable.ic_filter_platform
            TaskListFilter.Field.CLIENT_PLATFORM -> R.drawable.ic_filter_device
        }
    }
}

/** Where a Task was asked for, by name. */
fun originName(context: Context, origin: String?): String? = when (origin) {
    "slack" -> context.getString(R.string.origin_slack)
    "telegram" -> context.getString(R.string.origin_telegram)
    "feishu" -> context.getString(R.string.origin_feishu)
    "wechat" -> context.getString(R.string.origin_wechat)
    "signal" -> context.getString(R.string.origin_signal)
    "comma" -> context.getString(R.string.origin_comma)
    else -> null
}

/** A device Comma runs on, by name. */
fun deviceName(context: Context, platform: String?): String = context.getString(when (platform) {
    "macos" -> R.string.device_macos
    "windows" -> R.string.device_windows
    "linux" -> R.string.device_linux
    "ios" -> R.string.device_ios
    "android" -> R.string.device_android
    "web" -> R.string.device_web
    "watchos" -> R.string.device_watchos
    else -> R.string.device_unknown
})

/** An option's glyph in an 18dp square: the status glyph, the label's dot, the app's mark or the laptop. */
internal fun filterGlyph(context: Context, glyph: FilterOption.Glyph, sizeDp: Int = 18): View {
    val theme = TaskTheme(context)
    return when (glyph) {
        is FilterOption.Glyph.Status -> TaskStatusIconView(context).apply { setStatus(glyph.bucket, statusTint(context, glyph.bucket), spin = false) }
        is FilterOption.Glyph.Label -> ImageView(context).apply {
            setImageDrawable(LabelDot(DesignLabelColors.resolve(context, glyph.color), context.dp(sizeDp), context.dp(sizeDp) * 55 / 100))
        }
        is FilterOption.Glyph.Origin -> ImageView(context).apply { setImageDrawable(ProviderMarks.drawable(context, glyph.origin)) }
        FilterOption.Glyph.Device -> ImageView(context).apply {
            setImageResource(R.drawable.ic_filter_device)
            imageTintList = ColorStateList.valueOf(theme.textSecondary)
        }
        FilterOption.Glyph.None -> View(context)
    }.apply { layoutParams = LinearLayout.LayoutParams(context.dp(sizeDp), context.dp(sizeDp)) }
}

/** The status colours every list shares. */
fun statusTint(context: Context, bucket: TaskStatusBucket): Int = when (bucket) {
    TaskStatusBucket.NEEDS_REVIEW -> context.getColor(R.color.token_fg_attention)
    TaskStatusBucket.DONE -> context.getColor(R.color.token_fg_success)
    TaskStatusBucket.CANCELLED -> context.getColor(R.color.token_cancelled)
    else -> context.getColor(R.color.token_sidebar_icon)
}

/**
 * Filters for a Task list: a search capsule, the applied filters as rounded sentence rows, then every field in one
 * group. A field opens its options as a second sheet stacked on this one. Changes apply live through [onChange]:
 * the list behind and the status switcher follow them. [leading] adds rows above the applied filters, such as the
 * Inbox's Unread only.
 */
class FilterSheet(
    activity: ComponentActivity,
    private var filter: TaskListFilter,
    private val fields: List<TaskListFilter.Field>,
    private val choices: FilterChoices,
    private val onChange: (TaskListFilter) -> Unit,
    private val leading: (FilterSheet) -> List<View> = { emptyList() },
) : CommaSheet(activity, null, Detent.LARGE) {
    private val search = searchField(activity, activity.getString(R.string.filter_search_all))
    private val column = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(activity.dp(16), 0, activity.dp(16), activity.dp(24))
    }
    private val noResults = EmptyStateView(activity).apply {
        show(R.drawable.ic_tab_search, activity.getString(R.string.filter_none_found))
        isVisible = false
    }
    private var query = ""

    init {
        header.isVisible = true
        val body = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, activity.dp(44)).apply {
                setMargins(activity.dp(16), 0, activity.dp(16), 0)
            })
            addView(FrameLayout(activity).apply {
                addView(ScrollContainer(activity).apply { addView(column) })
                addView(noResults)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContent(body)
        (search.getChildAt(1) as EditText).doAfterTextChanged { query = it?.toString()?.trim().orEmpty(); render() }
        render()
    }

    fun update(next: TaskListFilter) {
        filter = next
        onChange(next)
        render()
    }

    fun refresh() = render()

    private fun render() {
        column.removeAllViews()
        val available = fields.filter { choices.options(it, filter).isNotEmpty() }
        if (query.isEmpty()) browsing(available) else results(available)
    }

    private fun browsing(available: List<TaskListFilter.Field>) {
        noResults.isVisible = false
        val extra = leading(this)
        if (extra.isNotEmpty()) {
            column.addView(group(extra), groupParams(activity, 16))
        }
        val applied = filter.narrowedFields.filter(fields::contains)
        if (applied.isNotEmpty()) {
            column.addView(caption(activity.getString(R.string.filter_applied), if (applied.size > 1) activity.getString(R.string.filter_clear_all) else null) {
                update(TaskListFilter())
            })
            applied.forEachIndexed { index, field ->
                column.addView(AppliedRow(field), groupParams(activity, if (index == 0) 0 else 8))
            }
        }
        fieldGroup(available)
    }

    private fun results(available: List<TaskListFilter.Field>) {
        val named = available.filter { FilterChoices.title(activity, it).contains(query, ignoreCase = true) }
        fieldGroup(named)
        var any = named.isNotEmpty()
        available.forEach { field ->
            val options = choices.options(field, filter).filter { it.name.contains(query, ignoreCase = true) }
            if (options.isEmpty()) return@forEach
            any = true
            val selected = choices.selected(field, filter)
            column.addView(caption(FilterChoices.title(activity, field)))
            column.addView(group(options.map { option ->
                optionRow(activity, option, option.id in selected, 0) { view ->
                    view.selectionTick()
                    update(choices.toggling(option.id, field, filter))
                }
            }), groupParams(activity, 0))
        }
        noResults.isVisible = !any
    }

    private fun fieldGroup(shown: List<TaskListFilter.Field>) {
        if (shown.isEmpty()) return
        column.addView(caption(activity.getString(R.string.filter_all)))
        column.addView(group(shown.map { field ->
            LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = activity.dp(50)
                setPadding(activity.dp(14), 0, activity.dp(14), 0)
                addView(ImageView(activity).apply {
                    setImageResource(FilterChoices.icon(field))
                    imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_secondary))
                }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
                addView(activity.label(Level.REGULAR, R.color.token_text_primary).apply { text = FilterChoices.title(activity, field) },
                    LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(8) })
                pressedFill()
                setOnClickListener { openField(field) }
            }
        }), groupParams(activity, 0))
    }

    private fun openField(field: TaskListFilter.Field) {
        FilterOptionsSheet(activity, field, { filter }, choices) { update(it) }.show()
    }

    private fun caption(text: String, action: String? = null, onAction: () -> Unit = {}) = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.BOTTOM
        setPadding(activity.dp(4), activity.dp(22), activity.dp(4), activity.dp(10))
        addView(activity.label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
            this.text = text
            isAccessibilityHeading = true
        }, LinearLayout.LayoutParams(0, -2, 1f))
        if (action != null) addView(activity.label(Level.SMALL, R.color.token_text_secondary, DesignFonts.semibold).apply {
            this.text = action
            setOnClickListener { onAction() }
        })
    }

    /** One narrowing field, read as a sentence on its own rounded row; the x stops the field narrowing. */
    private inner class AppliedRow(field: TaskListFilter.Field) : FrameLayout(activity) {
        init {
            background = rounded(activity.getColor(R.color.token_bg_tertiary), activity.dp(24).toFloat())
            clipToOutline = true
            val chosen = choices.chosen(field, filter)
            val flow = FlowLayout(activity, activity.dp(8)).apply {
                setPadding(activity.dp(14), activity.dp(8), activity.dp(44), activity.dp(8))
                addView(activity.label(Level.REGULAR, R.color.token_text_primary).apply { text = FilterChoices.title(activity, field) })
                addView(chip(activity.getString(if (chosen.size > 1) R.string.filter_is_any_of else R.string.filter_is), muted = true))
                if (chosen.isEmpty()) addView(chip(activity.getString(R.string.filter_none)))
                chosen.take(2).forEach { addView(chip(it.name, filterGlyph(activity, it.glyph, 16))) }
                if (chosen.size > 2) addView(chip(activity.getString(R.string.filter_more, chosen.size - 2)))
            }
            addView(flow, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
            minimumHeight = activity.dp(50)
            pressedFill()
            setOnClickListener { openField(field) }
            addView(ImageView(activity).apply {
                setImageResource(R.drawable.ic_action_close)
                imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_secondary))
                setPadding(activity.dp(13), activity.dp(13), activity.dp(13), activity.dp(13))
                contentDescription = activity.getString(R.string.filter_remove, FilterChoices.title(activity, field))
                setOnClickListener { update(filter.clearing(field)) }
            }, LayoutParams(activity.dp(44), activity.dp(44), Gravity.END or Gravity.CENTER_VERTICAL))
        }

        private fun chip(text: String, glyph: View? = null, muted: Boolean = false) = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(activity.getColor(R.color.token_surface_ink), activity.dp(12).toFloat())
            setPadding(activity.dp(9), activity.dp(3), activity.dp(9), activity.dp(3))
            if (glyph != null) addView(glyph, LinearLayout.LayoutParams(activity.dp(16), activity.dp(16)).apply { marginEnd = activity.dp(5) })
            addView(activity.label(Level.SMALL, if (muted) R.color.token_text_quaternary else R.color.token_text_primary, DesignFonts.medium)
                .apply { this.text = text })
        }
    }
}

/**
 * One field's options, as a sheet stacked over the filters: the options chosen when it opens lead in their own
 * group and the rest follow in a second one. Checkboxes apply as they are tapped, and the order holds while the
 * sheet is open, so a row never moves under the finger.
 */
class FilterOptionsSheet(
    activity: ComponentActivity,
    private val field: TaskListFilter.Field,
    private val current: () -> TaskListFilter,
    private val choices: FilterChoices,
    private val onChange: (TaskListFilter) -> Unit,
) : CommaSheet(activity, null, Detent.LARGE) {
    private val search = searchField(activity, activity.getString(R.string.filter_search_field))
    private val column = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(activity.dp(16), 0, activity.dp(16), activity.dp(24))
    }
    private val first = choices.selected(field, current())
    private val noResults = EmptyStateView(activity).apply {
        show(R.drawable.ic_tab_search, activity.getString(R.string.filter_none_found))
        isVisible = false
    }
    private var query = ""

    init {
        setContent(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, activity.dp(44)).apply {
                setMargins(activity.dp(16), 0, activity.dp(16), 0)
            })
            addView(FrameLayout(activity).apply {
                addView(ScrollContainer(activity).apply { addView(column) })
                addView(noResults)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        (search.getChildAt(1) as EditText).doAfterTextChanged { query = it?.toString()?.trim().orEmpty(); render() }
        render()
    }

    private fun render() {
        column.removeAllViews()
        val filter = current()
        val selected = choices.selected(field, filter)
        val counts = choices.counts(field)
        val visible = choices.options(field, filter).filter { query.isEmpty() || it.name.contains(query, ignoreCase = true) }
        noResults.isVisible = visible.isEmpty()
        if (visible.isEmpty()) return
        column.addView(activity.label(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
            text = FilterChoices.title(activity, field)
            setPadding(activity.dp(4), activity.dp(22), activity.dp(4), activity.dp(10))
        })
        listOf(true, false).forEach { leads ->
            val rows = visible.filter { (it.id in first) == leads }
            if (rows.isEmpty()) return@forEach
            column.addView(group(rows.map { option ->
                optionRow(activity, option, option.id in selected, counts[option.id] ?: 0) { view ->
                    view.selectionTick()
                    onChange(choices.toggling(option.id, field, current()))
                    render()
                }
            }), groupParams(activity, if (column.childCount > 1) 8 else 0))
        }
    }
}

/** One option: its checkbox, glyph, name and how many loaded Tasks it holds. */
internal fun optionRow(context: Context, option: FilterOption, selected: Boolean, count: Int, toggle: (View) -> Unit): View =
    LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = context.dp(50)
        setPadding(context.dp(14), context.dp(6), context.dp(14), context.dp(6))
        addView(Checkbox(context, selected), LinearLayout.LayoutParams(context.dp(20), context.dp(20)))
        addView(filterGlyph(context, option.glyph), LinearLayout.LayoutParams(context.dp(18), context.dp(18)).apply { marginStart = context.dp(12) })
        addView(context.label(Level.REGULAR, R.color.token_text_primary, lines = 2).apply { text = option.name },
            LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = context.dp(10) })
        if (count > 0) addView(context.label(Level.REGULAR, R.color.token_text_quaternary).apply { text = count.toString() })
        isSelected = selected
        contentDescription = option.name
        pressedFill()
        setOnClickListener(toggle)
    }

/** A rounded square: a hairline outline when off; a deeper fill holding the checkmark when on. */
internal class Checkbox(context: Context, on: Boolean) : FrameLayout(context) {
    init {
        val ink = context.getColor(R.color.token_text_primary)
        background = rounded(androidx.core.graphics.ColorUtils.setAlphaComponent(ink, if (on) 20 else 0), context.dp(5).toFloat(),
            androidx.core.graphics.ColorUtils.setAlphaComponent(ink, if (on) 36 else 31), maxOf(1, context.dp(1)))
        if (on) addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_action_check)
            imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_secondary))
        }, LayoutParams(context.dp(20), context.dp(20), Gravity.CENTER))
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
}

/** The search capsule the filter sheets and Task search open with: a glyph and the field on an ink capsule. */
internal fun searchField(context: Context, hint: String): LinearLayout = LinearLayout(context).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    background = rounded(context.getColor(R.color.token_surface_ink), context.dp(22).toFloat())
    setPadding(context.dp(12), 0, context.dp(12), 0)
    addView(ImageView(context).apply {
        setImageResource(R.drawable.ic_tab_search)
        imageTintList = ColorStateList.valueOf(context.getColor(R.color.token_text_quaternary))
    }, LinearLayout.LayoutParams(context.dp(18), context.dp(18)))
    addView(EditText(context).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(context.getColor(R.color.token_text_primary))
        setHintTextColor(context.getColor(R.color.token_text_placeholder))
        this.hint = hint
        background = null
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT
        imeOptions = EditorInfo.IME_ACTION_SEARCH or EditorInfo.IME_FLAG_NO_EXTRACT_UI
        setPadding(context.dp(8), 0, 0, 0)
    }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
}

/** Rows on one rounded surface, split by hairlines where the page shows through. */
internal fun group(rows: List<View>): View {
    val context = rows.first().context
    return LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(context.getColor(R.color.token_bg_tertiary), context.dp(24).toFloat())
        clipToOutline = true
        showDividers = LinearLayout.SHOW_DIVIDER_MIDDLE
        dividerDrawable = android.graphics.drawable.GradientDrawable().apply {
            setColor(context.getColor(R.color.token_card_primary))
            setSize(1, maxOf(1, (context.resources.displayMetrics.density * 0.67f).toInt()))
        }
        rows.forEach { addView(it, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)) }
    }
}

/** A group's place in a sheet's column, [top] dp under what is above it. */
private fun groupParams(context: Context, top: Int) =
    LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(top) }

/** Lays children out in rows, wrapping to the next row when one does not fit, [gap] apart both ways. */
internal class FlowLayout(context: Context, private val gap: Int) : ViewGroup(context) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val inner = width - paddingLeft - paddingRight
        var x = 0; var y = 0; var line = 0
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child.visibility == GONE) continue
            child.measure(MeasureSpec.makeMeasureSpec(inner, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
            if (x > 0 && x + child.measuredWidth > inner) { x = 0; y += line + gap; line = 0 }
            x += child.measuredWidth + gap
            line = maxOf(line, child.measuredHeight)
        }
        setMeasuredDimension(width, y + line + paddingTop + paddingBottom)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val inner = width - paddingLeft - paddingRight
        var x = 0; var y = 0; var line = 0
        val rows = mutableListOf<MutableList<View>>(mutableListOf())
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child.visibility == GONE) continue
            if (x > 0 && x + child.measuredWidth > inner) { x = 0; rows += mutableListOf<View>() }
            rows.last() += child
            x += child.measuredWidth + gap
        }
        y = paddingTop
        rows.forEach { row ->
            line = row.maxOfOrNull { it.measuredHeight } ?: 0
            x = paddingLeft
            row.forEach { child ->
                val top = y + (line - child.measuredHeight) / 2
                child.layout(x, top, x + child.measuredWidth, top + child.measuredHeight)
                x += child.measuredWidth + gap
            }
            y += line + gap
        }
    }
}
