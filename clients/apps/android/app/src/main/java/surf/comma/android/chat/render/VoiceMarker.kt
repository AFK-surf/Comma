package surf.comma.android.chat.render

import surf.comma.android.chat.model.MessageSource

/**
 * 时间线上的语音来源标记。
 *
 * 它是来源属性，不是一块内容：不进 [MessageContent]，不进
 * [PreparedContentBlock]，不改气泡宽高和 cell 高度。[ChatMessageCell]
 * 在已经量好的格子里，把一颗点阵麦克风画进正文栏左侧的空白——
 * 用户气泡的左边、助手通栏的边距里。
 *
 * 流式输出时 [surf.comma.android.chat.model.ChatMessage.source] 不会变，
 * 预排仍然只重排正在长的那一块。[sharedContentPrefix] 的输入是解析
 * 结果，跟标记无关。
 */
internal object VoiceMarker {
    const val COLS = 5
    const val DOT_DP = 1.2f
    const val PITCH_DP = 1.65f
    const val GAP_DP = 6f

    /**
     * 5 列点阵，高位是左边。胶囊头 + 短支架，和 NDot 标签同一套点阵语汇，
     * 比写一个 "VOICE" 窄，助手通栏那 28dp 边距里放得下。
     */
    val DOTS: IntArray = intArrayOf(
        0b01110,
        0b10001,
        0b10001,
        0b10001,
        0b01110,
        0b00100,
        0b01010,
        0b00100,
    )

    val widthDp: Float = (COLS - 1) * PITCH_DP + DOT_DP
    val heightDp: Float = (DOTS.size - 1) * PITCH_DP + DOT_DP

    data class Spec(
        val left: Float,
        val top: Float,
        val width: Float,
        val height: Float,
        val dotRadius: Float,
        val pitch: Float,
    )

    fun spec(
        source: MessageSource?,
        columnLeft: Float,
        contentTop: Float,
        density: Float,
    ): Spec? {
        if (source != MessageSource.VOICE) return null
        val width = widthDp * density
        val height = heightDp * density
        val gap = GAP_DP * density
        return Spec(
            left = (columnLeft - gap - width).coerceAtLeast(0f),
            top = contentTop,
            width = width,
            height = height,
            dotRadius = DOT_DP * density / 2f,
            pitch = PITCH_DP * density,
        )
    }
}
