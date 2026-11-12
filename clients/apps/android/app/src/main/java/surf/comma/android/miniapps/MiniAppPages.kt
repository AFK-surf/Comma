package surf.comma.android.miniapps

import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.auth.AuthState
import surf.comma.android.auth.Workspace
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.ChoiceMenu
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.SettingsSwitch
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/** Screenshots of a Version, side by side, read through the core like every other artwork. */
internal fun miniAppScreenshots(ctx: MiniAppsContext, urls: List<String>, via: MiniAppVia): View {
    val activity = ctx.activity
    val strip = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    urls.take(MiniAppRecord.MAX_SCREENSHOTS).forEach { url ->
        val image = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.FIT_START
            background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(16).toFloat())
            clipToOutline = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        MiniAppArtwork.show(image, ctx.core, url, via, placeholder = { image.setImageDrawable(null) })
        strip.addView(image, LinearLayout.LayoutParams(activity.dp(180), activity.dp(300)).apply { marginEnd = activity.dp(12) })
    }
    return ScrollContainer(activity).apply {
        orientation = ScrollContainer.HORIZONTAL
        contentDescription = activity.getString(R.string.mini_apps_screenshots)
        addView(strip)
    }
}

/**
 * An app's details: its cover, identity, Version facts and notes, screenshots and description, then its management.
 * Owners change access, create a share link, enable or disable it and make a ready Version live. Preview opens a
 * ready Version; Preview and publish lets the run screen offer Publish while the Version's build review matches.
 * Only the selected Version's build Task is followed.
 */
internal class MiniAppDetailPage(private val ctx: MiniAppsContext, workspace: Workspace, private val appId: String) : SettingsPage {
    override val key = "app:$appId"
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, "", showBack = true) { ctx.back() }
    override val view: View = layout
    private val model = MiniAppsModel(activity, ctx.core ?: throw CoreError("unavailable", "No client core"), workspace,
        MiniAppRuntimes.currentScope())
    private val via = MiniAppVia.Workspace(workspace.id)
    private val hero = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val about = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val manage = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private var selected: Int? = null
    private var shownHero: Pair<MiniAppRecord?, String?>? = null
    private val jobs = mutableListOf<Job>()
    private var reviewJob: Job? = null
    private var reviewed: String? = "unset"
    private var closed = false

    init {
        layout.section(hero, top = 0)
        layout.section(about, top = 16)
        layout.section(manage, top = 24)
        jobs += activity.lifecycleScope.launch { activity.repeatOnLifecycle(Lifecycle.State.STARTED) { model.followApp(appId) } }
        jobs += activity.lifecycleScope.launch {
            combine(model.state, MiniAppRuntimes.changes) { state, _ -> state }.collect { state ->
                if (closed) return@collect
                if (!model.current || state.missing) {
                    closed = true
                    if (state.missing) ctx.toast(activity.getString(R.string.mini_apps_unavailable_detail))
                    ctx.back()
                    return@collect
                }
                followReview()
                render()
            }
        }
    }

    override fun onRemoved() {
        jobs.forEach(Job::cancel)
        reviewJob?.cancel()
    }

    private fun chosen(): MiniAppVersionRecord? {
        val versions = model.state.value.versions
        return versions.firstOrNull { it.number == selected } ?: versions.maxByOrNull { it.number }
    }

    /** Follows the selected Version's build Task, and only it. */
    private fun followReview() {
        val conversation = chosen()?.conversationId
        if (conversation == reviewed) return
        reviewed = conversation
        reviewJob?.cancel()
        reviewJob = activity.lifecycleScope.launch { model.followReview(conversation) }
    }

    private fun render() {
        val state = model.state.value
        val app = state.app
        layout.titleView.text = app?.name.orEmpty()
        renderHero(app, state)
        about.removeAllViews()
        manage.removeAllViews()
        if (app == null) return
        renderAbout(app, state)
        renderManagement(app, state)
    }

    private fun renderHero(app: MiniAppRecord?, state: MiniAppsModel.State) {
        hero.removeAllViews()
        state.failure?.let { failure ->
            hero.addView(SettingsSection(activity, null).add(SettingsRow(activity, null, failure, R.color.token_text_error_primary)
                .onClick { activity.lifecycleScope.launch { model.perform("miniApp.refresh", JSONObject().put("app", appId)) } }),
                LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = activity.dp(16) })
        }
        if (app == null) {
            if (!state.loaded) hero.addView(activity.text(Level.REGULAR, R.color.token_text_secondary).apply {
                text = activity.getString(R.string.mini_apps_loading_app)
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(-1, activity.dp(120)))
            return
        }
        val cover = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(24).toFloat())
            clipToOutline = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        MiniAppArtwork.show(cover, ctx.core, app.coverUrl, via, placeholder = { cover.setImageDrawable(null) })
        hero.addView(cover, LinearLayout.LayoutParams(-1, activity.dp(200)))
        val identity = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        identity.addView(miniAppIcon(activity, ctx.core, app.iconUrl, via, 72), LinearLayout.LayoutParams(activity.dp(72), activity.dp(72)))
        val names = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        names.addView(activity.text(Level.TITLE3, R.color.token_text_primary, DesignFonts.semibold).apply {
            text = app.name.ifEmpty { activity.getString(R.string.mini_apps_app) }
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            isAccessibilityHeading = true
        })
        if (app.author.isNotEmpty()) names.addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply { text = app.author })
        identity.addView(names, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(16); marginEnd = activity.dp(12) })
        identity.addView(runButton(activity, model, app), LinearLayout.LayoutParams(-2, activity.dp(40)))
        hero.addView(identity, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(16) })
        val facts = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
        facts.addView(fact(R.string.mini_apps_fact_version, app.runningVersion?.let { "v$it" } ?: activity.getString(R.string.mini_apps_not_published)),
            LinearLayout.LayoutParams(0, -2, 1f))
        facts.addView(fact(R.string.mini_apps_fact_access, MiniAppVisibility.label(activity, app.visibility)), LinearLayout.LayoutParams(0, -2, 1f))
        facts.addView(fact(R.string.mini_apps_fact_status,
            activity.getString(if (app.active) R.string.mini_apps_active else R.string.mini_apps_disabled)), LinearLayout.LayoutParams(0, -2, 1f))
        hero.addView(facts, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }

    private fun fact(title: Int, value: String) = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        addView(activity.text(Level.MINI, R.color.token_text_tertiary).apply { text = activity.getString(title) })
        addView(activity.text(Level.SMALL, R.color.token_text_primary, DesignFonts.semibold).apply { text = value; maxLines = 2 })
    }

    private fun renderAbout(app: MiniAppRecord, state: MiniAppsModel.State) {
        state.versions.firstOrNull { it.number == app.runningVersion }?.takeIf { it.notes.isNotEmpty() }?.let { release ->
            about.addView(heading(activity.getString(R.string.mini_apps_whats_new), "v${release.number}"))
            about.addView(body(release.notes), LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = activity.dp(20) })
        }
        if (app.screenshotUrls.isNotEmpty()) {
            about.addView(heading(activity.getString(R.string.mini_apps_preview), null))
            about.addView(miniAppScreenshots(ctx, app.screenshotUrls, via), LinearLayout.LayoutParams(-1, activity.dp(300)).apply {
                bottomMargin = activity.dp(20)
            })
        }
        if (app.summary.isNotEmpty()) {
            about.addView(heading(activity.getString(R.string.mini_apps_about), null))
            about.addView(body(app.summary))
        }
    }

    private fun heading(title: String, trailing: String?) = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        setPadding(0, 0, 0, activity.dp(8))
        addView(activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
            text = title
            isAccessibilityHeading = true
        }, LinearLayout.LayoutParams(0, -2, 1f))
        if (trailing != null) addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply { text = trailing })
    }

    private fun body(text: String) = activity.text(Level.SMALL, R.color.token_text_primary).apply {
        this.text = text
        setTextIsSelectable(true)
    }

    private fun renderManagement(app: MiniAppRecord, state: MiniAppsModel.State) {
        val owner = model.owner
        val busy = state.busy
        if (owner) {
            val access = SettingsSection(activity, activity.getString(R.string.mini_apps_access_title))
            access.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_access_who))
                .value(MiniAppVisibility.label(activity, app.visibility), chevron = true)
                .onClick { row ->
                    ChoiceMenu.show(row, MiniAppVisibility.values.map { MiniAppVisibility.label(activity, it) },
                        MiniAppVisibility.values.indexOf(app.visibility)) { index ->
                        act("miniApps.update", JSONObject().put("visibility", MiniAppVisibility.values[index]), refresh = true)
                    }
                })
            if (app.visibility == "link") {
                val link = state.linkUrl
                access.add(if (link != null) SettingsRow(activity, null, link).apply { title.setTextIsSelectable(true) }
                else SettingsRow(activity, null, activity.getString(R.string.mini_apps_create_link), R.color.token_bg_brand_solid)
                    .onClick { act("miniApps.link.publish") })
            }
            add(access)
        }
        if (state.versions.isNotEmpty()) {
            val version = chosen()
            val versions = SettingsSection(activity, activity.getString(R.string.mini_apps_versions))
            val sorted = state.versions.sortedByDescending { it.number }
            versions.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_version))
                .value(version?.let(::versionLabel), chevron = true)
                .onClick { row ->
                    ChoiceMenu.show(row, sorted.map(::versionLabel), sorted.indexOf(version)) { index ->
                        selected = sorted[index].number
                        followReview()
                        render()
                    }
                })
            if (version != null) {
                if (version.notes.isNotEmpty()) versions.add(SettingsRow(activity, null, version.notes))
                version.commit?.let { versions.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_commit)).value(it.take(7))) }
                if (version.state == "ready" && app.active) {
                    val publication = model.publication(version)
                    versions.add(SettingsRow(activity, null, activity.getString(
                        if (publication == null) R.string.mini_apps_preview_version_action else R.string.mini_apps_preview_publish),
                        R.color.token_bg_brand_solid).value(null, chevron = true).onClick {
                        MiniAppRuntimes.run(activity, MiniAppTarget(model.workspace.id, appId, version.number,
                            conversationId = publication?.conversationId))
                    })
                    if (owner && !version.live) versions.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_make_live),
                        R.color.token_bg_brand_solid).onClick {
                        ConfirmDialog(activity, activity.getString(R.string.mini_apps_make_live_title),
                            activity.getString(R.string.mini_apps_make_live_message, version.number),
                            activity.getString(R.string.mini_apps_make_live_confirm, version.number), destructive = false) {
                            act("miniApps.rollback", JSONObject().put("version", version.number))
                        }.show()
                    })
                }
                version.conversationId?.let { task ->
                    versions.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_open_build), R.color.token_bg_brand_solid)
                        .value(null, chevron = true).onClick { ctx.store.openTask(task) })
                }
            }
            add(versions)
        }
        if (owner) {
            add(SettingsSection(activity, activity.getString(R.string.mini_apps_manage)).add(
                SettingsRow(activity, null, activity.getString(if (app.active) R.string.mini_apps_disable else R.string.mini_apps_enable),
                    R.color.token_bg_brand_solid).onClick { act(if (app.active) "miniApps.disable" else "miniApps.enable") }))
        } else if (app.installed) {
            add(SettingsSection(activity, activity.getString(R.string.mini_apps_manage))
                .add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_updates))
                    .value(app.pinnedVersion?.let { "v$it" } ?: activity.getString(R.string.mini_apps_follows_live)))
                .add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_uninstall), R.color.token_fg_error).onClick {
                    ConfirmDialog(activity, activity.getString(R.string.mini_apps_uninstall_title),
                        activity.getString(R.string.mini_apps_uninstall_message, model.workspace.name),
                        activity.getString(R.string.mini_apps_uninstall_confirm), destructive = true) {
                        activity.lifecycleScope.launch { if (model.perform("miniApps.uninstall", JSONObject().put("app", appId))) ctx.back() }
                    }.show()
                }))
        }
        for (index in 0 until manage.childCount) manage.getChildAt(index).isEnabled = !busy
    }

    private fun add(section: View) {
        manage.addView(section, LinearLayout.LayoutParams(-1, -2).apply { if (manage.childCount > 0) topMargin = activity.dp(24) })
    }

    private fun versionLabel(version: MiniAppVersionRecord) = if (version.live) activity.getString(R.string.mini_apps_version_live, version.number)
    else activity.getString(R.string.mini_apps_version_state, version.number, activity.getString(when (version.state) {
        "ready" -> R.string.mini_apps_state_ready
        "uploading" -> R.string.mini_apps_state_uploading
        else -> R.string.mini_apps_state_failed
    }))

    private fun act(operation: String, params: JSONObject = JSONObject(), refresh: Boolean = false) {
        activity.lifecycleScope.launch {
            if (model.perform(operation, params.put("app", appId)) && refresh) model.perform("miniApp.refresh", JSONObject().put("app", appId))
        }
    }
}

/**
 * A public link's page. The link resolves through the core and never creates an Install until the member chooses a
 * Workspace and confirms. At most the selected Workspace's Install is followed, through one `miniApp` topic. The
 * shared run uses the link's access path; Open workspace app uses the Install.
 */
internal class MiniAppSharedPage(private val ctx: MiniAppsContext, private val token: String) : SettingsPage {
    override val key = "shared"
    private val activity = ctx.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.mini_apps_shared_title)) { ctx.back() }
    override val view: View = layout
    private val core = ctx.core
    private val auth = AuthGraph.get(activity)
    private val opened = MiniAppRuntimes.currentScope()
    private val via = MiniAppVia.Link(token)
    private val top = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val install = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private var app: MiniAppRecord? = null
    private var version: Int? = null
    private var loading = false
    private var failure: String? = null
    private var busy = false
    private var workspaceId: String? = (auth.state.value as? AuthState.Connected)?.selection?.workspace?.id
    private var installation: MiniAppRecord? = null
    private var installationKnown = false
    private var installationFailure: String? = null
    private var followLive = true
    private var installJob: Job? = null
    private val jobs = mutableListOf<Job>()

    private val current get() = MiniAppRuntimes.isCurrent(opened, activity)
    private val workspaces: List<Workspace> get() = ctx.store.tasks.state.value.workspaces
    private val ownsApp get() = app != null && app?.workspaceId == workspaceId

    init {
        layout.section(top, top = 0)
        layout.section(install, top = 24)
        jobs += activity.lifecycleScope.launch { resolve() }
        jobs += activity.lifecycleScope.launch {
            combine(MiniAppRuntimes.changes, ctx.store.tasks.state.map { it.workspaces }.distinctUntilChanged()) { _, _ -> }.collect {
                if (current) render()
            }
        }
    }

    override fun onRemoved() {
        jobs.forEach(Job::cancel)
        installJob?.cancel()
    }

    private suspend fun resolve() {
        val core = core ?: return
        if (!current || loading) return
        loading = true
        failure = null
        app = null
        render()
        try {
            val resolved = core.call("miniApps.link.resolve", JSONObject().put("token", token)) as? JSONObject
            if (!current) return
            app = MiniAppRecord.parse(resolved?.optJSONObject("app"))
            version = resolved?.number("version")
            if (app == null || version == null) failure = activity.getString(R.string.mini_apps_shared_failed)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            failure = activity.getString(if ((error as? CoreError)?.status == 404) R.string.mini_apps_shared_revoked else R.string.mini_apps_shared_failed)
        } finally {
            loading = false
        }
        followInstallation()
        render()
    }

    private fun selectWorkspace(id: String?) {
        workspaceId = id
        followLive = true
        followInstallation()
        render()
    }

    /** Follows the chosen Workspace's Install of the app, with no per-Workspace scan or polling. */
    private fun followInstallation() {
        installJob?.cancel()
        installation = null
        installationKnown = false
        installationFailure = null
        val workspace = workspaceId ?: return
        val app = app ?: return
        val core = core ?: return
        if (app.workspaceId == workspace) {
            installationKnown = true
            return
        }
        installJob = activity.lifecycleScope.launch {
            core.subscribe(JSONObject().put("topic", "miniApp").put("workspace", workspace).put("app", app.id)) { it as? JSONObject }.collect { value ->
                if (!current || workspaceId != workspace) return@collect
                when (value) {
                    is TopicValue.Value -> when (value.value?.optString("status")) {
                        "ready" -> {
                            installation = MiniAppRecord.parse(value.value?.optJSONObject("app"))
                            installationKnown = true
                        }
                        "missing" -> {
                            installation = null
                            installationKnown = true
                        }
                        "failed" -> installationFailure = activity.getString(R.string.mini_apps_installation_failed)
                    }
                    is TopicValue.Failed -> installationFailure = activity.getString(R.string.mini_apps_installation_failed)
                }
                render()
            }
        }
    }

    private val canInstall get() = current && app != null && !ownsApp && !busy && installationKnown &&
        installation?.installed != true && workspaces.any { it.id == workspaceId }

    private fun install() {
        val core = core ?: return
        val workspace = workspaceId ?: return
        if (!canInstall) return
        busy = true
        failure = null
        render()
        activity.lifecycleScope.launch {
            val params = JSONObject().put("workspace", workspace).put("token", token)
            if (!followLive) version?.let { params.put("pinnedVersion", it) }
            try {
                val added = core.call("miniApps.install", params) as? JSONObject
                if (current && workspaceId == workspace) {
                    installation = MiniAppRecord.parse(added)
                    installationKnown = true
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (current) failure = activity.getString(R.string.mini_apps_install_failed)
            } finally {
                busy = false
                render()
            }
        }
    }

    private fun uninstall() {
        val core = core ?: return
        val workspace = workspaceId ?: return
        val app = app ?: return
        if (!current || busy || ownsApp || installation?.installed != true) return
        busy = true
        failure = null
        render()
        activity.lifecycleScope.launch {
            try {
                core.call("miniApps.uninstall", JSONObject().put("workspace", workspace).put("app", app.id))
                if (current && workspaceId == workspace) {
                    MiniAppRuntimes.close(workspace, app.id)
                    installation = null
                    installationKnown = true
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (current) failure = activity.getString(R.string.mini_apps_uninstall_failed)
            } finally {
                busy = false
                render()
            }
        }
    }

    private fun sharedTarget(): MiniAppTarget? {
        val app = app ?: return null
        val workspace = (auth.state.value as? AuthState.Connected)?.selection?.workspace?.id ?: return null
        return MiniAppTarget(workspace, app.id, shareToken = token)
    }

    private fun installedTarget(): MiniAppTarget? {
        val app = app ?: return null
        val workspace = workspaceId ?: return null
        if (!ownsApp && installation?.installed != true) return null
        return MiniAppTarget(workspace, app.id)
    }

    private fun render() {
        top.removeAllViews()
        install.removeAllViews()
        failure?.let { text ->
            top.addView(SettingsSection(activity, null).add(SettingsRow(activity, null, text, R.color.token_text_error_primary)
                .onClick { activity.lifecycleScope.launch { resolve() } }), LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = activity.dp(16) })
        }
        val app = app
        if (app == null) {
            if (loading) top.addView(activity.text(Level.REGULAR, R.color.token_text_secondary).apply {
                text = activity.getString(R.string.mini_apps_shared_loading)
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(-1, activity.dp(120)))
            return
        }
        val identity = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
            addView(miniAppIcon(activity, core, app.iconUrl, via, 40), LinearLayout.LayoutParams(activity.dp(40), activity.dp(40)))
            addView(activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
                text = app.name.ifEmpty { activity.getString(R.string.mini_apps_app) }
                maxLines = 2
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(12) })
            addView(activity.text(Level.REGULAR, R.color.token_text_tertiary).apply { text = "v${version ?: 0}" })
        }
        val section = SettingsSection(activity, null).add(identity)
        if (app.summary.isNotEmpty()) section.add(SettingsRow(activity, null, app.summary).apply { title.maxLines = 6 })
        if (app.author.isNotEmpty()) section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_by, app.author)))
        val continuing = sharedTarget()?.let(MiniAppRuntimes::retained)?.isSuspended == true
        section.add(SettingsRow(activity, null, activity.getString(if (continuing) R.string.mini_apps_continue else R.string.mini_apps_run_shared),
            R.color.token_bg_brand_solid).value(null, chevron = true).onClick { sharedTarget()?.let { MiniAppRuntimes.run(activity, it) } })
        top.addView(section)
        if (app.screenshotUrls.isNotEmpty()) top.addView(miniAppScreenshots(ctx, app.screenshotUrls, via),
            LinearLayout.LayoutParams(-1, activity.dp(300)).apply { topMargin = activity.dp(16) })
        renderInstall(app)
    }

    private fun renderInstall(app: MiniAppRecord) {
        val section = SettingsSection(activity, activity.getString(R.string.mini_apps_install_title))
        install.addView(section)
        if (workspaces.isEmpty()) {
            section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_install_no_workspace)))
            return
        }
        val chosen = workspaces.firstOrNull { it.id == workspaceId }
        section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_workspace))
            .value(chosen?.name?.ifEmpty { activity.getString(R.string.mini_apps_untitled_workspace) }
                ?: activity.getString(R.string.mini_apps_choose_workspace), chevron = true)
            .onClick { row ->
                ChoiceMenu.show(row, workspaces.map { it.name.ifEmpty { activity.getString(R.string.mini_apps_untitled_workspace) } },
                    workspaces.indexOfFirst { it.id == workspaceId }) { index -> selectWorkspace(workspaces[index].id) }
            })
        val installed = installation?.takeIf { it.installed }
        when {
            ownsApp -> {
                section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_owned)))
                section.add(openInstalled())
            }
            installed != null -> {
                section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_installed))
                    .value(installed.pinnedVersion?.let { "v$it" } ?: activity.getString(R.string.mini_apps_follows_live)))
                section.add(openInstalled())
                section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_uninstall), R.color.token_fg_error).onClick {
                    ConfirmDialog(activity, activity.getString(R.string.mini_apps_uninstall_title),
                        activity.getString(R.string.mini_apps_uninstall_shared_message),
                        activity.getString(R.string.mini_apps_uninstall_confirm), destructive = true) { uninstall() }.show()
                })
            }
            installationFailure != null -> section.add(SettingsRow(activity, null, installationFailure!!, R.color.token_text_error_primary)
                .onClick { followInstallation(); render() })
            workspaceId != null && !installationKnown -> section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_checking)))
            workspaceId != null -> {
                val toggle = SettingsSwitch(activity).apply { set(followLive, animate = false) }
                section.add(SettingsRow(activity, null, activity.getString(R.string.mini_apps_follow_live)).trailing(toggle).onClick {
                    followLive = !followLive
                    toggle.set(followLive)
                    render()
                })
                section.add(SettingsRow(activity, null, if (followLive) activity.getString(R.string.mini_apps_install)
                else activity.getString(R.string.mini_apps_install_version, version ?: 0), R.color.token_bg_brand_solid)
                    .apply { isEnabled = canInstall }.onClick { install() })
            }
        }
        if (busy) for (index in 0 until section.card.childCount) section.card.getChildAt(index).isEnabled = false
    }

    private fun openInstalled(): View {
        val continuing = installedTarget()?.let(MiniAppRuntimes::retained)?.isSuspended == true
        return SettingsRow(activity, null, activity.getString(if (continuing) R.string.mini_apps_continue else R.string.mini_apps_open_installed),
            R.color.token_bg_brand_solid).value(null, chevron = true).onClick { installedTarget()?.let { MiniAppRuntimes.run(activity, it) } }
    }
}
