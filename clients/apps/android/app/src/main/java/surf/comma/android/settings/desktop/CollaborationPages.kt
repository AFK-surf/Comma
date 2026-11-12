package surf.comma.android.settings.desktop

import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.core.view.isVisible
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.util.UUID

/** Settings > Shared tasks: the Workspace's active public links. */
internal class SharedTasksPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_shared_tasks, KEY) {
    private val feed = scope?.let { WorkspaceTopic(it, "taskShares", json("workspace" to it.workspaceId), workspaceField = true) }
    private val list = SettingsSection(activity, activity.getString(R.string.ds_shared_tasks))

    init {
        layout.section(list, top = 0)
        feed?.follow()
        start { scope?.perform("taskShares.refresh") }
    }

    override fun render() {
        super.render()
        val feed = feed ?: return
        loading.isVisible = !feed.loaded
        val shares = feed.value?.objects("shares").orEmpty()
        val rows = shares.mapNotNull { task ->
            val id = task.string("id") ?: return@mapNotNull null
            val title = task.string("title") ?: activity.getString(R.string.ds_task)
            activity.linkRow(title) { ctx.open(SharedTaskPage(ctx, feed.scope, id, title)) }
        }.toMutableList<View>()
        if (feed.loaded && shares.isEmpty()) rows += activity.infoRow(activity.getString(R.string.ds_shared_none))
        if (feed.value?.optBoolean("hasMore") == true) rows += activity.actionRow(activity.getString(R.string.ds_load_more)) {
            feed.scope.launch("taskShares.more")
        }.apply { isEnabled = feed.value?.optBoolean("loading") != true }
        list.fill(rows)
    }

    companion object { const val KEY = "shares" }
}

/** One shared Task's public link: send it, update its messages, replace it, or stop sharing. */
internal class SharedTaskPage(ctx: SettingsContext, shared: WorkspaceScope, private val task: String, title: String) :
    WorkspacePage(ctx, R.string.ds_share_task, "shares.detail", shared) {
    private val feed = WorkspaceTopic(shared, "taskShare", json("group" to shared.groupId, "conversation" to task))
    private val params get() = json("group" to scope!!.groupId, "conversation" to task)
    private val link = SettingsSection(activity, activity.getString(R.string.ds_shared_link)).footer(activity.getString(R.string.ds_shared_link_footer))
    private val state = SettingsSection(activity, null)
    private val job = feed.follow()

    init {
        layout.section(SettingsSection(activity, null).add(activity.textBlock(title).apply {
            surf.comma.android.ui.theme.DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.semibold)
        }), top = 0)
        layout.section(link)
        layout.section(state)
        layout.section(SettingsSection(activity, null).add(activity.actionRow(activity.getString(R.string.ds_open_task)) { ctx.openTask(task) }))
        loading.isVisible = false
        start { shared.perform("taskShare.refresh", params, workspaceParameter = false) }
    }

    override fun onClose() { job.cancel() }

    override fun render() {
        super.render()
        val share = feed.value?.optJSONObject("share")
        val url = share?.string("url")
        link.isVisible = url != null
        if (share != null && url != null) {
            val rows = mutableListOf<View>(activity.linkRow(activity.getString(R.string.ds_shared_send), icon = R.drawable.ic_share_os) { activity.shareText(url) },
                activity.textBlock(url, Level.SMALL, mono = true))
            if (share.optBoolean("has_newer_messages")) rows += activity.actionRow(activity.getString(R.string.ds_shared_update)) {
                scope?.launch("taskShare.publish", params, workspaceParameter = false)
            }
            rows += activity.actionRow(activity.getString(R.string.ds_shared_replace), destructive = true) { confirm("reset") }
            rows += activity.actionRow(activity.getString(R.string.ds_shared_stop), destructive = true) { confirm("revoke") }
            link.fill(rows)
        }
        state.fill(when {
            url != null -> emptyList()
            feed.value?.string("status") == "loading" -> listOf(activity.noteRow(activity.getString(R.string.settings_devices_loading)))
            feed.value?.string("status") == "ready" -> listOf(activity.infoRow(activity.getString(R.string.ds_shared_no_longer)))
            else -> emptyList()
        })
    }

    private fun confirm(action: String) {
        val label = activity.getString(if (action == "revoke") R.string.ds_shared_stop else R.string.ds_shared_replace)
        ConfirmDialog(activity, activity.getString(R.string.ds_shared_invalidate), "", label, destructive = true) {
            scope?.launch("taskShare.$action", params, workspaceParameter = false) { if (action == "revoke") ctx.back() }
        }.show()
    }
}

private fun android.content.Context.dateTime(seconds: Long?): String = seconds?.let {
    DateUtils.formatDateTime(this, it * 1000, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_TIME)
}.orEmpty()

private fun personName(person: JSONObject?) = person?.string("name") ?: person?.string("email").orEmpty()

private fun android.content.Context.requestStatus(value: String?) = when (value) {
    "pending" -> getString(R.string.ds_requests_pending)
    "accepted" -> getString(R.string.ds_requests_accepted)
    "declined" -> getString(R.string.ds_requests_declined)
    "withdrawn" -> getString(R.string.ds_requests_withdrawn)
    "expired" -> getString(R.string.ds_requests_expired)
    else -> value ?: "—"
}

/**
 * Settings > Task requests, in the desktop's order: requests waiting for the member, who may send requests here,
 * where the member may send, sent requests, and linked chat accounts. Section headers offer invite creation and
 * acceptance; each sender's more menu changes its approval mode or revokes it.
 */
internal class TaskRequestsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_requests, KEY) {
    private val model = scope?.let(::TaskRequestsModel)
    private val incoming = SettingsSection(activity, activity.getString(R.string.ds_requests_incoming))
    private val senders = SettingsSection(activity, null)
    private val targets = SettingsSection(activity, null)
    private val sent = SettingsSection(activity, activity.getString(R.string.ds_requests_sent))
    private val links = SettingsSection(activity, activity.getString(R.string.ds_requests_links))
    private val ownAuto = SwitchRow(activity, activity.getString(R.string.ds_requests_own_auto), activity.getString(R.string.ds_requests_own_auto_description)) { on ->
        launch { model?.setOwnAutoAccept(on) }
    }

    init {
        layout.section(incoming, top = 0)
        layout.section(caption(R.string.ds_requests_senders, R.string.ds_requests_create_invite) {
            launch { model?.invitePerson()?.let { activity.copySensitive(it); ctx.toast(activity.getString(R.string.ds_requests_invite_copied), false) } }
        })
        layout.section(senders, top = 8)
        layout.section(caption(R.string.ds_requests_targets, R.string.ds_requests_enter_invite) {
            model?.let { ctx.open(AcceptInvitationPage(ctx, it)) }
        })
        layout.section(targets, top = 8)
        layout.section(sent)
        layout.section(links)
        model?.feed?.follow()
        start { model?.refresh() }
    }

    /** A section header with its action at the trailing edge. */
    private fun caption(title: Int, action: Int, onClick: () -> Unit) = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(activity.text(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
            text = activity.getString(title)
            isAccessibilityHeading = true
            setPadding(activity.dp(4), 0, activity.dp(4), 0)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        addView(activity.inlineButton(activity.getString(action)) { onClick() })
    }

    override fun render() {
        super.render()
        val model = model ?: return
        val loaded = model.feed.loaded
        loading.isVisible = !loaded
        incoming.fill(model.rows("incoming").map { request ->
            val detail = listOf(personName(request.optJSONObject("sender")), activity.dateTime(request.int("created_at"))).filter(String::isNotEmpty)
            activity.describedRow(request.string("title") ?: activity.getString(R.string.ds_requests_request), detail.joinToString(" · "),
                activity.getString(R.string.ds_requests_review), R.color.token_bg_brand_solid).apply {
                setOnClickListener { ctx.open(RequestDetailPage(ctx, model, request, incoming = true)) }
            }
        }.ifEmpty { if (loaded) listOf(activity.infoRow(activity.getString(R.string.ds_requests_incoming_empty))) else emptyList() })
        val grants = model.grants
        senders.fill(grants.map(::grantRow).ifEmpty { if (loaded) listOf(activity.infoRow(activity.getString(R.string.ds_requests_senders_empty))) else emptyList() } +
            listOfNotNull(model.invite?.let { invite -> activity.actionRow(activity.getString(R.string.ds_requests_share_invite)) { activity.shareText(invite) } }))
        targets.fill(model.rows("targets").map { target ->
            val workspace = target.optJSONObject("workspace")
            val title = listOf(personName(workspace?.optJSONObject("owner")), workspace?.string("name").orEmpty()).filter(String::isNotEmpty).joinToString(" · ")
            activity.describedRow(title, activity.getString(R.string.ds_requests_sent_today, (target.int("sent_today") ?: 0).toInt(), (target.int("daily_limit") ?: 0).toInt()),
                activity.getString(R.string.ds_requests_send), R.color.token_bg_brand_solid).apply {
                setOnClickListener { ctx.open(SendRequestPage(ctx, model, target)) }
            }
        }.ifEmpty { if (loaded) listOf(activity.infoRow(activity.getString(R.string.ds_requests_targets_empty))) else emptyList() })
        sent.fill(model.rows("sent").map { request ->
            val detail = listOf(personName(request.optJSONObject("workspace")?.optJSONObject("owner")), activity.requestStatus(request.string("status")),
                request.string("decline_reason").orEmpty(), request.string("reply").orEmpty()).filter(String::isNotEmpty).joinToString(" · ")
            val withdraw = request.string("id")?.takeIf { request.string("status") == "pending" }?.let { id ->
                activity.inlineButton(activity.getString(R.string.ds_requests_withdraw), destructive = true) {
                    model.scope.launch("taskRequests.withdraw", json("request" to id), workspaceParameter = false)
                }
            }
            activity.describedRow(request.string("title") ?: activity.getString(R.string.ds_requests_request), detail, control = withdraw).apply {
                setOnClickListener { ctx.open(RequestDetailPage(ctx, model, request, incoming = false)) }
            }
        }.ifEmpty { if (loaded) listOf(activity.infoRow(activity.getString(R.string.ds_requests_sent_empty))) else emptyList() })
        val linkRows = model.rows("links").map { account ->
            val detail = listOf(account.string("provider").orEmpty(), account.string("email").orEmpty(), account.string("workspace").orEmpty())
                .filter(String::isNotEmpty).joinToString(" · ")
            activity.describedRow(account.string("name") ?: account.string("provider").orEmpty(), detail,
                control = activity.inlineButton(activity.getString(R.string.ds_requests_unlink), destructive = true) {
                    val id = account.string("id") ?: return@inlineButton
                    ConfirmDialog(activity, activity.getString(R.string.ds_requests_unlink_title), "", activity.getString(R.string.ds_requests_unlink_account),
                        destructive = true) { model.scope.launch("taskRequests.removeLink", json("id" to id), workspaceParameter = false) }.show()
                })
        }.toMutableList<View>()
        if (loaded && linkRows.isEmpty()) linkRows += activity.infoRow(activity.getString(R.string.ds_requests_links_empty))
        model.feed.value?.string("own")?.let { own -> ownAuto.set(own == "auto_accept"); linkRows += ownAuto.row }
        linkRows += activity.linkRow(activity.getString(R.string.ds_requests_link_account)) { ctx.open(LinkChatAccountPage(ctx, model)) }
        links.fill(linkRows)
    }

    private fun grantRow(grant: JSONObject): View {
        val invited = grant.string("status") == "invited"
        val name = if (invited) activity.getString(R.string.ds_requests_open_invite) else personName(grant.optJSONObject("grantee"))
        val detail = if (invited) grant.int("invite_expires_at")?.let { activity.getString(R.string.ds_expires, activity.dateTime(it)) }.orEmpty()
        else activity.getString(R.string.ds_requests_grant_detail,
            activity.getString(if (grant.string("mode") == "auto_accept") R.string.ds_requests_mode_auto else R.string.ds_requests_mode_review),
            (grant.int("daily_limit") ?: 0).toInt())
        val more = activity.moreButton(activity.getString(R.string.ds_requests_manage, name)) { anchor ->
            val menu = ActionMenu(activity)
            val id = grant.string("id")
            if (invited) grant.string("invite_url")?.let { link -> menu.item(activity.getString(R.string.ds_requests_copy_link)) { activity.copySensitive(link) } }
            else {
                val mode = if (grant.string("mode") == "auto_accept") "review" else "auto_accept"
                menu.item(activity.getString(if (mode == "auto_accept") R.string.ds_requests_switch_auto else R.string.ds_requests_switch_review)) {
                    if (id != null) launch { model?.setMode(id, mode) }
                }
            }
            menu.divider().item(activity.getString(R.string.ds_requests_revoke), destructive = true) {
                if (id != null) ConfirmDialog(activity, activity.getString(R.string.ds_requests_revoke_title), activity.getString(R.string.ds_requests_revoke_message),
                    activity.getString(R.string.ds_requests_revoke), destructive = true) {
                    model?.scope?.launch("taskRequests.revokeGrant", json("grant" to id))
                }.show()
            }.show(anchor)
        }
        return activity.describedRow(name, detail, control = more)
    }

    companion object { const val KEY = "requests" }
}

/** Accepts an invitation link once its preview has said what accepting gives each side. */
internal class AcceptInvitationPage(ctx: SettingsContext, private val model: TaskRequestsModel) :
    WorkspacePage(ctx, R.string.ds_requests_accept_invite, "requests.invite", model.scope) {
    private var invitation = ""
    private val section = SettingsSection(activity, activity.getString(R.string.ds_requests_accept_invite))
        .footer(activity.getString(R.string.ds_requests_accept_invite_footer))
    private val field = activity.fieldRow(activity.getString(R.string.ds_requests_invite_link)) {
        invitation = it
        model.invalidateInvitePreview()
        render()
    }

    init {
        layout.section(section, top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        val preview = model.invitePreview
        section.fill(listOfNotNull(field,
            activity.actionRow(activity.getString(R.string.ds_requests_preview_invite)) { launch { model.previewInvitation(invitation) { invitation } } }
                .apply { isEnabled = invitation.isNotBlank() },
            preview?.let { activity.infoRow(summary(it)) },
            preview?.takeUnless { it.optBoolean("own") }?.let {
                activity.actionRow(activity.getString(R.string.ds_requests_accept_invite_action)) { launch { if (model.acceptInvitation(invitation)) ctx.back() } }
            }))
    }

    /** What accepting gives each side, as the server said for this Workspace. */
    private fun summary(preview: JSONObject): String {
        val workspace = preview.optJSONObject("workspace")
        val owner = workspace?.optJSONObject("owner")
        val name = owner?.string("name") ?: owner?.string("email") ?: workspace?.string("name").orEmpty()
        val theirs = workspace?.string("name") ?: name
        if (preview.optBoolean("own")) return activity.getString(R.string.ds_requests_invite_own)
        val back = preview.optJSONObject("back")
            ?: return activity.getString(R.string.ds_requests_invite_one_way, name, theirs)
        val ours = back.optJSONObject("workspace")?.string("name").orEmpty()
        return activity.getString(
            if (back.string("mode") == "auto_accept") R.string.ds_requests_invite_both_auto else R.string.ds_requests_invite_both_review,
            name, theirs, ours)
    }
}

internal class LinkChatAccountPage(ctx: SettingsContext, private val model: TaskRequestsModel) :
    WorkspacePage(ctx, R.string.ds_requests_link_account, "requests.link", model.scope) {
    private var link = ""
    private val section = SettingsSection(activity, null)
    private val field = activity.fieldRow(activity.getString(R.string.ds_requests_account_link)) {
        link = it
        model.invalidatePreview()
        render()
    }

    init {
        layout.section(section, top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        val preview = model.linkPreview
        section.fill(listOfNotNull(field,
            activity.actionRow(activity.getString(R.string.ds_requests_preview_account)) { launch { model.previewLink(link) { link } } }
                .apply { isEnabled = link.isNotEmpty() },
            preview?.let { activity.infoRow(listOf(it.string("provider").orEmpty(), it.string("name").orEmpty()).joinToString(" · ")) },
            preview?.let { activity.actionRow(activity.getString(R.string.ds_requests_link_this)) { launch { if (model.acceptLink(link)) field.setText("") } } }))
    }
}

/**
 * One request. A waiting incoming request can be accepted with edited words, into a new Task or the Router chat, or
 * declined; otherwise it shows its words, status and reply.
 */
internal class RequestDetailPage(ctx: SettingsContext, private val model: TaskRequestsModel, private val request: JSONObject,
                                 private val incoming: Boolean) : WorkspacePage(ctx, R.string.ds_requests_request, "requests.detail", model.scope) {
    private val id = request.string("id").orEmpty()
    private val current get() = model.rows(if (incoming) "incoming" else "sent").firstOrNull { it.string("id") == id } ?: request
    private var title = request.optString("title")
    private var content = request.optString("content")
    private var reason = ""
    private var destination = "task"
    private val titleField = activity.fieldRow(activity.getString(R.string.ds_title)) { title = it }
    private val contentField = activity.fieldRow(activity.getString(R.string.ds_requests_content), lines = 3) { content = it; render() }
    private val reasonField = activity.fieldRow(activity.getString(R.string.ds_requests_decline_reason)) { reason = it }
    private val destinationRow = SettingsRow(activity, null, activity.getString(R.string.ds_requests_send_to))
    private val section = SettingsSection(activity, activity.getString(R.string.ds_requests_request))
    private var started = false

    init {
        titleField.setText(title)
        contentField.setText(content)
        started = true
        layout.section(section, top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        if (!started) return
        super.render()
        val current = current
        val rows = mutableListOf<View>()
        if (incoming && current.string("status") == "pending") {
            destinationRow.choices(listOf("task" to activity.getString(R.string.ds_requests_new_task),
                "router" to activity.getString(R.string.ds_requests_router_chat)), destination) { destination = it; render() }
            rows += listOf(titleField, contentField, destinationRow)
            rows += activity.actionRow(activity.getString(R.string.ds_requests_accept)) {
                model.scope.launch("taskRequests.accept", json("request" to id, "title" to title, "content" to content, "to" to destination)) { answer ->
                    ctx.back()
                    val task = answer.json?.optJSONObject("task")?.string("id")
                    if (task != null) ctx.openTask(task) else if (destination == "router") ctx.openRouter()
                }
            }.apply { isEnabled = content.isNotBlank() }
            rows += reasonField
            rows += activity.actionRow(activity.getString(R.string.ds_requests_decline), destructive = true) {
                ConfirmDialog(activity, activity.getString(R.string.ds_requests_decline_title), "", activity.getString(R.string.ds_requests_decline),
                    destructive = true) { model.scope.launch("taskRequests.decline", json("request" to id, "reason" to reason)) }.show()
            }
        } else {
            rows += activity.textBlock(current.string("title").orEmpty()).apply {
                surf.comma.android.ui.theme.DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.semibold)
            }
            rows += activity.textBlock(current.optString("content"))
            rows += activity.infoRow(activity.getString(R.string.ds_status), activity.requestStatus(current.string("status")))
            current.string("reply")?.let { rows += activity.textBlock(it) }
            current.string("decline_reason")?.let { rows += activity.textBlock(it) }
            if (!incoming && current.string("status") == "pending") rows += activity.actionRow(activity.getString(R.string.ds_requests_withdraw), destructive = true) {
                model.scope.launch("taskRequests.withdraw", json("request" to id), workspaceParameter = false)
            }
            current.optJSONObject("task")?.string("id")?.let { task -> rows += activity.actionRow(activity.getString(R.string.ds_open_task)) { ctx.openTask(task) } }
        }
        section.fill(rows)
    }
}

/** Sends a request to another Workspace, within its daily and waiting limits; the key keeps a retry from repeating it. */
internal class SendRequestPage(ctx: SettingsContext, private val model: TaskRequestsModel, private val target: JSONObject) :
    WorkspacePage(ctx, R.string.ds_requests_send_title, "requests.send", model.scope) {
    private val requestKey = UUID.randomUUID().toString()
    private var title = ""
    private var content = ""
    private var sent = false
    private val send = activity.actionRow(activity.getString(R.string.ds_requests_send_action)) {
        launch { if (model.send(target, title, content, requestKey)) { sent = true; ctx.back() } }
    }

    init {
        layout.section(SettingsSection(activity, target.optJSONObject("workspace")?.string("name") ?: activity.getString(R.string.settings_workspace))
            .add(activity.fieldRow(activity.getString(R.string.ds_title)) { title = it })
            .add(activity.fieldRow(activity.getString(R.string.ds_requests_content), lines = 4) { content = it; render() })
            .add(activity.noteRow(activity.getString(R.string.ds_requests_sent_today, (target.int("sent_today") ?: 0).toInt(),
                (target.int("daily_limit") ?: 0).toInt())))
            .add(send), top = 0)
        loading.isVisible = false
        start()
    }

    override fun render() {
        super.render()
        send.isEnabled = !sent && content.isNotBlank() && !TaskRequestsModel.full(target)
    }
}
