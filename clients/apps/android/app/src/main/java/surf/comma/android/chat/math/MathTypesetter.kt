package surf.comma.android.chat.math

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Typeface
import android.os.Looper
import android.text.TextPaint
import android.text.style.ReplacementSpan
import android.util.LruCache
import androidx.core.graphics.withTranslation
import surf.comma.android.ui.theme.UiSansTypeface
import kotlin.math.ceil

/**
 * Turns formula source into something a message can draw: a [MathBox] at a text size.
 *
 * Layouts are in ems and cached by source and style, so a streaming reply that lays out its last
 * paragraph again on every packet asks the engine for each formula once, and a change of text
 * size or theme reuses them. Failures are cached too: a formula that cannot be drawn is not
 * retried on every packet. The cache is bounded by how much drawing it holds ([MathLayout.weight]).
 *
 * Laying out blocks on the engine, so it is refused on the main thread: there a formula that is
 * not cached yet stays as its source.
 */
class MathTypesetter(
    private val engine: MathEngine,
    private val typefaces: (Int) -> Typeface?,
    maxWeight: Int = DEFAULT_MAX_WEIGHT,
) {
    private data class Key(val latex: String, val display: Boolean)

    private val layouts = object : LruCache<Key, Any>(maxWeight) {
        override fun sizeOf(key: Key, value: Any): Int = (value as? MathLayout)?.weight ?: 1
    }

    /** The layout of [latex], or null if it cannot be drawn (or not now). */
    fun layout(latex: String, display: Boolean): MathLayout? {
        val source = latex.trim()
        if (source.isEmpty() || source.length > MathLimits.MAX_SOURCE_CHARS) return null
        val key = Key(source, display)
        layouts.get(key)?.let { return it as? MathLayout }
        if (Looper.getMainLooper()?.isCurrentThread == true) return null
        return when (val result = engine.layout(source, display)) {
            is MathResult.Laid -> result.layout.takeIf { MathLimits.accepts(it) }.also { layouts.put(key, it ?: FAILED) }
            is MathResult.Failed -> null.also { layouts.put(key, FAILED) }
            MathResult.Unavailable -> null
        }
    }

    /** [latex] drawn at [textSizePx], or null if it cannot be. */
    fun box(latex: String, display: Boolean, textSizePx: Float): MathBox? {
        val laid = layout(latex, display) ?: return null
        // A layout that got past the checks but still cannot be built is shown as its source.
        return try {
            MathBox(laid, textSizePx, typefaces)
        } catch (_: RuntimeException) {
            null
        }
    }

    companion object {
        /** Around a few hundred ordinary formulas' worth of glyphs. */
        const val DEFAULT_MAX_WEIGHT = 40_000
        private val FAILED = Any()

        /** Set up once in the app's process; null in tests and in the math process. */
        @Volatile
        var installed: MathTypesetter? = null
            private set

        fun install(context: Context) {
            if (installed != null) return
            val fonts = MathFonts(context.applicationContext)
            installed = MathTypesetter(MathEngineClient(context), fonts::typeface)
        }
    }
}

/** The bundled math faces, opened on first use. */
private class MathFonts(private val context: Context) {
    private val faces: Array<Typeface?> by lazy {
        Array(MathFontIds.ALL.size) { index ->
            runCatching { Typeface.createFromAsset(context.assets, MathFontIds.assetPath(index)) }.getOrNull()
        }
    }

    fun typeface(index: Int): Typeface? = faces.getOrNull(index)
}

/**
 * One formula at one text size, ready to draw: glyph strings, outlines and rules are built once,
 * so drawing it (or recording it into a text block's display list) does no layout and no
 * allocation. It draws in the colour it is given, except where the formula sets its own.
 *
 * Math is always drawn left to right, whatever the direction of the text around it.
 */
class MathBox internal constructor(
    private val layout: MathLayout,
    val textSizePx: Float,
    typefaces: (Int) -> Typeface?,
) {
    val widthPx: Float = layout.width * textSizePx
    /** Above the baseline. */
    val ascentPx: Float = layout.height * textSizePx
    /** Below the baseline. */
    val descentPx: Float = layout.depth * textSizePx

    private val glyphText = Array(layout.glyphCount) { String(Character.toChars(layout.glyphCodePoints[it])) }
    // Faces the app does not ship (Chinese inside \text{}, emoji) fall back to the body face.
    private val glyphFaces = Array(layout.glyphCount) { typefaces(layout.glyphFonts[it]) ?: UiSansTypeface }
    private val outlines = layout.paths.map { path ->
        Path().apply {
            val p = path.points
            var at = 0
            fun x() = (path.x + p[at++]) * textSizePx
            fun y() = (path.y + p[at++]) * textSizePx
            for (verb in path.verbs) when (verb) {
                MathLayout.MOVE -> moveTo(x(), y())
                MathLayout.LINE -> lineTo(x(), y())
                MathLayout.QUAD -> quadTo(x(), y(), x(), y())
                MathLayout.CUBIC -> cubicTo(x(), y(), x(), y(), x(), y())
                MathLayout.CLOSE -> close()
            }
        }
    }
    private val glyphPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)

    /**
     * Draws with the box's top-left corner at ([left], [top]), in the engine's order, so a
     * background (`\colorbox`) stays under what is drawn on it. Main thread only.
     */
    fun draw(canvas: Canvas, left: Float, top: Float, color: Int) {
        val size = textSizePx
        val g = layout.glyphGeometry
        val r = layout.rules
        var glyph = 0
        var rule = 0
        var path = 0
        for (kind in layout.order) when (kind) {
            MathLayout.GLYPH -> {
                val index = glyph++
                glyphPaint.typeface = glyphFaces[index]
                glyphPaint.textSize = size * g[index * 3 + 2]
                glyphPaint.color = tint(layout.glyphColors[index], color)
                canvas.drawText(glyphText[index], left + g[index * 3] * size, top + g[index * 3 + 1] * size, glyphPaint)
            }
            MathLayout.RULE -> {
                val index = rule++
                fill.style = Paint.Style.FILL
                fill.color = tint(layout.ruleColors[index], color)
                val x = left + r[index * 4] * size
                val y = top + r[index * 4 + 1] * size
                // A rule thinner than a pixel still shows, as a pixel: fraction bars must not vanish.
                val h = maxOf(r[index * 4 + 3] * size, 1f)
                canvas.drawRect(x, y, x + r[index * 4 + 2] * size, y + h, fill)
            }
            MathLayout.PATH -> {
                val index = path++
                val outline = layout.paths[index]
                fill.color = tint(outline.color, color)
                fill.style = if (outline.fill) Paint.Style.FILL else Paint.Style.STROKE
                canvas.withTranslation(left, top) { drawPath(outlines[index], fill) }
            }
        }
    }

    /** The formula's own colour, or [text] where it has none; either way at the text's opacity. */
    private fun tint(own: Int, text: Int): Int {
        if (own == MathLayout.DEFAULT_COLOR) return text
        val alpha = ((own ushr 24) * (text ushr 24)) / 255
        return (alpha shl 24) or (own and 0x00FFFFFF)
    }
}

/**
 * An inline formula inside a line of text. The span covers the formula's source, so the text
 * still reads as what was written (copy, accessibility, the select-text page); the layout draws
 * the formula in its place, on the line's baseline, and makes the line tall enough for it.
 */
class MathSpan(val box: MathBox, private val padPx: Int) : ReplacementSpan() {
    val widthPx: Int = ceil(box.widthPx).toInt() + padPx * 2

    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        if (fm != null) {
            paint.getFontMetricsInt(fm)
            // Grow the line for tall formulas; never shrink it below the text's own metrics.
            val above = -(ceil(box.ascentPx).toInt() + padPx)
            val below = ceil(box.descentPx).toInt() + padPx
            fm.ascent = minOf(fm.ascent, above)
            fm.top = minOf(fm.top, above)
            fm.descent = maxOf(fm.descent, below)
            fm.bottom = maxOf(fm.bottom, below)
        }
        return widthPx
    }

    override fun draw(
        canvas: Canvas,
        text: CharSequence?,
        start: Int,
        end: Int,
        x: Float,
        top: Int,
        y: Int,
        bottom: Int,
        paint: Paint,
    ) {
        box.draw(canvas, x + padPx, y - box.ascentPx, paint.color)
    }
}
