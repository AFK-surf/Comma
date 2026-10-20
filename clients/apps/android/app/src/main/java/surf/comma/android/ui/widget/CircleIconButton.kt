package surf.comma.android.ui.widget

import android.content.Context
import android.graphics.Color
import android.util.AttributeSet
import android.view.Gravity
import android.widget.FrameLayout
import surf.comma.android.R

class CircleIconButton @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    val icon = DotMatrixView(context)

    init {
        isClickable = true
        isFocusable = true
        if (background == null) {
            setBackgroundResource(R.drawable.bg_circle_white)
        }
        addView(icon, LayoutParams(dp(18), dp(18), Gravity.CENTER))
    }

    fun setPattern(
        pattern: List<String>,
        color: Int = Color.BLACK,
        unlitColor: Int? = null,
        iconSizeDp: Int = 18,
    ) {
        val size = dp(iconSizeDp)
        icon.layoutParams = LayoutParams(size, size, Gravity.CENTER)
        icon.pattern = pattern
        icon.dotColor = color
        icon.unlitColor = unlitColor
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}
