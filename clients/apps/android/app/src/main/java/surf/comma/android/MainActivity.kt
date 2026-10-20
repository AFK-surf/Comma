package surf.comma.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowCompat
import androidx.core.view.doOnLayout
import androidx.core.view.doOnPreDraw
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import surf.comma.android.auth.AuthActivity
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthRepository
import surf.comma.android.chat.data.ConversationSourceFactory
import surf.comma.android.chat.live.ChatGraph
import surf.comma.android.shell.AppShell
import surf.comma.android.chat.live.ChatNavigation
import surf.comma.android.chat.live.ChatNavigator
import surf.comma.android.chat.live.HomeTopBar
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.chat.live.routeFor
import surf.comma.android.chat.live.withReplyActions
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.MessageCopy
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.codeSyntaxTheme
import surf.comma.android.performance.ConversationTelemetry
import surf.comma.android.performance.ConversationTelemetryFactory
import surf.comma.android.settings.BLUETOOTH_PERMISSIONS
import surf.comma.android.settings.devices.NearbyDevices
import surf.comma.android.settings.devices.NearbyPermissionDialog
import surf.comma.android.media.viewer.ImageViewerActivity
import surf.comma.android.media.localViewerImage
import surf.comma.android.notify.ReplyLink
import surf.comma.android.notify.ReplyNotifications
import surf.comma.android.ui.MessageActionsPopup
import surf.comma.android.ui.widget.BackdropBlurLayout
import surf.comma.android.voice.CallController
import surf.comma.android.voice.ui.CallScreen
import kotlin.coroutines.resume

/**
 * Entry point. Signed in, it is the main chat; otherwise it opens the sign-in page over itself
 * and comes back once the session connects. Debug and benchmark builds keep a direct path to
 * the measured local conversation.
 */
class MainActivity : ComponentActivity() {
    // Live chat.
    private var auth: AuthRepository? = null
    private var live: LiveChatScreen? = null
    private var shell: AppShell? = null
    private var replies: ReplyNotifications? = null
    private val navigator = ChatNavigator()
    // Nothing depends on the answer: without the permission the chat works as before.
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
    private var nearby: NearbyDevices? = null
    private var nearbyReason: NearbyPermissionDialog? = null
    private val nearbyPermission = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        nearby?.refresh()
    }
    private var callScreen: CallScreen? = null
    /**
     * Asked before each new call: the microphone (without it the call shows why it cannot start)
     * and, so the ongoing-call notification can show, notifications (a call works without them).
     */
    private val callPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        startCall()
    }

    // Local measured conversation.
    private val source = ConversationSourceFactory.create()
    // Laid out like the live chat, so the measured conversation draws the same bubbles.
    private val precomputer = MessageLayoutPrecomputer(bubbles = true)
    private var prepared: List<PreparedChatMessage> = emptyList()
    private lateinit var timeline: ChatTimelineView
    private lateinit var telemetry: ConversationTelemetry
    private lateinit var replay: Button
    private var scenario = "cold_start"
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (ConversationSourceFactory.useFixtures(intent)) showFixtures() else showLiveChat(savedInstanceState)
    }

    private fun showLiveChat(savedInstanceState: Bundle?) {
        nearby = NearbyDevices.get(this)
        val session = AuthGraph.get(this).also { auth = it }
        val repository = ChatGraph.conversations(this)
        val screen = LiveChatScreen(this, repository, session.state, retrySession = { session.retry() },
            onOpenAccount = { shell?.openSettings() },
            onCall = ::onCall,
            voiceReady = { session.voiceReady() },
            router = true,
        )
        live = screen
        replies = ReplyNotifications.get(this)
        val app = AppShell(this, screen, repository).also { shell = it }
        app.restoreState(savedInstanceState)
        setContentView(app)
        // The initial page is drawn once the shell has been laid out.
        app.doOnPreDraw { reportFullyDrawn() }
        // Over everything in the chat, sidebar and task sheet included; registered after them, so
        // back minimizes an expanded call first.
        callScreen = CallScreen(this).also {
            addContentView(it, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
        screen.bind()
        openReply(intent)
        openCall(intent)
        lifecycleScope.launch { session.start() }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                combine(session.state, session.conversationScope) { _, _ -> }.collect { askNearbyPermission() }
            }
        }
        // Collected for the whole activity lifetime: it must react while the sign-in page is on top.
        lifecycleScope.launch {
            combine(session.state, session.conversationScope) { state, scope -> routeFor(state, scope != null) }
                .collect { navigate(navigator.onRoute(it)) }
        }
    }

    private fun navigate(action: ChatNavigation) {
        when (action) {
            ChatNavigation.NONE -> Unit
            ChatNavigation.OPEN_AUTH -> startActivity(Intent(this, AuthActivity::class.java))
            // Brings this activity back to the front and closes the sign-in page above it.
            ChatNavigation.RETURN_TO_CHAT -> startActivity(Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            ChatNavigation.FINISH -> finish()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openReply(intent)
        openCall(intent)
    }

    /** The call notification opens the call page; it never starts a call. */
    private fun openCall(intent: Intent?) {
        if (intent?.getBooleanExtra(CallController.EXTRA_EXPAND_CALL, false) != true) return
        intent.removeExtra(CallController.EXTRA_EXPAND_CALL)
        callScreen?.expand()
    }

    /** The top bar's Call button: back to the call in progress, or ask for the microphone and call. */
    private fun onCall() {
        if (CallController.get(this).state.value.busy) {
            callScreen?.expand()
            return
        }
        val missing = buildList {
            if (!granted(Manifest.permission.RECORD_AUDIO)) add(Manifest.permission.RECORD_AUDIO)
            if (!granted(Manifest.permission.POST_NOTIFICATIONS)) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (missing.isEmpty()) startCall() else callPermissions.launch(missing.toTypedArray())
    }

    private fun startCall() {
        val state = CallController.get(this).start()
        callScreen?.expand()
        // A start refused for the microphone leaves the same finished state each time: show it again.
        if (!state.busy) callScreen?.revealCurrent()
    }

    private fun granted(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun askNearbyPermission() {
        val nearby = nearby ?: return
        if (!nearby.shouldAskPermission() || nearbyReason != null) return
        nearby.permissionAsked()
        nearbyReason = NearbyPermissionDialog(this,
            onContinue = { nearbyPermission.launch(BLUETOOTH_PERMISSIONS) },
            onDismiss = { nearbyReason = null }).also { it.show() }
    }

    /** A tapped reply notification: scroll to the reply if it belongs to this account's chat. */
    private fun openReply(intent: Intent?) {
        val link = ReplyLink.from(intent) ?: return
        val notifications = replies ?: return
        lifecycleScope.launch {
            notifications.target(link)?.let {
                shell?.revealRouter()
                live?.reveal(it)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // The router chat, and an open Task's, unless a raised Task covers the router.
        shell?.setForeground(true)
        replies?.chatShown()
    }

    override fun onResume() {
        super.onResume()
        auth?.let { navigate(navigator.onChatResumed(routeFor(it.state.value, it.conversationScope.value != null))) }
        askNearbyPermission()
        // Asked once, back in the chat after the user first left a reply waiting.
        shell?.resumed()
        replies?.takeIf { nearbyReason == null && it.shouldAskPermission() && auth?.conversationScope?.value != null }?.let {
            it.permissionAsked()
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onStop() {
        // Before the stream pauses, so a hold keeps it open without a reconnect.
        replies?.chatHidden()
        shell?.setForeground(false)
        if (live != null) navigator.onChatStopped()
        super.onStop()
    }

    private fun showFixtures() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(getColor(R.color.token_bg_primary))
        }
        root.addView(TextView(this).apply {
            text = getString(R.string.app_name)
            textSize = 22f
            setTextColor(getColor(R.color.token_text_primary))
            gravity = Gravity.CENTER_VERTICAL
            setPadding(24, 16, 24, 16)
        }, LinearLayout.LayoutParams(-1, -2))
        // The live chat's frosted top, the same size, so benchmarks measure its cost here.
        val body = BackdropBlurLayout(this).apply { mode = backdropMode(intent) }
        timeline = ChatTimelineView(this).apply { id = R.id.conversation_timeline }
        body.addView(timeline, FrameLayout.LayoutParams(-1, -1))
        // Its band and patches come from the real top bar, laid out off screen at this width
        // under a typical status bar, so the two cannot drift apart.
        val bar = HomeTopBar(this).apply {
            setStatusBarInset((BENCHMARK_STATUS_BAR_DP * resources.displayMetrics.density).toInt())
        }
        timeline.doOnLayout {
            bar.measure(
                View.MeasureSpec.makeMeasureSpec(it.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            )
            bar.layout(0, 0, bar.measuredWidth, bar.measuredHeight)
            body.setTopBand(bar.frostBottom, bar.frostSolid)
            bar.frostPatches().forEach { patch -> body.setTopPatch(patch.key, patch.bounds, patch.radius) }
        }
        timeline.addOnScrollListener(object : surf.comma.android.scroll.widget.RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: surf.comma.android.scroll.widget.RecyclerView, dx: Int, dy: Int) {
                body.setTopOverflow(timeline.canScrollVertically(-1))
            }
        })
        timeline.onImageClick = { image -> localViewerImage(image)?.let { ImageViewerActivity.start(this, listOf(it), 0) } }
        timeline.onLongPressMessage = MessageActionsPopup::show
        timeline.onCopyCode = { MessageActionsPopup.copyCode(this, it) }
        timeline.onReplyAction = { _, item ->
            val reply = MessageCopy.reply(prepared.filter {
                it.message.turnId == item.message.turnId && it.message.role == ChatRole.AGENT && it.message.cardKind == null
            }.map { it.message.text })
            MessageActionsPopup.copyMessage(this, reply)
            reply.isNotBlank()
        }
        root.addView(body, LinearLayout.LayoutParams(-1, 0, 1f))
        status = TextView(this).apply {
            id = R.id.conversation_status
            text = getString(R.string.conversation_loading)
            setSingleLine(true)
            setTextColor(getColor(R.color.token_text_primary))
            gravity = Gravity.CENTER
        }
        root.addView(status)
        replay = Button(this).apply {
            id = R.id.replay_reply
            setText(R.string.replay_reply)
            isEnabled = false
            visibility = if (source.canReplay) View.VISIBLE else View.GONE
            setOnClickListener { replayReply() }
        }
        root.addView(replay, LinearLayout.LayoutParams(-1, -2))
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        setContentView(root)
        telemetry = ConversationTelemetryFactory.create(window, timeline)
        // The release source cannot enable fixture/benchmark controls.
        val scene = if (source.canReplay) intent.getStringExtra("scenario") else null
        scenario = scene?.takeIf { it in setOf("cold_start", "long_fling", "streaming_history", "streaming_bottom", "waiting_reply") } ?: "cold_start"
        telemetry.scenario(scenario)
        timeline.doOnLayout {
            lifecycleScope.launch {
                render(source.load())
                status.text = getString(if (source.canReplay) R.string.conversation_ready else R.string.empty_conversation)
                status.contentDescription = "ready;stable_ids=${timeline.adapter?.hasStableIds()}"
                replay.isEnabled = source.canReplay
                // Fully drawn means the real list has committed AND completed layout/draw.
                timeline.doOnPreDraw { reportFullyDrawn() }
                timeline.invalidate()
            }
        }
    }

    private fun replayReply() {
        replay.isEnabled = false
        val waiting = scenario == "waiting_reply"
        telemetry.scenario(if (scenario == "streaming_bottom" || waiting) scenario else "streaming_history")
        timeline.stopScroll()
        // Sample only after any fling/layout has settled; no corrective scrolling by this probe.
        timeline.doOnPreDraw {
            telemetry.beginReply()
            status.setText(R.string.reply_playing)
            status.contentDescription = "streaming"
            lifecycleScope.launch {
                (if (waiting) source.replayAfterWaiting() else source.replay()).collect { render(it) }
                timeline.doOnPreDraw {
                    status.setText(R.string.reply_complete)
                    status.contentDescription = telemetry.endReply()
                    replay.isEnabled = true
                }
                timeline.invalidate()
            }
        }
        timeline.invalidate()
    }

    private suspend fun render(messages: List<ChatMessage>) {
        val metrics = resources.displayMetrics
        // The fixtures carry the live chat's reply buttons, so the benchmarks measure them too.
        prepared = precomputer.prepareChanged(
            previous = prepared, messages = withReplyActions(messages), viewportWidthPx = timeline.width,
            density = metrics.density, fontScale = resources.configuration.fontScale,
            syntaxTheme = codeSyntaxTheme(this),
            darkTheme = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES,
            palette = surf.comma.android.chat.render.ChatPalette.from(this),
            codeLabels = surf.comma.android.chat.render.codeLabels(this),
        )
        suspendCancellableCoroutine { continuation ->
            timeline.submitPrepared(prepared) {
                if (continuation.isActive) continuation.resume(Unit)
            }
        }
    }

    /** `top_backdrop` = blur (default), fade or off; only fixture builds read it. */
    private fun backdropMode(intent: Intent): BackdropBlurLayout.Mode =
        when (intent.getStringExtra("top_backdrop").takeIf { source.canReplay }) {
            "fade" -> BackdropBlurLayout.Mode.FADE
            "off" -> BackdropBlurLayout.Mode.OFF
            else -> BackdropBlurLayout.Mode.BLUR
        }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        shell?.saveState(outState)
    }

    override fun onDestroy() {
        nearbyReason?.dismiss()
        // The open Task's conversation lives in its own scope, outside the activity's: it ends here, not with it.
        shell?.release()
        live?.release()
        if (::timeline.isInitialized) timeline.release()
        if (::telemetry.isInitialized) telemetry.close()
        super.onDestroy()
    }

    private companion object {
        /** A typical status bar, for the top bar the fixture screen borrows its frost from. */
        const val BENCHMARK_STATUS_BAR_DP = 36
    }
}
