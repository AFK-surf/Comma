package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import surf.comma.android.R

class DotRuleView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.rule_grey)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val density = resources.displayMetrics.density
        val step = 7f * density
        val radius = 1.3f * density
        val y = height / 2f
        var x = step / 2f
        while (x < width) {
            canvas.drawCircle(x, y, radius, paint)
            x += step
        }
    }
}
