package surf.comma.android.chat.demo

import android.content.res.Configuration
import android.os.Bundle
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnLayout
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.chat.live.LiveTimeline
import surf.comma.android.chat.live.ReplyAction
import surf.comma.android.chat.live.TriggerMenu
import surf.comma.android.chat.live.followComposer
import surf.comma.android.chat.live.entryBlocks
import surf.comma.android.chat.live.mapConversation
import surf.comma.android.chat.live.replyText
import surf.comma.android.ui.MessageActionsPopup
import surf.comma.android.chat.render.ChatPalette
import surf.comma.android.chat.render.ChatTimelineView
import surf.comma.android.chat.render.MessageLayoutPrecomputer
import surf.comma.android.chat.render.codeLabels
import surf.comma.android.chat.render.codeSyntaxTheme
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.ChatMessage
import surf.comma.android.conversation.ChatRole
import surf.comma.android.conversation.MessagePart
import surf.comma.android.conversation.ModelMentionLinks
import surf.comma.android.conversation.ParticipantStatus
import surf.comma.android.conversation.ReplyDraft
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.tasks.TaskStatusBucket
import surf.comma.android.tasks.TaskSummary
import surf.comma.android.ui.composer.ComposerView
import surf.comma.android.workspace.MentionModel
import surf.comma.android.ui.theme.DesignTypography

/**
 * Debug-only page that shows made-up conversations through the live chat's mapping and layout,
 * with the composer, so bubbles can be checked on a device without a backend or an account.
 *
 * adb shell am start -n surf.comma.android.dev/surf.comma.android.chat.demo.ChatBubblesDemoActivity \
 *   --es scene mix --ez night false --ef font 1.0 --ez narrow false
 *
 * Scenes: mix, long, code, table, image, gap, notice, typing, scroll (wide code blocks and tables
 * among history), math (inline and display formulas, a wide one, a broken one, prices and code
 * that are not math), arrive (a reply landing, on a loop) and models (the router chat's @ menu with
 * made-up models and Tasks; a send shows as the client core shows it). `--ez rtl true` lays the
 * page out right to left.
 */
class ChatBubblesDemoActivity : ComponentActivity() {
    /** The list, for device tests that press on its rows. */
    lateinit var timeline: ChatTimelineView
        private set
    /** The conversation on screen, for device tests that check what was copied. */
    var shown: ConversationState? = null
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val night = intent.getBooleanExtra("night", false)
        val font = intent.getFloatExtra("font", 1f)
        val narrow = intent.getBooleanExtra("narrow", false)
        val rtl = intent.getBooleanExtra("rtl", false)
        val scene = intent.getStringExtra("scene") ?: "mix"
        val uiMode = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
        val context = ContextThemeWrapper(this, R.style.Theme_Chat).apply {
            applyOverrideConfiguration(Configuration().also { it.uiMode = uiMode })
        }
        window.decorView.setBackgroundColor(context.getColor(R.color.token_bg_primary))
        val root = FrameLayout(context).apply {
            setBackgroundColor(context.getColor(R.color.token_bg_primary))
            if (rtl) layoutDirection = android.view.View.LAYOUT_DIRECTION_RTL
        }
        val page = FrameLayout(context)
        val density = resources.displayMetrics.density
        root.addView(page, FrameLayout.LayoutParams(
            if (narrow) (NARROW_DP * density).toInt() else ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER_HORIZONTAL))
        val timeline = ChatTimelineView(context).also { timeline = it }
        page.addView(timeline, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        val composer = ComposerView(context)
        composer.attachTo(page)
        val mentions = if (scene != "models") null else TriggerMenu(context, composer.field, isRouter = true,
            tasks = { DEMO_TASKS }, skills = { emptyList() }, excludedTaskId = { null }, onNeedSkills = {},
            models = { DEMO_MODELS }).also { menu ->
            page.addView(menu.view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
                marginStart = (16 * density).toInt(); marginEnd = (16 * density).toInt()
            })
            composer.transformOutgoing = menu::serialize
        }
        setContentView(root)
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(bars.left, 0, bars.right, bars.bottom)
            timeline.setPadding(0, bars.top, 0, timeline.paddingBottom)
            insets
        }
        composer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            timeline.setComposerInset(kotlin.math.round(timeline.height - (composer.capsuleTop - timeline.y)).toInt())
            mentions?.let { followComposer(it.view, composer.height - (8 * density).toInt(), composer.liftPx) }
        }
        val active = ParticipantStatus("p", "active", null, null, null, null)
        fun state(entries: List<TimelineEntry>, working: Boolean) = ConversationState(conversationId = "demo",
            timeline = entries, participant = active.takeIf { working }, connection = surf.comma.android.conversation.Connection.LIVE)
        // The live chat's menu and copy actions, wired the same way.
        timeline.onLongPressMessage = { anchor, item ->
            val key = mapped?.rowEntries?.get(item.message.id)
            val blocks = key?.let { k -> shown?.let { entryBlocks(it, k) } }
            MessageActionsPopup.show(anchor, item, blocks ?: item.contents)
        }
        timeline.onReplyAction = { action, item ->
            when (action) {
                ReplyAction.COPY -> {
                    val text = item.message.cardPayload?.let { turn -> shown?.let { replyText(it, turn) } }.orEmpty()
                    if (text.isNotBlank()) MessageActionsPopup.copyMessage(this, text)
                    text.isNotBlank()
                }
            }
        }
        timeline.onCopyCode = { MessageActionsPopup.copyCode(this, it) }
        val precomputer = MessageLayoutPrecomputer(bubbles = true)
        var prepared = emptyList<surf.comma.android.chat.render.PreparedChatMessage>()
        suspend fun show(state: ConversationState) {
            val next = mapConversation(state, replyActions = true)
            mapped = next
            shown = state
            prepared = precomputer.prepareChanged(prepared, next.rows, timeline.width,
                density, resources.configuration.fontScale * DesignTypography.chatScale() * font, night,
                codeLabels = codeLabels(context), syntaxTheme = codeSyntaxTheme(context), palette = ChatPalette.from(context))
            timeline.submitPrepared(prepared)
        }
        if (mentions != null) {
            // What was sent shows as the client core shows a person's words: each model mention as `@name`.
            var said = scene(scene)
            composer.onSend = { text, _ ->
                android.util.Log.i("ChatBubblesDemo", "sent: $text")
                said = said + user(ModelMentionLinks.asWords(text))
                lifecycleScope.launch { show(state(said, working = false)) }
            }
        }
        timeline.doOnLayout {
            lifecycleScope.launch {
                if (scene != "arrive") {
                    show(state(scene(scene), working = scene == "typing" || scene == "mix"))
                    return@launch
                }
                // A reply of two messages arriving one after the other, over and over.
                val question = user("What's on this afternoon?")
                val first = agent("Two things: the **design review** at 14:00 and a one-to-one at 16:30.")
                val second = agent("Want me to move the one-to-one?")
                val before = listOf(user("Morning"), agent("Good morning!"))
                while (true) {
                    show(state(before, working = false))
                    kotlinx.coroutines.delay(1200)
                    show(state(before + question, working = true))
                    kotlinx.coroutines.delay(1800)
                    show(state(before + question + first, working = true))
                    kotlinx.coroutines.delay(1800)
                    show(state(before + question + first + second, working = false))
                    kotlinx.coroutines.delay(2500)
                }
            }
        }
    }

    private var seq = 0L
    private var mapped: LiveTimeline? = null

    private fun say(actor: String, text: String): TimelineEntry {
        seq += 1
        val user = actor == "user"
        val display = ChatMessage(messageId = "demo_$seq", seq = seq, role = if (user) ChatRole.USER else ChatRole.ASSISTANT,
            actorType = actor, agentId = "demo_agent".takeIf { !user }, clientRequestId = "demo-req-$seq".takeIf { user },
            replyToMessageId = null, threadRootMessageId = null, createdAt = 1_700_000_000_000L + seq * 60_000L,
            parts = listOf(MessagePart.Text(text)), attachments = emptyList(), refs = emptyList(), workspaceFiles = emptyList())
        return TimelineEntry.Message(display.clientRequestId?.let { "r:$it" } ?: "m:${display.messageId}", display)
    }

    private fun user(text: String) = say("user", text)
    private fun agent(text: String) = say("agent", text)

    private fun scene(name: String): List<TimelineEntry> = when (name) {
        "long" -> listOf(
            user("Can you summarise the plan for this week? Here is the doc: " +
                "https://example.org/team/planning/2026/week-41/notes-and-decisions-final-version-2.html"),
            agent(PLAN),
        )
        "code" -> listOf(
            user("How do I retry a request?"),
            agent("Wrap the call and back off between attempts:\n\n```kotlin\n" +
                "suspend fun <T> retrying(times: Int = 3, block: suspend () -> T): T {\n" +
                "    repeat(times - 1) { attempt -> runCatching { return block() }; delay(200L shl attempt) }\n" +
                "    return block()\n}\n```\n\nUse `retrying { api.fetch() }` where the call can fail."),
            user("Thanks"),
            agent("Ok"),
        )
        "table" -> listOf(
            user("Compare the three options"),
            agent("Here they are side by side:\n\n| Option | Cost per month | Setup time | Notes |\n|---|---|---|---|\n" +
                "| Basic | 10 | 1 day | Good enough for a small team |\n| Team | 45 | 3 days | Shared workspaces and roles |\n" +
                "| Enterprise | Custom | 2 weeks | Single sign-on, audit log, support |\n\nThe **Team** plan fits best."),
        )
        "image" -> listOf(
            user("What does the chart look like?"),
            agent("Here is the latest one:\n\n![chart](android.resource://$packageName/${R.drawable.fixture_image_02})\n\n" +
                "Traffic peaked on Tuesday."),
        )
        "scroll" -> (1..4).flatMap { listOf(user("Question $it"), agent(HISTORY)) } + listOf(
            user("把部署脚本和各区域状态发我"),
            agent(WIDE_REPLY),
            user("Thanks"),
            agent("短代码不用横滑：\n\n```sh\nls -la\n```\n\n两列的表也一样：\n\n| 区域 | 状态 |\n|---|---|\n| eu | 正常 |"),
        )
        "math" -> (1..3).flatMap { listOf(user("Question $it"), agent(HISTORY)) } + listOf(
            user("Explain the quadratic formula. It cost me $5 and $10 to buy the book, see `echo ${'$'}HOME`."),
            agent(MATH_REPLY),
            user("And a wide one?"),
            agent(WIDE_MATH),
        )
        "models" -> listOf(
            user("早上好"),
            agent("早上好！要我做点什么？在输入框里 @ 一个模型，就会用它新建一个 Task。"),
        )
        "gap" -> listOf(user("Morning"), agent("Good morning!"), TimelineEntry.Gap("gap:3"),
            agent("Your meeting moved to 3 pm."), say("system", "Workspace is ready"), user("Got it"))
        "notice" -> listOf(user("Set up the new workspace"), agent("Creating it now."),
            say("system", "Workspace is ready"), agent("Done. I invited the team."))
        "typing" -> listOf(user("Draft a reply to the landlord"), agent("Sure, a first version:"),
            ReplyDraft("demo-response", listOf("demo_1"), "demo-draft", 4, "Dear Mr Smith, thank you for", false)
                .let { TimelineEntry.Draft(it.key, it) })
        else -> listOf(
            user("早上好"),
            agent("早上好！有什么可以帮你？"),
            user("帮我看看下午的安排，另外提醒我给 Alex 回邮件"),
            agent("下午有两件事：\n\n1. **14:00** 产品评审（会议室 B）\n2. **16:30** 和 Alex 的一对一\n\n" +
                "我会在 16:00 提醒你回 Alex 的邮件。"),
            agent("需要我先起草一封回复吗？"),
            user("好"),
        )
    }

    private companion object {
        const val NARROW_DP = 320
        val DEMO_MODELS = listOf(
            MentionModel("gpt-5.5", "GPT 5.5", "openai", listOf("low", "medium", "high")),
            MentionModel("claude-opus-4.7", "Claude Opus 4.7", "anthropic", listOf("low", "medium", "high", "max")),
            MentionModel("gemini-3-pro", "Gemini 3 Pro", "google", emptyList()),
            MentionModel("kimi-k2", "Kimi K2", "moonshotai", emptyList()),
        )
        val DEMO_TASKS = listOf(
            TaskSummary("cnv1_demo1", "修复登录页的跳转", TaskStatusBucket.IN_PROGRESS, updatedAt = 2_000L),
            TaskSummary("cnv1_demo2", "整理本周会议纪要", TaskStatusBucket.IN_PROGRESS, updatedAt = 1_000L),
        )
        const val HISTORY = "An earlier answer, a few paragraphs long, so the list has room to scroll.\n\n" +
            "Second paragraph of it.\n\nThird paragraph, to make it taller."
        const val WIDE_REPLY = "部署脚本如下，长行可以横着滑：\n\n```kotlin\n" +
            "suspend fun deploy(region: String, version: String, dryRun: Boolean = false): Result<DeployReport> = retrying(times = 3) { api.deploy(region = region, version = version, dryRun = dryRun, notify = listOf(\"ops\", \"release\")) }\n" +
            "val report = deploy(region = \"eu-west-1\", version = \"2026.10.05-rc3\").getOrThrow()\n" +
            "println(\"${'$'}{report.region}: ${'$'}{report.instances} instances, ${'$'}{report.failed} failed, took ${'$'}{report.seconds}s (log at ${'$'}{report.logUrl})\")\n```\n\n" +
            "各区域状态：\n\n| 区域 | 版本 | 实例 | 失败 | 负责人 | 最后部署 | 备注 |\n|---|---|---|---|---|---|---|\n" +
            "| eu-west-1 | 2026.10.05-rc3 | 48 | 0 | Alex Chen | 10-05 09:12 | 正常 |\n" +
            "| us-east-2 | 2026.10.04 | 64 | 2 | Sam Li | 10-04 22:40 | 两台回滚中，等待确认 |\n" +
            "| ap-southeast-1 | 2026.10.04 | 32 | 0 | 王小明 | 10-04 23:05 | 正常 |\n\n" +
            "回滚命令：\n\n```sh\n" +
            "kubectl --context prod-us-east-2 -n api rollout undo deployment/api-server --to-revision=41 && kubectl --context prod-us-east-2 -n api rollout status deployment/api-server --timeout=300s\n```\n\n" +
            "有问题随时叫我。"
        const val MATH_REPLY = "For ${'$'}ax^2 + bx + c = 0${'$'} with ${'$'}a \\ne 0${'$'}, the roots are\n\n" +
            "${'$'}${'$'}\nx = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n${'$'}${'$'}\n\n" +
            "The part under the root, \\(\\Delta = b^2 - 4ac\\), decides how many real roots there are. " +
            "Sums and integrals sit on the line too: ${'$'}\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}${'$'} and ${'$'}\\int_0^1 x^2\\,dx = \\tfrac13${'$'}.\n\n" +
            "\\[\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1} = \\frac{1}{ad - bc} \\begin{pmatrix} d & -b \\\\ -c & a \\end{pmatrix}\\]\n\n" +
            "${'$'}${'$'}\n\\begin{aligned}\nf(x) &= (x + 1)^2 \\\\\n&= x^2 + 2x + 1\n\\end{aligned}\n${'$'}${'$'}\n\n" +
            "Highlighted: ${'$'}\\colorbox{yellow}{X} + \\fcolorbox{red}{yellow}{Y}${'$'}\n\n" +
            "- In a list: ${'$'}e^{i\\pi} + 1 = 0${'$'}\n- Prices stay prices: ${'$'}5 and ${'$'}10, and \\${'$'}20 too.\n\n" +
            "| Name | Formula |\n|---|---|\n| Area | ${'$'}\\pi r^2${'$'} |\n| Volume | ${'$'}\\frac{4}{3}\\pi r^3${'$'} |\n\n" +
            "Code is left alone: `${'$'}x${'$'}` and\n\n```sh\necho \"${'$'}HOME costs ${'$'}5\"\n```\n\n" +
            "A broken one keeps its source: ${'$'}\\frac{1}{${'$'} and ${'$'}${'$'}\\notacommand{x}${'$'}${'$'}."
        const val WIDE_MATH = "Too wide for the bubble, so it scrolls:\n\n" +
            "${'$'}${'$'}\n\\sum_{n=0}^{\\infty} \\frac{(-1)^n x^{2n+1}}{(2n+1)!} = x - \\frac{x^3}{3!} + \\frac{x^5}{5!} - \\frac{x^7}{7!} + \\frac{x^9}{9!} - \\frac{x^{11}}{11!} + \\frac{x^{13}}{13!} - \\cdots = \\sin x\n${'$'}${'$'}\n\n" +
            "And the end of the reply."
        const val PLAN = "## This week\n\nThree things matter most. The launch review on **Wednesday** decides the date, " +
            "so the checklist has to be done by Tuesday evening.\n\n- Finish the onboarding copy\n" +
            "- Run the migration on staging and `verify` the counts\n- Book the room for Friday\n\n" +
            "> Keep Thursday free for fixes.\n\nAfter that, the rest of the week is open for the hiring loop and " +
            "the quarterly notes. I left a link to the template in the doc."
    }
}
