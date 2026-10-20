package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import kotlin.math.min

/** Nothing's dot-matrix language: '#' is a lit dot, '.' an unlit one. */
class DotMatrixView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    var pattern: List<String> = emptyList()
        set(value) {
            field = value
            invalidate()
        }

    var dotColor: Int = Color.BLACK
        set(value) {
            field = value
            invalidate()
        }

    var unlitColor: Int? = null
        set(value) {
            field = value
            invalidate()
        }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (pattern.isEmpty()) return
        val rows = pattern.size
        val columns = pattern.maxOf { it.length }
        if (columns == 0) return
        val step = min(width.toFloat() / columns, height.toFloat() / rows)
        val radius = step * 0.34f
        val originX = (width - step * columns) / 2f
        val originY = (height - step * rows) / 2f
        pattern.forEachIndexed { row, line ->
            for (column in 0 until columns) {
                val lit = column < line.length && line[column] == '#'
                val color = if (lit) dotColor else unlitColor ?: continue
                paint.color = color
                canvas.drawCircle(
                    originX + step * (column + 0.5f),
                    originY + step * (row + 0.5f),
                    radius,
                    paint,
                )
            }
        }
    }
}
