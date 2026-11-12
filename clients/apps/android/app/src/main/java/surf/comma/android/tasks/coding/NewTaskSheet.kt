package surf.comma.android.tasks.coding

import android.content.res.ColorStateList
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.tasks.list.FlowLayout
import surf.comma.android.tasks.tools.ToolPage
import surf.comma.android.ui.widget.GlassSurface
import surf.comma.android.ui.widget.glassControl
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.Band
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.cutoutClearance
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.dpf
import surf.comma.android.ui.kit.glass
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceCalls

/**
 * New task, from the Home task list's plus: close, the environment capsule and the round create action in the header,
 * the instructions, then the repository, branch and model capsules. The create action stays off until the Task can
 * start; a made Task opens in the dock. The header keeps its controls clear of a camera cutout in a landscape edge.
 */
internal class NewTaskSheet(
    activity: ComponentActivity,
    private val calls: WorkspaceCalls,
    private val opened: (String) -> Unit,
) : CommaSheet(activity, null, Detent.MEDIUM) {
    private val form = NewTaskForm(calls, NewTaskForm.Labels(
        cloud = activity.getString(R.string.new_task_cloud), code = activity.getString(R.string.new_task_code),
        sandbox = activity.getString(R.string.coding_sandbox), defaultModel = activity.getString(R.string.new_task_default_model),
        modelsUnavailable = activity.getString(R.string.new_task_models_unavailable),
    ))
    private val environment = activity.label(Level.SMALL, R.color.token_text_primary, DesignFonts.medium).apply {
        compoundDrawablePadding = activity.dp(6)
        gravity = Gravity.CENTER
        minHeight = activity.dp(44)
        maxWidth = activity.dp(240)
        setPadding(activity.dp(14), 0, activity.dp(14), 0)
        val press = glassControl(R.color.token_card_primary)
        if (press == null) {
            glass(elevated = false)
            tactile(0.96f)
        } else setOnTouchListener { _, event -> press.track(event); false }
        contentDescription = activity.getString(R.string.new_task_run_in)
        setOnClickListener { environmentMenu(it) }
    }
    private val create = FrameLayout(activity).apply {
        contentDescription = activity.getString(R.string.new_task_create)
        addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_composer_arrow_up)
            imageTintList = ColorStateList.valueOf(android.graphics.Color.WHITE)
        }, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
        addView(ProgressBar(activity).apply { isVisible = false }, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
        val press = glassControl(R.color.token_card_primary, tint = R.color.token_glass_tint_brand)
        if (press == null) {
            background = rounded(activity.getColor(R.color.token_bg_brand_solid), activity.dpf(22f))
            tactile(0.92f)
        } else setOnTouchListener { _, event -> press.track(event); false }
        setOnClickListener { start() }
    }
    private val editor = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        setHint(R.string.new_task_prompt)
        contentDescription = activity.getString(R.string.new_task_instructions)
        gravity = Gravity.TOP or Gravity.START
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        background = null
        setPadding(activity.dp(20), activity.dp(8), activity.dp(20), activity.dp(8))
        doAfterTextChanged { form.text = it?.toString().orEmpty(); renderHeader() }
    }
    private val error = activity.label(Level.MINI, R.color.token_text_error_primary, lines = 0).apply { isVisible = false }
    private val retry = activity.label(Level.MINI, R.color.token_bg_brand_solid, DesignFonts.medium).apply {
        setText(R.string.task_tools_retry)
        setPadding(activity.dp(8), activity.dp(8), 0, activity.dp(8))
        setOnClickListener { reload() }
    }
    private val properties = FlowLayout(activity, activity.dp(8)).apply {
        setPadding(activity.dp(16), activity.dp(12), activity.dp(16), activity.dp(12))
    }
    private val jobs = mutableListOf<Job>()
    private var environmentJob: Job? = null
    private var loadedEnvironment: String? = null
    private var branchesFor: String? = null

    init {
        header.addView(environment, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, activity.dp(44), Gravity.CENTER))
        trailing.addView(create, FrameLayout.LayoutParams(activity.dp(44), activity.dp(44)))
        setContent(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(editor, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(activity.dp(16), 0, activity.dp(16), 0)
                addView(error, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                addView(retry)
            })
            addView(properties, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        })
        // The header's controls keep clear of a cutout that crosses their row, as in a landscape edge.
        ViewCompat.setOnApplyWindowInsetsListener(header) { view, insets ->
            view.post { clearCutouts() }
            insets
        }
        header.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> clearCutouts() }
        form.onChange = ::render
        jobs += activity.lifecycleScope.launch {
            calls.subscribe(JSONObject().put("topic", "models").put("prefer", calls.workspaceId)) { it as? JSONObject }.collect { form.modelsChanged(it) }
        }
        jobs += activity.lifecycleScope.launch {
            calls.subscribe(JSONObject().put("topic", "stations").put("workspace", calls.workspaceId)) { it as? JSONObject }.collect { form.stationsChanged(it) }
        }
        render()
    }

    override fun onShown() {
        editor.requestFocus()
    }

    override fun onRemoved() {
        jobs.forEach { it.cancel() }
        environmentJob?.cancel()
    }

    private fun clearCutouts() {
        val cutout = ViewCompat.getRootWindowInsets(header)?.displayCutout ?: run { header.setPadding(0, 0, 0, 0); return }
        val location = IntArray(2).also(header::getLocationInWindow)
        val band = Band(location[0], location[1], location[0] + header.width, location[1] + header.height)
        val cutouts = cutout.boundingRects.map { Band(it.left, it.top, it.right, it.bottom) }
        val (start, end) = cutoutClearance(band, cutouts, margin = activity.dp(16), spacing = activity.dp(8))
        if (header.paddingLeft != start || header.paddingRight != end) header.setPadding(start, 0, end, 0)
    }

    private fun reload() {
        activity.lifecycleScope.launch {
            runCatching { calls.call("models.refresh", JSONObject().put("workspace", calls.workspaceId)) }
            if (form.inCoding) form.loadRepos() else form.loadEnvironment()
        }
    }

    private fun render() {
        // What the environment needs is read once it is chosen.
        if (form.environmentId != loadedEnvironment && form.environmentId.isNotEmpty()) {
            loadedEnvironment = form.environmentId
            environmentJob?.cancel()
            environmentJob = activity.lifecycleScope.launch {
                form.loadEnvironment()
                if (form.inCoding && !form.reposLoaded) form.loadRepos()
            }
        }
        if (form.repoId != branchesFor) {
            branchesFor = form.repoId
            activity.lifecycleScope.launch { form.loadBranches() }
        }
        renderHeader()
        val message = form.error?.takeIf(String::isNotEmpty) ?: form.profilesError
        error.text = message
        error.isVisible = message != null
        retry.isVisible = message != null
        properties.removeAllViews()
        if (form.inCoding) {
            properties.addView(chip(form.repo?.id ?: activity.getString(R.string.coding_repository), R.drawable.provider_github, tint = false) {
                RepositoryPickerSheet(activity, RepositoryPicker(calls, form.repo)) { form.selectRepository(it) }.show()
            }.apply { contentDescription = activity.getString(R.string.coding_repository) })
            properties.addView(chip(form.branch.ifEmpty { form.repo?.base ?: activity.getString(R.string.new_task_default_branch) },
                R.drawable.ic_action_link, enabled = form.repo != null) { anchor -> branchMenu(anchor) }
                .apply { contentDescription = activity.getString(R.string.coding_base_branch) })
        }
        val modelTitle = if (form.inCloud) form.cloudModel?.name else form.run?.label
        val loading = !form.modelsLoaded || (!form.inCloud && !form.inSandbox && !form.profilesLoaded)
        properties.addView(chip(modelTitle ?: activity.getString(R.string.new_task_model), R.drawable.ic_media_file_code,
            loading = loading, enabled = if (form.inCloud) form.cloudModels.isNotEmpty() else form.runs.isNotEmpty()) { anchor -> modelMenu(anchor) }
            .apply { contentDescription = activity.getString(R.string.new_task_model_account) })
    }

    private fun renderHeader() {
        val name = form.environments.firstOrNull { it.id == form.environmentId }?.name ?: activity.getString(R.string.new_task_run_in)
        environment.text = name
        environment.stateDescription = name
        val enabled = form.canStart
        create.isEnabled = enabled
        val lit = enabled || form.starting
        val glass = create.background as? GlassSurface
        if (glass == null) {
            create.alpha = if (lit) 1f else 0.4f
        } else {
            // As an iOS prominent button: off, it is grey glass, not a faded blue.
            glass.setGlassTint(activity.getColor(if (lit) R.color.token_glass_tint_brand else R.color.token_glass_tint_off))
            (create.getChildAt(0) as ImageView).imageTintList =
                ColorStateList.valueOf(if (lit) android.graphics.Color.WHITE else activity.getColor(R.color.token_glass_icon_off))
        }
        create.getChildAt(0).isVisible = !form.starting
        create.getChildAt(1).isVisible = form.starting
    }

    private fun environmentMenu(anchor: View) {
        val menu = ActionMenu(activity)
        form.environments.forEach { item ->
            val title = if (item.online) item.name else activity.getString(R.string.task_offline, item.name)
            menu.item(title, enabled = item.online, checked = item.id == form.environmentId) { form.chooseEnvironment(item.id) }
        }
        menu.show(anchor)
    }

    private fun branchMenu(anchor: View) {
        val menu = ActionMenu(activity)
        menu.item(activity.getString(R.string.new_task_default_branch), checked = form.branch.isEmpty()) { form.branch = ""; render() }
        form.branches.forEach { name -> menu.item(name, checked = name == form.branch) { form.branch = name; render() } }
        if (form.moreBranches) menu.divider().item(activity.getString(R.string.new_task_more_branches)) {
            activity.lifecycleScope.launch { form.loadBranches(more = true) }
        }
        menu.show(anchor)
    }

    private fun modelMenu(anchor: View) {
        val menu = ActionMenu(activity)
        if (form.inCloud) form.cloudModels.forEach { option ->
            menu.item(option.name, checked = option.id == form.cloudModel?.id) { form.cloudModelId = option.id; render() }
        } else form.runs.forEach { run ->
            menu.item(run.label, checked = run.id == form.run?.id) { form.runId = run.id; render() }
        }
        menu.show(anchor)
    }

    private fun chip(title: String, icon: Int, tint: Boolean = true, loading: Boolean = false, enabled: Boolean = true,
                     act: (View) -> Unit): View = surf.comma.android.ui.widget.GlassCapsule(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = activity.dp(44)
        setPadding(activity.dp(12), 0, activity.dp(12), 0)
        glassOver(R.color.token_card_primary) { glass(elevated = false) }
        if (loading) addView(ProgressBar(activity), LinearLayout.LayoutParams(activity.dp(16), activity.dp(16)))
        else addView(ImageView(activity).apply {
            setImageResource(icon)
            if (tint) imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_primary))
        }, LinearLayout.LayoutParams(activity.dp(16), activity.dp(16)))
        addView(activity.label(Level.SMALL, R.color.token_text_primary, DesignFonts.medium).apply {
            text = title
            maxWidth = activity.dp(180)
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = activity.dp(6) })
        addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_chevron_down_small)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_text_primary))
        }, LinearLayout.LayoutParams(activity.dp(12), activity.dp(12)).apply { marginStart = activity.dp(4) })
        isEnabled = enabled
        alpha = if (enabled) 1f else 0.5f
        if (enabled) { tactile(0.96f); setOnClickListener { act(it) } }
    }

    private fun start() {
        if (!form.canStart) return
        activity.lifecycleScope.launch {
            val task = form.start() ?: return@launch
            dismiss()
            opened(task)
        }
    }
}

/**
 * Choosing a repository: the connected GitHub account and its organizations, filtered by name as the member types;
 * an owner opens its repositories, searched on the server within that owner. The choice stays here until Confirm.
 */
internal class RepositoryPickerSheet(
    activity: ComponentActivity,
    private val picker: RepositoryPicker,
    private val confirm: (CodingRepo) -> Unit,
) : CommaSheet(activity, activity.getString(R.string.coding_repository), Detent.LARGE) {
    private val page = ToolPage(activity)
    private val search = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        isSingleLine = true
        background = rounded(activity.getColor(R.color.token_bg_tertiary), activity.dpf(12f))
        setPadding(activity.dp(14), activity.dp(10), activity.dp(14), activity.dp(10))
        doAfterTextChanged { picker.type(it?.toString().orEmpty()) }
    }
    private val done = FrameLayout(activity).apply {
        contentDescription = activity.getString(R.string.new_task_confirm)
        background = rounded(activity.getColor(R.color.token_bg_brand_solid), activity.dpf(22f))
        addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_composer_check)
            imageTintList = ColorStateList.valueOf(android.graphics.Color.WHITE)
        }, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
        tactile(0.92f)
        setOnClickListener { picker.selected?.let { confirm(it); dismiss() } }
    }
    private var searching: Job? = null
    private var searchKey: String? = null

    init {
        trailing.addView(done, FrameLayout.LayoutParams(activity.dp(44), activity.dp(44)))
        setContent(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(search, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                marginStart = activity.dp(16); marginEnd = activity.dp(16); bottomMargin = activity.dp(8)
            })
            addView(page.view, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })
        picker.onChange = ::render
        render()
        activity.lifecycleScope.launch { picker.loadOwners() }
    }

    override fun onRemoved() {
        searching?.cancel()
        picker.onChange = {}
    }

    private fun render() {
        val owner = picker.owner
        search.hint = owner?.let { activity.getString(R.string.new_task_search_in, it.login) } ?: activity.getString(R.string.new_task_search_owners)
        val key = (owner?.id ?: "") + "\t" + picker.query
        if (owner != null && key != searchKey) {
            searchKey = key
            searching?.cancel()
            searching = activity.lifecycleScope.launch { picker.search() }
        } else if (owner == null) searchKey = null
        done.isEnabled = picker.selected != null
        done.alpha = if (picker.selected != null) 1f else 0.4f
        page.clear()
        val section = page.section()
        if (owner != null) {
            section.add(surf.comma.android.settings.SettingsRow(activity, R.drawable.ic_nav_chevron_down, activity.getString(R.string.new_task_organizations))
                .value(owner.login).onClick { picker.choose(null); search.setText("") }.apply { icon.rotation = 90f })
            picker.repos.forEach { repo -> section.add(repositoryRow(repo)) }
            if (picker.moreRepos && picker.error == null) page.action(section, activity.getString(R.string.task_files_load_more), enabled = !picker.loading) {
                activity.lifecycleScope.launch { picker.loadRepos(more = true) }
            }
            if (picker.limited) page.note(section, activity.getString(R.string.new_task_refine))
            if (picker.loaded && picker.repos.isEmpty() && picker.error == null) page.note(section, activity.getString(R.string.new_task_no_results))
        } else {
            picker.visibleOwners.forEach { item -> section.add(ownerRow(item)) }
            if (picker.moreOwners && picker.error == null) page.action(section, activity.getString(R.string.task_files_load_more), enabled = !picker.ownersLoading) {
                activity.lifecycleScope.launch { picker.loadOwners(more = true) }
            }
            if (picker.ownersLoaded && picker.visibleOwners.isEmpty() && picker.error == null) page.note(section, activity.getString(R.string.new_task_no_results))
        }
        val error = picker.error
        if (error != null) page.error(error) {
            activity.lifecycleScope.launch { if (picker.owner == null) picker.loadOwners(picker.moreOwners) else picker.loadRepos(picker.moreRepos) }
        } else if (picker.loading || picker.ownersLoading) page.progress()
    }

    private fun ownerRow(owner: RepositoryOwner): View {
        val avatar = ImageView(activity).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            val radius = if (owner.kind == "user") activity.dpf(16f) else activity.dpf(6f)
            background = rounded(activity.getColor(R.color.token_bg_quaternary), radius)
            clipToOutline = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val url = owner.avatarUrl
        val cached = url?.let(OwnerAvatars::cached)
        if (cached != null) avatar.setImageBitmap(cached)
        else if (url != null) activity.lifecycleScope.launch { OwnerAvatars.load(url, activity.dp(32))?.let(avatar::setImageBitmap) }
        return LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(56)
            setPadding(activity.dp(14), activity.dp(8), activity.dp(10), activity.dp(8))
            addView(avatar, LinearLayout.LayoutParams(activity.dp(32), activity.dp(32)))
            addView(activity.label(Level.REGULAR, R.color.token_text_primary).apply { text = owner.login },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = activity.dp(12) })
            addView(ImageView(activity).apply {
                setImageResource(R.drawable.ic_settings_chevron)
                imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_fg_quaternary))
            }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
            setOnClickListener { search.setText(""); picker.choose(owner) }
        }
    }

    private fun repositoryRow(repo: CodingRepo): View = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        minimumHeight = activity.dp(56)
        setPadding(activity.dp(14), activity.dp(8), activity.dp(14), activity.dp(8))
        addView(ImageView(activity).apply { setImageResource(R.drawable.provider_github) }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            addView(activity.label(Level.REGULAR, R.color.token_text_primary).apply { text = repo.name })
            addView(activity.label(Level.MINI, R.color.token_text_tertiary).apply { text = repo.owner })
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = activity.dp(12) })
        val chosen = picker.selected?.id == repo.id
        if (chosen) addView(ImageView(activity).apply {
            setImageResource(R.drawable.ic_composer_check)
            imageTintList = ColorStateList.valueOf(activity.getColor(R.color.token_bg_brand_solid))
        }, LinearLayout.LayoutParams(activity.dp(20), activity.dp(20)))
        isSelected = chosen
        setOnClickListener { picker.selected = repo; render() }
    }

}
