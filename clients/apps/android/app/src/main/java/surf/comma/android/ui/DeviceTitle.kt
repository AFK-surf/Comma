package surf.comma.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ReplacementSpan
import androidx.core.content.ContextCompat
import surf.comma.android.chat.model.DeviceOrigin
import surf.comma.android.chat.render.DeviceOriginMarker
import kotlin.math.roundToInt

/**
 * [title] with one picture in front of it per kind of device that has spoken in the conversation.
 * No kinds, the title as it was.
 *
 * The pictures are spans inside the title's own line rather than views beside it: they scale with
 * the title's text size, stay on its baseline, and leave the row's layout exactly as it was.
 */
internal fun titleWithDeviceIcons(
    context: Context,
    origins: List<DeviceOrigin>,
    title: CharSequence,
): CharSequence {
    if (origins.isEmpty()) return title
    val gapPx = (DEVICE_ICON_GAP_DP * context.resources.displayMetrics.density).roundToInt()
    val builder = SpannableStringBuilder()
    origins.forEachIndexed { index, origin ->
        val drawable = ContextCompat.getDrawable(context, DeviceOriginMarker.drawableFor(origin))
            ?.mutate()
            ?: return@forEachIndexed
        val start = builder.length
        builder.append(OBJECT_REPLACEMENT)
        val gap = if (index == origins.lastIndex) gapPx * 2 else gapPx
        builder.setSpan(DeviceIconSpan(drawable, gap), start, builder.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }
    return builder.append(title)
}

/** What a screen reader says for the same title: the devices by name, then the title. */
internal fun deviceTitleDescription(
    context: Context,
    origins: List<DeviceOrigin>,
    title: CharSequence,
): CharSequence? {
    if (origins.isEmpty()) return null
    val devices = origins.joinToString(", ") { context.getString(DeviceOriginMarker.labelFor(it)) }
    return "$devices, $title"
}

/**
 * One device picture exactly as tall as a CJK character of the title, and level with it, followed
 * by [gapPx]. Titles are mostly Chinese; measured against a Latin capital the picture came out a
 * size smaller than the words beside it. Every row measures the same glyph, so every row's
 * pictures are the same size whatever its title says. It reports the paint's own font metrics, so
 * the line is exactly as tall as text alone.
 */
private class DeviceIconSpan(
    private val drawable: Drawable,
    private val gapPx: Int,
) : ReplacementSpan() {
    private val glyphBounds = Rect()

    override fun getSize(
        paint: Paint,
        text: CharSequence?,
        start: Int,
        end: Int,
        fm: Paint.FontMetricsInt?,
    ): Int {
        fm?.let(paint::getFontMetricsInt)
        return iconWidth(glyph(paint).height()) + gapPx
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
        val glyph = glyph(paint)
        val left = x.roundToInt()
        drawable.setBounds(left, y + glyph.top, left + iconWidth(glyph.height()), y + glyph.bottom)
        drawable.draw(canvas)
    }

    /** The reference glyph's ink, relative to the baseline. */
    private fun glyph(paint: Paint): Rect {
        paint.getTextBounds(GLYPH_REFERENCE, 0, GLYPH_REFERENCE.length, glyphBounds)
        if (glyphBounds.height() < 1) glyphBounds.top = glyphBounds.bottom - 1
        return glyphBounds
    }

    private fun iconWidth(height: Int): Int {
        val intrinsicHeight = drawable.intrinsicHeight.coerceAtLeast(1)
        return (drawable.intrinsicWidth * height.toFloat() / intrinsicHeight).roundToInt()
    }
}

private const val OBJECT_REPLACEMENT = "￼"
private const val GLYPH_REFERENCE = "中"
private const val DEVICE_ICON_GAP_DP = 3f
