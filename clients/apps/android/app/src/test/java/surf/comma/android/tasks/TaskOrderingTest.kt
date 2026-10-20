package surf.comma.android.tasks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskStatusBucketTest {
    @Test
    fun archiveFollowsTheServerAndFallsBackToEnded() {
        val base = TaskSummary(id = "t", title = "t", bucket = TaskStatusBucket.DONE)
        assertTrue(base.canArchive)
        assertFalse(base.copy(archiveAllowed = false).canArchive)
        assertFalse(base.copy(bucket = TaskStatusBucket.IN_PROGRESS).canArchive)
        assertTrue(base.copy(bucket = TaskStatusBucket.IN_PROGRESS, archiveAllowed = true).canArchive)
        assertFalse(base.copy(bucket = TaskStatusBucket.ARCHIVED, archiveAllowed = true).canArchive)
        assertFalse(base.copy(bucket = TaskStatusBucket.NEEDS_REVIEW).canArchive)
    }

    @Test
    fun endedMeansDoneCancelledOrArchived() {
        val ended = TaskStatusBucket.entries.filter { it.isEnded }.toSet()
        assertEquals(
            setOf(TaskStatusBucket.DONE, TaskStatusBucket.CANCELLED, TaskStatusBucket.ARCHIVED),
            ended,
        )
    }

    @Test
    fun unknownOrMissingBucketsReadAsInProgress() {
        assertEquals(TaskStatusBucket.NEEDS_REVIEW, TaskStatusBucket.of("needs_review"))
        // Every new task starts in progress; a name the core no longer sends, such as "backlog", is not a state of its own.
        listOf("backlog", "something_new", "", null).forEach { assertEquals(TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.of(it)) }
    }
}

class TaskGroupingTest {
    @Test
    fun groupsInTheCoresSectionsAndSkipsEmptyOnes() {
        val tasks = listOf(
            task("a", TaskStatusBucket.DONE),
            task("b", TaskStatusBucket.IN_PROGRESS),
            task("c", TaskStatusBucket.ARCHIVED),
            task("d", TaskStatusBucket.CANCELLED, failed = true),
        )
        val sections = listOf(
            TaskSection(TaskStatusBucket.IN_PROGRESS, listOf("b")),
            TaskSection(TaskStatusBucket.NEEDS_REVIEW, emptyList()),
            TaskSection(TaskStatusBucket.DONE, listOf("a")),
            TaskSection(TaskStatusBucket.CANCELLED, listOf("d")),
        )
        val groups = orderedGroups(tasks, null, sections)
        assertEquals(
            listOf(TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.DONE, TaskStatusBucket.CANCELLED),
            groups.map { it.bucket },
        )
        assertTrue(groups.none { group -> group.tasks.any { it.id == "c" } })
    }

    @Test
    fun keepsTheCoresCardOrderAndLeavesOutIdsTheListDoesNotHave() {
        val tasks = listOf(task("a", TaskStatusBucket.IN_PROGRESS), task("b", TaskStatusBucket.IN_PROGRESS),
            task("c", TaskStatusBucket.IN_PROGRESS))
        val sections = listOf(TaskSection(TaskStatusBucket.IN_PROGRESS, listOf("c", "gone", "a", "b")))
        assertEquals(listOf("c", "a", "b"), orderedGroups(tasks, null, sections).single().tasks.map { it.id })
    }

    @Test
    fun rowsPutAHeaderWithCountBeforeEachGroup() {
        val tasks = listOf(
            task("a", TaskStatusBucket.DONE, updatedAt = 1),
            task("b", TaskStatusBucket.IN_PROGRESS, updatedAt = 1),
            task("c", TaskStatusBucket.DONE, updatedAt = 2),
        )
        val rows = taskListRows(tasks, labelId = null, coreSections(tasks))
        assertEquals(
            listOf("header:in_progress", "task:b", "header:done", "task:c", "task:a"),
            rows.map { it.key },
        )
        assertEquals(2, (rows[2] as TaskListRow.Header).count)
    }

    @Test
    fun rowKeysAreUniqueAcrossHeadersAndCards() {
        val tasks = (0 until 30).map { task("t$it", listOf(TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.DONE, TaskStatusBucket.CANCELLED)[it % 3]) }
        val keys = taskListRows(tasks, null, coreSections(tasks)).map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }
}

class TaskLabelFilterTest {
    private val catalog = listOf(
        TaskLabel("l1", "Design", "blue"),
        TaskLabel("l2", "Bug", "error"),
        TaskLabel("l3", "Unused", "gray"),
        TaskLabel("l4", "Archived only", "gray"),
    )
    private val tasks = listOf(
        task("a", TaskStatusBucket.IN_PROGRESS, labels = listOf("l2")),
        task("b", TaskStatusBucket.DONE, labels = listOf("l1", "l2")),
        task("c", TaskStatusBucket.NEEDS_REVIEW),
        task("d", TaskStatusBucket.ARCHIVED, labels = listOf("l4")),
        task("e", TaskStatusBucket.IN_PROGRESS, labels = listOf("missing")),
    )

    @Test
    fun nullFilterKeepsEverything() {
        assertEquals(tasks, filterByLabel(tasks, null))
    }

    @Test
    fun filterKeepsTasksCarryingTheLabel() {
        assertEquals(listOf("a", "b"), filterByLabel(tasks, "l2").map { it.id })
        assertEquals(listOf("b"), filterByLabel(tasks, "l1").map { it.id })
        assertTrue(filterByLabel(tasks, "l3").isEmpty())
    }

    @Test
    fun offersOnlyUsedCatalogLabelsInCatalogOrder() {
        assertEquals(listOf("l1", "l2"), filterableLabels(tasks, catalog).map { it.id })
    }

    @Test
    fun staleSelectionFallsBackToAll() {
        val offered = filterableLabels(tasks, catalog)
        assertEquals("l1", effectiveLabelFilter("l1", offered))
        assertNull(effectiveLabelFilter("l3", offered))
        assertNull(effectiveLabelFilter(null, offered))
    }

    @Test
    fun rowsApplyTheFilterBeforeGrouping() {
        val rows = taskListRows(tasks, "l1", coreSections(tasks))
        assertEquals(listOf("header:done", "task:b"), rows.map { it.key })
    }
}

class ConversationPanelTest {
    private val created = listOf(
        task("first", TaskStatusBucket.DONE),
        task("second", TaskStatusBucket.IN_PROGRESS),
        task("third", TaskStatusBucket.NEEDS_REVIEW),
        task("fourth", TaskStatusBucket.IN_PROGRESS),
        task("fifth", TaskStatusBucket.ARCHIVED),
        task("sixth", TaskStatusBucket.CANCELLED, failed = true),
    )

    @Test
    fun runningTasksComeFirstAndOthersKeepCreationOrder() {
        assertEquals(
            listOf("second", "fourth", "first", "third", "sixth"),
            conversationPanelOrder(created, emptySet()).map { it.id },
        )
    }

    @Test
    fun hiddenTasksDropOut() {
        assertEquals(
            listOf("second", "fourth", "third"),
            conversationPanelOrder(created, setOf("first", "sixth")).map { it.id },
        )
    }

    @Test
    fun countsMatchTheVisibleRows() {
        assertEquals(TaskPanelCounts(total = 5, running = 2), conversationPanelCounts(created, emptySet()))
        assertEquals(
            TaskPanelCounts(total = 3, running = 1),
            conversationPanelCounts(created, setOf("first", "second")),
        )
    }

    @Test
    fun emptyWhenEverythingIsHiddenOrArchived() {
        val counts = conversationPanelCounts(created, created.map { it.id }.toSet())
        assertTrue(counts.isEmpty)
        assertFalse(conversationPanelCounts(created, emptySet()).isEmpty)
        assertEquals(TaskPanelCounts(0, 0), conversationPanelCounts(emptyList(), emptySet()))
    }

    @Test
    fun statusChangeReordersWithoutLosingCreationOrder() {
        val later = created.map { if (it.id == "second") it.copy(bucket = TaskStatusBucket.DONE) else it }
        assertEquals(
            listOf("fourth", "first", "second", "third", "sixth"),
            conversationPanelOrder(later, emptySet()).map { it.id },
        )
    }
}

private fun task(
    id: String,
    bucket: TaskStatusBucket,
    updatedAt: Long = 0,
    labels: List<String> = emptyList(),
    failed: Boolean = false,
) = TaskSummary(id = id, title = id, bucket = bucket, labelIds = labels, updatedAt = updatedAt, failed = failed)
