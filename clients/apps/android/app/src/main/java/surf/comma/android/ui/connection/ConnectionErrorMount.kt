package surf.comma.android.ui.connection

import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthState
import surf.comma.android.conversation.ChatView

/** Keeps the chat's layout and bindings independent of the empty-chat recovery page. */
internal fun mountConnectionError(
    activity: ComponentActivity,
    root: FrameLayout,
    repository: ChatView,
    session: StateFlow<AuthState>,
    retrySession: suspend () -> Unit,
    onOpenAccount: () -> Unit,
    owner: androidx.lifecycle.LifecycleOwner = activity,
) {
    val page = ConnectionErrorView(activity).apply { visibility = View.GONE }
    val content = (0 until root.childCount).map(root::getChildAt)
    val hidden = mutableMapOf<View, Pair<Int, Int>>()
    lateinit var controller: ConnectionErrorController
    controller = ConnectionErrorController(onChanged = { state ->
        if (state != null) {
            if (page.visibility != View.VISIBLE) {
                root.findFocus()?.clearFocus()
                ViewCompat.getWindowInsetsController(root)?.hide(WindowInsetsCompat.Type.ime())
            }
            content.forEach { view ->
                hidden.putIfAbsent(view, view.visibility to view.importantForAccessibility)
                view.visibility = View.INVISIBLE
                view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            }
            page.visibility = View.VISIBLE
            page.render(state)
        } else {
            page.visibility = View.GONE
            hidden.forEach { (view, saved) ->
                view.visibility = saved.first
                view.importantForAccessibility = saved.second
            }
            hidden.clear()
        }
    }, onRetry = { target ->
        when (target) {
            ConnectionRetryTarget.SESSION -> owner.lifecycleScope.launch {
                try { retrySession() } finally {
                    controller.present(session.value, repository.state.value)
                    controller.sessionRetryFinished()
                }
            }
            ConnectionRetryTarget.CONVERSATION -> repository.reconnect()
        }
    })
    page.onRetry = controller::retry
    page.onSwitchAccount = onOpenAccount
    root.addView(page, FrameLayout.LayoutParams(-1, -1))
    owner.lifecycleScope.launch {
        owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            launch {
                combine(session, repository.state) { auth, chat -> auth to chat }.collect { (auth, chat) ->
                    controller.present(auth, chat)
                }
            }
            launch { connectionAvailability(activity).collect(controller::connectivityChanged) }
        }
    }
}
