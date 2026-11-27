package surf.comma.android.shell

import android.annotation.SuppressLint
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.activity.BackEventCompat
import androidx.activity.ComponentActivity
import android.os.Bundle
import androidx.activity.OnBackPressedCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
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
import surf.comma.android.ui.widget.LiquidGlass
import surf.comma.android.ui.kit.dp
import surf.comma.android.workspace.WorkspaceGraph
import surf.comma.android.workspace.WorkspaceStore
import kotlin.math.roundToInt

/**
 * The signed-in app, as the iOS app's shell: Home, Inbox and Settings under the floating tab bar, task search over
 * the tabs, the router chat ("Comma") as a layer that grows out of its circle beside the tabs ([RouterLayer]), and an open Task in a
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
    private val settings: SettingsHost = SettingsHost(activity, embedded = true, toast = { text, error -> store.showToast(text, error) },
        links = surf.comma.android.settings.SettingsLinks(
            openRouter = { openRouter() },
            attachToRouter = { name, bytes -> routerRepository.attach(name, bytes) != null },
            openApps = { apps.openList() },
        ))
    private val people = surf.comma.android.people.PeopleTab(settings, store)
    private val apps: surf.comma.android.miniapps.MiniApps = surf.comma.android.miniapps.MiniApps(settings, store)
    private val tabBar = ShellTabBar(activity)
    private val routerLayer = RouterLayer(activity, router, ::routerCircle, ::routerCorners).apply { visibility = GONE; isClickable = true }
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
    /** Whether [layoutInsets] last laid the card out above a settled Task bar. */
    private var footSettled = false
    /** Whether the app is on screen; the router chat keeps its stream only while it is and no Task covers it. */
    private var foreground = true
    /** The last Task request ([WorkspaceStore.OpenTask.reveal]) shown, so a restart does not raise the dock again. */
    private var handledReveal: Int? = null
    /** A Task left minimized before the activity was recreated comes back minimized. */
    private var restoreMinimized = false
    private var safeTop = 0
    private var safeBottom = 0
    private var displayCorners = surf.comma.android.ui.kit.DisplayCorners.UNKNOWN
    /** The open Task's browser viewer from before the activity was recreated (a rotation); it opens again with it. */
    private var restoreBrowser: String? = null
    private var seenReplySeq = Long.MAX_VALUE
    /** The account scope [seenReplySeq] counts in; another one starts the count again. */
    private var seenReplyScope: ConversationScope? = null
    /** The back gesture holds the router chat's shape as it goes and closes it or lets it spring back. */
    private val routerBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackStarted(backEvent: BackEventCompat) = routerLayer.backStarted(backEvent)
        override fun handleOnBackProgressed(backEvent: BackEventCompat) = routerLayer.backProgressed(backEvent)
        override fun handleOnBackPressed() = closeRouter(routerLayer.backReleased())
        override fun handleOnBackCancelled() = routerLayer.backCancelled()
    }

    init {
        setBackgroundColor(android.graphics.Color.BLACK)
        pages.addView(home, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        pages.addView(inbox, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        pages.addView(people.host, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        pages.addView(settings.host, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        surf.comma.android.miniapps.MiniAppRuntimes.start(activity)
        surf.comma.android.miniapps.MiniAppRuntimes.draftTarget = ::insertIntoRouter
        apps.onNewApp = { prompt ->
            // As the desktop's prefill: a draft that already holds the request keeps it once. The keyboard comes up
            // once the router chat has opened, not while it is still zooming in.
            if (!router.draftText().contains(prompt.trim())) router.fillDraft(prompt, focus = false)
            showRouter(focus = true, animate = true)
        }
        // The tab's list is there from the start, never slid in: a theme, language or text size change recreates the
        // activity with Settings showing.
        settings.restore(RootPage(settings))
        card.addView(pages, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        card.addView(tabBar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
            marginStart = activity.dp(BAR_SIDE_DP); marginEnd = activity.dp(BAR_SIDE_DP)
        })
        card.addView(routerLayer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(card, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(dock, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(toasts, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        dock.onFoot = { dockFootMoved() }
        // Above a Task's bar the card's foot rounds; while the bar comes or goes the clip follows it.
        card.outlineProvider = object : android.view.ViewOutlineProvider() {
            override fun getOutline(view: View, outline: android.graphics.Outline) {
                val lift = if (dockSettled) 0f else footLift()
                cardCorners().outline(view, outline, android.graphics.RectF(0f, 0f, view.width.toFloat(), view.height - lift))
            }
        }
        router.onOpenSidebar = { closeRouter() }
        // As on iOS, a Task's card in the router chat opens the Task in the dock, over the chat.
        router.onOpenTaskCard = { id, _ -> store.openTask(id) }
        router.onOpenBrowser = ::openRouterBrowser
        // While the chat is out of its circle or on its way, its shape stands in for the circle.
        routerLayer.onShown = { shown ->
            tabBar.setRouterHidden(shown)
            frostUnderTabBar()
        }
        routerLayer.onPullClose = ::closeRouter
        routerLayer.onNearlyOpen = {
            // The keyboard comes up once the chat has opened, not while it is still growing.
            if (focusAfterOpening) {
                focusAfterOpening = false
                router.focusComposer()
            }
        }
        tabBar.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            frostUnderTabBar()
            routerLayer.circleMoved()
        }
        tabBar.onGlassTouch = { pages.trackPress("tabs", it) }
        tabBar.backdrop = { canvas ->
            canvas.save()
            canvas.translate((pages.left - tabBar.left).toFloat(), (pages.top - tabBar.top).toFloat())
            pages.drawContent(canvas)
            canvas.restore()
        }
        tabBar.onSelect = ::select
        tabBar.onRouter = { openRouter() }
        activity.onBackPressedDispatcher.addCallback(activity, routerBack)
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            safeTop = bars.top
            safeBottom = bars.bottom
            displayCorners = surf.comma.android.ui.kit.DisplayCorners.of(insets.toWindowInsets())
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
                launch { store.openTask.collect { open -> if (open.id == null) dock.dismissNow() } }
                // Each request to show a Task raises it once; the same request read again on a restart leaves a
                // minimized dock as it is.
                launch {
                    store.openTask.collect { open ->
                        if (open.reveal == handledReveal) return@collect
                        handledReveal = open.reveal
                        // Only the first request read after a recreation is the Task that was open before it.
                        val raise = !restoreMinimized
                        restoreMinimized = false
                        val id = open.id ?: return@collect
                        dock.open(id, raise, open.group)
                        restoreBrowser?.let { viewer -> dock.openBrowser(viewer, raise = false) }
                        restoreBrowser = null
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
        val shapes = if (tabBar.visibility == VISIBLE) tabBar.frostShapes() else emptyList()
        shapes.forEach { it.bounds.offset(tabBar.left - pages.left, tabBar.top - pages.top) }
        val density = resources.displayMetrics.density
        pages.setFloatingGroup("tabs", shapes, LiquidGlass.BLEND_DP * density)
        val capsule = shapes.firstOrNull()?.bounds
        pages.setGroupPress("tabs", ((capsule?.width() ?: 0) * ShellTabBar.LENS_BAR_SCALE / 2f).toInt(),
            ((capsule?.height() ?: 0) * ShellTabBar.LENS_BAR_SCALE / 2f).toInt(), ShellTabBar.LENS_BLEND_DP * density,
            if (resources.configuration.isNightModeActive) ShellTabBar.LENS_VEIL_DARK else ShellTabBar.LENS_VEIL)
    }

    // MARK: Tabs

    private fun select(next: AppTab) {
        if (next == tab) {
            when (next) {
                AppTab.HOME -> home.reselected()
                AppTab.INBOX -> inbox.reselected()
                AppTab.PEOPLE -> people.reselected()
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
        people.host.isVisible = next == AppTab.PEOPLE
        people.active = next == AppTab.PEOPLE
        settings.host.isVisible = next == AppTab.SETTINGS
        settings.active = next == AppTab.SETTINGS
        if (next == AppTab.HOME) home.shown()
        if (next == AppTab.SETTINGS) settings.renderAll()
    }

    /**
     * Whether the app's card ends above a minimized Task's bar. While a bar comes or goes ([TaskDock.foot] between 0
     * and 1) the card keeps the whole screen and only its clipped foot, the tab bar and Home's switcher follow the bar
     * ([applyFoot]), so the pages keep their layout on every frame and nothing jumps when the Task goes.
     */
    private val dockSettled: Boolean get() = dock.isOpen && footShare() >= 1f

    /**
     * [TaskDock.foot] as the share of the bar's room the app's foot keeps. A bar a little below its place (the sheet
     * settling past it as it minimizes) leaves the app as it is; only a bar going further pulls the foot down.
     */
    private fun footShare(): Float = (dock.foot / FOOT_SETTLED).coerceAtMost(1f)

    private fun layoutInsets() {
        // A settled Task's bar takes the foot of the screen, the system's navigation area included; the app card ends
        // above it, a gap clear of it, and its own foot then needs no room for the navigation bar.
        val docked = dockSettled
        footSettled = docked
        val barBottom = tabBarBottom(docked)
        (tabBar.layoutParams as LayoutParams).bottomMargin = barBottom
        tabBar.requestLayout()
        val reserve = barBottom + activity.dp(ShellTabBar.HEIGHT_DP)
        home.setInsets(safeTop, reserve)
        inbox.setInsets(safeTop, reserve)
        settings.bottomReserve = reserve + activity.dp(8) - safeBottom
        people.bottomReserve = reserve + activity.dp(8) - safeBottom
        val dockReserve = if (docked) TaskDock.reserve(activity, safeBottom) else 0
        (card.layoutParams as LayoutParams).bottomMargin = dockReserve
        card.requestLayout()
        applyFoot()
    }

    /** The tab bar's distance from the card's foot: clear of the navigation area unless a settled Task's bar covers it. */
    private fun tabBarBottom(docked: Boolean): Int = maxOf(if (docked) 0 else safeBottom, activity.dp(12)) + activity.dp(BAR_GAP_DP)

    /** How far above the screen's foot the app's foot sits while a Task's bar comes or goes. */
    private fun footLift(): Float = TaskDock.reserve(activity, safeBottom) * footShare()

    private fun dockFootMoved() {
        val settled = dockSettled
        if (settled != footSettled) {
            footSettled = settled
            layoutInsets()
        } else applyFoot()
    }

    /**
     * Puts the foot of the app where the Task's bar now is: the card's clip, the tab bar and Home's switcher move with
     * it, the tab bar between its place above a settled bar and its own place at the screen's foot.
     */
    private fun applyFoot() {
        val settled = dockSettled
        card.clipToOutline = settled || footShare() > 0f
        card.invalidateOutline()
        val free = tabBarBottom(false)
        val above = TaskDock.reserve(activity, safeBottom) + tabBarBottom(true)
        val lift = if (settled) 0 else ((above - free) * footShare()).roundToInt()
        val params = tabBar.layoutParams as LayoutParams
        if (params.bottomMargin != free + lift && !settled) {
            params.bottomMargin = free + lift
            tabBar.requestLayout()
        }
        home.setSwitcherLift(lift)
        // The router chat and search fill the card down to its visible foot.
        listOfNotNull(routerLayer, search).forEach { layer ->
            val params = layer.layoutParams as LayoutParams
            if (params.bottomMargin != layerFoot()) {
                params.bottomMargin = layerFoot()
                layer.requestLayout()
            }
        }
    }

    /** The full-size layers' room below them: the bar's share while it comes or goes, none otherwise. */
    private fun layerFoot(): Int = if (dockSettled) 0 else footLift().roundToInt()

    /**
     * The app's corners above a docked Task: its foot rounds, each corner no rounder than the display's corner on
     * that side (a foldable's outer screen has small ones), and its top meets the display's own corners.
     */
    internal fun cardCorners(): surf.comma.android.ui.kit.CornerRadii {
        val radius = activity.dp(CARD_RADIUS_DP).toFloat()
        val cap = surf.comma.android.ui.kit.DisplayCorners.Companion::cap
        return surf.comma.android.ui.kit.CornerRadii(0f, 0f, cap(radius, displayCorners.bottomRight), cap(radius, displayCorners.bottomLeft))
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
    fun release() {
        surf.comma.android.miniapps.MiniAppRuntimes.releaseDraftTarget(::insertIntoRouter)
        dock.release()
    }

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
        dock.browserViewer?.let { out.putString(STATE_TASK_BROWSER, it) }
        out.putBoolean(STATE_ROUTER_OPEN, routerOpen || launchRouter)
        settings.saveState(out)
    }

    /** Restores the selected page and the open Task's raised or minimized state. */
    fun restoreState(state: Bundle?) {
        state ?: return
        state.getString(STATE_TAB)?.let { name -> AppTab.entries.firstOrNull { it.name == name } }?.let(::showTab)
        restoreMinimized = state.getBoolean(STATE_DOCK_MINIMIZED)
        restoreBrowser = state.getString(STATE_TASK_BROWSER)
        launchRouter = state.getBoolean(STATE_ROUTER_OPEN, true)
        settings.restoreState(state)
        if (launchRouter && store.auth.conversationScope.value != null) {
            launchRouter = false
            showRouter(focus = false, animate = false)
        } else if (!launchRouter) {
            closeRouter()
            routerLayer.jumpClosed()
        }
    }

    // MARK: Search

    override fun openSearch() {
        if (search != null) return
        if (routerOpen) closeRouter()
        val layer = SearchLayer(this) {
            val current = search ?: return@SearchLayer
            search = null
            card.removeView(current)
        }
        search = layer
        card.addView(layer, card.indexOfChild(routerLayer), LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT).apply {
            bottomMargin = layerFoot()
        })
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
        markRepliesSeen()
        routerLayer.open(animate)
    }

    override fun insertIntoRouter(text: String) {
        openRouter(focus = false)
        router.fillDraft(text)
    }

    /**
     * Closes the router chat at once: from here on it takes no new touch and the circle under it opens it again.
     * A [release] from a gesture hands over how the shape was moving.
     */
    private fun closeRouter(release: RouterLayer.Release? = null) {
        if (!routerOpen) return
        routerOpen = false
        focusAfterOpening = false
        updateBack()
        router.dismissInput()
        markRepliesSeen()
        routerLayer.close(release)
    }

    /** The tab bar's circle in the router layer's coordinates. */
    private fun routerCircle(): android.graphics.RectF? {
        val location = IntArray(2)
        val (w, h) = tabBar.routerBounds(location)
        if (w <= 0 || h <= 0) return null
        val origin = IntArray(2).also(routerLayer::getLocationInWindow)
        val left = (location[0] - origin[0]).toFloat()
        val top = (location[1] - origin[1]).toFloat()
        return android.graphics.RectF(left, top, left + w, top + h)
    }

    /**
     * The router chat's corners at full size: the display's own, or 32dp where the system does not say; above a
     * docked Task its foot rounds as the app's card does ([cardCorners]).
     */
    private fun routerCorners(): surf.comma.android.ui.kit.CornerRadii {
        val fallback = activity.dp(ROUTER_FALLBACK_RADIUS_DP).toFloat()
        fun display(radius: Float) = if (radius.isFinite() && radius > 0f) radius else fallback
        val docked = footShare() > 0f
        val card = cardCorners()
        return surf.comma.android.ui.kit.CornerRadii(display(displayCorners.topLeft), display(displayCorners.topRight),
            if (docked) card.bottomRight else display(displayCorners.bottomRight),
            if (docked) card.bottomLeft else display(displayCorners.bottomLeft))
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

    /** The router chat's own remote browser: the browser of the participant working in the router conversation. */
    private fun openRouterBrowser(participant: String) {
        val calls = store.workspaceCalls() ?: return
        val conversation = routerRepository.state.value.conversationId ?: return
        surf.comma.android.remote.RemoteBrowserSheet(activity, surf.comma.android.remote.RemoteBrowser(calls, conversation, participant)).show()
    }

    private var taskLinkJob: Job? = null

    /**
     * A Task deep link (`<scheme>://task?...`): switches to the link's Workspace if it belongs
     * to the signed-in account, then opens the Task in the dock. Ignored otherwise.
     */
    fun openTaskLink(link: surf.comma.android.tasks.TaskDeepLink) {
        taskLinkJob?.cancel()
        taskLinkJob = activity.lifecycleScope.launch {
            val initialScope = store.auth.conversationScope.filterNotNull().first()
            val targetScope = if (initialScope.workspaceId == link.workspaceId && initialScope.groupId == link.groupId) {
                initialScope
            } else {
                val state = store.tasks.state.first {
                    it.workspaces.any { ws -> ws.id == link.workspaceId && ws.groupId == link.groupId } || it.listLoaded
                }
                if (!store.isCurrent(initialScope)) return@launch
                val workspace = state.workspaces.firstOrNull {
                    it.id == link.workspaceId && it.groupId == link.groupId
                } ?: return@launch
                if (!store.auth.switchWorkspace(workspace.id)) return@launch
                val switched = store.auth.conversationScope.first { scope ->
                    scope == null ||
                        scope.accountId != initialScope.accountId ||
                        (scope.workspaceId == link.workspaceId && scope.groupId == link.groupId)
                } ?: return@launch
                if (switched.accountId != initialScope.accountId) return@launch
                switched
            }
            if (!store.isCurrent(targetScope)) return@launch
            launchRouter = false
            closeRouter()
            search?.dismiss()
            store.openTask(link.taskId)
        }
    }

    /** A shared app link: Settings opens its page over the Apps list, above the router chat. */
    fun openMiniAppLink(token: String) {
        closeRouter()
        search?.dismiss()
        if (dock.isOpen) dock.minimize()
        showTab(AppTab.SETTINGS)
        apps.openShared(token)
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
        private const val STATE_TASK_BROWSER = "shell.taskBrowser"
        private const val CARD_RADIUS_DP = 28
        /** The share of a Task bar's room still on screen below which the app's foot starts to follow it down. */
        private const val FOOT_SETTLED = 0.95f
        private const val ROUTER_FALLBACK_RADIUS_DP = 32
    }
}
