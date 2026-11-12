package surf.comma.android.ui.composer

import android.graphics.Bitmap
import android.graphics.RectF
import android.net.Uri
import android.text.Layout
import android.text.TextPaint
import surf.comma.android.media.PickedFile
import surf.comma.android.media.ViewerImage

/**
 * A file of the draft, as its provider describes it. The composer never compresses or uploads it. A file picked on
 * this page has the [uri] it was picked from, which its thumbnail draws. Any other file of the draft has [Uri.EMPTY]
 * and draws [uploaded], the server's copy of an uploaded image, or else a card with its name.
 */
data class ComposerAttachment(val id: String, val uri: Uri, val file: PickedFile, val uploaded: ViewerImage.Remote? = null) {
    /** Whether the device has the file at hand, at [uri]. */
    val local: Boolean get() = uri != Uri.EMPTY
}

/** A file of the draft as its host lists it, and how its upload goes. */
data class ShownAttachment(val attachment: ComposerAttachment, val state: AttachmentUploadState)

/**
 * A frozen copy of what the user just sent, for the send transition. Everything is in window
 * coordinates and detached from the live views, so it stays valid after the composer clears.
 *
 * @property textLayout a static copy of the input's layout (same paint and width), or null when
 *   the message has no text. Draw it with its top-left at [textOrigin].
 * @property surfaceBounds the rounded input surface at the moment of sending.
 */
class ComposerSendSnapshot(
    val text: CharSequence,
    val textLayout: Layout?,
    val textPaint: TextPaint,
    val textOrigin: android.graphics.PointF,
    val surfaceBounds: RectF,
    val attachments: List<Attachment>,
) {
    /** A thumbnail as shown in the composer. [bitmap] is null if it had not loaded yet. */
    class Attachment(val id: String, val uri: Uri, val bounds: RectF, val bitmap: Bitmap?,
                     val visibleBounds: RectF = RectF(bounds))
}
