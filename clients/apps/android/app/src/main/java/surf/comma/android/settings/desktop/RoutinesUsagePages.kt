package surf.comma.android.settings.desktop

import android.app.TimePickerDialog
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.view.Gravity
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import androidx.core.view.isVisible
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import surf.comma.android.R
import surf.comma.android.routines.ProviderMarks
import surf.comma.android.settings.SettingsContext
import surf.comma.android.settings.SettingsRow
import surf.comma.android.settings.SettingsSection
import surf.comma.android.settings.SettingsSwitch
import surf.comma.android.settings.dp
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.text.NumberFormat
import java.util.Calendar

/** Settings > Routines: the daily briefing, its sources, and the owner's proactive messages. */
internal class RoutinesSettingsPage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_routines, KEY) {
    private val model = scope?.let { RoutinesSettingsModel(it) }
    private val scheduled = SwitchRow(activity, activity.getString(R.string.ds_routines_scheduled)) { on -> launch { model?.setSchedule(enabled = on) } }
    private val time = SettingsRow(activity, null, activity.getString(R.string.ds_routines_time))
    private val zone = SettingsRow(activity, null, activity.getString(R.string.ds_routines_zone))
    private val briefing = SettingsSection(activity, activity.getString(R.string.ds_routines_briefing)).add(scheduled.row).add(time).add(zone)
        .footer(activity.getString(R.string.ds_routines_briefing_footer))
    private val sources = SettingsSection(activity, activity.getString(R.string.ds_routines_sources))
        .footer(activity.getString(R.string.ds_routines_sources_footer))
    private val autoEnable = SwitchRow(activity, activity.getString(R.string.ds_routines_auto_enable)) { on ->
        launch { model?.save(json("autoEnableNewSources" to on)) }
    }
    private val proactiveSwitch = SwitchRow(activity, activity.getString(R.string.ds_routines_allow_proactive)) { on -> launch { model?.setProactive(on) } }
    private val proactive = SettingsSection(activity, activity.getString(R.string.ds_routines_proactive))
        .footer(activity.getString(R.string.ds_routines_proactive_footer))
    private var proactiveJob = model?.followProactive()

    init {
        time.onClick {
            val model = model ?: return@onClick
            TimePickerDialog(activity, { _, hour, minute -> launch { model.setSchedule(hour = hour, minute = minute) } },
                model.hour, model.minute, DateFormat.is24HourFormat(activity)).show()
        }
        layout.section(briefing, top = 0)
        layout.section(sources)
        layout.section(proactive)
        model?.follow()
        start { model?.refresh() }
    }

    override fun render() {
        super.render()
        val model = model ?: return
        loading.isVisible = !model.loaded
        briefing.isVisible = model.settings != null
        sources.isVisible = model.settings != null
        scheduled.set(model.enabled)
        val calendar = Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, model.hour); set(Calendar.MINUTE, model.minute) }
        time.value(DateFormat.getTimeFormat(activity).format(calendar.time), chevron = true)
        time.isEnabled = model.enabled
        zone.value(model.zone)
        autoEnable.set(model.autoEnable)
        val rows = model.sources.map { source ->
            val switch = SettingsSwitch(activity).apply { set(source.enabled, animate = false) }
            LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = activity.dp(50)
                setPadding(activity.dp(14), activity.dp(10), activity.dp(10), activity.dp(10))
                addView(ImageView(activity).apply {
                    setImageDrawable(ProviderMarks.drawable(activity, source.appId))
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LinearLayout.LayoutParams(activity.dp(24), activity.dp(24)))
                addView(LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(activity.text(Level.REGULAR, R.color.token_text_primary).apply { text = source.appName })
                    source.label?.let { label -> addView(activity.text(Level.SMALL, R.color.token_text_tertiary).apply { text = label }) }
                    if (source.needsReconnect) addView(activity.text(Level.SMALL, R.color.token_text_error_primary).apply {
                        text = activity.getString(R.string.ds_routines_reconnect)
                    })
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = activity.dp(8) })
                addView(switch)
                setOnClickListener { launch { model.setSource(source, !source.enabled) } }
            }
        }
        sources.fill(rows.ifEmpty { listOf(activity.noteRow(activity.getString(R.string.ds_routines_no_sources))) } + autoEnable.row)
        val state = model.proactive
        proactive.fill(listOf(when (state?.string("kind")) {
            "ready" -> proactiveSwitch.row.also { proactiveSwitch.set(state.optBoolean("enabled")) }
            "owner-only" -> activity.noteRow(activity.getString(R.string.ds_routines_owner_only))
            "failed" -> activity.actionRow(activity.getString(R.string.ds_routines_retry_proactive)) {
                proactiveJob?.cancel()
                proactiveJob = model.followProactive()
            }
            else -> activity.noteRow(activity.getString(R.string.settings_devices_loading))
        }))
    }

    companion object { const val KEY = "routines" }
}

/** Settings > Usage: credits, the plan and its cycle, and credit balances. It refreshes on entry and on return. */
internal class UsagePage(ctx: SettingsContext) : WorkspacePage(ctx, R.string.ds_usage, KEY) {
    private val model = scope?.let(::UsageModel)
    private val credits = activity.text(Level.TITLE1, R.color.token_text_primary, DesignFonts.semibold)
    private val creditsNote = activity.text(Level.SMALL, R.color.token_text_error_primary)
    private val available = SettingsSection(activity, activity.getString(R.string.ds_usage_available)).add(LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(activity.dp(16), activity.dp(16), activity.dp(16), activity.dp(16))
        addView(credits)
        addView(creditsNote, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
    })
    private val plan = SettingsSection(activity, activity.getString(R.string.ds_usage_plan))
    private val balances = SettingsSection(activity, activity.getString(R.string.ds_usage_balances))
    private val resume = object : DefaultLifecycleObserver {
        override fun onResume(owner: LifecycleOwner) { launch { model?.refresh() } }
    }

    init {
        layout.section(available, top = 0)
        layout.section(plan)
        layout.section(balances)
        model?.follow()
        activity.lifecycle.addObserver(resume)
        start { model?.refresh() }
    }

    override fun onClose() = activity.lifecycle.removeObserver(resume)

    override fun render() {
        super.render()
        val model = model ?: return
        val ready = model.status == "ready"
        loading.isVisible = model.status != "ready" && model.status != "unavailable"
        if (model.status == "unavailable" && model.scope.error == null) showError(PageError.Text(R.string.ds_usage_load_failed)) { model.refresh() }
        available.isVisible = ready
        plan.isVisible = ready && !model.unlimited
        balances.isVisible = ready && !model.unlimited && model.grants.isNotEmpty()
        if (!ready) return
        credits.text = if (model.unlimited) activity.getString(R.string.ds_usage_unlimited) else NumberFormat.getIntegerInstance().format(model.credits)
        val percent = model.allowance?.int("percent")
        creditsNote.text = when {
            model.unlimited -> null
            model.credits == 0L -> activity.getString(R.string.ds_usage_none_left)
            percent != null && percent <= 10 -> activity.getString(R.string.ds_usage_low)
            else -> null
        }
        creditsNote.isVisible = !creditsNote.text.isNullOrEmpty()
        val rows = mutableListOf<View>(activity.infoRow(activity.getString(R.string.ds_usage_plan_name),
            model.planName?.ifEmpty { activity.getString(R.string.ds_usage_subscription) } ?: activity.getString(R.string.ds_usage_no_subscription)))
        model.subscription?.let { rows += activity.infoRow(activity.getString(R.string.ds_status), subscriptionStatus(it.string("status"))) }
        model.usage?.let { usage ->
            usage.int("usedPercent")?.let { used ->
                rows += LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
                    addView(LinearLayout(activity).apply {
                        addView(activity.text(Level.REGULAR, R.color.token_text_primary).apply { text = activity.getString(R.string.ds_usage_cycle) },
                            LinearLayout.LayoutParams(0, -2, 1f))
                        addView(activity.text(Level.REGULAR, R.color.token_text_tertiary).apply { text = activity.getString(R.string.ds_usage_used, used.toInt()) })
                    })
                    addView(ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
                        max = 100
                        progress = used.toInt().coerceIn(0, 100)
                        progressTintList = android.content.res.ColorStateList.valueOf(activity.getColor(R.color.token_bg_brand_solid))
                        contentDescription = activity.getString(R.string.ds_usage_cycle)
                    }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(8) })
                }
            }
            UsageModel.date(usage.string("resetsAt"))?.let { date ->
                rows += activity.infoRow(activity.getString(if (usage.optBoolean("ends")) R.string.ds_usage_expire else R.string.ds_usage_reset),
                    DateUtils.formatDateTime(activity, date.toEpochMilli(), DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_YEAR))
            }
            usage.int("otherCredits")?.takeIf { it > 0 }?.let {
                rows += activity.infoRow(activity.getString(R.string.ds_usage_other), NumberFormat.getIntegerInstance().format(it))
            }
        }
        plan.fill(rows)
        balances.fill(model.grants.map { grant ->
            val expiry = UsageModel.date(grant.string("expires_at"))?.let {
                activity.getString(R.string.ds_expires, DateUtils.formatDateTime(activity, it.toEpochMilli(),
                    DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_SHOW_YEAR))
            }
            SettingsRow(activity, null, grantTitle(grant.string("source_type"))).detail(expiry)
                .value(NumberFormat.getIntegerInstance().format(grant.int("remaining_credits") ?: 0))
        })
    }

    private fun subscriptionStatus(status: String?) = activity.getString(when (status) {
        "active" -> R.string.ds_usage_active
        "trialing" -> R.string.ds_usage_trial
        "past_due" -> R.string.ds_usage_past_due
        "unpaid" -> R.string.ds_usage_unpaid
        "paused" -> R.string.ds_usage_paused
        else -> R.string.ds_unavailable
    })

    private fun grantTitle(source: String?) = activity.getString(when (source) {
        "subscription_cycle", "redeem_subscription_cycle" -> R.string.ds_usage_grant_subscription
        "comma_signup" -> R.string.ds_usage_grant_welcome
        "credit_pack", "purchase" -> R.string.ds_usage_grant_pack
        else -> R.string.ds_usage_grant_other
    })

    companion object { const val KEY = "usage" }
}
