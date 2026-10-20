package surf.comma.android.tasks

/**
 * A task that has stopped for good: it can be hidden from the conversation panel and swiped
 * to archive. Needs-review is not ended; it is waiting on the reader.
 */
val TaskStatusBucket.isEnded: Boolean
    get() = this == TaskStatusBucket.DONE ||
        this == TaskStatusBucket.CANCELLED ||
        this == TaskStatusBucket.ARCHIVED

/**
 * Whether a task may be swiped to archive. The server decides (it refuses while a task is
 * not finished); without its answer, an ended but not yet archived task qualifies.
 */
val TaskSummary.canArchive: Boolean
    get() = bucket != TaskStatusBucket.ARCHIVED && (archiveAllowed ?: bucket.isEnded)
