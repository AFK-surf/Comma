package surf.comma.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.getSystemService
import surf.comma.android.R
import surf.comma.android.chat.render.MessageContent
import surf.comma.android.chat.render.SelectableText
import surf.comma.android.chat.render.CopyTarget
import surf.comma.android.chat.render.MessageCopy
import surf.comma.android.chat.render.PreparedChatMessage
import surf.comma.android.chat.render.ChatMessageCell
import surf.comma.android.ui.theme.UiSansTypeface

/** Copy actions and text selection on the existing message bubble. */
object MessageActionsPopup {
    private const val CARD_PADDING_DP = 6
    private const val CARD_ELEVATION_DP = 12

    /**
     * [fullBlocks] keeps Select all copying the whole message when a reference card splits its rows.
     */
    fun show(anchor: View, item: PreparedChatMessage, fullBlocks: List<MessageContent> = item.contents) {
        val context = anchor.context
        val entries = entriesFor(item, fullBlocks)
        if (entries.isEmpty()) return

        val density = context.resources.displayMetrics.density
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, (CARD_PADDING_DP * density).toInt(), 0, (CARD_PADDING_DP * density).toInt())
        }
        val popup = PopupWindow(
            card,
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
            true,
        ).apply {
            // The same floating card as the composer's attach menu: on the white page it needs
            // its hairline and shadow to read as a card. The window draws both, so the shadow
            // is not clipped to the content.
            setBackgroundDrawable(GradientDrawable().apply {
                val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                    Configuration.UI_MODE_NIGHT_YES
                setColor(context.getColor(if (night) R.color.token_bg_tertiary else R.color.token_bg_primary))
                cornerRadius = context.resources.getDimension(R.dimen.radius_5xl)
                setStroke(1, context.getColor(R.color.token_border_primary)) // DESIGN §4: one physical pixel
            })
            elevation = CARD_ELEVATION_DP * density
        }
        entries.forEach { entry ->
            card.addView(
                TextView(context).apply {
                    text = context.getString(entry.labelRes)
                    typeface = UiSansTypeface
                    textSize = 15f
                    gravity = Gravity.CENTER_VERTICAL
                    setTextColor(context.getColor(R.color.token_text_primary))
                    setPadding(
                        (22 * density).toInt(),
                        (14 * density).toInt(),
                        (22 * density).toInt(),
                        (14 * density).toInt(),
                    )
                    isClickable = true
                    setOnClickListener {
                        popup.dismiss()
                        if (entry.selects) anchor.post {
                            if (anchor.isAttachedToWindow) (anchor as? ChatMessageCell)?.selectText(entry.blocks)
                        } else copy(context, entry.label(context), entry.text)
                    }
                },
            )
        }
        popup.showAsDropDown(anchor, (20 * density).toInt(), -(anchor.height / 2))
    }

    /** [selects] starts selection in the current bubble instead of copying immediately. */
    internal data class Entry(
        val labelRes: Int,
        val text: String,
        val selects: Boolean = false,
        /** The whole logical message for Select all. */
        val blocks: List<MessageContent> = emptyList(),
    ) {
        fun label(context: Context): String = context.getString(labelRes)
    }

    internal fun entriesFor(item: PreparedChatMessage, fullBlocks: List<MessageContent>): List<Entry> {
        val copies = MessageCopy.targets(item.message.text, item.contents).map { (target, text) ->
            when (target) {
                CopyTarget.CODE -> Entry(R.string.action_copy_code, text)
                CopyTarget.FULL -> Entry(R.string.action_copy_message, text)
            }
        }
        val blocks = fullBlocks.ifEmpty { item.contents }
        val select = SelectableText.build(blocks).toString().trim()
        return if (copies.isEmpty() || select.isEmpty()) copies
            else copies + Entry(R.string.action_select_text, select, selects = true, blocks = blocks)
    }

    /** A whole reply, from the button under it. Same clipboard label as the menu's entry. */
    fun copyMessage(context: Context, text: String) {
        if (text.isBlank()) return
        copy(context, context.getString(R.string.action_copy_message), text)
    }

    /** 代码块 header 上那颗「复制」。落点跟菜单里的「复制代码」是同一个，提示也一样。 */
    fun copyCode(context: Context, code: String) {
        if (code.isBlank()) return
        copy(context, context.getString(R.string.action_copy_code), code)
    }

    private fun copy(context: Context, label: String, text: String) {
        val clipboard = context.getSystemService<ClipboardManager>() ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
        // Android 13+ 系统自己会弹复制提示，再来一个 Toast 是重复的。
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(context, R.string.copied, Toast.LENGTH_SHORT).show()
        }
    }
}
