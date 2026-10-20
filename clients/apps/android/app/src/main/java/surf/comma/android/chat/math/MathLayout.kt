package surf.comma.android.chat.math

import android.os.Parcel
import io.ratex.DisplayItem
import io.ratex.DisplayList
import io.ratex.PathCommand

/**
 * One formula, laid out, in ems: what to draw and where, before any text size is chosen. The
 * origin is the top-left corner of the box; the baseline is [height] below it.
 *
 * It crosses from the math process to the app in a [Parcel] ([writeTo] / [read]), as flat arrays,
 * so a formula with thousands of glyphs is a handful of array copies, not thousands of objects.
 * Colours are ARGB; [DEFAULT_COLOR] means "the colour of the text around it". [order] keeps the
 * engine's drawing order across the three kinds: a `\colorbox` background comes before its text.
 */
class MathLayout(
    val width: Float,
    val height: Float,
    val depth: Float,
    /** x, y (baseline), scale per glyph. */
    val glyphGeometry: FloatArray,
    /** Index into [MathFontIds.ALL], or -1 for a face the app does not ship. */
    val glyphFonts: IntArray,
    val glyphCodePoints: IntArray,
    val glyphColors: IntArray,
    /** left, top, width, height per filled rectangle: fraction bars, rules, `\boxed` edges. */
    val rules: FloatArray,
    val ruleColors: IntArray,
    val paths: List<Path>,
    /** [GLYPH], [RULE] or [PATH] per item, in drawing order; the n-th of a kind is its n-th entry. */
    val order: ByteArray,
) {
    /**
     * A drawn outline (a tall radical, a stretched brace) in ems. [verbs] are [MOVE] ... [CLOSE],
     * and [points] holds their coordinates in order: one pair for a move or line, two for a
     * quadratic, three for a cubic, none for a close.
     */
    class Path(
        val x: Float,
        val y: Float,
        val fill: Boolean,
        val color: Int,
        val verbs: ByteArray,
        val points: FloatArray,
    )

    val glyphCount: Int get() = glyphCodePoints.size

    /** How much drawing this layout holds, which is what a cache of layouts is bounded by. */
    val weight: Int get() = 1 + glyphCount + ruleColors.size + paths.sumOf { 1 + it.verbs.size }

    fun writeTo(out: Parcel) {
        out.writeFloat(width)
        out.writeFloat(height)
        out.writeFloat(depth)
        out.writeFloatArray(glyphGeometry)
        out.writeIntArray(glyphFonts)
        out.writeIntArray(glyphCodePoints)
        out.writeIntArray(glyphColors)
        out.writeFloatArray(rules)
        out.writeIntArray(ruleColors)
        out.writeByteArray(order)
        out.writeInt(paths.size)
        paths.forEach { path ->
            out.writeFloat(path.x)
            out.writeFloat(path.y)
            out.writeInt(if (path.fill) 1 else 0)
            out.writeInt(path.color)
            out.writeByteArray(path.verbs)
            out.writeFloatArray(path.points)
        }
    }

    companion object {
        const val MOVE: Byte = 0
        const val LINE: Byte = 1
        const val QUAD: Byte = 2
        const val CUBIC: Byte = 3
        const val CLOSE: Byte = 4

        const val GLYPH: Byte = 0
        const val RULE: Byte = 1
        const val PATH: Byte = 2

        /** The colour the math process asks for; it stands for the surrounding text's colour. */
        const val DEFAULT_COLOR: Int = 0xFF000000.toInt()

        /**
         * Reads a layout written by [writeTo]. Anything inconsistent (arrays of different
         * lengths, a size that is not finite) is refused rather than drawn.
         */
        fun read(source: Parcel): MathLayout? {
            val width = source.readFloat()
            val height = source.readFloat()
            val depth = source.readFloat()
            val geometry = source.createFloatArray() ?: return null
            val fonts = source.createIntArray() ?: return null
            val codePoints = source.createIntArray() ?: return null
            val colors = source.createIntArray() ?: return null
            val rules = source.createFloatArray() ?: return null
            val ruleColors = source.createIntArray() ?: return null
            val order = source.createByteArray() ?: return null
            val pathCount = source.readInt()
            val glyphs = codePoints.size
            if (geometry.size != glyphs * 3 || fonts.size != glyphs || colors.size != glyphs) return null
            if (rules.size != ruleColors.size * 4 || pathCount !in 0..MathLimits.MAX_DRAW_ITEMS) return null
            val paths = ArrayList<Path>(pathCount)
            repeat(pathCount) {
                val x = source.readFloat()
                val y = source.readFloat()
                val fill = source.readInt() == 1
                val color = source.readInt()
                val verbs = source.createByteArray() ?: return null
                val points = source.createFloatArray() ?: return null
                if (points.size != verbs.sumOf { pointCount(it) * 2 }) return null
                paths.add(Path(x, y, fill, color, verbs, points))
            }
            return MathLayout(width, height, depth, geometry, fonts, codePoints, colors, rules, ruleColors, paths, order)
                .takeIf { MathLimits.accepts(it) }
        }

        private fun pointCount(verb: Byte): Int = when (verb) {
            MOVE, LINE -> 1
            QUAD -> 2
            CUBIC -> 3
            else -> 0
        }

        /**
         * The library's display list as a [MathLayout]. Lines become rectangles (a dashed line
         * stays a rectangle: dashed rules only come from `\hdashline`, and a solid one reads the
         * same). Glyph outlines are not carried: glyphs are drawn from the bundled fonts.
         */
        fun from(list: DisplayList): MathLayout {
            val glyphs = list.items.filterIsInstance<DisplayItem.GlyphPath>()
            val geometry = FloatArray(glyphs.size * 3)
            val fonts = IntArray(glyphs.size)
            val codePoints = IntArray(glyphs.size)
            val colors = IntArray(glyphs.size)
            glyphs.forEachIndexed { index, glyph ->
                geometry[index * 3] = glyph.x.toFloat()
                geometry[index * 3 + 1] = glyph.y.toFloat()
                geometry[index * 3 + 2] = glyph.scale.toFloat()
                fonts[index] = MathFontIds.indexOf(glyph.font)
                codePoints[index] = glyph.charCode
                colors[index] = glyph.color.toArgb()
            }
            val rules = ArrayList<Float>()
            val ruleColors = ArrayList<Int>()
            val paths = ArrayList<Path>()
            val order = ByteArray(list.items.size)
            list.items.forEachIndexed { index, item ->
                order[index] = when (item) {
                    is DisplayItem.GlyphPath -> GLYPH
                    is DisplayItem.Rect, is DisplayItem.Line -> RULE
                    is DisplayItem.Path -> PATH
                }
            }
            for (item in list.items) {
                when (item) {
                    is DisplayItem.Rect -> {
                        rules += listOf(item.x.toFloat(), item.y.toFloat(), item.width.toFloat(), item.height.toFloat())
                        ruleColors += item.color.toArgb()
                    }
                    is DisplayItem.Line -> {
                        val thickness = item.thickness.toFloat()
                        rules += listOf(item.x.toFloat(), item.y.toFloat() - thickness / 2f, item.width.toFloat(), thickness)
                        ruleColors += item.color.toArgb()
                    }
                    is DisplayItem.Path -> {
                        val verbs = ByteArray(item.commands.size)
                        val points = ArrayList<Float>(item.commands.size * 2)
                        item.commands.forEachIndexed { index, command ->
                            verbs[index] = when (command) {
                                is PathCommand.MoveTo -> MOVE.also { points += listOf(command.x.toFloat(), command.y.toFloat()) }
                                is PathCommand.LineTo -> LINE.also { points += listOf(command.x.toFloat(), command.y.toFloat()) }
                                is PathCommand.QuadTo -> QUAD.also {
                                    points += listOf(command.x1.toFloat(), command.y1.toFloat(), command.x.toFloat(), command.y.toFloat())
                                }
                                is PathCommand.CubicTo -> CUBIC.also {
                                    points += listOf(
                                        command.x1.toFloat(), command.y1.toFloat(),
                                        command.x2.toFloat(), command.y2.toFloat(),
                                        command.x.toFloat(), command.y.toFloat(),
                                    )
                                }
                                PathCommand.Close -> CLOSE
                            }
                        }
                        paths += Path(item.x.toFloat(), item.y.toFloat(), item.fill, item.color.toArgb(), verbs, points.toFloatArray())
                    }
                    is DisplayItem.GlyphPath -> Unit
                }
            }
            return MathLayout(
                width = list.width.toFloat(),
                height = list.height.toFloat(),
                depth = list.depth.toFloat(),
                glyphGeometry = geometry,
                glyphFonts = fonts,
                glyphCodePoints = codePoints,
                glyphColors = colors,
                rules = rules.toFloatArray(),
                ruleColors = ruleColors.toIntArray(),
                paths = paths,
                order = order,
            )
        }
    }
}

/**
 * The bounds a formula has to stay within, on both sides of the process boundary. Past any of
 * them the formula is shown as its source text.
 */
object MathLimits {
    /** Longer than any formula a reply needs; it keeps one formula's work and output small. */
    const val MAX_SOURCE_CHARS = 2_000

    /** Glyphs, rules and outlines together. Also keeps a reply under the binder's 1 MB. */
    const val MAX_DRAW_ITEMS = 6_000

    /** A box this wide or tall is a mistake (`\kern{9999em}`), not a formula. */
    const val MAX_WIDTH_EM = 300f
    const val MAX_HEIGHT_EM = 120f

    /** Formulas typeset in one message; the rest stay as their source. */
    const val MAX_PER_MESSAGE = 120

    fun accepts(layout: MathLayout): Boolean {
        val total = layout.height + layout.depth
        val order = layout.order
        return order.count { it == MathLayout.GLYPH } == layout.glyphCount &&
            order.count { it == MathLayout.RULE } == layout.ruleColors.size &&
            order.count { it == MathLayout.PATH } == layout.paths.size &&
            layout.glyphCodePoints.all(Character::isValidCodePoint) &&
            layout.glyphFonts.all { it in -1 until MathFontIds.ALL.size } &&
            layout.width.isFinite() && layout.height.isFinite() && layout.depth.isFinite() &&
            layout.width in 0f..MAX_WIDTH_EM && total in 0f..MAX_HEIGHT_EM &&
            layout.glyphGeometry.all(Float::isFinite) && layout.rules.all(Float::isFinite) &&
            layout.paths.all { path -> path.x.isFinite() && path.y.isFinite() && path.points.all(Float::isFinite) } &&
            layout.weight <= MAX_DRAW_ITEMS
    }
}

/** The math faces, in the order glyphs refer to them by index. Files are `fonts/KaTeX_<id>.ttf`. */
object MathFontIds {
    val ALL = listOf(
        "AMS-Regular", "Caligraphic-Regular", "Caligraphic-Bold", "Fraktur-Regular", "Fraktur-Bold",
        "Main-Bold", "Main-BoldItalic", "Main-Italic", "Main-Regular", "Math-BoldItalic", "Math-Italic",
        "SansSerif-Bold", "SansSerif-Italic", "SansSerif-Regular", "Script-Regular", "Size1-Regular",
        "Size2-Regular", "Size3-Regular", "Size4-Regular", "Typewriter-Regular",
    )

    fun indexOf(id: String): Int = ALL.indexOf(id)

    fun assetPath(index: Int): String = "fonts/KaTeX_${ALL[index]}.ttf"
}
