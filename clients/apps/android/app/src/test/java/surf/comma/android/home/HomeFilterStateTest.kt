package surf.comma.android.home

import android.os.Bundle
import androidx.activity.ComponentActivity
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.list.TaskListFilter

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HomeFilterStateTest {
    @Test fun `activity saved state restores all filters without resetting the same workspace`() {
        val expected = TaskListFilter(setOf(TaskStatusBucket.IN_PROGRESS), setOf("label"), setOf("slack"), setOf("android"))
        val saved = Bundle()
        Robolectric.buildActivity(ComponentActivity::class.java).setup().use { activity ->
            val state = HomeFilterState(activity.get().savedStateRegistry)
            state.selectWorkspace("workspace")
            state.filter = expected
            activity.pause().stop().saveInstanceState(saved)
        }
        Robolectric.buildActivity(ComponentActivity::class.java).create(saved).use { activity ->
            val restored = HomeFilterState(activity.get().savedStateRegistry)
            restored.selectWorkspace("workspace")
            assertEquals(expected, restored.filter)
            restored.selectWorkspace("another")
            assertEquals(setOf(TaskStatusBucket.NEEDS_REVIEW), restored.filter.statuses)
            assertNull(restored.filter.labels)
        }
    }

    @Test fun `all statuses and an empty selection stay distinct after recreation`() {
        for (statuses in listOf(null, emptySet<TaskStatusBucket>())) {
            val saved = Bundle()
            Robolectric.buildActivity(ComponentActivity::class.java).setup().use { activity ->
                HomeFilterState(activity.get().savedStateRegistry).filter = TaskListFilter(statuses = statuses)
                activity.pause().stop().saveInstanceState(saved)
            }
            Robolectric.buildActivity(ComponentActivity::class.java).create(saved).use { activity ->
                assertEquals(statuses, HomeFilterState(activity.get().savedStateRegistry).filter.statuses)
            }
        }
    }
}
