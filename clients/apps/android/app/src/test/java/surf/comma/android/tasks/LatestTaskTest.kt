package surf.comma.android.tasks

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LatestTaskTest {
    @Test fun `no tasks, no capsule task`() {
        assertNull(latestTask(emptyList()))
    }

    @Test fun `the most recently updated task wins whatever its status`() {
        val tasks = listOf(
            TaskSummary("running", "Running", TaskStatusBucket.IN_PROGRESS, updatedAt = 100),
            TaskSummary("done", "Done", TaskStatusBucket.DONE, updatedAt = 300),
            TaskSummary("review", "Review", TaskStatusBucket.NEEDS_REVIEW, updatedAt = 200),
        )
        assertEquals("done", latestTask(tasks)?.id)
    }

    @Test fun `archived tasks never show, even when newest`() {
        val tasks = listOf(
            TaskSummary("kept", "Kept", TaskStatusBucket.IN_PROGRESS, updatedAt = 100),
            TaskSummary("gone", "Gone", TaskStatusBucket.ARCHIVED, updatedAt = 900),
        )
        assertEquals("kept", latestTask(tasks)?.id)
        assertNull(latestTask(listOf(TaskSummary("gone", "Gone", TaskStatusBucket.ARCHIVED, updatedAt = 900))))
    }

    @Test fun `equal timestamps pick the same task every time`() {
        val a = TaskSummary("a", "A", TaskStatusBucket.IN_PROGRESS, updatedAt = 5)
        val b = TaskSummary("b", "B", TaskStatusBucket.IN_PROGRESS, updatedAt = 5)
        assertEquals("a", latestTask(listOf(a, b))?.id)
        assertEquals("a", latestTask(listOf(b, a))?.id)
    }

    @Test fun `unknown update times lose to known ones`() {
        val tasks = listOf(TaskSummary("unknown", "U", TaskStatusBucket.IN_PROGRESS), TaskSummary("known", "K", TaskStatusBucket.IN_PROGRESS, updatedAt = 1))
        assertEquals("known", latestTask(tasks)?.id)
    }

    @Test fun `the sidebar lists listed tasks newest first and the capsule shows its first row`() {
        val tasks = listOf(
            TaskSummary("old", "Old", TaskStatusBucket.DONE, updatedAt = 1),
            TaskSummary("archived", "Archived", TaskStatusBucket.ARCHIVED, updatedAt = 50),
            TaskSummary("new", "New", TaskStatusBucket.IN_PROGRESS, updatedAt = 9),
            TaskSummary("mid", "Mid", TaskStatusBucket.NEEDS_REVIEW, updatedAt = 5),
        )
        assertEquals(listOf("new", "mid", "old"), sidebarTasks(tasks).map { it.id })
        assertEquals(sidebarTasks(tasks).first(), latestTask(tasks))
    }
}
