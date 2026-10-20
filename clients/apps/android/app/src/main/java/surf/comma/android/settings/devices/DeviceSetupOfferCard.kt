package surf.comma.android.settings.devices

import android.content.Context
import android.content.ContextWrapper
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.settings.SettingsActivity
import surf.comma.android.settings.dp
import surf.comma.android.settings.filledButton
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography

internal class DeviceSetupOfferCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = DeviceSetupOffer.TYPE
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) =
        if (DeviceSetupOffer.parse(message.cardPayload)?.status in setOf("done", "expired", "dismissed")) 88f else 168f
    override fun create(context: Context): View = DeviceSetupOfferCard(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as DeviceSetupOfferCard).bind(item)
}

/** Native, accessible buttons under the agent's message. No BLE address survives in this card. */
internal class DeviceSetupOfferCard(context: Context) : FrameLayout(context) {
    private val title = context.text(DesignTypography.Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold)
    private val status = context.text(DesignTypography.Level.SMALL, R.color.token_text_tertiary)
    val connect = context.filledButton("Connect", R.color.token_bg_brand_solid, null)
    val dismiss = context.filledButton("Not now", R.color.token_bg_quaternary, R.color.token_text_primary)
    private val buttons = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(connect, LinearLayout.LayoutParams(0, context.dp(48), 1f))
        addView(dismiss, LinearLayout.LayoutParams(0, context.dp(48), 1f).apply { marginStart = context.dp(8) })
    }
    private val card = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(context.dp(16), context.dp(12), context.dp(16), context.dp(12))
        background = roundRect(context.getColor(R.color.token_bg_secondary), context.dp(12).toFloat())
        addView(title, LinearLayout.LayoutParams(-1, -2))
        addView(status, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(6) })
        addView(buttons, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(12) })
    }
    private var item: PreparedChatMessage? = null
    private var offer: DeviceSetupOffer? = null
    private var busy = false
    private val expire = Runnable { render() }
    /** Tests supply the phone identity and action handler without starting application services. */
    var localReporter: () -> String = { NearbyDevices.get(context).reporterId }
    var onAction: (DeviceSetupOffer, String) -> Unit = ::act

    init {
        addView(card)
        connect.contentDescription = "Connect"
        dismiss.contentDescription = "Not now"
        connect.setOnClickListener { offer?.let { onAction(it, "started") } }
        dismiss.setOnClickListener { offer?.let { onAction(it, "dismiss") } }
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        show(DeviceSetupOffer.parse(item.message.cardPayload))
        requestLayout()
    }

    /** Home may still hold an older revision than an action response this card already shows. */
    fun show(value: DeviceSetupOffer?) {
        val current = offer
        if (current?.offerId != value?.offerId) busy = false
        else if (current != null && value != null && !current.replacedBy(value)) return render()
        offer = value
        render()
    }

    private fun render() {
        removeCallbacks(expire)
        val offer = offer
        card.isVisible = offer != null
        if (offer == null) return
        val now = System.currentTimeMillis()
        val display = offer.presentation(localReporter(), now)
        title.text = offer.name
        status.text = display.label
        connect.isVisible = display.connect
        dismiss.isVisible = display.dismiss
        connect.isEnabled = !busy
        dismiss.isEnabled = !busy
        buttons.isVisible = display.connect || display.dismiss
        if (isAttachedToWindow && offer.status in setOf("open", "started") && offer.expiresAt > now) {
            postDelayed(expire, offer.expiresAt - now)
        }
    }

    private fun act(selected: DeviceSetupOffer, action: String) {
        if (busy) return
        val activity = generateSequence(context) { (it as? ContextWrapper)?.baseContext }
            .filterIsInstance<ComponentActivity>().firstOrNull() ?: return
        val nearby = NearbyDevices.get(context)
        val owner = nearby.currentOwner() ?: return
        if (action == "started" && !selected.presentation(nearby.reporterId, System.currentTimeMillis()).connect) return
        busy = true
        render()
        activity.lifecycleScope.launch {
            try {
                val result = nearby.action(owner, selected, action)
                if (!nearby.isCurrent(owner)) return@launch
                // A Home event may have rebound the row while the request was in flight: show()
                // keeps the higher revision; without revisions only an unchanged row takes it.
                val shown = offer
                if (shown == selected || (shown?.offerId == selected.offerId && shown.revision != null)) show(result)
                val current = offer?.takeIf { it.offerId == selected.offerId } ?: result
                if (action == "started" && result.status == "started" &&
                    activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
                    current.presentation(nearby.reporterId, System.currentTimeMillis()).connect) {
                    SettingsActivity.startAddDevice(activity, result)
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                Toast.makeText(context, "Could not update the device setup. Try again.", Toast.LENGTH_LONG).show()
            } finally {
                if (offer?.offerId == selected.offerId) { busy = false; render() }
            }
        }
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); render() }
    override fun onDetachedFromWindow() { removeCallbacks(expire); super.onDetachedFromWindow() }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val current = item
        val height = current?.cellHeightPx ?: MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(width, height)
        card.measure(MeasureSpec.makeMeasureSpec((width - (current?.sideMarginPx ?: 0) * 2).coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - (current?.topMarginPx ?: 0)).coerceAtLeast(0), MeasureSpec.AT_MOST))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val left = item?.sideMarginPx ?: 0
        val top = item?.topMarginPx ?: 0
        card.layout(left, top, left + card.measuredWidth, top + card.measuredHeight)
    }
}
