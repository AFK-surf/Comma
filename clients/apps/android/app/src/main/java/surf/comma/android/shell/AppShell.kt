package surf.comma.android.shell

import android.annotation.SuppressLint
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import android.os.Bundle
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.dynamicanimation.animation.FloatPropertyCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.ConversationScope
import surf.comma.android.chat.live.LiveChatScreen
import surf.comma.android.conversation.ChatRole
import surf.comma.android.conversation.ChatView
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.home.HomePage
import surf.comma.android.inbox.InboxPage
import surf.comma.android.inbox.InboxProjection
import surf.comma.android.notify.ReplyNotifications
import surf.comma.android.settings.RootPage
import surf.comma.android.settings.SettingsGraph
import surf.comma.android.settings.SettingsHost
import surf.comma.android.tasks.list.TaskActions
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring
import surf.comma.android.workspace.WorkspaceGraph
import surf.comma.android.workspace.WorkspaceStore

/**
 * The signed-in app, as the iOS app's shell: Home, Inbox and Settings under the floating tab bar, task search over
 * the tabs, the router chat ("Comma") as a layer that zooms out of its circle beside the tabs, and an open Task in a
 * bottom dock that minimizes to a bar at the foot of the app. The router chat and the Task keep their own
 * conversations, so neither reloads.
 */
@SuppressLint("ViewConstructor")
class AppShell(
    override val activity: ComponentActivity,
    private val router: LiveChatScreen,
    private val routerRepository: ChatView,
    override val store: WorkspaceStore = WorkspaceGraph.get(activity),
) : FrameLayout(activity), Shell {
    override val actions = TaskActions(activity, store)

    /** The app itself: pages, tab bar, router chat and search. It ends above a minimized Task's bar. */
    private val card = FrameLayout(activity).apply {
        id = R.id.shell_root
        setBackgroundColor(activity.getColor(R.color.token_bg_primary))
        // The floating tab bar's shadow falls outside its own bounds.
        clipChildren = false
    }
    /** Holds the pages and frosts what scrolls under the floating tab bar. */
    private val pages = surf.comma.android.ui.widget.BackdropBlurLayout(activity)
    private val home = HomePage(this)
    private val inbox = InboxPage(this)
    private val settings = SettingsHost(activity, embedded = true, toast = { text, error -> store.showToast(text, error) })
    private val tabBar = ShellTabBar(activity)
    private val routerLayer = FrameLayout(activity).apply { visibility = GONE; isClickable = true }
    private val dock = TaskDock(this) { open, raised -> dockChanged(open, raised) }
    private val toasts = ToastStage(activity, store)
    private var search: SearchLayer? = null
    private var tab = AppTab.HOME
    private var routerOpen = false
    /** A fresh launch or sign-in opens chat once; returning to the app keeps the selected page. */
    private var launchRouter = true
    private var routerScope: ConversationScope? = null
    private var focusAfterOpening = false
    private var dockMinimized = false
    private var dockRaised = false
    /** Whether the app is on screen; the router chat keeps its stream only while it is and no Task covers it. */
    private var foreground = true
    /** The last Task request ([WorkspaceStore.taskReveal]) shown, so a restart does not raise the dock again. */
    private var handledReveal: Int? = null
    /** A Task left minimized before the activity was recreated comes back minimized. */
    private var restoreMinimized = false
    private var safeTop = 0
    private var safeBottom = 0
    private var seenReplySeq = Long.MAX_VALUE
    /** The account scope [seenReplySeq] counts in; another one starts the count again. */
    private var seenReplyScope: ConversationScope? = null
    /** The router chat's corner while it zooms; one outline reads it on every frame. */
    private var routerRadius = 0f
    private val routerOutline = object : android.view.ViewOutlineProvider() {
        override fun getOutline(view: View, outline: android.graphics.Outline) =
            outline.setRoundRect(0, 0, view.width, view.height, routerRadius)
    }
    private val routerBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() = closeRouter()
    }

    /** How far the router chat has come out of its circle: 0 closed, 1 open. */
    private var zoom = 0f
        set(value) {
            field = value
            applyZoom()
        }
    private val zoomSpring = DesignSpring(this, ZOOM, DesignMotion.springSpatial, 0.001f)

    init {
        setBackgroundColor(android.graphics.Color.BLACK)
        pages.addView(home, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        pages.addView(inbox, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        pages.addView(settings.host, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        settings.open(RootPage(settings))
        card.addView(pages, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        card.addView(tabBar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            marginStart = activity.dp(BAR_SIDE_DP); marginEnd = activity.dp(BAR_SIDE_DP)
        })
        routerLayer.addView(router.root, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        card.addView(routerLayer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(dock, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(toasts, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        router.onOpenSidebar = ::closeRouter
        // As on iOS, a Task's card in the router chat opens the Task in the dock, over the chat.
        router.onOpenTaskCard = { id, _ -> store.openTask(id) }
        routerLayer.outlineProvider = routerOutline
        tabBar.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> frostUnderTabBar() }
        tabBar.onSelect = ::select
        tabBar.onSearch = ::openSearch
        tabBar.onRouter = { openRouter() }
        activity.onBackPressedDispatcher.addCallback(activity, routerBack)
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            safeTop = bars.top
            safeBottom = bars.bottom
            layoutInsets()
            val keyboard = insets.isVisible(WindowInsetsCompat.Type.ime())
            home.setKeyboardVisible(keyboard && !routerOpen)
            insets
        }
        showTab(AppTab.HOME)
        bind()
    }

    private fun bind() {
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    combine(store.tasks.state, store.inboxMarks) { state, marks -> InboxProjection.hasUnread(state.snapshot.tasks, marks) }
                        .collect(tabBar::setInboxUnread)
                }
                launch {
                    SettingsGraph.account(activity).state.collect { state ->
                        val account = (store.auth.state.value as? AuthState.Connected)?.account
                        tabBar.setAvatar(state.avatar, state.profile?.displayName(account?.name) ?: account?.name ?: account?.email.orEmpty(),
                            state.generation)
                    }
                }
                launch { routerRepository.state.collect(::routerChanged) }
                launch { ReplyNotifications.get(activity).enabled.collect { updateSettingsAttention() } }
                // The store lets the Task go on sign-out or another account or Workspace: so does the dock.
                launch { store.openTask.collect { id -> if (id == null) dock.dismissNow() } }
                // Each request to show a Task raises it once; the same request read again on a restart leaves a
                // minimized dock as it is.
                launch {
                    store.taskReveal.collect { reveal ->
                        if (reveal == handledReveal) return@collect
                        handledReveal = reveal
                        // Only the first request read after a recreation is the Task that was open before it.
                        val raise = !restoreMinimized
                        restoreMinimized = false
                        val id = store.openTask.value ?: return@collect
                        dock.open(id, raise)
                    }
                }
                launch {
                    combine(store.auth.state, store.auth.conversationScope) { state, scope -> state to scope }
                        .collect { (state, scope) ->
                            // A retained offline scope keeps its chat. A changed or removed scope closes it.
                            if (routerScope != null && routerScope !== scope) closeRouter()
                            routerScope = scope
                            if (state is AuthState.Login || state == AuthState.Unconfigured) {
                                launchRouter = true
                                closeRouter()
                            } else if (launchRouter && scope != null) {
                                launchRouter = false
                                showRouter(focus = false, animate = false)
                            }
                        }
                }
            }
        }
    }

    fun resumed() {
        updateSettingsAttention()
        settings.renderAll()
        if (tab == AppTab.HOME) home.shown()
    }

    private fun updateSettingsAttention() {
        val replies = ReplyNotifications.get(activity)
        tabBar.setSettingsAttention(replies.enabled.value && !replies.canPost())
    }

    override fun notificationsOff(): (() -> Unit)? {
        val replies = ReplyNotifications.get(activity)
        if (replies.enabled.value && replies.canPost()) return null
        return { select(AppTab.SETTINGS) }
    }

    /** The tab bar's glass shows the page blurred under its capsule and its circle. */
    private fun frostUnderTabBar() {
        val shapes = tabBar.frostShapes()
        listOf("tabs", "router").forEachIndexed { index, key ->
            val (rect, radius) = shapes[index]
            rect.offset(tabBar.left - pages.left, tabBar.top - pages.top)
            pages.setFloatingPatch(key, if (tabBar.visibility == VISIBLE) rect else null, radius)
        }
    }

    // MARK: Tabs

    private fun select(next: AppTab) {
        if (next == tab) {
            when (next) {
                AppTab.HOME -> home.reselected()
                AppTab.INBOX -> inbox.reselected()
                AppTab.SETTINGS -> settings.host.popToRoot()
            }
            return
        }
        showTab(next)
    }

    private fun showTab(next: AppTab) {
        tab = next
        tabBar.select(next)
        home.isVisible = next == AppTab.HOME
        inbox.isVisible = next == AppTab.INBOX
        settings.host.isVisible = next == AppTab.SETTINGS
        settings.active = next == AppTab.SETTINGS
        if (next == AppTab.HOME) home.shown()
        if (next == AppTab.SETTINGS) settings.renderAll()
    }

    private fun layoutInsets() {
        // An open Task's bar takes the foot of the screen, the system's navigation area included; the app card ends
        // above it, a gap clear of it, and its own foot then needs no room for the navigation bar.
        val docked = dock.isOpen
        val footInset = if (docked) 0 else safeBottom
        val barBottom = maxOf(footInset, activity.dp(12)) + activity.dp(BAR_GAP_DP)
        (tabBar.layoutParams as LayoutParams).bottomMargin = barBottom
        tabBar.requestLayout()
        val reserve = barBottom + activity.dp(ShellTabBar.HEIGHT_DP)
        home.setInsets(safeTop, reserve)
        inbox.setInsets(safeTop, reserve)
        settings.bottomReserve = reserve + activity.dp(8) - safeBottom
        val dockReserve = if (docked) TaskDock.reserve(activity, safeBottom) else 0
        (card.layoutParams as LayoutParams).bottomMargin = dockReserve
        card.clipToOutline = dockReserve > 0
        card.outlineProvider = if (dockReserve > 0) object : android.view.ViewOutlineProvider() {
            override fun getOutline(view: View, outline: android.graphics.Outline) =
                outline.setRoundRect(0, 0, view.width, view.height, activity.dp(28).toFloat())
        } else android.view.ViewOutlineProvider.BACKGROUND
        card.requestLayout()
    }

    // MARK: Task dock

    private fun dockChanged(open: Boolean, raised: Boolean) {
        dockMinimized = open && !raised
        dockRaised = open && raised
        if (raised) router.dismissInput()
        applyForeground()
        updateBack()
        layoutInsets()
    }

    /** The activity started or stopped: both chats keep their streams only while the app is on screen. */
    fun setForeground(visible: Boolean) {
        foreground = visible
        applyForeground()
        dock.setForeground(visible)
    }

    private fun applyForeground() = routerRepository.setForeground(foreground && !dockRaised)

    /** The activity ends: the open Task's conversation, its chat and their streams stop with it. */
    fun release() = dock.release()

    // MARK: Back

    /**
     * Back acts on the top layer: a raised Task, then the router chat, then search. Each registers its own callback,
     * and the last registered wins, so the ones under the top layer are turned off.
     */
    private fun updateBack() {
        routerBack.isEnabled = routerOpen && !dockRaised
        search?.setBackEnabled(!routerOpen && !dockRaised)
    }

    // MARK: Saved state

    fun saveState(out: Bundle) {
        out.putString(STATE_TAB, tab.name)
        out.putBoolean(STATE_DOCK_MINIMIZED, dockMinimized)
        out.putBoolean(STATE_ROUTER_OPEN, routerOpen || launchRouter)
    }

    /** Restores the selected page and the open Task's raised or minimized state. */
    fun restoreState(state: Bundle?) {
        state ?: return
        state.getString(STATE_TAB)?.let { name -> AppTab.entries.firstOrNull { it.name == name } }?.let(::showTab)
        restoreMinimized = state.getBoolean(STATE_DOCK_MINIMIZED)
        launchRouter = state.getBoolean(STATE_ROUTER_OPEN, true)
        if (launchRouter && store.auth.conversationScope.value != null) {
            launchRouter = false
            showRouter(focus = false, animate = false)
        } else if (!launchRouter) {
            closeRouter()
            zoomSpring.cancel()
            zoom = 0f
        }
    }

    // MARK: Search

    private fun openSearch() {
        if (search != null) return
        if (routerOpen) closeRouter()
        val layer = SearchLayer(this) {
            val current = search ?: return@SearchLayer
            search = null
            card.removeView(current)
        }
        search = layer
        card.addView(layer, card.indexOfChild(routerLayer), LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        updateBack()
        layer.show()
    }

    // MARK: Router chat

    override fun openRouter(focus: Boolean) {
        showRouter(focus, animate = true)
    }

    private fun showRouter(focus: Boolean, animate: Boolean) {
        if (routerOpen) {
            if (focus) router.focusComposer()
            return
        }
        search?.dismiss()
        if (animate && dock.isOpen) dock.minimize()
        routerOpen = true
        focusAfterOpening = focus
        updateBack()
        routerLayer.visibility = VISIBLE
        markRepliesSeen()
        if (animate) zoomSpring.animateTo(1f) else {
            zoomSpring.cancel()
            zoom = 1f
        }
    }

    override fun insertIntoRouter(text: String) {
        openRouter(focus = false)
        router.fillDraft(text)
    }

    private fun closeRouter() {
        if (!routerOpen) return
        routerOpen = false
        focusAfterOpening = false
        updateBack()
        router.dismissInput()
        markRepliesSeen()
        zoomSpring.animateTo(0f)
    }

    /** The router chat grows out of its circle and shrinks back into it, its corners rounding as it gets small. */
    private fun applyZoom() {
        val location = IntArray(2)
        val (w, h) = tabBar.routerBounds(location)
        val origin = IntArray(2).also(card::getLocationInWindow)
        val cx = location[0] - origin[0] + w / 2f
        val cy = location[1] - origin[1] + h / 2f
        val z = zoom
        val shown = z.coerceIn(0f, 1f)
        routerLayer.pivotX = cx
        routerLayer.pivotY = cy
        val small = if (card.width > 0) w.toFloat() / card.width else 0.15f
        val scale = small + (1f - small) * z
        routerLayer.scaleX = scale
        routerLayer.scaleY = small + (1f - small) * z
        routerLayer.alpha = ((z - 0.05f) / 0.45f).coerceIn(0f, 1f)
        routerLayer.clipToOutline = z < 0.999f
        routerRadius = activity.dp(32) * (1f - shown) / scale.coerceAtLeast(0.05f)
        routerLayer.invalidateOutline()
        if (!routerOpen && z <= 0.01f) {
            routerLayer.visibility = GONE
        }
        if (routerOpen && z >= 0.98f && focusAfterOpening) {
            focusAfterOpening = false
            router.focusComposer()
        }
    }

    /** Replies Comma sent while the chat was closed are counted on its circle; Comma replying plays its mark. */
    private fun routerChanged(state: ConversationState) {
        val replies = state.timeline.filterIsInstance<TimelineEntry.Message>().filter { it.message.role == ChatRole.ASSISTANT }
        val newest = replies.maxOfOrNull { it.message.seq } ?: 0L
        // The chat is shared across accounts and Workspaces: another one's replies are counted from its own start.
        if (state.scope != seenReplyScope) {
            seenReplyScope = state.scope
            seenReplySeq = Long.MAX_VALUE
        }
        if (seenReplySeq == Long.MAX_VALUE && state.cacheLoaded) seenReplySeq = newest
        if (routerOpen) seenReplySeq = maxOf(seenReplySeq, newest)
        val unread = if (routerOpen || seenReplySeq == Long.MAX_VALUE) 0 else replies.count { it.message.seq > seenReplySeq }
        val replying = state.reply.pending || state.timeline.any { it is TimelineEntry.Draft }
        tabBar.setRouter(unread, replying)
    }

    private fun markRepliesSeen() {
        val newest = routerRepository.state.value.timeline.filterIsInstance<TimelineEntry.Message>()
            .filter { it.message.role == ChatRole.ASSISTANT }.maxOfOrNull { it.message.seq } ?: 0L
        seenReplySeq = newest
        routerChanged(routerRepository.state.value)
    }

    /** The connection page's way to the account: Settings, over which the chat closes. */
    fun openSettings() {
        closeRouter()
        showTab(AppTab.SETTINGS)
    }

    /** A tapped reply notification: the Task dock steps down and the router chat comes forward. */
    fun revealRouter() {
        if (dock.isOpen) dock.minimize()
        openRouter()
    }

    companion object {
        const val BAR_SIDE_DP = 20
        const val BAR_GAP_DP = 4
        private const val STATE_TAB = "shell.tab"
        private const val STATE_DOCK_MINIMIZED = "shell.dockMinimized"
        private const val STATE_ROUTER_OPEN = "shell.routerOpen"

        private val ZOOM = object : FloatPropertyCompat<AppShell>("zoom") {
            override fun getValue(shell: AppShell) = shell.zoom
            override fun setValue(shell: AppShell, value: Float) { shell.zoom = value }
        }
    }
}
