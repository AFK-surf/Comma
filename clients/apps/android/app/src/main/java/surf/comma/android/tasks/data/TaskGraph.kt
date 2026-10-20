package surf.comma.android.tasks.data

import android.content.Context
import androidx.annotation.MainThread
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.conversation.AuthConversationSessions

/** The production entry point in every variant. Debug demos explicitly keep their fixture owner. */
object TaskGraph {
    private var instance: ServerTaskRepository? = null

    /** Call on the main thread. All consumers share this process-owned repository and Group stream. */
    @MainThread
    fun get(context: Context, auth: AuthRepository): ServerTaskRepository {
        instance?.let { return it }
        val app = context.applicationContext
        val repository = ServerTaskRepository(AuthConversationSessions(auth), AuthGraph.core(app))
        instance = repository
        repository.start()
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = repository.setForeground(true)
            override fun onStop(owner: LifecycleOwner) = repository.setForeground(false)
        })
        repository.setForeground(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        return repository
    }
}
