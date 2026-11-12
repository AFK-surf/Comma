package surf.comma.android.chat.live

import android.content.Context
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import org.json.JSONArray
import org.json.JSONObject
import surf.comma.android.R
import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.ChatCardRenderer
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.conversation.ChatRole
import surf.comma.android.conversation.ConversationState
import surf.comma.android.conversation.TimelineEntry
import surf.comma.android.scroll.widget.ScrollContainer
import surf.comma.android.settings.color
import surf.comma.android.settings.dp
import surf.comma.android.settings.roundRect
import surf.comma.android.settings.text
import surf.comma.android.ui.kit.tactile
import surf.comma.android.ui.theme.DesignFonts
import surf.comma.android.ui.theme.DesignTypography.Level
import java.util.Locale

/** One follow-up the core suggests for a settled turn (`chatSuggestions`): [label] on the chip, [prompt] sent. */
data class ChatSuggestion(val id: String, val label: String, val prompt: String) {
    companion object {
        /** At most this many chips show, as on iOS. */
        const val MAX_SHOWN = 4

        /** The topic's value: the valid suggestions, at most [MAX_SHOWN]; anything else reads as none. */
        fun list(value: Any?): List<ChatSuggestion> {
            val array = value as? JSONArray ?: return emptyList()
            return (0 until array.length()).mapNotNull { index -> parse(array.optJSONObject(index)) }.take(MAX_SHOWN)
        }

        private fun parse(json: JSONObject?): ChatSuggestion? {
            json ?: return null
            fun field(name: String) = json.optString(name).takeIf { json.has(name) && !json.isNull(name) && it.isNotEmpty() }
            val id = field("id") ?: return null
            val label = field("label") ?: return null
            val prompt = field("prompt") ?: return null
            // The same bound as iOS: a prompt is a short reply, never a long instruction.
            if (prompt.length > MAX_PROMPT) return null
            return ChatSuggestion(id, label, prompt)
        }

        private const val MAX_PROMPT = 12

        /** The language the core writes suggestions in: Simplified Chinese for Chinese, English otherwise. */
        fun language(locale: Locale): String = if (locale.language == "zh") "zh-CN" else "en"

        /**
         * The agent message whose follow-ups the chat may show, or null while a turn is in flight (a send, an
         * activity, a streaming reply), after a message of the member's that no reply followed, before the conversation
         * loaded, or in an archived conversation. Suggestions describe a finished turn only.
         */
        fun settledMessage(state: ConversationState): String? {
            if (state.conversationId == null || state.draft == null || state.status == "archived") return null
            val busy = state.reply.pending || state.activity != null || state.participant?.state == "active" ||
                state.timeline.any { it is TimelineEntry.Pending || it is TimelineEntry.Draft }
            if (busy) return null
            val last = (state.timeline.lastOrNull { it is TimelineEntry.Message } as? TimelineEntry.Message)?.message ?: return null
            return last.messageId.takeIf { last.role == ChatRole.ASSISTANT && last.actorType == "agent" }
        }

        fun encode(suggestions: List<ChatSuggestion>): String = JSONArray(suggestions.map {
            JSONObject().put("id", it.id).put("label", it.label).put("prompt", it.prompt)
        }).toString()

        fun decode(payload: String?): List<ChatSuggestion> = runCatching { list(JSONArray(payload.orEmpty())) }.getOrDefault(emptyList())
    }
}

/** The row kind of the suggestion chips after the settled turn. */
internal const val SUGGESTIONS_KIND = "chat.suggestions"

/** The chips under the last turn. The row is one chip tall; more chips than fit scroll sideways. */
internal class ChatSuggestionsRenderer(override val viewType: Int) : ChatCardRenderer {
    override val kind = SUGGESTIONS_KIND
    override fun bodyHeightDp(message: ChatMessage, cardWidthDp: Float) = CHIP_HEIGHT_DP
    override fun create(context: Context): View = ChatSuggestionsRow(context)
    override fun bind(view: View, item: PreparedChatMessage) = (view as ChatSuggestionsRow).bind(item)

    companion object {
        const val CHIP_HEIGHT_DP = 44f
    }
}

internal class ChatSuggestionsRow(context: Context) : FrameLayout(context) {
    /** What a chip does; the timeline's page sets it. Null leaves the chips inert. */
    var hostOf: () -> ((ChatSuggestion) -> Unit)? = { null }
    private val strip = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val scroll = ScrollContainer(context).apply {
        orientation = ScrollContainer.HORIZONTAL
        addView(strip)
    }
    private var item: PreparedChatMessage? = null

    init {
        addView(scroll)
        contentDescription = context.getString(R.string.chat_suggestions)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    fun bind(next: PreparedChatMessage) {
        item = next
        strip.removeAllViews()
        strip.setPadding(next.sideMarginPx, 0, next.sideMarginPx, 0)
        val height = context.dp(ChatSuggestionsRenderer.CHIP_HEIGHT_DP)
        ChatSuggestion.decode(next.message.cardPayload).forEachIndexed { index, suggestion ->
            strip.addView(context.text(Level.SMALL, R.color.token_text_secondary, DesignFonts.medium).apply {
                text = suggestion.label
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                gravity = Gravity.CENTER
                setPadding(context.dp(16), 0, context.dp(16), 0)
                background = roundRect(context.color(R.color.token_bg_secondary), height / 2f)
                isClickable = true
                tactile()
                setOnClickListener { hostOf()?.invoke(suggestion) }
            }, LinearLayout.LayoutParams(-2, height).apply { if (index > 0) marginStart = context.dp(8) })
        }
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val current = item
        val height = current?.cellHeightPx ?: 0
        setMeasuredDimension(width, height)
        scroll.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec((height - (current?.topMarginPx ?: 0)).coerceAtLeast(0), MeasureSpec.EXACTLY))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val top = item?.topMarginPx ?: 0
        scroll.layout(0, top, scroll.measuredWidth, top + scroll.measuredHeight)
    }
}
