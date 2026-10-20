package surf.comma.android.chat.live

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.text.Editable
import android.text.Spanned
import android.text.TextPaint
import android.text.TextWatcher
import android.text.style.MetricAffectingSpan
import android.view.Gravity
import android.view.View
import android.view.ViewTreeObserver
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import surf.comma.android.R
import surf.comma.android.conversation.ModelMentionLinks
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.list.statusTint
import surf.comma.android.tasks.ui.TaskStatusIconView
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.pressedFill
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.MentionModel
import surf.comma.android.workspace.Skill

/** A character that opens a composer menu: `@` for Task and model mentions, `/` for skills and agent commands. */
internal enum class ComposerTrigger(val char: Char) { MENTION('@'), SKILL('/') }

/** An open menu: its trigger, where it sits (from the trigger to the caret) and what has been typed after it. */
internal data class TriggerMatch(val trigger: ComposerTrigger, val start: Int, val end: Int, val query: String) {
    companion object {
        /**
         * The menu the caret opens in [text]: the run between the last whitespace before the caret and the caret
         * must start with a trigger that does not appear again in it. A CJK input method's fullwidth ＠ and ／ count.
         */
        fun find(text: CharSequence, caret: Int): TriggerMatch? {
            if (caret < 0 || caret > text.length) return null
            var start = caret
            while (start > 0 && !text[start - 1].isWhitespace()) start--
            if (start >= caret) return null
            val trigger = when (text[start]) {
                '@', '＠' -> ComposerTrigger.MENTION
                '/', '／' -> ComposerTrigger.SKILL
                else -> return null
            }
            val query = text.substring(start + 1, caret)
            if (query.contains(text[start])) return null
            return TriggerMatch(trigger, start, caret, query)
        }
    }
}

/**
 * A pick from the @ menu still in the draft. The field shows it as [displayText]; the message carries [wireText], the
 * desktop's Markdown link, which the agent and the server read with no new field. A mention edited by hand degrades
 * to text.
 */
internal sealed interface ComposerMention {
    val label: String
    val wireText: String
    val displayText: String get() = "@$label"

    companion object {
        /** The desktop's label: brackets as parentheses, each run of whitespace one space; [fallback] when none is left. */
        fun label(text: String, fallback: String): String =
            text.replace('[', '(').replace(']', ')').split(Regex("\\s+")).filter(String::isNotEmpty)
                .joinToString(" ").ifEmpty { fallback }

        /** [text] with each `@label` a picked mention still matches replaced by its link, longest labels first. */
        fun serialize(text: String, mentions: List<ComposerMention>): String {
            if (mentions.isEmpty() || '@' !in text) return text
            val unused = mentions.sortedByDescending { it.label.length }.toMutableList()
            val out = StringBuilder()
            var index = 0
            var afterSpace = true
            while (index < text.length) {
                val c = text[index]
                if (c == '@' && afterSpace) {
                    val found = unused.firstOrNull { m ->
                        text.startsWith(m.label, index + 1) &&
                            (index + 1 + m.label.length == text.length || !text[index + 1 + m.label.length].isLetterOrDigit())
                    }
                    if (found != null) {
                        out.append(found.wireText)
                        unused.remove(found)
                        index += 1 + found.label.length
                        afterSpace = false
                        continue
                    }
                }
                out.append(c)
                afterSpace = c.isWhitespace()
                index++
            }
            return out.toString()
        }
    }
}

/** A Task picked from the @ menu: `@Title` in the field, `[Title](comma:task/<id>)` in the message. */
internal data class TaskMention(override val label: String, val conversationId: String) : ComposerMention {
    override val wireText get() = "[$label](comma:task/$conversationId)"

    companion object {
        private val LINK_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._-]*$")

        fun of(title: String, id: String): TaskMention? {
            if (!LINK_ID.matches(id)) return null
            return TaskMention(ComposerMention.label(title, id), id)
        }
    }
}

/**
 * A model picked from the router chat's @ menu, at its default thinking effort or at one chosen: `@GPT 5.5` or
 * `@GPT 5.5 · high` in the field, `[GPT 5.5 · high](comma:model/<id>?effort=high)` in the message. The server starts a
 * Task with that model and the rest of the message instead of the router's turn.
 */
internal data class ModelMention(override val label: String, val modelId: String, val effort: String? = null) : ComposerMention {
    override val wireText get() = "[$label](comma:model/$modelId${effort?.let { "?effort=$it" }.orEmpty()})"

    companion object {
        private val MODEL_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}$")
        private val EFFORT = Regex("^[a-z_]{1,32}$")

        /** [modelId], named [name], at [effort] or its default; null for an id or effort no link can carry. */
        fun of(name: String, modelId: String, effort: String? = null): ModelMention? {
            if (!MODEL_ID.matches(modelId) || (effort != null && !EFFORT.matches(effort))) return null
            return ModelMention(ComposerMention.label(if (effort == null) name else "$name · $effort", modelId), modelId, effort)
        }

        /** The model mentions a person's [text] carries, in order, as the server reads them. */
        fun parse(text: String): List<ModelMention> = if (ModelMentionLinks.PREFIX !in text) emptyList() else
            ModelMentionLinks.PATTERN.findAll(text).map {
                ModelMention(it.groupValues[1], it.groupValues[2], it.groupValues[3].ifEmpty { null })
            }.toList()
    }
}

/**
 * How a mention reads in the field, as the desktop's token: link-coloured, medium weight. It covers the mention's
 * [ComposerMention.displayText]; a deletion that reaches into it takes the whole mention away ([TriggerMenu]).
 */
internal class MentionSpan(val mention: ComposerMention, private val color: Int, private val typeface: Typeface) : MetricAffectingSpan() {
    override fun updateDrawState(paint: TextPaint) {
        paint.color = color
        paint.typeface = typeface
    }

    override fun updateMeasureState(paint: TextPaint) {
        paint.typeface = typeface
    }
}

/**
 * The composer's two menus, as on the desktop and the iOS app: @ lists open Tasks, newest first, and in the router
 * chat first the models a Task can start with; / lists the agent commands in the router chat, then the workspace
 * skills. Each section is ranked by the desktop filter; a settled section with no match is dropped, a loading one
 * stays with a Searching row. A model that takes thinking efforts opens a second level of them from its row's chevron.
 * A menu floats over the conversation just above the composer; picking a row puts it into the draft at the trigger.
 * Nothing is sent from here.
 */
internal class TriggerMenu(
    private val context: Context,
    private val field: EditText,
    private val isRouter: Boolean,
    private val tasks: () -> List<TaskSummary>,
    private val skills: () -> List<Skill>?,
    private val excludedTaskId: () -> String?,
    private val onNeedSkills: () -> Unit,
    /** The models the router chat offers; null while they are read. */
    private val models: () -> List<MentionModel>? = { emptyList() },
    private val onNeedModels: () -> Unit = {},
) {
    /** Picks still in the draft, which [serialize] turns into links on send. */
    private val mentions = mutableListOf<ComposerMention>()
    private val column = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(0, context.dp(6), 0, context.dp(6))
    }
    /** At most [MAX_HEIGHT_DP] tall, so the conversation still shows above it; longer lists scroll inside. */
    val view: FrameLayout = object : FrameLayout(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
            super.onMeasure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(context.dp(MAX_HEIGHT_DP), MeasureSpec.AT_MOST))
    }.apply {
        // Opaque, so its rows read over any message; the edge and shadow lift it off the conversation.
        background = surf.comma.android.ui.kit.rounded(context.getColor(R.color.token_card_primary), context.dp(22).toFloat(),
            context.getColor(R.color.token_border_primary), 1)
        elevation = context.dp(12).toFloat()
        clipToOutline = true
        visibility = View.GONE
        addView(ScrollContainer(context).apply { addView(column) }, FrameLayout.LayoutParams(-1, -2))
    }
    private var dismissedAt: Int? = null
    /** The model whose thinking efforts the menu lists, and the trigger it was opened from. */
    private var efforts: Pair<Int, MentionModel>? = null
    /** Set while the rest of a mention a deletion reached into is taken away. */
    private var trimming = false
    private val focusWatcher = ViewTreeObserver.OnGlobalFocusChangeListener { lost, gained ->
        if (gained === field) refresh() else if (lost === field) hide()
    }

    init {
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (trimming) return
                s?.let(::keepMentions)
                refresh()
            }
        })
        // Watched through the window, not the field's own focus listener, which belongs to the composer.
        if (field.isAttachedToWindow) field.viewTreeObserver.addOnGlobalFocusChangeListener(focusWatcher)
        field.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: View) = v.viewTreeObserver.addOnGlobalFocusChangeListener(focusWatcher)
            override fun onViewDetachedFromWindow(v: View) = v.viewTreeObserver.removeOnGlobalFocusChangeListener(focusWatcher)
        })
    }

    fun serialize(text: String): String {
        mentions.retainAll { it.displayText in field.text }
        return ComposerMention.serialize(text, mentions)
    }

    /** The locations of the skills the outgoing text names. */
    fun skillLocations(text: String): List<String> = Skill.mentionedLocations(text, skills().orEmpty())

    fun hide() {
        efforts = null
        view.isVisible = false
    }

    /** Escape-like dismissal: the open trigger stays closed until the caret leaves it. */
    fun dismiss() {
        dismissedAt = TriggerMatch.find(field.text, field.selectionEnd)?.start
        hide()
    }

    fun refresh() {
        if (field.selectionStart != field.selectionEnd) return hide()
        val match = TriggerMatch.find(field.text, field.selectionEnd)
        if (match == null || match.start == dismissedAt) {
            if (match == null) dismissedAt = null
            return hide()
        }
        if (match.trigger == ComposerTrigger.SKILL) onNeedSkills()
        if (match.trigger == ComposerTrigger.MENTION && isRouter) onNeedModels()
        efforts?.let { (at, model) -> if (at == match.start && match.trigger == ComposerTrigger.MENTION) return showEfforts(model, match) }
        efforts = null
        val sections = sections(match)
        if (sections.isEmpty()) return hide()
        column.removeAllViews()
        sections.forEach { section ->
            column.addView(sectionTitle(section.title))
            if (section.items.isEmpty() && section.loading) {
                column.addView(context.label(Level.SMALL, R.color.token_text_tertiary).apply {
                    setText(R.string.composer_searching)
                    setPadding(context.dp(14), context.dp(10), context.dp(14), context.dp(10))
                })
            }
            section.items.forEach { item -> column.addView(row(item, match)) }
        }
        view.isVisible = true
    }

    /** A model's second level: back to the menu, then its default thinking effort and each it takes. */
    private fun showEfforts(model: MentionModel, match: TriggerMatch) {
        efforts = match.start to model
        column.removeAllViews()
        column.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = context.dp(44)
            setPadding(context.dp(14), context.dp(6), context.dp(14), context.dp(6))
            addView(icon(R.drawable.ic_task_back), LinearLayout.LayoutParams(context.dp(16), context.dp(16)).apply { marginEnd = context.dp(10) })
            addView(context.label(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply { text = model.name },
                LinearLayout.LayoutParams(0, -2, 1f))
            pressedFill()
            setOnClickListener {
                efforts = null
                refresh()
            }
            contentDescription = context.getString(R.string.composer_efforts_back)
        })
        column.addView(sectionTitle(context.getString(R.string.composer_effort)))
        (listOf<String?>(null) + model.efforts).forEach { effort ->
            val mention = ModelMention.of(model.name, model.id, effort) ?: return@forEach
            column.addView(row(Item("model:${model.id}:${effort.orEmpty()}", effort ?: context.getString(R.string.composer_effort_default),
                null, null, insertion = mention.displayText, mention = mention, plain = true), match))
        }
        view.isVisible = true
    }

    /**
     * A row of the menu. [model] marks a model's row, which opens its thinking efforts from a chevron when it takes
     * any; [plain] rows (a thinking effort) keep the icon's room empty, under the name they belong to.
     */
    private data class Item(val id: String, val label: String, val detail: String?, val search: String?,
                            val task: TaskSummary? = null, val insertion: String, val mention: ComposerMention? = null,
                            val command: Boolean = false, val model: MentionModel? = null, val plain: Boolean = false)
    private data class Section(val title: String, val items: List<Item>, val loading: Boolean)

    private fun sections(match: TriggerMatch): List<Section> {
        val all = when (match.trigger) {
            ComposerTrigger.MENTION -> {
                val taskSection = Section(context.getString(R.string.composer_tasks), taskItems(), false)
                if (isRouter) {
                    val catalog = models()
                    listOf(Section(context.getString(R.string.composer_models), modelItems(catalog.orEmpty()), catalog == null), taskSection)
                } else listOf(taskSection)
            }
            ComposerTrigger.SKILL -> {
                val catalog = skills()
                val skillSection = Section(context.getString(R.string.composer_skills), skillItems(catalog.orEmpty(), match), catalog == null)
                if (isRouter) listOf(Section(context.getString(R.string.composer_agent_commands), commandItems(), false), skillSection)
                else listOf(skillSection)
            }
        }
        return all.mapNotNull { section ->
            val items = filter(section.items, match.query)
            if (items.isEmpty() && !section.loading) null else section.copy(items = items.take(MAX_ROWS))
        }
    }

    private fun taskItems(): List<Item> = tasks().filter { !it.isArchived && it.id != excludedTaskId() && it.title.isNotBlank() }
        .sortedByDescending { it.updatedAt }.mapNotNull { task ->
            val mention = TaskMention.of(task.title, task.id) ?: return@mapNotNull null
            Item("task:${task.id}", task.title, null, null, task, mention.displayText, mention)
        }

    /** Each model at its default effort, found by its name or its id. */
    private fun modelItems(catalog: List<MentionModel>): List<Item> = catalog.mapNotNull { model ->
        val mention = ModelMention.of(model.name, model.id) ?: return@mapNotNull null
        Item("model:${model.id}", model.name, null, model.id, insertion = mention.displayText, mention = mention, model = model)
    }

    private fun skillItems(catalog: List<Skill>, match: TriggerMatch): List<Item> {
        val rest = field.text.toString().removeRange(match.start, match.end)
        val mentioned = Skill.mentionedLocations(rest, catalog).toSet()
        return catalog.filter { it.location !in mentioned }.map { skill ->
            Item(skill.id, skill.name, skill.description, skill.id, insertion = "/${skill.id}")
        }
    }

    private fun commandItems(): List<Item> = listOf(
        Triple("status", "status", R.string.composer_command_status),
        Triple("compact", "compact", R.string.composer_command_compact),
        Triple("help", "help", R.string.composer_command_help),
    ).map { (name, body, detail) ->
        Item("salix-$name", "/$name", context.getString(detail), "salix-command $name", insertion = "/$body", command = true)
    }

    /** The desktop ranking: a search text, label or id that starts with the query, then one that contains it, then a detail. */
    private fun filter(items: List<Item>, query: String): List<Item> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return items
        return items.mapIndexedNotNull { index, item ->
            val primary = listOfNotNull(item.search, item.label, item.id).map { it.lowercase() }
            val rank = when {
                primary.any { it.startsWith(q) } -> 0
                primary.any { it.contains(q) } -> 1
                item.detail?.lowercase()?.contains(q) == true -> 2
                else -> return@mapIndexedNotNull null
            }
            Triple(rank, index, item)
        }.sortedWith(compareBy({ it.first }, { it.second })).map { it.third }
    }

    private fun sectionTitle(title: String): View = context.label(Level.MINI, R.color.token_text_quaternary, DesignFonts.semibold).apply {
        text = title
        setPadding(context.dp(14), context.dp(8), context.dp(14), context.dp(4))
    }

    private fun icon(resource: Int, tint: Int = R.color.token_text_tertiary) = ImageView(context).apply {
        setImageResource(resource)
        imageTintList = ColorStateList.valueOf(context.getColor(tint))
    }

    private fun row(item: Item, match: TriggerMatch): View = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = context.dp(44)
        setPadding(context.dp(14), context.dp(6), context.dp(14), context.dp(6))
        val iconSize = LinearLayout.LayoutParams(context.dp(16), context.dp(16)).apply { marginEnd = context.dp(10) }
        when {
            item.task != null -> addView(TaskStatusIconView(context).apply {
                setStatus(item.task.bucket, statusTint(context, item.task.bucket), spin = false)
            }, iconSize)
            item.model != null -> addView(icon(R.drawable.ic_history_thinking), iconSize)
            item.plain -> addView(View(context), iconSize)
            !item.command -> addView(icon(R.drawable.ic_composer_slash), iconSize)
        }
        val effortful = item.model?.takeIf { it.efforts.isNotEmpty() }
        addView(context.label(Level.REGULAR, R.color.token_text_primary).apply { text = item.label },
            if (effortful != null) LinearLayout.LayoutParams(0, -2, 1f) else LinearLayout.LayoutParams(-2, -2))
        item.detail?.let { detail ->
            addView(context.label(Level.SMALL, R.color.token_text_quaternary).apply { text = detail },
                LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = context.dp(8) })
        }
        // The row takes the model at its default effort; the chevron opens the others.
        effortful?.let { model ->
            addView(icon(R.drawable.ic_settings_chevron, R.color.token_text_quaternary).apply {
                scaleType = ImageView.ScaleType.CENTER
                contentDescription = context.getString(R.string.composer_efforts_open, model.name)
                pressedFill(radius = context.dp(12).toFloat())
                setOnClickListener { showEfforts(model, match) }
            }, LinearLayout.LayoutParams(context.dp(EFFORTS_TARGET_DP), context.dp(44)).apply {
                // The whole row's height, over its padding, so the row stays as tall as the others; the glyph's own
                // inset brings its stroke to the row's edge.
                topMargin = -context.dp(6)
                bottomMargin = -context.dp(6)
                marginEnd = -context.dp(8)
            })
        }
        pressedFill()
        setOnClickListener { pick(item, match) }
        contentDescription = listOfNotNull(item.label, item.detail).joinToString(", ")
    }

    /** Replaces the trigger and its query with the row's text and a space, the caret after it; a mention is marked as one. */
    private fun pick(item: Item, match: TriggerMatch) {
        val text = field.text
        if (match.end > text.length) return hide()
        val end = if (match.end < text.length && text[match.end].isWhitespace()) match.end + 1 else match.end
        val insertion = item.insertion + " "
        text.replace(match.start, end, insertion)
        item.mention?.let { mention ->
            mentions += mention
            text.setSpan(MentionSpan(mention, context.getColor(R.color.token_markdown_text_link), DesignFonts.inter(context, DesignFonts.medium)),
                match.start, match.start + mention.displayText.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        field.setSelection((match.start + insertion.length).coerceAtMost(field.text.length))
        hide()
    }

    /** A mention whose words were changed is text again; a deletion that reached into one takes the rest of it, as on the desktop. */
    private fun keepMentions(text: Editable) {
        for (span in text.getSpans(0, text.length, MentionSpan::class.java)) {
            val start = text.getSpanStart(span)
            val end = text.getSpanEnd(span)
            if (start < 0 || text.substring(start, end) == span.mention.displayText) continue
            text.removeSpan(span)
            if (end - start < span.mention.displayText.length) {
                trimming = true
                try {
                    text.delete(start, end)
                } finally {
                    trimming = false
                }
            }
        }
    }

    private companion object {
        const val MAX_ROWS = 30
        const val MAX_HEIGHT_DP = 300
        const val EFFORTS_TARGET_DP = 40
    }
}
