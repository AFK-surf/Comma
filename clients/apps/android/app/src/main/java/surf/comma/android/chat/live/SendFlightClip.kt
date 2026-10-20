package surf.comma.android.chat.live

import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF

/** A piece can leave its real source aperture once; afterwards it belongs to the chat viewport. */
internal class SendFlightClip {
    val sourceInWindow = RectF()
    private val source = RectF()
    private val path = Path()
    var departed = false
        private set

    fun apply(canvas: Canvas, chat: RectF, frame: RectF, originX: Float, originY: Float, landed: Boolean) {
        source.set(sourceInWindow)
        source.offset(-originX, -originY)
        if (landed || !RectF.intersects(frame, source)) departed = true
        path.reset()
        if (!chat.isEmpty) path.addRect(chat, Path.Direction.CW)
        if (!departed && !source.isEmpty) path.addRect(source, Path.Direction.CW)
        canvas.clipPath(path)
    }
}
