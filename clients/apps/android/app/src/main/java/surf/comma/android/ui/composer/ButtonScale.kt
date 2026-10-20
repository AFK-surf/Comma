package surf.comma.android.ui.composer

import android.content.Context
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import androidx.dynamicanimation.animation.DynamicAnimation
import surf.comma.android.ui.theme.DesignMotion
import surf.comma.android.ui.theme.DesignSpring

/**
 * One view's scale, driven by a single pair of [DesignMotion.springScale] springs. Shown/hidden
 * and pressed combine into one target, so a press during a swap does not fight the swap.
 */
internal class ButtonScale(private val view: View, private val action: Boolean) {
    private val x = DesignSpring(view, DynamicAnimation.SCALE_X, DesignMotion.springScale)
    private val y = DesignSpring(view, DynamicAnimation.SCALE_Y, DesignMotion.springScale)
    private var shown = true
    private var pressed = false

    fun setShown(value: Boolean, animated: Boolean) {
        shown = value
        apply(animated)
    }

    fun setPressed(value: Boolean) {
        if (pressed == value) return
        pressed = value
        apply(animated = true)
    }

    private fun apply(animated: Boolean) {
        // pressScale() is read when the press starts, so the system animation switch applies.
        val target = (if (shown) 1f else HIDDEN_SCALE) * (if (pressed) DesignMotion.pressScale(action) else 1f)
        if (animated) {
            x.animateTo(target)
            y.animateTo(target)
        } else {
            x.cancel()
            y.cancel()
            view.scaleX = target
            view.scaleY = target
        }
    }

    companion object {
        /** A hidden button shrinks to this while it fades; it never scales to zero. */
        const val HIDDEN_SCALE = 0.6f
    }
}

/** An icon button that reports press changes, including ones set programmatically. */
// The composer supplies its own icon tint and uses platform widgets on every supported API.
@android.annotation.SuppressLint("AppCompatCustomView")
internal class PressableImageView(context: Context) : ImageView(context) {
    var onPressedChanged: ((Boolean) -> Unit)? = null

    override fun setPressed(pressed: Boolean) {
        val changed = pressed != isPressed
        super.setPressed(pressed)
        if (changed) onPressedChanged?.invoke(pressed)
    }
}

/** A tile that shrinks slightly while pressed. */
internal class PressableTile(context: Context) : LinearLayout(context) {
    // Nullable: the platform constructor may touch pressed state before this class initialises.
    private var scale: ButtonScale? = null

    init {
        scale = ButtonScale(this, action = false)
    }

    override fun setPressed(pressed: Boolean) {
        val changed = pressed != isPressed
        super.setPressed(pressed)
        if (changed) scale?.setPressed(pressed)
    }
}
