package surf.comma.android.dynamicui

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.text.TextUtils
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import surf.comma.android.BuildConfig
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.ui.AppearanceStore
import surf.comma.android.ui.kit.CapsuleButton
import surf.comma.android.ui.kit.CommaSheet
import surf.comma.android.ui.kit.dp
import surf.comma.android.ui.kit.label
import surf.comma.android.ui.kit.rounded
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.ui.theme.NativeWebTokens
import surf.comma.android.workspace.WorkspaceGraph
import java.util.Locale
import java.util.TimeZone

/**
 * One chat widget in a full-height sheet, after a tap, as on iOS: one isolated runtime per sheet, destroyed when the
 * sheet closes. A proposal reaches the chat's draft only through Add to draft, and is sent later by the member; a link
 * opens only after the member confirms it.
 */
class DynamicUiSheet private constructor(
    activity: ComponentActivity,
    private val model: DynamicUiModel,
    private val scope: CoroutineScope,
    private val fillDraft: (String) -> Unit,
) : CommaSheet(activity, activity.getString(R.string.dynamic_ui_title), Detent.LARGE) {
    private val stage = FrameLayout(activity)
    private val progress = ProgressBar(activity)
    private val failure = activity.label(Level.REGULAR, R.color.token_text_secondary, lines = 4).apply {
        gravity = Gravity.CENTER
        isVisible = false
    }
    private val proposalText = activity.label(Level.REGULAR, R.color.token_text_primary, lines = 6).apply {
        ellipsize = TextUtils.TruncateAt.END
    }
    private val proposal = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(activity.getColor(R.color.token_bg_secondary), activity.resources.getDimension(R.dimen.card_corner))
        val margin = activity.resources.getDimensionPixelSize(R.dimen.spacing_xl)
        setPadding(margin, margin, margin, margin)
        isVisible = false
    }
    private var host: DynamicUiWebHost? = null
    private var linkDialog: SettingsDialog? = null
    private var shownLink: String? = null

    init {
        val margin = activity.resources.getDimensionPixelSize(R.dimen.spacing_xl)
        stage.addView(progress, FrameLayout.LayoutParams(activity.dp(24), activity.dp(24), Gravity.CENTER))
        stage.addView(failure, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER).apply {
            marginStart = margin
            marginEnd = margin
        })
        proposal.addView(proposalText, LinearLayout.LayoutParams(-1, -2))
        proposal.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(CapsuleButton(activity, activity.getString(R.string.settings_cancel)).apply {
                setOnClickListener { model.dismissProposal() }
            })
            addView(CapsuleButton(activity, activity.getString(R.string.dynamic_ui_add_to_draft)).apply {
                setOnClickListener {
                    model.takeProposal()?.let(fillDraft)
                    dismiss()
                }
            }, LinearLayout.LayoutParams(-2, -2).apply { marginStart = activity.dp(8) })
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        setContent(LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(activity.getColor(R.color.token_card_primary))
            addView(stage, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(proposal, LinearLayout.LayoutParams(-1, -2).apply {
                marginStart = margin
                marginEnd = margin
                bottomMargin = margin
            })
        })
    }

    override fun onShown() {
        model.start()
        scope.launch { model.state.collect(::render) }
    }

    private fun render(state: DynamicUiModel.State) {
        val ui = state.ui
        if (host == null && ui != null && state.stateLoaded && state.unavailable == null && !state.failed) startRuntime()
        val reason = when {
            state.failed -> state.failure ?: activity.getString(R.string.dynamic_ui_failed)
            state.unavailable != null -> state.unavailable.ifEmpty { activity.getString(R.string.dynamic_ui_load_failed) }
            else -> null
        }
        failure.text = reason
        failure.isVisible = reason != null
        host?.webView?.isVisible = reason == null
        progress.isVisible = reason == null && !state.runtimeReady
        proposalText.text = state.proposal
        proposal.isVisible = state.proposal != null
        if (state.link != shownLink) {
            shownLink = state.link
            linkDialog?.dismiss()
            linkDialog = state.link?.let { link ->
                LinkDialog(activity, link, open = { model.takeLink(link)?.let(::open) }, close = { model.dismissLink(link) })
                    .also { it.show() }
            }
        }
    }

    private fun startRuntime() {
        val dark = AppearanceStore.isNight(activity)
        val runtime = runCatching { DynamicUiWebHost(activity) { frame -> receive(frame) } }.getOrElse {
            model.fail(activity.getString(R.string.dynamic_ui_runtime_missing))
            return
        }
        host = runtime
        stage.addView(runtime.webView, 0, FrameLayout.LayoutParams(-1, -1))
        val theme = NativeWebTokens.values(activity, dark).mapKeys { it.key.removePrefix("--comma-") } +
            mapOf("scheme" to (if (dark) "dark" else "light"),
                "space" to "${css(R.dimen.spacing_xl)}px", "radius" to "${css(R.dimen.card_corner)}px")
        runtime.start(model.initialization(theme, copy(), Locale.getDefault().toLanguageTag(), TimeZone.getDefault().id))
    }

    private fun css(dimen: Int) = (activity.resources.getDimension(dimen) / activity.resources.displayMetrics.density).toInt()

    private fun receive(frame: DynamicUiFrame) {
        when (frame) {
            is DynamicUiFrame.Event -> model.receive(frame.event)
            is DynamicUiFrame.Failed -> model.fail(frame.reason.ifEmpty { null })
            DynamicUiFrame.Started, DynamicUiFrame.Connected -> Unit
        }
    }

    private fun open(url: String) {
        if (!DynamicUiEvent.isOpenableLink(url)) return
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
        } catch (_: ActivityNotFoundException) {
        }
    }

    /** The runtime's words, as the iOS app gives them. */
    private fun copy(): Map<String, String> = mapOf(
        "recommended" to R.string.dynamic_ui_copy_recommended, "alternatives" to R.string.dynamic_ui_copy_alternatives,
        "high" to R.string.dynamic_ui_copy_high, "low" to R.string.dynamic_ui_copy_low,
        "feelsLike" to R.string.dynamic_ui_copy_feels_like, "humidity" to R.string.dynamic_ui_copy_humidity,
        "ongoing" to R.string.dynamic_ui_copy_ongoing, "directions" to R.string.dynamic_ui_copy_directions,
        "range" to R.string.dynamic_ui_copy_range, "days" to R.string.dynamic_ui_copy_days,
        "attribute" to R.string.dynamic_ui_copy_attribute, "option" to R.string.dynamic_ui_copy_option,
        "checklistProgress" to R.string.dynamic_ui_copy_checklist_progress, "focus" to R.string.dynamic_ui_copy_focus,
        "rest" to R.string.dynamic_ui_copy_rest, "paused" to R.string.dynamic_ui_copy_paused,
        "timeUp" to R.string.dynamic_ui_copy_time_up, "timerCycle" to R.string.dynamic_ui_copy_timer_cycle,
        "arrivesBy" to R.string.dynamic_ui_copy_arrives_by, "orderHeadline" to R.string.dynamic_ui_copy_order_headline,
        "offline" to R.string.dynamic_ui_copy_offline, "upNext" to R.string.dynamic_ui_copy_up_next,
        "partFailed" to R.string.dynamic_ui_copy_part_failed,
    ).mapValues { activity.getString(it.value) } + ("versus" to "VS")

    override fun onRemoved() {
        linkDialog?.dismiss()
        linkDialog = null
        host?.let { (it.webView.parent as? android.view.ViewGroup)?.removeView(it.webView) }
        host?.stop()
        host = null
        model.stop()
        scope.cancel()
    }

    private class LinkDialog(activity: Activity, link: String, private val open: () -> Unit, private val close: () -> Unit) :
        SettingsDialog(activity) {
        init {
            card.addView(title(activity.getString(R.string.dynamic_ui_open_link_title)))
            card.addView(message(link).apply {
                maxLines = 6
                ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
            card.addView(buttons(activity.getString(R.string.dynamic_ui_open_link), destructive = false) { open() },
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
        }

        override fun onClosing() = close()
    }

    companion object {
        /** Opens [target] over [activity] in the current account and Workspace; nothing without them. */
        fun open(activity: ComponentActivity, target: DynamicUiTarget, fillDraft: (String) -> Unit) {
            val core = AuthGraph.core(activity) ?: return
            val workspaces = WorkspaceGraph.get(activity)
            val workspace = workspaces.workspace ?: return
            val account = workspaces.accountId ?: return
            val current = { workspaces.workspace?.id == workspace.id && workspaces.accountId == account }
            val scope = CoroutineScope(SupervisorJob(activity.lifecycleScope.coroutineContext[Job]) +
                kotlinx.coroutines.Dispatchers.Main.immediate)
            val model = DynamicUiModel(core, target, workspace.groupId,
                DynamicUiModel.stateKey(BuildConfig.BACKEND_BASE_URL, account, workspace.id, target.id), current, scope)
            DynamicUiSheet(activity, model, scope, fillDraft).show()
        }
    }
}
