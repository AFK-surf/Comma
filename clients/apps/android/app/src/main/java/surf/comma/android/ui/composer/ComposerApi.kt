package surf.comma.android.ui.composer

import android.graphics.Bitmap
import android.graphics.RectF
import android.net.Uri
import android.text.Layout
import android.text.TextPaint

/** An image the user attached. The composer never compresses or uploads it. */
data class ComposerAttachment(val id: String, val uri: Uri)

/**
 * A frozen copy of what the user just sent, for the send transition. Everything is in window
 * coordinates and detached from the live views, so it stays valid after the composer clears.
 *
 * @property textLayout a static copy of the input's layout (same paint and width), or null when
 *   the message has no text. Draw it with its top-left at [textOrigin].
 * @property surfaceBounds the rounded input surface (or the voice bubble) at the moment of sending.
 */
class ComposerSendSnapshot(
    val text: CharSequence,
    val textLayout: Layout?,
    val textPaint: TextPaint,
    val textOrigin: android.graphics.PointF,
    val surfaceBounds: RectF,
    val surfaceCornerRadius: Float,
    val attachments: List<Attachment>,
    val fromVoice: Boolean,
) {
    /** A thumbnail as shown in the composer. [bitmap] is null if it had not loaded yet. */
    class Attachment(val id: String, val uri: Uri, val bounds: RectF, val bitmap: Bitmap?,
                     val visibleBounds: RectF = RectF(bounds))
}
