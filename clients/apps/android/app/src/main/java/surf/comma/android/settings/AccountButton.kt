package surf.comma.android.settings

import android.content.Context
import android.view.Gravity
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.findViewTreeLifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState

/** The signed-in person's avatar (or first letter) in the chat's top bar; it opens the settings. */
class AccountButton(context: Context, avatarDp: Int = 30) : FrameLayout(context) {
    private val avatar = AvatarView(context)
    private var watching: Job? = null

    /** The name the avatar stands for, each time it changes; e.g. for a label beside it. */
    var onName: ((String) -> Unit)? = null

    init {
        id = R.id.chat_settings
        contentDescription = context.getString(R.string.settings_open)
        isClickable = true
        isFocusable = true
        addView(avatar, LayoutParams(context.dp(avatarDp), context.dp(avatarDp), Gravity.CENTER))
        PressScale(this)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        val owner = findViewTreeLifecycleOwner() ?: return
        val account = SettingsGraph.account(context)
        val auth = AuthGraph.get(context)
        watching = owner.lifecycleScope.launch {
            owner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(account.state, auth.state) { settings, session -> settings to session }.collect { (settings, session) ->
                    // While the session is still being checked (or could not be, offline), the
                    // saved session still says whose it is: the letter must not blank out.
                    val signedIn = (session as? AuthState.Connected)?.account ?: auth.savedAccount
                    val name = settings.profile?.displayName(signedIn?.name) ?: signedIn?.name?.takeIf(String::isNotBlank)
                        ?: signedIn?.email.orEmpty()
                    avatar.show(settings.avatar, name, settings.generation)
                    onName?.invoke(name)
                }
            }
        }
    }

    override fun onDetachedFromWindow() {
        watching?.cancel()
        watching = null
        super.onDetachedFromWindow()
    }
}
