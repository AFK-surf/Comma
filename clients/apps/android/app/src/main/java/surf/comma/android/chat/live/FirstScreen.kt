package surf.comma.android.chat.live

import surf.comma.android.chat.model.ChatMessage
import surf.comma.android.chat.render.PreparedChatMessage

/**
 * Lays out only the newest rows first: enough, from the end, to fill [targetHeightPx]. Starts
 * with [initialCount] rows and doubles, so a long history costs a screen of layout before the
 * chat appears instead of all of it. [prepare] reuses rows it has already laid out.
 */
internal suspend fun prepareFirstScreen(
    rows: List<ChatMessage>,
    targetHeightPx: Int,
    initialCount: Int = FIRST_SCREEN_ROWS,
    prepare: suspend (List<ChatMessage>) -> List<PreparedChatMessage>,
): List<PreparedChatMessage> {
    var count = initialCount.coerceAtLeast(1)
    while (true) {
        val prepared = prepare(rows.takeLast(count))
        if (count >= rows.size || prepared.sumOf { it.cellHeightPx } >= targetHeightPx) return prepared
        count = (count * 2).coerceAtMost(rows.size)
    }
}

/** Below this many rows the whole list is laid out at once. */
internal const val FIRST_SCREEN_MIN_ROWS = 24
internal const val FIRST_SCREEN_ROWS = 8
