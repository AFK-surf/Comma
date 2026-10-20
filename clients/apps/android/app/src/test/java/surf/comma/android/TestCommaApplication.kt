package surf.comma.android

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Dispatchers
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.scroll.widget.AsyncDifferConfig
import surf.comma.android.ui.Background
import java.util.concurrent.Executors
import kotlin.coroutines.CoroutineContext

/**
 * The application every Robolectric test runs in (`robolectric.properties`). The work the app hands to background
 * threads finishes before the call that started it returns: file work in place, as in every unit test, and layout on
 * a worker the caller waits for, since layout refuses the main thread. So the main looper alone decides when a screen
 * changes: a test advances it and never waits in real time. The client core is a signed-out test core: Hermes does
 * not run here, and a real one would never answer.
 */
class TestCommaApplication : CommaApplication() {
    override fun onCreate() {
        AsyncDifferConfig.Builder.setDefaultBackgroundThreadExecutor { it.run() }
        Background.compute = OffMainInPlace
        AuthGraph.install(TestAuthRepository(MemorySessions(), io = Dispatchers.Unconfined),
            CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
        super.onCreate()
    }
}

/**
 * Runs each piece of work on one worker thread and waits for it: off the main thread, as the app requires of layout
 * work, yet done before the code that started it goes on.
 */
private object OffMainInPlace : CoroutineDispatcher() {
    @Volatile private var thread: Thread? = null
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "test-background").apply { isDaemon = true }.also { thread = it }
    }

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        // Work started from this work runs in place: waiting for it would wait for itself.
        if (Thread.currentThread() === thread) block.run() else worker.submit(block).get()
    }
}
