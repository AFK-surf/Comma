package surf.comma.android.shell

import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.children
import androidx.core.view.descendants
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import surf.comma.android.R
import surf.comma.android.auth.MemorySessions
import surf.comma.android.auth.TestAuthRepository
import surf.comma.android.conversation.AuthConversationSessions
import surf.comma.android.tasks.data.ServerTaskRepository
import surf.comma.android.tasks.list.TaskActions
import surf.comma.android.workspace.CommaApi
import surf.comma.android.workspace.WorkspaceStore

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-xxhdpi")
class SearchLayerTest {
    @Test fun `the prompt centres between the status bar and the field, above the keyboard`() {
        Robolectric.buildActivity(ComponentActivity::class.java).use { controller ->
            val activity = controller.get()
            activity.setTheme(R.style.Theme_Chat)
            controller.setup()
            val auth = TestAuthRepository(MemorySessions())
            val tasks = ServerTaskRepository(AuthConversationSessions(auth), null, io = Dispatchers.Unconfined)
            val store = WorkspaceStore(activity, auth, tasks, CommaApi(null))
            val shell = object : Shell {
                override val activity = activity
                override val store = store
                override val actions = TaskActions(activity, store)
                override fun openRouter(focus: Boolean) = Unit
                override fun insertIntoRouter(text: String) = Unit
                override fun openSearch() = Unit
                override fun notificationsOff(): (() -> Unit)? = null
            }
            try {
                val layer = SearchLayer(shell) {}
                val hint = layer.children.filterIsInstance<TextView>().single { it.text == activity.getString(R.string.search_hint) }
                val bar = layer.children.single { it is ViewGroup && it.descendants.any { view -> view is EditText } }
                val density = activity.resources.displayMetrics.density
                fun dp(value: Int) = (value * density).toInt()
                val width = dp(411)
                val height = dp(891)
                val statusBar = dp(24)
                // The keyboard up, then down again: the prompt follows the field both ways.
                for (keyboard in listOf(dp(300), 0)) {
                    ViewCompat.dispatchApplyWindowInsets(layer, WindowInsetsCompat.Builder()
                        .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, statusBar, 0, 0))
                        .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, dp(24)))
                        .setInsets(WindowInsetsCompat.Type.ime(), Insets.of(0, 0, 0, keyboard))
                        .build())
                    layer.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                        View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
                    layer.layout(0, 0, width, height)
                    assertEquals("the field sits on the keyboard or the navigation area", height - maxOf(keyboard, dp(24)), bar.bottom)
                    // Where the text is drawn, wherever its view's bounds are.
                    val text = hint.top + hint.totalPaddingTop + hint.layout.height / 2f
                    assertEquals("the prompt is centred in the room between the status bar and the field",
                        (statusBar + bar.top) / 2f, text, 2f)
                }
            } finally {
                tasks.close()
            }
        }
    }
}
