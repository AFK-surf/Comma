package surf.comma.android.tasks.demo

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import surf.comma.android.tasks.TaskLabel
import surf.comma.android.tasks.TaskRepository
import surf.comma.android.tasks.TaskSnapshot
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary

/**
 * Deterministic test data for the task surfaces. Debug builds only; release has no fixture.
 * Statuses use the raw values the server sends (`active`, `completed`, `failed`, ...), so the
 * folding into buckets is exercised exactly as it will be against real data.
 */
class FixtureTaskRepository(private val now: Long = System.currentTimeMillis()) : TaskRepository {
    private val state = MutableStateFlow(TaskSnapshot(seedTasks(), LABELS))
    private var refreshCount = 0

    /** The latest snapshot, for demo code that needs it synchronously. */
    val current: TaskSnapshot get() = state.value

    override fun observeTasks(): Flow<TaskSnapshot> = state

    override fun observeConversationTasks(conversationId: String): Flow<List<TaskSummary>> =
        state.map { snapshot ->
            val ids = CONVERSATIONS[conversationId].orEmpty()
            ids.mapNotNull { id -> snapshot.tasks.firstOrNull { it.id == id } }
        }.distinctUntilChanged()

    override fun observeTask(taskId: String): Flow<TaskSummary?> =
        state.map { snapshot -> snapshot.tasks.firstOrNull { it.id == taskId } }.distinctUntilChanged()

    /** Simulates a round trip; each refresh moves the running tasks along a little. */
    override suspend fun refresh() {
        delay(REFRESH_DELAY_MS)
        refreshCount++
        val stamp = System.currentTimeMillis()
        state.update { snapshot ->
            snapshot.copy(
                tasks = snapshot.tasks.map { task ->
                    when {
                        task.id == "task-03" && refreshCount == 1 ->
                            task.copy(bucket = TaskStatusBucket.DONE, progress = null, updatedAt = stamp, archiveAllowed = true)
                        task.bucket == TaskStatusBucket.IN_PROGRESS -> task.copy(
                            progress = PROGRESS_LINES[(refreshCount + task.id.hashCode()).mod(PROGRESS_LINES.size)],
                            updatedAt = stamp,
                        )
                        else -> task
                    }
                },
            )
        }
    }

    /** Demo stand-in for the archive call the list reports through its callback. */
    fun archiveLocally(taskId: String) {
        state.update { snapshot ->
            snapshot.copy(
                tasks = snapshot.tasks.map {
                    if (it.id == taskId) it.copy(bucket = TaskStatusBucket.ARCHIVED, archiveAllowed = false) else it
                },
            )
        }
    }

    private fun seedTasks(): List<TaskSummary> = SEEDS.mapIndexed { index, seed ->
        val id = "task-%02d".format(index + 1)
        TaskSummary(
            id = id,
            title = seed.title,
            bucket = seed.bucket,
            failed = seed.failed,
            progress = seed.progress,
            labelIds = seed.labels,
            updatedAt = now - seed.minutesAgo * MINUTE,
            createdAt = now - (seed.minutesAgo + 30) * MINUTE,
            archiveAllowed = seed.bucket == TaskStatusBucket.DONE || seed.failed,
        )
    }

    private class Seed(
        val title: String,
        val bucket: TaskStatusBucket,
        val minutesAgo: Long,
        val labels: List<String> = emptyList(),
        val progress: String? = null,
        val failed: Boolean = false,
    )

    companion object {
        const val DEMO_CONVERSATION = "demo-conversation"
        private const val MINUTE = 60_000L
        private const val DAY = 24 * 60L
        private const val REFRESH_DELAY_MS = 900L

        private val LABELS = listOf(
            TaskLabel("label-client", "客户端", "blue"),
            TaskLabel("label-bug", "缺陷", "error"),
            TaskLabel("label-docs", "文档", "success"),
            TaskLabel("label-design", "设计", "purple"),
            TaskLabel("label-research", "调研", "#EF6820"),
            TaskLabel("label-unused", "未使用", "gray"),
        )

        private val PROGRESS_LINES = listOf(
            "正在运行单元测试",
            "正在阅读相关代码",
            "正在编译并检查告警",
            "正在整理修改说明",
        )

        private val SEEDS = listOf(
            Seed("修复登录页键盘弹出时按钮被遮挡", TaskStatusBucket.IN_PROGRESS, 2, listOf("label-client", "label-bug"), "正在编译并检查告警"),
            Seed("整理本周发布说明", TaskStatusBucket.IN_PROGRESS, 8, listOf("label-docs")),
            Seed("给会话列表加上下拉刷新", TaskStatusBucket.IN_PROGRESS, 15, listOf("label-client"), "正在运行单元测试"),
            Seed("核对深色模式下的对比度，列出所有低于 4.5:1 的文字", TaskStatusBucket.NEEDS_REVIEW, 40, listOf("label-design", "label-client")),
            Seed("调研图片上传的分片方案", TaskStatusBucket.NEEDS_REVIEW, 3 * 60, listOf("label-research")),
            Seed("统一设置页的间距", TaskStatusBucket.IN_PROGRESS, 5 * 60, listOf("label-design")),
            Seed("清理没用到的资源文件", TaskStatusBucket.IN_PROGRESS, DAY, listOf("label-client")),
            Seed("为长会话写滚动基线测试", TaskStatusBucket.IN_PROGRESS, 2 * DAY, listOf("label-client", "label-research")),
            Seed("更新隐私说明里的数据保留期限", TaskStatusBucket.DONE, 50, listOf("label-docs")),
            Seed("修复通知点开后跳错会话", TaskStatusBucket.DONE, 3 * 60, listOf("label-client", "label-bug")),
            Seed("把错误提示改成完整句子", TaskStatusBucket.DONE, DAY, listOf("label-docs")),
            Seed("压缩启动图", TaskStatusBucket.DONE, 2 * DAY, listOf("label-design")),
            Seed("迁移旧版缓存目录", TaskStatusBucket.CANCELLED, 90, listOf("label-bug"), failed = true),
            Seed("导出上个月的崩溃统计", TaskStatusBucket.CANCELLED, 3 * DAY, listOf("label-research")),
            Seed("去掉废弃的实验开关", TaskStatusBucket.ARCHIVED, 5 * DAY, listOf("label-client")),
        ) + (1..24).map { n ->
            // Bulk rows so the list is long enough to fling.
            val bucket = listOf(TaskStatusBucket.DONE, TaskStatusBucket.DONE, TaskStatusBucket.IN_PROGRESS,
                TaskStatusBucket.IN_PROGRESS, TaskStatusBucket.CANCELLED, TaskStatusBucket.NEEDS_REVIEW)[n % 6]
            val labels = listOf(listOf("label-client"), listOf("label-docs", "label-design"), emptyList())[n % 3]
            Seed("批量任务 $n：检查第 $n 组页面的文案与排版", bucket, (n * 97L) % (6 * DAY) + 5, labels,
                failed = bucket == TaskStatusBucket.CANCELLED)
        }

        /** Creation order of the tasks each demo conversation spawned. */
        private val CONVERSATIONS = mapOf(
            DEMO_CONVERSATION to listOf("task-09", "task-01", "task-06", "task-13", "task-03", "task-04", "task-10"),
        )
    }
}
