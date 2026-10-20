package surf.comma.android.chat.streaming

import kotlin.math.max
import kotlin.random.Random

/**
 * 把一段已经拿到的完整文本，按真实传输的节奏吐出来。
 *
 * 流式不是匀速的：token 成簇到达，包大小和间隔都在抖，模型偶尔卡一下，
 * 句号后的停顿明显长于逗号。恒速喂字会让光标塌成一条均匀的扫描线，
 * 一眼就能看出打字机是假的。
 *
 * 每条流一个实例。原来是 object + 可变状态，两条流并发时 burst 计数会互相踩，
 * 而且没法测——现在换成类，构造函数收 [random]，测试可以钉死种子。
 */
class StreamRhythm(private val random: Random = Random) {

    private var packetsLeftInBurst = nextBurstSize()

    private fun nextBurstSize(): Int = random.nextInt(3, 7)

    /** 每包 4–9 个字符，15% 的概率合并成 10–18 个的大包。 */
    fun chunkSize(): Int =
        if (random.nextFloat() < 0.15f) random.nextInt(10, 19) else random.nextInt(4, 10)

    /**
     * 簇内 12–26ms，簇间 80–169ms，再叠标点停顿。重要的是节奏的形状而不是绝对时长：
     * 要调快就整体等比缩短，别单独改某一段。
     *
     * 扫的是整个包而不只是末字符：包边界爱落哪落哪，句号通常在包中间，
     * 只看包尾会漏掉几乎所有的句停顿。
     */
    fun delayAfter(text: CharSequence, start: Int, end: Int): Long {
        val safeStart = start.coerceIn(0, text.length)
        val safeEnd = end.coerceIn(safeStart, text.length)
        var punctuationKind = 0 // 0 = 无, 1 = 句中, 2 = 句末, 3 = 段落
        for (index in safeStart until safeEnd) {
            punctuationKind = max(
                punctuationKind,
                when (text[index]) {
                    '\n' -> 3
                    '.', '!', '?', '。', '！', '？' -> 2
                    ',', ';', ':', '，', '；', '：', '、' -> 1
                    else -> 0
                },
            )
        }

        val base = random.nextLong(12, 27)
        val punctuation = when (punctuationKind) {
            3 -> random.nextLong(190, 311)
            2 -> random.nextLong(110, 191)
            1 -> random.nextLong(45, 91)
            else -> 0L
        }
        packetsLeftInBurst--
        val burstRest = if (packetsLeftInBurst <= 0) {
            packetsLeftInBurst = nextBurstSize()
            // 标点已经断了这一簇，不要再叠一个间隔上去。
            if (punctuation == 0L) random.nextLong(80, 170) else 0L
        } else {
            0L
        }
        val inferenceStall = if (random.nextFloat() < 0.01f) random.nextLong(260, 461) else 0L
        return base + burstRest + inferenceStall + punctuation
    }
}
