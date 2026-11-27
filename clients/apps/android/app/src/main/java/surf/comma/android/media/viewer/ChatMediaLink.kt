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
    /** Multi-image group row host for bidirectional viewer sync and per-card shared-element bounds. */
    interface GroupHost {
        /** Aligns the collapsed fan deck's front card to [imageIndex] and returns that card's view. */
        fun alignToImage(imageIndex: Int): View?
        /** The card view currently representing [imageIndex]. */
        fun cardView(imageIndex: Int): View?
        /** A copy of the loaded drawable currently shown for [imageIndex], or null. */
        fun picture(imageIndex: Int, resources: android.content.res.Resources): android.graphics.drawable.Drawable?
        /** Corner radius of the group's image cards in pixels, for rounded shared-element transitions. */
        fun cardCornerRadiusPx(): Float = 0f
    }

    private val tiles = HashMap<Long, WeakReference<View>>()
    private val cornerRadii = HashMap<Long, Float>()
    private val groups = HashMap<Long, WeakReference<GroupHost>>()

    /** Brings a row's tile into the chat's view; the chat that opened the viewer sets it. */
    var reveal: ((Long) -> Unit)? = null

    /** Notifies the chat that the viewer paged to [imageIndex] inside multi-image row [row]. */
    var onAlignGroup: ((row: Long, imageIndex: Int) -> Unit)? = null

    @MainThread
    fun register(row: Long, tile: View, cornerRadiusPx: Float = 0f) {
        tiles[row] = WeakReference(tile)
        cornerRadii[row] = cornerRadiusPx.coerceAtLeast(0f)
    }

    @MainThread
    fun unregister(row: Long, tile: View) {
        if (tiles[row]?.get() === tile) {
            tiles.remove(row)
            cornerRadii.remove(row)
        }
    }

    @MainThread
    fun registerGroup(row: Long, host: GroupHost) {
        groups[row] = WeakReference(host)
    }

    @MainThread
    fun unregisterGroup(row: Long, host: GroupHost) {
        if (groups[row]?.get() === host) groups.remove(row)
    }

    /** Aligns multi-image row [row] to [imageIndex] so closing the viewer returns to that card. */
    @MainThread
    fun align(row: Long, imageIndex: Int) {
        if (imageIndex < 0) return
        onAlignGroup?.invoke(row, imageIndex)
        groups[row]?.get()?.alignToImage(imageIndex)
    }

    @MainThread
    fun tile(row: Long, imageIndex: Int = -1): View? {
        if (imageIndex >= 0) {
            groups[row]?.get()?.cardView(imageIndex)?.let { return it }
        }
        return tiles[row]?.get()
    }

    /** Corner radius of the tile in pixels, for matching rounded clips during shared-element transitions. */
    @MainThread
    fun cornerRadius(row: Long, imageIndex: Int = -1): Float {
        if (imageIndex >= 0) {
            groups[row]?.get()?.let { return it.cardCornerRadiusPx().coerceAtLeast(0f) }
        }
        return cornerRadii[row] ?: 0f
    }

    /** A copy of the picture the tile shows, for the viewer to show while its own decode runs; null without one. */
    @MainThread
    fun picture(row: Long, resources: android.content.res.Resources, imageIndex: Int = -1): android.graphics.drawable.Drawable? {
        if (imageIndex >= 0) {
            groups[row]?.get()?.picture(imageIndex, resources)?.let { return it }
        }
        val image = (tile(row) as? android.view.ViewGroup)?.getChildAt(0) as? surf.comma.android.media.SendImageView ?: return null
        return image.presentation.target?.constantState?.newDrawable(resources)
    }

    /**
     * The tile's rectangle on screen, or false when it is not drawn: detached, hidden, empty or scrolled out of the
     * chat's visible area.
     */
    @MainThread
    fun bounds(row: Long, out: Rect, imageIndex: Int = -1): Boolean {
        val tile = tile(row, imageIndex) ?: return false
        if (!tile.isAttachedToWindow || !tile.isShown || tile.width <= 0 || tile.height <= 0) return false
        if (!tile.getGlobalVisibleRect(Rect())) return false
        val location = IntArray(2)
        tile.getLocationOnScreen(location)
        out.set(location[0], location[1], location[0] + tile.width, location[1] + tile.height)
        return true
    }
}
