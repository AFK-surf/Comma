package surf.comma.android.settings.desktop

import android.text.InputType
import android.view.View
import android.widget.ImageView
import androidx.core.view.isVisible
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.dp

/**
 * Settings > Channels: each channel with its mark and connection status. Each row follows its channel's topic while
 * the list is open, and refreshes when the app returns.
 */
internal class ChannelsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_channels, KEY) {
    // Each row has its own scope, so one channel's failure shows only on its row.
    private val models = scope?.let { scope -> Channel.entries.map { ChannelModel(scope.child(), it, ctx.apiHost) } }.orEmpty()
    private val rows = models.associateWith { model ->
        SettingsRow(activity, null, title(model.channel)).onClick { ctx.open(ChannelPage(ctx, model.channel)) }.apply {
            icon.setImageResource(model.channel.logo)
            icon.imageTintList = null
            icon.isVisible = true
            icon.scaleType = ImageView.ScaleType.FIT_CENTER
        }
    }
    private val resume = object : DefaultLifecycleObserver {
        private var first = true
        override fun onResume(owner: LifecycleOwner) {
            if (first) { first = false; return }
            models.forEach { model -> launch { model.action("refresh") } }
        }
    }

    init {
        val section = SettingsSection(activity, activity.getString(R.string.ds_channels_connect)).footer(activity.getString(R.string.ds_channels_footer))
        rows.values.forEach { section.add(it) }
        layout.section(section, top = 0)
        models.forEach {
            it.scope.onChange { if (scope?.current != false) render() }
            it.feed.follow()
        }
        activity.lifecycle.addObserver(resume)
        loading.isVisible = false
        start()
    }

    override fun onClose() = activity.lifecycle.removeObserver(resume)

    override fun render() {
        super.render()
        rows.forEach { (model, row) ->
            val (text, color) = when {
                !model.scope.current || model.scope.error != null -> R.string.ds_unavailable to R.color.token_text_tertiary
                !model.feed.loaded || !model.hasState -> R.string.ds_loading to R.color.token_text_tertiary
                model.connected -> R.string.ds_connected to R.color.token_fg_success
                else -> R.string.ds_not_connected to R.color.token_text_tertiary
            }
            row.value(activity.getString(text), chevron = true)
            row.value.setTextColor(activity.getColor(color))
        }
    }

    companion object {
        const val KEY = "channels"

        fun title(channel: Channel): String = when (channel) {
            Channel.TELEGRAM -> "Telegram"
            Channel.WECHAT -> "WeChat"
            Channel.SIGNAL -> "Signal"
            Channel.IMESSAGE -> "iMessage"
            Channel.LINEAR -> "Linear"
        }
    }
}

/** One channel's connection: connect, the channel's own steps, and disconnect. */
internal class ChannelPage(ctx: SettingsContext, channel: Channel) :
    WorkspacePage(ctx, R.string.ds_channels, "channels.detail", titleText = if (channel == Channel.WECHAT) ctx.activity.getString(R.string.ds_wechat) else ChannelsPage.title(channel)) {
    private val model = scope?.let { ChannelModel(it, channel, ctx.apiHost) }
    private var input = ""
    private var number = ""
    private val handleField = activity.fieldRow(activity.getString(R.string.ds_channels_imessage_handle),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS) { input = it.trim(); render() }
    private val codeField = activity.fieldRow(activity.getString(R.string.ds_verification_code), InputType.TYPE_CLASS_NUMBER) { input = it.trim(); render() }
    private val numberField = activity.fieldRow(activity.getString(R.string.ds_phone_number), InputType.TYPE_CLASS_PHONE) { number = it.trim() }
    private val status = SettingsSection(activity, null)
    private val details = SettingsSection(activity, null)
    private val extra = SettingsSection(activity, null)
    private val resume = object : DefaultLifecycleObserver {
        private var first = true
        override fun onResume(owner: LifecycleOwner) {
            if (first) { first = false; return }
            launch { model?.action("refresh") }
        }
    }

    init {
        layout.section(status, top = 0)
        layout.section(details)
        layout.section(extra)
        model?.feed?.follow()
        activity.lifecycle.addObserver(resume)
        start { model?.action("refresh") }
    }

    override fun onClose() = activity.lifecycle.removeObserver(resume)

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.feed.loaded
        if (model.feed.value?.optBoolean("error") == true && model.scope.error == null) {
            showError(PageError.Text(R.string.ds_channels_status_failed)) { model.action("refresh") }
        }
        val connected = model.connected
        val rows = mutableListOf<View>(activity.infoRow(activity.getString(R.string.ds_status),
            activity.getString(if (connected) R.string.ds_connected else R.string.ds_not_connected)))
        if (!connected) {
            if (model.channel == Channel.IMESSAGE) rows += handleField
            rows += activity.actionRow(activity.getString(R.string.ds_connect)) {
                launch { model.connect(input)?.let(activity::openLink) }
            }.apply { isEnabled = !model.busy && !(model.channel == Channel.IMESSAGE && input.isEmpty()) }
        } else if (model.channel != Channel.SIGNAL) {
            rows += activity.actionRow(activity.getString(R.string.ds_disconnect), destructive = true) {
                ConfirmDialog(activity, activity.getString(R.string.ds_channels_disconnect_title), "", activity.getString(R.string.ds_disconnect),
                    destructive = true) { launch { model.action("disconnect") } }.show()
            }
        }
        status.fill(rows)
        details.fill(emptyList())
        extra.fill(emptyList())
        when (model.channel) {
            Channel.TELEGRAM -> telegram(model)
            Channel.WECHAT -> wechat(model)
            Channel.SIGNAL -> signal(model)
            Channel.IMESSAGE -> imessage(model)
            Channel.LINEAR -> linear(model)
        }
    }

    private fun cancel(model: ChannelModel) = activity.actionRow(activity.getString(R.string.ds_cancel_connection)) { launch { model.action("cancel") } }

    private fun telegram(model: ChannelModel) {
        val state = model.state ?: return
        val rows = mutableListOf<View>()
        state.string("bot_url")?.takeIf { it.startsWith("https://") }?.let { url ->
            rows += activity.actionRow(activity.getString(R.string.ds_channels_open_bot)) { activity.openLink(url) }
        }
        state.optJSONObject("link")?.string("telegram_username")?.let { rows += activity.infoRow(activity.getString(R.string.ds_account), it) }
        if (model.feed.value?.string("attempt") != null) rows += cancel(model)
        details.fill(rows)
    }

    private fun wechat(model: ChannelModel) {
        val pending = model.state?.optJSONObject("pending") ?: return
        val rows = mutableListOf<View>()
        // The QR code image is the service's; it opens in the browser rather than being fetched here.
        pending.string("qrcode_url")?.takeIf { it.startsWith("https://") }?.let { url ->
            rows += activity.actionRow(activity.getString(R.string.ds_channels_wechat_qr)) { activity.openLink(url) }
        }
        if (pending.string("login_status") == "need_verifycode") {
            rows += codeField
            rows += activity.actionRow(activity.getString(R.string.ds_channels_verify)) { launch { model.action("verify", json("code" to input)) } }
                .apply { isEnabled = input.isNotEmpty() }
        }
        if (pending.string("login_status") in setOf("expired", "verify_code_blocked")) rows += activity.noteRow(activity.getString(R.string.ds_channels_expired))
        rows += cancel(model)
        details.fill(rows)
    }

    private fun signal(model: ChannelModel) {
        val rows = mutableListOf<View>()
        model.feed.value?.optJSONObject("integration")?.objects("bindings")?.forEach { chat ->
            rows += activity.infoRow(chat.string("display_name") ?: chat.string("peer").orEmpty())
            rows += activity.actionRow(activity.getString(R.string.ds_channels_disconnect_chat), destructive = true) {
                val binding = chat.string("binding_id") ?: return@actionRow
                ConfirmDialog(activity, activity.getString(R.string.ds_channels_disconnect_signal), "", activity.getString(R.string.ds_disconnect),
                    destructive = true) { launch { model.action("disconnect", json("binding" to binding)) } }.show()
            }
        }
        if (model.connected) rows += activity.actionRow(activity.getString(R.string.ds_channels_another_chat)) { launch { model.connect() } }
        model.signalCode?.let { code ->
            rows += activity.noteRow(activity.getString(R.string.ds_channels_signal_send))
            rows += activity.infoRow(code.string("number").orEmpty())
            rows += activity.textBlock(code.string("command").orEmpty(), mono = true)
            rows += activity.actionRow(activity.getString(R.string.ds_channels_cancel_code)) {
                code.string("claimId")?.let { claim -> launch { model.action("cancelCode", json("claim" to claim)) } }
            }
        }
        details.fill(rows)
        val current = model.feed.value?.optJSONObject("number")?.optJSONObject("effective")?.string("e164") ?: "—"
        extra.fill(listOf(activity.infoRow(activity.getString(R.string.ds_channels_current_number), current), numberField,
            activity.actionRow(activity.getString(R.string.ds_channels_save_number)) { launch { model.action("setNumber", json("number" to number)) } }))
    }

    private fun imessage(model: ChannelModel) {
        model.state?.optJSONObject("pending_claim")?.let { pending ->
            details.fill(listOfNotNull(activity.noteRow(activity.getString(R.string.ds_channels_imessage_send)),
                activity.textBlock(pending.string("code").orEmpty(), surf.comma.android.ui.theme.DesignTypography.Level.TITLE2, mono = true),
                pending.string("line_handle")?.let { activity.infoRow(activity.getString(R.string.ds_channels_send_to), it) }, cancel(model)))
        }
        model.state?.optJSONObject("link")?.string("sender_handle")?.let { extra.fill(listOf(activity.infoRow(activity.getString(R.string.ds_account), it))) }
    }

    private fun linear(model: ChannelModel) {
        val state = model.state
        val rows = mutableListOf<View>()
        state?.optJSONObject("member")?.let { member ->
            rows += activity.infoRow(activity.getString(R.string.ds_channels_organization),
                state.optJSONObject("installation")?.string("organization_name") ?: "—")
            rows += activity.infoRow(activity.getString(R.string.ds_account), member.string("linear_user_name") ?: member.string("linear_user_email") ?: "—")
            rows += SettingsRow(activity, null, activity.getString(R.string.ds_channels_linear_completion)).choices(listOf(
                "unchanged" to activity.getString(R.string.ds_channels_linear_keep), "in_review" to activity.getString(R.string.ds_channels_linear_review),
                "done" to activity.getString(R.string.ds_channels_linear_done)), member.string("completion_state_policy") ?: "unchanged") {
                launch { model.action("updateSettings", json("completion_state_policy" to it)) }
            }
        }
        details.fill(rows)
        val more = mutableListOf<View>()
        if (state?.optJSONObject("installation")?.optBoolean("installer") == true) {
            more += activity.actionRow(activity.getString(R.string.ds_channels_remove_org), destructive = true) {
                ConfirmDialog(activity, activity.getString(R.string.ds_channels_remove_org_title), activity.getString(R.string.ds_channels_remove_org_message),
                    activity.getString(R.string.ds_channels_remove_org), destructive = true) {
                    launch { model.action("disconnect", json("scope" to "organization")) }
                }.show()
            }
        }
        if (model.feed.value?.string("attempt") != null) more += cancel(model)
        extra.fill(more)
    }
}
