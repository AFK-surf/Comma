package surf.comma.android.tasks.coding

import android.content.Intent
import androidx.core.net.toUri
import android.text.InputType
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import androidx.activity.ComponentActivity
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.ConfirmDialog
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSwitch
import surf.comma.android.tasks.tools.ToolPage
import surf.comma.android.ui.ActionMenu
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level

/** A sandbox or pull request state in the member's words. */
internal fun codingStatus(activity: ComponentActivity, value: String?): String = when (value) {
    "ready" -> activity.getString(R.string.coding_state_ready)
    "starting" -> activity.getString(R.string.coding_state_starting)
    "stopped" -> activity.getString(R.string.coding_state_stopped)
    "lost" -> activity.getString(R.string.coding_state_lost)
    "failed" -> activity.getString(R.string.coding_state_failed)
    "ended" -> activity.getString(R.string.coding_state_ended)
    "open" -> activity.getString(R.string.coding_state_open)
    "draft" -> activity.getString(R.string.coding_state_draft)
    "merged" -> activity.getString(R.string.coding_state_merged)
    "closed" -> activity.getString(R.string.coding_state_closed)
    else -> value ?: "—"
}

/**
 * Task details > Code review: the coding Task's repository and sandbox, its changes against all of the branch,
 * the uncommitted ones or one commit, each file's diff, its execution history, and its pull request. Merging names
 * the pull request number and head the member reviewed.
 */
internal class CodingReviewSheet(activity: ComponentActivity, private val review: CodingReview) :
    CommaSheet(activity, activity.getString(R.string.coding_review_title), Detent.LARGE) {
    private val page = ToolPage(activity)

    init {
        setContent(page.view)
        review.onChange = ::render
        render()
        activity.lifecycleScope.launch { review.load() }
    }

    private fun render() {
        page.clear()
        if (!review.loaded) page.progress()
        review.session?.let(::environment)
        if (review.changes != null) {
            changes()
            pullRequest()
        }
        review.error?.let { page.error(it) { activity.lifecycleScope.launch { review.load() } } }
    }

    private fun row(section: surf.comma.android.settings.SettingsSection, title: Int, value: String?) =
        section.add(SettingsRow(activity, null, activity.getString(title)).value(value ?: "—"))

    private fun environment(session: JSONObject) {
        val section = page.section(activity.getString(R.string.coding_environment))
        session.optJSONObject("repo")?.let { repo ->
            row(section, R.string.coding_repository, listOfNotNull(repo.text("owner"), repo.text("name")).joinToString("/"))
            row(section, R.string.coding_branch, repo.text("branch"))
            row(section, R.string.coding_base_branch, repo.text("baseRef"))
        }
        row(section, R.string.coding_sandbox, codingStatus(activity, session.text("state")))
        session.text("reason")?.let { page.note(section, it) }
        if (session.text("state") == "ready") page.action(section, activity.getString(R.string.coding_open_terminal), enabled = !review.busy) {
            activity.lifecycleScope.launch { review.terminal()?.let(::open) }
        }
        section.add(SettingsRow(activity, null, activity.getString(R.string.coding_history)).value(null, chevron = true)
            .onClick { CodingHistorySheet(activity, review).show() })
    }

    private fun changes() {
        val section = page.section(activity.getString(R.string.coding_changes))
        val choices = buildList {
            add("" to activity.getString(R.string.coding_all_changes))
            if (review.hasUncommitted || review.selection == "uncommitted") add("uncommitted" to activity.getString(R.string.coding_uncommitted))
            review.commits.forEach { commit -> commit.text("sha")?.let { add(it to commit.text("title").orEmpty()) } }
        }
        section.add(SettingsRow(activity, null, activity.getString(R.string.coding_compare))
            .value(choices.firstOrNull { it.first == review.selection }?.second, chevron = true).onClick { anchor ->
                val menu = ActionMenu(activity)
                choices.forEach { (id, title) -> menu.item(title, checked = id == review.selection) { activity.lifecycleScope.launch { review.select(id) } } }
                menu.show(anchor)
            })
        if (review.files.isEmpty()) page.note(section, activity.getString(R.string.coding_no_changes))
        review.files.forEach { file ->
            section.add(SettingsRow(activity, null, file.text("path").orEmpty())
                .detail("+${file.optInt("additions")}  −${file.optInt("deletions")}").value(null, chevron = true)
                .onClick { CodePatchSheet(activity, file).show() })
        }
        if (review.changes?.optBoolean("truncated") == true) page.note(section, activity.getString(R.string.coding_truncated))
    }

    private fun pullRequest() {
        val section = page.section(activity.getString(R.string.coding_pull_request))
        val pr = review.pullRequest
        val enabled = !review.busy && review.current
        if (pr == null) {
            page.action(section, activity.getString(R.string.coding_create_pr), enabled = enabled) { edit() }
            return
        }
        section.add(SettingsRow(activity, null, pr.text("title") ?: activity.getString(R.string.coding_pull_request))
            .value(codingStatus(activity, pr.text("state"))))
        pr.optJSONObject("checks")?.let { checks ->
            section.add(SettingsRow(activity, null, activity.getString(R.string.coding_checks)).detail(activity.getString(R.string.coding_checks_summary,
                checks.optInt("passed"), checks.optInt("failed"), checks.optInt("total"))))
        }
        pr.text("url")?.takeIf { it.startsWith("https://") }?.let { url ->
            page.action(section, activity.getString(R.string.coding_open_github)) { open(url) }
        }
        val state = pr.text("state")
        if (state == "open" || state == "draft") {
            page.action(section, activity.getString(R.string.coding_edit_pr), enabled = enabled) { edit() }
            if (state == "draft") page.action(section, activity.getString(R.string.coding_ready_pr), enabled = enabled) {
                activity.lifecycleScope.launch { review.markReady() }
            }
            val number = pr.intOrNull("number")
            val head = pr.text("headSha")
            if (state == "open" && number != null && head != null) {
                page.action(section, activity.getString(R.string.coding_merge_pr), enabled = enabled && pr.text("mergeable") != "conflicting") {
                    ConfirmDialog(activity, activity.getString(R.string.coding_merge_title), "#$number · ${head.take(12)}",
                        activity.getString(R.string.coding_merge_pr), destructive = false) {
                        activity.lifecycleScope.launch { review.merge(number, head) }
                    }.show()
                }
            }
        } else if (pr.optBoolean("newCommits")) {
            page.action(section, activity.getString(R.string.coding_create_pr), enabled = enabled) { edit() }
        }
    }

    private fun edit() = PullRequestSheet(activity, review) { render() }.show()

    private fun open(url: String) {
        runCatching { activity.startActivity(Intent(Intent.ACTION_VIEW, url.toUri())) }
    }

    override fun onRemoved() {
        review.onChange = {}
    }
}

/** One file's diff, in a monospaced block that scrolls sideways. */
internal class CodePatchSheet(activity: ComponentActivity, file: JSONObject) :
    CommaSheet(activity, file.text("path") ?: activity.getString(R.string.coding_changes), Detent.LARGE) {
    init {
        val page = ToolPage(activity)
        val section = page.section()
        val patch = file.text("patch")
        if (patch == null) page.note(section, activity.getString(R.string.coding_no_diff))
        else section.add(ScrollContainer(activity).apply {
            orientation = ScrollContainer.HORIZONTAL
            addView(activity.label(Level.MINI, R.color.token_text_primary, lines = 0).apply {
                text = patch
                typeface = android.graphics.Typeface.MONOSPACE
                setTextIsSelectable(true)
                setHorizontallyScrolling(true)
                setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
            }, ViewGroup.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        })
        setContent(page.view)
    }
}

/** The session's execution history, read when opened and a page further back on request. */
internal class CodingHistorySheet(activity: ComponentActivity, private val review: CodingReview) :
    CommaSheet(activity, activity.getString(R.string.coding_history), Detent.LARGE) {
    private val page = ToolPage(activity)
    private val previous = review.onChange

    init {
        setContent(page.view)
        review.onChange = { previous(); render() }
        render()
        activity.lifecycleScope.launch { review.loadHistory() }
    }

    private fun render() {
        page.clear()
        if (review.history?.optBoolean("available", true) == false) page.note(page.section(), activity.getString(R.string.coding_history_unavailable))
        review.historyItems.forEach { item ->
            val section = page.section()
            if (item.text("kind") == "group") {
                item.objects("steps").forEach { step ->
                    val body = step.optJSONObject("body")
                    val detail = listOfNotNull(
                        body?.let { it.text("command") ?: it.text("diff") ?: it.text("lines") ?: it.text("text") ?: it.text("path") },
                        step.text("result") ?: step.text("text"),
                    ).joinToString("\n")
                    section.add(SettingsRow(activity, null, step.text("hint") ?: step.text("tool") ?: activity.getString(R.string.coding_thinking))
                        .detail(detail))
                }
            } else {
                page.note(section, item.text("text").orEmpty()).setTextIsSelectable(true)
            }
        }
        val start = review.history?.intOrNull("start")
        if (start != null && start > 0) page.action(page.section(), activity.getString(R.string.task_files_load_more)) {
            activity.lifecycleScope.launch { review.loadHistory(more = true) }
        }
    }

    override fun onRemoved() {
        review.onChange = previous
    }
}

/** Creates or edits the pull request: its title, description and, for a new one, whether it is a draft. */
internal class PullRequestSheet(activity: ComponentActivity, private val review: CodingReview, private val saved: () -> Unit) :
    CommaSheet(activity, activity.getString(R.string.coding_pull_request), Detent.LARGE) {
    private val page = ToolPage(activity)

    init {
        val section = page.section(activity.getString(R.string.coding_pull_request))
        section.add(field(R.string.coding_pr_title, review.prTitle, multiline = false) { review.prTitle = it })
        section.add(field(R.string.coding_pr_description, review.prBody, multiline = true) { review.prBody = it })
        if (review.createsPullRequest) {
            val toggle = SettingsSwitch(activity).apply { set(review.prDraft, animate = false) }
            section.add(SettingsRow(activity, null, activity.getString(R.string.coding_pr_draft)).trailing(toggle).onClick {
                review.prDraft = !review.prDraft
                toggle.set(review.prDraft)
            })
        }
        page.action(section, activity.getString(R.string.coding_pr_save)) {
            if (review.prTitle.isBlank() || review.busy) return@action
            activity.lifecycleScope.launch {
                if (review.savePullRequest()) { saved(); dismiss() } else review.error?.let { page.error(it, null) }
            }
        }
        setContent(page.view)
    }

    private fun field(hint: Int, value: String, multiline: Boolean, changed: (String) -> Unit) = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.getColor(R.color.token_text_primary))
        setHintTextColor(activity.getColor(R.color.token_text_placeholder))
        setHint(hint)
        setText(value)
        background = null
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
            (if (multiline) InputType.TYPE_TEXT_FLAG_MULTI_LINE else 0)
        if (multiline) minLines = 4 else isSingleLine = true
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
        doAfterTextChanged { changed(it?.toString().orEmpty()) }
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }
}
