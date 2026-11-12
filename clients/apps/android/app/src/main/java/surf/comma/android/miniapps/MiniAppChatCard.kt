package surf.comma.android.miniapps

import android.content.Context
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.core.view.isVisible
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.auth.AuthGraph
import surf.comma.android.chat.live.LiveRowKinds
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.model.ChatRole
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import surf.comma.android.workspace.WorkspaceGraph

/**
 * A Mini App Version a build deployed, after the message that names it: icon, name, Version and summary. It is a
 * launch card, not a background WebView, and makes no request while the transcript renders beyond its icon. Only a
 * press opens the Version in the restricted container, in the current Workspace.
 */
internal class MiniAppCardRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = LiveRowKinds.MINI_APP

    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = CARD_HEIGHT_DP

    override fun create(context: Context): View = MiniAppChatRow(context)

    override fun bind(view: View, item: PreparedChatMessage) = (view as MiniAppChatRow).bind(item)

    private companion object {
        const val CARD_HEIGHT_DP = 96f
    }
}

internal class MiniAppChatRow(context: Context) : FrameLayout(context) {
    private val card = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = roundRect(context.color(R.color.token_bg_tertiary), context.dp(20).toFloat())
        setPadding(context.dp(14), context.dp(12), context.dp(14), context.dp(12))
        isClickable = true
        tactile()
    }
    private val icon = ImageView(context).apply {
        background = roundRect(context.color(R.color.token_bg_secondary), context.dp(10).toFloat())
        clipToOutline = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private val name = context.text(Level.REGULAR, R.color.token_text_primary, DesignFonts.semibold).apply {
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    private val version = context.text(Level.SMALL, R.color.token_text_tertiary)
    private val summary = context.text(Level.SMALL, R.color.token_text_secondary).apply {
        maxLines = 2
        ellipsize = TextUtils.TruncateAt.END
    }
    private var item: PreparedChatMessage? = null
    private var app: MiniAppCardValue? = null

    init {
        card.addView(icon, LinearLayout.LayoutParams(context.dp(44), context.dp(44)))
        val texts = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val line = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(name, LinearLayout.LayoutParams(0, -2, 1f))
                addView(version, LinearLayout.LayoutParams(-2, -2).apply { marginStart = context.dp(8) })
            }
            addView(line, LinearLayout.LayoutParams(-1, -2))
            addView(summary, LinearLayout.LayoutParams(-1, -2).apply { topMargin = context.dp(2) })
        }
        card.addView(texts, LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = context.dp(12) })
        card.addView(ImageView(context).apply {
            setImageResource(R.drawable.ic_settings_chevron)
            imageTintList = android.content.res.ColorStateList.valueOf(context.color(R.color.token_fg_quaternary))
        }, LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginStart = context.dp(4) })
        card.setOnClickListener { open() }
        addView(card)
    }

    fun bind(item: PreparedChatMessage) {
        this.item = item
        val app = runCatching { MiniAppCardValue.parse(JSONObject(item.message.cardPayload.orEmpty())) }.getOrNull()
        this.app = app
        name.text = app?.name?.ifEmpty { null } ?: context.getString(R.string.mini_apps_app)
        version.text = app?.let { "v${it.version}" }.orEmpty()
        summary.text = app?.summary
        summary.isVisible = !app?.summary.isNullOrEmpty()
        card.contentDescription = name.text
        card.stateDescription = app?.let { context.getString(R.string.mini_app_card_hint, it.version) }
        val workspace = WorkspaceGraph.get(context).workspace
        if (app != null && workspace != null) {
            MiniAppArtwork.show(icon, AuthGraph.core(context), "/v1/comma/apps/${app.appId}/icon?v=${app.version}",
                MiniAppVia.Workspace(workspace.id), placeholder = ::iconPlaceholder) { loaded ->
                if (loaded) {
                    icon.imageTintList = null
                    icon.scaleType = ImageView.ScaleType.CENTER_CROP
                    icon.setPadding(0, 0, 0, 0)
                }
            }
        } else iconPlaceholder()
        requestLayout()
    }

    private fun iconPlaceholder() {
        icon.scaleType = ImageView.ScaleType.CENTER_INSIDE
        icon.setImageResource(R.drawable.ic_tab_apps)
        icon.imageTintList = android.content.res.ColorStateList.valueOf(context.color(R.color.token_text_tertiary))
        icon.setPadding(context.dp(10), context.dp(10), context.dp(10), context.dp(10))
    }

    private fun open() {
        val app = app ?: return
        val workspace = WorkspaceGraph.get(context).workspace ?: return
        // A build Task's preview may offer Publish while its review still matches; the run screen checks that itself.
        MiniAppRuntimes.run(context, MiniAppTarget(workspace.id, app.appId, app.version, conversationId = app.conversationId))
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val current = item
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = current?.cellHeightPx ?: 0
        setMeasuredDimension(width, height)
        val side = current?.sideMarginPx ?: 0
        card.measure(MeasureSpec.makeMeasureSpec((width - side * 2).coerceAtLeast(0), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - (current?.topMarginPx ?: 0)).coerceAtLeast(0), MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val current = item ?: return
        val left = if (current.message.role == ChatRole.USER) width - current.sideMarginPx - card.measuredWidth else current.sideMarginPx
        card.layout(left, current.topMarginPx, left + card.measuredWidth, current.topMarginPx + card.measuredHeight)
    }
}
