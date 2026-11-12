package surf.comma.android.settings.desktop

import android.text.InputType
import androidx.core.view.isVisible
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.dp

/** Settings > Models: the Router's and new Tasks' models, and the Workspace's model accounts. */
internal class ModelsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_models, KEY) {
    private val model = scope?.let(::ModelsModel)
    private val router = activity.linkRow(activity.getString(R.string.ds_models_router), icon = R.drawable.ic_history_thinking) {
        model?.let { ctx.open(ModelSelectionPage(ctx, it, task = false)) }
    }
    private val tasks = activity.linkRow(activity.getString(R.string.ds_models_tasks), icon = R.drawable.ic_settings_sparkles) {
        model?.let { ctx.open(ModelSelectionPage(ctx, it, task = true)) }
    }
    private val defaults = SettingsSection(activity, activity.getString(R.string.ds_models_defaults)).add(router).add(tasks)
        .footer(activity.getString(R.string.ds_models_defaults_footer))
    private val accounts = SettingsSection(activity, activity.getString(R.string.ds_models_accounts))
    private val more = activity.actionRow(activity.getString(R.string.ds_load_more)) { scope?.launch("models.moreProfiles") }
    private val add = activity.actionRow(activity.getString(R.string.ds_models_add_account)) {
        model?.let { ctx.open(AddModelAccountPage(ctx, it)) }
    }

    init {
        layout.section(defaults, top = 0)
        layout.section(accounts)
        model?.follow()
        start { scope?.perform("models.refresh", workspaceParameter = false) }
    }

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.loaded
        defaults.isVisible = model.router != null
        router.value(model.title(model.routerSelection) ?: activity.getString(R.string.ds_models_default), chevron = true)
        tasks.value(model.title(model.taskSelection) ?: activity.getString(R.string.ds_models_default), chevron = true)
        val rows = model.profiles.mapNotNull { profile ->
            val id = profile.string("id") ?: return@mapNotNull null
            activity.linkRow(model.profileName(profile),
                activity.getString(if (profile.optBoolean("disabled")) R.string.ds_off else R.string.ds_on)) {
                ctx.open(ModelAccountPage(ctx, model, id))
            }
        }.toMutableList<android.view.View>()
        if (model.loaded && model.profiles.isEmpty()) rows += activity.infoRow(activity.getString(R.string.ds_models_no_accounts))
        if (model.moreProfiles) rows += more
        add.isEnabled = model.presets.isNotEmpty()
        rows += add
        accounts.fill(rows)
    }

    companion object { const val KEY = "models" }
}

/** The Router's or new Tasks' model, its thinking effort and the account that serves it. */
internal class ModelSelectionPage(ctx: SettingsContext, private val model: ModelsModel, private val task: Boolean) :
    WorkspacePage(ctx, if (task) R.string.ds_models_task_model else R.string.ds_models_router_model, "models.selection", model.scope) {
    private var selection = if (task) model.taskSelection else model.routerSelection
    private val modelRow = SettingsRow(activity, null, activity.getString(R.string.ds_models_model))
    private val effortRow = SettingsRow(activity, null, activity.getString(R.string.ds_models_effort))
    private val accountRow = SettingsRow(activity, null, activity.getString(R.string.ds_models_account))
    private val paid = SwitchRow(activity, activity.getString(R.string.ds_models_allow_paid)) {
        selection = selection.copy(allowPaid = it)
        render()
    }
    private val modelSection = SettingsSection(activity, activity.getString(R.string.ds_models_model)).add(modelRow).add(effortRow)
    private val accountSection = SettingsSection(activity, activity.getString(R.string.ds_models_account)).add(accountRow).add(paid.row)
        .footer(activity.getString(R.string.ds_models_allow_paid_footer))
    private val unserved = activity.noteRow(activity.getString(R.string.ds_models_unserved), R.color.token_text_error_primary)
    private val save = activity.inlineButton(activity.getString(R.string.settings_save)) {
        launch { if (model.saveSelection(selection, task)) ctx.back() }
    }

    init {
        layout.trailing.addView(save)
        layout.section(modelSection, top = 0)
        layout.section(accountSection)
        layout.section(unserved, top = 8)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        val offered = model.models.filter { it.serving.isNotEmpty() }
        val option = model.models.firstOrNull { it.id == selection.model }
        val options = mutableListOf<Pair<String, CharSequence>>("" to activity.getString(R.string.ds_models_default))
        offered.sortedWith(compareBy({ it.vendor }, { it.name })).forEach { options += it.id to listOf(it.vendor, it.name).filter(String::isNotEmpty).joinToString(" · ") }
        selection.model?.takeIf { id -> offered.none { it.id == id } }?.let { options += it to (model.title(selection) ?: it) }
        modelRow.choices(options, selection.model.orEmpty()) { id -> selection = selection.withModel(id.ifEmpty { null }); render() }
        modelRow.value(model.title(selection) ?: activity.getString(R.string.ds_models_default), chevron = true)
        effortRow.isVisible = option?.efforts?.isNotEmpty() == true
        effortRow.choices(listOf<Pair<String, CharSequence>>("" to activity.getString(R.string.ds_default)) + option?.efforts.orEmpty().map { it to it },
            selection.effort.orEmpty()) { selection = selection.copy(effort = it.ifEmpty { null }); render() }
        val catalog = selection.kind == "catalog"
        accountSection.isVisible = catalog
        val accounts = model.profiles.filter { option?.serving?.contains(it.string("id")) == true }
        accountRow.choices(listOf<Pair<String, CharSequence>>("" to activity.getString(R.string.ds_models_automatic)) +
            accounts.map { it.string("id").orEmpty() to model.profileName(it) }, selection.profile.orEmpty()) {
            selection = selection.copy(profile = it.ifEmpty { null }); render()
        }
        paid.set(selection.allowPaid)
        val noServer = catalog && option?.serving.isNullOrEmpty()
        unserved.isVisible = noServer
        val enabled = !model.scope.busy && model.scope.current && !noServer
        save.isEnabled = enabled
        save.alpha = if (enabled) 1f else 0.4f
    }
}

/** One model account: its status, name, usage or API key, and removal. */
internal class ModelAccountPage(ctx: SettingsContext, private val model: ModelsModel, private val profileId: String) :
    WorkspacePage(ctx, R.string.ds_models_account_title, "models.account", model.scope) {
    private val profile: JSONObject? get() = model.profiles.firstOrNull { it.string("id") == profileId }
    private val info = SettingsSection(activity, activity.getString(R.string.ds_models_account))
    private val enabled = SwitchRow(activity, activity.getString(R.string.ds_models_enabled)) { on ->
        scope?.launch("models.updateProfile", json("profile" to profileId, "disabled" to !on))
    }
    private var name = ""
    private val nameField = activity.fieldRow(activity.getString(R.string.ds_name)) { name = it; render() }
    private val saveName = activity.actionRow(activity.getString(R.string.ds_save_name)) {
        scope?.launch("models.updateProfile", json("profile" to profileId, "name" to name.trim()))
    }
    private val usage = SettingsSection(activity, activity.getString(R.string.ds_usage))
    private val refreshUsage = activity.actionRow(activity.getString(R.string.ds_models_refresh_usage)) {
        scope?.launch("models.refreshQuota", json("profile" to profileId))
    }
    private val reconnect = activity.actionRow(activity.getString(R.string.ds_reconnect_account)) {
        ctx.open(AddModelAccountPage(ctx, model, renewing = profile))
    }
    private val keySection = SettingsSection(activity, activity.getString(R.string.ds_api_key))
    private var apiKey = ""
    private val keyField = activity.fieldRow(activity.getString(R.string.ds_models_new_key),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD) { apiKey = it; render() }
    private val replaceKey = activity.actionRow(activity.getString(R.string.ds_models_replace_key)) {
        scope?.launch("models.updateProfile", json("profile" to profileId, "api_key" to apiKey)) { keyField.setText("") }
    }
    private val remove = SettingsSection(activity, null).add(activity.actionRow(activity.getString(R.string.ds_models_remove_account), destructive = true) {
        ConfirmDialog(activity, activity.getString(R.string.ds_models_remove_title), "", activity.getString(R.string.ds_models_remove_account),
            destructive = true) { scope?.launch("models.deleteProfile", json("profile" to profileId)) { ctx.back() } }.show()
    })

    init {
        nameField.setText(profile?.string("name").orEmpty())
        layout.section(info, top = 0)
        layout.section(usage)
        layout.section(keySection)
        layout.section(remove)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        val profile = profile
        listOf(info, usage, keySection, remove).forEach { it.isVisible = profile != null }
        if (profile == null) return
        val rows = mutableListOf<android.view.View>(activity.infoRow(activity.getString(R.string.ds_models_provider), model.providerName(profile.string("source").orEmpty())))
        profile.string("email")?.let { rows += activity.infoRow(activity.getString(R.string.settings_email), it) }
        rows += activity.infoRow(activity.getString(R.string.ds_status),
            activity.getString(if (profile.string("status") == "active") R.string.ds_connected else R.string.ds_needs_attention))
        enabled.set(!profile.optBoolean("disabled"))
        saveName.isEnabled = name.isNotBlank()
        rows += listOf(enabled.row, nameField, saveName)
        info.fill(rows)
        if (profile.optBoolean("subscription")) {
            keySection.isVisible = false
            usage.fill(profile.objects("meters").map { meter ->
                val window = meter.string("window")
                val label = activity.getString(if (window == "5h") R.string.ds_models_five_hour else R.string.ds_models_weekly)
                // A week one model has to itself (Claude's Fable) says whose.
                activity.infoRow(if (window == "model") "${meter.string("model").orEmpty()} · $label" else label,
                    activity.getString(R.string.ds_models_remaining, (meter.int("percent") ?: 0).toInt()))
            } + listOf(refreshUsage, reconnect))
        } else {
            usage.isVisible = false
            replaceKey.isEnabled = apiKey.isNotBlank()
            keySection.fill(listOfNotNull(profile.string("key_hint")?.let { activity.infoRow(activity.getString(R.string.ds_models_current_key), it) },
                keyField, replaceKey))
        }
    }

    override fun onClose() = keyField.setText("")
}

/**
 * Adds a model account: a subscription signed in through the browser (a device code or a pasted code), or an API
 * key. [renewing] signs an existing subscription account in again. Keys stay in the form until it is sent or closed.
 */
internal class AddModelAccountPage(ctx: SettingsContext, private val model: ModelsModel, private val renewing: JSONObject? = null) :
    WorkspacePage(ctx, R.string.ds_models_add_account, "models.add", model.scope) {
    private var presetId = renewing?.let { old -> model.presets.firstOrNull { it.string("subscriptionSource") == old.string("source") }?.string("id") }.orEmpty()
    private val preset get() = model.presets.firstOrNull { it.string("id") == presetId }
    private val needsEndpoint get() = preset?.optBoolean("baseUrl") == true || preset?.optJSONObject("discover") != null
    private var signIn: JSONObject? = null
    private var waiting = false
    private var name = ""
    private var apiKey = ""
    private var endpoint = ""
    private var code = ""
    private var wire = "responses"
    private val providerRow = SettingsRow(activity, null, activity.getString(R.string.ds_models_provider))
    private val providerSection = SettingsSection(activity, activity.getString(R.string.ds_models_provider)).add(providerRow)
    private val subscription = SettingsSection(activity, activity.getString(R.string.ds_models_subscription))
        .add(activity.actionRow(activity.getString(R.string.ds_models_sign_in_subscription)) { beginSignIn() })
    private val nameField = activity.fieldRow(activity.getString(R.string.ds_models_name_optional)) { name = it }
    private val keyField = activity.fieldRow(activity.getString(R.string.ds_api_key), InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD) { apiKey = it; render() }
    private val endpointField = activity.fieldRow(activity.getString(R.string.ds_models_endpoint), InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI) { endpoint = it; render() }
    private val protocolRow = SettingsRow(activity, null, activity.getString(R.string.ds_models_protocol))
    private val connect = activity.actionRow(activity.getString(R.string.ds_models_connect_account)) { launch { add() } }
    private val apiSection = SettingsSection(activity, activity.getString(R.string.ds_models_api_account))
    private val signInSection = SettingsSection(activity, activity.getString(R.string.ds_models_sign_in))
    private val codeField = activity.fieldRow(activity.getString(R.string.ds_models_authorization_code)) { code = it; render() }

    init {
        layout.section(signInSection, top = 0)
        layout.section(providerSection, top = 0)
        layout.section(subscription)
        layout.section(apiSection)
        loading.isVisible = false
        start()
    }

    private fun beginSignIn() {
        val source = preset?.string("subscriptionSource") ?: return
        val params = json("provider" to source)
        val id = renewing?.string("id")
        val version = renewing?.string("version")
        if (id != null && version != null) { params.put("account", id); params.put("version", version) }
        launch {
            val answer = scope?.perform("models.signIn.begin", params)?.json ?: return@launch
            signIn = answer
            render()
            if (answer.string("mode") == "device") answer.string("id")?.let { waitFor(it) }
        }
    }

    private suspend fun waitFor(attempt: String) {
        val scope = scope ?: return
        waiting = true
        render()
        try {
            scope.call("models.signIn.wait", json("attempt" to attempt))
            ctx.back()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            if (scope.current) scope.error = WorkspaceScope.describe(e)
        } finally {
            waiting = false
            if (signIn?.string("id") == attempt) render()
        }
    }

    private suspend fun add() {
        val preset = preset ?: return
        val params = json("source" to (preset.string("keySource") ?: preset.string("id") ?: "custom"))
        if (name.isNotEmpty()) params.put("name", name)
        if (apiKey.isNotEmpty()) params.put("api_key", apiKey)
        if (needsEndpoint) params.put("base_url", endpoint)
        preset.optJSONObject("discover")?.let { params.put("discover", true).put("protocol", it.string("protocol") ?: wire) }
        if (scope?.perform("models.createProfile", params) != null) { keyField.setText(""); ctx.back() }
    }

    override fun render() {
        super.render()
        val attempt = signIn
        signInSection.isVisible = attempt != null
        providerSection.isVisible = attempt == null
        if (attempt != null) {
            subscription.isVisible = false
            apiSection.isVisible = false
            val rows = mutableListOf<android.view.View>()
            attempt.string("user_code")?.let { rows += activity.textBlock(it, mono = true) }
            attempt.string("url")?.let { url -> rows += activity.actionRow(activity.getString(R.string.ds_continue_in_browser)) { activity.openLink(url) } }
            if (attempt.string("mode") != "device") {
                rows += codeField
                rows += activity.actionRow(activity.getString(R.string.ds_models_complete_sign_in)) {
                    scope?.launch("models.signIn.complete", json("attempt" to attempt.string("id").orEmpty(), "code" to code)) {
                        codeField.setText(""); ctx.back()
                    }
                }.apply { isEnabled = code.isNotEmpty() }
            } else if (waiting) rows += activity.noteRow(activity.getString(R.string.ds_models_waiting))
            rows += activity.actionRow(activity.getString(R.string.ds_models_other_provider)) { signIn = null; codeField.setText(""); render() }
            signInSection.fill(rows)
            return
        }
        providerRow.choices(listOf<Pair<String, CharSequence>>("" to activity.getString(R.string.ds_models_choose_provider)) +
            model.presets.map { it.string("id").orEmpty() to model.presetName(it) }, presetId) {
            presetId = it
            keyField.setText("")
            endpointField.setText("")
            render()
        }
        providerRow.isEnabled = renewing == null
        val preset = preset
        subscription.isVisible = preset?.string("subscriptionSource") != null
        val api = renewing == null && preset != null && (preset.string("keySource") != null || preset.optJSONObject("discover") != null)
        apiSection.isVisible = api
        if (api && preset != null) {
            val rows = mutableListOf<android.view.View>(nameField, keyField)
            if (needsEndpoint) rows += endpointField
            if (preset.optJSONObject("discover") != null) {
                protocolRow.choices(listOf("responses" to activity.getString(R.string.ds_models_responses),
                    "chat_completions" to activity.getString(R.string.ds_models_chat_completions), "anthropic" to "Anthropic"), wire) { wire = it; render() }
                rows += protocolRow
            }
            connect.isEnabled = !(apiKey.isEmpty() && !preset.optBoolean("keyOptional")) && !(needsEndpoint && endpoint.isEmpty())
            rows += connect
            apiSection.fill(rows)
        }
    }

    override fun onClose() {
        keyField.setText("")
        codeField.setText("")
    }
}

/** Settings > Router settings: the Router's name and reply style, and a link to its custom instructions. */
internal class RouterSettingsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_router_settings, KEY) {
    private val model = scope?.let(::RouterSettingsModel)
    private val nameField = activity.fieldRow(activity.getString(R.string.ds_name)) { model?.draftName = it; renderSave() }
    private val saveName = activity.actionRow(activity.getString(R.string.ds_save_name)) { launch { model?.rename() } }
    private val style = SettingsRow(activity, null, activity.getString(R.string.ds_router_reply_style))

    init {
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_models_router)).add(nameField).add(saveName), top = 0)
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_router_replies)).add(style))
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_router_system_prompt))
            .add(activity.linkRow(activity.getString(R.string.ds_router_instructions), icon = R.drawable.ic_settings_file) {
                model?.let { ctx.open(RouterInstructionsPage(ctx, it)) }
            }).footer(activity.getString(R.string.ds_router_instructions_footer)))
        model?.follow()
        start { model?.refresh() }
    }

    private fun renderSave() { saveName.isEnabled = model?.canRename == true }

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.loaded
        if (nameField.text.toString() != model.draftName) nameField.setText(model.draftName)
        renderSave()
        style.choices(listOf("default" to activity.getString(R.string.ds_default), "concise" to activity.getString(R.string.ds_router_concise)),
            model.style) { launch { model.setStyle(it) } }
        style.isEnabled = model.loaded
    }

    companion object { const val KEY = "router" }
}

/** The Router's custom instructions; a conflicting save keeps the edit and shows the latest saved text. */
internal class RouterInstructionsPage(ctx: SettingsContext, private val model: RouterSettingsModel) :
    WorkspacePage(ctx, R.string.ds_router_instructions, "router.instructions", model.scope) {
    private val editor = activity.fieldRow(activity.getString(R.string.ds_router_instructions), lines = 10) {
        model.instructions = it
        renderSave()
    }
    private val latest = activity.textBlock("")
    private val latestSection = SettingsSection(activity, activity.getString(R.string.ds_router_latest)).add(latest)
    private val editorSection = SettingsSection(activity, activity.getString(R.string.ds_router_instructions)).add(editor)
    private val reset = SettingsSection(activity, null).add(activity.actionRow(activity.getString(R.string.ds_router_reset), destructive = true) {
        ConfirmDialog(activity, activity.getString(R.string.ds_router_reset_title), "", activity.getString(R.string.ds_router_reset),
            destructive = true) { launch { if (model.saveInstructions("")) editor.setText("") } }.show()
    })
    private val save = activity.inlineButton(activity.getString(R.string.settings_save)) {
        launch { if (model.saveInstructions(model.instructions)) ctx.back() }
    }

    init {
        layout.trailing.addView(save)
        layout.section(editorSection, top = 0)
        layout.section(latestSection)
        layout.section(reset)
        start { model.loadInstructions() }
        if (model.savedInstructions == null) launch { model.loadInstructions() }
    }

    private fun renderSave() {
        val enabled = model.savedInstructions != null && model.instructions != model.savedInstructions && !model.savingInstructions && model.scope.current
        save.isEnabled = enabled
        save.alpha = if (enabled) 1f else 0.4f
    }

    override fun render() {
        super.render()
        val ready = model.savedInstructions != null
        loading.isVisible = !ready && model.scope.error == null
        editorSection.isVisible = ready
        reset.isVisible = ready
        latestSection.isVisible = model.instructionsChanged
        latest.text = model.savedInstructions.orEmpty()
        if (ready && editor.text.toString() != model.instructions) editor.setText(model.instructions)
        editor.minHeight = activity.dp(240)
        renderSave()
    }
}
