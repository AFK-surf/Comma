package surf.comma.android.chat.render

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import surf.comma.android.R
import surf.comma.android.chat.model.DeviceOrigin
import surf.comma.android.chat.model.MessageSource

/**
 * The device picture: in front of a conversation's title, and beside a message another kind of
 * device sent ([DeviceOrigin.markFor]).
 *
 * Like [VoiceMarker] it is an attribute of the message, not a piece of it: it takes no room in
 * [PreparedChatMessage], moves nothing, and changes neither the bubble nor its colour.
 * [ChatMessageCell] draws it into the space left of the user bubble, level with the first line.
 */
internal object DeviceOriginMarker {

    @DrawableRes
    fun drawableFor(origin: DeviceOrigin): Int = when (origin) {
        DeviceOrigin.PHONE -> R.drawable.ic_device_phone
        DeviceOrigin.MAC -> R.drawable.ic_device_mac
    }

    @StringRes
    fun labelFor(origin: DeviceOrigin): Int = when (origin) {
        DeviceOrigin.PHONE -> R.string.device_phone
        DeviceOrigin.MAC -> R.string.device_mac
    }

    data class Spec(
        val left: Float,
        val top: Float,
        val right: Float,
        val bottom: Float,
    )

    /**
     * Where the picture goes, or null when the message carries none.
     *
     * [iconWidth] and [iconHeight] are the drawable's own size in pixels. It sits [VoiceMarker.GAP_DP]
     * left of the column, top-aligned with the first line as the voice marker is. A message that
     * had both would put the device one step further out, so neither covers the other.
     */
    fun spec(
        origin: DeviceOrigin?,
        source: MessageSource?,
        columnLeft: Float,
        contentTop: Float,
        iconWidth: Float,
        iconHeight: Float,
        density: Float,
    ): Spec? {
        origin ?: return null
        val gap = VoiceMarker.GAP_DP * density
        val voiceMarker = VoiceMarker.spec(source, columnLeft, contentTop, density)
        val right = (voiceMarker?.left ?: columnLeft) - gap
        val left = (right - iconWidth).coerceAtLeast(0f)
        return Spec(
            left = left,
            top = contentTop,
            right = left + iconWidth,
            bottom = contentTop + iconHeight,
        )
    }
}
