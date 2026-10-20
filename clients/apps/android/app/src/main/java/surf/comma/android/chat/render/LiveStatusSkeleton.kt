package surf.comma.android.chat.render

/**
 * 思考态的内容骨架（Gemini 拆解参数，见 docs/plan/ws3-streaming-ux.md 参照基准）：
 * 每组 3 条骨架条，条高 15dp、间距 13dp、圆角 4dp、末条 60% 宽；shimmer 用
 * LinearGradient 2000ms 线性无限循环。骨架总高 ≈ 首段正文（三行 25sp 行高）的高度，
 * 首个 delta 原位替换为正文时不产生排版跳变。
 */
internal object LiveStatusSkeleton {
    const val BAR_COUNT = 3
    const val BAR_HEIGHT_DP = 15f
    const val BAR_GAP_DP = 13f
    const val CORNER_RADIUS_DP = 4f
    const val LAST_BAR_WIDTH_FRACTION = 0.6f
    const val SHIMMER_PERIOD_MS = 2000L

    /** 骨架组总高（dp），供布局预计算给行定高。 */
    const val TOTAL_HEIGHT_DP = BAR_COUNT * BAR_HEIGHT_DP + (BAR_COUNT - 1) * BAR_GAP_DP

    /** 线性循环相位 0..1（LinearInterpolator 语义：不缓动）。 */
    fun phase(timeMs: Long): Float =
        (timeMs % SHIMMER_PERIOD_MS).toFloat() / SHIMMER_PERIOD_MS
}
