package surf.comma.android.tasks.list

import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary

/**
 * How a Task list is narrowed: AND across fields, OR within a field, and null for a field that does not
 * narrow. The rules follow the desktop Tasks route; status is a field here because the phone has no board
 * columns.
 */
data class TaskListFilter(
    val statuses: Set<TaskStatusBucket>? = null,
    val labels: Set<String>? = null,
    val origins: Set<String>? = null,
    val clientPlatforms: Set<String>? = null,
) {
    enum class Field { STATUS, LABEL, PLATFORM, CLIENT_PLATFORM }

    /** Whether [task] passes every narrowed field. Label ids the catalog no longer knows are ignored. */
    fun matches(task: TaskSummary, knownLabelIds: Set<String> = emptySet()): Boolean = Field.entries.all { field ->
        val selected = values(field) ?: return@all true
        keys(field, task, knownLabelIds).any(selected::contains)
    }

    /** The field's selected option ids, or null when it does not narrow. Status ids are wire names. */
    fun values(field: Field): Set<String>? = when (field) {
        Field.STATUS -> statuses?.map { it.wireName }?.toSet()
        Field.LABEL -> labels
        Field.PLATFORM -> origins
        Field.CLIENT_PLATFORM -> clientPlatforms
    }

    /** This filter with [field] narrowed to [values]. Selecting every option in [all] stops narrowing. */
    fun setting(field: Field, values: Set<String>, all: Set<String>): TaskListFilter {
        val narrowed = if (values.containsAll(all)) null else values
        return when (field) {
            Field.STATUS -> copy(statuses = narrowed?.mapNotNull { id -> TaskStatusBucket.entries.firstOrNull { it.wireName == id } }?.toSet())
            Field.LABEL -> copy(labels = narrowed)
            Field.PLATFORM -> copy(origins = narrowed)
            Field.CLIENT_PLATFORM -> copy(clientPlatforms = narrowed)
        }
    }

    fun clearing(field: Field) = setting(field, emptySet(), emptySet())

    /** The fields that narrow, in display order. */
    val narrowedFields: List<Field> get() = Field.entries.filter { values(it) != null }

    /**
     * The option ids [field] offers, in menu order: every status; the catalog's labels, then No label; the
     * platforms and devices the loaded Tasks use, plus any still selected. An empty list hides the field.
     */
    fun options(field: Field, tasks: List<TaskSummary>, labelIds: List<String>): List<String> {
        val selected = values(field).orEmpty()
        return when (field) {
            Field.STATUS -> STATUS_BUCKETS.map { it.wireName }
            Field.LABEL -> if (labelIds.isEmpty()) emptyList() else labelIds + NO_LABEL
            Field.PLATFORM -> {
                val used = selected + tasks.map { originKey(it.origin) }
                val offered = (ORIGIN_KEYS + UNSPECIFIED).filter(used::contains)
                if (offered == listOf(UNSPECIFIED) && selected.isEmpty()) emptyList() else offered
            }
            Field.CLIENT_PLATFORM -> {
                val used = selected + tasks.mapNotNull { clientPlatformKey(it.clientPlatform) }
                (CLIENT_PLATFORM_KEYS + UNKNOWN_CLIENT_PLATFORM).filter(used::contains)
            }
        }
    }

    companion object {
        /** Every status in display order, the desktop board's column order. */
        val STATUS_BUCKETS = listOf(
            TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.NEEDS_REVIEW,
            TaskStatusBucket.DONE, TaskStatusBucket.CANCELLED,
        )
        const val NO_LABEL = "comma:no-label"
        const val UNSPECIFIED = "comma:unspecified"
        val ORIGIN_KEYS = listOf("slack", "telegram", "feishu", "wechat", "signal", "comma")
        val CLIENT_PLATFORM_KEYS = listOf("macos", "windows", "linux", "ios", "android", "web", "watchos")
        const val UNKNOWN_CLIENT_PLATFORM = "unknown"

        fun originKey(origin: String?): String = origin?.takeIf { it in ORIGIN_KEYS } ?: UNSPECIFIED

        fun clientPlatformKey(platform: String?): String? {
            if (platform.isNullOrEmpty()) return null
            return if (platform in CLIENT_PLATFORM_KEYS) platform else UNKNOWN_CLIENT_PLATFORM
        }

        /** How many of [tasks] each of the field's options holds, regardless of the current narrowing. */
        fun counts(field: Field, tasks: List<TaskSummary>, knownLabelIds: Set<String>): Map<String, Int> {
            val counts = mutableMapOf<String, Int>()
            for (task in tasks) for (key in keys(field, task, knownLabelIds)) counts[key] = (counts[key] ?: 0) + 1
            return counts
        }

        private fun keys(field: Field, task: TaskSummary, knownLabelIds: Set<String>): Set<String> = when (field) {
            Field.STATUS -> setOf(task.bucket.wireName)
            Field.LABEL -> task.labelIds.toSet().intersect(knownLabelIds).ifEmpty { setOf(NO_LABEL) }
            Field.PLATFORM -> setOf(originKey(task.origin))
            Field.CLIENT_PLATFORM -> setOfNotNull(clientPlatformKey(task.clientPlatform))
        }
    }
}
