package surf.comma.android.people

import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.core.CoreError
import surf.comma.android.settings.FieldDialog
import surf.comma.android.settings.SettingsPageLayout
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.color
import surf.comma.android.settings.desktop.TaskRequestsModel
import surf.comma.android.settings.desktop.describe
import surf.comma.android.settings.desktop.fieldRow
import surf.comma.android.settings.desktop.int
import surf.comma.android.settings.desktop.json
import surf.comma.android.settings.desktop.string
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.tasks.list.FlowLayout
import android.widget.EditText
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.util.UUID

/** A sheet's scrolling body of sections on the sheet's own surface, with no bar of its own. */
private fun ComponentActivity.sheetBody() = SettingsPageLayout(this, "", showBack = false) {}.apply {
    bar.isVisible = false
    setBackgroundColor(getColor(R.color.token_card_primary))
}

/**
 * A message being written, as the system's mail writes one: lines of a label and what goes there, a hairline under
 * each, then the text itself filling the rest, and a quiet note at the foot. The keyboard opens on [focus].
 */
private class ComposeBody(private val activity: ComponentActivity) : LinearLayout(activity) {
    val note = activity.text(Level.SMALL, R.color.token_text_tertiary)
    val failure = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }

    init {
        orientation = VERTICAL
        setBackgroundColor(activity.color(R.color.token_card_primary))
    }

    /** One line: [label] leading, then [content]; a hairline under it. */
    fun line(label: CharSequence, content: View, trailing: View? = null) {
        val row = LinearLayout(activity).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = activity.dp(48)
            setPadding(activity.dp(20), activity.dp(6), activity.dp(12), activity.dp(6))
            addView(activity.text(Level.REGULAR, R.color.token_text_tertiary).apply { text = label },
                LayoutParams(-2, -2).apply { marginEnd = activity.dp(8) })
            addView(content, LayoutParams(0, -2, 1f))
            trailing?.let { addView(it) }
        }
        addView(row, LayoutParams(-1, -2))
        hairline()
    }

    /** A line that is only a field, as a subject is. */
    fun field(field: EditText) {
        field.setPadding(activity.dp(20), activity.dp(12), activity.dp(20), activity.dp(12))
        addView(field, LayoutParams(-1, -2))
        hairline()
    }

    /** The text, taking what is left of the sheet; the note and any failure under it. */
    fun text(field: EditText) {
        field.setPadding(activity.dp(20), activity.dp(14), activity.dp(20), activity.dp(14))
        field.minLines = 1
        addView(field, LayoutParams(-1, 0, 1f))
        addView(failure, LayoutParams(-1, -2).apply { marginStart = activity.dp(20); marginEnd = activity.dp(20) })
        addView(note, LayoutParams(-1, -2).apply {
            marginStart = activity.dp(20); marginEnd = activity.dp(20); topMargin = activity.dp(8); bottomMargin = activity.dp(16)
        })
    }

    private fun hairline() = addView(View(activity).apply { setBackgroundColor(activity.color(R.color.token_border_primary)) },
        LayoutParams(-1, 1).apply { marginStart = activity.dp(20) })

    /** Opens the keyboard on [field] once the sheet is up. */
    fun focus(field: EditText) = field.post {
        field.requestFocus()
        (activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager)
            ?.showSoftInput(field, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
    }
}

/** Someone on a To line: their face, their name, and a cross that takes them off when [onRemove] is given. */
private fun ComponentActivity.recipientChip(avatar: PersonAvatarView, name: CharSequence, onRemove: (() -> Unit)?): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundRect(color(R.color.token_bg_tertiary), dp(16).toFloat())
        setPadding(dp(4), dp(4), if (onRemove == null) dp(12) else dp(4), dp(4))
        addView(avatar, LinearLayout.LayoutParams(dp(24), dp(24)))
        addView(text(Level.REGULAR, R.color.token_text_primary).apply {
            text = name
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(8) })
        onRemove?.let { remove ->
            addView(android.widget.ImageView(context).apply {
                setImageResource(R.drawable.ic_action_close)
                imageTintList = android.content.res.ColorStateList.valueOf(color(R.color.token_text_tertiary))
                scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
                setPadding(dp(4), dp(4), dp(4), dp(4))
                contentDescription = getString(R.string.people_remove, name)
                setOnClickListener { remove() }
            }, LinearLayout.LayoutParams(dp(24), dp(24)).apply { marginStart = dp(2) })
        }
    }

/**
 * A Collaborative Task being written, as a new message is: who it is with on the To line (more from People, or someone
 * not on Comma by their email), what to do together, and Start. The member pays and no one joins once it starts.
 * Started, its Task opens.
 */
internal class CollaborateSheet(private val tab: PeopleTab, private val model: PeopleModel, initial: List<String>) :
    CommaSheet(tab.activity, tab.activity.getString(R.string.people_collaborate), Detent.LARGE) {
    private val chosen = initial.toMutableList()
    private val emails = mutableListOf<String>()
    private val key = UUID.randomUUID().toString().replace("-", "")
    private var pending = false
    private val body = ComposeBody(activity)
    private val to = FlowLayout(activity, activity.dp(6))
    private val message = activity.fieldRow(activity.getString(R.string.people_compose_placeholder),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, lines = 6) { renderState() }
    private val add = android.widget.ImageView(activity).apply {
        id = R.id.people_add_recipient
        setImageResource(R.drawable.ic_plus_small)
        imageTintList = android.content.res.ColorStateList.valueOf(activity.color(R.color.token_fg_primary))
        scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
        contentDescription = activity.getString(R.string.people_add_people)
        layoutParams = LinearLayout.LayoutParams(activity.dp(40), activity.dp(40))
        surf.comma.android.settings.PressFeedback(this, R.color.token_bg_quaternary, scale = true)
        setOnClickListener { pick(it) }
    }
    private val start = activity.barAction(activity.getString(R.string.people_start)) { start() }.apply { id = R.id.people_start }

    init {
        body.line(activity.getString(R.string.people_to), to, add)
        body.text(message)
        trailing.addView(start)
        setContent(body)
        renderRecipients()
        renderState()
    }

    override fun onShown() { body.focus(message) }

    private val people get() = chosen.mapNotNull(model::person)

    private fun renderRecipients() {
        to.removeAllViews()
        people.forEach { person ->
            val avatar = PersonAvatarView(activity, 24).apply { show(person.name, person.avatar, model.scope.core) }
            to.addView(activity.recipientChip(avatar, person.name) { chosen.remove(person.id); changed() })
        }
        emails.forEach { email ->
            to.addView(activity.recipientChip(PersonAvatarView(activity, 24).apply { show(email) }, email) { emails.remove(email); changed() })
        }
    }

    private fun renderState() {
        body.note.text = listOfNotNull(activity.getString(R.string.people_together_note),
            activity.getString(R.string.people_invite_email_note).takeIf { emails.isNotEmpty() }).joinToString("\n")
        val ready = !pending && message.text.isNotBlank() && (chosen.isNotEmpty() || emails.isNotEmpty()) && model.scope.current
        start.isEnabled = ready
        start.alpha = if (ready) 1f else 0.4f
        message.isEnabled = !pending
    }

    private fun changed() {
        body.failure.isVisible = false
        renderRecipients()
        renderState()
    }

    /** More people from People, checked as they are in; or someone by email. */
    private fun pick(anchor: View) {
        val menu = ActionMenu(activity)
        model.people.forEach { person ->
            menu.item(person.name, checked = person.id in chosen) {
                if (person.id in chosen) chosen.remove(person.id) else chosen.add(person.id)
                changed()
            }
        }
        menu.divider().item(activity.getString(R.string.people_invite_email), R.drawable.ic_plus_small) { inviteEmail() }
        menu.show(anchor, haptic = true)
    }

    private fun inviteEmail() {
        FieldDialog(activity, activity.getString(R.string.people_invite_email), activity.getString(R.string.people_email), "",
            activity.getString(R.string.people_add),
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, 254, onSave = { value ->
                val email = value.trim().lowercase()
                if (email !in emails) emails += email
                changed()
            }, description = activity.getString(R.string.people_invite_email_hint), keyboard = true,
            refused = { value -> value.trim().split("@").let { it.size != 2 || it.any(String::isBlank) } }).show()
    }

    private fun start() {
        if (pending) return
        pending = true
        body.failure.isVisible = false
        renderState()
        val params = json("workspace" to model.scope.workspaceId, "people" to JSONArray(chosen),
            "content" to message.text.toString().trim(), "key" to key)
        if (emails.isNotEmpty()) params.put("emails", JSONArray(emails))
        model.scope.work.launch {
            try {
                val answer = model.scope.call("collaborations.start", params, workspaceParameter = false) as? JSONObject
                val task = answer?.optJSONObject("task")?.string("id") ?: throw CoreError("bad_response", "")
                dismiss()
                tab.openTask(task)
            } catch (e: CancellationException) {
                pending = false
            } catch (e: Exception) {
                pending = false
                body.failure.text = activity.getString(startFailure(e as? CoreError))
                body.failure.isVisible = true
                renderState()
            }
        }
    }

    companion object {
        /** Why it did not start, in words: never a server's code. */
        fun startFailure(error: CoreError?): Int = when {
            error?.status == 402 || error?.code == "billing_unavailable" -> R.string.people_start_failed_credits
            error?.status == 409 || error?.code == "conflict" -> R.string.people_start_failed_started
            error?.status == 400 -> R.string.people_start_failed_input
            else -> R.string.people_start_failed
        }
    }
}

/** A request to one person's Comma, written as a message: To them, a subject, what to do, and Send. */
internal class RequestSheet(activity: ComponentActivity, private val requests: TaskRequestsModel, private val person: PeoplePerson,
                            private val target: JSONObject) :
    CommaSheet(activity, activity.getString(R.string.people_request), Detent.LARGE) {
    private val key = UUID.randomUUID().toString()
    private val body = ComposeBody(activity)
    private val title = activity.fieldRow(activity.getString(R.string.people_request_title)) { render() }
    private val content = activity.fieldRow(activity.getString(R.string.people_request_placeholder),
        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES, lines = 6) { render() }
    private val send = activity.barAction(activity.getString(R.string.people_send)) { send() }
    private val unlisten: () -> Unit

    init {
        val avatar = PersonAvatarView(activity, 24).apply { show(person.name, person.avatar, requests.scope.core) }
        body.line(activity.getString(R.string.people_to), atStart(activity.recipientChip(avatar,
            activity.getString(R.string.people_request_to, person.name), null)))
        body.field(title)
        body.text(content)
        val full = TaskRequestsModel.full(target)
        body.note.text = if (full) activity.getString(R.string.people_request_full, person.name)
            else activity.getString(R.string.people_request_note, person.name, (target.int("sent_today") ?: 0).toInt(),
                (target.int("daily_limit") ?: 0).toInt())
        trailing.addView(send)
        setContent(body)
        unlisten = requests.scope.onChange { render() }
        onDismissed = { unlisten() }
        render()
    }

    override fun onShown() { body.focus(title) }

    private fun render() {
        val ready = content.text.isNotBlank() && !TaskRequestsModel.full(target) && !requests.scope.busy && requests.scope.current
        send.isEnabled = ready
        send.alpha = if (ready) 1f else 0.4f
        body.failure.text = requests.scope.error?.let { activity.describe(it) }
        body.failure.isVisible = body.failure.text.isNotEmpty()
    }

    private fun send() {
        requests.scope.work.launch {
            if (requests.send(target, title.text.toString(), content.text.toString(), key)) dismiss()
        }
    }
}

/** [child] at its own width, at the start of a line. */
private fun atStart(child: View) = android.widget.FrameLayout(child.context).apply {
    addView(child, android.widget.FrameLayout.LayoutParams(-2, -2))
}

/**
 * The invite link someone sent: pasted (or typed), Next shows who sent it as the server reads it, and Accept adds them
 * to People, both ways when the member's workspace takes them.
 */
internal class EnterInviteSheet(activity: ComponentActivity, private val requests: TaskRequestsModel) :
    CommaSheet(activity, activity.getString(R.string.people_enter_invite), Detent.MEDIUM) {
    private val body = activity.sheetBody()
    private val link = activity.fieldRow(activity.getString(R.string.people_enter_invite_hint), InputType.TYPE_TEXT_VARIATION_URI) {
        requests.invalidateInvitePreview()
        render()
    }
    private val card = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(activity.dp(20), activity.dp(20), activity.dp(20), activity.dp(20))
        background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(24).toFloat())
    }
    private val failure = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false }
    private val next = activity.barAction(activity.getString(R.string.people_next)) { preview() }
    private val unlisten: () -> Unit

    init {
        body.section(SettingsSection(activity, null).add(link).footer(activity.getString(R.string.people_enter_invite_footer)), top = 0)
        body.section(card, top = 16)
        body.section(failure, top = 8)
        trailing.addView(next)
        setContent(body)
        unlisten = requests.scope.onChange { render() }
        onDismissed = { unlisten(); requests.invalidateInvitePreview() }
        render()
    }

    private val value get() = link.text.toString().trim()

    private fun preview() {
        val invitation = value
        requests.scope.work.launch { requests.previewInvitation(invitation) { value } }
    }

    private fun render() {
        val preview = requests.invitePreview
        next.isVisible = preview == null
        next.isEnabled = value.isNotEmpty() && !requests.scope.busy
        next.alpha = if (next.isEnabled) 1f else 0.4f
        failure.text = requests.scope.error?.let { activity.describe(it) }
        failure.isVisible = failure.text.isNotEmpty()
        card.removeAllViews()
        card.isVisible = preview != null
        preview ?: return
        val workspace = preview.optJSONObject("workspace")
        val owner = workspace?.optJSONObject("owner")
        val name = owner?.string("name") ?: owner?.string("email") ?: workspace?.string("name").orEmpty()
        card.addView(PersonAvatarView(activity, 56).apply { show(name) }, LinearLayout.LayoutParams(activity.dp(56), activity.dp(56)))
        if (preview.optBoolean("own")) {
            card.addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply {
                text = activity.getString(R.string.people_invite_own)
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(14) })
            return
        }
        card.addView(activity.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
            text = name
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(14) })
        card.addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply {
            text = activity.getString(R.string.people_invite_from, name)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(4) })
        card.addView(activity.filledButton(activity.getString(R.string.people_accept), R.color.token_bg_brand_solid, null).apply {
            setOnClickListener { requests.scope.work.launch { if (requests.acceptInvitation(value)) dismiss() } }
        }, LinearLayout.LayoutParams(-1, activity.dp(44)).apply { topMargin = activity.dp(16) })
    }
}

/**
 * An invitation to a Collaborative Task another person hosts: who is in it, who invited the member and pays, that only
 * this Task is shared, then Decline or Join. Nothing of the Task shows until the member joins; joined, [joined] opens it.
 */
internal class InvitationSheet(activity: ComponentActivity, private val model: PeopleModel, private val item: PeopleCollaboration,
                               private val joined: () -> Unit) : CommaSheet(activity, null, Detent.MEDIUM) {
    private val failure = activity.text(Level.SMALL, R.color.token_text_error_primary).apply { isVisible = false; gravity = Gravity.CENTER }
    private val buttons = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val decline = activity.filledButton(activity.getString(R.string.people_decline), R.color.token_bg_tertiary, R.color.token_text_primary)
    private val join = activity.filledButton(activity.getString(R.string.people_join), R.color.token_bg_brand_solid, null)
    private var answering = false

    init {
        val content = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(activity.dp(20), activity.dp(8), activity.dp(20), activity.dp(16))
        }
        val faces = listOf(item.hostName to item.hostId?.let(model::person)?.avatar) +
            item.members.map { (id, name) -> name to id?.let(model::person)?.avatar }
        content.addView(activity.avatarStack(faces, 44, R.color.token_card_primary, core = model.scope.core, max = 5))
        content.addView(activity.text(Level.LARGE, R.color.token_text_primary, DesignFonts.semibold).apply {
            text = item.title
            gravity = Gravity.CENTER
        }.lines(3), LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        content.addView(activity.text(Level.SMALL, R.color.token_text_secondary).apply {
            text = activity.getString(R.string.people_invited_you, item.hostName)
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        val facts = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(activity.dp(16), activity.dp(14), activity.dp(16), activity.dp(14))
            background = roundRect(activity.color(R.color.token_bg_tertiary), activity.dp(16).toFloat())
            listOf(activity.getString(R.string.people_invite_paid, item.hostName), activity.getString(R.string.people_invite_scope),
                activity.getString(R.string.people_invite_preview)).forEachIndexed { index, line ->
                addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply { text = line },
                    LinearLayout.LayoutParams(-1, -2).apply { if (index > 0) topMargin = activity.dp(8) })
            }
        }
        content.addView(facts, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        content.addView(failure, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
        decline.setOnClickListener { answer(false) }
        join.setOnClickListener { answer(true) }
        buttons.addView(decline, LinearLayout.LayoutParams(0, activity.dp(44), 1f))
        buttons.addView(join, LinearLayout.LayoutParams(0, activity.dp(44), 1f).apply { marginStart = activity.dp(12) })
        content.addView(buttons, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        setContent(content)
    }

    private fun restore() {
        answering = false
        decline.isEnabled = true
        decline.alpha = 1f
        join.isEnabled = true
        join.alpha = 1f
    }

    private fun answer(join: Boolean) {
        if (answering) return
        answering = true
        decline.isEnabled = false
        decline.alpha = 0.4f
        this.join.isEnabled = false
        this.join.alpha = 0.4f
        failure.isVisible = false
        model.scope.work.launch {
            try {
                if (model.answer(item, join)) {
                    dismiss()
                    if (join) joined()
                } else {
                    failure.text = model.scope.error?.let { activity.describe(it) } ?: activity.getString(R.string.ds_error_generic)
                    failure.isVisible = true
                    restore()
                }
            } catch (e: CancellationException) {
                restore()
                throw e
            }
        }
    }
}
