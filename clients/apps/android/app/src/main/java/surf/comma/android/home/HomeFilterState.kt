package surf.comma.android.home

import android.os.Bundle
import androidx.savedstate.SavedStateRegistry
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.list.TaskListFilter

/**
 * Activity saved state, scoped to the workspace whose tasks the person filtered. Construct it once per Activity:
 * [SavedStateRegistry.registerSavedStateProvider] throws for a key that is already registered. AppShell builds one
 * HomePage per Activity.
 */
internal class HomeFilterState(registry: SavedStateRegistry) {
    private val restored = registry.consumeRestoredStateForKey(KEY)
    var workspaceId: String? = restored?.getString("workspace")
        private set
    var filter: TaskListFilter = restored?.let { state ->
        TaskListFilter(
            statuses = state.getStringArrayList("statuses")?.mapNotNull { name -> TaskStatusBucket.entries.firstOrNull { it.name == name } }?.toSet(),
            labels = state.getStringArrayList("labels")?.toSet(),
            origins = state.getStringArrayList("origins")?.toSet(),
            clientPlatforms = state.getStringArrayList("clients")?.toSet(),
        )
    } ?: initial()

    init {
        registry.registerSavedStateProvider(KEY) {
            Bundle().apply {
                putString("workspace", workspaceId)
                filter.statuses?.let { putStringArrayList("statuses", ArrayList(it.map { status -> status.name })) }
                filter.labels?.let { putStringArrayList("labels", ArrayList(it)) }
                filter.origins?.let { putStringArrayList("origins", ArrayList(it)) }
                filter.clientPlatforms?.let { putStringArrayList("clients", ArrayList(it)) }
            }
        }
    }

    fun selectWorkspace(id: String?) {
        if (workspaceId == id) return
        workspaceId = id
        filter = initial()
    }

    private fun initial() = TaskListFilter(statuses = setOf(TaskStatusBucket.NEEDS_REVIEW))
    private companion object { const val KEY = "home.filter" }
}
