package surf.comma.android.tasks.ui

import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskListRow
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.tasks.canArchive

/** A label pill on a card: outlined, with a dot in the label's color. */
class PreparedPill(
    val text: TextBlock,
    val left: Int,
    val top: Int,
    val width: Int,
    val height: Int,
    val dotColor: Int,
)

/** A laid-out row of the full task list. Built off the main thread; views only draw it. */
sealed interface PreparedTaskRow {
    val key: String
    val heightPx: Int

    class Header(
        override val key: String,
        val bucket: TaskStatusBucket,
        val label: TextBlock,
        val count: TextBlock,
        override val heightPx: Int,
    ) : PreparedTaskRow

    class Card(
        override val key: String,
        val task: TaskSummary,
        val bucket: TaskStatusBucket,
        val title: TextBlock,
        /** A running task's progress, or that it failed; null when the header says it all. */
        val status: TextBlock?,
        val pills: List<PreparedPill>,
        /** When it was updated; null when the source did not say. */
        val footer: TextBlock?,
        /** Offsets inside the card, which starts at the row's top-left gutter. */
        val statusTop: Int,
        val footerTop: Int,
        val cardHeightPx: Int,
        override val heightPx: Int,
        val contentDescription: String,
        /** Ended tasks can be swiped to archive. */
        val archivable: Boolean,
    ) : PreparedTaskRow
}

/** Card and header geometry; the views read the same numbers when drawing. */
class TaskCardMetrics(theme: TaskTheme) {
    val gutter = theme.dpInt(16f)
    val pad = theme.dpInt(12f)
    val icon = theme.dpInt(16f)
    val iconGap = theme.dpInt(8f)
    val cardGap = theme.dpInt(8f)
    val radius = theme.dp(12f)
    val pillPadH = theme.dpInt(8f)
    val pillPadV = theme.dpInt(1f)
    val pillGap = theme.dpInt(4f)
    val dot = theme.dpInt(6f)
    val dotGap = theme.dpInt(4f)
    val headerHeight = theme.dpInt(40f)
    val titleLineHeight = theme.lineHeightPx(TaskType.cardTitle)
}

/**
 * Turns list rows into [PreparedTaskRow]s for a given width. Safe to call from a background
 * dispatcher: it only reads the immutable theme and strings, and every call builds its own
 * paints. Results are memoised on the exact inputs, so a refresh that changes one task lays
 * out one card.
 */
class TaskRowPreparer(private val theme: TaskTheme, private val strings: TaskStrings) {
    val metrics = TaskCardMetrics(theme)
    private val cache = LruMap<Any, PreparedTaskRow>(MAX_CACHED_ROWS)

    fun prepare(rows: List<TaskListRow>, labels: List<TaskLabel>, widthPx: Int): List<PreparedTaskRow> {
        val catalog = labels.associateBy { it.id }
        val day = strings.day()
        return rows.map { row ->
            when (row) {
                is TaskListRow.Header -> {
                    val key = HeaderKey(row, widthPx)
                    cache.getOrPut(key) { header(row) }
                }
                is TaskListRow.Card -> {
                    val cardLabels = row.task.labelIds.mapNotNull { catalog[it] }
                    val key = CardKey(row.task, cardLabels, widthPx, day)
                    cache.getOrPut(key) { card(row, cardLabels, widthPx) }
                }
            }
        }
    }

    private fun header(row: TaskListRow.Header): PreparedTaskRow.Header {
        val label = theme.line(theme.statusLabel(row.bucket), TaskType.sectionHeader, theme.textSecondary, Int.MAX_VALUE)
        val count = theme.line(row.count.toString(), TaskType.meta, theme.textQuaternary, Int.MAX_VALUE)
        return PreparedTaskRow.Header(row.key, row.bucket, label, count, metrics.headerHeight)
    }

    private fun card(row: TaskListRow.Card, labels: List<TaskLabel>, widthPx: Int): PreparedTaskRow.Card {
        val task = row.task
        val bucket = task.bucket
        val m = metrics
        val cardWidth = widthPx - m.gutter * 2
        val textLeft = m.pad + m.icon + m.iconGap
        val textWidth = (cardWidth - textLeft - m.pad).coerceAtLeast(1)
        val titleText = strings.title(task)
        val title = theme.block(titleText, TaskType.cardTitle, theme.textPrimary, textWidth, maxLines = 2)

        // The section header already names the status; a card adds only what is its own: a
        // running task's latest progress, or that a task in the cancelled group failed.
        val statusText = theme.statusText(bucket, task.failed)
        val detailText = when {
            bucket == TaskStatusBucket.IN_PROGRESS -> task.progress?.trim()?.takeIf { it.isNotEmpty() }
            task.failed -> statusText
            else -> null
        }
        val status = detailText?.let { theme.block(it, TaskType.meta, theme.textSecondary, textWidth) }
        val statusTop = m.pad + title.heightPx
        var cursor = statusTop + (status?.heightPx ?: 0)

        val pills = layoutPills(labels, textLeft, cursor + m.cardGap, textWidth)
        if (pills.isNotEmpty()) cursor = pills.maxOf { it.top + it.height }

        val updatedText = strings.updated(task.updatedAt)
        val footer = updatedText?.let { theme.block(it, TaskType.pill, theme.textQuaternary, textWidth) }
        val footerTop = cursor + if (footer != null) m.pillGap * 2 else 0
        val cardHeight = footerTop + (footer?.heightPx ?: 0) + m.pad

        // Read aloud in full: the status is said even though the card only shows it by its glyph.
        val description = buildList {
            add(titleText)
            add(statusText)
            detailText?.takeIf { it != statusText }?.let(::add)
            labels.forEach { add(it.name) }
            updatedText?.let(::add)
        }.joinToString(", ")
        return PreparedTaskRow.Card(
            key = row.key,
            task = task,
            bucket = bucket,
            title = title,
            status = status,
            pills = pills,
            footer = footer,
            statusTop = statusTop,
            footerTop = footerTop,
            cardHeightPx = cardHeight,
            heightPx = cardHeight + m.cardGap,
            contentDescription = description,
            archivable = task.canArchive,
        )
    }

    /** Flows pills left to right, wrapping onto new lines inside [maxWidth]. */
    private fun layoutPills(
        labels: List<TaskLabel>,
        left: Int,
        top: Int,
        maxWidth: Int,
    ): List<PreparedPill> {
        val m = metrics
        if (labels.isEmpty()) return emptyList()
        val lineHeight = theme.lineHeightPx(TaskType.pill)
        val height = lineHeight + m.pillPadV * 2
        var x = 0
        var y = top
        val lead = m.dot + m.dotGap
        return labels.map { label ->
            val textMax = (maxWidth - m.pillPadH * 2 - lead).coerceAtLeast(1)
            val text = theme.line(label.name, TaskType.pill, theme.textSecondary, textMax)
            val width = m.pillPadH * 2 + lead + text.contentWidthPx
            if (x > 0 && x + width > maxWidth) {
                x = 0
                y += height + m.pillGap
            }
            PreparedPill(text, left + x, y, width, height, theme.labelColor(label.color)).also { x += width + m.pillGap }
        }
    }

    private data class HeaderKey(val row: TaskListRow.Header, val width: Int)
    private data class CardKey(val task: TaskSummary, val labels: List<TaskLabel>, val width: Int, val day: Int)

    private companion object {
        const val MAX_CACHED_ROWS = 400
    }
}

/** A small synchronized LRU map; preparation may run on any worker of the default pool. */
internal class LruMap<K : Any, V : Any>(private val maxSize: Int) {
    private val map = object : LinkedHashMap<K, V>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean = size > maxSize
    }

    fun getOrPut(key: K, build: () -> V): V {
        synchronized(map) { map[key]?.let { return it } }
        val built = build()
        synchronized(map) { map[key] = built }
        return built
    }
}
