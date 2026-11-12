package surf.comma.android.settings.desktop

import android.app.DatePickerDialog
import android.content.res.ColorStateList
import android.text.InputType
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.core.view.isVisible
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.FieldDialog
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.SettingsSwitch
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.voice.CallController
import java.util.Calendar
import java.util.Locale

private fun android.content.Context.shortDate(millis: Long) =
    DateUtils.formatDateTime(this, millis, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_YEAR)

/**
 * Settings > Voice settings, in the desktop's order: phone numbers, calls, the voice agent's API keys, then status.
 * The key list shares the page's voice subscription. A created key's value is cleared when this page closes.
 */
internal class VoiceSettingsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_voice, KEY) {
    private val model = scope?.let { VoiceModel(it, MediaVoicePlayback()) }
    private val keys = model?.let { ApiKeysModel(it.feed, voice = true) }
    private val numbers = SettingsSection(activity, activity.getString(R.string.ds_voice_numbers))
    private val calls = SettingsSection(activity, activity.getString(R.string.ds_voice_calls))
    private val keyList = keys?.let { ApiKeysContent(ctx, it, embedded = true, open = ctx::open) }
    private val readiness = SettingsSection(activity, activity.getString(R.string.ds_voice_readiness))
    private var sheet: VoicePickerSheet? = null

    init {
        layout.section(numbers, top = 0)
        layout.section(calls)
        keyList?.sections?.forEach { layout.section(it) }
        layout.section(readiness)
        model?.feed?.follow()
        start { model?.refresh() }
    }

    override fun onClose() {
        model?.stop()
        keys?.clearSecret()
        sheet?.dismiss()
    }

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.feed.loaded
        val integration = model.integration
        val rows = mutableListOf<View>()
        when {
            model.feed.value?.optBoolean("integrationError") == true -> rows += activity.actionRow(activity.getString(R.string.ds_voice_unavailable)) {
                launch { model.refresh() }
            }
            integration == null -> rows += activity.noteRow(activity.getString(R.string.settings_devices_loading))
            else -> {
                val lines = integration.strings("lines")
                if (lines.isEmpty()) rows += activity.describedRow(activity.getString(R.string.ds_voice_no_line), activity.getString(R.string.ds_voice_no_line_description))
                lines.forEach { line ->
                    rows += activity.describedRow(activity.getString(R.string.ds_voice_line, line), activity.getString(R.string.ds_voice_line_description),
                        control = activity.inlineButton(activity.getString(R.string.ds_voice_add_number)) { ctx.open(VoiceVerificationPage(ctx, model, line)) })
                }
                integration.objects("numbers").forEach { number -> number.string("e164")?.let { rows += numberRow(model, number, it) } }
            }
        }
        numbers.fill(rows)
        calls.isVisible = integration != null
        if (integration != null) calls.fill(callRows(model, integration))
        keyList?.render()
        val status = integration?.optJSONObject("readiness")
        readiness.fill(listOf(if (status == null) activity.noteRow(activity.getString(R.string.settings_devices_loading)) else {
            val ready = status.optBoolean("ready")
            activity.describedRow(activity.getString(R.string.ds_voice_readiness_title), readinessDescription(status),
                activity.getString(if (ready) R.string.ds_voice_ready_status else R.string.ds_voice_not_ready_status),
                if (ready) R.color.token_fg_success else R.color.token_text_tertiary)
        }))
        sheet?.render()
    }

    private fun numberRow(model: VoiceModel, number: JSONObject, e164: String): View {
        val locked = number.string("status") == "locked"
        val parts = mutableListOf<String>()
        number.int("verified_at")?.let { parts += activity.getString(R.string.ds_voice_number_verified, activity.shortDate(it)) }
        val until = number.int("pin_locked_until")
        parts += if (locked && until != null) activity.getString(R.string.ds_voice_pin_locked,
            DateUtils.formatDateTime(activity, until, DateUtils.FORMAT_SHOW_TIME))
        else activity.getString(if (number.optBoolean("pin_set")) R.string.ds_voice_pin_set else R.string.ds_voice_pin_not_set)
        val more = activity.moreButton(activity.getString(R.string.ds_voice_number_actions, e164)) { anchor ->
            val pinSet = number.optBoolean("pin_set")
            ActionMenu(activity)
                .item(activity.getString(if (pinSet) R.string.ds_voice_change_pin else R.string.ds_voice_set_pin)) {
                    ctx.open(VoicePinPage(ctx, model, e164))
                }
                .apply { if (pinSet) item(activity.getString(R.string.ds_voice_clear_pin)) { model.scope.launch("voice.setPin", json("e164" to e164, "pin" to "")) } }
                .divider()
                .item(activity.getString(R.string.ds_voice_remove_number), destructive = true) {
                    ConfirmDialog(activity, activity.getString(R.string.ds_voice_remove_number_title), e164,
                        activity.getString(R.string.ds_voice_remove_number), destructive = true) {
                        model.scope.launch("voice.removeNumber", json("e164" to e164))
                    }.show()
                }
                .show(anchor)
        }
        return activity.describedRow(e164, parts.joinToString(" · "),
            activity.getString(if (locked) R.string.ds_voice_locked else R.string.ds_voice_verified),
            if (locked) R.color.token_text_error_primary else R.color.token_fg_success, more)
    }

    private fun callRows(model: VoiceModel, integration: JSONObject): List<View> {
        val custom = integration.optJSONObject("preferences")?.optJSONObject("custom_voice")
        val routerName = activity.getString(R.string.ds_voice_router_name)
        val voice = activity.inlineButton(voiceTitle(model.selectedOption())) { openPicker(model) }.apply {
            contentDescription = activity.getString(R.string.ds_voice_voice)
        }
        val routerCalls = SettingsSwitch(activity).apply {
            set(integration.optJSONObject("preferences")?.optBoolean("router_calls") == true, animate = false)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            setOnClickListener { model.scope.launch("voice.setPreferences", json("routerCalls" to !checked)) }
            contentDescription = activity.getString(R.string.ds_voice_router_calls, routerName)
        }
        return listOf(
            activity.describedRow(activity.getString(R.string.ds_voice_voice), activity.getString(R.string.ds_voice_voice_description), control = voice),
            activity.describedRow(activity.getString(R.string.ds_voice_custom), custom?.string("description") ?: activity.getString(R.string.ds_voice_custom_none),
                control = activity.inlineButton(activity.getString(if (custom == null) R.string.ds_voice_custom_create else R.string.ds_voice_custom_replace)) {
                    ctx.open(CustomVoicePage(ctx, model))
                }),
            activity.describedRow(activity.getString(R.string.ds_voice_router_calls, routerName),
                activity.getString(R.string.ds_voice_router_calls_description, routerName), control = routerCalls),
        )
    }

    private fun voiceTitle(option: VoiceOption?) = when {
        option == null -> activity.getString(R.string.ds_voice_default)
        option.title == null -> activity.getString(R.string.ds_voice_custom_default)
        else -> option.title
    }

    private fun readinessDescription(status: JSONObject) = activity.getString(when {
        status.optBoolean("ready") -> R.string.ds_voice_ready
        status.string("reason") == "disabled" -> R.string.ds_voice_not_ready_disabled
        status.string("reason") in setOf("not_configured", "twilio_not_configured", "no_platform_lines") -> R.string.ds_voice_not_ready_configured
        else -> R.string.ds_voice_not_ready_other
    })

    private fun openPicker(model: VoiceModel) {
        sheet?.dismiss()
        sheet = VoicePickerSheet(ctx, model) { sheet = null }.also { it.show() }
    }

    companion object { const val KEY = "voice" }
}

/**
 * The call voice, in a sheet: the default, the custom voice and the presets, each with its own sample button. A
 * sample never selects the voice; closing the sheet, leaving the app or a call starting stops it. A call disables
 * samples.
 */
internal class VoicePickerSheet(private val ctx: SettingsContext, private val model: VoiceModel, private val closed: () -> Unit) :
    CommaSheet(ctx.activity, ctx.activity.getString(R.string.ds_voice_voice), Detent.LARGE) {
    private val layout = SettingsPageLayout(activity, "", showBack = false) {}.apply {
        bar.isVisible = false
        setBackgroundColor(activity.getColor(R.color.token_card_primary))
    }
    private val defaults = SettingsSection(activity, null)
    private val custom = SettingsSection(activity, activity.getString(R.string.ds_voice_custom_default))
    private val presets = SettingsSection(activity, activity.getString(R.string.ds_voice_presets))
    private val failure = activity.noteRow(activity.getString(R.string.ds_voice_preview_failed), R.color.token_text_error_primary)
    private val calls = CallController.get(activity)
    private val callWatch: Job = activity.lifecycleScope.launch {
        calls.state.collect { if (it.busy) model.stop(); render() }
    }
    private val pause = object : DefaultLifecycleObserver {
        override fun onStop(owner: LifecycleOwner) = model.stop()
    }

    init {
        layout.section(defaults, top = 0)
        layout.section(custom)
        layout.section(presets)
        layout.section(failure, top = 8)
        setContent(layout)
        activity.lifecycle.addObserver(pause)
        render()
    }

    override fun onRemoved() {
        callWatch.cancel()
        activity.lifecycle.removeObserver(pause)
        model.stop()
        closed()
    }

    fun render() {
        val default = VoiceOption("", activity.getString(R.string.ds_voice_default), activity.getString(R.string.ds_voice_default_subtitle))
        defaults.fill(listOf(row(default)))
        val customVoice = model.customVoice
        custom.isVisible = customVoice != null
        custom.fill(listOfNotNull(customVoice?.let { row(it.copy(title = it.title ?: activity.getString(R.string.ds_voice_custom_default))) }))
        presets.fill(model.presetVoices.map(::row))
        failure.isVisible = model.previewFailed
    }

    private fun row(option: VoiceOption): View {
        val detail = option.detail ?: option.presetLocale?.let { locale ->
            val language = Locale.forLanguageTag(locale).getDisplayName(Locale.getDefault())
            activity.getString(if (option.female == true) R.string.ds_voice_female else R.string.ds_voice_male, language)
        }
        val chosen = model.selected == option.id
        val check = ImageView(activity).apply {
            setImageResource(R.drawable.ic_action_check)
            imageTintList = ColorStateList.valueOf(activity.color(R.color.token_bg_brand_solid))
            alpha = if (chosen) 1f else 0f
            layoutParams = LinearLayout.LayoutParams(activity.dp(24), activity.dp(24))
        }
        val choose = activity.describedRow(option.title.orEmpty(), detail, control = check).apply {
            isSelected = chosen
            PressFeedback(this, R.color.token_surface_ink, scale = false)
            setOnClickListener { model.scope.work.launch { if (model.select(option.id)) dismiss() } }
        }
        val preview = model.preview?.takeIf { it.voice == option.id }
        val play = FrameLayout(activity).apply {
            if (preview is VoicePreview.Loading) addView(ProgressBar(activity).apply {
                indeterminateTintList = ColorStateList.valueOf(activity.color(R.color.token_text_secondary))
            }, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
            else addView(ImageView(activity).apply {
                setImageResource(if (preview is VoicePreview.Playing) R.drawable.ic_media_pause else R.drawable.ic_media_play)
                imageTintList = ColorStateList.valueOf(activity.color(R.color.token_text_secondary))
            }, FrameLayout.LayoutParams(activity.dp(20), activity.dp(20), Gravity.CENTER))
            contentDescription = activity.getString(when (preview) {
                is VoicePreview.Playing -> R.string.ds_voice_preview_stop
                is VoicePreview.Loading -> R.string.ds_voice_preview_loading
                null -> R.string.ds_voice_preview_play
            }, option.title.orEmpty())
            isEnabled = !calls.state.value.busy
            alpha = if (isEnabled) 1f else 0.4f
            PressFeedback(this, R.color.token_bg_quaternary, scale = true)
            setOnClickListener { model.preview(option.id) }
        }
        return LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(choose, LinearLayout.LayoutParams(0, -2, 1f))
            addView(play, LinearLayout.LayoutParams(activity.dp(50), activity.dp(50)).apply { marginEnd = activity.dp(8) })
        }
    }
}

/** Verifies a caller number for [line] with a code sent to it. */
internal class VoiceVerificationPage(ctx: SettingsContext, private val model: VoiceModel, private val line: String) :
    WorkspacePage(ctx, R.string.ds_voice_add_number_title, "voice.number", model.scope) {
    private var number = ""
    private var code = ""
    private var sent = false
    private val numberField = activity.fieldRow(activity.getString(R.string.ds_phone_number), InputType.TYPE_CLASS_PHONE) { number = it.trim(); render() }
    private val codeField = activity.fieldRow(activity.getString(R.string.ds_verification_code), InputType.TYPE_CLASS_NUMBER) { code = it.trim(); render() }
    private val section = SettingsSection(activity, line).footer(activity.getString(R.string.ds_voice_add_number_description))

    init {
        layout.section(section, top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        numberField.isEnabled = !sent
        val params = { json("e164" to number, "line" to line) }
        section.fill(if (sent) listOf(numberField, codeField,
            activity.actionRow(activity.getString(R.string.ds_voice_verify_number)) {
                model.scope.launch("voice.checkCode", params().put("code", code)) { ctx.back() }
            }.apply { isEnabled = code.isNotEmpty() },
            activity.actionRow(activity.getString(R.string.ds_voice_other_number)) { sent = false; codeField.setText(""); render() })
        else listOf(numberField, activity.actionRow(activity.getString(R.string.ds_voice_send_code)) {
            model.scope.launch("voice.startVerification", params()) { sent = true; render() }
        }.apply { isEnabled = number.startsWith("+") }))
    }
}

/** Makes the Workspace's custom voice from a description and selects it. */
internal class CustomVoicePage(ctx: SettingsContext, private val model: VoiceModel) :
    WorkspacePage(ctx, R.string.ds_voice_custom_title, "voice.custom", model.scope) {
    private var name = ""
    private var description = ""
    private val create = activity.actionRow(activity.getString(R.string.ds_voice_custom_submit)) {
        model.scope.launch("voice.createCustomVoice", json("description" to description, "name" to name)) { ctx.back() }
    }

    init {
        layout.section(SettingsSection(activity, activity.getString(R.string.ds_voice_custom_default))
            .add(activity.fieldRow(activity.getString(R.string.ds_voice_custom_name)) { name = it })
            .add(activity.fieldRow(activity.getString(R.string.ds_voice_custom_describe), lines = 3) { description = it; render() })
            .add(create).footer(activity.getString(R.string.ds_voice_custom_footer)), top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        create.isEnabled = description.isNotBlank()
    }
}

/** Sets or clears a caller number's PIN; an empty PIN removes it. */
internal class VoicePinPage(ctx: SettingsContext, private val model: VoiceModel, number: String) :
    WorkspacePage(ctx, R.string.ds_voice_pin_title, "voice.pin", model.scope) {
    private var pin = ""

    init {
        val field = activity.fieldRow(activity.getString(R.string.ds_voice_new_pin), InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD) { pin = it }
        layout.section(SettingsSection(activity, number).add(field)
            .add(activity.actionRow(activity.getString(R.string.ds_voice_save_pin)) {
                model.scope.launch("voice.setPin", json("e164" to number, "pin" to pin)) { ctx.back() }
            }).footer(activity.getString(R.string.ds_voice_pin_footer)), top = 0)
        loading.isVisible = false
        start()
    }
}

/**
 * A Workspace's API keys as rows: the one-time value of a key just made, the keys with their menus, and (on its own
 * page) the creation form. [embedded] is Voice settings' inline list, whose page clears the value when it closes.
 */
internal class ApiKeysContent(
    private val ctx: SettingsContext,
    val model: ApiKeysModel,
    private val embedded: Boolean,
    private val open: (surf.comma.android.settings.SettingsPage) -> Unit,
) {
    private val activity = ctx.activity
    private val secret = SettingsSection(activity, activity.getString(R.string.ds_keys_copy_now)).footer(activity.getString(R.string.ds_keys_once))
    private val list = SettingsSection(activity, activity.getString(if (model.voice) R.string.ds_voice_keys else R.string.ds_keys))
    private val failed = activity.noteRow(activity.getString(R.string.ds_keys_load_failed), R.color.token_text_error_primary)
    val sections: List<View> = listOf(secret, list, failed)

    fun render() {
        val value = model.secret
        secret.isVisible = value != null
        if (value != null) secret.fill(listOf(activity.textBlock(value, mono = true),
            activity.actionRow(activity.getString(R.string.ds_keys_copy)) { activity.copySensitive(value) },
            activity.actionRow(activity.getString(R.string.ds_done)) { model.clearSecret() }))
        val rows = mutableListOf<View>()
        if (embedded) rows += activity.describedRow(activity.getString(R.string.ds_voice_keys_connect), activity.getString(R.string.ds_voice_keys_description),
            control = activity.inlineButton(activity.getString(R.string.ds_keys_new)) { model.clearSecret(); open(CreateKeyPage(ctx, model)) })
        model.keys.forEach { key -> key.string("key_id")?.let { rows += keyRow(key, it) } }
        val keysFailed = model.feed.value?.optBoolean("keysError") == true
        if (model.feed.loaded && model.keys.isEmpty() && !keysFailed) rows += activity.infoRow(activity.getString(R.string.ds_keys_none))
        if (!embedded) rows += activity.actionRow(activity.getString(R.string.ds_keys_create)) { model.clearSecret(); open(CreateKeyPage(ctx, model)) }
        list.fill(rows)
        failed.isVisible = model.voice && keysFailed
        failed.setOnClickListener { model.scope.launch("voice.refresh", workspaceParameter = false) }
    }

    private fun keyRow(key: JSONObject, id: String): View {
        val active = key.string("status") == "active"
        val name = key.string("name").orEmpty()
        val prefix = key.string("prefix").orEmpty().removeSuffix("…")
        val date = { seconds: Long? -> seconds?.let { activity.shortDate(it * 1000) } ?: "—" }
        val detail = activity.getString(R.string.ds_keys_details, prefix, date(key.int("created_at")), date(key.int("last_used_at")))
        val more = activity.moreButton(activity.getString(R.string.ds_keys_actions)) { anchor ->
            ActionMenu(activity)
                .item(activity.getString(R.string.ds_rename)) { rename(id, name) }
                .item(activity.getString(if (active) R.string.ds_keys_disable else R.string.ds_keys_enable)) { model.setActive(id, !active) }
                .divider()
                .item(activity.getString(R.string.ds_keys_delete), destructive = true) {
                    ConfirmDialog(activity, activity.getString(R.string.ds_keys_delete_title), name, activity.getString(R.string.ds_keys_delete),
                        destructive = true) { model.delete(id) }.show()
                }
                .show(anchor)
        }
        return activity.describedRow(name, detail, activity.getString(if (active) R.string.ds_active else R.string.ds_disabled),
            if (active) R.color.token_fg_success else R.color.token_text_tertiary, more)
    }

    private fun rename(id: String, current: String) {
        FieldDialog(activity, activity.getString(R.string.ds_keys_rename), activity.getString(R.string.ds_keys_name), current,
            activity.getString(R.string.settings_save), InputType.TYPE_CLASS_TEXT, 100, onSave = { model.rename(id, it) }, keyboard = true).show()
    }
}

/** Settings > Router API keys. */
internal class RouterKeysPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_router_keys, KEY) {
    private val model = scope?.let(ApiKeysModel::router)
    private val content = model?.let { ApiKeysContent(ctx, it, embedded = false, open = ctx::open) }

    init {
        content?.sections?.forEach { layout.section(it, top = 16) }
        model?.feed?.follow()
        start { scope?.perform("routerKeys.refresh", workspaceParameter = false) }
    }

    override fun onClose() { model?.clearSecret() }

    override fun render() {
        super.render()
        loading.isVisible = model?.feed?.loaded == false
        content?.render()
    }

    companion object { const val KEY = "routerKeys" }
}

/** A new API key's name, and for voice keys an optional expiry. The value shows once on the page it was made from. */
internal class CreateKeyPage(ctx: SettingsContext, private val model: ApiKeysModel) :
    WorkspacePage(ctx, R.string.ds_keys_create, "keys.create", model.scope) {
    private var name = ""
    private var expiry: Calendar? = null
    private val expires = SwitchRow(activity, activity.getString(R.string.ds_keys_set_expiry)) { on ->
        expiry = if (on) Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 30) } else null
        render()
    }
    private val date = surf.comma.android.settings.SettingsRow(activity, null, activity.getString(R.string.ds_keys_expires)).onClick { pickDate() }
    private val create = activity.actionRow(activity.getString(R.string.ds_keys_create_key)) {
        launch { if (model.create(name, expiry?.timeInMillis?.div(1000))) ctx.back() }
    }
    private val section = SettingsSection(activity, activity.getString(R.string.ds_keys_create))
    private val nameField = activity.fieldRow(activity.getString(R.string.ds_keys_name)) { name = it; render() }

    init {
        layout.section(section, top = 0)
        loading.isVisible = false
        start()
    }

    private fun pickDate() {
        val current = expiry ?: return
        DatePickerDialog(activity, { _, year, month, day ->
            expiry = Calendar.getInstance().apply { set(year, month, day, 23, 59, 59) }
            render()
        }, current.get(Calendar.YEAR), current.get(Calendar.MONTH), current.get(Calendar.DAY_OF_MONTH)).apply {
            datePicker.minDate = System.currentTimeMillis()
        }.show()
    }

    override fun render() {
        super.render()
        expires.set(expiry != null)
        date.value(expiry?.let { activity.shortDate(it.timeInMillis) }, chevron = true)
        create.isEnabled = name.isNotBlank()
        section.fill(listOfNotNull(nameField, expires.row.takeIf { model.voice }, date.takeIf { model.voice && expiry != null }, create))
    }
}
