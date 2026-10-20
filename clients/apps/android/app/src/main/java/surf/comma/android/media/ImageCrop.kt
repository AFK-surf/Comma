package surf.comma.android.media

import android.graphics.RectF
import kotlin.math.max

/** Full, oriented image coordinates. Only the aperture changes shape; pixels scale uniformly. */
internal object ImageCrop {
    fun cover(width: Int, height: Int, aperture: RectF, out: RectF) {
        require(width > 0 && height > 0)
        val scale = max(aperture.width() / width, aperture.height() / height)
        val w = width * scale
        val h = height * scale
        out.set(aperture.centerX() - w / 2f, aperture.centerY() - h / 2f,
            aperture.centerX() + w / 2f, aperture.centerY() + h / 2f)
    }
}
