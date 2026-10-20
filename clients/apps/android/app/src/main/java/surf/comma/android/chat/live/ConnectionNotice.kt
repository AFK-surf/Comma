package surf.comma.android.chat.live

import android.content.Context
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.conversation.Connection
import surf.comma.android.conversation.ConversationProblem
import surf.comma.android.conversation.ConversationState
import surf.comma.android.ui.connection.ConnectionRetryTarget
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignTypography
import kotlin.math.roundToInt

/** What the notice under the top bar says: offline, or the connection failed for another reason. */
internal enum class ConnectionNotice { OFFLINE, FAILED }

/**
 * When the chat (with something on screen) has lost its connection for a while, and what to do
 * about it. An empty chat is the full-page error's to explain, so the notice stays off there.
 *
 * The notice waits [DELAY_MILLIS] after the connection was lost and only shows if something has
 * actually failed, so a cold start or a quick reconnect never flashes it. Once shown it stays until
 * the chat is live again, through retries that briefly clear the failure.
 *
 * It also passes network changes on: the conversation reconnects at once when the network returns,
 * and a session check that failed is retried then, too.
 */
internal class ConnectionNoticeController(
    private val clock: () -> Long,
    /** Asks for [tick] after this many milliseconds. */
    private val wakeIn: (Long) -> Unit,
    private val onChanged: (ConnectionNotice?) -> Unit,
    private val onRetry: (ConnectionRetryTarget) -> Unit,
    private val onNetworkChanged: (Boolean) -> Unit,
) {
    var shown: ConnectionNotice? = null
        private set
    private var auth: AuthState = AuthState.Starting
    private var chat: ConversationState? = null
    private var online: Boolean? = null
    /** When the connection was last lost, or null while it is live. */
    private var downSince: Long? = null

    fun present(auth: AuthState, chat: ConversationState?) {
        this.auth = auth
        this.chat = chat
        refresh()
    }

    /** Null means the system has not said yet. */
    fun connectivityChanged(available: Boolean?) {
        val previous = online
        online = available
        if (previous != null && available != null && previous != available) {
            onNetworkChanged(available)
            if (available && auth is AuthState.Retry && ownsChat()) onRetry(ConnectionRetryTarget.SESSION)
        }
        refresh()
    }

    /** A tap on the notice. */
    fun retry() {
        if (shown == null) return
        onRetry(if (auth is AuthState.Retry) ConnectionRetryTarget.SESSION else ConnectionRetryTarget.CONVERSATION)
    }

    fun tick() = refresh()

    /** False while the chat is empty, where the full-page error explains the connection instead. */
    private fun ownsChat(): Boolean {
        val chat = chat ?: return false
        return !chat.cacheLoaded || chat.timeline.isNotEmpty()
    }

    private fun refresh() {
        val chat = chat
        val auth = auth
        val down = ownsChat() && (auth is AuthState.Retry || auth is AuthState.Connecting || auth == AuthState.Starting ||
            chat?.connection in DOWN)
        if (!down) {
            downSince = null
            publish(null)
            return
        }
        val now = clock()
        val since = downSince ?: now.also { downSince = it }
        val failed = auth is AuthState.Retry || chat?.problem != null || chat?.connection == Connection.PAUSED
        val next = when {
            shown != null && !failed -> shown
            !failed -> null
            now - since >= DELAY_MILLIS -> kind()
            else -> {
                wakeIn(DELAY_MILLIS - (now - since))
                null
            }
        }
        publish(next)
    }

    private fun kind(): ConnectionNotice = when {
        auth is AuthState.Retry -> ConnectionNotice.FAILED
        online == false || chat?.problem == ConversationProblem.NETWORK -> ConnectionNotice.OFFLINE
        else -> ConnectionNotice.FAILED
    }

    private fun publish(next: ConnectionNotice?) {
        if (next == shown) return
        shown = next
        onChanged(next)
    }

    companion object {
        /** How long the connection has to be gone before the notice shows. */
        const val DELAY_MILLIS = 3_000L
        private val DOWN = setOf(Connection.CONNECTING, Connection.RECONNECTING, Connection.PAUSED)
    }
}

/** The notice itself: a small pill under the top bar that retries on a tap. Fades in and out. */
internal class ConnectionNoticeView(context: Context) : FrameLayout(context) {
    private val density = resources.displayMetrics.density

    private val line = TextView(context).apply {
        DesignTypography.applyTo(this, DesignTypography.Level.SMALL, DesignFonts.medium)
        setTextColor(context.getColor(R.color.token_text_secondary))
        gravity = Gravity.CENTER
        maxLines = 1
        includeFontPadding = false
        minHeight = dp(HEIGHT_DP)
        setPadding(dp(PADDING_DP), 0, dp(PADDING_DP), 0)
    }

    /** The line it shows; exposed for tests. */
    val text: CharSequence get() = line.text

    /** What is shown, or null while hidden (or fading out). */
    var notice: ConnectionNotice? = null
        private set

    init {
        id = R.id.chat_connection_notice
        addView(line, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        // Opaque, so it reads over whatever has scrolled up under it.
        background = GradientDrawable().apply {
            cornerRadius = dp(HEIGHT_DP) / 2f
            setColor(context.getColor(R.color.token_bg_primary))
            setStroke(HomeTopBar.HAIRLINE_PX, context.getColor(R.color.token_border_primary))
        }
        isFocusable = true
        alpha = 0f
        visibility = GONE
    }

    fun show(value: ConnectionNotice?) {
        if (value == notice) return
        notice = value
        animate().cancel()
        if (value != null) {
            line.text = context.getString(if (value == ConnectionNotice.OFFLINE) R.string.chat_paused else R.string.chat_session_retry)
            visibility = VISIBLE
            isClickable = true
            animate().alpha(1f).setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                .setInterpolator(DesignMotion.softInOut).start()
        } else {
            isClickable = false
            animate().alpha(0f).setDuration(DesignMotion.durationMillis(DesignMotion.stateChange))
                .setInterpolator(DesignMotion.softInOut).withEndAction { if (notice == null) visibility = GONE }.start()
        }
    }

    private fun dp(value: Int) = (value * density).roundToInt()

    private companion object {
        const val HEIGHT_DP = 28
        const val PADDING_DP = 12
    }
}
