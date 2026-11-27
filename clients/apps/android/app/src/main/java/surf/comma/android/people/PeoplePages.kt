package surf.comma.android.people

import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.auth.AuthState
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.PressFeedback
import surf.comma.android.settings.SettingsPage
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.desktop.WorkspacePage
import surf.comma.android.settings.desktop.describe
import surf.comma.android.settings.desktop.int
import surf.comma.android.settings.desktop.json
import surf.comma.android.settings.desktop.requestStatus
import surf.comma.android.settings.desktop.shareText
import surf.comma.android.settings.desktop.string
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.ui.statusIconRes
import surf.comma.android.tasks.ui.statusTintRes
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.EmptyStateView
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level

/**
 * People: everyone the member works with, by name. A row opens the person; Add shares the member's invite link
 * through the system share sheet or takes the link someone sent. What waits from them (invitations, requests) is the
 * Inbox's.
 */
internal class PeopleListPage(private val tab: PeopleTab) : SettingsPage {
    override val key = "people"
    private val activity = tab.activity
    private val layout = SettingsPageLayout(activity, activity.getString(R.string.people_title), showBack = false) {}
    override val view: View = layout
    private val scope = tab.workspaceScope()
    val workspaceId: String? = scope?.workspaceId
    private val model = scope?.let { PeopleModel(it, (tab.auth as? AuthState.Connected)?.account?.id) }
    private val rows = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private var query = ""
    private val search = android.widget.EditText(activity).apply {
        hint = activity.getString(R.string.people_search)
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        setTextColor(activity.getColor(R.color.token_text_primary))
        surf.comma.android.ui.theme.DesignTypography.applyTo(this, Level.REGULAR, DesignFonts.regular)
        background = surf.comma.android.settings.roundRect(activity.getColor(R.color.token_bg_tertiary), activity.dp(20).toFloat())
        setPadding(activity.dp(16), 0, activity.dp(16), 0)
        setSingleLine()
        gravity = Gravity.CENTER_VERTICAL
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
        addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: android.text.Editable?) { query = s?.toString().orEmpty().trim(); render() }
        })
        minHeight = activity.dp(44)
    }
    private val error = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val empty = EmptyStateView(activity)
    private var following: List<Job> = emptyList()

    init {
        layout.section(search, top = 0)
        layout.section(error, top = 8)
        layout.section(rows, top = 4)
        layout.overlay(empty)
        layout.trailing.addView(ImageView(activity).apply {
            id = R.id.people_add
            setImageResource(R.drawable.ic_plus_small)
            imageTintList = android.content.res.ColorStateList.valueOf(activity.getColor(R.color.token_fg_primary))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = activity.getString(R.string.people_add)
            PressFeedback(this, R.color.token_bg_quaternary, scale = true)
            setOnClickListener { addMenu(it) }
        }, LinearLayout.LayoutParams(activity.dp(44), activity.dp(44)))
        scope?.onChange { render() }
        render()
    }

    fun setFollowing(shown: Boolean) {
        val model = model ?: return
        if (!shown) {
            following.forEach(Job::cancel)
            following = emptyList()
            return
        }
        if (following.isEmpty()) following = model.follow()
    }

    fun scrollToTop() = layout.list.smoothScrollToPosition(0)

    override fun onRemoved() {
        setFollowing(false)
        scope?.close()
    }

    private fun addMenu(anchor: View) {
        ActionMenu(activity)
            .item(activity.getString(R.string.people_share_invite), R.drawable.ic_share_os) { shareInvite() }
            .item(activity.getString(R.string.people_enter_invite), R.drawable.ic_action_link) { enterInvite() }
            .show(anchor, haptic = true)
    }

    private fun shareInvite() {
        val model = model ?: return
        model.scope.work.launch { model.requests.invitePerson()?.let(activity::shareText) }
    }

    private fun enterInvite() {
        val model = model ?: return
        EnterInviteSheet(activity, model.requests).show()
    }

    private fun render() {
        val model = model
        error.isVisible = scope?.error != null
        error.text = scope?.error?.let { activity.describe(it) }
        rows.removeAllViews()
        if (model == null) {
            empty.show(R.drawable.ic_tab_people_group, activity.getString(R.string.people_no_workspace),
                activity.getString(R.string.people_no_workspace_detail))
            empty.isVisible = true
            return
        }
        val people = model.people
        val shown = people.filter { query.isEmpty() || "${it.name} ${it.email.orEmpty()}".contains(query, ignoreCase = true) }
        search.isVisible = people.isNotEmpty()
        // As the system's contacts: under the initial each name starts with, with # strictly last.
        shown.groupBy { peopleSectionLetter(it.name) }.entries
            .sortedWith(compareBy<Map.Entry<Char, List<PeoplePerson>>> { it.key == '#' }.thenBy { it.key })
            .forEach { (letter, group) ->
            rows.addView(activity.text(Level.SMALL, R.color.token_text_quaternary, DesignFonts.semibold).apply {
                text = letter.toString()
                isAccessibilityHeading = true
                setPadding(activity.dp(10), activity.dp(12), activity.dp(10), activity.dp(2))
            })
            group.forEach { person ->
                val avatar = PersonAvatarView(activity, 40).apply {
                    show(person.name, person.avatar, model.scope.core)
                    layoutParams = LinearLayout.LayoutParams(activity.dp(40), activity.dp(40))
                }
                rows.addView(activity.personRow(avatar, person.name, person.email?.takeIf { it != person.name }) {
                    tab.open(PersonPage(tab, model, person.id))
                })
            }
        }
        empty.isVisible = !model.loaded || people.isEmpty()
        when {
            !model.loaded -> empty.show(null, activity.getString(R.string.people_loading))
            people.isEmpty() -> empty.show(R.drawable.ic_tab_people_group, activity.getString(R.string.people_empty),
                activity.getString(R.string.people_empty_detail),
                activity.getString(R.string.people_share_invite) to ::shareInvite,
                activity.getString(R.string.people_enter_invite) to ::enterInvite, primary = true)
        }
    }
}

/**
 * One person: who they are, the two ways to work with them (a Collaborative Task with them, or a request to their
 * Comma when they take requests), and everything the two of you have to do with each other, the latest first. The
 * more menu sets how their requests are taken, or stops them.
 */
internal class PersonPage(private val tab: PeopleTab, private val model: PeopleModel, private val personId: String) :
    WorkspacePage(tab, R.string.people_title, "people.person", model.scope, titleText = "") {
    private val avatar = PersonAvatarView(activity, 88)
    private val name = activity.text(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply { gravity = Gravity.CENTER }
    private val email = activity.text(Level.SMALL, R.color.token_text_tertiary).apply { gravity = Gravity.CENTER }
    private val actions = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val tasks = surf.comma.android.settings.SettingsSection(activity, activity.getString(R.string.people_tasks))
    private val tasksEmpty = activity.text(Level.SMALL, R.color.token_text_tertiary).apply {
        setPadding(activity.dp(4), activity.dp(8), activity.dp(4), activity.dp(8))
    }
    private val more = ImageView(activity).apply {
        setImageResource(R.drawable.ic_action_more)
        imageTintList = android.content.res.ColorStateList.valueOf(activity.getColor(R.color.token_fg_primary))
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        setOnClickListener { menu(it) }
    }
    private var shownKey: Any? = null

    init {
        loading.isVisible = false
        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(avatar, LinearLayout.LayoutParams(activity.dp(88), activity.dp(88)))
            addView(name, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(16) })
            addView(email, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(4) })
            addView(actions, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        }
        layout.section(header, top = 8)
        layout.section(tasks, top = 28)
        layout.section(tasksEmpty, top = 0)
        layout.trailing.addView(more, LinearLayout.LayoutParams(activity.dp(44), activity.dp(44)))
        start()
    }

    override fun render() {
        super.render()
        val person = model.person(personId)
        if (person == null) {
            // Someone who left People (their access revoked) leaves the page with them.
            if (model.loaded) ctx.back()
            return
        }
        avatar.show(person.name, person.avatar, model.scope.core)
        name.text = person.name
        email.text = person.email?.takeIf { it != person.name }
        email.isVisible = email.text.isNotEmpty()
        more.isVisible = person.sendsGrant != null
        more.contentDescription = activity.getString(R.string.people_more, person.name)
        val all = tab.store.tasks.state.value.snapshot.tasks
        val tasksById = all.associateBy { it.id }
        val hosted = model.hostedTasks(all, person.id)
        val joined = model.joinedTasks(person.id)
        val reqs = model.requestsWith(person.id)
        val target = model.target(person)
        val key = listOf(
            person.copy(avatar = null),
            person.avatar?.toString(),
            target?.string("grant_id"),
            target?.int("sent_today"),
            target?.int("daily_limit"),
            target?.int("pending"),
            target?.int("pending_limit"),
            hosted,
            joined,
            reqs.map { (r, incoming) ->
                val taskId = r.optJSONObject("task")?.string("id")
                listOf(r.string("id"), r.string("status"), r.string("task_status"), r.string("title"),
                    r.int("created_at"), r.int("decided_at"), r.int("task_updated_at"), incoming, taskId,
                    taskId?.let { tasksById[it]?.listBucket })
            },
        )
        if (key == shownKey) return
        shownKey = key
        actions.removeAllViews()
        val tiles = mutableListOf<View>(activity.actionTile(R.drawable.ic_tab_people_group, activity.getString(R.string.people_collaborate), R.id.people_collaborate) {
            CollaborateSheet(tab, model, listOf(person.id)).show()
        })
        target?.let {
            tiles += activity.actionTile(R.drawable.ic_arrow_up_right, activity.getString(R.string.people_request), R.id.people_request) {
                RequestSheet(activity, model.requests, person, it).show()
            }
        }
        tiles.forEachIndexed { index, tile ->
            actions.addView(tile, LinearLayout.LayoutParams(0, -2, 1f).apply { if (index > 0) marginStart = activity.dp(12) })
        }
        renderTasks(person, hosted, joined, reqs, tasksById)
    }

    private fun renderTasks(
        person: PeoplePerson,
        hosted: List<surf.comma.android.tasks.TaskSummary>,
        joined: List<PeopleCollaboration>,
        reqs: List<Pair<org.json.JSONObject, Boolean>>,
        tasksById: Map<String, surf.comma.android.tasks.TaskSummary>,
    ) {
        tasks.card.removeAllViews()
        val rows = mutableListOf<Pair<Long, View>>()
        for (task in hosted) {
            val faces = listOf(((tab.auth as? AuthState.Connected)?.account?.name.orEmpty()) to null) +
                task.together.mapNotNull { model.person(it)?.let { p -> p.name to p.avatar } }
            val stack = activity.avatarStack(faces, 20, R.color.token_bg_tertiary, core = model.scope.core, max = 3)
            val glyph = statusGlyph(task.listBucket)
            rows += task.changedAt to activity.personRow(glyph, task.title, activity.getString(surf.comma.android.tasks.ui.statusLabelRes(task.listBucket))) {
                tab.openTask(task.id)
            }.apply { addView(stack) }
        }
        for (item in joined) {
            val detail = activity.getString(if (item.invited) R.string.people_invited_you else R.string.people_hosted_by, item.hostName)
            // Not joined yet, it has no status of its own for the member: the dashed ring of a Task not started.
            val glyph = if (item.invited) statusGlyph(null) else statusGlyph(TaskStatusBucket.IN_PROGRESS)
            rows += (item.invitedAt ?: 0) * 1000 to activity.personRow(glyph, item.title, detail) {
                if (item.invited) InvitationSheet(activity, model, item) { tab.openMemberTask(item.taskId, item.groupId) }.show()
                else tab.openMemberTask(item.taskId, item.groupId)
            }
        }
        for ((request, incoming) in reqs) {
            val status = request.string("status")
            val taskStatus = if (incoming) null else request.string("task_status")
            val detail = activity.getString(if (incoming) R.string.people_their_request else R.string.people_your_request,
                activity.requestStatus(status, taskStatus))
            val bucket = request.optJSONObject("task")?.string("id")?.let { tasksById[it]?.listBucket }
                ?: taskStatus?.takeIf { it.isNotBlank() }?.let(TaskStatusBucket::fromTaskStatus)
            val at = (if (incoming) request.int("created_at")
                else request.int("task_updated_at") ?: request.int("decided_at") ?: request.int("created_at")) ?: 0
            val row = activity.personRow(requestGlyph(status, bucket),
                request.string("title") ?: activity.getString(R.string.ds_requests_request), detail) {
                tab.open(surf.comma.android.settings.desktop.RequestDetailPage(tab, model.requests, request, incoming))
            }
            if (!incoming) {
                request.string("id")?.let { requestId ->
                    row.setOnLongClickListener { anchor ->
                        val menu = ActionMenu(activity)
                        if (status == "pending") {
                            menu.item(activity.getString(R.string.ds_requests_withdraw), destructive = true) {
                                model.scope.launch("taskRequests.withdraw", json("request" to requestId), workspaceParameter = false)
                            }
                        } else {
                            menu.item(activity.getString(R.string.ds_requests_delete_request), R.drawable.ic_trash_can, destructive = true) {
                                ConfirmDialog(
                                    activity,
                                    activity.getString(R.string.ds_requests_delete_title),
                                    activity.getString(R.string.ds_requests_delete_description),
                                    activity.getString(R.string.ds_requests_delete_request),
                                    destructive = true,
                                ) { model.scope.launch("taskRequests.hide", json("request" to requestId), workspaceParameter = false) }.show()
                            }
                        }
                        menu.show(anchor, haptic = true)
                        true
                    }
                }
            }
            rows += at * 1000 to row
        }
        rows.sortedByDescending { it.first }.forEach { tasks.add(it.second.apply { setPadding(activity.dp(14), paddingTop, activity.dp(14), paddingBottom) }) }
        tasks.isVisible = rows.isNotEmpty()
        tasksEmpty.isVisible = rows.isEmpty()
        tasksEmpty.text = activity.getString(R.string.people_tasks_empty, person.name)
    }

    /** Every row leads with the glyph the Tasks list shows for its status, so a Task looks the same everywhere. */
    private fun statusGlyph(bucket: TaskStatusBucket?, tint: Int? = null) =
        activity.rowGlyph(statusIconRes(bucket), tint ?: bucket?.let(::statusTintRes) ?: R.color.token_fg_quaternary)

    /**
     * A request as the Task it asks for: waiting, the dashed ring of one not started; accepted, its Task's own status
     * where this member has the Task; declined, withdrawn or expired, the quiet ring of one that will not run.
     */
    private fun requestGlyph(status: String?, bucket: TaskStatusBucket?) = when (status) {
        "pending" -> statusGlyph(null)
        "accepted" -> statusGlyph(bucket ?: TaskStatusBucket.IN_PROGRESS)
        else -> statusGlyph(TaskStatusBucket.CANCELLED, R.color.token_fg_quaternary)
    }

    private fun menu(anchor: View) {
        val person = model.person(personId) ?: return
        val grant = person.sendsGrant ?: return
        ActionMenu(activity)
            .item(activity.getString(R.string.ds_requests_mode_review), checked = person.sendsMode == "review") {
                launch { model.requests.setMode(grant, "review") }
            }
            .item(activity.getString(R.string.ds_requests_mode_auto), checked = person.sendsMode == "auto_accept") {
                launch { model.requests.setMode(grant, "auto_accept") }
            }
            .divider()
            .item(activity.getString(R.string.people_stop, person.name), destructive = true) {
                ConfirmDialog(activity, activity.getString(R.string.people_stop_title, person.name),
                    activity.getString(R.string.people_stop_detail), activity.getString(R.string.people_stop_action), destructive = true) {
                    model.scope.launch("taskRequests.revokeGrant", org.json.JSONObject().put("grant", grant))
                }.show()
            }
            .show(anchor, haptic = true)
    }
}

/** ASCII Latin initial (diacritics folded) A..Z; everything else (digits, symbols, CJK) groups under `#`. */
internal fun peopleSectionLetter(name: String): Char {
    val first = name.trimStart().firstOrNull() ?: return '#'
    val folded = java.text.Normalizer.normalize(first.toString(), java.text.Normalizer.Form.NFD)
        .firstOrNull { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
        ?.uppercaseChar() ?: return '#'
    return if (folded in 'A'..'Z') folded else '#'
}

/** How long ago, as the Inbox's rows say it. */
internal fun android.content.Context.ago(seconds: Long?): String = seconds?.let {
    DateUtils.getRelativeTimeSpanString(it * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS,
        DateUtils.FORMAT_ABBREV_RELATIVE).toString()
}.orEmpty()

