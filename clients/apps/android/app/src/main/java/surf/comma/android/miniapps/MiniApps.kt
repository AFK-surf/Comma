package surf.comma.android.miniapps

import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.TextUtils
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.Workspace
import surf.comma.android.core.CoreApi
import surf.comma.android.settings.SettingsHost
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceStore

/** What the Apps pages can reach. */
internal interface MiniAppsContext {
    val activity: ComponentActivity
    val core: CoreApi?
    val store: WorkspaceStore
    fun open(page: SettingsPage)
    fun back()
    fun toast(text: String, failure: Boolean = true)
    /**
     * As on the desktop: [prompt], the start of a request to build an app, goes into the router chat's composer, which
     * opens with the keyboard up for the member to finish the sentence and send it. Nothing is sent.
     */
    fun newApp(prompt: String)
}

/**
 * Apps, a page of Settings › Comma: the current Workspace's own, shared and installed apps, their details, and shared
 * links, on Settings' own stack. The list follows its core topic only while it is on that stack. Another account or
 * Workspace takes the Apps pages off the stack: they belong to the Workspace they opened in.
 */
internal class MiniApps(private val settings: SettingsHost, override val store: WorkspaceStore) : MiniAppsContext {
    override val activity: ComponentActivity = settings.activity
    override val core: CoreApi? = AuthGraph.core(activity)
    private val auth = AuthGraph.get(activity)
    private var shownScope: Any? = null
    /** A shared link that arrived before there was a Workspace to open it in. */
    private var pendingToken: String? = null

    init {
        activity.lifecycleScope.launch {
            combine(auth.state, auth.conversationScope) { _, scope -> scope }.collect { scope ->
                if (scope !== shownScope) {
                    shownScope = scope
                    if (settings.host.pages().any(::isAppsPage)) settings.host.popToRoot()
                }
                pendingToken?.takeIf { workspace() != null }?.let {
                    pendingToken = null
                    openShared(it)
                }
            }
        }
    }

    private fun isAppsPage(page: SettingsPage) =
        page is MiniAppsListPage || page is MiniAppDetailPage || page is MiniAppSharedPage

    private fun workspace(): Workspace? = (auth.state.value as? AuthState.Connected)?.selection?.workspace

    /** Settings › Comma › Apps: the list, beside Settings' list in columns. */
    fun openList() {
        settings.openFromList(MiniAppsListPage(this, workspace()).also { it.setFollowing(true) })
    }

    /** A shared link: its page over the Apps list. */
    fun openShared(token: String) {
        if (workspace() == null) {
            pendingToken = token
            return
        }
        settings.host.popToRoot()
        openList()
        open(MiniAppSharedPage(this, token))
    }

    override fun open(page: SettingsPage) = settings.open(page)

    override fun back() = settings.back()

    override fun toast(text: String, failure: Boolean) = store.showToast(text, failure)

    /** Set by the shell, which owns the router chat. */
    var onNewApp: (String) -> Unit = {}

    override fun newApp(prompt: String) = onNewApp(prompt)
}

/** Current Workspace apps. The page follows one core topic and makes no request per row. */
internal class MiniAppsListPage(private val ctx: MiniAppsContext, val workspace: Workspace?) : SettingsPage {
    override val key = KEY
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.mini_apps_title), showBack = true) { ctx.back() }
    override val view: View = layout
    private val model = workspace?.let { ctx.core?.let { core -> MiniAppsModel(activity, core, it, MiniAppRuntimes.currentScope()) } }
    private val search = searchField()
    private val empty = EmptyStateView(activity)
    /** A failed refresh over apps already shown, above them in the list rather than over them. */
    private val failed = EmptyStateView(activity).apply { isVisible = false }
    private val cards = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private var following: Job? = null
    private var watching: Job? = null
    private var query = ""

    init {
        layout.section(search, top = 0)
        layout.section(failed, top = 8)
        layout.section(cards, top = 8)
        // As on iOS, the empty, loading and failed states sit in the middle of the page, over the list.
        layout.overlay(empty)
        if (model == null) {
            search.isVisible = false
            empty.show(R.drawable.ic_tab_apps, activity.getString(R.string.mini_apps_no_workspace),
                activity.getString(R.string.mini_apps_no_workspace_detail))
        } else render()
    }

    fun setFollowing(shown: Boolean) {
        val model = model ?: return
        if (!shown) {
            following?.cancel()
            following = null
            watching?.cancel()
            watching = null
            return
        }
        if (following != null) return
        following = activity.lifecycleScope.launch { activity.repeatOnLifecycle(Lifecycle.State.STARTED) { model.followList() } }
        watching = activity.lifecycleScope.launch {
            combine(model.state, MiniAppRuntimes.changes) { _, _ -> }.collect { render() }
        }
    }

    override fun onRemoved() = setFollowing(false)

    companion object { const val KEY = "apps" }

    private fun render() {
        val model = model ?: return
        val state = model.state.value
        val needle = query.trim()
        val shown = state.apps.filter { needle.isEmpty() || "${it.name} ${it.summary}".contains(needle, ignoreCase = true) }
        val retry = activity.getString(R.string.shell_retry) to { activity.lifecycleScope.launch { model.perform("miniApps.refresh") }; Unit }
        // A failure keeps the apps already loaded: it shows above them, and in the middle only when there are none.
        val failedOverApps = state.failure != null && state.apps.isNotEmpty()
        failed.isVisible = failedOverApps
        if (failedOverApps) failed.show(null, state.failure!!, null, retry)
        when {
            failedOverApps -> Unit
            state.failure != null -> empty.show(null, state.failure, null, retry)
            !state.loaded -> empty.show(null, activity.getString(R.string.mini_apps_loading))
            state.apps.isEmpty() -> empty.show(R.drawable.ic_tab_apps, activity.getString(R.string.mini_apps_empty),
                activity.getString(R.string.mini_apps_empty_detail),
                activity.getString(R.string.mini_apps_new) to { ctx.newApp(activity.getString(R.string.mini_apps_new_prompt)) },
                primary = true)
            shown.isEmpty() -> empty.show(R.drawable.ic_tab_search, activity.getString(R.string.mini_apps_no_results, needle))
        }
        empty.isVisible = !failedOverApps && (state.failure != null || !state.loaded || shown.isEmpty())
        // Search waits for apps to search.
        search.isVisible = state.apps.isNotEmpty()
        // Rows are few and bounded by the Workspace's apps; they are rebuilt from the one topic value.
        cards.removeAllViews()
        shown.forEachIndexed { index, app ->
            cards.addView(card(model, app), LinearLayout.LayoutParams(-1, -2).apply { if (index > 0) topMargin = activity.dp(16) })
        }
    }

    private fun card(model: MiniAppsModel, app: MiniAppRecord): View {
        val via = MiniAppVia.Workspace(model.workspace.id)
        val radius = activity.dp(24).toFloat()
        val card = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = roundRect(activity.color(R.color.token_card_primary), radius)
            clipToOutline = true
            isClickable = true
            contentDescription = app.name
            setOnClickListener { ctx.open(MiniAppDetailPage(ctx, model.workspace, app.id)) }
        }
        val cover = FrameLayout(activity)
        val image = ImageView(activity).apply { scaleType = ImageView.ScaleType.CENTER_CROP }
        MiniAppArtwork.show(image, ctx.core, app.coverUrl, via, placeholder = { image.setImageDrawable(null); image.setBackgroundColor(activity.color(R.color.token_bg_tertiary)) })
        cover.addView(image, FrameLayout.LayoutParams(-1, -1))
        // The title reads over any cover on a fade of the card's own surface.
        cover.addView(View(activity).apply {
            background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP,
                intArrayOf(activity.color(R.color.token_card_primary), android.graphics.Color.TRANSPARENT))
        }, FrameLayout.LayoutParams(-1, activity.dp(96), Gravity.BOTTOM))
        val identity = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(16), 0, activity.dp(16), activity.dp(12))
            addView(icon(app, via, 40), LinearLayout.LayoutParams(activity.dp(40), activity.dp(40)))
            addView(activity.text(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply {
                text = app.name.ifEmpty { activity.getString(R.string.mini_apps_app) }
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(12) })
        }
        cover.addView(identity, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
        card.addView(cover, LinearLayout.LayoutParams(-1, activity.dp(184)))
        val footer = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(16), activity.dp(12), activity.dp(16), activity.dp(16))
        }
        val texts = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        texts.addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply {
            text = app.summary.ifEmpty { app.author }
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            isVisible = text.isNotEmpty()
        })
        texts.addView(activity.text(Level.MINI, R.color.token_text_tertiary).apply { text = status(app) },
            LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(4) })
        footer.addView(texts, LinearLayout.LayoutParams(0, -2, 1f))
        footer.addView(runButton(activity, model, app), LinearLayout.LayoutParams(-2, activity.dp(40)).apply { marginStart = activity.dp(12) })
        card.addView(footer, LinearLayout.LayoutParams(-1, -2))
        return card
    }

    private fun icon(app: MiniAppRecord, via: MiniAppVia, size: Int) = miniAppIcon(activity, ctx.core, app.iconUrl, via, size)

    private fun status(app: MiniAppRecord): String {
        if (!app.active) return activity.getString(R.string.mini_apps_disabled)
        val version = app.runningVersion ?: return activity.getString(R.string.mini_apps_not_published)
        if (app.installed) return activity.getString(R.string.mini_apps_installed_version, version)
        return if (app.liveVersion == null) activity.getString(R.string.mini_apps_preview_version, version) else "v$version"
    }

    private fun searchField(): View = FrameLayout(activity).apply {
        addView(EditText(activity).apply {
            id = R.id.mini_app_search
            hint = activity.getString(R.string.mini_apps_search)
            setHintTextColor(activity.color(R.color.token_text_placeholder))
            setTextColor(activity.color(R.color.token_text_primary))
            surf.comma.android.ui.theme.DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.regular)
            background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(20).toFloat())
            setPadding(activity.dp(16), 0, activity.dp(16), 0)
            setSingleLine()
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    query = s?.toString().orEmpty()
                    render()
                }
            })
        }, FrameLayout.LayoutParams(-1, activity.dp(44)))
    }
}

/** An app's icon at [size] dp: its Version artwork, or the Apps glyph. */
internal fun miniAppIcon(activity: ComponentActivity, core: CoreApi?, url: String?, via: MiniAppVia, size: Int): ImageView =
    ImageView(activity).apply {
        val radius = activity.dp(if (size <= 40) 10 else (size * 0.22f).toInt()).toFloat()
        background = roundRect(activity.color(R.color.token_bg_secondary), radius)
        clipToOutline = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        MiniAppArtwork.show(this, core, url, via, placeholder = {
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setImageResource(R.drawable.ic_tab_apps)
            imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_tertiary))
            setPadding(activity.dp(size / 5), activity.dp(size / 5), activity.dp(size / 5), activity.dp(size / 5))
        }) { loaded ->
            if (loaded) {
                scaleType = ImageView.ScaleType.CENTER_CROP
                imageTintList = null
                setPadding(0, 0, 0, 0)
            }
        }
    }

/** Run, or Continue for a suspended run of the same app. */
internal fun runButton(activity: ComponentActivity, model: MiniAppsModel, app: MiniAppRecord): TextView {
    val continuing = MiniAppRuntimes.canContinue(model.workspace.id, app.id)
    return activity.filledButton(activity.getString(if (continuing) R.string.mini_apps_continue else R.string.mini_apps_run),
        R.color.token_bg_brand_solid, null).apply {
        id = R.id.mini_app_run
        background = roundRect(activity.color(R.color.token_bg_brand_solid), activity.dp(20).toFloat())
        setPadding(activity.dp(20), 0, activity.dp(20), 0)
        contentDescription = text.toString() + " " + app.name
        isEnabled = app.active && app.runningVersion != null && model.current
        alpha = if (isEnabled) 1f else 0.5f
        setOnClickListener { MiniAppRuntimes.run(activity, MiniAppTarget(model.workspace.id, app.id)) }
    }
}
