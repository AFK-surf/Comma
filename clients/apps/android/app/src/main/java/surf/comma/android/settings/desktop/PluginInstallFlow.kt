package surf.comma.android.settings.desktop

import android.app.Activity
import android.text.InputType
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * A Router's request to add a plugin, answered from a chat's card: the Plugins page's install of that one plugin, in
 * [scope]'s Workspace, which it closes when it ends. It reads the plugin from the catalog and starts the install once:
 * a browser authorization opens with [openLink]; the form the install asks for (a Google sign-in's code, a key) is
 * asked in a dialog, which a fresh sign-in updates in place. The server ends the request once the plugin is installed.
 * It ends when the plugin is installed, the dialog is cancelled, the install fails or the Workspace changes; [onEnd]
 * then says so to its owner, which starts one at a time for a request.
 */
internal class PluginInstallFlow(
    private val activity: Activity,
    private val scope: WorkspaceScope,
    private val pluginId: String,
    private val name: String,
    private val openLink: (String) -> Unit,
    private val onEnd: () -> Unit = {},
) {
    private val model = PluginsModel(scope, only = pluginId)
    private var dialog: PluginFormDialog? = null
    private var connectLineDialog: PluginConnectLineDialog? = null
    private var ended = false
    /** The card's answer, given once: whether the install got going. */
    private var report: ((Boolean) -> Unit)? = null
    private var started = false
    /** The first call answered; what comes next is a form, a browser authorization or the plugin installed. */
    private var asked = false
    private var sending = false
    /** The form the value in flight was sent to; another form (a fresh sign-in) takes a new value. */
    private var sentForm: PluginConfiguration? = null

    /** Starts it; [done] says once, on the main thread, whether it got the install going. */
    fun start(done: (Boolean) -> Unit) {
        report = done
        scope.onChange { changed() }
        model.follow()
        model.followNotices()
        changed()
    }

    private fun changed() {
        if (ended) return
        if (!scope.current) return finish(false)
        if (!model.loaded) return
        val plugin = model.plugins.firstOrNull { it.id == pluginId } ?: return finish(false)
        if (!started) {
            started = true
            if (plugin.installed) return finish(true)
            if (plugin.locked) return finish(false)
            scope.work.launch {
                val url = model.install(plugin)
                asked = true
                when {
                    url != null -> { openLink(url); finish(true) }
                    scope.error != null && dialog == null -> finish(false)
                    else -> {
                        // Under way: what comes next (a form, or the plugin installed) arrives on its own.
                        reported(true)
                        changed()
                    }
                }
            }
            return
        }
        if (plugin.installed && model.configuration(plugin) == null) return finish(true)
        val showConfig = model.configuration(plugin)?.takeIf { it.showValue }
        if (showConfig != null) {
            dialog?.close()
            dialog = null
            val shown = connectLineDialog ?: PluginConnectLineDialog(activity, name) {
                model.dismissConfiguration()
                finish(true)
            }.also { connectLineDialog = it; it.show() }
            shown.update(showConfig.value.orEmpty())
            reported(true)
            return
        }
        val form = model.configuration(plugin)?.takeIf { !it.showValue } ?: staticForm(plugin)
        if (form != null) {
            if (sending && form != sentForm) sending = false
            val shown = dialog ?: PluginFormDialog(activity, name, openLink, onSend = { send(plugin, it) },
                onCancel = { model.dismissConfiguration(); finish(true) }).also { dialog = it; it.show() }
            shown.update(form, (model.formError ?: scope.error)?.let(activity::describe) ?: form.error, sending)
            reported(true)
        } else if (asked && scope.error != null) {
            // The install failed after it started (the core's notice says so).
            finish(false)
        }
    }

    /** A form a core names only by its plugin: the catalog's own credential setup. */
    private fun staticForm(plugin: Plugin): PluginConfiguration? {
        if (!plugin.asksCredential) return null
        val key = plugin.credentialKey ?: return null
        if (model.configurationPlugin != plugin.id) return null
        return PluginConfiguration(plugin.id, false, null, null, key, plugin.credentialLabel, plugin.helpUrl, plugin.credentialFormat, null, null)
    }

    private fun send(plugin: Plugin, value: String) {
        if (sending) return
        sending = true
        sentForm = model.configuration(plugin)?.takeIf { it.format != "show" } ?: staticForm(plugin)
        changed()
        scope.work.launch {
            model.install(plugin, value)?.let(openLink)
            // Taken, the form is put away and the dialog waits, still sending, for the plugin to be installed.
            sending = model.configuration(plugin) == null && model.formError == null && scope.error == null
            changed()
        }
    }

    private fun reported(started: Boolean) {
        val report = report ?: return
        this.report = null
        report(started)
    }

    private fun finish(started: Boolean) {
        if (ended) return
        ended = true
        dialog?.close()
        dialog = null
        connectLineDialog?.close()
        connectLineDialog = null
        scope.close()
        reported(started)
        onEnd()
    }
}

/**
 * What an install from a chat's card asks for: a Google sign-in (the page opens in the browser, and the code it shows
 * is pasted back), or a value such as a key. The dialog stays open until the value connects or the person cancels.
 */
internal class PluginFormDialog(
    private val activity: Activity,
    name: String,
    private val openLink: (String) -> Unit,
    private val onSend: (String) -> Unit,
    private val onCancel: () -> Unit,
) : SettingsDialog(activity, keyboard = true) {
    private val note = message("")
    private val signIn = activity.text(Level.SMALL, R.color.token_label_brand).apply {
        setPadding(0, activity.dp(6), 0, activity.dp(6))
    }
    private val field = EditText(activity).apply {
        setTextColor(activity.color(R.color.token_text_primary))
        setHintTextColor(activity.color(R.color.token_text_placeholder))
        DesignTypography.applyTo(this, Level.REGULAR)
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        isSingleLine = true
        background = roundRect(activity.color(R.color.token_bg_quaternary), activity.dp(10).toFloat())
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
    }
    private val error = activity.text(Level.SMALL, R.color.token_text_error_primary)
    private val connect = button(activity.getString(R.string.ds_plugins_code_connect), R.color.token_bg_brand_solid, null)
    private var form: PluginConfiguration? = null
    private var sending = false
    private var closing = false

    init {
        card.addView(title(activity.getString(R.string.chat_request_plugin_title, name)))
        card.addView(note, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        card.addView(signIn, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        card.addView(field, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(10) })
        card.addView(error, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        val cancel = button(activity.getString(R.string.settings_cancel), R.color.token_bg_quaternary, R.color.token_text_primary)
        cancel.setOnClickListener { dismiss() }
        connect.setOnClickListener { send() }
        card.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(cancel, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
            addView(connect, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(8) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        field.doAfterTextChanged { validate() }
        field.setOnEditorActionListener { _, _, _ -> send(); true }
        signIn.setOnClickListener { form?.helpUrl?.let(openLink) }
    }

    /** Shows [next], keeping what was typed unless the form is another sign-in; [problem] says why the last value failed. */
    fun update(next: PluginConfiguration, problem: String?, sending: Boolean) {
        val previous = form
        form = next
        this.sending = sending
        if (previous?.oauthCode != next.oauthCode) {
            field.inputType = InputType.TYPE_CLASS_TEXT or
                (if (next.oauthCode) InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS else InputType.TYPE_TEXT_VARIATION_PASSWORD)
            // After the input type: a password type sets a monospace typeface of its own.
            DesignTypography.applyTo(field, Level.REGULAR)
        }
        // A fresh sign-in makes the last code useless.
        if (previous != null && next.oauthCode && previous.attemptId != next.attemptId) field.setText("")
        field.hint = next.label ?: activity.getString(if (next.oauthCode) R.string.ds_plugins_authorization_code else R.string.ds_api_key)
        note.text = activity.getString(if (next.oauthCode) R.string.ds_plugins_code_hint else R.string.chat_request_fill_hint)
        signIn.text = activity.getString(if (next.oauthCode) R.string.ds_plugins_sign_in_google else R.string.ds_plugins_setup_help)
        signIn.isVisible = next.helpUrl != null
        error.text = problem.orEmpty()
        error.isVisible = problem != null
        validate()
    }

    private fun validate() {
        val ready = !sending && field.text.isNotBlank()
        connect.isEnabled = ready
        connect.alpha = if (ready) 1f else 0.4f
    }

    private fun send() {
        if (!connect.isEnabled) return
        val value = field.text.toString()
        onSend(if (form?.oauthCode == true) value.trim() else value)
    }

    /** Closes it for the flow, which ended: not a cancel. */
    fun close() {
        closing = true
        dismiss()
    }

    override fun onClosing() {
        field.setText("")
        if (!closing) onCancel()
    }
}

/** Shows a one-time connect line (`format == "show"`) to copy into a Monoid station. */
internal class PluginConnectLineDialog(
    private val activity: Activity,
    name: String,
    private val onDone: () -> Unit,
) : SettingsDialog(activity, keyboard = false) {
    private val lineView = activity.text(Level.SMALL, R.color.token_text_primary).apply {
        typeface = android.graphics.Typeface.MONOSPACE
        setTextIsSelectable(true)
        background = roundRect(activity.color(R.color.token_bg_quaternary), activity.dp(10).toFloat())
        setPadding(activity.dp(12), activity.dp(10), activity.dp(12), activity.dp(10))
    }
    private val copy = button(activity.getString(R.string.ds_plugins_show_copy), R.color.token_bg_quaternary, R.color.token_text_primary)
    private val done = button(activity.getString(R.string.ds_done), R.color.token_bg_brand_solid, null)
    private var currentLine = ""
    private var closing = false

    init {
        card.addView(title(activity.getString(R.string.ds_plugins_show_title, name)))
        card.addView(message(activity.getString(R.string.ds_plugins_show_description)), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        card.addView(lineView, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        card.addView(message(activity.getString(R.string.ds_plugins_show_once)), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        copy.setOnClickListener {
            if (currentLine.isNotEmpty()) {
                activity.copySensitive(currentLine)
                copy.text = activity.getString(R.string.ds_plugins_show_copied)
            }
        }
        done.setOnClickListener { dismiss() }
        card.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(copy, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
            addView(done, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(8) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }

    fun update(line: String) {
        if (line != currentLine) {
            currentLine = line
            lineView.text = line
            copy.text = activity.getString(R.string.ds_plugins_show_copy)
        }
    }

    fun close() {
        closing = true
        dismiss()
    }

    override fun onClosing() {
        if (!closing) onDone()
    }
}
