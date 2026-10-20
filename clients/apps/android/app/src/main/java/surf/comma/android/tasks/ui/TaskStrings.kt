package surf.comma.android.tasks.ui

import android.content.Context
import android.icu.text.DateFormat
import android.icu.text.DisplayContext
import java.util.Calendar
import java.util.Date
import java.util.Locale
import surf.comma.android.R
import surf.comma.android.tasks.TaskPanelCounts
import surf.comma.android.tasks.TaskSummary

/**
 * Copy the task surfaces format, resolved once so background preparation never reaches
 * back into a Context.
 */
class TaskStrings(context: Context, private val clock: () -> Long = System::currentTimeMillis) {
    private val resources = context.resources
    private val locale: Locale = resources.configuration.locales[0]
    private val updatedPattern = context.getString(R.string.task_updated_date)
    private val updatedRecently = context.getString(R.string.task_updated_recently)
    val untitled: String = context.getString(R.string.task_untitled)
    val hide: String = context.getString(R.string.task_action_hide)
    val archive: String = context.getString(R.string.task_action_archive)

    fun title(task: TaskSummary): String = task.title.ifBlank { untitled }

    /** "Updated Sep 28". Seconds and milliseconds are both accepted, as the server sends either. */
    fun updatedAt(timestamp: Long): String {
        if (timestamp <= 0L) return updatedRecently
        val millis = if (timestamp < SECONDS_CUTOFF) timestamp * 1000 else timestamp
        // ICU formatters are not thread-safe; one per call keeps background preparation safe.
        val format = DateFormat.getInstanceForSkeleton(DateFormat.ABBR_MONTH_DAY, locale).apply {
            setContext(DisplayContext.CAPITALIZATION_FOR_MIDDLE_OF_SENTENCE)
        }
        return String.format(locale, updatedPattern, format.format(Date(millis)))
    }

    /**
     * When the task last changed, as precisely as is useful at a glance: the time for today,
     * the day for this year, the full date before that. Null when the source sent no time;
     * nothing is made up in its place.
     */
    fun updated(timestamp: Long): String? {
        if (timestamp <= 0L) return null
        val millis = if (timestamp < SECONDS_CUTOFF) timestamp * 1000 else timestamp
        val now = Calendar.getInstance(locale).apply { timeInMillis = clock() }
        val then = Calendar.getInstance(locale).apply { timeInMillis = millis }
        val skeleton = when {
            then.get(Calendar.YEAR) != now.get(Calendar.YEAR) -> DateFormat.YEAR_ABBR_MONTH_DAY
            then.get(Calendar.DAY_OF_YEAR) != now.get(Calendar.DAY_OF_YEAR) -> DateFormat.ABBR_MONTH_DAY
            else -> TIME_OF_DAY
        }
        val format = DateFormat.getInstanceForSkeleton(skeleton, locale).apply {
            setContext(DisplayContext.CAPITALIZATION_FOR_MIDDLE_OF_SENTENCE)
        }
        return String.format(locale, updatedPattern, format.format(Date(millis)))
    }

    /** Today's date as a number, so prepared rows that show a time of day are rebuilt tomorrow. */
    fun day(): Int = Calendar.getInstance(locale).apply { timeInMillis = clock() }.let {
        it.get(Calendar.YEAR) * 1000 + it.get(Calendar.DAY_OF_YEAR)
    }

    /** "3 tasks · 1 running", or just "3 tasks" when nothing runs. */
    fun panelCounts(counts: TaskPanelCounts): String {
        val total = resources.getQuantityString(R.plurals.task_count, counts.total, counts.total)
        if (counts.running == 0) return total
        val running = resources.getQuantityString(R.plurals.task_running_count, counts.running, counts.running)
        return resources.getString(R.string.task_counts_joined, total, running)
    }

    private companion object {
        /** Hour and minute in the locale's own 12- or 24-hour style. */
        const val TIME_OF_DAY = "jm"

        /** Anything below this is a Unix time in seconds (it is year 2286 in milliseconds). */
        const val SECONDS_CUTOFF = 10_000_000_000L
    }
}
