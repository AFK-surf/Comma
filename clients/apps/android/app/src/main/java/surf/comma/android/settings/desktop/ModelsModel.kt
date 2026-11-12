package surf.comma.android.settings.desktop

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.CoreError
import surf.comma.android.core.TopicValue

/** A model the catalog offers: its thinking efforts and the connected accounts ([serving]) that can run it. */
internal data class ModelOption(val id: String, val name: String, val vendor: String, val efforts: List<String>, val serving: List<String>) {
    companion object {
        fun parse(json: JSONObject): ModelOption? {
            val id = json.string("id") ?: return null
            val name = json.string("name") ?: return null
            return ModelOption(id, name, json.string("vendor").orEmpty(), json.strings("efforts"), json.strings("serving"))
        }
    }
}

/** The Router's or new Tasks' model: Comma's default ("builtin"), or a catalog model with its options. */
internal data class ModelSelection(
    val kind: String = "builtin",
    val model: String? = null,
    val effort: String? = null,
    val profile: String? = null,
    val allowPaid: Boolean = false,
) {
    val params: JSONObject
        get() = if (kind == "builtin" || model == null) json("kind" to "builtin")
        else json("kind" to kind, "model" to model, "reasoning_effort" to effort, "profile_id" to profile, "allow_paid" to allowPaid)

    /** Another model; its effort and account start over. */
    fun withModel(id: String?) = copy(kind = if (id == null) "builtin" else "catalog", model = id, effort = null, profile = null)

    companion object {
        fun parse(json: JSONObject?) = ModelSelection(json?.string("kind") ?: "builtin", json?.string("model"),
            json?.string("reasoning_effort"), json?.string("profile_id"), json?.optBoolean("allow_paid") == true)
    }
}

/** Settings > Models: the shared `models` topic of this Workspace, model accounts, and the Router and Task models. */
internal class ModelsModel(val scope: WorkspaceScope) {
    var value: JSONObject? = null
        private set
    var loaded = false
        private set

    val models get() = value?.objects("models").orEmpty().mapNotNull(ModelOption::parse)
    val profiles get() = value?.objects("profiles").orEmpty()
    val presets get() = value?.objects("presets").orEmpty()
    val router get() = value?.optJSONObject("agents")?.optJSONObject("agents")?.optJSONObject("router")
    val taskSelection get() = ModelSelection.parse(value?.optJSONObject("agents")?.optJSONObject("task_model")?.optJSONObject("selection"))
    val routerSelection get() = ModelSelection.parse(router?.optJSONObject("selection"))
    val moreProfiles get() = value?.optBoolean("moreProfiles") == true

    fun follow(): Job = scope.work.launch {
        scope.core.subscribe(json("topic" to "models", "prefer" to scope.workspaceId)) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> {
                    val next = update.value as? JSONObject ?: return@collect
                    if (next.string("workspace") != scope.workspaceId) {
                        if (next.optBoolean("error") || next.string("workspace") != null) {
                            loaded = true
                            scope.error = PageError.Text(R.string.ds_models_unavailable)
                        }
                        return@collect
                    }
                    value = next
                    loaded = next.optJSONObject("catalog") != null || next.optBoolean("error")
                    if (next.optBoolean("error")) scope.error = PageError.Text(R.string.ds_models_load_failed)
                    else scope.changed()
                }
                is TopicValue.Failed -> {
                    loaded = true
                    scope.error = WorkspaceScope.describe(update.error)
                }
            }
        }
    }

    /** The model's name, or "Comma default". Null means the default. */
    fun title(selection: ModelSelection): String? =
        if (selection.kind == "builtin" || selection.model == null) null
        else models.firstOrNull { it.id == selection.model }?.name ?: selection.model

    fun providerName(source: String): String =
        value?.optJSONObject("catalog")?.optJSONObject("sources")?.optJSONObject(source)?.string("name") ?: source

    fun presetName(preset: JSONObject): String = preset.string("name")
        ?: providerName(preset.string("keySource") ?: preset.string("subscriptionSource") ?: preset.string("id").orEmpty())

    fun profileName(profile: JSONObject): String =
        profile.string("name") ?: profile.string("email") ?: profile.string("source") ?: profile.string("id").orEmpty()

    suspend fun saveSelection(selection: ModelSelection, task: Boolean): Boolean {
        val params = json("selection" to selection.params)
        if (!task) params.put("agent", router?.string("agent_id") ?: return false)
        return scope.perform(if (task) "models.setTaskModel" else "models.setAgentModel", params) != null
    }
}

/** Settings > Router settings: the Router's name and reply style, and the Workspace's custom instructions. */
internal class RouterSettingsModel(val scope: WorkspaceScope) {
    var name = ""
        private set
    var style = "default"
        private set
    var loaded = false
        private set
    /** What the name field shows; it follows the server until the member edits it. */
    var draftName = ""
    var instructions = ""
    var savedInstructions: String? = null
        private set
    private var hash: String? = null
    /** The saved instructions changed on another device; the member's edit stays. */
    var instructionsChanged = false
        private set
    var savingInstructions = false
        private set

    fun follow(): Job = scope.work.launch {
        launch { refresh() }
        scope.core.subscribe(json("topic" to "router", "workspace" to scope.workspaceId, "read" to "settings")) { it }.collect { update ->
            if (!scope.current) return@collect
            when (update) {
                is TopicValue.Value -> (update.value as? JSONObject)?.let(::install)
                is TopicValue.Failed -> scope.error = WorkspaceScope.describe(update.error)
            }
        }
    }

    suspend fun refresh() {
        val next = scope.perform("router.refresh")?.json
        if (next != null) install(next)
        else if (scope.current && scope.error == null) scope.error = PageError.Text(R.string.ds_models_load_failed)
    }

    private fun install(json: JSONObject) {
        val next = json.string("name") ?: return
        val previous = name
        name = next
        if (!loaded || draftName == previous) draftName = next
        style = json.string("reply_style") ?: "default"
        loaded = true
        scope.changed()
    }

    suspend fun rename(): Boolean = scope.perform("models.renameAgent", json("name" to draftName.trim())) != null

    suspend fun setStyle(value: String) { scope.perform("models.setReplyStyle", json("style" to value)) }

    val canRename get() = loaded && draftName.trim().isNotEmpty() && draftName.length <= 40 && draftName != name

    suspend fun loadInstructions() {
        try {
            val json = scope.call("systemFiles.instructions", json("group" to scope.groupId), workspaceParameter = false) as? JSONObject
            val content = json?.optString("content")?.takeIf { json.has("content") } ?: return
            instructions = content
            savedInstructions = content
            hash = json.string("hash")
            scope.changed()
        } catch (_: CancellationException) {
        } catch (e: Exception) {
            if (scope.current) scope.error = WorkspaceScope.describe(e)
        }
    }

    /** Saves [content] over the version last read. A conflict keeps the member's edit and reads the latest. */
    suspend fun saveInstructions(content: String): Boolean {
        if (savedInstructions == null || !scope.current || scope.busy || savingInstructions) return false
        savingInstructions = true
        instructionsChanged = false
        scope.changed()
        try {
            val params = json("group" to scope.groupId, "content" to content)
            hash?.let { params.put("expectedHash", it) }
            val next = scope.call("systemFiles.writeInstructions", params, workspaceParameter = false) as? JSONObject ?: return false
            if (!next.has("content")) return false
            instructions = next.optString("content")
            savedInstructions = instructions
            hash = next.string("hash")
            return true
        } catch (_: CancellationException) {
            return false
        } catch (e: Exception) {
            if (!scope.current) return false
            if ((e as? CoreError)?.status == 409) {
                val draft = instructions
                loadInstructions()
                instructions = draft
                instructionsChanged = true
                scope.error = PageError.Text(R.string.ds_router_instructions_conflict)
            } else scope.error = WorkspaceScope.describe(e)
            return false
        } finally {
            savingInstructions = false
            scope.changed()
        }
    }
}
