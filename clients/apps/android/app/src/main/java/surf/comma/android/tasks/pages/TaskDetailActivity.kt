package surf.comma.android.tasks.pages

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.tasks.data.TaskGraph

/** One task as a full page; the body is a [TaskDetailPane]. */
class TaskDetailActivity : ComponentActivity() {
    private var pane: TaskDetailPane? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val auth = AuthGraph.get(this)
        val guard = TaskPageGuard(auth.conversationScope.value)
        val id = intent.getStringExtra(TaskPages.EXTRA_TASK_ID)
        if (id.isNullOrBlank() || guard.shouldClose(auth.conversationScope.value)) {
            finish()
            return
        }
        val pane = TaskDetailPane(this, id, TaskGraph.get(this, auth), auth.conversationScope).also { pane = it }
        pane.view.onBack = ::finish
        pane.onOpenTask = { other -> TaskPages.openDetail(this, other) }
        setContentView(pane.view)

        lifecycleScope.launch { auth.conversationScope.collect { if (guard.shouldClose(it)) finish() } }
        lifecycleScope.launch { repeatOnLifecycle(Lifecycle.State.STARTED) { pane.run() } }
    }

    override fun onDestroy() {
        pane?.release()
        super.onDestroy()
    }
}
