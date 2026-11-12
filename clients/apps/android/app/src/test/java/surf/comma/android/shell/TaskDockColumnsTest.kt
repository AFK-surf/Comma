package surf.comma.android.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Where the Task's browser goes: beside the conversation on a wide window held sideways, else in a sheet. */
class TaskDockColumnsTest {
    @Test
    fun aWideLandscapeWindowSplitsAndAnUprightOrNarrowOneDoesNot() {
        // An unfolded foldable held sideways: the conversation keeps half, the browser takes the rest.
        assertEquals(1100, TaskDock.conversationColumn(width = 2200, height = 1800, minColumn = 700))
        // The same screen upright, or a phone held sideways with no room for two columns, opens a sheet.
        assertNull(TaskDock.conversationColumn(width = 1800, height = 2200, minColumn = 700))
        assertNull(TaskDock.conversationColumn(width = 1300, height = 700, minColumn = 700))
    }
}
