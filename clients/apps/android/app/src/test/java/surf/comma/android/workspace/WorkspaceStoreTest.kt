package surf.comma.android.workspace

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.tasks.data.ServerTaskRepository

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class WorkspaceStoreTest {
    @Test fun `a reader that runs at once gets the Task each request asks for`() {
        val auth = TestAuthRepository(MemorySessions())
        val tasks = ServerTaskRepository(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
        val store = WorkspaceStore(RuntimeEnvironment.getApplication(), auth, tasks, CommaApi(null))
        val asked = mutableListOf<String?>()
        // The shell reads the requests on the main thread's immediate dispatcher: a tap's request reaches it at once.
        val reader = CoroutineScope(Dispatchers.Unconfined).launch {
            var handled = store.openTask.value.reveal
            store.openTask.collect { open ->
                if (open.reveal == handled) return@collect
                handled = open.reveal
                asked += open.id
            }
        }
        try {
            store.openTask("a")
            store.openTask("b")
            assertEquals(listOf("a", "b"), asked)
            store.closeTask()
            assertNull("a reader that starts after the close finds no Task to show", store.openTask.value.id)
            store.openTask("c")
            store.openTask("c")
            assertEquals("a closed dock and the Task already open still show the Task asked for",
                listOf("a", "b", "c", "c"), asked)
        } finally {
            reader.cancel()
            tasks.close()
        }
    }
}
