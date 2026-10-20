package surf.comma.android.tasks.data

import surf.comma.android.tasks.TaskGroup
import surf.comma.android.tasks.orderedGroups

/** The listed tasks in the core's sections. */
fun TaskDataState.orderedGroups(labelId: String? = null): List<TaskGroup> =
    orderedGroups(snapshot.tasks, labelId, sections)
