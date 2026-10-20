package surf.comma.android.tasks

data class TaskGroup(
    val bucket: TaskStatusBucket,
    val tasks: List<TaskSummary>,
)

/**
 * A section of the full task list as the core orders it (the `taskOrder` topic's `sections`): the statuses in the
 * order every client shows them, each with its tasks' ids in board order.
 */
data class TaskSection(
    val bucket: TaskStatusBucket,
    val ids: List<String>,
)

/** Newest update first; the id breaks ties so equal timestamps never reshuffle. */
val TASK_RECENCY_ORDER: Comparator<TaskSummary> =
    compareByDescending<TaskSummary> { it.updatedAt }.thenBy { it.id }

/** The core's [sections] of the listed [tasks] after the label filter, the empty ones left out. */
fun orderedGroups(tasks: List<TaskSummary>, labelId: String?, sections: List<TaskSection>): List<TaskGroup> {
    val shown = filterByLabel(tasks, labelId).associateBy { it.id }
    return sections.mapNotNull { section ->
        section.ids.mapNotNull(shown::get).takeIf { it.isNotEmpty() }?.let { TaskGroup(section.bucket, it) }
    }
}

/** What the badge on the task entry counts: running tasks among those loaded. */
fun runningTaskCount(tasks: List<TaskSummary>): Int = tasks.count { it.bucket == TaskStatusBucket.IN_PROGRESS }

/** Null [labelId] means "all". */
fun filterByLabel(tasks: List<TaskSummary>, labelId: String?): List<TaskSummary> =
    if (labelId == null) tasks else tasks.filter { labelId in it.labelIds }

/**
 * Labels worth offering as filters: those carried by at least one listed (non-archived)
 * task, in catalog order. Ids missing from the catalog are skipped; there is no name to show.
 */
fun filterableLabels(tasks: List<TaskSummary>, catalog: List<TaskLabel>): List<TaskLabel> {
    val used = tasks.asSequence()
        .filter { it.bucket != TaskStatusBucket.ARCHIVED }
        .flatMap { it.labelIds }
        .toSet()
    return catalog.filter { it.id in used }
}

/** A selected filter that no longer matches any offered label falls back to "all". */
fun effectiveLabelFilter(selected: String?, offered: List<TaskLabel>): String? =
    selected?.takeIf { id -> offered.any { it.id == id } }

sealed interface TaskListRow {
    /** Stable across refreshes; the adapter maps it to a stable item id. */
    val key: String

    data class Header(val bucket: TaskStatusBucket, val count: Int) : TaskListRow {
        override val key: String get() = "header:${bucket.wireName}"
    }

    data class Card(val task: TaskSummary) : TaskListRow {
        override val key: String get() = "task:${task.id}"
    }
}

/** The full list after filtering: a header per group, followed by its cards. */
fun taskListRows(
    tasks: List<TaskSummary>,
    labelId: String?,
    sections: List<TaskSection>,
): List<TaskListRow> =
    orderedGroups(tasks, labelId, sections).flatMap { group ->
        buildList {
            add(TaskListRow.Header(group.bucket, group.tasks.size))
            group.tasks.forEach { add(TaskListRow.Card(it)) }
        }
    }

/**
 * Rows of the conversation's task panel. [tasks] arrive in creation order. Running tasks
 * move to the front; everything else keeps creation order. Hidden and archived tasks drop out.
 */
fun conversationPanelOrder(tasks: List<TaskSummary>, hiddenIds: Set<String>): List<TaskSummary> {
    val visible = tasks.filter { it.id !in hiddenIds && it.bucket != TaskStatusBucket.ARCHIVED }
    val (running, rest) = visible.partition { it.bucket == TaskStatusBucket.IN_PROGRESS }
    return running + rest
}

data class TaskPanelCounts(val total: Int, val running: Int) {
    val isEmpty: Boolean get() = total == 0
}

/** What the pill above the composer counts: exactly the rows the panel would show. */
fun conversationPanelCounts(tasks: List<TaskSummary>, hiddenIds: Set<String>): TaskPanelCounts {
    val rows = conversationPanelOrder(tasks, hiddenIds)
    return TaskPanelCounts(
        total = rows.size,
        running = rows.count { it.bucket == TaskStatusBucket.IN_PROGRESS },
    )
}

/**
 * The chat sidebar's rows: every listed task, most recently updated first. Archived tasks are
 * gone from every list, so they are not here either.
 */
fun sidebarTasks(tasks: List<TaskSummary>): List<TaskSummary> =
    tasks.filter { it.bucket != TaskStatusBucket.ARCHIVED }.sortedWith(TASK_RECENCY_ORDER)

/** The task the chat's top capsule shows: the sidebar's first row, or null when it is empty. */
fun latestTask(tasks: List<TaskSummary>): TaskSummary? =
    tasks.asSequence().filter { it.bucket != TaskStatusBucket.ARCHIVED }.minWithOrNull(TASK_RECENCY_ORDER)
