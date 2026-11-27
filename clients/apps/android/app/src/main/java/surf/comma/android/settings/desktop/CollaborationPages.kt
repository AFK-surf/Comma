package surf.comma.android.settings.desktop

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.Drawable
import android.text.InputType
import android.text.TextUtils
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.chat.render.BubbleTail
import surf.comma.android.people.PersonAvatarView
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.FieldDialog
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.clipToRoundedBackground
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.ui.statusIconRes
import surf.comma.android.tasks.ui.statusLabelRes
import surf.comma.android.tasks.ui.statusTintRes
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.ui.theme.uiSansAt
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

internal fun android.content.Context.requestStatus(value: String?, taskStatus: String? = null): String = when (value) {
    "pending" -> getString(R.string.ds_requests_pending)
    "accepted" -> {
        val trimmed = taskStatus?.trim().orEmpty()
        when {
            trimmed.isEmpty() -> getString(R.string.ds_requests_accepted)
            trimmed.equals("escalated", ignoreCase = true) -> getString(R.string.ds_requests_needs_input)
            else -> getString(statusLabelRes(TaskStatusBucket.fromTaskStatus(trimmed)))
        }
    }
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
            val detail = listOf(personName(request.optJSONObject("workspace")?.optJSONObject("owner")),
                activity.requestStatus(request.string("status"), request.string("task_status")),
                request.string("decline_reason").orEmpty(), request.string("reply").orEmpty()).filter(String::isNotEmpty).joinToString(" · ")
            val action = request.string("id")?.let { id ->
                if (request.string("status") == "pending") {
                    activity.inlineButton(activity.getString(R.string.ds_requests_withdraw), destructive = true) {
                        model.scope.launch("taskRequests.withdraw", json("request" to id), workspaceParameter = false)
                    }
                } else {
                    activity.inlineButton(activity.getString(R.string.ds_requests_delete), destructive = true) {
                        ConfirmDialog(
                            activity,
                            activity.getString(R.string.ds_requests_delete_title),
                            activity.getString(R.string.ds_requests_delete_description),
                            activity.getString(R.string.ds_requests_delete_request),
                            destructive = true,
                        ) { model.scope.launch("taskRequests.hide", json("request" to id), workspaceParameter = false) }.show()
                    }
                }
            }
            activity.describedRow(request.string("title") ?: activity.getString(R.string.ds_requests_request), detail, control = action).apply {
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

private const val MAX_DECLINE_REASON_BYTES = 1_000

/**
 * One request. A waiting incoming request shows its sender, timestamp, and a labeled editable request card with a
 * pinned Decline / Create task footer; sent and decided requests match the mobile Task chat: a two-line title and
 * status bar over an airy thread of real curved Comma chat bubbles.
 */
internal class RequestDetailPage(ctx: SettingsContext, private val model: TaskRequestsModel, private val request: JSONObject,
                                 private val incoming: Boolean) :
    WorkspacePage(ctx, R.string.ds_requests_request, "requests.detail", model.scope) {
    private val id = request.string("id").orEmpty()
    private val current
        get() = (if (incoming) {
            model.rows("received").firstOrNull { it.string("id") == id }
                ?: model.rows("incoming").firstOrNull { it.string("id") == id }
        } else {
            model.rows("sent").firstOrNull { it.string("id") == id }
        }) ?: request
    private var title = request.optString("title")
    private var content = request.optString("content")
    private val titleField = activity.fieldRow(activity.getString(R.string.ds_title)) { title = it }.apply {
        typeface = uiSansAt(DesignFonts.semibold)
        gravity = Gravity.TOP or Gravity.START
        includeFontPadding = false
        minHeight = 0
        minimumHeight = 0
        setPadding(0, activity.dp(6), 0, 0)
    }
    private val contentField = activity.fieldRow(activity.getString(R.string.ds_requests_content), lines = 4) { content = it; render() }.apply {
        setPadding(0, activity.dp(4), 0, 0)
        minimumHeight = activity.dp(104)
    }
    private val reviewHeader = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
    }
    private val reviewDecline = activity.filledButton(
        activity.getString(R.string.ds_requests_decline),
        R.color.token_bg_tertiary,
        R.color.token_text_error_primary,
        pill = true,
    ).apply {
        setOnClickListener {
            FieldDialog(
                activity = activity,
                title = activity.getString(R.string.ds_requests_decline_title),
                hint = activity.getString(R.string.ds_requests_decline_reason),
                current = "",
                saveLabel = activity.getString(R.string.ds_requests_decline),
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES,
                maxLength = MAX_DECLINE_REASON_BYTES,
                onSave = { reason ->
                    model.scope.launch("taskRequests.decline", json("request" to id, "reason" to reason))
                },
                description = activity.getString(R.string.ds_requests_decline_message),
                keyboard = true,
                refused = { false },
                destructive = true,
                requireChange = false,
                maxBytes = MAX_DECLINE_REASON_BYTES,
            ).show()
        }
    }
    private val reviewAccept = activity.filledButton(
        activity.getString(R.string.ds_requests_accept),
        R.color.token_bg_brand_solid,
        null,
        pill = true,
    ).apply {
        setOnClickListener {
            model.scope.launch("taskRequests.accept", json("request" to id, "title" to title, "content" to content)) { answer ->
                ctx.back()
                val task = answer.json?.optJSONObject("task")?.string("id")
                if (task != null) ctx.openTask(task)
            }
        }
    }
    private val reviewFooter = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(activity.color(R.color.token_bg_primary))
        addView(View(activity).apply { setBackgroundColor(activity.color(R.color.token_border_primary)) },
            LinearLayout.LayoutParams(-1, 1))
        val actions = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(activity.dp(16), activity.dp(12), activity.dp(16), activity.dp(12))
            addView(reviewDecline, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
            addView(reviewAccept, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(12) })
        }
        addView(actions, LinearLayout.LayoutParams(-1, -2))
    }
    private val reviewBody = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        addView(reviewHeader, LinearLayout.LayoutParams(-1, -2).apply {
            topMargin = activity.dp(4)
            bottomMargin = activity.dp(16)
        })
        val cardRadius = activity.dp(24).toFloat()
        val card = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            background = roundRect(activity.color(R.color.token_bg_tertiary), cardRadius)
            clipToRoundedBackground(cardRadius)
            val titleGroup = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(activity.dp(16), activity.dp(14), activity.dp(16), activity.dp(14))
                addView(activity.text(Level.MINI, R.color.token_text_tertiary, DesignFonts.medium).apply {
                    text = activity.getString(R.string.ds_title)
                }, LinearLayout.LayoutParams(-2, -2))
                addView(titleField, LinearLayout.LayoutParams(-1, -2))
            }
            addView(titleGroup, LinearLayout.LayoutParams(-1, -2))
            addView(View(activity).apply { setBackgroundColor(activity.color(R.color.token_bg_primary)) },
                LinearLayout.LayoutParams(-1, maxOf(1, (activity.resources.displayMetrics.density * 0.67f).toInt())).apply {
                    marginStart = activity.dp(16)
                })
            val contentGroup = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(activity.dp(16), activity.dp(14), activity.dp(16), activity.dp(14))
                addView(activity.text(Level.MINI, R.color.token_text_tertiary, DesignFonts.medium).apply {
                    text = activity.getString(R.string.ds_requests_content)
                }, LinearLayout.LayoutParams(-2, -2))
                addView(contentField, LinearLayout.LayoutParams(-1, -2))
            }
            addView(contentGroup, LinearLayout.LayoutParams(-1, -2))
        }
        addView(card, LinearLayout.LayoutParams(-1, -2))
        addView(activity.text(Level.MINI, R.color.token_text_tertiary).apply {
            text = activity.getString(R.string.ds_requests_accept_note)
            setPadding(activity.dp(4), activity.dp(12), activity.dp(4), 0)
        }, LinearLayout.LayoutParams(-1, -2))
    }
    private val thread = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val barTitle = activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.medium).apply {
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        gravity = Gravity.CENTER
        includeFontPadding = false
        isAccessibilityHeading = true
    }
    private val barStatusIcon = ImageView(activity)
    private val barStatusText = activity.text(Level.MINI, R.color.token_text_quaternary, DesignFonts.medium).apply {
        maxLines = 1
        includeFontPadding = false
    }
    private val barHeader = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        addView(barTitle, LinearLayout.LayoutParams(-2, -2))
        addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(barStatusIcon, LinearLayout.LayoutParams(activity.dp(12), activity.dp(12)).apply {
                marginEnd = activity.dp(4)
            })
            addView(barStatusText, LinearLayout.LayoutParams(-2, -2))
        }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(1) })
    }
    private val more = ImageView(activity).apply {
        id = R.id.request_detail_more
        setImageResource(R.drawable.ic_action_more)
        imageTintList = android.content.res.ColorStateList.valueOf(activity.getColor(R.color.token_fg_primary))
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        contentDescription = activity.getString(R.string.ds_requests_more)
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        clipToRoundedBackground(activity.dp(22).toFloat())
        setOnClickListener { openMore(it) }
    }
    private var started = false

    init {
        titleField.setText(title)
        contentField.setText(content)
        started = true
        layout.bar.addView(barHeader, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER).apply {
            marginStart = activity.dp(56)
            marginEnd = activity.dp(56)
        })
        layout.section(reviewBody, top = 0)
        layout.section(thread, top = 0)
        layout.footer(reviewFooter)
        layout.trailing.addView(more, LinearLayout.LayoutParams(activity.dp(44), activity.dp(44)))
        loading.isVisible = false
        start()
    }

    private fun openMore(anchor: View) {
        if (id.isEmpty()) return
        val status = current.string("status")
        val menu = ActionMenu(activity)
        if (status == "pending") {
            menu.item(activity.getString(R.string.ds_requests_withdraw), destructive = true) {
                model.scope.launch("taskRequests.withdraw", json("request" to id), workspaceParameter = false)
            }
        } else {
            menu.item(activity.getString(R.string.ds_requests_delete_request), R.drawable.ic_trash_can, destructive = true) {
                ConfirmDialog(
                    activity,
                    activity.getString(R.string.ds_requests_delete_title),
                    activity.getString(R.string.ds_requests_delete_description),
                    activity.getString(R.string.ds_requests_delete_request),
                    destructive = true,
                ) {
                    model.scope.launch("taskRequests.hide", json("request" to id), workspaceParameter = false) { ctx.back() }
                }.show()
            }
        }
        menu.show(anchor, haptic = true)
    }

    override fun render() {
        if (!started) return
        super.render()
        val current = current
        val pendingIncoming = incoming && current.string("status") == "pending"
        more.isVisible = !incoming && id.isNotEmpty()
        layout.titleView.isVisible = pendingIncoming
        barHeader.isVisible = !pendingIncoming
        reviewBody.isVisible = pendingIncoming
        reviewFooter.isVisible = pendingIncoming
        layout.syncFooterPadding()
        thread.isVisible = !pendingIncoming
        if (pendingIncoming) {
            val sender = current.optJSONObject("sender")
            val senderName = personName(sender)
            val senderAvatar = sender?.string("id")?.let { pid ->
                model.rows("people").firstOrNull { it.string("id") == pid }?.optJSONObject("avatar")
            }
            val timestamp = activity.dateTime(current.int("created_at"))
            reviewHeader.removeAllViews()
            reviewHeader.isVisible = senderName.isNotEmpty() || timestamp.isNotEmpty()
            if (senderName.isNotEmpty()) {
                reviewHeader.addView(
                    recipientChip(senderName, senderAvatar, activity.getString(R.string.ds_requests_from_person, senderName)),
                    LinearLayout.LayoutParams(-2, -2),
                )
            }
            if (timestamp.isNotEmpty()) {
                reviewHeader.addView(
                    activity.text(Level.MINI, R.color.token_text_tertiary).apply { text = timestamp },
                    LinearLayout.LayoutParams(-2, -2).apply { if (senderName.isNotEmpty()) topMargin = activity.dp(6) },
                )
            }
            val ready = content.isNotBlank()
            reviewAccept.isEnabled = ready
            reviewAccept.alpha = if (ready) 1f else 0.4f
        } else {
            renderThread(current)
        }
    }

    private fun recipientChip(name: String, avatarSource: JSONObject?, label: CharSequence) = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(999).toFloat())
        setPadding(activity.dp(3), activity.dp(3), activity.dp(10), activity.dp(3))
        addView(PersonAvatarView(activity, 22).apply {
            show(name, avatarSource, model.scope.core)
        }, LinearLayout.LayoutParams(activity.dp(22), activity.dp(22)))
        addView(activity.text(Level.SMALL, R.color.token_text_primary).apply {
            text = label
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = activity.dp(6) })
    }

    private fun renderThread(current: JSONObject) {
        thread.removeAllViews()
        val status = current.string("status")
        val taskStatus = if (incoming) null else current.string("task_status")
        val bucket = when (status) {
            "pending" -> null
            "accepted" -> taskStatus?.takeIf { it.isNotBlank() }?.let(TaskStatusBucket::fromTaskStatus) ?: TaskStatusBucket.IN_PROGRESS
            else -> TaskStatusBucket.CANCELLED
        }
        val quiet = status != "pending" && status != "accepted"
        val tintRes = if (quiet || bucket == null) R.color.token_fg_quaternary else statusTintRes(bucket)
        val statusText = activity.requestStatus(status, taskStatus)
        val heading = current.string("title").orEmpty().ifEmpty { activity.getString(R.string.ds_requests_request) }
        barTitle.text = heading
        barStatusIcon.setImageResource(statusIconRes(bucket))
        barStatusIcon.imageTintList = android.content.res.ColorStateList.valueOf(activity.color(tintRes))
        barStatusText.text = statusText

        val person = if (incoming) current.optJSONObject("sender") else current.optJSONObject("workspace")?.optJSONObject("owner")
        val personId = person?.string("id")
        val counterparty = personName(person).ifEmpty { current.optJSONObject("workspace")?.string("name").orEmpty() }
        val avatarSource = personId?.let { pid ->
            model.rows("people").firstOrNull { it.string("id") == pid }?.optJSONObject("avatar")
        }
        val timestamp = activity.dateTime(current.int("created_at"))

        if (counterparty.isNotEmpty() || timestamp.isNotEmpty()) {
            val opening = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                if (counterparty.isNotEmpty()) {
                    val chipRow = LinearLayout(activity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        if (!incoming) {
                            addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply {
                                text = activity.getString(R.string.people_to)
                            }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = activity.dp(6) })
                        }
                        val chipLabel = if (incoming) activity.getString(R.string.ds_requests_from_person, counterparty)
                        else activity.getString(R.string.people_request_to, counterparty)
                        addView(recipientChip(counterparty, avatarSource, chipLabel))
                    }
                    addView(chipRow, LinearLayout.LayoutParams(-2, -2))
                }
                if (timestamp.isNotEmpty()) {
                    addView(activity.text(Level.MINI, R.color.token_text_tertiary).apply {
                        text = timestamp
                        gravity = Gravity.CENTER
                    }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = activity.dp(6) })
                }
            }
            thread.addView(opening, LinearLayout.LayoutParams(-1, -2).apply {
                topMargin = activity.dp(12)
                bottomMargin = activity.dp(22)
            })
        }

        val requestText = current.optString("content").trim()
        if (requestText.isNotEmpty()) {
            if (!incoming) {
                val row = LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END
                    addView(messageBubble(requestText, outgoing = true), LinearLayout.LayoutParams(-2, -2).apply {
                        marginStart = activity.dp(48)
                    })
                }
                thread.addView(row, LinearLayout.LayoutParams(-1, -2))
            } else {
                thread.addView(incomingRow(counterparty, avatarSource, isComma = false, counterparty, requestText), LinearLayout.LayoutParams(-1, -2))
            }
        }

        val reply = current.string("reply")?.trim().orEmpty()
        val declineReason = current.string("decline_reason")?.trim().orEmpty()
        when {
            reply.isNotEmpty() -> {
                val caption = if (!incoming && counterparty.isNotEmpty()) activity.getString(R.string.people_request_to, counterparty) else ""
                thread.addView(incomingRow(counterparty, avatarSource, isComma = true, caption, reply), LinearLayout.LayoutParams(-1, -2).apply {
                    topMargin = activity.dp(14)
                })
            }
            declineReason.isNotEmpty() -> {
                thread.addView(
                    incomingRow(counterparty, avatarSource, isComma = false, activity.getString(R.string.ds_requests_declined), declineReason),
                    LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(14) },
                )
            }
            !incoming && status !in setOf("declined", "withdrawn", "expired") -> {
                thread.addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply {
                    text = activity.getString(R.string.ds_requests_no_result)
                    gravity = Gravity.CENTER
                }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
            }
        }

        current.optJSONObject("task")?.string("id")?.let { task ->
            thread.addView(activity.filledButton(activity.getString(R.string.ds_open_task), R.color.token_bg_brand_solid, null).apply {
                setOnClickListener { ctx.openTask(task) }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(24) })
        }
    }

    private fun incomingRow(counterparty: String, avatarSource: JSONObject?, isComma: Boolean, caption: String, body: String): View {
        val tailDepthPx = activity.dp(BubbleTail.DEPTH_DP.toInt())
        return LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            if (isComma || counterparty.isNotEmpty()) {
                val avatar: View = if (isComma) {
                    FrameLayout(activity).apply {
                        addView(ImageView(activity).apply {
                            setImageResource(R.drawable.ic_cue_mark)
                            imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_text_primary))
                        }, FrameLayout.LayoutParams(activity.dp(16), activity.dp(16), Gravity.CENTER))
                    }
                } else {
                    PersonAvatarView(activity, 24).apply { show(counterparty, avatarSource, model.scope.core) }
                }
                addView(avatar, LinearLayout.LayoutParams(activity.dp(24), activity.dp(24)).apply {
                    marginEnd = activity.dp(8)
                    bottomMargin = tailDepthPx
                })
            }
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                if (caption.isNotEmpty()) {
                    addView(activity.text(Level.MINI, R.color.token_text_tertiary).apply {
                        text = caption
                        setPadding(activity.dp(14), 0, 0, 0)
                    }, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = activity.dp(4) })
                }
                addView(messageBubble(body, outgoing = false), LinearLayout.LayoutParams(-2, -2))
            }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = activity.dp(42) })
        }
    }

    private fun messageBubble(text: String, outgoing: Boolean) = activity.text(
        Level.REGULAR,
        if (outgoing) R.color.token_text_primary else R.color.token_markdown_text_primary,
    ).apply {
        this.text = text
        if (outgoing) setTextColor(Color.WHITE)
        setTextIsSelectable(true)
        val tailDepthPx = activity.dp(BubbleTail.DEPTH_DP.toInt())
        setPadding(activity.dp(14), activity.dp(9), activity.dp(14), activity.dp(9) + tailDepthPx)
        background = BubbleDrawable(
            fill = activity.color(if (outgoing) R.color.token_bg_brand_solid else R.color.token_markdown_bg_message),
            right = outgoing,
            density = resources.displayMetrics.density,
        )
    }

    private class BubbleDrawable(private val fill: Int, private val right: Boolean, private val density: Float) : Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = fill }
        private val path = Path()
        private val scratch = Path()
        private val body = RectF()
        private val radiusPx = BubbleTail.RADIUS_DP * density
        private val tailDepthPx = BubbleTail.DEPTH_DP * density

        override fun draw(canvas: Canvas) {
            val w = bounds.width().toFloat()
            val h = (bounds.height().toFloat() - tailDepthPx).coerceAtLeast(radiusPx)
            if (w <= 0f || h <= 0f) return
            body.set(0f, 0f, w, h)
            BubbleTail.outline(path, scratch, body, radiusPx, right, density)
            canvas.drawPath(path, paint)
        }

        override fun setAlpha(alpha: Int) { paint.alpha = alpha }
        override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
        @Deprecated("Deprecated in Java") override fun getOpacity() = PixelFormat.TRANSLUCENT
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
