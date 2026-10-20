package surf.comma.android.ui.theme

import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.FontStyle
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Nothing OS ships its own type on the device. We load it straight from the system font
 * directory instead of bundling it, and fall back to the platform sans on other hardware.
 */
private const val SystemFontDirectory = "/system/fonts"

private fun fontFile(vararg fileNames: String): File? = fileNames
    .asSequence()
    .map { File(SystemFontDirectory, it) }
    .firstOrNull { it.canRead() }

private fun systemTypeface(vararg fileNames: String): Typeface? = fileNames
    .asSequence()
    .map { File(SystemFontDirectory, it) }
    .filter { it.canRead() }
    .mapNotNull { runCatching { Typeface.createFromFile(it) }.getOrNull() }
    .firstOrNull()

/** Ndot — the dot-matrix face used for labels, counters and the app title. */
val NDotTypeface: Typeface by lazy {
    systemTypeface("Ndot-55.otf", "NDot55Caps.otf", "Ndot-57-Aligned.otf", "Ndot-57.otf")
        ?: Typeface.DEFAULT
}

/**
 * Neutral sans for titles, body copy and input. Nothing maps `sans-serif` to its own NType82,
 * which is a serif on this ROM, so the plain grotesque is requested by file instead.
 */
val UiSansTypeface: Typeface by lazy {
    fontFile("Roboto-Regular.ttf", "Roboto-Regular.ttc", "NType82-Regular.otf")
        ?.let { runCatching { withCjkFallback(systemFont(it, 400), 400) }.getOrNull() }
        ?: Typeface.create("sans-serif", Typeface.NORMAL)
}

private fun systemFont(file: File, weight: Int): Font =
    Font.Builder(file).setFontVariationSettings("'wght' $weight").setWeight(weight).build()

/** The system face keeps its own weight; only the Chinese fallback is asked for [cjkFallbackWeight]. */
private fun withCjkFallback(font: Font, weight: Int): Typeface =
    Typeface.CustomFallbackBuilder(FontFamily.Builder(font).build())
        .setStyle(FontStyle(cjkFallbackWeight(weight), FontStyle.FONT_SLANT_UPRIGHT))
        .setSystemFallback("sans-serif")
        .build()

/**
 * 同一张脸的加粗版，**真加粗，不是描粗的**。
 *
 * `Typeface.create(UiSansTypeface, Typeface.BOLD)` 拿不到真字重：这台 ROM 的
 * `/system/fonts` 里只有一个 `Roboto-Regular.ttf`——它是可变字体，粗细在 `wght` 轴上，
 * 而 `createFromFile` 载进来的实例没带轴设置。系统只好合成加粗（把轮廓往外描一圈）。
 * 拉丁字母还看得过去，中文糊得很明显：笔画多，描粗之后横竖挤在一起发黑。
 *
 * 这里直接把 `wght` 轴设到位。顺带一提，`fonts.xml` 里 `zh-Hans` 的
 * `NotoSansCJK-Regular.ttc` 同样是可变字体、100–900 都有真实例，所以中文回退也能
 * 按这个字重取到真字面，而不是再被描一遍。
 */
fun uiSansAt(weight: Int): Typeface = weightedCache.getOrPut(weight) {
    val file = fontFile("Roboto-Regular.ttf", "Roboto-Regular.ttc", "NType82-Regular.otf")
    val built = file?.let {
        runCatching {
            withCjkFallback(systemFont(it, weight), weight)
        }.getOrNull()
    }
    built ?: Typeface.create(UiSansTypeface, weight, false)
}

/**
 * 并发 map，不是裸 `HashMap`：`uiSansAt` 在 `MessageLayoutPrecomputer` 的
 * `withContext(Dispatchers.Default)` 里被调用，那是个多线程池，同时排版两条消息就会并发进来。
 * `getOrPut` 不是原子的，但重复构造无害——同一个 weight 造出来的 `Typeface` 是等价的幂等值，
 * 谁赢都一样；要紧的是别再出现并发 put 丢条目或读到半构造状态。
 */
private val weightedCache = ConcurrentHashMap<Int, Typeface>()

/** 正文加粗用 600，不是 700——中文在 700 上偏重，600 跟 16sp 的正文更配。 */
const val UiSansSemiBold = 600
