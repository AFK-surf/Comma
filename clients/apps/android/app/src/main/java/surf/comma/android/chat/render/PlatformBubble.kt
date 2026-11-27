package surf.comma.android.chat.render

import surf.comma.android.R

/**
 * A person's message that came in from a chat platform takes that platform's bubble colour, the same values the
 * desktop and iPhone draw (`clients/packages/app/src/components/chat/MessagePlatformBadge.tsx`). A message typed in
 * a Comma app keeps the brand bubble.
 */
internal object PlatformBubble {
    /** [text] is null where the default white reads on the fill. */
    data class Colors(val fill: Int, val text: Int?)

    fun colors(platform: String?, darkTheme: Boolean): Colors? = when (platform) {
        "wechat" -> Colors(0xFF9DF29F.toInt(), 0xFF082D07.toInt())
        "telegram" -> Colors(0xFFB8EAF7.toInt(), 0xFF082B3A.toInt())
        "signal" -> Colors(0xFF3B6DE3.toInt(), null)
        "slack" -> Colors(0xFF611F69.toInt(), null)
        "feishu", "lark" -> Colors(0xFF2C61E8.toInt(), null)
        // Messages green differs by theme.
        "imessage" -> Colors(if (darkTheme) 0xFF30D65B.toInt() else 0xFF4BDE70.toInt(), null)
        "discord" -> Colors(0xFF5865F2.toInt(), null)
        else -> null
    }

    /** The platform's logo, which the drag to the left shows beside its messages; null where none ships. */
    fun logo(platform: String?): Int? = when (platform) {
        "wechat" -> R.drawable.provider_wechat
        "telegram" -> R.drawable.provider_telegram
        "signal" -> R.drawable.provider_signal
        "slack" -> R.drawable.provider_slack
        "feishu" -> R.drawable.provider_feishu
        "lark" -> R.drawable.provider_lark
        "imessage" -> R.drawable.provider_imessage
        else -> null
    }
}
