package surf.comma.android.tasks

import kotlinx.coroutines.flow.Flow

/**
 * Read side of tasks. The surfaces only observe; mutations such as archiving are reported
 * to the host through callbacks and are not part of this interface yet.
 */
interface TaskRepository {
    /** Every task in the group plus the label catalog. */
    fun observeTasks(): Flow<TaskSnapshot>

    /** Tasks created from one conversation, in creation order. */
    fun observeConversationTasks(conversationId: String): Flow<List<TaskSummary>>

    /** One task; null when it is unknown or no longer visible. */
    fun observeTask(taskId: String): Flow<TaskSummary?>

    /** Re-reads from the source of truth. Returns when the new snapshot has been published. */
    suspend fun refresh()
}
