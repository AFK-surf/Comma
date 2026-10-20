package surf.comma.android.labels

import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Paint
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import surf.comma.android.R
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignLabelColors
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.LabelCatalog
import surf.comma.android.workspace.LabelProposal
import surf.comma.android.workspace.WorkspaceGraph

/**
 * The Group's Task label catalog: add, edit and delete labels, decide Comma's proposals, and choose whether
 * proposals need approval. Every change returns the whole catalog, which replaces the shown copy. A Settings page;
 * [TaskLabelsSheet] shows the same content over an open Task.
 */
internal class TaskLabelsPage(ctx: SettingsContext) : SettingsPage {
    override val key = KEY
    private val layout = SettingsPageLayout(ctx.activity, ctx.activity.getString(R.string.labels_title)) { ctx.back() }
    override val view: View = layout
    private val content = TaskLabelsContent(ctx.activity, layout)

    override fun onRemoved() = content.release()

    companion object { const val KEY = "labels" }
}

/** The label catalog over an open Task, from its details card's Manage labels. */
internal class TaskLabelsSheet(activity: ComponentActivity, onChanged: () -> Unit = {}) :
    CommaSheet(activity, activity.getString(R.string.labels_title), Detent.LARGE) {
    private val layout = SettingsPageLayout(activity, "", showBack = false) {}.apply {
        bar.isVisible = false
        setBackgroundColor(activity.getColor(R.color.token_card_primary))
    }
    private val content = TaskLabelsContent(activity, layout, onChanged)

    init { setContent(layout) }

    override fun onRemoved() = content.release()
}

private class TaskLabelsContent(
    private val activity: ComponentActivity,
    private val layout: SettingsPageLayout,
    private val onChanged: () -> Unit = {},
) {
    private val store = WorkspaceGraph.get(activity)
    private val error = activity.label(Level.SMALL, R.color.token_text_error_primary, lines = 0).apply {
        isVisible = false
        setPadding(activity.dp(4), 0, activity.dp(4), 0)
    }
    private val loading = activity.label(Level.SMALL, R.color.token_text_quaternary).apply {
        text = activity.getString(R.string.settings_devices_loading)
        gravity = Gravity.CENTER
    }
    private val proposals = SettingsSection(activity, activity.getString(R.string.labels_suggested))
    private val labels = SettingsSection(activity, activity.getString(R.string.labels_section))
        .footer(activity.getString(R.string.labels_footer))
    private val ask = SettingsRow(activity, null, activity.getString(R.string.labels_policy_ask))
    private val auto = SettingsRow(activity, null, activity.getString(R.string.labels_policy_auto))
    private val policy = SettingsSection(activity, activity.getString(R.string.labels_policy)).add(ask).add(auto)
        .footer(activity.getString(R.string.labels_policy_footer))
    private var catalog: LabelCatalog? = null
    /** Requests run one at a time, in the order asked, so each one starts from the catalog the last returned. */
    private val requests = Mutex()
    private var inFlight = 0
    private val busy get() = inFlight > 0
    private var released = false

    init {
        layout.section(error, top = 0)
        layout.section(loading, top = 0)
        layout.section(proposals, top = 0)
        layout.section(labels)
        layout.section(policy)
        ask.trailing(check()).onClick { setPolicy("ask") }
        auto.trailing(check()).onClick { setPolicy("auto") }
        render()
        perform { labelCatalog(it) }
    }

    fun release() { released = true }

    private fun render() {
        val catalog = catalog
        loading.isVisible = catalog == null && !error.isVisible
        proposals.isVisible = catalog?.proposals?.isNotEmpty() == true
        labels.isVisible = catalog != null
        policy.isVisible = catalog != null
        if (catalog == null) return
        proposals.card.removeAllViews()
        catalog.proposals.forEach { proposals.add(ProposalRow(it)) }
        labels.card.removeAllViews()
        if (catalog.labels.isEmpty()) labels.add(SettingsRow(activity, null, activity.getString(R.string.labels_none)).apply {
            title.setTextColor(activity.getColor(R.color.token_text_tertiary))
        })
        catalog.labels.forEach { label -> labels.add(labelRow(label, catalog.descriptions[label.id])) }
        labels.add(SettingsRow(activity, R.drawable.ic_action_plus, activity.getString(R.string.labels_add), tint = R.color.token_bg_brand_solid)
            .onClick { edit(null, catalog.colors.firstOrNull() ?: "blue", null) })
        ask.findViewWithTag<View>(CHECK)?.alpha = if (catalog.approvalPolicy == "ask") 1f else 0f
        auto.findViewWithTag<View>(CHECK)?.alpha = if (catalog.approvalPolicy == "auto") 1f else 0f
        listOf(ask, auto).forEach { it.isEnabled = !busy }
    }

    private fun labelRow(label: TaskLabel, description: String?): View {
        val row = SettingsRow(activity, null, label.name)
        row.icon.isVisible = true
        row.icon.setImageDrawable(dot(DesignLabelColors.resolve(activity, label.color)))
        row.icon.imageTintList = null
        row.detail(description)
        val more = ImageView(activity).apply {
            setImageResource(R.drawable.ic_inbox_actions)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_secondary))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = activity.getString(R.string.labels_actions, label.name)
            setPadding(activity.dp(10), activity.dp(10), activity.dp(10), activity.dp(10))
            layoutParams = FrameLayout.LayoutParams(activity.dp(44), activity.dp(44))
            setOnClickListener { menu(it, label, description) }
        }
        row.trailing(more)
        row.onClick { edit(label, label.color, description) }
        row.setOnLongClickListener { menu(it, label, description); true }
        return row
    }

    private fun menu(anchor: View, label: TaskLabel, description: String?) {
        ActionMenu(activity).apply {
            item(activity.getString(R.string.labels_edit), R.drawable.ic_action_rename) { edit(label, label.color, description) }
            item(activity.getString(R.string.labels_delete), R.drawable.ic_trash_can, destructive = true) {
                perform { deleteLabel(it, label.id) }
            }
        }.show(anchor)
    }

    private fun edit(label: TaskLabel?, color: String, description: String?) {
        LabelEditor(activity, label, color, description, catalog?.colors.orEmpty()) { name, chosen, text ->
            // The editor has closed by now, so its save waits for any request in flight rather than being dropped.
            perform(queue = true) {
                if (label != null) updateLabel(it, label.id, name, chosen, text) else createLabel(it, name, chosen, text)
            }
        }.show()
    }

    private fun setPolicy(value: String) {
        if (catalog?.approvalPolicy == value) return
        perform { setLabelPolicy(it, value) }
    }

    /** Runs one catalog request. A tap while another is in flight is dropped unless [queue] says to wait its turn. */
    private fun perform(queue: Boolean = false,
                        block: suspend surf.comma.android.workspace.CommaApi.(surf.comma.android.auth.ConversationScope) -> LabelCatalog) {
        if (busy && !queue) return
        inFlight++
        render()
        activity.lifecycleScope.launch {
            requests.withLock {
                try {
                    val next = store.call(block)
                    if (released) return@withLock
                    val changed = catalog != null
                    catalog = next
                    error.isVisible = false
                    // Proposals that apply labels and deletions change Tasks too.
                    if (changed) { store.refresh(); onChanged() }
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (_: Exception) {
                    if (released) return@withLock
                    error.text = activity.getString(R.string.app_failure_generic)
                    error.isVisible = true
                } finally {
                    inFlight--
                    if (!released) render()
                }
            }
        }
    }

    private fun check() = ImageView(activity).apply {
        tag = CHECK
        setImageResource(R.drawable.ic_action_check)
        imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_bg_brand_solid))
        layoutParams = FrameLayout.LayoutParams(activity.dp(24), activity.dp(24))
        alpha = 0f
    }

    /** A label change Comma suggested: what it does, the labels it names, why, and the member's answer. */
    private inner class ProposalRow(proposal: LabelProposal) : LinearLayout(activity) {
        init {
            orientation = VERTICAL
            setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
            addView(activity.label(Level.REGULAR, R.color.token_text_primary, lines = 0).apply { text = headline(proposal) })
            if (proposal.labels.isNotEmpty()) {
                val chips = LinearLayout(activity).apply { orientation = HORIZONTAL }
                proposal.labels.take(4).forEach { label ->
                    chips.addView(TextView(activity).apply {
                        DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
                        setTextColor(activity.getColor(R.color.token_text_primary))
                        text = label.name
                        compoundDrawablePadding = activity.dp(5)
                        setCompoundDrawablesRelativeWithIntrinsicBounds(dot(DesignLabelColors.resolve(activity, label.color), 8), null, null, null)
                        setPadding(activity.dp(9), activity.dp(3), activity.dp(9), activity.dp(3))
                        background = rounded(activity.getColor(R.color.token_surface_ink), activity.dp(12).toFloat())
                    }, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginEnd = activity.dp(6) })
                }
                addView(chips, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            }
            proposal.summary?.let { summary ->
                addView(activity.label(Level.SMALL, R.color.token_text_tertiary, lines = 0).apply { text = summary },
                    LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(8) })
            }
            val answers = LinearLayout(activity).apply { orientation = HORIZONTAL }
            answers.addView(answer(R.string.labels_approve, R.color.token_bg_brand_solid, android.graphics.Color.WHITE) {
                perform { resolveProposal(it, proposal.id, true) }
            })
            answers.addView(answer(R.string.labels_dismiss, R.color.token_surface_ink, activity.getColor(R.color.token_text_primary)) {
                perform { resolveProposal(it, proposal.id, false) }
            }, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = activity.dp(8) })
            addView(answers, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = activity.dp(12) })
        }

        private fun answer(text: Int, fill: Int, ink: Int, action: () -> Unit) = TextView(activity).apply {
            DesignTypography.applyTo(this, Level.SMALL, DesignFonts.medium)
            setTextColor(ink)
            setText(text)
            gravity = Gravity.CENTER
            minHeight = activity.dp(32)
            setPadding(activity.dp(14), 0, activity.dp(14), 0)
            background = rounded(activity.getColor(fill), activity.dp(16).toFloat())
            tactile()
            setOnClickListener { action() }
        }
    }

    private fun headline(proposal: LabelProposal): String = when (proposal.op) {
        "create" -> activity.getString(R.string.labels_proposal_create)
        "update" -> activity.getString(R.string.labels_proposal_update)
        "delete" -> activity.getString(R.string.labels_proposal_delete)
        "apply" -> proposal.conversationTitle?.let { activity.getString(R.string.labels_proposal_apply, it) }
            ?: activity.getString(R.string.labels_proposal_apply_task)
        else -> activity.getString(R.string.labels_proposal_other)
    }

    private fun dot(color: Int, sizeDp: Int = 20) = LabelDot(color, activity.dp(sizeDp), activity.dp(minOf(10, sizeDp)))

    private companion object { const val CHECK = "check" }
}

/** A label's colour as a dot centred in a square, for row icons and chips. */
internal class LabelDot(color: Int, private val side: Int, private val diameter: Int) : android.graphics.drawable.Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    override fun draw(canvas: Canvas) {
        val b = bounds
        canvas.drawCircle(b.exactCenterX(), b.exactCenterY(), diameter / 2f, paint)
    }
    override fun getIntrinsicWidth() = side
    override fun getIntrinsicHeight() = side
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) { paint.colorFilter = colorFilter }
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = android.graphics.PixelFormat.TRANSLUCENT
}

/** The sheet for a label's name, description and colour. */
internal class LabelEditor(
    activity: ComponentActivity,
    private val label: TaskLabel?,
    color: String,
    description: String?,
    colors: List<String>,
    private val save: (name: String, color: String, description: String?) -> Unit,
) : CommaSheet(activity, activity.getString(if (label == null) R.string.labels_new else R.string.labels_edit), Detent.LARGE) {
    private var chosen = color
    private val name = field(activity.getString(R.string.labels_name), label?.name.orEmpty(), multiline = false)
    private val details = field(activity.getString(R.string.labels_description), description.orEmpty(), multiline = true)
    private val saveButton = TextView(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.semibold)
        setText(R.string.shell_save)
        setTextColor(activity.getColor(R.color.token_bg_brand_solid))
        gravity = Gravity.CENTER
        minHeight = activity.dp(44)
        setPadding(activity.dp(12), 0, activity.dp(12), 0)
        tactile()
    }
    private val swatches = GridLayout(activity).apply { columnCount = 6 }
    private val options = (colors.ifEmpty { FALLBACK }).let { if (color in it) it else it + color }

    init {
        val page = SettingsPageLayout(activity, "", showBack = false) {}.apply {
            bar.isVisible = false
            setBackgroundColor(activity.getColor(R.color.token_card_primary))
        }
        page.section(SettingsSection(activity, null).add(name).add(details), top = 0)
        page.section(SettingsSection(activity, activity.getString(R.string.labels_colour)).add(swatches.apply {
            setPadding(activity.dp(6), activity.dp(6), activity.dp(6), activity.dp(6))
        }))
        setContent(page)
        trailing.addView(saveButton)
        saveButton.setOnClickListener {
            val trimmed = name.text.toString().trim()
            if (trimmed.isEmpty()) return@setOnClickListener
            val text = details.text.toString().trim()
            save(trimmed, chosen, if (label == null && text.isEmpty()) null else text)
            dismiss()
        }
        name.doAfterTextChanged { updateSave() }
        updateSave()
        drawSwatches()
    }

    override fun onShown() {
        if (label != null) return
        name.requestFocus()
        name.post { activity.getSystemService(InputMethodManager::class.java)?.showSoftInput(name, 0) }
    }

    private fun updateSave() {
        val enabled = name.text.toString().isNotBlank()
        saveButton.isEnabled = enabled
        saveButton.alpha = if (enabled) 1f else 0.4f
    }

    private fun drawSwatches() {
        swatches.removeAllViews()
        val size = activity.dp(44)
        options.forEach { option ->
            val tint = DesignLabelColors.resolve(activity, option)
            val selected = option == chosen
            swatches.addView(FrameLayout(activity).apply {
                addView(View(activity).apply {
                    background = android.graphics.drawable.GradientDrawable().apply {
                        shape = android.graphics.drawable.GradientDrawable.OVAL
                        setColor(tint)
                        if (selected) setStroke(activity.dp(3), androidx.core.graphics.ColorUtils.setAlphaComponent(tint, 115))
                    }
                }, FrameLayout.LayoutParams(activity.dp(if (selected) 36 else 30), activity.dp(if (selected) 36 else 30), Gravity.CENTER))
                if (selected) addView(ImageView(activity).apply {
                    setImageResource(R.drawable.ic_action_check)
                    imageTintList = ColorStateList.valueOf(android.graphics.Color.WHITE)
                }, FrameLayout.LayoutParams(activity.dp(24), activity.dp(24), Gravity.CENTER))
                contentDescription = option
                isSelected = selected
                tactile(0.9f)
                setOnClickListener { chosen = option; drawSwatches() }
            }, GridLayout.LayoutParams().apply {
                width = 0
                height = size
                columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
            })
        }
    }

    private fun field(hint: String, value: String, multiline: Boolean) = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.regular)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        this.hint = hint
        setText(value)
        background = null
        minHeight = activity.dp(50)
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
            (if (multiline) InputType.TYPE_TEXT_FLAG_MULTI_LINE else 0)
        if (multiline) maxLines = 4 else isSingleLine = true
        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    private companion object {
        val FALLBACK = listOf("blue", "indigo", "purple", "pink", "orange", "warning", "success", "error", "brand")
    }
}
