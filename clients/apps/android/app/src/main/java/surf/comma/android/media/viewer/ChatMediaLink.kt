package surf.comma.android.media.viewer

import android.graphics.Rect
import android.view.View
import androidx.annotation.MainThread
import java.lang.ref.WeakReference

/**
 * The chat's media tiles as the open viewer finds them, by timeline row: the viewer zooms from the tile it opened and
 * back to the tile of the page it closes on, and asks the chat to reveal that tile while the member pages. Tiles are
 * held weakly; a chat that is gone has none. Main thread only.
 */
object ChatMediaLink {
    private val tiles = HashMap<Long, WeakReference<View>>()

    /** Brings a row's tile into the chat's view; the chat that opened the viewer sets it. */
    var reveal: ((Long) -> Unit)? = null

    @MainThread
    fun register(row: Long, tile: View) {
        tiles[row] = WeakReference(tile)
    }

    @MainThread
    fun unregister(row: Long, tile: View) {
        if (tiles[row]?.get() === tile) tiles.remove(row)
    }

    @MainThread fun tile(row: Long): View? = tiles[row]?.get()

    /** A copy of the picture the tile shows, for the viewer to show while its own decode runs; null without one. */
    @MainThread
    fun picture(row: Long, resources: android.content.res.Resources): android.graphics.drawable.Drawable? {
        val image = (tile(row) as? android.view.ViewGroup)?.getChildAt(0) as? surf.comma.android.media.SendImageView ?: return null
        return image.presentation.target?.constantState?.newDrawable(resources)
    }

    /**
     * The tile's rectangle on screen, or false when it is not drawn: detached, hidden, empty or scrolled out of the
     * chat's visible area.
     */
    @MainThread
    fun bounds(row: Long, out: Rect): Boolean {
        val tile = tile(row) ?: return false
        if (!tile.isAttachedToWindow || !tile.isShown || tile.width <= 0 || tile.height <= 0) return false
        if (!tile.getGlobalVisibleRect(Rect())) return false
        val location = IntArray(2)
        tile.getLocationOnScreen(location)
        out.set(location[0], location[1], location[0] + tile.width, location[1] + tile.height)
        return true
    }
}
