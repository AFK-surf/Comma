package surf.comma.android.chat.live

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardHeights
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.AgentRequest
import surf.comma.android.conversation.AgentRequestInput
import surf.comma.android.conversation.AgentRequestOutcome
import surf.comma.android.conversation.AgentRequestStatus
import surf.comma.android.settings.SettingsDialog
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignTypography
import surf.comma.android.ui.theme.DesignTypography.Level
import kotlin.math.max

/** The account names the cards show for the providers an Agent connects; others show their id, capitalized. */
private val PROVIDER_NAMES = mapOf(
    "github" to "GitHub",
    "google" to "Google",
    "linear" to "Linear",
    "notion" to "Notion",
    "slack" to "Slack",
    "feishu" to "Feishu",
)

private const val SECRET_PROVIDER = "secret"
private const val CLI_PROVIDER = "cli"

/** Whether the card's main button asks for what the person fills in, not for a page to open. */
private fun AgentRequest.fills(): Boolean =
    input != null && input.kind != AgentRequestInput.Kind.DEVICE && input.kind != AgentRequestInput.Kind.OPEN

internal fun providerName(provider: String): String =
    PROVIDER_NAMES[provider] ?: provider.replaceFirstChar { it.uppercaseChar() }

/** The row's payload ([LiveRowKinds.AGENT_REQUEST]): the request as the core reads it. */
internal fun decodeAgentRequest(payload: String?): AgentRequest? =
    runCatching { AgentRequest.parse(JSONObject(payload ?: return null)) }.getOrNull()

/** How a request's card stands at [now]: open while it waits and its deadline has not passed, else a receipt. */
internal enum class AgentRequestShown { OPEN, CONNECTED, DECLINED, EXPIRED, CANCELLED, FAILED }

internal fun agentRequestShown(request: AgentRequest, now: Long): AgentRequestShown = when (request.status) {
    // A deadline that passed ends the request, though the server settles it only when it is next read.
    AgentRequestStatus.PENDING ->
        if (request.expiresAt != null && now >= request.expiresAt) AgentRequestShown.EXPIRED else AgentRequestShown.OPEN
    AgentRequestStatus.COMPLETED -> when (request.outcome) {
        AgentRequestOutcome.CONNECTED, AgentRequestOutcome.SHARED -> AgentRequestShown.CONNECTED
        AgentRequestOutcome.DECLINED -> AgentRequestShown.DECLINED
        null -> AgentRequestShown.FAILED
    }
    AgentRequestStatus.EXPIRED -> AgentRequestShown.EXPIRED
    AgentRequestStatus.CANCELLED -> AgentRequestShown.CANCELLED
    AgentRequestStatus.FAILED -> AgentRequestShown.FAILED
}

/** How sharing this device's position went: the core took it, or the card says why not. */
internal enum class AgentLocationAnswer { TAKEN, DENIED, UNAVAILABLE, FAILED }

/** What a request card does on the page that shows it. A page without one shows the card without its actions. */
internal interface AgentRequestCardHost {
    /** The requests whose page was opened here: their cards wait for the browser. Kept while the page lives. */
    val opened: MutableSet<String>

    /** Opens the provider's page in the browser. */
    fun authorize(url: String)

    /** Declines request [requestId]; [done] says on the main thread whether the core took it. */
    fun decline(requestId: String, done: (Boolean) -> Unit)

    /** Asks the person for what [request] needs, then sends it; [done] says on the main thread whether it was taken. */
    fun fill(request: AgentRequest, done: (Boolean) -> Unit)

    /** Asks the system for this device's position once, then sends it; [done] says on the main thread how it went. */
    fun shareLocation(requestId: String, done: (AgentLocationAnswer) -> Unit)

    /** Whether this phone is answering location request [requestId] by itself now: the card only says so. */
    fun answeringLocation(requestId: String): Boolean = false

    /** Calls [changed] when [answeringLocation] may have changed, until the returned function is called. */
    fun watchLocationAnswers(changed: () -> Unit): () -> Unit = {}
}

/** What fills in a request: a dialog keeps the keyboard and a secret away from the conversation's recycled rows. */
internal class AgentRequestFillDialog(
    activity: Activity,
    request: AgentRequest,
    onSave: (Map<String, String>) -> Unit,
) : SettingsDialog(activity, keyboard = true) {
    init {
        val strings = AgentRequestStrings(activity)
        val input = request.input
        val isApp = input?.kind == AgentRequestInput.Kind.APP
        val isPaste = input?.kind == AgentRequestInput.Kind.PASTE
        val appId = if (isApp) field(activity, activity.getString(R.string.chat_request_app_id), secret = false) else null
        val secret = field(activity, when {
            isApp -> activity.getString(R.string.chat_request_app_secret)
            isPaste -> activity.getString(R.string.chat_request_login_code)
            else -> strings.name(request)
        }, secret = !isPaste)
        card.addView(title(strings.title(request)))
        card.addView(message(if (input?.redirectUri != null) activity.getString(R.string.chat_request_fill_hint) +
            "\n" + activity.getString(R.string.chat_request_redirect_url) + ": " + input.redirectUri
            else activity.getString(R.string.chat_request_fill_hint)),
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(6) })
        for (view in listOfNotNull(appId, secret)) {
            card.addView(view, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(12) })
        }
        input?.helpUrl?.let { url ->
            card.addView(activity.text(Level.SMALL, R.color.token_label_brand).apply {
                text = if (isApp) activity.getString(R.string.chat_request_app_help, providerName(request.provider))
                    else activity.getString(R.string.chat_request_value_help)
                setOnClickListener {
                    runCatching { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(10) })
        }
        if (isPaste) request.authorizationUrl?.let { url ->
            card.addView(activity.text(Level.SMALL, R.color.token_label_brand).apply {
                text = activity.getString(R.string.chat_request_login_open)
                setOnClickListener {
                    runCatching { activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(10) })
        }
        val row = buttons(activity.getString(when {
            isApp -> R.string.chat_request_next
            isPaste -> R.string.chat_request_login_submit
            else -> R.string.chat_request_save
        }), false) {
            onSave(
                if (isApp) mapOf("client_id" to appId!!.text.toString().trim(),
                    "client_secret" to secret.text.toString().trim())
                else mapOf("value" to secret.text.toString()),
            )
        }
        val save = row.findViewById<TextView>(R.id.settings_dialog_confirm)
        fun validate() {
            val ready = secret.text.isNotBlank() && (appId == null || appId.text.isNotBlank())
            save.isEnabled = ready
            save.alpha = if (ready) 1f else 0.4f
        }
        appId?.doAfterTextChanged { validate() }
        secret.doAfterTextChanged { validate() }
        validate()
        card.addView(row, LinearLayout.LayoutParams(-1, -2).apply { topMargin = activity.dp(20) })
    }

    private fun field(activity: Activity, hint: String, secret: Boolean) = EditText(activity).apply {
        DesignTypography.applyTo(this, Level.REGULAR)
        setTextColor(activity.color(R.color.token_text_primary))
        setHintTextColor(activity.color(R.color.token_text_placeholder))
        this.hint = hint
        inputType = InputType.TYPE_CLASS_TEXT or
            (if (secret) InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS)
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        isSingleLine = true
        background = roundRect(activity.color(R.color.token_bg_quaternary), activity.dp(10).toFloat())
        setPadding(activity.dp(14), activity.dp(12), activity.dp(14), activity.dp(12))
    }
}

/** The card's words, read once. */
internal class AgentRequestStrings(private val context: Context) {
    val authorize: String = context.getString(R.string.chat_request_authorize)
    val reopen: String = context.getString(R.string.chat_request_reopen)
    val decline: String = context.getString(R.string.chat_request_decline)
    val waiting: String = context.getString(R.string.chat_request_waiting_browser)
    val openForm: String = context.getString(R.string.chat_request_open_form)
    val waitingForm: String = context.getString(R.string.chat_request_waiting_form)
    val declineFailed: String = context.getString(R.string.chat_request_decline_failed)
    val fill: String = context.getString(R.string.chat_request_fill)
    val copyAndOpen: String = context.getString(R.string.chat_request_login_copy_open)
    val fillFailed: String = context.getString(R.string.chat_request_fill_failed)
    val expired: String = context.getString(R.string.chat_request_expired)
    val cancelled: String = context.getString(R.string.chat_request_cancelled)
    val failed: String = context.getString(R.string.chat_request_failed)
    val shareLocation: String = context.getString(R.string.chat_request_location_share)
    val locating: String = context.getString(R.string.chat_request_location_locating)
    val locationDenied: String = context.getString(R.string.chat_request_location_denied)
    val locationUnavailable: String = context.getString(R.string.chat_request_location_unavailable)
    val locationFailed: String = context.getString(R.string.chat_request_location_failed)

    /** What a secret is called: the Agent's words for it. */
    fun name(request: AgentRequest): String = request.label ?: request.alias ?: providerName(request.provider)

    fun title(request: AgentRequest): String =
        if (request.isLocation) context.getString(R.string.chat_request_location_title)
        else if (request.provider == CLI_PROVIDER) context.getString(R.string.chat_request_login_title, request.alias.orEmpty())
        else if (request.provider == SECRET_PROVIDER) context.getString(R.string.chat_request_fill_title, name(request))
        else context.getString(R.string.chat_request_connect_title, providerName(request.provider))

    /** The receipt's line: how the request ended, and a note after it. */
    fun outcome(request: AgentRequest, shown: AgentRequestShown): String = when (shown) {
        AgentRequestShown.CONNECTED ->
            if (request.isLocation) context.getString(R.string.chat_request_location_shared)
            else if (request.provider == SECRET_PROVIDER) context.getString(R.string.chat_request_saved)
            else if (request.provider == CLI_PROVIDER) context.getString(R.string.chat_request_logged_in)
            else context.getString(R.string.chat_request_connected, providerName(request.provider)) +
                (request.account?.let { " · $it" } ?: "")
        AgentRequestShown.DECLINED ->
            if (request.isLocation) context.getString(R.string.chat_request_location_declined)
            else context.getString(R.string.chat_request_declined, providerName(request.provider))
        AgentRequestShown.EXPIRED -> expired
        AgentRequestShown.CANCELLED -> cancelled
        AgentRequestShown.FAILED, AgentRequestShown.OPEN -> failed
    }
}

/**
 * Request card heights, measured ahead of time from the payload with the question card's own type, so the list
 * knows each row's height before the view loads. An open card is measured as it first shows, before a status line.
 */
internal class AgentRequestCardLayout(
    context: Context,
    private val now: () -> Long = System::currentTimeMillis,
) : ChatCardHeights {
    private val style = QuestionCardStyle(context)
    private val strings = AgentRequestStrings(context)

    override fun bodyHeightPx(message: ChatMessage, rowWidthPx: Int, sideMarginPx: Int): Int? {
        if (message.cardKind != LiveRowKinds.AGENT_REQUEST) return null
        val request = decodeAgentRequest(message.cardPayload) ?: return 0
        val width = (rowWidthPx - sideMarginPx * 2).coerceAtLeast(1)
        val shown = agentRequestShown(request, now())
        return if (shown == AgentRequestShown.OPEN) openHeight(request, width)
        else receiptHeight(request, shown, width)
    }

    fun openHeight(request: AgentRequest, width: Int): Int = with(style) {
        // The account's mark stands beside the title and the reason.
        val mark = dp(MARK_DP)
        val column = width - headPad * 2 - mark - indicatorGap
        var text = prompt.height(strings.title(request), column)
        if (request.reason.isNotBlank()) text += headGap + description.height(request.reason, column)
        headPad + max(mark, text) + footTop + buttonH + footInset + dp(SHADOW_ROOM_DP)
    }

    fun receiptHeight(request: AgentRequest, shown: AgentRequestShown, width: Int): Int = with(style) {
        val column = width - receiptPadStart - receiptPadEnd - receiptIcon - receiptGap
        val answer = receiptStyle(shown)
        val text = receiptPrompt.height(strings.title(request), column) + receiptLineGap +
            answer.height(strings.outcome(request, shown), column)
        receiptPadV * 2 + max(receiptIconTop(answer) + receiptIcon, text) + dp(SHADOW_ROOM_DP)
    }

    private fun receiptStyle(shown: AgentRequestShown) =
        if (shown == AgentRequestShown.CONNECTED) style.receiptAnswer else style.receiptMuted
}

/** The account's mark tile, and the mark in it. */
private const val MARK_DP = 40f
private const val MARK_GLYPH_DP = 22f
/** The shadow xs colour (gray 900, #101828). */
private const val SHADOW_XS = 0xFF101828.toInt()
/** Below the card, the room its shadow xs (0 1 2) takes. */
private const val SHADOW_ROOM_DP = 2f

/** The design's shadow xs (0 1 2, gray 900 at 5%), drawn by the outline's elevation. */
private fun View.shadowXs() {
    elevation = resources.displayMetrics.density
    outlineAmbientShadowColor = SHADOW_XS
    outlineSpotShadowColor = SHADOW_XS
}

internal class AgentRequestCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.AGENT_REQUEST

    /** A rough height for a page that does not measure the card; the pages that show it use [AgentRequestCardLayout]. */
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float): Float = 72f

    override fun create(context: Context): View = AgentRequestCardView(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as AgentRequestCardView).bind(item)
    override fun release(view: View) = (view as AgentRequestCardView).release()
}

/**
 * An Agent's request to the person ([LiveRowKinds.AGENT_REQUEST]), in the question card's shell. The server decides
 * how it ends; the card shows what the core says, so every device shows the same ending. Authorizing opens the
 * provider's page in the browser; the provider's verified answer ends the request, and the card becomes its receipt.
 * Declining asks the core. On a phone it says only what is asked and why; a status line shows only after the person
 * acted (the browser is open, or the decline did not go). At its deadline the card closes into its receipt.
 */
@SuppressLint("ViewConstructor")
internal class AgentRequestCardView(
    context: Context,
    private val now: () -> Long = System::currentTimeMillis,
) : FrameLayout(context) {
    private val style = QuestionCardStyle(context)
    private val strings = AgentRequestStrings(context)

    /** The page's way to answer; the adapter gives it. None: an open card's buttons do nothing. */
    var hostOf: () -> AgentRequestCardHost? = { null }

    // ---- The open card ----
    /** The account's mark, on a bordered, lightly shadowed tile beside the title. */
    private val markGlyph = ImageView(context)
    private val mark = FrameLayout(context).apply {
        // A 1dp border and the design's shadow xs (0 1 2, the dark gray at 5%), drawn by the outline's elevation.
        background = GradientDrawable().apply {
            cornerRadius = style.dp(10f).toFloat()
            setColor(style.bgPrimary)
            setStroke(style.dp(1f), style.border)
        }
        shadowXs()
        addView(markGlyph, LayoutParams(style.dp(MARK_GLYPH_DP), style.dp(MARK_GLYPH_DP), Gravity.CENTER))
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val title = text(style.prompt, style.textPrimary)
    private val reason = text(style.description, style.textSecondary)
    private val note = text(style.note, style.textSecondary).apply { setPadding(style.noteSide, 0, style.noteSide, 0) }
    val decline = context.filledButton(strings.decline, R.color.token_bg_quaternary, R.color.token_text_primary)
    val authorize = context.filledButton(strings.authorize, R.color.token_bg_brand_solid, null)
    private val form = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply {
            cornerRadius = style.cardRadius
            setColor(style.cardFill)
            setStroke(style.hairline, style.border)
        }
        shadowXs()
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.TOP
            setPadding(style.headPad, style.headPad, style.headPad, 0)
            addView(mark, LinearLayout.LayoutParams(style.dp(MARK_DP), style.dp(MARK_DP)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(title, matchWidth())
                addView(reason, matchWidth().apply { topMargin = style.headGap })
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = style.indicatorGap })
        })
        addView(note, matchWidth().apply { topMargin = style.noteTop })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(style.footInset, style.footTop, style.footInset, style.footInset)
            addView(decline, LinearLayout.LayoutParams(0, style.buttonH, 1f))
            addView(authorize, LinearLayout.LayoutParams(0, style.buttonH, 2f).apply { marginStart = style.buttonGap })
        })
    }

    // ---- The receipt ----
    private val receiptGlyph = ImageView(context)
    private val receiptIcon = FrameLayout(context).apply {
        addView(receiptGlyph, LayoutParams(style.receiptGlyph, style.receiptGlyph, Gravity.CENTER))
    }
    private val receiptTitle = text(style.receiptPrompt, style.textSecondary)
    private val receiptOutcome = TextView(context)
    private val receipt = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.TOP
        setPadding(style.receiptPadStart, style.receiptPadV, style.receiptPadEnd, style.receiptPadV)
        background = style.rowBackground(style.cardFill, style.receiptRadius, style.borderSecondary)
        shadowXs()
        addView(receiptIcon, LinearLayout.LayoutParams(style.receiptIcon, style.receiptIcon))
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(receiptTitle, matchWidth())
            addView(receiptOutcome, matchWidth().apply { topMargin = style.receiptLineGap })
        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = style.receiptGap })
    }

    private var item: PreparedChatMessage? = null
    private var request: AgentRequest? = null
    private var declining = false
    private var declineFailed = false
    private var fillFailed = false
    private var locating = false
    private var locationNote: String? = null
    // Not View.postDelayed, which holds its callbacks until the view is attached.
    private val clock = Handler(Looper.getMainLooper())
    private val tick = Runnable { render() }
    private var unwatchAnswers: (() -> Unit)? = null

    init {
        addView(form)
        addView(receipt)
        form.visibility = GONE
        receipt.visibility = GONE
        authorize.setOnClickListener {
            val current = request ?: return@setOnClickListener
            val host = hostOf() ?: return@setOnClickListener
            if (current.isLocation) {
                if (locating) return@setOnClickListener
                locating = true
                locationNote = null
                host.shareLocation(current.id) { answer ->
                    locating = false
                    locationNote = when (answer) {
                        AgentLocationAnswer.TAKEN -> null
                        AgentLocationAnswer.DENIED -> strings.locationDenied
                        AgentLocationAnswer.UNAVAILABLE -> strings.locationUnavailable
                        AgentLocationAnswer.FAILED -> strings.locationFailed
                    }
                    if (request?.id == current.id) render()
                }
                render()
                return@setOnClickListener
            }
            if (current.fills()) {
                fillFailed = false
                host.fill(current) { taken ->
                    fillFailed = !taken
                    if (request?.id == current.id) render()
                }
                render()
                return@setOnClickListener
            }
            val url = current.authorizationUrl ?: return@setOnClickListener
            current.input?.code?.let { code ->
                context.getSystemService(ClipboardManager::class.java)
                    ?.setPrimaryClip(ClipData.newPlainText(null, code))
            }
            host.opened += current.id
            host.authorize(url)
            render()
        }
        decline.setOnClickListener {
            val current = request ?: return@setOnClickListener
            val host = hostOf() ?: return@setOnClickListener
            if (declining) return@setOnClickListener
            declining = true
            declineFailed = false
            host.decline(current.id) { taken ->
                declining = false
                if (!taken) declineFailed = true
                if (request?.id == current.id) render()
            }
            render()
        }
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        show(decodeAgentRequest(item.message.cardPayload))
        requestLayout()
    }

    /** Shows [next]: the open card while it waits, its receipt once it ended. */
    fun show(next: AgentRequest?) {
        if (next?.id != request?.id) {
            declining = false
            declineFailed = false
            fillFailed = false
            locating = false
            locationNote = null
        }
        request = next
        render()
    }

    private fun render() {
        clock.removeCallbacks(tick)
        val current = request
        if (current == null) {
            form.visibility = GONE
            receipt.visibility = GONE
            return
        }
        val at = now()
        val shown = agentRequestShown(current, at)
        if (shown != AgentRequestShown.OPEN) {
            showReceipt(current, shown)
            return
        }
        val host = hostOf()
        val opened = host != null && current.id in host.opened
        title.text = strings.title(current)
        if (current.isLocation) {
            markGlyph.setImageResource(R.drawable.ic_action_location)
            markGlyph.setColorFilter(style.textPrimary)
        } else {
            markGlyph.clearColorFilter()
            markGlyph.setImageDrawable(surf.comma.android.routines.ProviderMarks.drawable(context, current.provider))
        }
        reason.text = current.reason
        reason.isVisible = current.reason.isNotBlank()
        val answering = current.isLocation && host?.answeringLocation(current.id) == true
        val status = when {
            declineFailed -> strings.declineFailed
            fillFailed -> strings.fillFailed
            locating || answering -> strings.locating
            locationNote != null -> locationNote
            current.input?.code != null -> current.input.code
            opened && current.provider == SECRET_PROVIDER -> strings.waitingForm
            opened -> strings.waiting
            else -> null
        }
        note.text = status.orEmpty()
        note.isVisible = status != null
        // The deadline closes the card into its receipt.
        current.expiresAt?.let { clock.postDelayed(tick, it - at) }
        authorize.text = when {
            current.isLocation -> strings.shareLocation
            current.fills() -> strings.fill
            opened -> strings.reopen
            current.input?.code != null -> strings.copyAndOpen
            // A secret the card cannot take (one with fields) is filled in on Comma's own form.
            current.provider == SECRET_PROVIDER -> strings.openForm
            else -> strings.authorize
        }
        authorize.isEnabled = host != null &&
            (if (current.isLocation) !locating && !answering else current.fills() || current.authorizationUrl != null)
        authorize.alpha = if (authorize.isEnabled) 1f else DISABLED_ALPHA
        decline.isEnabled = host != null && !declining
        decline.alpha = if (decline.isEnabled) 1f else DISABLED_ALPHA
        receipt.visibility = GONE
        if (form.visibility != VISIBLE) {
            form.visibility = VISIBLE
            requestLayout()
        }
    }

    private fun showReceipt(current: AgentRequest, shown: AgentRequestShown) {
        val wasOpen = form.isVisible
        form.visibility = GONE
        receipt.visibility = VISIBLE
        receiptTitle.text = strings.title(current)
        val connected = shown == AgentRequestShown.CONNECTED
        (if (connected) style.receiptAnswer else style.receiptMuted).applyTo(receiptOutcome)
        receiptOutcome.setTextColor(if (connected) style.textPrimary else style.textSecondary)
        receiptOutcome.text = strings.outcome(current, shown)
        receiptIcon.layoutParams = (receiptIcon.layoutParams as LinearLayout.LayoutParams).apply {
            topMargin = style.receiptIconTop(if (connected) style.receiptAnswer else style.receiptMuted)
        }
        receiptIcon.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (connected) style.brand else style.bgTertiary)
        }
        receiptGlyph.setImageResource(when (shown) {
            AgentRequestShown.CONNECTED -> R.drawable.ic_composer_check
            AgentRequestShown.DECLINED -> R.drawable.ic_action_cross_small
            AgentRequestShown.EXPIRED -> R.drawable.ic_history
            else -> R.drawable.ic_arrow_rotate_cw
        })
        receiptGlyph.setColorFilter(if (connected) style.onBrand else style.textTertiary)
        receipt.contentDescription = "${receiptTitle.text}\n${receiptOutcome.text}"
        // The deadline passed on screen: the open card closes into its receipt.
        if (wasOpen) requestLayout()
    }

    /** The receipt's line when the card is closed, or null while it is open; for tests. */
    internal val receiptLine: CharSequence? get() = if (receipt.isVisible) receiptOutcome.text else null

    /** The open card's status line, or null; for tests. */
    internal val noteShown: CharSequence? get() = note.text.takeIf { form.isVisible && note.isVisible }

    fun release() {
        clock.removeCallbacks(tick)
        unwatchAnswers?.invoke()
        unwatchAnswers = null
    }

    override fun onDetachedFromWindow() {
        release()
        super.onDetachedFromWindow()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        unwatchAnswers = hostOf()?.watchLocationAnswers { render() }
        render()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val current = item
        val side = current?.sideMarginPx ?: 0
        val top = current?.topMarginPx ?: 0
        val content = shown()
        if (content == null) {
            setMeasuredDimension(width, top)
            return
        }
        content.measure(MeasureSpec.makeMeasureSpec((width - side * 2).coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        // Room under the card for its shadow, which the row would otherwise cut off.
        setMeasuredDimension(width, top + content.measuredHeight + style.dp(SHADOW_ROOM_DP))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val content = shown() ?: return
        val left = item?.sideMarginPx ?: 0
        val top = item?.topMarginPx ?: 0
        content.layout(left, top, left + content.measuredWidth, top + content.measuredHeight)
    }

    private fun shown(): View? = when {
        form.isVisible -> form
        receipt.isVisible -> receipt
        else -> null
    }

    private fun text(type: QuestionText, color: Int) = TextView(context).apply {
        type.applyTo(this)
        setTextColor(color)
    }

    private fun matchWidth() =
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)

    private companion object {
        const val DISABLED_ALPHA = 0.5f
    }
}
