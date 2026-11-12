package surf.comma.android.ui

import android.os.Handler
import android.os.HandlerThread
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * Where the app does its work off the main thread: laying out rows ([compute]) and reading files and the network
 * ([files]). The unit tests' JVM starts with `comma.background=inline` (set by Gradle): the work runs where it is
 * started, so a test decides the order of everything. The Robolectric test application sets its own.
 */
object Background {
    private val inline = System.getProperty("comma.background") == "inline"
    @Volatile var compute: CoroutineDispatcher = if (inline) Dispatchers.Unconfined else Dispatchers.Default
        internal set
    @Volatile var files: CoroutineDispatcher = if (inline) Dispatchers.Unconfined else Dispatchers.IO
        internal set

    /**
     * A thread of its own named [name] for work that goes in order (a screen view's pictures), with its [Handler] for
     * what reports there (MediaCodec); in the unit tests the work runs where it is posted, and there is no handler.
     */
    fun serial(name: String): Serial {
        if (inline) return Serial(post = { it() }, quit = {}, handler = null)
        val thread = HandlerThread(name).apply { start() }
        val handler = Handler(thread.looper)
        return Serial(post = { work -> handler.post(work) }, quit = { thread.quitSafely() }, handler = handler)
    }

    class Serial(val post: (() -> Unit) -> Unit, val quit: () -> Unit, val handler: Handler?)
}
