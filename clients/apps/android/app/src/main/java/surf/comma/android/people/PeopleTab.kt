package surf.comma.android.people

import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.settings.PageHost
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsHost
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.workspace.WorkspaceStore

/**
 * The People tab: its own stack of pages, with everything else a page needs from Settings' host (the account, the
 * workspace scope, toasts). Another account or workspace starts it again from its list, which follows its topics only
 * while the tab is shown.
 */
internal class PeopleTab(private val settings: SettingsHost, val store: WorkspaceStore) : SettingsContext by settings {
    val host = PageHost(activity) {}.apply { keepsRoot = true }
    private var insetTop = 0
    private var insetBottom = 0
    private var root: PeopleListPage? = null
    private var shownScope: Any? = null

    var bottomReserve = 0
        set(value) {
            field = value
            host.pages().forEach(::inset)
        }

    var active: Boolean
        get() = host.active
        set(value) {
            host.active = value
            root?.setFollowing(value)
        }

    init {
        ViewCompat.setOnApplyWindowInsetsListener(host) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            insetTop = bars.top
            insetBottom = bars.bottom
            host.pages().forEach(::inset)
            insets
        }
        activity.onBackPressedDispatcher.addCallback(activity, host.backCallback)
        val auth = AuthGraph.get(activity)
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(auth.state, auth.conversationScope) { state, scope -> state to scope }.collect { (state, scope) ->
                    val workspace = (state as? AuthState.Connected)?.selection?.workspace
                    if (scope === shownScope && root != null && root?.workspaceId == workspace?.id) return@collect
                    shownScope = scope
                    rebuild()
                }
            }
        }
        activity.lifecycleScope.launch {
            activity.repeatOnLifecycle(Lifecycle.State.STARTED) {
                store.tasks.state.collect { host.render() }
            }
        }
    }

    private fun rebuild() {
        host.clear()
        root = PeopleListPage(this).also {
            inset(it)
            host.push(it, animate = false)
            it.setFollowing(active)
        }
    }

    /** A second press on People returns to the list, at its top. */
    fun reselected() {
        if (host.pages().size > 1) host.popToRoot() else root?.scrollToTop()
    }

    override fun open(page: SettingsPage) {
        inset(page)
        host.push(page)
    }

    override fun openFromList(page: SettingsPage) {
        if (host.columns) host.popToRoot()
        open(page)
    }

    override val shownBesideList: String? get() = if (host.columns) host.keys.getOrNull(1) else null

    override fun back() = host.pop()

    override fun onRender(page: SettingsPage, render: () -> Unit) = host.onRender(page, render)

    override fun openTask(id: String) = store.openTask(id)

    /** Opens a Collaborative Task another person hosts, through the host's Group. */
    fun openMemberTask(id: String, group: String) = store.openTask(id, group)

    private fun inset(page: SettingsPage) {
        (page.view as? SettingsPageLayout)?.applyInsets(insetTop, insetBottom + bottomReserve)
    }
}
