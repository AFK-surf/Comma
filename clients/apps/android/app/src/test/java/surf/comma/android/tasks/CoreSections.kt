package surf.comma.android.tasks

/**
 * What the core's `taskOrder` topic says of [tasks] when no card was placed by hand: the shown statuses in their order,
 * each bucket's tasks in list order, which the server gives most recently updated first.
 */
internal fun coreSections(tasks: List<TaskSummary>): List<TaskSection> =
    listOf(TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.NEEDS_REVIEW, TaskStatusBucket.DONE,
        TaskStatusBucket.CANCELLED).map { bucket ->
        TaskSection(bucket, tasks.filter { it.bucket == bucket }.sortedWith(TASK_RECENCY_ORDER).map { it.id })
    }
