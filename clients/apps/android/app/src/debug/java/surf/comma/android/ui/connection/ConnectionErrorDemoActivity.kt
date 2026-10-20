package surf.comma.android.ui.connection

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/** Debug-only visual fixture. Extras: reason (enum name) and busy (boolean). No account or requests. */
class ConnectionErrorDemoActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val reason = ConnectionErrorReason.entries.firstOrNull { it.name == intent.getStringExtra("reason") }
            ?: ConnectionErrorReason.UNREACHABLE
        var state = ConnectionErrorState(reason, ConnectionRetryTarget.SESSION, intent.getBooleanExtra("busy", false))
        val page = ConnectionErrorView(this)
        page.onRetry = { state = state.copy(busy = true); page.render(state) }
        page.onSwitchAccount = { finish() }
        page.render(state)
        ViewCompat.setOnApplyWindowInsetsListener(page) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(page)
    }
}
