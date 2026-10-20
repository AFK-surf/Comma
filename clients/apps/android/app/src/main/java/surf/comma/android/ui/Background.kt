package surf.comma.android.ui

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
}
